package com.navis.app.navis

import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Method
import java.lang.reflect.Proxy
import org.junit.Assert.*
import org.junit.Test
import sun.misc.Unsafe

/**
 * Callback-order regressions. The real bridge is driven through the same
 * Unsafe/reflection/proxy pattern as JustAudioRepeatBoundaryTest, but with:
 *  - one distinct timeline-window UID per queue item,
 *  - the production scheduling path (the missing Handler throws an NPE at `handler.post`, which is
 *    caught and recorded as the posted (uid, revision) action, run later by runPosts()),
 *  - re-entrant ExoPlayer-style synchronous listener dispatch for setPlayWhenReady()/seekTo(),
 *  - an app-visible getPlayWhenReady() that lags the playback thread's native pause until
 *    deliverPause() (what Media3 1.4.1 does: ExoPlayerImpl.getPlayWhenReady() reads playbackInfo).
 */
class JustAudioRepeatCallbackTest {
    private val unsafe = Unsafe::class.java.getDeclaredField("theUnsafe").let {
        it.isAccessible = true; it.get(null) as Unsafe
    }
    private val bridgeClass = Class.forName("com.ryanheise.just_audio.AudioPlayer")
    private val resultClass = Class.forName("io.flutter.plugin.common.MethodChannel\$Result")
    private val exoClass = Class.forName("androidx.media3.exoplayer.ExoPlayer")

    private fun put(target: Any, name: String, value: Any?) {
        target.javaClass.getDeclaredField(name).apply { isAccessible = true }.set(target, value)
    }

    class Post(val uid: Any, val revision: Long)

