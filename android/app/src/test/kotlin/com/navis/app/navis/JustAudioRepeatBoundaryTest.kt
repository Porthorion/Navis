package com.navis.app.navis

import java.lang.reflect.Proxy
import org.junit.Assert.*
import org.junit.Test
import sun.misc.Unsafe

/** Exercises the real vendored bridge without a Looper or an audio device. */
class JustAudioRepeatBoundaryTest {
    private val unsafe = Unsafe::class.java.getDeclaredField("theUnsafe").let {
        it.isAccessible = true
        it.get(null) as Unsafe
    }
    private val bridgeClass = Class.forName("com.ryanheise.just_audio.AudioPlayer")

    private fun put(target: Any, name: String, value: Any?) {
        target.javaClass.getDeclaredField(name).apply { isAccessible = true }.set(target, value)
    }

    private inner class Fixture {
        val bridge = unsafe.allocateInstance(bridgeClass)
        val streamTag = "fixture-stream"
        var items = mutableListOf(item(streamTag), item(null), item(null))
        var index = 0
        var nativeMode = -1
        var pauseAtEnd = false
        var playing = true
        var ended = false
        var resumes = 0
        val seeks = mutableListOf<Int>()
        val uid = Any()
        var currentUid: Any = uid
        private fun timeline(): Any {
            val windowClass = Class.forName("androidx.media3.common.Timeline\$Window")
            val windows = items.map { unsafe.allocateInstance(windowClass).also { put(it, "uid", currentUid) } }
            val immutable = Class.forName("com.google.common.collect.ImmutableList")
            val timeline = unsafe.allocateInstance(Class.forName("androidx.media3.common.Timeline\$RemotableTimeline"))
            put(timeline, "windows", immutable.getMethod("copyOf", Collection::class.java).invoke(null, windows))
            return timeline
        }
        val exoClass = Class.forName("androidx.media3.exoplayer.ExoPlayer")
        val exo = Proxy.newProxyInstance(exoClass.classLoader, arrayOf(exoClass)) { _, method, args ->
            when (method.name) {
                "getMediaItemCount" -> items.size
                "getMediaItemAt" -> items[args[0] as Int]
                "getCurrentMediaItemIndex" -> index
                "getCurrentTimeline" -> timeline()
                "setRepeatMode" -> { nativeMode = args[0] as Int; null }
                "setPauseAtEndOfMediaItems" -> { pauseAtEnd = args[0] as Boolean; null }
                "getPauseAtEndOfMediaItems" -> pauseAtEnd
                "getPlayWhenReady" -> playing
                "getPlaybackState" -> if (ended) 4 else 3
                "setPlayWhenReady" -> {
                    playing = args[0] as Boolean
                    if (playing) resumes++
                    null
                }
                "seekTo" -> { seeks.add(args[0] as Int); ended = false; null }
                "getCurrentPosition", "getBufferedPosition" -> 10_000L
                "getDuration" -> 10_000L
                else -> throw AssertionError("Unexpected native call: ${method.name}")
            }
        }

        init {
            put(bridge, "player", exo)
            put(bridge, "progressiveHttpSources", hashSetOf(streamTag))
            put(bridge, "playRequested", true)
            val state = Class.forName("com.ryanheise.just_audio.AudioPlayer\$ProcessingState")
            put(bridge, "processingState", state.enumConstants.first { it.toString() == "ready" })
            put(bridge, "eventChannel", unsafe.allocateInstance(
                Class.forName("com.ryanheise.just_audio.BetterEventChannel"),
            ))
        }

        fun item(tag: String?): Any {
            val itemClass = Class.forName("androidx.media3.common.MediaItem")
            val item = unsafe.allocateInstance(itemClass)
            if (tag != null) {
                val config = unsafe.allocateInstance(Class.forName(
                    "androidx.media3.common.MediaItem\$LocalConfiguration",
                ))
                put(config, "tag", tag)
                put(item, "localConfiguration", config)
            }
            return item
        }

        fun field(name: String): Any? = bridgeClass.getDeclaredField(name)
            .apply { isAccessible = true }.get(bridge)

        fun call(name: String) = bridgeClass.getDeclaredMethod(name)
            .apply { isAccessible = true }.invoke(bridge)

        fun mode(value: Int) = bridgeClass.getMethod("setLoopMode", Int::class.javaPrimitiveType)
            .invoke(bridge, value)

        fun endedCallback() = bridgeClass.getMethod("onPlaybackStateChanged", Int::class.javaPrimitiveType)
            .invoke(bridge, 4)

        fun boundary() {
            playing = false
            // A posted callback is driven explicitly below; no Android Looper runs here.
            put(bridge, "repeatPending", true)
            endReason()
            assertSame("the end callback must retain the old pause UID", uid, field("repeatAtEndUid"))
        }

        fun endReason() {
            val reason = Class.forName("androidx.media3.common.Player")
                .getField("PLAY_WHEN_READY_CHANGE_REASON_END_OF_MEDIA_ITEM").getInt(null)
            bridgeClass.getMethod("onPlayWhenReadyChanged", Boolean::class.javaPrimitiveType,
                Int::class.javaPrimitiveType).invoke(bridge, false, reason)
        }

        fun complete(boundaryUid: Any = uid, revision: Long = 0L) {
            bridgeClass.getDeclaredMethod(
                "completeProgressiveRepeat", Any::class.java, Long::class.javaPrimitiveType,
            ).apply { isAccessible = true }.invoke(bridge, boundaryUid, revision)
        }
    }

