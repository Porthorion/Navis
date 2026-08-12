package com.navis.app.navis

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.lifecycle.Observer
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.WorkRequest
import java.util.concurrent.TimeUnit
import java.util.concurrent.CountDownLatch

internal data class BackgroundSyncScheduleSpec(
    val profileKey: String,
    val intervalMinutes: Long,
    val unmeteredOnly: Boolean,
) {
    init {
        require(profileKey.matches(Regex("[0-9a-f]{32}")))
        require(intervalMinutes in supportedIntervals)
    }

    val networkType: NetworkType
        get() = if (unmeteredOnly) NetworkType.UNMETERED else NetworkType.CONNECTED

    val periodicWorkName: String
        get() = "navis.library.automatic.$profileKey.v1"

    val catchupWorkName: String
        get() = "navis.library.catchup.$profileKey.v1"

    companion object {
        val supportedIntervals = setOf(15L, 30L, 60L, 120L, 360L, 720L)
    }
}

internal data class BackgroundSyncScheduleObservation(
    val available: Boolean = true,
    val state: String,
    val workId: String? = null,
    val attemptCount: Int = 0,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "available" to available,
        "state" to state,
        "workId" to workId,
        "attemptCount" to attemptCount,
    )
}

internal class AndroidBackgroundSyncScheduler(
    context: Context,
    private val workManager: WorkManager = WorkManager.getInstance(context.applicationContext),
) {
    fun configurePeriodic(spec: BackgroundSyncScheduleSpec): BackgroundSyncScheduleObservation {
        val request = PeriodicWorkRequestBuilder<NavisBackgroundSyncWorker>(
            spec.intervalMinutes,
            TimeUnit.MINUTES,
        ).setConstraints(constraintsFor(spec))
            .setInputData(NavisBackgroundSyncWorker.inputData(spec.profileKey))
            .setBackoffCriteria(
                androidx.work.BackoffPolicy.EXPONENTIAL,
                WorkRequest.MIN_BACKOFF_MILLIS,
                TimeUnit.MILLISECONDS,
            ).addTag(spec.periodicWorkName)
            .build()
        workManager.enqueueUniquePeriodicWork(
            spec.periodicWorkName,
            ExistingPeriodicWorkPolicy.UPDATE,
            request,
        )
        return BackgroundSyncScheduleObservation(
            state = "scheduled",
            workId = request.id.toString(),
        )
    }

    fun enqueueCatchup(spec: BackgroundSyncScheduleSpec): BackgroundSyncScheduleObservation {
        val request = OneTimeWorkRequestBuilder<NavisBackgroundSyncWorker>()
            .setConstraints(constraintsFor(spec))
            .setInputData(NavisBackgroundSyncWorker.inputData(spec.profileKey))
            .setBackoffCriteria(
                androidx.work.BackoffPolicy.EXPONENTIAL,
                WorkRequest.MIN_BACKOFF_MILLIS,
                TimeUnit.MILLISECONDS,
            ).addTag(spec.catchupWorkName)
            .build()
        workManager.enqueueUniqueWork(
            spec.catchupWorkName,
            ExistingWorkPolicy.KEEP,
            request,
        )
        return BackgroundSyncScheduleObservation(
            state = "enqueued",
            workId = request.id.toString(),
        )
    }

    fun cancel(profileKey: String): BackgroundSyncScheduleObservation {
        val spec = BackgroundSyncScheduleSpec(profileKey, 15, true)
        workManager.cancelUniqueWork(spec.periodicWorkName)
        workManager.cancelUniqueWork(spec.catchupWorkName)
        return BackgroundSyncScheduleObservation(state = "cancelled")
    }

    fun status(profileKey: String): BackgroundSyncScheduleObservation {
        val spec = BackgroundSyncScheduleSpec(profileKey, 15, true)
        // MainActivity invokes this from a background thread. LiveData.value
        // is often null until observed, so observe on the main thread and wait
        // briefly for one snapshot instead of falsely reporting no work.
        val info = listOf(spec.periodicWorkName, spec.catchupWorkName)
            .flatMap(::workInfosForUniqueName)
            .maxWithOrNull(
                compareBy<WorkInfo> { it.state.observationPriority }
                    .thenBy { it.runAttemptCount }
            )
            ?: return BackgroundSyncScheduleObservation(state = "none")
        return BackgroundSyncScheduleObservation(
            state = info.state.toChannelState(),
            workId = info.id.toString(),
            attemptCount = info.runAttemptCount.coerceIn(0, 100),
        )
    }

    private fun constraintsFor(spec: BackgroundSyncScheduleSpec): Constraints =
        Constraints.Builder().setRequiredNetworkType(spec.networkType).build()

    private fun workInfosForUniqueName(name: String): List<WorkInfo> {
        check(Looper.myLooper() != Looper.getMainLooper()) {
            "WorkManager status must be queried away from the main thread."
        }
        val liveData = workManager.getWorkInfosForUniqueWorkLiveData(name)
        val latch = CountDownLatch(1)
        var snapshot: List<WorkInfo> = emptyList()
        val observer = Observer<List<WorkInfo>> { values ->
            snapshot = values ?: emptyList()
            latch.countDown()
        }
        val mainHandler = Handler(Looper.getMainLooper())
        mainHandler.post { liveData.observeForever(observer) }
        try {
            latch.await(statusQueryTimeoutMillis, TimeUnit.MILLISECONDS)
        } finally {
            mainHandler.post { liveData.removeObserver(observer) }
        }
        return snapshot
    }

    private companion object {
        const val statusQueryTimeoutMillis = 2_000L
    }
}

private fun WorkInfo.State.toChannelState(): String = when (this) {
    WorkInfo.State.RUNNING -> "running"
    WorkInfo.State.ENQUEUED -> "enqueued"
    WorkInfo.State.BLOCKED -> "blocked"
    WorkInfo.State.CANCELLED -> "cancelled"
    WorkInfo.State.SUCCEEDED, WorkInfo.State.FAILED -> "none"
}

private val WorkInfo.State.observationPriority: Int
    get() = when (this) {
        WorkInfo.State.RUNNING -> 4
        WorkInfo.State.ENQUEUED -> 3
        WorkInfo.State.BLOCKED -> 2
        WorkInfo.State.CANCELLED -> 1
        WorkInfo.State.SUCCEEDED, WorkInfo.State.FAILED -> 0
    }
