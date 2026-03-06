package com.navis.app.navis

import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.Locale

class MainActivity : AudioServiceActivity() {

    private val updaterChannelName = "com.navis.app/updater"
    private val powerChannelName = "com.navis.app/power"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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

        startActivity(intent)

        // Ensure we don't keep a stale pre-update task/process around in
        // Recents after handing off to Package Installer.
        closeTaskAfterInstallerLaunch()
    }

    private fun closeTaskAfterInstallerLaunch() {
        Handler(Looper.getMainLooper()).postDelayed({
            runCatching {
                moveTaskToBack(true)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    finishAndRemoveTask()
                } else {
                    finish()
                }
            }

            runCatching {
                Process.killProcess(Process.myPid())
            }
        }, 250)
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
}
