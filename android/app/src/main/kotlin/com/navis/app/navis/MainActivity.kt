package com.navis.app.navis

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class MainActivity : AudioServiceActivity() {

    private val powerChannelName = "com.navis.app/power"
    private val deviceChannelName = "com.navis.app/device"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            powerChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isIgnoringBatteryOptimizations" -> {
                    result.success(isIgnoringBatteryOptimizations())
                }
                "requestIgnoreBatteryOptimizations" -> {
                    try {
                        requestIgnoreBatteryOptimizations()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("POWER_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            deviceChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getDeviceName" -> {
                    result.success(resolveDeviceName())
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true
        }
        val powerManager = getSystemService(POWER_SERVICE) as PowerManager
        return powerManager.isIgnoringBatteryOptimizations(applicationContext.packageName)
    }

    private fun requestIgnoreBatteryOptimizations() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return
        }

        val intent = Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:${applicationContext.packageName}")
        ).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        val packageManager = applicationContext.packageManager
        if (intent.resolveActivity(packageManager) != null) {
            startActivity(intent)
            return
        }

        startActivity(
            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        )
    }

    private fun resolveDeviceName(): String {
        normalizedDeviceName(Settings.Global.getString(contentResolver, "device_name"))?.let {
            return it
        }
        normalizedDeviceName(Settings.Secure.getString(contentResolver, "bluetooth_name"))?.let {
            return it
        }

        val manufacturer = normalizedDeviceName(Build.MANUFACTURER)
        val model = normalizedDeviceName(Build.MODEL)
        if (manufacturer == null) {
            return model ?: "Android device"
        }
        if (model == null || model.startsWith(manufacturer, ignoreCase = true)) {
            return model ?: manufacturer
        }
        return "$manufacturer $model"
    }

    private fun normalizedDeviceName(value: String?): String? {
        val normalized = value
            ?.trim()
            ?.replace(Regex("\\s+"), " ")
            ?.takeIf { it.isNotEmpty() }
            ?: return null
        val lowercase = normalized.lowercase(Locale.US)
        if (
            lowercase == "localhost" ||
            lowercase == "localhost.localdomain" ||
            lowercase == "unknown"
        ) {
            return null
        }
        return normalized
    }
}
