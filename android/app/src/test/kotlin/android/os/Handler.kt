package android.os

import java.util.ArrayDeque

/** Host-only queue for the real bridge's posted runnables; no Looper or clock. */
class Handler {
    val posted = ArrayDeque<Runnable>()

    fun post(action: Runnable): Boolean {
        posted.addLast(action)
        return true
    }
}
