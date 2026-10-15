package dev.aihaptics.haptics_lab

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/** Observes the default route; never binds traffic or modifies the user's VPN. */
class NetworkLifecycle(context: Context, private val channel: MethodChannel) {
    private val manager = context.getSystemService(ConnectivityManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private var watching = false
    private var disposed = false
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = changed()
        override fun onLost(network: Network) = changed()
    }
    private fun changed() {
        handler.post { if (!disposed) channel.invokeMethod("changed", null) }
    }
    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "watch") result.notImplemented()
            else try {
                if (!watching) {
                    manager.registerDefaultNetworkCallback(callback)
                    watching = true
                }
                result.success(null)
            } catch (_: Exception) { result.error("network_watch_failed", "Network observation unavailable", null) }
        }
    }
    fun dispose() {
        disposed = true
        if (watching) try { manager.unregisterNetworkCallback(callback) } catch (_: Exception) { }
        watching = false
        channel.setMethodCallHandler(null)
    }
}
