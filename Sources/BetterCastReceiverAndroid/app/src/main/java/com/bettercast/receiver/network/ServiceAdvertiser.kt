package com.bettercast.receiver.network

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

class ServiceAdvertiser(context: Context) {

    companion object {
        private const val TAG = "ServiceAdvertiser"
        private const val TCP_SERVICE_TYPE = "_bettercast._tcp."
        private const val UDP_SERVICE_TYPE = "_bettercast._udp."
        private const val TCP_SERVICE_NAME = "BetterCast Receiver Android"
        private const val UDP_SERVICE_NAME = "BetterCast Receiver UDP Android"
    }

    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager

    private val _isAdvertising = MutableStateFlow(false)
    val isAdvertising: StateFlow<Boolean> = _isAdvertising.asStateFlow()

    private val _statusMessage = MutableStateFlow("Idle")
    val statusMessage: StateFlow<String> = _statusMessage.asStateFlow()

    private var tcpRegistrationListener: NsdManager.RegistrationListener? = null
    private var udpRegistrationListener: NsdManager.RegistrationListener? = null

    fun startAdvertising(port: Int) {
        if (_isAdvertising.value) return

        // Register TCP service
        registerService(
            serviceName = TCP_SERVICE_NAME,
            serviceType = TCP_SERVICE_TYPE,
            port = port,
            onListener = { tcpRegistrationListener = it },
            label = "TCP"
        )

        // Register UDP service on the same port
        registerService(
            serviceName = UDP_SERVICE_NAME,
            serviceType = UDP_SERVICE_TYPE,
            port = port,
            onListener = { udpRegistrationListener = it },
            label = "UDP"
        )
    }

    private fun registerService(
        serviceName: String,
        serviceType: String,
        port: Int,
        onListener: (NsdManager.RegistrationListener) -> Unit,
        label: String
    ) {
        val serviceInfo = NsdServiceInfo().apply {
            this.serviceName = serviceName
            this.serviceType = serviceType
            setPort(port)
        }

        val listener = object : NsdManager.RegistrationListener {
            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "$label registration failed: $errorCode")
            }

            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "$label unregistration failed: $errorCode")
            }

            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                Log.d(TAG, "$label service registered: ${serviceInfo.serviceName} on port $port")
                _isAdvertising.value = true
                _statusMessage.value = "Advertising as ${serviceInfo.serviceName}"
            }

            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {
                Log.d(TAG, "$label service unregistered")
            }
        }

        onListener(listener)

        try {
            nsdManager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to register $label service", e)
        }
    }

    fun stopAdvertising() {
        tcpRegistrationListener?.let {
            try { nsdManager.unregisterService(it) } catch (e: Exception) {
                Log.e(TAG, "Failed to unregister TCP", e)
            }
        }
        udpRegistrationListener?.let {
            try { nsdManager.unregisterService(it) } catch (e: Exception) {
                Log.e(TAG, "Failed to unregister UDP", e)
            }
        }

        tcpRegistrationListener = null
        udpRegistrationListener = null
        _isAdvertising.value = false
        _statusMessage.value = "Stopped"
    }
}
