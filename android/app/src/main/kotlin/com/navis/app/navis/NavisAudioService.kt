package com.navis.app.navis

import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.media.MediaBrowserServiceCompat
import com.ryanheise.audioservice.AudioService

class NavisAudioService : AudioService() {
    override fun onGetRoot(
        clientPackageName: String,
        clientUid: Int,
        rootHints: Bundle?,
    ): MediaBrowserServiceCompat.BrowserRoot? {
        val packagesForUid = packageManager.getPackagesForUid(clientUid)
        val isSystemApp = isSystemApp(clientPackageName)
        val allowed = NavisMediaBrowserCallerValidator.isAllowed(
            clientPackageName = clientPackageName,
            clientUid = clientUid,
            appPackageName = packageName,
            appUid = applicationInfo.uid,
            packagesForUid = packagesForUid,
            isSystemApp = isSystemApp,
            allowAnyVerifiedCaller = BuildConfig.DEBUG,
        )
        if (!allowed) {
            Log.w(TAG, "Rejected media browser caller package=$clientPackageName uid=$clientUid")
            return null
        }
        return super.onGetRoot(clientPackageName, clientUid, rootHints)
    }

    private fun isSystemApp(packageName: String): Boolean {
        val applicationInfo = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getApplicationInfo(
                    packageName,
                    PackageManager.ApplicationInfoFlags.of(0),
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.getApplicationInfo(packageName, 0)
            }
        } catch (_: PackageManager.NameNotFoundException) {
            return false
        }
        val systemFlags =
            ApplicationInfo.FLAG_SYSTEM or ApplicationInfo.FLAG_UPDATED_SYSTEM_APP
        return applicationInfo.flags and systemFlags != 0
    }

    private companion object {
        const val TAG = "NavisAudioService"
    }
}

internal object NavisMediaBrowserCallerValidator {
    private val trustedProjectionPackages = setOf(
        "com.google.android.projection.gearhead",
        "com.google.android.apps.auto",
        "com.google.android.gms",
        "com.google.android.googlequicksearchbox",
        "com.google.android.apps.googleassistant",
    )

    fun isAllowed(
        clientPackageName: String,
        clientUid: Int,
        appPackageName: String,
        appUid: Int,
        packagesForUid: Array<String>?,
        isSystemApp: Boolean,
        allowAnyVerifiedCaller: Boolean,
    ): Boolean {
        if (clientPackageName.isBlank() ||
            packagesForUid?.contains(clientPackageName) != true
        ) {
            return false
        }
        if (allowAnyVerifiedCaller ||
            clientUid == appUid ||
            clientPackageName == appPackageName ||
            isSystemApp
        ) {
            return true
        }
        return clientPackageName in trustedProjectionPackages
    }
}