    inner class Fx(kinds: String, startIndex: Int, mode: Int) {
        val bridge: Any = unsafe.allocateInstance(bridgeClass)
        val tag = "probe-stream"
        val items = mutableListOf<Any>()
        val kindList = mutableListOf<Char>()
        val uids = mutableListOf<Any>()
        var index = startIndex
        var nativeMode = -1
        var pauseAtEnd = false
        var playing = true          // app-visible getPlayWhenReady()
        var ended = false           // app-visible getPlaybackState() == ENDED
        var resumes = 0             // setPlayWhenReady(true) calls that changed state
        val seeks = mutableListOf<String>()
        val posts = ArrayDeque<Post>()
        val log = mutableListOf<String>()

        private fun newItem(kind: Char): Any {
            val itemClass = Class.forName("androidx.media3.common.MediaItem")
            val item = unsafe.allocateInstance(itemClass)
            if (kind == 'S') {
                val config = unsafe.allocateInstance(Class.forName("androidx.media3.common.MediaItem\$LocalConfiguration"))
                put(config, "tag", tag)
                put(item, "localConfiguration", config)
            }
            return item
        }

        private fun timeline(): Any {
            val windowClass = Class.forName("androidx.media3.common.Timeline\$Window")
            val windows = uids.map { u -> unsafe.allocateInstance(windowClass).also { put(it, "uid", u) } }
            val immutable = Class.forName("com.google.common.collect.ImmutableList")
            val timeline = unsafe.allocateInstance(Class.forName("androidx.media3.common.Timeline\$RemotableTimeline"))
            put(timeline, "windows", immutable.getMethod("copyOf", Collection::class.java).invoke(null, windows))
            return timeline
        }

        val exo: Any = Proxy.newProxyInstance(exoClass.classLoader, arrayOf(exoClass)) { _, m, a ->
            when (m.name) {
                "getMediaItemCount" -> items.size
                "getMediaItemAt" -> items[a[0] as Int]
                "getCurrentMediaItemIndex" -> index
                "getCurrentTimeline" -> timeline()
                "setRepeatMode" -> { nativeMode = a[0] as Int; log.add("repeatMode(${a[0]})"); null }
                "setPauseAtEndOfMediaItems" -> {
                    val v = a[0] as Boolean
                    if (v != pauseAtEnd) { pauseAtEnd = v; log.add("pauseAtEnd($v)") }  // ExoPlayerImpl dedups
                    null
                }
                "getPlayWhenReady" -> playing
                "getPlaybackState" -> if (ended) 4 else 3
                "setPlayWhenReady" -> {
                    val v = a[0] as Boolean
                    if (v != playing) {
                        playing = v
                        if (v) resumes++
                        log.add("playWhenReady($v)")
                        dispatch { call("onPlayWhenReadyChanged", v, 1) }      // USER_REQUEST, synchronous
                    }
                    null
                }
                "seekTo" -> {
                    val to = a[0] as Int
                    val changed = to != index
                    index = to; ended = false
                    seeks.add("$to@${a[1]}"); log.add("seekTo($to,${a[1]})")
                    dispatch { call("onPositionDiscontinuity", null, null, 1) }  // SEEK
                    if (changed) dispatch { call("onMediaItemTransition", null, 2) }  // SEEK
                    null
                }
                "hasNextMediaItem" -> index < items.size - 1
                "seekToNextMediaItem" -> {
                    index += 1; ended = false; seeks.add("$index@next"); log.add("seekToNext")
                    null
                }
                "getCurrentPosition", "getBufferedPosition", "getDuration" -> 10_000L
                else -> throw AssertionError("Unexpected native call: ${m.name}")
            }
        }

        init {
            for (k in kinds) addLocal(k)
            put(bridge, "player", exo)
            put(bridge, "progressiveHttpSources", hashSetOf(tag))
            put(bridge, "playRequested", true)
            val state = Class.forName("com.ryanheise.just_audio.AudioPlayer\$ProcessingState")
            put(bridge, "processingState", state.enumConstants.first { it.toString() == "ready" })
            put(bridge, "eventChannel", unsafe.allocateInstance(Class.forName("com.ryanheise.just_audio.BetterEventChannel")))
            put(bridge, "lastPlaylistLength", items.size)
            mode(mode)
        }

        private fun addLocal(k: Char) { items.add(newItem(k)); kindList.add(k); uids.add(Any()) }

        // ---- reflection helpers
        private fun find(name: String, arity: Int): Method =
            (bridgeClass.methods.toList() + bridgeClass.declaredMethods.toList())
                .first { it.name == name && it.parameterCount == arity }.also { it.isAccessible = true }

        fun call(name: String, vararg args: Any?) { find(name, args.size).invoke(bridge, *args) }
        fun field(name: String): Any? = bridgeClass.declaredFields.firstOrNull { it.name == name }?.apply { isAccessible = true }?.get(bridge)

        /** Runs one app/native-thread entry; records the production handler.post as a Post. */
        fun dispatch(block: () -> Unit) {
            try { block() } catch (e: InvocationTargetException) {
                val c = e.cause
                if (c is NullPointerException && c.stackTrace.firstOrNull()?.methodName == "scheduleProgressiveRepeat") {
                    val uid = field("repeatAtEndUid")
                        ?: throw AssertionError("an empty timeline must not schedule a repeat post")
                    posts.addLast(Post(uid, field("repeatRevision") as Long))
                    log.add("post(rev=${field("repeatRevision")})")
                } else throw (c ?: e)
            }
        }

        // ---- app-thread operations
        fun mode(m: Int) = dispatch { call("setLoopMode", m) }
        fun timelineChanged() {
            dispatch { call("onTimelineChanged", timeline(), 0) }
            put(bridge, "lastPlaylistLength", items.size)
        }
        fun removeAt(i: Int) {
            items.removeAt(i); kindList.removeAt(i); uids.removeAt(i)
            if (i < index) index -= 1
            timelineChanged()
        }
        fun insert(i: Int, k: Char) {
            items.add(i, newItem(k)); kindList.add(i, k); uids.add(i, Any())
            if (i <= index) index += 1
            timelineChanged()
        }
        fun append(k: Char) = insert(items.size, k)
        fun pause() = dispatch { call("pause") }
        fun play() = dispatch { call("play", null) }
        fun seek(posMs: Long, idx: Int?) = dispatch { call("seek", posMs, idx, null) }

        // ---- playback-thread update reaching the app thread (ExoPlayer order: state, then playWhenReady)
        fun deliverPause(isEnded: Boolean) {
            playing = false
            ended = isEnded
            if (isEnded) dispatch { call("onPlaybackStateChanged", 4) }
            dispatch { call("onPlayWhenReadyChanged", false, 5) }   // END_OF_MEDIA_ITEM
        }

        fun runPosts() {
            var n = 0
            while (posts.isNotEmpty()) {
                val p = posts.removeFirst()
                dispatch { call("completeProgressiveRepeat", p.uid, p.revision) }
                if (++n > 20) fail("post storm: $log")
            }
        }

        fun state() = field("processingState").toString()
        fun digest() = "resumes=$resumes seeks=$seeks state=${state()} pending=${field("repeatPending")} " +
            "atEnd=${field("repeatAtEndUid") != null} pauseUid=${field("repeatPauseUid") != null} " +
            "native=$nativeMode pauseAtEnd=$pauseAtEnd playing=$playing posts=${posts.size} log=$log"
    }

