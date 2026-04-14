package com.bettercast.receiver.network

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

data class DiscoveredSender(
    val name: String,
    val host: String,
    val port: Int
)

class ServiceDiscovery(context: Context) {

    companion object {
        private const val TAG = "ServiceDiscovery"
        private const val SERVICE_TYPE = "_bettercast._tcp."
    }

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager

    private val _discoveredSenders = MutableStateFlow<List<DiscoveredSender>>(emptyList())
    val discoveredSenders: StateFlow<List<DiscoveredSender>> = _discoveredSenders.asStateFlow()

    private val _isDiscovering = MutableStateFlow(false)
    val isDiscovering: StateFlow<Boolean> = _isDiscovering.asStateFlow()

    private val pendingResolves = mutableSetOf<String>()
    private val foundServices = mutableListOf<NsdServiceInfo>()

    private var discoveryListener: NsdManager.DiscoveryListener? = null

    fun startDiscovery() {
        if (_isDiscovering.value) return

        _discoveredSenders.value = emptyList()
        foundServices.clear()
        pendingResolves.clear()

        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                Log.d(TAG, "Discovery started for $serviceType")
                _isDiscovering.value = true
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                Log.d(TAG, "Service found: ${serviceInfo.serviceName}")
                val name = serviceInfo.serviceName
                if (name !in pendingResolves) {
                    pendingResolves.add(name)
                    resolveService(serviceInfo)
                }
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                Log.d(TAG, "Service lost: ${serviceInfo.serviceName}")
                val name = serviceInfo.serviceName
                pendingResolves.remove(name)
                _discoveredSenders.value = _discoveredSenders.value.filter { it.name != name }
            }

            override fun onDiscoveryStopped(serviceType: String) {
                Log.d(TAG, "Discovery stopped")
                _isDiscovering.value = false
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "Start discovery failed: $errorCode")
                _isDiscovering.value = false
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.e(TAG, "Stop discovery failed: $errorCode")
            }
        }

        discoveryListener = listener

        try {
            nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start discovery", e)
            _isDiscovering.value = false
        }
    }

    private fun resolveService(serviceInfo: NsdServiceInfo) {
        nsdManager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "Resolve failed for ${serviceInfo.serviceName}: $errorCode")
                pendingResolves.remove(serviceInfo.serviceName)
            }

            override fun onServiceResolved(resolvedInfo: NsdServiceInfo) {
                val host = resolvedInfo.host?.hostAddress ?: return
                val port = resolvedInfo.port
                val name = resolvedInfo.serviceName
                Log.d(TAG, "Resolved: $name -> $host:$port")

                val sender = DiscoveredSender(name = name, host = host, port = port)
                val current = _discoveredSenders.value.toMutableList()
                current.removeAll { it.name == name }
                current.add(sender)
                _discoveredSenders.value = current
            }
        })
    }

    fun stopDiscovery() {
        val listener = discoveryListener ?: return
        discoveryListener = null

        try {
            nsdManager.stopServiceDiscovery(listener)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to stop discovery", e)
        }

        _isDiscovering.value = false
    }
}
