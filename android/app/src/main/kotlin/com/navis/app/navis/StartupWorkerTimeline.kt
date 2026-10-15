package com.navis.app.navis

import android.content.Context
import java.io.File
import java.io.RandomAccessFile
import java.time.Instant
import org.json.JSONObject

/** Identity-free worker evidence, independent of any Flutter/plugin bootstrap. */
internal object StartupWorkerTimeline {
    private val outcomes = setOf(
        "success", "failure", "timeout", "deferredPlayback", "noWorkDue",
        "deferredPolicy", "credentialUnavailable", "deferredSetup", "deferredUpgrade", "leaseHeld",
        "permanentFailure", "transientFailure", "stoppedBySystem",
    )

    fun record(context: Context, event: String, outcome: String? = null, elapsedMs: Long? = null) {
        if (event !in setOf("workerEntry", "workerExit")) return
        runCatching {
            // A separate lock protects overlapping dispatches and another
            // process; foreground Dart only reads this separate native ring.
            RandomAccessFile(File(context.filesDir, "startup-worker.lock"), "rw").use { lock ->
                lock.channel.lock().use {
                    val file = File(context.filesDir, "startup-worker.jsonl")
                    val previous = if (file.exists() && file.length() <= 32768L)
                        file.readLines().takeLast(99) else emptyList()
                    val row = JSONObject()
                        .put("at", Instant.now().toString())
                        .put("event", event)
                    if (outcome != null) row.put("outcome", if (outcome in outcomes) outcome else "failure")
                    if (elapsedMs != null) row.put("elapsedMs", elapsedMs.coerceIn(0L, 1_000_000_000L))
                    file.writeText((previous + row.toString()).joinToString("\n", postfix = "\n"))
                }
            }
        }.onFailure {
            android.util.Log.w("NavisStartup", "Worker startup details unavailable")
        }
    }
}
