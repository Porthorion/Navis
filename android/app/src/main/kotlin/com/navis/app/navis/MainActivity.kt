package com.navis.app.navis

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.Locale

class MainActivity : AudioServiceActivity() {

    private val updaterChannelName = "com.navis.app/updater"
    private val distributionChannelName = "com.navis.app/distribution"
    private val powerChannelName = "com.navis.app/power"
    private val deviceChannelName = "com.navis.app/device"
    private val networkCostChannelName = "com.navis.app/network_cost"
    private val backgroundSyncChannelName = "com.navis.app/background_sync"
    private val diagnosticsHandshakeChannelName = "com.navis.app/diagnostics_handshake"
    @Volatile
    private var pendingCloseAfterInstallerHandoff = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        if (BuildConfig.SELF_UPDATE_ENABLED) {
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                updaterChannelName
            ).setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val filePath = call.argument<String>("filePath")
                        if (filePath == null) {
                            result.error("INVALID_ARG", "filePath is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            installApk(filePath)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("INSTALL_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            distributionChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInstallSource" -> {
                    result.success(resolveInstallSource())
                }
                else -> result.notImplemented()
            }
        }

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

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            networkCostChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isActiveNetworkMetered" -> {
                    result.success(isActiveNetworkMetered())
                }
                else -> result.notImplemented()
            }
        }

        val backgroundScheduler = AndroidBackgroundSyncScheduler(applicationContext)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            backgroundSyncChannelName
        ).setMethodCallHandler { call, result ->
            val profileKey = call.argument<String>("profileKey")
            if (profileKey == null || !profileKey.matches(Regex("[0-9a-f]{32}"))) {
                result.error("INVALID_ARGUMENT", "Invalid opaque profile key.", null)
                return@setMethodCallHandler
            }
            try {
                when (call.method) {
                    "configurePeriodic" -> {
                        val intervalMinutes = call.argument<Int>("intervalMinutes")?.toLong()
                        val unmeteredOnly = call.argument<Boolean>("unmeteredOnly")
                        if (intervalMinutes == null || unmeteredOnly == null) {
                            result.error("INVALID_ARGUMENT", "Missing schedule parameters.", null)
                            return@setMethodCallHandler
                        }
                        val spec = BackgroundSyncScheduleSpec(
                            profileKey = profileKey,
                            intervalMinutes = intervalMinutes,
                            unmeteredOnly = unmeteredOnly,
                        )
                        result.success(backgroundScheduler.configurePeriodic(spec).toMap())
                    }
                    "enqueueCatchup" -> {
                        val unmeteredOnly = call.argument<Boolean>("unmeteredOnly")
                        if (unmeteredOnly == null) {
                            result.error("INVALID_ARGUMENT", "Missing network constraint.", null)
                            return@setMethodCallHandler
                        }
                        val spec = BackgroundSyncScheduleSpec(
                            profileKey = profileKey,
                            intervalMinutes = 15,
                            unmeteredOnly = unmeteredOnly,
                        )
                        result.success(backgroundScheduler.enqueueCatchup(spec).toMap())
                    }
                    "cancel" -> {
                        result.success(backgroundScheduler.cancel(profileKey).toMap())
                    }
                    "status" -> {
                        Thread {
                            val observation = runCatching {
                                backgroundScheduler.status(profileKey)
                            }.getOrElse {
                                BackgroundSyncScheduleObservation(state = "platformFailure")
                            }
                            runOnUiThread { result.success(observation.toMap()) }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            } catch (_: IllegalArgumentException) {
                result.error("INVALID_ARGUMENT", "Unsupported schedule parameters.", null)
            } catch (_: Exception) {
                result.error("SCHEDULER_FAILURE", "Native schedule reconciliation failed.", null)
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            diagnosticsHandshakeChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "publish" -> {
                    val port = call.argument<Int>("port")
                    val token = call.argument<String>("token")
                    val pid = call.argument<Int>("pid")
                    val mode = call.argument<String>("mode")
                    if (
                        port == null || port !in 1..65535 ||
                        token == null || !token.matches(Regex("[A-Za-z0-9_-]{43}")) ||
                        pid == null || pid < 1 ||
                        mode !in setOf("clone", "primaryCertification")
                    ) {
                        result.error("INVALID_ARGUMENT", "Invalid diagnostics handshake.", null)
                        return@setMethodCallHandler
                    }
                    try {
                        writeDiagnosticsHandshake(port, token, pid, requireNotNull(mode))
                        result.success(null)
                    } catch (_: Exception) {
                        result.error(
                            "HANDSHAKE_WRITE_FAILED",
                            "Could not publish diagnostics handshake.",
                            null,
                        )
                    }
                }
                "clear" -> {
                    try {
                        clearDiagnosticsHandshake()
                        result.success(null)
                    } catch (_: Exception) {
                        result.error(
                            "HANDSHAKE_CLEAR_FAILED",
                            "Could not clear diagnostics handshake.",
                            null,
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun diagnosticsHandshakeFile(): File {
        val externalFiles = getExternalFilesDir(null)
            ?: throw IllegalStateException("External app files directory is unavailable")
        return File(File(externalFiles, "navis-diagnostics"), "handshake.json")
    }

    private fun writeDiagnosticsHandshake(port: Int, token: String, pid: Int, mode: String) {
        val target = diagnosticsHandshakeFile()
        val directory = target.parentFile
            ?: throw IllegalStateException("Diagnostics handshake directory is unavailable")
        if (!directory.exists() && !directory.mkdirs()) {
            throw IllegalStateException("Could not create diagnostics handshake directory")
        }
        val temporary = File.createTempFile("handshake-", ".tmp", directory)
        try {
            FileOutputStream(temporary).bufferedWriter(Charsets.UTF_8).use { writer ->
                writer.write(
                    "{\"port\":$port,\"token\":\"$token\",\"pid\":$pid," +
                        "\"mode\":\"$mode\"}",
                )
                writer.flush()
            }
            if (target.exists() && !target.delete()) {
                throw IllegalStateException("Could not replace diagnostics handshake")
            }
            if (!temporary.renameTo(target)) {
                throw IllegalStateException("Could not publish diagnostics handshake")
            }
        } finally {
            if (temporary.exists()) {
                temporary.delete()
            }
        }
    }

    private fun clearDiagnosticsHandshake() {
        val target = diagnosticsHandshakeFile()
        if (target.exists() && !target.delete()) {
            throw IllegalStateException("Could not clear diagnostics handshake")
        }
    }

    private fun isActiveNetworkMetered(): Boolean {
        val connectivityManager =
            getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        return connectivityManager.isActiveNetworkMetered
    }

    private fun resolveInstallSource(): Map<String, String?> {
        val packageName = applicationContext.packageName
        val packageManager = applicationContext.packageManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val sourceInfo = packageManager.getInstallSourceInfo(packageName)
            return mapOf(
                "installerPackage" to sourceInfo.installingPackageName,
                "initiatingPackage" to sourceInfo.initiatingPackageName,
            )
        }

        @Suppress("DEPRECATION")
        val installerPackage = packageManager.getInstallerPackageName(packageName)
        return mapOf(
            "installerPackage" to installerPackage,
            "initiatingPackage" to null,
        )
    }

    private fun installApk(filePath: String) {
        val file = File(filePath)
        if (!file.exists()) {
            throw IllegalStateException("APK file not found at $filePath")
        }

        val archiveInfo = getArchivePackageInfo(filePath)
            ?: throw IllegalStateException("Invalid APK at $filePath")
        val installedInfo = getInstalledPackageInfo(applicationContext.packageName)

        val archivePackageName = archiveInfo.packageName
        if (archivePackageName != applicationContext.packageName) {
            throw IllegalStateException(
                "APK package mismatch. Expected ${applicationContext.packageName}, got $archivePackageName"
            )
        }

        val installedDigests = signingDigests(installedInfo)
        val archiveDigests = signingDigests(archiveInfo)
        if (
            installedDigests.isNotEmpty() &&
            archiveDigests.isNotEmpty() &&
            installedDigests.intersect(archiveDigests).isEmpty()
        ) {
            throw IllegalStateException(
                "APK signature mismatch with installed app. " +
                    "Uninstall the current app once, then install the new APK."
            )
        }

        val uri = FileProvider.getUriForFile(
            this,
            "${applicationContext.packageName}.fileprovider",
            file
        )

        val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
            setData(uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra(Intent.EXTRA_RETURN_RESULT, false)
        }

        val packageManager = applicationContext.packageManager
        if (intent.resolveActivity(packageManager) == null) {
            throw IllegalStateException("No package installer available to handle APK installation")
        }

        pendingCloseAfterInstallerHandoff = true
        startActivity(intent)
    }

    override fun onStop() {
        super.onStop()
        if (!pendingCloseAfterInstallerHandoff) {
            return
        }
        pendingCloseAfterInstallerHandoff = false
        closeTaskAfterInstallerHandoff()
    }

    private fun closeTaskAfterInstallerHandoff() {
        Handler(Looper.getMainLooper()).post {
            runCatching {
                moveTaskToBack(true)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    finishAndRemoveTask()
                } else {
                    finish()
                }
            }
        }
    }

    private fun getArchivePackageInfo(filePath: String): PackageInfo? {
        val flags = PackageManager.GET_SIGNING_CERTIFICATES.toLong()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageArchiveInfo(
                filePath,
                PackageManager.PackageInfoFlags.of(flags)
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageArchiveInfo(filePath, flags.toInt())
        }
    }

    private fun getInstalledPackageInfo(packageName: String): PackageInfo {
        val flags = PackageManager.GET_SIGNING_CERTIFICATES.toLong()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageInfo(
                packageName,
                PackageManager.PackageInfoFlags.of(flags)
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageInfo(packageName, flags.toInt())
        }
    }

    private fun signingDigests(packageInfo: PackageInfo): Set<String> {
        val signatures: Array<Signature> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signingInfo = packageInfo.signingInfo ?: return emptySet()
            if (signingInfo.hasMultipleSigners()) {
                signingInfo.apkContentsSigners
            } else {
                signingInfo.signingCertificateHistory
            }
        } else {
            @Suppress("DEPRECATION")
            packageInfo.signatures ?: return emptySet()
        }

        return signatures.map { signature ->
            val digest = MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
            digest.joinToString(separator = "") { byte ->
                String.format(Locale.US, "%02x", byte.toInt() and 0xff)
            }
        }.toSet()
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
