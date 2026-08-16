package com.bettercast.receiver.network

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket

/**
 * Dials a discovered Mac sender and asks it to start streaming to this device.
 *
 * The invite is one-shot and carries no video. The phone connects to the sender's
 * `_bettercast-sender._tcp` service, sends a single hello naming itself, and hangs up;
 * the Mac then looks that name up in its own browse list and dials back to the
 * receiver's `_bettercast._tcp` listener, which is what actually carries the stream.
 *
 * That indirection is the Mac's design, not ours — it is how the sender ends up with a
 * properly named connection (and, between Apple devices, an AWDL route). The practical
 * consequence here is that [invite] succeeding only means the Mac was told; the stream
 * still arrives through [TcpClient]'s accept loop as usual.
 */
class SenderInviter {

    companion object {
        private const val TAG = "SenderInviter"
        private const val CONNECT_TIMEOUT_MS = 5_000
        private const val OVERALL_TIMEOUT_MS = 8_000L

        /** Matches `InputEventType.command` on the Mac. */
        private const val TYPE_COMMAND = 99

        /** Device-hello command the sender listens for on the invite connection. */
        private const val COMMAND_DEVICE_HELLO = 770
    }

    /**
     * Wire shape of the hello.
     *
     * Deliberately its own type rather than a `deviceName` field bolted onto
     * [com.bettercast.receiver.input.InputEvent]: that class is serialised for every
     * touch event, and a nullable field there would put `"deviceName":null` on the wire
     * thousands of times a session. The Mac decodes `deviceName` as an optional, so
     * leaving it off the other events is fine.
     */
    @Serializable
    private data class DeviceHello(
        val type: Int = TYPE_COMMAND,
        val x: Double = 0.0,
        val y: Double = 0.0,
        val keyCode: Int = COMMAND_DEVICE_HELLO,
        val deltaX: Double = 0.0,
        val deltaY: Double = 0.0,
        val eventId: Long = 1,
        val deviceName: String
    )

    private val json = Json { encodeDefaults = true }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /**
     * Invite [sender] to stream to this device, reporting the outcome on a background
     * thread. [onResult] receives null on success or a human-readable failure.
     */
    fun invite(sender: DiscoveredSender, deviceName: String, onResult: (String?) -> Unit) {
        scope.launch {
            val failure = withTimeoutOrNull(OVERALL_TIMEOUT_MS) {
                try {
                    Socket().use { socket ->
                        socket.tcpNoDelay = true
                        socket.connect(InetSocketAddress(sender.host, sender.port), CONNECT_TIMEOUT_MS)

                        val payload = json.encodeToString(
                            DeviceHello.serializer(),
                            DeviceHello(deviceName = deviceName)
                        ).toByteArray(Charsets.UTF_8)

                        DataOutputStream(socket.getOutputStream()).apply {
                            writeInt(payload.size)   // 4-byte big-endian length prefix
                            write(payload)
                            flush()
                        }
                        Log.i(TAG, "Invited ${sender.name} at ${sender.host}:${sender.port} as '$deviceName'")
                    }
                    null
                } catch (e: Exception) {
                    Log.e(TAG, "Invite to ${sender.name} failed", e)
                    "Could not reach ${sender.name}: ${e.message ?: "connection failed"}"
                }
            } ?: "Timed out inviting ${sender.name}"

            onResult(failure)
        }
    }
}
