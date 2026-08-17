package com.bettercast.receiver.network

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

data class DiscoveredSender(
    val name: String,
    val host: String,
    val port: Int
)

/**
 * Browses for BetterCast senders and resolves them to an address the phone can dial.
 *
 * Two things about `NsdManager` shape this class, and both of them used to break it:
 *
 * 1. **Start and stop are asynchronous.** `discoverServices` does not begin discovery,
 *    it *requests* it; `onDiscoveryStarted` arrives later. Likewise `stopServiceDiscovery`
 *    only completes at `onDiscoveryStopped`. Treating either as immediate means the next
 *    `discoverServices` lands while the framework still considers the previous one live,
 *    and it comes back `FAILURE_ALREADY_ACTIVE` — permanently, with no retry. That is how
 *    the sender list went empty and stayed empty for the rest of the process.
 *
 * 2. **Only one resolve may be in flight.** A second concurrent `resolveService` fails
 *    with the same error code, so resolves are queued and run strictly one at a time.
 *
 * Both are handled here by tracking the framework's real state separately from what we
 * *want* it to be, and reconciling the two whenever a callback tells us the truth.
 */
class ServiceDiscovery(context: Context) {

    companion object {
        private const val TAG = "ServiceDiscovery"

        /**
         * The Mac sender's *invite* service.
         *
         * This used to browse `_bettercast._tcp.`, which is what receivers advertise —
         * so the phone was looking for other receivers, found itself, and never saw a
         * Mac. Senders advertise `_bettercast-sender._tcp`, matching the type the iOS
         * receiver browses in NetworkListenerIOS.
         */
        private const val SERVICE_TYPE = "_bettercast-sender._tcp."

        /** `NsdManager.FAILURE_ALREADY_ACTIVE` — not public on every API level. */
        private const val FAILURE_ALREADY_ACTIVE = 3

        /** Backoff before retrying a start or resolve the framework rejected as busy. */
        private const val RETRY_DELAY_MS = 700L
    }

    private val appContext = context.applicationContext
    private val nsdManager = appContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifiManager =
        appContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager

    private val handler = Handler(Looper.getMainLooper())

    private val _discoveredSenders = MutableStateFlow<List<DiscoveredSender>>(emptyList())
    val discoveredSenders: StateFlow<List<DiscoveredSender>> = _discoveredSenders.asStateFlow()

    private val _isDiscovering = MutableStateFlow(false)
    val isDiscovering: StateFlow<Boolean> = _isDiscovering.asStateFlow()

    /** What the caller wants. The framework catches up to this asynchronously. */
    private var wantRunning = false

    /** The listener currently known to the framework, live or still shutting down. */
    private var activeListener: NsdManager.DiscoveryListener? = null

    /** True between `discoverServices` and its start/fail callback. */
    private var startPending = false

    /** True between `stopServiceDiscovery` and its stop/fail callback. */
    private var stopPending = false

    private val resolveQueue = ArrayDeque<NsdServiceInfo>()
    private var resolveInFlight = false

    /**
     * Held while browsing.
     *
     * `NsdManager` runs in the system server and takes its own lock, but several OEM
     * Wi-Fi stacks still drop multicast to the app processor without one held by a
     * foreground app. It is cheap insurance and the permission is already declared.
     */
    private val multicastLock = try {
        wifiManager?.createMulticastLock("bettercast-nsd")?.apply { setReferenceCounted(false) }
    } catch (e: Exception) {
        Log.w(TAG, "Multicast lock unavailable", e)
        null
    }

    @Synchronized
    fun startDiscovery() {
        wantRunning = true
        pump()
    }

    @Synchronized
    fun stopDiscovery() {
        wantRunning = false
        pump()
    }

    /**
     * Drive the framework toward [wantRunning].
     *
     * Called from every callback as well as from the public entry points, so a state
     * that could not be reached earlier (because a start or stop was still settling) is
     * retried as soon as the framework reports back.
     */
    @Synchronized
    private fun pump() {
        if (startPending || stopPending) return  // a callback will call us again

        if (wantRunning && activeListener == null) {
            beginDiscovery()
        } else if (!wantRunning && activeListener != null) {
            endDiscovery()
        }
    }

