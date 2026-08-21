package com.navis.app.navis

import androidx.work.NetworkType
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.Assert.assertThrows

class AndroidBackgroundSyncSchedulerTest {
    @Test
    fun `periodic spec uses opaque versioned names and unmetered constraint`() {
        val spec = BackgroundSyncScheduleSpec(
            profileKey = "a".repeat(32),
            intervalMinutes = 60,
            unmeteredOnly = true,
        )

        assertEquals("navis.library.automatic.${"a".repeat(32)}.v1", spec.periodicWorkName)
        assertEquals("navis.library.catchup.${"a".repeat(32)}.v1", spec.catchupWorkName)
        assertEquals(NetworkType.UNMETERED, spec.networkType)
    }

    @Test
    fun `metered permission maps to connected without exposing profile identity`() {
        val spec = BackgroundSyncScheduleSpec(
            profileKey = "b".repeat(32),
            intervalMinutes = 15,
            unmeteredOnly = false,
        )

        assertEquals(NetworkType.CONNECTED, spec.networkType)
        assertEquals("navis.library.automatic.${"b".repeat(32)}.v1", spec.periodicWorkName)
    }

    @Test
    fun `spec rejects invalid workmanager cadence and nonopaque keys`() {
        assertThrows(IllegalArgumentException::class.java) {
            BackgroundSyncScheduleSpec("not-a-profile", 60, true)
        }
        assertThrows(IllegalArgumentException::class.java) {
            BackgroundSyncScheduleSpec("c".repeat(32), 10, true)
        }
    }

    @Test
    fun `only bootstrap failures ask WorkManager to retry`() {
        assertEquals(
            BackgroundSyncWorkerDirective.RETRY,
            BackgroundSyncWorkerResultMapper.directiveFor("transientFailure"),
        )
        assertEquals(
            BackgroundSyncWorkerDirective.FAILURE,
            BackgroundSyncWorkerResultMapper.directiveFor("permanentFailure"),
        )
        assertEquals(
            BackgroundSyncWorkerDirective.SUCCESS,
            BackgroundSyncWorkerResultMapper.directiveFor("leaseHeld"),
        )
        assertEquals(
            BackgroundSyncWorkerDirective.SUCCESS,
            BackgroundSyncWorkerResultMapper.directiveFor(null),
        )
    }

    @Test
    fun `native fallback categories stay bounded and distinct`() {
        assertEquals(
            BackgroundSyncNativeOutcome("engineTimeout", "engineTimeout"),
            BackgroundSyncNativeFailure.TIMEOUT.outcome,
        )
        assertEquals(
            BackgroundSyncNativeOutcome("stoppedBySystem", "stoppedBySystem"),
            BackgroundSyncNativeFailure.CANCELLED.outcome,
        )
        assertEquals(
            BackgroundSyncNativeOutcome("transientFailure", "bootstrapFailure"),
            BackgroundSyncNativeFailure.BOOTSTRAP_FAILURE.outcome,
        )
        assertEquals(
            BackgroundSyncNativeOutcome(
                "bootstrapRetryExhausted",
                "retryCapReached",
            ),
            BackgroundSyncNativeFailure.RETRY_EXHAUSTED.outcome,
        )
    }

}