    @Test fun loopModeChangesKeepTheAlreadyOwnedPause() {
        for (mode in listOf(0, 2, 1)) {
            val f = Fixture()
            f.index = 1
            f.items[1] = f.item(f.streamTag)
            f.mode(1)
            f.boundary()
            f.mode(mode)
            assertSame("mode changes must retain the paused occurrence", f.uid, f.field("repeatAtEndUid"))
            assertEquals(true, f.field("repeatPending"))
            assertEquals(0, f.nativeMode)
        }
    }

    @Test fun playlistEligibilityUsesOnlyCurrentTaggedItemsAtEveryPosition() {
        val f = Fixture()
        for (streamIndex in 0..2) {
            f.items = MutableList(3) { f.item(if (it == streamIndex) f.streamTag else null) }
            for (current in 0..2) {
                f.index = current
                f.mode(2)
                assertEquals(0, f.nativeMode)
                f.mode(1)
                assertEquals(if (current == streamIndex) 0 else 1, f.nativeMode)
            }
        }
        f.items = mutableListOf(f.item(null), f.item("not-registered"), f.item(null))
        f.mode(2)
        assertEquals("decoded sources outside the playlist do not own ALL", 2, f.nativeMode)
        f.items.clear()
        f.index = -1
        f.mode(2)
        assertEquals(2, f.nativeMode)
    }

    @Test fun modeSwitchesUseTheLatestPolicyExactlyOnce() {
        for (boundaryFirst in listOf(false, true)) {
            for (ended in listOf(false, true)) {
                for (mode in listOf(0, 2, 1)) {
                    val f = Fixture()
                    f.mode(1)
                    if (boundaryFirst) f.boundary() else f.playing = false
                    f.ended = ended
                    f.mode(0)
                    f.mode(mode)
                    if (!boundaryFirst) f.boundary()
                    f.complete()
                    f.complete()
                    assertEquals(1, f.resumes)
                    assertEquals(if (mode == 1) listOf(0) else if (ended) listOf(1) else emptyList<Int>(), f.seeks)
                    assertEquals(false, f.field("repeatPending"))
                }
            }
        }
    }

