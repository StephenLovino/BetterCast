package com.bettercast.receiver.viewmodel

import android.app.Application
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.bettercast.receiver.input.InputEvent
import com.bettercast.receiver.network.ConnectionState
import com.bettercast.receiver.network.ServiceAdvertiser
import com.bettercast.receiver.network.TcpClient
import com.bettercast.receiver.network.UdpClient
import com.bettercast.receiver.video.VideoDecoder
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.net.NetworkInterface

enum class ReceiverState {
    WAITING,
    CONNECTED,
    RECONNECTING,
    ERROR
}

class ReceiverViewModel(application: Application) : AndroidViewModel(application) {

    companion object {
        private const val TAG = "ReceiverViewModel"
    }

    private val _state = MutableStateFlow(ReceiverState.WAITING)
    val state: StateFlow<ReceiverState> = _state.asStateFlow()

    private val _statusMessage = MutableStateFlow("Starting...")
    val statusMessage: StateFlow<String> = _statusMessage.asStateFlow()

    private val _connectedSenderName = MutableStateFlow<String?>(null)
    val connectedSenderName: StateFlow<String?> = _connectedSenderName.asStateFlow()

    private val _deviceIp = MutableStateFlow<String?>(null)
    val deviceIp: StateFlow<String?> = _deviceIp.asStateFlow()

    val tcpServer = TcpClient()
    val videoDecoder = VideoDecoder()
    private val serviceAdvertiser = ServiceAdvertiser(application)
    private var udpClient: UdpClient? = null

    private var wasConnected = false

    init {
        // Observe TCP connection state changes
        viewModelScope.launch {
            tcpServer.connectionState.collect { connState ->
                when (connState) {
                    ConnectionState.CONNECTED -> {
                        wasConnected = true
                        _state.value = ReceiverState.CONNECTED
                        _statusMessage.value = "Connected to sender (TCP)"
                        _connectedSenderName.value = tcpServer.connectedSenderName.value
                    }
                    ConnectionState.LISTENING -> {
                        // Only show waiting if UDP isn't connected either
                        if (udpClient?.isSenderConnected != true) {
                            if (wasConnected) {
                                // Was previously connected — show reconnecting instead of blank waiting
                                _state.value = ReceiverState.RECONNECTING
                                _statusMessage.value = "Switching connection..."
                            } else {
                                _state.value = ReceiverState.WAITING
                                _statusMessage.value = "Waiting for sender to connect..."
                            }
                            _connectedSenderName.value = null
                            videoDecoder.stop()
                        }
                    }
                    ConnectionState.ERROR -> {
                        _state.value = ReceiverState.ERROR
                        _statusMessage.value = tcpServer.errorMessage.value ?: "Connection error"
                    }
                    ConnectionState.IDLE -> {
                        wasConnected = false
                        _state.value = ReceiverState.WAITING
                        _statusMessage.value = "Starting..."
                    }
                }
            }
        }

        // Wire video decoder keyframe requests
        videoDecoder.onKeyframeNeeded = {
            sendInputEvent(InputEvent.requestKeyframe())
        }

        // Wire TCP frame data to video decoder
        tcpServer.onFrameReceived = { data ->
            videoDecoder.onFrameData(data)
        }

        // Start the server and advertise
        startReceiver()
    }

    private fun startReceiver() {
        _deviceIp.value = getDeviceIpAddress()

        // Start TCP server on fixed port (enables ADB port forwarding)
        val port = tcpServer.startListening()
        if (port > 0) {
            val ip = _deviceIp.value ?: "unknown"
            Log.d(TAG, "TCP server listening on $ip:$port")
            _statusMessage.value = "Waiting for sender..."

            // Advertise via mDNS/Bonjour so the sender can find us
            serviceAdvertiser.startAdvertising(port)

            // Start UDP client on the same port
            val udp = UdpClient(port)
            udp.onFrameReassembled = { data ->
                videoDecoder.onFrameData(data)
            }
            udp.onGapDetected = {
                videoDecoder.requestKeyframeIfNeeded()
            }
            udp.onSenderConnected = {
                viewModelScope.launch {
                    _state.value = ReceiverState.CONNECTED
                    _statusMessage.value = "Connected to sender (UDP)"
                    _connectedSenderName.value = "Sender (UDP)"
                }
            }
            udp.start()
            udpClient = udp
        } else {
            _state.value = ReceiverState.ERROR
            _statusMessage.value = "Failed to start server"
        }
    }

    fun disconnect() {
        tcpServer.disconnect()
        udpClient?.stop()
        videoDecoder.stop()
        _connectedSenderName.value = null
        _state.value = ReceiverState.WAITING
        _statusMessage.value = "Waiting for sender to connect..."

        // Restart UDP listener
        val port = tcpServer.listeningPort
        if (port > 0) {
            val udp = UdpClient(port)
            udp.onFrameReassembled = { data ->
                videoDecoder.onFrameData(data)
            }
            udp.onGapDetected = {
                videoDecoder.requestKeyframeIfNeeded()
            }
            udp.onSenderConnected = {
                viewModelScope.launch {
                    _state.value = ReceiverState.CONNECTED
                    _statusMessage.value = "Connected to sender (UDP)"
                    _connectedSenderName.value = "Sender (UDP)"
                }
            }
            udp.start()
            udpClient = udp
        }
    }

    fun sendInputEvent(event: InputEvent) {
        if (_state.value != ReceiverState.CONNECTED) return

        // Send via whichever transport is connected
        // Prefer TCP if connected, fall back to UDP
        if (tcpServer.connectionState.value == ConnectionState.CONNECTED) {
            tcpServer.sendInputEvent(event)
        } else if (udpClient?.isSenderConnected == true) {
            udpClient?.sendInputEvent(event)
        }
    }

    /** Fully stop the receiver (release port). Used when switching to Sender mode. */
    fun stopReceiver() {
        serviceAdvertiser.stopAdvertising()
        tcpServer.stopListening()
        udpClient?.destroy()
        udpClient = null
        videoDecoder.stop()
        _state.value = ReceiverState.WAITING
        _statusMessage.value = "Stopped"
    }

    fun retry() {
        stopReceiver()
        startReceiver()
    }

    private fun getDeviceIpAddress(): String? {
        try {
            for (iface in NetworkInterface.getNetworkInterfaces()) {
                if (iface.isLoopback || !iface.isUp) continue
                // Prefer wlan0 (WiFi) but accept any non-loopback
                for (addr in iface.inetAddresses) {
                    if (addr.isLoopbackAddress) continue
                    val ip = addr.hostAddress ?: continue
                    // IPv4 only
                    if (ip.contains(':')) continue
                    return ip
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to get IP address", e)
        }
        return null
    }

    override fun onCleared() {
        super.onCleared()
        serviceAdvertiser.stopAdvertising()
        tcpServer.destroy()
        udpClient?.destroy()
        videoDecoder.destroy()
    }
}