    private fun report(name: String, f: Fx) = println("PROBE $name :: ${f.digest()}")

    // ---------------------------------------------------------------- G1: late pause reason
    /** Mode switch is processed on the app thread before the native pause is delivered. */
    @Test fun g1a_oneToOff_middle_latePauseReason() {
        val f = Fx("SFF", 0, 1)
        f.mode(0)                 // user taps Repeat Off; getPlayWhenReady() is still true
        f.deliverPause(false)     // ExoPlayer had already paused at the end of item 0
        f.runPosts()
        report("g1a", f)
        assertEquals("OFF must release the already-paused middle boundary exactly once: ${f.digest()}", 1, f.resumes)
        assertTrue("no restart expected: ${f.digest()}", f.seeks.isEmpty())
    }

    @Test fun g1b_oneToAll_middle_latePauseReason() {
        val f = Fx("SFF", 0, 1)
        f.mode(2)
        f.deliverPause(false)
        f.runPosts()
        report("g1b", f)
        assertEquals(f.digest(), 1, f.resumes)
        assertTrue(f.digest(), f.seeks.isEmpty())
    }

    /** Top-level removeMediaItems is an app-thread API: timeline callback precedes the late pause. */
    @Test fun g1c_removeLastStream_lastFile_ALL_latePauseReason() {
        val f = Fx("SF", 1, 2)
        f.removeAt(0)             // app thread; getPlayWhenReady() still true
        f.deliverPause(true)      // late END_OF_MEDIA_ITEM + STATE_ENDED
        f.runPosts()
        report("g1c", f)
        assertEquals("ALL must wrap exactly once: ${f.digest()}", listOf("0@0"), f.seeks)
        assertEquals(f.digest(), 1, f.resumes)
        assertNotEquals("Repeat All must not publish completed: ${f.digest()}", "completed", f.state())
    }

    /** Nested playlist: the removal rides in the playback-thread batch [timeline, ENDED, END reason]. */
    @Test fun g1d_removeLastStream_sameBatch_timelineBeforeReason() {
        val f = Fx("SF", 1, 2)
        f.playing = false; f.ended = true            // already applied to the app-visible playbackInfo
        f.removeAt(0)                                // onTimelineChanged first
        f.call("onPlaybackStateChanged", 4)
        f.call("onPlayWhenReadyChanged", false, 5)
        f.runPosts()
        report("g1d", f)
        assertEquals(f.digest(), listOf("0@0"), f.seeks)
        assertEquals(f.digest(), 1, f.resumes)
        assertNotEquals(f.digest(), "completed", f.state())
    }

