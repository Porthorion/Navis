package com.navis.app.navis

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.Worker
import androidx.work.WorkerParameters
import androidx.work.WorkInfo
import androidx.work.OneTimeWorkRequest
import androidx.work.PeriodicWorkRequest
import androidx.work.NetworkType
import androidx.work.testing.SynchronousExecutor
import androidx.work.testing.WorkManagerTestInitHelper
import kotlinx.coroutines.delay
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Exercises the real WorkManager test driver without bringing up a Flutter
 * engine. Production continues to schedule [NavisBackgroundSyncWorker].
 */
@RunWith(AndroidJUnit4::class)
class AndroidBackgroundSyncSchedulerInstrumentedTest {
    private lateinit var context: Context
    private lateinit var scheduler: AndroidBackgroundSyncScheduler

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        WorkManagerTestInitHelper.initializeTestWorkManager(
            context,
            androidx.work.Configuration.Builder()
                .setExecutor(SynchronousExecutor())
                .setTaskExecutor(SynchronousExecutor())
                .build(),
        )
        scheduler = AndroidBackgroundSyncScheduler(
            context,
            workerClass = ConstraintReleaseWorker::class.java,
        )
    }

    @After
    fun tearDown() {
        BackgroundSyncFlutterSessions.testFactory = null
        runBlocking {
            scheduler.cancel("a".repeat(32))
        }
    }

    @Test
    fun catchupRunsOnlyAfterTheTestDriverReleasesConstraints() = runBlocking {
        val spec = BackgroundSyncScheduleSpec(
            profileKey = "a".repeat(32),
            intervalMinutes = 60,
            unmeteredOnly = true,
        )

        val scheduled = scheduler.configurePeriodic(spec)
        val catchup = scheduler.enqueueCatchup(spec)
        assertEquals("scheduled", scheduled.state)
        assertEquals("enqueued", catchup.state)

        val workId = requireNotNull(catchup.workId)
        val driver = WorkManagerTestInitHelper.getTestDriver(context)
        requireNotNull(driver).setAllConstraintsMet(java.util.UUID.fromString(workId))

        val info = requireNotNull(
            androidx.work.WorkManager.getInstance(context)
                .getWorkInfoById(java.util.UUID.fromString(workId))
                .get(),
        )
        assertEquals(androidx.work.WorkInfo.State.SUCCEEDED, info.state)

        // The production status path uses WorkManager's future API rather
        // than a timing-sensitive LiveData observer.
        assertNotEquals("statusUnavailable", scheduler.status(spec.profileKey).state)
    }

    @Test
    fun dispatchGateAdmitsOneWorkerPerProfileBeforeFlutterBootstraps() {
        val profileKey = "b".repeat(32)
        assertEquals(true, BackgroundSyncDispatchGate.tryAcquire(context, profileKey))
        assertEquals(false, BackgroundSyncDispatchGate.tryAcquire(context, profileKey))
        BackgroundSyncDispatchGate.release(profileKey)
        assertEquals(true, BackgroundSyncDispatchGate.tryAcquire(context, profileKey))
        BackgroundSyncDispatchGate.release(profileKey)
    }

    @Test
    fun nativeFallbackOutcomeRemainsObservableUntilItIsExplicitlyCleared() {
        val profileKey = "c".repeat(32)
        val store = BackgroundSyncOutcomeStore(context)
        store.clear(profileKey)
        store.record(profileKey, "engineTimeout", "engineTimeout")

        assertEquals("engineTimeout", store.read(profileKey)?.result)
        assertEquals("engineTimeout", store.read(profileKey)?.stopReason)

        store.clear(profileKey)
        assertEquals(null, store.read(profileKey))
    }

    @Test
    fun enqueueFailureIsReportedAsPlatformFailureRatherThanScheduled() = runBlocking {
        val profileKey = "d".repeat(32)
        val scheduler = AndroidBackgroundSyncScheduler(
            context,
            workManagerClient = FailingWorkManagerClient(),
        )

        val observation = scheduler.configurePeriodic(
            BackgroundSyncScheduleSpec(profileKey, 60, true),
        )

        assertEquals("platformFailure", observation.state)
        assertNotEquals("scheduled", observation.state)
    }

    @Test
    fun unavailableStatusRetainsTheDurableTerminalOutcome() = runBlocking {
        val profileKey = "e".repeat(32)
        val store = BackgroundSyncOutcomeStore(context)
        store.record(profileKey, "engineTimeout", "engineTimeout")
        val scheduler = AndroidBackgroundSyncScheduler(
            context,
            workManagerClient = FailingWorkManagerClient(),
            outcomeStore = store,
        )

        val observation = scheduler.status(profileKey)

        assertEquals("statusUnavailable", observation.state)
        assertEquals("engineTimeout", observation.workerResult)
        assertEquals("engineTimeout", observation.workerStopReason)
        store.clear(profileKey)
    }

    @Test
    fun periodicUpdateKeepsOneUniqueRequestAndCancellationIsAcknowledged() = runBlocking {
        val profileKey = "f".repeat(32)
        val initial = BackgroundSyncScheduleSpec(profileKey, 60, true)
        val updated = BackgroundSyncScheduleSpec(profileKey, 120, false)

        assertEquals("scheduled", scheduler.configurePeriodic(initial).state)
        assertEquals("scheduled", scheduler.configurePeriodic(updated).state)

        val workManager = androidx.work.WorkManager.getInstance(context)
        val scheduled = workManager
            .getWorkInfosForUniqueWork(updated.periodicWorkName)
            .get()
        assertEquals(1, scheduled.size)
        assertEquals(NetworkType.CONNECTED, scheduled.single().constraints.requiredNetworkType)

        assertEquals("cancelled", scheduler.cancel(profileKey).state)
        val cancelled = workManager
            .getWorkInfosForUniqueWork(updated.periodicWorkName)
            .get()
        assertEquals(androidx.work.WorkInfo.State.CANCELLED, cancelled.single().state)
    }

    @Test
    fun realWorkerPersistsTimeoutFallbackWhenItsFlutterSessionTimesOut() = runBlocking {
        val profileKey = "1".repeat(32)
        BackgroundSyncFlutterSessions.testFactory = { TimeoutFlutterSession() }
        val scheduler = AndroidBackgroundSyncScheduler(context)
        val spec = BackgroundSyncScheduleSpec(profileKey, 60, true)
        val catchup = scheduler.enqueueCatchup(spec)
        val workId = requireNotNull(catchup.workId)

        WorkManagerTestInitHelper.getTestDriver(context)
            ?.setAllConstraintsMet(java.util.UUID.fromString(workId))

        assertEquals(
            BackgroundSyncNativeFailure.TIMEOUT.outcome.result,
            awaitOutcome(profileKey)?.result,
        )
        scheduler.cancel(profileKey)
        Unit
    }

    @Test
    fun realWorkerPersistsBootstrapFallbackWhenItsFlutterSessionFails() = runBlocking {
        val profileKey = "2".repeat(32)
        BackgroundSyncFlutterSessions.testFactory = { FailingFlutterSession() }
        val scheduler = AndroidBackgroundSyncScheduler(context)
        val spec = BackgroundSyncScheduleSpec(profileKey, 60, true)
        val catchup = scheduler.enqueueCatchup(spec)
        val workId = requireNotNull(catchup.workId)

        WorkManagerTestInitHelper.getTestDriver(context)
            ?.setAllConstraintsMet(java.util.UUID.fromString(workId))

        assertEquals(
            BackgroundSyncNativeFailure.BOOTSTRAP_FAILURE.outcome.result,
            awaitOutcome(profileKey)?.result,
        )
        scheduler.cancel(profileKey)
        Unit
    }

    @Test
    fun realWorkerPersistsDartCallFallbackWhenItsSessionFailsAfterReady() = runBlocking {
        val profileKey = "3".repeat(32)
        BackgroundSyncFlutterSessions.testFactory = { DartFailureFlutterSession() }
        val scheduler = AndroidBackgroundSyncScheduler(context)
        val catchup = scheduler.enqueueCatchup(
            BackgroundSyncScheduleSpec(profileKey, 60, true),
        )

        WorkManagerTestInitHelper.getTestDriver(context)
            ?.setAllConstraintsMet(java.util.UUID.fromString(requireNotNull(catchup.workId)))

        assertEquals(
            BackgroundSyncNativeFailure.BOOTSTRAP_FAILURE.outcome.result,
            awaitOutcome(profileKey)?.result,
        )
        scheduler.cancel(profileKey)
        Unit
    }

    @Test
    fun realWorkerPersistsCancellationFallbackWhenItsSessionIsCancelled() = runBlocking {
        val profileKey = "4".repeat(32)
        BackgroundSyncFlutterSessions.testFactory = { CancelledFlutterSession() }
        val scheduler = AndroidBackgroundSyncScheduler(context)
        val catchup = scheduler.enqueueCatchup(
            BackgroundSyncScheduleSpec(profileKey, 60, true),
        )

        WorkManagerTestInitHelper.getTestDriver(context)
            ?.setAllConstraintsMet(java.util.UUID.fromString(requireNotNull(catchup.workId)))

        assertEquals(
            BackgroundSyncNativeFailure.CANCELLED.outcome.result,
            awaitOutcome(profileKey)?.result,
        )
        scheduler.cancel(profileKey)
        Unit
    }

    private suspend fun awaitOutcome(profileKey: String): BackgroundSyncOutcomeStore.Outcome? {
        val store = BackgroundSyncOutcomeStore(context)
        repeat(50) {
            store.read(profileKey)?.let { return it }
            delay(20)
        }
        return store.read(profileKey)
    }
}

