package com.navis.app.navis

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NavisMediaBrowserCallerValidatorTest {
    @Test
    fun rejectsPackageThatDoesNotBelongToUid() {
        assertFalse(
            isAllowed(
                clientPackageName = "com.google.android.projection.gearhead",
                packagesForUid = arrayOf("example.spoof"),
            ),
        )
    }

    @Test
    fun allowsAndroidAutoAfterUidVerification() {
        assertTrue(
            isAllowed(
                clientPackageName = "com.google.android.projection.gearhead",
                packagesForUid = arrayOf("com.google.android.projection.gearhead"),
            ),
        )
    }

    @Test
    fun allowsSystemMediaClients() {
        assertTrue(
            isAllowed(
                clientPackageName = "com.vendor.car.media",
                packagesForUid = arrayOf("com.vendor.car.media"),
                isSystemApp = true,
            ),
        )
    }

    @Test
    fun allowsOwnApplication() {
        assertTrue(
            isAllowed(
                clientPackageName = "com.navis.app.navis",
                clientUid = 12000,
                appUid = 12000,
                packagesForUid = arrayOf("com.navis.app.navis"),
            ),
        )
    }

    @Test
    fun debugBuildAllowsVerifiedMediaControllerTestClients() {
        assertTrue(
            isAllowed(
                clientPackageName = "com.example.media.controller",
                packagesForUid = arrayOf("com.example.media.controller"),
                allowAnyVerifiedCaller = true,
            ),
        )
    }

    @Test
    fun releaseBuildRejectsUntrustedThirdPartyClient() {
        assertFalse(
            isAllowed(
                clientPackageName = "com.example.untrusted",
                packagesForUid = arrayOf("com.example.untrusted"),
            ),
        )
    }

    private fun isAllowed(
        clientPackageName: String,
        clientUid: Int = 13000,
        appPackageName: String = "com.navis.app.navis",
        appUid: Int = 12000,
        packagesForUid: Array<String>?,
        isSystemApp: Boolean = false,
        allowAnyVerifiedCaller: Boolean = false,
    ): Boolean {
        return NavisMediaBrowserCallerValidator.isAllowed(
            clientPackageName = clientPackageName,
            clientUid = clientUid,
            appPackageName = appPackageName,
            appUid = appUid,
            packagesForUid = packagesForUid,
            isSystemApp = isSystemApp,
            allowAnyVerifiedCaller = allowAnyVerifiedCaller,
        )
    }
}