    // ---------------------------------------------------------------- G2: reason first, then change, then post
    @Test fun g2_matrix_reasonFirst_thenChange() {
        val fails = mutableListOf<String>()
        for (initial in listOf(1, 2)) {
            for (queue in listOf("SFF", "FSF", "FFS", "SS", "S", "SF")) {
                for (idx in queue.indices) {
                    val last = idx == queue.length - 1
                    if (initial == 2 && (!last || 'S' !in queue)) continue   // ALL pauses only at the last item of an owned playlist
                    if (initial == 1 && queue[idx] != 'S') continue         // ONE owns only an eligible current item
                    for (newMode in listOf(0, 1, 2)) {
                        val f = Fx(queue, idx, initial)
                        f.deliverPause(last)
                        f.mode(newMode)
                        f.runPosts()
                        // oracle: latest mode, current item, ended only at the last item
                        val expSeeks: List<String>
                        val expResumes: Int
                        if (newMode == 1) { expSeeks = listOf("$idx@0"); expResumes = 1 }
                        else if (last) {
                            if (newMode == 2) { expSeeks = listOf("0@0"); expResumes = 1 }
                            else { expSeeks = emptyList(); expResumes = 0 }
                        } else { expSeeks = emptyList(); expResumes = 1 }
                        val ok = f.seeks == expSeeks && f.resumes == expResumes &&
                            (!(newMode == 0 && last) || f.state() == "completed")
                        if (!ok) fails.add("queue=$queue idx=$idx initial=$initial new=$newMode -> ${f.digest()} exp=$expSeeks/$expResumes")
                    }
                }
            }
        }
        println("PROBE g2 fails=${fails.size}")
        fails.forEach { println("PROBE g2 FAIL $it") }
        assertTrue(fails.joinToString("\n"), fails.isEmpty())
    }

    @Test fun g2b_reasonFirst_thenRemovalAndMaybeAppend() {
        val fails = mutableListOf<String>()
        for (append in listOf(false, true)) {
            for (removeFirst in listOf(false, true)) {
                val f = Fx("SF", 1, 2)
                f.deliverPause(true)
                if (!removeFirst && append) f.append('F')
                f.removeAt(0)
                if (removeFirst && append) f.append('F')
                f.runPosts()
                val exp = if (append) listOf("1@0") else listOf("0@0")
                if (f.seeks != exp || f.resumes != 1) fails.add("append=$append removeFirst=$removeFirst -> ${f.digest()} exp=$exp")
            }
        }
        println("PROBE g2b fails=${fails.size}")
        fails.forEach { println("PROBE g2b FAIL $it") }
        assertTrue(fails.joinToString("\n"), fails.isEmpty())
    }

    // ---------------------------------------------------------------- G3: pause / play
    @Test fun g3a_pauseCancelsPostedAction() {
        val f = Fx("SFF", 0, 1)
        f.deliverPause(false)
        f.pause()
        f.runPosts()
        report("g3a", f)
        assertEquals(f.digest(), 0, f.resumes)
        assertTrue(f.digest(), f.seeks.isEmpty())
    }

    @Test fun g3b_pause_modeOff_play_resumesOnceWithoutRestart() {
        val f = Fx("SFF", 0, 1)
        f.deliverPause(false)
        f.pause()
        f.mode(0)
        f.play()
        f.runPosts()
        report("g3b", f)
        assertEquals(f.digest(), 1, f.resumes)
        assertTrue(f.digest(), f.seeks.isEmpty())
    }

    @Test fun g3c_pause_modeAll_play_resumesOnce() {
        val f = Fx("SFF", 0, 1)
        f.deliverPause(false)
        f.pause()
        f.mode(2)
        f.play()
        f.runPosts()
        report("g3c", f)
        assertEquals(f.digest(), 1, f.resumes)
        assertTrue(f.digest(), f.seeks.isEmpty())
    }

    /** Pause lands before the native pause is delivered (no reason is ever delivered afterwards). */
    @Test fun g3d_pauseBeforeDelivery_thenPlayWithoutBoundaryEvidenceResumes() {
        val f = Fx("SFF", 0, 1)
        f.pause()                 // app-visible playWhenReady true -> false; internal player is already paused at the end
        f.play()
        f.runPosts()
        report("g3d", f)
        // No boundary signal distinguishes this from an ordinary in-item Pause/Play.
        assertTrue(f.digest(), f.seeks.isEmpty())
        assertEquals(f.digest(), 1, f.resumes)
    }

    @Test fun g3e_pausedBoundary_modeFlipsDoNotResume() {
        val f = Fx("SFF", 0, 1)
        f.deliverPause(false)
        f.pause()
        f.mode(0); f.mode(2); f.mode(1)
        f.runPosts()
        report("g3e", f)
        assertEquals(f.digest(), 0, f.resumes)
        assertTrue(f.digest(), f.seeks.isEmpty())
    }

