package com.navis.app.navis

import android.content.Context
import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.FileChannel
import java.nio.channels.FileLock
import java.nio.channels.OverlappingFileLockException
import java.util.concurrent.ConcurrentHashMap
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.WorkerParameters
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume

private const val backgroundSyncChannelName = "com.navis.app/background_sync"
private const val engineReadyTimeoutMillis = 15_000L
private const val workerTimeoutMillis = 8 * 60 * 1000L
private const val cancellationCheckpointTimeoutMillis = 10_000L

class NavisBackgroundSyncWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    // WorkManager calls CoroutineWorker on a background dispatcher, while all
    // FlutterEngine and binary-messenger setup must happen on Android's main
    // thread. The Dart sync itself remains asynchronous; this dispatcher only
    // owns the Android embedding lifecycle and never performs network I/O.
    override suspend fun doWork(): Result = withContext(Dispatchers.Main.immediate) {
        coroutineScope {
            val profileKey = inputData.getString(profileKeyDataKey)
            if (profileKey == null || !profileKey.matches(Regex("[0-9a-f]{32}"))) {
                return@coroutineScope Result.failure()
            }
            val outcomeStore = BackgroundSyncOutcomeStore(applicationContext)
            if (!BackgroundSyncDispatchGate.tryAcquire(applicationContext, profileKey)) {
                outcomeStore.record(
                    profileKey,
                    "alreadyDispatching",
                    "alreadyDispatching",
                )
                return@coroutineScope Result.success()
            }
            try {
            if (runAttemptCount >= maxBootstrapAttempts) {
                val outcome = BackgroundSyncNativeFailure.RETRY_EXHAUSTED.outcome
                outcomeStore.record(
                    profileKey,
                    outcome.result,
                    outcome.stopReason,
                )
                return@coroutineScope Result.failure()
            }
            var session: BackgroundSyncFlutterSession? = null
            try {
                val activeSession = BackgroundSyncFlutterSessions.create(applicationContext)
                session = activeSession
                activeSession.start()
                val response = activeSession.runAutomatic(
                    profileKey = profileKey,
                    workId = id.toString(),
                    attemptCount = runAttemptCount.coerceIn(0, maxReportedAttemptCount),
                )
                // A Dart response is authoritative over an earlier native
                // bootstrap fallback for this profile.
                outcomeStore.clear(profileKey)
                when (BackgroundSyncWorkerResultMapper.directiveFor(response?.get("category") as? String)) {
                    BackgroundSyncWorkerDirective.RETRY -> Result.retry()
                    BackgroundSyncWorkerDirective.FAILURE -> Result.failure()
                    BackgroundSyncWorkerDirective.SUCCESS -> Result.success()
                }
            } catch (_: TimeoutCancellationException) {
                val outcome = BackgroundSyncNativeFailure.TIMEOUT.outcome
                outcomeStore.record(profileKey, outcome.result, outcome.stopReason)
                Result.retry()
            } catch (error: CancellationException) {
                val outcome = BackgroundSyncNativeFailure.CANCELLED.outcome
                outcomeStore.record(profileKey, outcome.result, outcome.stopReason)
                withContext(NonCancellable + Dispatchers.Main.immediate) {
                    runCatching {
                        withTimeout(cancellationCheckpointTimeoutMillis) {
                            session?.cancel()
                        }
                    }
                }
                throw error
            } catch (_: Throwable) {
                val outcome = BackgroundSyncNativeFailure.BOOTSTRAP_FAILURE.outcome
                outcomeStore.record(profileKey, outcome.result, outcome.stopReason)
                Result.retry()
            } finally {
                withContext(NonCancellable + Dispatchers.Main.immediate) {
                    runCatching {
                        withTimeout(cancellationCheckpointTimeoutMillis) {
                            session?.close()
                        }
                    }
                }
            }
            } finally {
                BackgroundSyncDispatchGate.release(profileKey)
            }
        }
    }

    companion object {
        private const val profileKeyDataKey = "profile_key"
        private const val maxReportedAttemptCount = 100
        private const val maxBootstrapAttempts = 3

        fun inputData(profileKey: String): Data = Data.Builder()
            .putString(profileKeyDataKey, profileKey)
            .build()
    }

}

/** Flutter boundary for the headless worker; replaceable only by same-process tests. */
internal interface BackgroundSyncFlutterSession {
    suspend fun start()

    suspend fun runAutomatic(
        profileKey: String,
        workId: String,
        attemptCount: Int,
    ): Map<String, Any?>?

    suspend fun cancel()

    suspend fun close()
}

internal object BackgroundSyncFlutterSessions {
    @Volatile
    var testFactory: ((Context) -> BackgroundSyncFlutterSession)? = null

    fun create(context: Context): BackgroundSyncFlutterSession =
        testFactory?.invoke(context) ?: FlutterEngineBackgroundSyncSession(context)
}

