package com.navis.app.navis

import android.content.Context
import android.media.AudioManager
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
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume

class NavisBackgroundSyncWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result = coroutineScope {
        val profileKey = inputData.getString(profileKeyDataKey)
        if (profileKey == null || !profileKey.matches(Regex("[0-9a-f]{32}"))) {
            return@coroutineScope Result.failure()
        }
        val engine = FlutterEngine(applicationContext)
        val ready = CompletableDeferred<Unit>()
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, channelName)
        try {
            GeneratedPluginRegistrant.registerWith(engine)
            channel.setMethodCallHandler { call, result ->
                if (call.method == "ready") {
                    if (!ready.isCompleted) {
                        ready.complete(Unit)
                    }
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
            val response = withTimeout(workerTimeoutMillis) {
                channel.invokeMapMethod(
                    "runAutomaticBackgroundSync",
                    mapOf(
                        "profileKey" to profileKey,
                        "workId" to id.toString(),
                        "attemptCount" to runAttemptCount.coerceIn(0, maxReportedAttemptCount),
                        "hasActivePlayback" to isMusicActive(),
                    ),
                )
            }
            when (BackgroundSyncWorkerResultMapper.directiveFor(response?.get("category") as? String)) {
                BackgroundSyncWorkerDirective.RETRY -> Result.retry()
                BackgroundSyncWorkerDirective.FAILURE -> Result.failure()
                BackgroundSyncWorkerDirective.SUCCESS -> Result.success()
            }
        } catch (_: TimeoutCancellationException) {
            Result.retry()
        } catch (error: CancellationException) {
            withContext(NonCancellable) {
                runCatching {
                    withTimeout(cancellationCheckpointTimeoutMillis) {
                        channel.invokeVoidMethod("cancel")
                    }
                }
            }
            throw error
        } catch (_: Throwable) {
            Result.retry()
        } finally {
            withContext(NonCancellable) {
                runCatching {
                    withTimeout(cancellationCheckpointTimeoutMillis) {
                        channel.invokeVoidMethod("shutdown")
                    }
                }
            }
            engine.destroy()
        }
    }

    companion object {
        private const val channelName = "com.navis.app/background_sync"
        private const val profileKeyDataKey = "profile_key"
        private const val engineReadyTimeoutMillis = 15_000L
        private const val workerTimeoutMillis = 8 * 60 * 1000L
        private const val cancellationCheckpointTimeoutMillis = 10_000L
        private const val maxReportedAttemptCount = 100

        fun inputData(profileKey: String): Data = Data.Builder()
            .putString(profileKeyDataKey, profileKey)
            .build()
    }

    private fun isMusicActive(): Boolean {
        val audioManager = applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        return audioManager.isMusicActive
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