    @Test fun g3f_pauseThenPlay_rearmsExactlyOnePost() {
        val f = Fx("SFF", 0, 1)
        f.deliverPause(false)
        f.pause()
        f.play()
        f.runPosts()
        report("g3f", f)
        assertEquals(f.digest(), listOf("0@0"), f.seeks)
        assertEquals(f.digest(), 1, f.resumes)
    }

    // ---------------------------------------------------------------- G4: seek
    @Test fun g4a_seekAfterModeOff_resumesAtPosition() {
        val f = Fx("SFF", 0, 1)
        f.deliverPause(false)
        f.mode(0)
        f.seek(5000, null)
        f.runPosts()
        report("g4a", f)
        assertEquals(f.digest(), listOf("0@5000"), f.seeks)
        assertEquals(f.digest(), 1, f.resumes)
    }

    @Test fun g4b_seekBeforeDelivery_canBeOverwrittenByLateEnd() {
        val f = Fx("SFF", 0, 1)
        f.seek(5000, null)        // user seeks inside the same item right before the native pause is delivered
        f.deliverPause(false)
        f.runPosts()
        report("g4b", f)
        // A late old end signal is indistinguishable from a fresh natural end after the seek.
        assertEquals(f.digest(), listOf("0@5000", "0@0"), f.seeks)
    }

    @Test fun g4c_selectNextSongAtBoundary() {
        val f = Fx("SSF", 0, 1)
        f.deliverPause(false)
        f.seek(0, 1)
        f.runPosts()
        report("g4c", f)
        assertEquals(f.digest(), listOf("1@0"), f.seeks)
        assertEquals(f.digest(), 1, f.resumes)
    }

    // ---------------------------------------------------------------- G6: ownership regained / flips
    @Test fun g6a_ownershipLostThenRegained_beforePost() {
        val f = Fx("SF", 1, 2)
        f.deliverPause(true)
        f.removeAt(0)
        f.insert(0, 'S')
        f.runPosts()
        report("g6a", f)
        assertEquals(f.digest(), listOf("0@0"), f.seeks)
        assertEquals(f.digest(), 1, f.resumes)
        assertEquals("owned again: native repeat must be OFF", 0, f.nativeMode)
    }

    @Test fun g6b_ownershipLost_nativeRepeatRestored() {
        val f = Fx("SF", 1, 2)
        f.deliverPause(true)
        f.removeAt(0)
        f.runPosts()
        report("g6b", f)
        assertEquals("file-only ALL must hand repeat back to Media3", 2, f.nativeMode)
        assertFalse(f.digest(), f.pauseAtEnd)
    }

    @Test fun g6c_modeFlipsAtBoundary_leaveNoStaleOwnership() {
        // ONE -> OFF -> ONE -> ALL before the post: one resume, no restart for middle item
        val f = Fx("SFF", 0, 1)
        f.deliverPause(false)
        f.mode(0); f.mode(1); f.mode(2)
        f.runPosts()
        report("g6c", f)
        assertEquals(f.digest(), 1, f.resumes)
        assertTrue(f.digest(), f.seeks.isEmpty())
        assertFalse("ALL on a middle item must not leave the end-pause armed", f.pauseAtEnd)
    }

    // ---------------------------------------------------------------- G7: repeated loops
    @Test fun g7_repeatOneLoopsThreeTimes() {
        val f = Fx("SF", 0, 1)
        for (cycle in 1..3) {
            f.deliverPause(false)
            f.runPosts()
            assertEquals("cycle $cycle: ${f.digest()}", cycle, f.resumes)
            assertEquals("cycle $cycle: ${f.digest()}", cycle, f.seeks.size)
            assertTrue("cycle $cycle repeatPauseUid must be re-armed after resume: ${f.digest()}",
                f.field("repeatPauseUid") != null)
        }
        report("g7", f)
    }

    @Test fun g7b_repeatAllWrapsThreeTimes_singleStream() {
        val f = Fx("S", 0, 2)
        for (cycle in 1..3) {
            f.deliverPause(true)
            f.runPosts()
            assertEquals("cycle $cycle: ${f.digest()}", cycle, f.resumes)
            assertEquals("cycle $cycle: ${f.digest()}", cycle, f.seeks.size)
        }
        report("g7b", f)
    }

