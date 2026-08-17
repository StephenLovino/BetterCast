package com.bettercast.receiver.viewmodel

import android.app.Application
import android.util.Log
import androidx.annotation.StringRes
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.bettercast.receiver.R
import com.bettercast.receiver.audio.AudioPlayer
import com.bettercast.receiver.data.SettingsStore
import com.bettercast.receiver.input.InputEvent
import com.bettercast.receiver.network.ConnectionState
import com.bettercast.receiver.network.DiscoveredSender
import com.bettercast.receiver.network.HotspotManager
import com.bettercast.receiver.network.SenderInviter
import com.bettercast.receiver.network.ServiceAdvertiser
import com.bettercast.receiver.network.ServiceDiscovery
import com.bettercast.receiver.network.TcpClient
import com.bettercast.receiver.network.UdpClient
import com.bettercast.receiver.video.VideoDecoder
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
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

        /**
         * How long "Switching connection..." is allowed to stand before falling back to
         * the waiting screen. A genuine transport handover (the Mac moving a session from
         * infrastructure to P2P) completes in about a second; anything longer means the
         * sender is not coming back on its own.
         */
        private const val RECONNECT_GRACE_MS = 6_000L
    }

    private val _state = MutableStateFlow(ReceiverState.WAITING)
    val state: StateFlow<ReceiverState> = _state.asStateFlow()

    // application, not str(): this initialiser runs before the rest of the class is set up.
    private val _statusMessage = MutableStateFlow(application.getString(R.string.status_starting))
    val statusMessage: StateFlow<String> = _statusMessage.asStateFlow()

    private val _connectedSenderName = MutableStateFlow<String?>(null)
    val connectedSenderName: StateFlow<String?> = _connectedSenderName.asStateFlow()

    private val _deviceIp = MutableStateFlow<String?>(null)
    val deviceIp: StateFlow<String?> = _deviceIp.asStateFlow()

    /** Credentials of the local-only hotspot, non-null only while it is running. */
    private val _hotspot = MutableStateFlow<HotspotManager.Credentials?>(null)
    val hotspot: StateFlow<HotspotManager.Credentials?> = _hotspot.asStateFlow()

    private val _hotspotError = MutableStateFlow<String?>(null)
    val hotspotError: StateFlow<String?> = _hotspotError.asStateFlow()

    /** Non-null while an invite is in flight, so the row can show progress. */
    private val _invitingSender = MutableStateFlow<String?>(null)
    val invitingSender: StateFlow<String?> = _invitingSender.asStateFlow()

    private val _inviteError = MutableStateFlow<String?>(null)
    val inviteError: StateFlow<String?> = _inviteError.asStateFlow()

    /**
     * Status messages reach the UI as plain strings, so they are resolved here rather
     * than at the call site — `stringResource` is composable-only and these are set
     * from network callbacks.
     */
    private fun str(@StringRes id: Int, vararg args: Any): String =
        getApplication<Application>().getString(id, *args)

    val settings = SettingsStore(application)

    val tcpServer = TcpClient()
    val videoDecoder = VideoDecoder()
    private val audioPlayer = AudioPlayer()
    private val serviceAdvertiser = ServiceAdvertiser(application)
    private val serviceDiscovery = ServiceDiscovery(application)
    private val senderInviter = SenderInviter()
    private val hotspotManager = HotspotManager(application)
    private var udpClient: UdpClient? = null

    /** Macs advertising themselves on this network, for the pick-a-sender list. */
    val discoveredSenders: StateFlow<List<DiscoveredSender>> = serviceDiscovery.discoveredSenders

    private var wasConnected = false
    private var reconnectWatchdog: Job? = null

    init {
        // Observe TCP connection state changes
        viewModelScope.launch {
            tcpServer.connectionState.collect { connState ->
                when (connState) {
                    ConnectionState.CONNECTED -> {
                        reconnectWatchdog?.cancel()
                        wasConnected = true
                        _state.value = ReceiverState.CONNECTED
                        _statusMessage.value = str(R.string.status_connected_tcp)
                        _connectedSenderName.value = tcpServer.connectedSenderName.value
                    }
                    ConnectionState.LISTENING -> {
                        // Only show waiting if UDP isn't connected either
                        if (udpClient?.isSenderConnected != true) {
                            if (wasConnected) {
                                // Was previously connected — show reconnecting instead of
                                // blank waiting, but only briefly. Reconnecting has no
                                // sender list and no controls, so leaving it up
                                // indefinitely strands the user: the only escape was to
                                // start the session from the Mac instead.
                                _state.value = ReceiverState.RECONNECTING
                                _statusMessage.value = str(R.string.status_switching)
                                startReconnectWatchdog()
                            } else {
                                _state.value = ReceiverState.WAITING
                                _statusMessage.value = str(R.string.status_waiting_connect)
                            }
                            _connectedSenderName.value = null
                            videoDecoder.stop()
                        }
                    }
                    ConnectionState.ERROR -> {
                        _state.value = ReceiverState.ERROR
                        _statusMessage.value = tcpServer.errorMessage.value
                            ?: str(R.string.status_connection_error)
                    }
                    ConnectionState.IDLE -> {
                        wasConnected = false
                        _state.value = ReceiverState.WAITING
                        _statusMessage.value = str(R.string.status_starting)
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

        // Wire TCP audio data to the audio player (starts lazily on first real packet).
        // Muting drops packets here rather than pausing the track, so the stream stays
        // in sync and unmuting picks up at the live edge instead of replaying a backlog.
        tcpServer.onAudioReceived = { data ->
            if (settings.audioEnabled.value) audioPlayer.onAudioData(data)
        }

        // Browsing is only useful while idle: once a stream is up the list is noise, and
        // NSD keeps a multicast lock open for as long as it runs.
        viewModelScope.launch {
            state.collect { current ->
                if (current == ReceiverState.CONNECTED) serviceDiscovery.stopDiscovery()
                else serviceDiscovery.startDiscovery()
            }
        }

        viewModelScope.launch {
            settings.audioEnabled.collect { enabled -> if (!enabled) audioPlayer.stop() }
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
            _statusMessage.value = str(R.string.status_waiting)

            // Advertise via mDNS/Bonjour so the sender can find us
            serviceAdvertiser.startAdvertising(port, settings.deviceName.value)

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
                    _statusMessage.value = str(R.string.status_connected_udp)
                    _connectedSenderName.value = "Sender (UDP)"
                }
            }
            udp.start()
            udpClient = udp
        } else {
            _state.value = ReceiverState.ERROR
            _statusMessage.value = str(R.string.status_failed_start)
        }
    }

    private fun startReconnectWatchdog() {
        reconnectWatchdog?.cancel()
        reconnectWatchdog = viewModelScope.launch {
            delay(RECONNECT_GRACE_MS)
            if (_state.value == ReceiverState.RECONNECTING) {
                backToDevices()
            }
        }
    }

    /** Give up waiting for a handover and show the sender list again. */
    fun backToDevices() {
        reconnectWatchdog?.cancel()
        wasConnected = false
        _state.value = ReceiverState.WAITING
        _statusMessage.value = str(R.string.status_waiting_connect)
    }

    fun disconnect() {
        tcpServer.disconnect()
        udpClient?.stop()
        videoDecoder.stop()
        audioPlayer.stop()
        _connectedSenderName.value = null
        _state.value = ReceiverState.WAITING
        _statusMessage.value = str(R.string.status_waiting_connect)

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
                    _statusMessage.value = str(R.string.status_connected_udp)
                    _connectedSenderName.value = "Sender (UDP)"
                }
            }
            udp.start()
            udpClient = udp
        }
    }

    /**
     * Ask a discovered Mac to stream here.
     *
     * The Mac dials back rather than replying on this connection, so success only means
     * the request landed — the stream still arrives through the normal accept loop.
     */
    fun inviteSender(sender: DiscoveredSender) {
        _inviteError.value = null
        _invitingSender.value = sender.name
        senderInviter.invite(sender, settings.deviceName.value) { failure ->
            viewModelScope.launch {
                _invitingSender.value = null
                _inviteError.value = failure
                if (failure == null) _statusMessage.value = str(R.string.status_invited, sender.name)
            }
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

    /**
     * Host a local-only hotspot so a Mac can connect with no router.
     *
     * The phone drops off Wi-Fi while this is up and neither device has internet —
     * that is what "local only" means, and it is the point: it creates a network
     * where there was none.
     */
    fun startHotspot() {
        _hotspotError.value = null
        hotspotManager.start(
            onReady = { creds ->
                _hotspot.value = creds
                Log.d(TAG, "Hotspot ready: ${creds.ssid}")
                // The IP changes when we become the access point, so refresh it.
                _deviceIp.value = getDeviceIpAddress()
            },
            onError = { message ->
                _hotspot.value = null
                _hotspotError.value = message
                Log.e(TAG, "Hotspot error: $message")
            }
        )
    }

    fun stopHotspot() {
        hotspotManager.stop()
        _hotspot.value = null
        _hotspotError.value = null
        _deviceIp.value = getDeviceIpAddress()
    }

    /** Fully stop the receiver (release port). Used when switching to Sender mode. */
    fun stopReceiver() {
        serviceAdvertiser.stopAdvertising()
        tcpServer.stopListening()
        udpClient?.destroy()
        udpClient = null
        videoDecoder.stop()
        audioPlayer.stop()
        _state.value = ReceiverState.WAITING
        _statusMessage.value = str(R.string.status_stopped)
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
        reconnectWatchdog?.cancel()
        serviceDiscovery.stopDiscovery()
        hotspotManager.stop()
        serviceAdvertiser.stopAdvertising()
        tcpServer.destroy()
        udpClient?.destroy()
        videoDecoder.destroy()
        audioPlayer.destroy()
    }
}
