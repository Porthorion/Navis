package com.navis.app.navis

import android.content.Context
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
        val info = workManager.getWorkInfosForUniqueWorkLiveData(spec.periodicWorkName)
            .value
            ?.maxByOrNull { it.runAttemptCount }
            ?: return BackgroundSyncScheduleObservation(state = "none")
        return BackgroundSyncScheduleObservation(
            state = info.state.toChannelState(),
            workId = info.id.toString(),
            attemptCount = info.runAttemptCount.coerceIn(0, 100),
        )
    }

    private fun constraintsFor(spec: BackgroundSyncScheduleSpec): Constraints =
        Constraints.Builder().setRequiredNetworkType(spec.networkType).build()
}

private fun WorkInfo.State.toChannelState(): String = when (this) {
    WorkInfo.State.RUNNING -> "running"
    WorkInfo.State.ENQUEUED -> "enqueued"
    WorkInfo.State.BLOCKED -> "blocked"
    WorkInfo.State.CANCELLED -> "cancelled"
    WorkInfo.State.SUCCEEDED, WorkInfo.State.FAILED -> "none"
}