    // ---------------------------------------------------------------- G8: misc
    @Test fun g8a_sameModeAtBoundary_isHarmless() {
        val f = Fx("SFF", 0, 1)
        f.deliverPause(false)
        f.mode(1); f.mode(1)
        f.runPosts()
        report("g8a", f)
        assertEquals(f.digest(), listOf("0@0"), f.seeks)
        assertEquals(f.digest(), 1, f.resumes)
    }

    @Test fun g8b_inactiveDeckModeFlips_neverResume() {
        val f = Fx("SFF", 0, 0)
        f.playing = false
        put(f.bridge, "playRequested", false)
        f.mode(1); f.mode(2); f.mode(0); f.mode(2); f.mode(1)
        f.runPosts()
        report("g8b", f)
        assertEquals(f.digest(), 0, f.resumes)
        assertTrue(f.digest(), f.seeks.isEmpty())
        assertTrue(f.digest(), f.posts.isEmpty())
    }

    @Test fun g8c_allToOneAtLastFile_restartsTheFile() {
        val f = Fx("SF", 1, 2)
        f.deliverPause(true)
        f.mode(1)
        f.runPosts()
        report("g8c", f)
        assertEquals("ONE on a file hands repeat back to Media3", 1, f.nativeMode)
        assertEquals(f.digest(), listOf("1@0"), f.seeks)
        assertEquals(f.digest(), 1, f.resumes)
    }

    @Test fun g8d_staleEndedCallback_fileOnly_delta() {
        // behaviour delta vs base: an ENDED callback while getPlaybackState() != ENDED
        val f = Fx("FF", 1, 0)
        f.call("onPlaybackStateChanged", 4)     // ended=false in the fixture (stale callback)
        report("g8d", f)
        assertEquals("ready", f.state())
    }

    @Test fun g8e_fileOnly_ended_publishesCompleted() {
        val f = Fx("FF", 1, 0)
        f.ended = true
        f.call("onPlaybackStateChanged", 4)
        report("g8e", f)
        assertEquals("completed", f.state())
    }

    @Test fun g8f_lateEndedAfterWrapConsumed_noCompletion() {
        val f = Fx("SF", 1, 2)
        f.deliverPause(true)
        f.runPosts()                              // wrap consumed, player running again
        f.call("onPlaybackStateChanged", 4)       // stray ENDED
        report("g8f", f)
        assertNotEquals(f.digest(), "completed", f.state())
    }

    @Test fun g8g_offAtTrueEnd_afterBoundary_completes() {
        val f = Fx("SF", 1, 2)
        f.deliverPause(true)
        f.mode(0)
        f.runPosts()
        report("g8g", f)
        assertEquals("completed", f.state())
        assertNull("consuming an Off boundary must clear its old pause owner", f.field("repeatPauseUid"))
        assertEquals(f.digest(), 0, f.resumes)
        assertTrue(f.digest(), f.seeks.isEmpty())
    }

    // ---------------------------------------------------------------- G9: retention of the pause-policy UID
    /** Any in-item scrub clears repeatPauseUid (seek()) and nothing re-arms it for a same-index seek. */
    @Test fun g9a_scrubThenRemoveLastStream_sameBatch() {
        val f = Fx("SF", 1, 2)
        f.seek(5000, null)                       // scrub inside the pause-armed last item while playing
        assertSame("an in-item scrub must re-arm its pause owner", f.uids[1], f.field("repeatPauseUid"))
        f.playing = false; f.ended = true        // nested-playlist batch: [timeline, ENDED, END reason]
        f.removeAt(0)
        f.call("onPlaybackStateChanged", 4)
        f.call("onPlayWhenReadyChanged", false, 5)
        f.runPosts()
        report("g9a", f)
        assertEquals("ALL must still wrap exactly once after a scrub: ${f.digest()}", 1, f.resumes)
        assertNotEquals(f.digest(), "completed", f.state())
    }

