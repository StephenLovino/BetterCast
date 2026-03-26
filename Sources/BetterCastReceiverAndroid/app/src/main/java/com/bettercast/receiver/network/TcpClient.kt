package com.bettercast.receiver.network

import android.util.Log
import com.bettercast.receiver.input.InputEvent
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer

enum class ConnectionState {
    IDLE,
    LISTENING,
    CONNECTED,
    ERROR
}

class TcpClient {

    companion object {
        private const val TAG = "TcpServer"
        private const val HEARTBEAT_INTERVAL_MS = 500L
        const val DEFAULT_PORT = 51820
    }

    private val _connectionState = MutableStateFlow(ConnectionState.IDLE)
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    private val _connectedSenderName = MutableStateFlow<String?>(null)
    val connectedSenderName: StateFlow<String?> = _connectedSenderName.asStateFlow()

    private var serverSocket: ServerSocket? = null
    private var clientSocket: Socket? = null
    private var outputStream: DataOutputStream? = null
    private var inputStream: DataInputStream? = null

    private val sendQueue = Channel<ByteArray>(Channel.BUFFERED)

    private var acceptJob: Job? = null
    private var readJob: Job? = null
    private var writeJob: Job? = null
    private var heartbeatJob: Job? = null

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    var onFrameReceived: ((ByteArray) -> Unit)? = null

    /** The port the server is listening on (0 = not yet bound) */
    var listeningPort: Int = 0
        private set

    /**
     * Start listening for incoming connections.
     * Returns the port number to advertise via NSD.
     */
    fun startListening(): Int {
        if (_connectionState.value == ConnectionState.LISTENING ||
            _connectionState.value == ConnectionState.CONNECTED) {
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
                    Log.d(TAG, "Waiting for sender connection...")
                    val socket = server.accept()
                    socket.tcpNoDelay = true
                    socket.keepAlive = true
                    socket.receiveBufferSize = 524288  // 512KB — handles ADB tunnel jitter bursts
                    socket.sendBufferSize = 65536      // 64KB for input events

                    // Disconnect previous client if any
                    disconnectClient()

                    clientSocket = socket
                    outputStream = DataOutputStream(socket.getOutputStream())
                    inputStream = DataInputStream(socket.getInputStream())

                    val senderAddress = socket.remoteSocketAddress.toString()
                    Log.d(TAG, "Sender connected from $senderAddress")
                    _connectedSenderName.value = senderAddress
                    _connectionState.value = ConnectionState.CONNECTED

                    startReadLoop()
                    startWriteLoop()
                    startHeartbeat()
                }
            } catch (e: IOException) {
                if (isActive) {
                    Log.e(TAG, "Accept error", e)
                }
            }
        }
    }

    /**
     * Check if a frame contains a keyframe (IDR NALU type 5) or SPS (type 7).
     * Frame format: [8 bytes PTS][4-byte NALU length][NALU data]...
     */
    private fun isKeyframe(frameData: ByteArray): Boolean {
        if (frameData.size < 13) return false // 8 PTS + 4 length + 1 NALU min
        var offset = 8 // skip PTS
        while (offset + 4 < frameData.size) {
            val naluLen = ((frameData[offset].toInt() and 0xFF) shl 24) or
                    ((frameData[offset + 1].toInt() and 0xFF) shl 16) or
                    ((frameData[offset + 2].toInt() and 0xFF) shl 8) or
                    (frameData[offset + 3].toInt() and 0xFF)
            offset += 4
            if (naluLen <= 0 || offset + naluLen > frameData.size) break
            val naluType = frameData[offset].toInt() and 0x1F
            if (naluType == 5 || naluType == 7) return true // IDR or SPS
            offset += naluLen
        }
        return false
    }

    var onAudioReceived: ((ByteArray) -> Unit)? = null

    private fun startReadLoop() {
        readJob?.cancel()
        readJob = scope.launch {
            val input = inputStream ?: run {
                Log.e(TAG, "Read loop: inputStream is null!")
                return@launch
            }
            Log.i(TAG, "Read loop started, onFrameReceived=${onFrameReceived != null}")
            var frameCount = 0L
            var audioCount = 0L
            try {
                while (isActive) {
                    val length = input.readInt()
                    if (length <= 0 || length > 10_000_000) {
                        Log.w(TAG, "Invalid frame length: $length")
                        continue
                    }

                    val buffer = ByteArray(length)
                    input.readFully(buffer)

                    // Check for type byte prefix (added with audio streaming)
                    // 0x01 = video, 0x02 = audio
                    if (buffer.isNotEmpty()) {
                        val typeByte = buffer[0].toInt() and 0xFF
                        if (typeByte == 0x01 && buffer.size > 1) {
                            // Video packet — strip type byte
                            val videoData = buffer.copyOfRange(1, buffer.size)
                            frameCount++
                            if (frameCount <= 5 || frameCount % 300 == 0L) {
                                val keyframe = isKeyframe(videoData)
                                Log.i(TAG, "Deliver frame #$frameCount: ${videoData.size} bytes${if (keyframe) " [KEYFRAME]" else ""}")
                            }
                            onFrameReceived?.invoke(videoData)
                            continue
                        } else if (typeByte == 0x02 && buffer.size > 1) {
                            // Audio packet — strip type byte
                            val audioData = buffer.copyOfRange(1, buffer.size)
                            audioCount++
                            if (audioCount <= 3 || audioCount % 200 == 0L) {
                                Log.i(TAG, "Audio packet #$audioCount: ${audioData.size} bytes")
                            }
                            onAudioReceived?.invoke(audioData)
                            continue
                        }
                    }

                    // Legacy: no type byte, treat as video (backward compat)
                    frameCount++
                    if (frameCount <= 5 || frameCount % 300 == 0L) {
                        val keyframe = isKeyframe(buffer)
                        Log.i(TAG, "Deliver frame #$frameCount: ${buffer.size} bytes${if (keyframe) " [KEYFRAME]" else ""}")
                    }
                    onFrameReceived?.invoke(buffer)
                }
            } catch (e: IOException) {
                if (isActive) {
                    Log.e(TAG, "Read error after $frameCount frames", e)
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

    private fun startHeartbeat() {
        heartbeatJob?.cancel()
        heartbeatJob = scope.launch {
            while (isActive && _connectionState.value == ConnectionState.CONNECTED) {
                delay(HEARTBEAT_INTERVAL_MS)
                sendInputEvent(InputEvent.heartbeat())
            }
        }
    }

    fun sendInputEvent(event: InputEvent) {
        val repeatCount = if (InputEvent.isCritical(event.type)) 3 else 1
        val json = Json.encodeToString(event)
        val jsonBytes = json.toByteArray(Charsets.UTF_8)

        val packet = ByteBuffer.allocate(4 + jsonBytes.size)
        packet.putInt(jsonBytes.size)
        packet.put(jsonBytes)
        val packetBytes = packet.array()

        scope.launch {
            repeat(repeatCount) {
                sendQueue.trySend(packetBytes)
            }
        }
    }

    private fun handleClientDisconnect(reason: String) {
        Log.d(TAG, "Client disconnected: $reason")
        disconnectClient()
        // Go back to listening state (server socket still open)
        if (serverSocket != null && !serverSocket!!.isClosed) {
            _connectionState.value = ConnectionState.LISTENING
            _errorMessage.value = reason
        }
    }

    private fun disconnectClient() {
        heartbeatJob?.cancel()
        readJob?.cancel()
        writeJob?.cancel()
        heartbeatJob = null
        readJob = null
        writeJob = null

        _connectedSenderName.value = null

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