private class FlutterEngineBackgroundSyncSession(
    private val context: Context,
) : BackgroundSyncFlutterSession {
    private val ready = CompletableDeferred<Unit>()
    private lateinit var engine: FlutterEngine
    private lateinit var channel: MethodChannel
    private var networkCostChannel: MethodChannel? = null

    override suspend fun start() {
        engine = FlutterEngine(context)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, backgroundSyncChannelName)
        GeneratedPluginRegistrant.registerWith(engine)
        networkCostChannel = registerNetworkCostChannel(context, engine.dartExecutor.binaryMessenger)
        channel.setMethodCallHandler { call, result ->
            if (call.method == "ready") {
                if (!ready.isCompleted) ready.complete(Unit)
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
        val loader = FlutterInjector.instance().flutterLoader()
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                "navisBackgroundSyncEntrypoint",
            ),
        )
        withTimeout(engineReadyTimeoutMillis) { ready.await() }
    }

    override suspend fun runAutomatic(
        profileKey: String,
        workId: String,
        attemptCount: Int,
    ): Map<String, Any?>? = withTimeout(workerTimeoutMillis) {
        channel.invokeMapMethod(
            "runAutomaticBackgroundSync",
            mapOf(
                "profileKey" to profileKey,
                "workId" to workId,
                "attemptCount" to attemptCount,
            ),
        )
    }

    override suspend fun cancel() {
        channel.invokeVoidMethod("cancel")
    }

    override suspend fun close() {
        networkCostChannel?.setMethodCallHandler(null)
        networkCostChannel = null
        if (::engine.isInitialized) engine.destroy()
    }
}

/** Bounded native categories persisted when Dart cannot return an outcome. */
internal enum class BackgroundSyncNativeFailure(
    val outcome: BackgroundSyncNativeOutcome,
) {
    TIMEOUT(BackgroundSyncNativeOutcome("engineTimeout", "engineTimeout")),
    CANCELLED(BackgroundSyncNativeOutcome("stoppedBySystem", "stoppedBySystem")),
    BOOTSTRAP_FAILURE(BackgroundSyncNativeOutcome("transientFailure", "bootstrapFailure")),
    RETRY_EXHAUSTED(BackgroundSyncNativeOutcome("bootstrapRetryExhausted", "retryCapReached")),
}

internal data class BackgroundSyncNativeOutcome(
    val result: String,
    val stopReason: String,
)

/** Prevents periodic and catch-up work from booting duplicate Flutter engines. */
internal object BackgroundSyncDispatchGate {
    private data class Handle(
        val channel: FileChannel,
        val lock: FileLock,
    )

    private val handles = ConcurrentHashMap<String, Handle>()

    /**
     * An advisory OS file lock survives the boundary between WorkManager
     * processes and is automatically released if Android kills the owner.
     */
    fun tryAcquire(context: Context, profileKey: String): Boolean = synchronized(this) {
        if (handles.containsKey(profileKey)) return false
        val directory = File(context.filesDir, "navis-background-sync")
        if (!directory.exists() && !directory.mkdirs()) return false
        val channel = try {
            RandomAccessFile(File(directory, "$profileKey.lock"), "rw").channel
        } catch (_: Throwable) {
            return false
        }
        val lock = try {
            channel.tryLock()
        } catch (_: OverlappingFileLockException) {
            null
        } catch (_: Throwable) {
            null
        }
        if (lock == null) {
            channel.close()
            return false
        }
        handles[profileKey] = Handle(channel, lock)
        true
    }

    fun release(profileKey: String) {
        val handle = handles.remove(profileKey) ?: return
        runCatching { handle.lock.release() }
        runCatching { handle.channel.close() }
    }
}

/** Maps the small, redacted Dart protocol to WorkManager semantics. */
internal enum class BackgroundSyncWorkerDirective { SUCCESS, RETRY, FAILURE }

internal object BackgroundSyncWorkerResultMapper {
    fun directiveFor(category: String?): BackgroundSyncWorkerDirective = when (category) {
        // Only failures that occurred before the coordinator had a chance to
        // persist its own cooldown are retried by WorkManager.
        "transientFailure" -> BackgroundSyncWorkerDirective.RETRY
        "permanentFailure" -> BackgroundSyncWorkerDirective.FAILURE
        else -> BackgroundSyncWorkerDirective.SUCCESS
    }
}

private suspend fun MethodChannel.invokeMapMethod(
    method: String,
    arguments: Any? = null,
): Map<String, Any?>? =
    suspendCancellableCoroutine { continuation ->
        invokeMethod(method, arguments, object : MethodChannel.Result {
            override fun success(result: Any?) {
                @Suppress("UNCHECKED_CAST")
                continuation.resume(result as? Map<String, Any?>)
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                continuation.resume(null)
            }

            override fun notImplemented() {
                continuation.resume(null)
            }
        })
    }

private suspend fun MethodChannel.invokeVoidMethod(method: String) {
    suspendCancellableCoroutine { continuation ->
        invokeMethod(method, null, object : MethodChannel.Result {
            override fun success(result: Any?) {
                continuation.resume(Unit)
            }

            override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                continuation.resume(Unit)
            }

            override fun notImplemented() {
                continuation.resume(Unit)
            }
        })
    }
}