    @Test fun g3g_pause_removeStream_play_wrapsOnce() {
        val f = Fx("SF", 1, 2)
        f.deliverPause(true)
        f.pause()
        f.removeAt(0)
        f.play()
        f.runPosts()
        report("g3g", f)
        assertEquals(f.digest(), listOf("0@0"), f.seeks)
        assertEquals(f.digest(), 1, f.resumes)
    }

    @Test fun g9b_scrubKeepsPauseUidForOrdinaryReasonFirstFlow() {
        val f = Fx("SFF", 0, 1)
        f.seek(5000, null)
        f.deliverPause(false)
        f.runPosts()
        report("g9b", f)
        assertEquals(f.digest(), listOf("0@5000", "0@0"), f.seeks)   // scrub, then the Repeat One restart
        assertEquals(f.digest(), 1, f.resumes)
    }

    @Test fun policyTransitionClearsThePreviousPauseOwner() {
        val f = Fx("SF", 0, 1)
        assertSame(f.uids[0], f.field("repeatPauseUid"))
        f.index = 1
        f.call("onMediaItemTransition", null, 2)
        assertNull(f.field("repeatPauseUid"))
        assertEquals(1, f.nativeMode)
        assertFalse(f.pauseAtEnd)
    }

    @Test fun seekWhilePausedClearsTheOldPauseOwner() {
        val f = Fx("SF", 0, 1)
        f.pause()
        f.seek(5000, 1)
        assertNull(f.field("repeatPauseUid"))
        assertFalse(f.playing)
        assertTrue(f.posts.isEmpty())
    }

    @Test fun nativePauseCancelsAnAlreadyPostedBoundary() {
        val f = Fx("SF", 0, 1)
        f.deliverPause(false)
        assertEquals(1, f.posts.size)
        f.call("onPlayWhenReadyChanged", false, 2)
        assertEquals(false, f.field("repeatPending"))
        f.runPosts()
        assertEquals(0, f.resumes)
    }

    @Test fun mediaItemTransitionInvalidatesTheOldPostedRevision() {
        val f = Fx("SS", 0, 1)
        f.deliverPause(false)
        val oldRevision = f.field("repeatRevision") as Long
        f.index = 1
        f.call("onMediaItemTransition", null, 2)
        assertEquals(false, f.field("repeatPending"))
        assertEquals(oldRevision + 1, f.field("repeatRevision"))
        f.runPosts()
        assertTrue(f.seeks.isEmpty())
        assertEquals(0, f.resumes)
    }

    @Test fun emptyTimelinePublishesCompletionWithoutPostingRepeat() {
        val f = Fx("S", 0, 2)
        f.items.clear()
        f.kindList.clear()
        f.uids.clear()
        f.index = -1
        f.deliverPause(true)
        f.runPosts()
        assertEquals("completed", f.state())
        assertEquals(0, f.resumes)
        assertTrue(f.seeks.isEmpty())
        assertTrue(f.posts.isEmpty())
    }
    // Current-occurrence removal and repeat-boundary regression coverage.
    /** ExoPlayerImpl.removeMediaItems(current): timeline, discontinuity(REMOVE), transition(PLAYLIST_CHANGED), [ENDED]. */
    private fun Fx.removeCurrent(i: Int, newIndex: Int, toEnded: Boolean) {
        items.removeAt(i); kindList.removeAt(i); uids.removeAt(i)
        index = newIndex
        if (toEnded) ended = true
        timelineChanged()
        dispatch { call("onPositionDiscontinuity", null, null, 4) }
        dispatch { call("onMediaItemTransition", null, 3) }
        if (toEnded) dispatch { call("onPlaybackStateChanged", 4) }
    }

    /** D1 (regression vs base): removing the CURRENT occurrence after its boundary was delivered, another stream remains. */
    @Test fun d1_removeCurrentStreamAtDeliveredBoundary_remainingStreamResumes() {
        val f = Fx("SS", 1, 1)
        f.deliverPause(true)                  // last item ended: native pause + ENDED delivered, post captured
        f.removeCurrent(1, 0, toEnded = false) // already ENDED: state unchanged, current becomes item 0
        f.runPosts()
        report("d1", f)
        assertEquals("the remaining stream must be restarted exactly once: ${f.digest()}", listOf("0@0"), f.seeks)
        assertEquals(f.digest(), 1, f.resumes)
    }