    @Test fun removingLastEligibleStreamReleasesBothBoundaryCallbackOrders() {
        for (boundaryFirst in listOf(false, true)) {
            for (ended in listOf(false, true)) {
                for (append in listOf(false, true)) {
                    val f = Fixture()
                    f.mode(2)
                    // The current file remains after the stream before it is removed.
                    f.items = mutableListOf(f.item(f.streamTag), f.item(null))
                    f.index = 1
                    f.call("updateLoopPolicy")
                    if (boundaryFirst) f.boundary() else f.playing = false
                    if (append) f.items.add(f.item(null))
                    f.items.removeAt(0)
                    f.index = 0
                    f.call("updateLoopPolicy")
                    assertEquals(2, f.nativeMode)
                    assertFalse(f.pauseAtEnd)
                    if (!boundaryFirst) f.boundary()
                    f.ended = ended
                    f.complete()
                    f.complete()
                    val expected = if (!append) listOf(0) else if (ended) listOf(1) else emptyList<Int>()
                    assertEquals(expected, f.seeks)
                    assertEquals(1, f.resumes)
                    assertEquals(2, f.nativeMode)
                }
            }
        }
    }

    @Test fun postedActionRecomputesOwnershipBeforeResuming() {
        val f = Fixture()
        f.mode(2)
        f.boundary()
        f.items = mutableListOf(f.item(null))
        f.complete()
        assertEquals(2, f.nativeMode)
        assertFalse(f.pauseAtEnd)
        assertEquals(1, f.resumes)
    }

    @Test fun staleOccurrenceAndExplicitPauseCannotResume() {
        for (pause in listOf(false, true)) {
            val f = Fixture()
            f.mode(1)
            f.boundary()
            if (pause) bridgeClass.getMethod("pause").invoke(f.bridge)
            f.mode(2)
            f.complete(if (pause) f.uid else Any())
            assertEquals(0, f.resumes)
            assertTrue(f.seeks.isEmpty())
        }
    }

    @Test fun replacedOccurrenceInvalidatesThePostedBoundary() {
        val f = Fixture()
        f.mode(1)
        f.boundary()
        f.currentUid = Any()
        f.call("cancelRepeatIfItemChanged")
        f.complete()
        assertEquals(0, f.resumes)
        assertTrue(f.seeks.isEmpty())
        assertEquals(false, f.field("repeatPending"))
    }

    @Test fun oldCallbackCannotConsumeANewerPlayBoundary() {
        val f = Fixture()
        f.mode(1)
        f.boundary()
        bridgeClass.getMethod("pause").invoke(f.bridge)
        put(f.bridge, "repeatPending", true)
        bridgeClass.getMethod("play", Class.forName("io.flutter.plugin.common.MethodChannel\$Result"))
            .invoke(f.bridge, null)
        f.complete(revision = 0L)
        assertEquals(true, f.field("repeatPending"))
        f.complete(revision = 1L)
        assertEquals(listOf(0), f.seeks)
        assertEquals(1, f.resumes)
    }

    @Test fun lateEndReasonCannotRearmAConsumedBoundary() {
        val f = Fixture()
        f.mode(1)
        f.boundary()
        f.complete()
        f.endReason()
        assertEquals(false, f.field("repeatPending"))
        assertEquals(1, f.resumes)
    }

    @Test fun offAtTrueEndDoesNotRestart() {
        val f = Fixture()
        f.mode(2)
        f.boundary()
        f.items = mutableListOf(f.item(null))
        f.ended = true
        f.mode(0)
        f.complete()
        assertEquals("play was requested: playWhenReady must be restored", true, f.playing)
        assertEquals(1, f.resumes)
        assertTrue(f.seeks.isEmpty())
        assertEquals(false, f.field("repeatPending"))
        assertEquals("completed", f.field("processingState").toString())
    }

    @Test fun lateEndedCallbackAfterReleasingOwnershipCannotPublishCompletion() {
        val f = Fixture()
        f.mode(2)
        f.boundary()
        f.items = mutableListOf(f.item(null))
        f.complete()
        f.endedCallback()
        assertEquals("ready", f.field("processingState").toString())
        assertEquals(1, f.resumes)
    }
}