private class FailingWorkManagerClient : BackgroundSyncWorkManagerClient {
    override suspend fun enqueueUniquePeriodicWork(name: String, request: PeriodicWorkRequest) {
        throw IllegalStateException("injected WorkManager enqueue failure")
    }

    override suspend fun enqueueUniqueWork(name: String, request: OneTimeWorkRequest) {
        throw IllegalStateException("injected WorkManager enqueue failure")
    }

    override suspend fun cancelUniqueWork(name: String) {
        throw IllegalStateException("injected WorkManager cancellation failure")
    }

    override suspend fun workInfosForUniqueWork(name: String): List<WorkInfo> {
        throw IllegalStateException("injected WorkManager observation failure")
    }
}

private class TimeoutFlutterSession : BackgroundSyncFlutterSession {
    override suspend fun start() {
        withTimeout(1) { delay(10) }
    }

    override suspend fun runAutomatic(
        profileKey: String,
        workId: String,
        attemptCount: Int,
    ): Map<String, Any?>? = null

    override suspend fun cancel() {}

    override suspend fun close() {}
}

private class FailingFlutterSession : BackgroundSyncFlutterSession {
    override suspend fun start() {
        throw IllegalStateException("injected Flutter bootstrap failure")
    }

    override suspend fun runAutomatic(
        profileKey: String,
        workId: String,
        attemptCount: Int,
    ): Map<String, Any?>? = null

    override suspend fun cancel() {}

    override suspend fun close() {}
}

private class DartFailureFlutterSession : BackgroundSyncFlutterSession {
    override suspend fun start() {}

    override suspend fun runAutomatic(
        profileKey: String,
        workId: String,
        attemptCount: Int,
    ): Map<String, Any?>? {
        throw IllegalStateException("injected Dart invocation failure")
    }

    override suspend fun cancel() {}

    override suspend fun close() {}
}

private class CancelledFlutterSession : BackgroundSyncFlutterSession {
    override suspend fun start() {
        throw CancellationException("injected worker cancellation")
    }

    override suspend fun runAutomatic(
        profileKey: String,
        workId: String,
        attemptCount: Int,
    ): Map<String, Any?>? = null

    override suspend fun cancel() {}

    override suspend fun close() {}
}

class ConstraintReleaseWorker(
    context: Context,
    params: WorkerParameters,
) : Worker(context, params) {
    override fun doWork(): Result = Result.success()
}