    /** D1b: same, queue becomes file-only (ALL); base un-ends, HEAD leaves ENDED with completion unpublished. */
    @Test fun d1b_removeCurrentLastStreamAtDeliveredBoundary_fileOnly_notStuckEndedAndUnpublished() {
        val f = Fx("FS", 1, 2)
        f.deliverPause(true)
        f.removeCurrent(1, 0, toEnded = false)
        f.runPosts()
        report("d1b", f)
        assertTrue("ENDED must be published or the engine must be restarted: ${f.digest()}",
            f.state() == "completed" || f.resumes == 1)
    }

    /** D3 (delta regression): user Pause mid-song, remove the CURRENT last stream, tail removal ends the engine. */
    @Test fun d3_pausedRemoveCurrentLastStream_legacyRecoveryRewindsTheRemainingItem() {
        val f = Fx("FS", 1, 2)
        f.pause()
        f.removeCurrent(1, 0, toEnded = true)
        report("d3", f)
        assertEquals("paused ENDED after a tail removal must rewind like any file queue: ${f.digest()}", listOf("0@0"), f.seeks)
    }

    /** D2: Off + last item + engine NOT ended (scrub moved it off the end): the paused boundary must be released. */
    @Test fun d2_offAtLastItemEngineNotEnded_releasesTheBoundary() {
        val f = Fx("S", 0, 2)
        f.seek(5000, null)
        f.mode(0)
        f.deliverPause(false)                 // late END_OF_MEDIA_ITEM after the scrub and Off
        f.runPosts()
        report("d2", f)
        assertEquals("playback must continue from the scrub: ${f.digest()}", 1, f.resumes)
        assertEquals(f.digest(), listOf("0@5000"), f.seeks)
        assertTrue(f.playing)
    }

    // ---- surviving-mutant gap tests (all pass on HEAD; each is killed by the named mutant)
    /** C4: completeProgressiveRepeat must clear repeatAtEndUid, else Pause/Play mid-item replays the consumed boundary. */
    @Test fun gap_c4_consumedBoundaryIsNotReplayedByPauseThenPlay() {
        val f = Fx("SFF", 0, 1)
        f.deliverPause(false); f.runPosts()
        assertEquals(listOf("0@0"), f.seeks)
        f.pause(); f.play(); f.runPosts()
        assertEquals(f.digest(), listOf("0@0"), f.seeks)
    }

    /** K4: seek() must cancel the pending post, else a same-item scrub at a pending Repeat One boundary is overwritten. */
    @Test fun gap_k4_scrubAtPendingRepeatOneBoundaryIsNotOverwrittenByTheStalePost() {
        val f = Fx("SFF", 0, 1)
        f.deliverPause(false)
        f.seek(5000, null)
        f.runPosts()
        assertEquals(f.digest(), listOf("0@5000"), f.seeks)
    }

    /** L3: onTimelineChanged itself must restore the native repeat policy (no boundary needed). */
    @Test fun gap_l3_timelineCallbackRestoresNativePolicyWhenLastStreamIsRemoved() {
        val f = Fx("SF", 1, 2)
        assertEquals(0, f.nativeMode)
        f.removeAt(0)
        assertEquals(f.digest(), 2, f.nativeMode)
        assertFalse(f.digest(), f.pauseAtEnd)
    }

    /** U6: an owned Repeat One item must arm the native end pause (never asserted by the committed tests). */
    @Test fun gap_u6_repeatOneOnEligibleItemArmsNativeEndPause() {
        val f = Fx("SFF", 0, 1)
        assertEquals(0, f.nativeMode)
        assertTrue(f.digest(), f.pauseAtEnd)
        val g = Fx("FSF", 2, 2)       // ALL owned by the playlist, pause only on the last item
        assertTrue(g.digest(), g.pauseAtEnd)
        val h = Fx("SFF", 1, 2)       // ALL owned, middle item: no end pause
        assertFalse(h.digest(), h.pauseAtEnd)
    }
}
