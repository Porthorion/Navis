package com.navis.app.navis

import android.content.Context
import android.net.ConnectivityManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** The same OS cost policy is available in foreground and headless engines. */
internal fun registerNetworkCostChannel(
    context: Context,
    messenger: BinaryMessenger,
): MethodChannel = MethodChannel(messenger, "com.navis.app/network_cost").apply {
    val connectivity = context.applicationContext
        .getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    setMethodCallHandler { call, result ->
        when (call.method) {
            "isActiveNetworkMetered" -> result.success(connectivity.isActiveNetworkMetered)
            else -> result.notImplemented()
        }
    }
}
