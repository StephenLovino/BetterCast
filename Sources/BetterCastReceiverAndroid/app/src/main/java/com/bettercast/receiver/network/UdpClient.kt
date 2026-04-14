package com.bettercast.receiver.network

import android.util.Log
import com.bettercast.receiver.input.InputEvent
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder

class UdpClient(private val port: Int) {

    companion object {
        private const val TAG = "UdpClient"
        private const val MAX_PACKET_SIZE = 65535
        private const val STALE_FRAME_TIMEOUT_MS = 500L
        private const val CLEANUP_INTERVAL = 100
        private const val HEARTBEAT_INTERVAL_MS = 5_000L
        const val DEFAULT_PORT = 51820
    }

    private data class FrameBuffer(
        val totalChunks: Int,
        val chunks: MutableMap<Int, ByteArray>,
        val timestamp: Long
    )

    private var socket: DatagramSocket? = null
    private var receiveJob: Job? = null
    private var heartbeatJob: Job? = null
    private var sendJob: Job? = null
    private var cleanupCounter = 0

    private val frameBuffers = mutableMapOf<Long, FrameBuffer>()
    private var lastDecodedFrameId: Long = 0

    // Track sender address for sending heartbeats/input back
    @Volatile private var senderAddress: InetAddress? = null
    @Volatile private var senderPort: Int = 0
    @Volatile var isSenderConnected: Boolean = false
        private set

    private val sendQueue = Channel<ByteArray>(Channel.BUFFERED)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    var onFrameReassembled: ((ByteArray) -> Unit)? = null
    var onGapDetected: (() -> Unit)? = null
    var onSenderConnected: (() -> Unit)? = null

    fun start() {
        if (receiveJob != null) return

        receiveJob = scope.launch {
            try {
                val sock = DatagramSocket(null) // create unbound
                sock.reuseAddress = true
                sock.bind(InetSocketAddress(port)) // bind after setting reuseAddress
                socket = sock
                Log.d(TAG, "UDP listening on port $port")

                val buffer = ByteArray(MAX_PACKET_SIZE)
                val packet = DatagramPacket(buffer, buffer.size)

                while (isActive) {
                    sock.receive(packet)

                    // Track sender address for bidirectional communication
                    val newAddr = packet.address
                    val newPort = packet.port
                    if (senderAddress == null || senderAddress != newAddr || senderPort != newPort) {
                        senderAddress = newAddr
                        senderPort = newPort
                        if (!isSenderConnected) {
                            isSenderConnected = true
                            Log.d(TAG, "Sender connected from $newAddr:$newPort")
                            startHeartbeat()
                            startSendLoop()
                            onSenderConnected?.invoke()
                        }
                    }

                    val data = packet.data.copyOfRange(packet.offset, packet.offset + packet.length)
                    handlePacket(data)
                }
            } catch (e: Exception) {
                if (isActive) {
                    Log.e(TAG, "UDP receive error", e)
                }
            }
        }
    }

    private fun handlePacket(data: ByteArray) {
        if (data.size <= 8) return

        val header = ByteBuffer.wrap(data, 0, 8).order(ByteOrder.BIG_ENDIAN)
        val frameId = header.int.toLong() and 0xFFFFFFFFL
        val chunkId = header.short.toInt() and 0xFFFF
        val totalChunks = header.short.toInt() and 0xFFFF

        val payload = data.copyOfRange(8, data.size)

        synchronized(frameBuffers) {
            if (lastDecodedFrameId == 0L) {
                lastDecodedFrameId = frameId - 1
            }

            val fb = frameBuffers.getOrPut(frameId) {
                FrameBuffer(
                    totalChunks = totalChunks,
                    chunks = mutableMapOf(),
                    timestamp = System.currentTimeMillis()
                )
            }

            fb.chunks[chunkId] = payload

            if (fb.chunks.size == fb.totalChunks) {
                // Gap detection
                val diff = frameId - lastDecodedFrameId
                if (diff > 1 && diff < 1000) {
                    onGapDetected?.invoke()
                }

                lastDecodedFrameId = frameId

                // Reassemble
                val sortedChunks = fb.chunks.toSortedMap()
                var totalSize = 0
                for ((_, chunk) in sortedChunks) {
                    totalSize += chunk.size
                }
                val fullFrame = ByteArray(totalSize)
                var offset = 0
                for ((_, chunk) in sortedChunks) {
                    System.arraycopy(chunk, 0, fullFrame, offset, chunk.size)
                    offset += chunk.size
                }

                frameBuffers.remove(frameId)
                onFrameReassembled?.invoke(fullFrame)

                // Periodic cleanup
                cleanupCounter++
                if (cleanupCounter % CLEANUP_INTERVAL == 0) {
                    cleanupStaleFrames()
                }
            }
        }
    }

    private fun cleanupStaleFrames() {
        val now = System.currentTimeMillis()
        val staleIds = frameBuffers.entries
            .filter { now - it.value.timestamp > STALE_FRAME_TIMEOUT_MS }
            .map { it.key }
        for (id in staleIds) {
            frameBuffers.remove(id)
        }
    }

    private fun startHeartbeat() {
        heartbeatJob?.cancel()
        heartbeatJob = scope.launch {
            while (isActive && isSenderConnected) {
                delay(HEARTBEAT_INTERVAL_MS)
                sendInputEvent(InputEvent.heartbeat())
            }
        }
    }

    private fun startSendLoop() {
        sendJob?.cancel()
        sendJob = scope.launch {
            val sock = socket ?: return@launch
            try {
                for (data in sendQueue) {
                    if (!isActive) break
                    val addr = senderAddress ?: continue
                    val p = senderPort
                    try {
                        val packet = DatagramPacket(data, data.size, addr, p)
                        sock.send(packet)
                    } catch (e: Exception) {
                        Log.e(TAG, "UDP send failed to $addr:$p: ${e.message}")
                    }
                }
            } catch (e: Exception) {
                if (isActive) {
                    Log.e(TAG, "UDP send loop error", e)
                }
            }
        }
    }

    fun sendInputEvent(event: InputEvent) {
        val repeatCount = if (InputEvent.isCritical(event.type)) 3 else 1
        val json = Json.encodeToString(event)
        val jsonBytes = json.toByteArray(Charsets.UTF_8)

        // Length-prefixed JSON (same format as TCP)
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

    fun stop() {
        isSenderConnected = false
        senderAddress = null
        senderPort = 0

        heartbeatJob?.cancel()
        sendJob?.cancel()
        receiveJob?.cancel()
        heartbeatJob = null
        sendJob = null
        receiveJob = null

        try { socket?.close() } catch (_: Exception) {}
        socket = null

        synchronized(frameBuffers) {
            frameBuffers.clear()
        }
    }

    fun destroy() {
        stop()
        scope.cancel()
    }
}