    private fun beginDiscovery() {
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                Log.d(TAG, "Discovery started for $serviceType")
                synchronized(this@ServiceDiscovery) {
                    startPending = false
                    _isDiscovering.value = true
                    pump()  // a stop may have been requested while we were starting
                }
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "Start discovery failed: $errorCode")
                synchronized(this@ServiceDiscovery) {
                    startPending = false
                    _isDiscovering.value = false
                    // The framework never took ownership, so this listener is dead.
                    if (activeListener === this) activeListener = null

                    if (wantRunning) {
                        // ALREADY_ACTIVE means a previous discovery is still winding
                        // down. Backing off and trying again is the only recovery —
                        // giving up here is what used to kill the list permanently.
                        handler.postDelayed({ pump() }, RETRY_DELAY_MS)
                    }
                }
            }

            override fun onDiscoveryStopped(serviceType: String) {
                Log.d(TAG, "Discovery stopped")
                synchronized(this@ServiceDiscovery) {
                    stopPending = false
                    if (activeListener === this) activeListener = null
                    _isDiscovering.value = false
                    pump()  // honour a restart requested mid-stop
                }
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "Stop discovery failed: $errorCode")
                synchronized(this@ServiceDiscovery) {
                    stopPending = false
                    // Assume the framework has let go; if it has not, the next start
                    // fails with ALREADY_ACTIVE and retries on the backoff above.
                    if (activeListener === this) activeListener = null
                    _isDiscovering.value = false
                    pump()
                }
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                Log.d(TAG, "Service found: ${serviceInfo.serviceName}")
                enqueueResolve(serviceInfo)
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                Log.d(TAG, "Service lost: ${serviceInfo.serviceName}")
                val name = serviceInfo.serviceName
                _discoveredSenders.value = _discoveredSenders.value.filter { it.name != name }
            }
        }

        activeListener = listener
        startPending = true
        acquireMulticastLock()

        try {
            nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start discovery", e)
            startPending = false
            activeListener = null
            _isDiscovering.value = false
            if (wantRunning) handler.postDelayed({ pump() }, RETRY_DELAY_MS)
        }
    }

    private fun endDiscovery() {
        val listener = activeListener ?: return
        stopPending = true
        releaseMulticastLock()
        _discoveredSenders.value = emptyList()
        synchronized(resolveQueue) { resolveQueue.clear() }

        try {
            nsdManager.stopServiceDiscovery(listener)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to stop discovery", e)
            stopPending = false
            activeListener = null
            _isDiscovering.value = false
        }
    }

    // ---- resolve serialisation -------------------------------------------------

    private fun enqueueResolve(serviceInfo: NsdServiceInfo) {
        synchronized(resolveQueue) {
            // Drop duplicates already waiting; a refound service replaces its entry.
            resolveQueue.removeAll { it.serviceName == serviceInfo.serviceName }
            resolveQueue.addLast(serviceInfo)
        }
        drainResolveQueue()
    }

    private fun drainResolveQueue() {
        val next: NsdServiceInfo
        synchronized(resolveQueue) {
            if (resolveInFlight) return
            next = resolveQueue.removeFirstOrNull() ?: return
            resolveInFlight = true
        }
        resolveOne(next)
    }

    private fun finishResolve() {
        synchronized(resolveQueue) { resolveInFlight = false }
        drainResolveQueue()
    }

    @Suppress("DEPRECATION") // registerServiceInfoCallback is API 34+; this works everywhere
    private fun resolveOne(serviceInfo: NsdServiceInfo, attempt: Int = 1) {
        val listener = object : NsdManager.ResolveListener {
            override fun onResolveFailed(failed: NsdServiceInfo, errorCode: Int) {
                if (errorCode == FAILURE_ALREADY_ACTIVE && attempt < 4) {
                    // Another resolve is still settling inside the framework. Ours never
                    // started, so retry it rather than losing the sender entirely.
                    Log.d(TAG, "Resolve busy for ${failed.serviceName}, retry $attempt")
                    handler.postDelayed({ resolveOne(serviceInfo, attempt + 1) }, RETRY_DELAY_MS)
                    return
                }
                Log.e(TAG, "Resolve failed for ${failed.serviceName}: $errorCode")
                finishResolve()
            }

            override fun onServiceResolved(resolvedInfo: NsdServiceInfo) {
                val host = resolvedInfo.host?.hostAddress
                val port = resolvedInfo.port
                val name = resolvedInfo.serviceName
                if (host.isNullOrEmpty() || port <= 0) {
                    Log.w(TAG, "Resolved $name with no usable address")
                    finishResolve()
                    return
                }
                Log.d(TAG, "Resolved: $name -> $host:$port")

                val sender = DiscoveredSender(name = name, host = host, port = port)
                val current = _discoveredSenders.value.toMutableList()
                current.removeAll { it.name == name }
                current.add(sender)
                _discoveredSenders.value = current
                finishResolve()
            }
        }

        try {
            nsdManager.resolveService(serviceInfo, listener)
        } catch (e: Exception) {
            Log.e(TAG, "resolveService threw for ${serviceInfo.serviceName}", e)
            finishResolve()
        }
    }

    // ---- multicast lock --------------------------------------------------------

    private fun acquireMulticastLock() {
        try {
            multicastLock?.takeIf { !it.isHeld }?.acquire()
        } catch (e: Exception) {
            Log.w(TAG, "Could not acquire multicast lock", e)
        }
    }

    private fun releaseMulticastLock() {
        try {
            multicastLock?.takeIf { it.isHeld }?.release()
        } catch (e: Exception) {
            Log.w(TAG, "Could not release multicast lock", e)
        }
    }
}
