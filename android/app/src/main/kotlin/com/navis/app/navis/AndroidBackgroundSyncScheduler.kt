package com.navis.app.navis

import android.content.Context
import androidx.concurrent.futures.await
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.ListenableWorker
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.WorkRequest
import java.util.concurrent.TimeUnit
import java.util.concurrent.Executor
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

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
    val workerResult: String? = null,
    val workerStopReason: String? = null,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "available" to available,
        "state" to state,
        "workId" to workId,
        "attemptCount" to attemptCount,
        "workerResult" to workerResult,
        "workerStopReason" to workerStopReason,
    )
}

/** Narrow seam for deterministic native WorkManager failure coverage. */
internal interface BackgroundSyncWorkManagerClient {
    suspend fun enqueueUniquePeriodicWork(
        name: String,
        request: androidx.work.PeriodicWorkRequest,
    )

    suspend fun enqueueUniqueWork(name: String, request: OneTimeWorkRequest)

    suspend fun cancelUniqueWork(name: String)

    suspend fun workInfosForUniqueWork(name: String): List<WorkInfo>
}

internal class WorkManagerBackgroundSyncClient(
    private val workManager: WorkManager,
) : BackgroundSyncWorkManagerClient {
    override suspend fun enqueueUniquePeriodicWork(
        name: String,
        request: androidx.work.PeriodicWorkRequest,
    ) {
        workManager.enqueueUniquePeriodicWork(name, ExistingPeriodicWorkPolicy.UPDATE, request)
            .awaitAcknowledgement()
    }

    override suspend fun enqueueUniqueWork(name: String, request: OneTimeWorkRequest) {
        workManager.enqueueUniqueWork(name, ExistingWorkPolicy.KEEP, request)
            .awaitAcknowledgement()
    }

    override suspend fun cancelUniqueWork(name: String) {
        workManager.cancelUniqueWork(name).awaitAcknowledgement()
    }

    override suspend fun workInfosForUniqueWork(name: String): List<WorkInfo> =
        workManager.getWorkInfosForUniqueWork(name).await()
}

internal class AndroidBackgroundSyncScheduler(
    context: Context,
    private val workManagerClient: BackgroundSyncWorkManagerClient =
        WorkManagerBackgroundSyncClient(WorkManager.getInstance(context.applicationContext)),
    private val outcomeStore: BackgroundSyncOutcomeStore = BackgroundSyncOutcomeStore(context),
    private val workerClass: Class<out ListenableWorker> = NavisBackgroundSyncWorker::class.java,
) {
    suspend fun configurePeriodic(spec: BackgroundSyncScheduleSpec): BackgroundSyncScheduleObservation {
        val request = androidx.work.PeriodicWorkRequest.Builder(
            workerClass,
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
        return try {
            workManagerClient.enqueueUniquePeriodicWork(spec.periodicWorkName, request)
            BackgroundSyncScheduleObservation(
                state = "scheduled",
                workId = request.id.toString(),
            )
        } catch (_: Throwable) {
            BackgroundSyncScheduleObservation(state = "platformFailure")
        }
    }

    suspend fun enqueueCatchup(spec: BackgroundSyncScheduleSpec): BackgroundSyncScheduleObservation {
        val request = OneTimeWorkRequest.Builder(workerClass)
            .setConstraints(constraintsFor(spec))
            .setInputData(NavisBackgroundSyncWorker.inputData(spec.profileKey))
            .setBackoffCriteria(
                androidx.work.BackoffPolicy.EXPONENTIAL,
                WorkRequest.MIN_BACKOFF_MILLIS,
                TimeUnit.MILLISECONDS,
            ).addTag(spec.catchupWorkName)
            .build()
        return try {
            workManagerClient.enqueueUniqueWork(spec.catchupWorkName, request)
            BackgroundSyncScheduleObservation(
                state = "enqueued",
                workId = request.id.toString(),
            )
        } catch (_: Throwable) {
            BackgroundSyncScheduleObservation(state = "platformFailure")
        }
    }

    suspend fun cancel(profileKey: String): BackgroundSyncScheduleObservation {
        val spec = BackgroundSyncScheduleSpec(profileKey, 15, true)
        return try {
            workManagerClient.cancelUniqueWork(spec.periodicWorkName)
            workManagerClient.cancelUniqueWork(spec.catchupWorkName)
            BackgroundSyncScheduleObservation(state = "cancelled")
        } catch (_: Throwable) {
            BackgroundSyncScheduleObservation(state = "platformFailure")
        }
    }

    suspend fun status(profileKey: String): BackgroundSyncScheduleObservation {
        val spec = BackgroundSyncScheduleSpec(profileKey, 15, true)
        // Status is an observation surface. It must not consume the terminal
        // outcome: Settings, the foreground reconciler, and authenticated
        // diagnostics may all read it independently after a worker finishes.
        val outcome = outcomeStore.read(profileKey)
        val workInfos = try {
            listOf(spec.periodicWorkName, spec.catchupWorkName)
                .flatMap { name -> workManagerClient.workInfosForUniqueWork(name) }
        } catch (_: Throwable) {
            return BackgroundSyncScheduleObservation(
                state = "statusUnavailable",
                workerResult = outcome?.result,
                workerStopReason = outcome?.stopReason,
            )
        }
        val info = workInfos
            .maxWithOrNull(
                compareBy<WorkInfo> { it.state.observationPriority }
                    .thenBy { it.runAttemptCount }
            )
            ?: return BackgroundSyncScheduleObservation(
                state = "none",
                workerResult = outcome?.result,
                workerStopReason = outcome?.stopReason,
            )
        return BackgroundSyncScheduleObservation(
            state = info.state.toChannelState(),
            workId = info.id.toString(),
            attemptCount = info.runAttemptCount.coerceIn(0, 100),
            workerResult = outcome?.result,
            workerStopReason = outcome?.stopReason,
        )
    }

    private fun constraintsFor(spec: BackgroundSyncScheduleSpec): Constraints =
        Constraints.Builder().setRequiredNetworkType(spec.networkType).build()

}

internal class BackgroundSyncOutcomeStore(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(
        "navis.background_sync.outcomes", Context.MODE_PRIVATE,
    )

    data class Outcome(val result: String, val stopReason: String?)

    fun record(profileKey: String, result: String, stopReason: String? = null) {
        preferences.edit()
            .putString("$profileKey.result", result)
            .putString("$profileKey.stop_reason", stopReason)
            .apply()
    }

    fun read(profileKey: String): Outcome? {
        val result = preferences.getString("$profileKey.result", null) ?: return null
        return Outcome(result, preferences.getString("$profileKey.stop_reason", null))
    }

    fun clear(profileKey: String) {
        preferences.edit()
            .remove("$profileKey.result")
            .remove("$profileKey.stop_reason")
            .apply()
    }
}

private suspend fun androidx.work.Operation.awaitAcknowledgement() {
    suspendCancellableCoroutine { continuation ->
        result.addListener(
            {
                try {
                    result.get()
                    if (continuation.isActive) {
                        continuation.resume(Unit)
                    }
                } catch (error: Throwable) {
                    if (continuation.isActive) {
                        continuation.resumeWithException(error)
                    }
                }
            },
            directExecutor,
        )
    }
}

private val directExecutor = Executor { runnable -> runnable.run() }

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
