package com.bettercast.receiver.sender

import android.util.Log
import com.bettercast.receiver.input.InputEvent
import com.bettercast.receiver.network.ConnectionState
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.Json
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer

/**
 * TCP server that sends H.264 video frames and receives input events.
 * Mirrors TcpClient pattern but with reversed data flow.
 */
class TcpSender {

    companion object {
        private const val TAG = "TcpSender"
        const val DEFAULT_PORT = 51820
    }

    private val _connectionState = MutableStateFlow(ConnectionState.IDLE)
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    private var serverSocket: ServerSocket? = null
    private var clientSocket: Socket? = null
    private var outputStream: DataOutputStream? = null
    private var inputStream: DataInputStream? = null

    private val sendQueue = Channel<ByteArray>(Channel.BUFFERED)

    private var acceptJob: Job? = null
    private var readJob: Job? = null
    private var writeJob: Job? = null

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    var onKeyframeRequested: (() -> Unit)? = null
    var onInputEventReceived: ((InputEvent) -> Unit)? = null

    var listeningPort: Int = 0
        private set

    /**
     * Start listening for incoming receiver connections.
     */
    fun startListening(): Int {
        if (_connectionState.value == ConnectionState.LISTENING ||
            _connectionState.value == ConnectionState.CONNECTED
        ) {
            return listeningPort
        }

        _errorMessage.value = null

        try {
            val server = ServerSocket(DEFAULT_PORT)
            serverSocket = server
            listeningPort = server.localPort
            _connectionState.value = ConnectionState.LISTENING

            Log.d(TAG, "Listening on port $listeningPort")
            startAcceptLoop(server)
            return listeningPort
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start server", e)
            _connectionState.value = ConnectionState.ERROR
            _errorMessage.value = "Failed to start listener: ${e.message}"
            return 0
        }
    }

    private fun startAcceptLoop(server: ServerSocket) {
        acceptJob = scope.launch {
            try {
                while (isActive) {
                    Log.d(TAG, "Waiting for receiver connection...")
                    val socket = server.accept()
                    socket.tcpNoDelay = true
                    socket.keepAlive = true
                    socket.sendBufferSize = 524288    // 512KB for video frames
                    socket.receiveBufferSize = 65536  // 64KB for input events

                    // Disconnect previous client if any
                    disconnectClient()

                    clientSocket = socket
                    outputStream = DataOutputStream(socket.getOutputStream())
                    inputStream = DataInputStream(socket.getInputStream())

                    val receiverAddress = socket.remoteSocketAddress.toString()
                    Log.d(TAG, "Receiver connected from $receiverAddress")
                    _connectionState.value = ConnectionState.CONNECTED

                    startReadLoop()
                    startWriteLoop()
                }
            } catch (e: IOException) {
                if (isActive) {
                    Log.e(TAG, "Accept error", e)
                }
            }
        }
    }

    /**
     * Enqueue an encoded video frame for sending.
     * Frame data is already in megapacket format (PTS + AVCC NALUs).
     * This wraps it with 4-byte big-endian length prefix.
     */
    fun sendFrame(frameData: ByteArray) {
        if (_connectionState.value != ConnectionState.CONNECTED) return

        val packet = ByteBuffer.allocate(4 + frameData.size)
        packet.putInt(frameData.size) // big-endian by default
        packet.put(frameData)
        sendQueue.trySend(packet.array())
    }

    /**
     * Read loop: receives input events from the Mac receiver.
     * Format: [4-byte big-endian length][JSON InputEvent]
     */
    private fun startReadLoop() {
        readJob?.cancel()
        readJob = scope.launch {
            val input = inputStream ?: return@launch
            Log.i(TAG, "Read loop started (receiving input events)")

            try {
                while (isActive) {
                    val length = input.readInt()
                    if (length <= 0 || length > 100_000) {
                        Log.w(TAG, "Invalid input event length: $length")
                        continue
                    }

                    val buffer = ByteArray(length)
                    input.readFully(buffer)

                    try {
                        val json = String(buffer, Charsets.UTF_8)
                        val event = Json.decodeFromString<InputEvent>(json)

                        when {
                            event.type == InputEvent.TYPE_COMMAND &&
                                    event.keyCode == InputEvent.COMMAND_HEARTBEAT -> {
                                // Heartbeat from receiver — connection alive, no-op
                            }
                            event.type == InputEvent.TYPE_COMMAND &&
                                    event.keyCode == InputEvent.COMMAND_REQUEST_KEYFRAME -> {
                                Log.d(TAG, "Keyframe requested by receiver")
                                onKeyframeRequested?.invoke()
                            }
                            else -> {
                                onInputEventReceived?.invoke(event)
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed to parse input event", e)
                    }
                }
            } catch (e: IOException) {
                if (isActive) {
                    Log.e(TAG, "Read error", e)
                    handleClientDisconnect("Read error: ${e.message}")
                }
            }
        }
    }

    private fun startWriteLoop() {
        writeJob?.cancel()
        writeJob = scope.launch {
            val output = outputStream ?: return@launch
            try {
                for (data in sendQueue) {
                    if (!isActive) break
                    output.write(data)
                    output.flush()
                }
            } catch (e: IOException) {
                if (isActive) {
                    Log.e(TAG, "Write error", e)
                    handleClientDisconnect("Write error: ${e.message}")
                }
            }
        }
    }

    private fun handleClientDisconnect(reason: String) {
        Log.d(TAG, "Client disconnected: $reason")
        disconnectClient()
        if (serverSocket != null && !serverSocket!!.isClosed) {
            _connectionState.value = ConnectionState.LISTENING
            _errorMessage.value = reason
        }
    }

    private fun disconnectClient() {
        readJob?.cancel()
        writeJob?.cancel()
        readJob = null
        writeJob = null

        try { inputStream?.close() } catch (_: Exception) {}
        try { outputStream?.close() } catch (_: Exception) {}
        try { clientSocket?.close() } catch (_: Exception) {}

        inputStream = null
        outputStream = null
        clientSocket = null
    }

    fun disconnect() {
        disconnectClient()
        _connectionState.value = ConnectionState.LISTENING
        _errorMessage.value = null
    }

    fun stopListening() {
        disconnectClient()
        acceptJob?.cancel()
        acceptJob = null

        try { serverSocket?.close() } catch (_: Exception) {}
        serverSocket = null
        listeningPort = 0

        _connectionState.value = ConnectionState.IDLE
        _errorMessage.value = null
    }

    fun destroy() {
        stopListening()
        scope.cancel()
    }
}
