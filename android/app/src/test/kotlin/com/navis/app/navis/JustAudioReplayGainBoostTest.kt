package com.navis.app.navis

import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Proxy
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Test
import sun.misc.Unsafe

/**
 * ReplayGain boost on Android: the processor stage and the bridge's native
 * lowering before any command that can change which song plays next. The real
 * vendored classes run, with no Looper, audio device or media3 player.
 */
class JustAudioReplayGainBoostTest {
    private val unsafe = Unsafe::class.java.getDeclaredField("theUnsafe").let {
        it.isAccessible = true
        it.get(null) as Unsafe
    }
    private val bridgeClass = Class.forName("com.ryanheise.just_audio.AudioPlayer")
    private val processorClass = Class.forName("com.ryanheise.just_audio.NavisEqualizerProcessor")
    private val formatClass = Class.forName("androidx.media3.common.audio.AudioProcessor\$AudioFormat")
    private val sixDb = 20 * Math.log10(2.0)

    private fun put(target: Any, name: String, value: Any?) {
        target.javaClass.getDeclaredField(name).apply { isAccessible = true }.set(target, value)
    }

    private fun unwrap(block: () -> Any?): Any? = try {
        block()
    } catch (e: InvocationTargetException) {
        throw e.cause ?: e
    }

    // ---- processor

    private inner class Processor(
        eq: Map<String, Any?>? = null,
        val channels: Int = 1,
        configure: Boolean = true,
    ) {
        val raw: Any = processorClass.getDeclaredConstructor(Map::class.java)
            .apply { isAccessible = true }
            .newInstance(eq ?: mapOf(
                "enabled" to false, "autoHeadroom" to true, "preampDb" to 0.0, "filters" to emptyList<Any>(),
            ))

        private fun call(name: String, vararg types: Class<*>, args: Array<Any?> = emptyArray()): Any? =
            unwrap { method(name, *types).invoke(raw, *args) }

        // Public methods of a package-private class still need setAccessible.
        private fun method(name: String, vararg types: Class<*>) =
            (processorClass.methods.toList() + processorClass.declaredMethods.toList())
                .first { it.name == name && it.parameterTypes.contentEquals(types) }
                .apply { isAccessible = true }

        init {
            if (configure) configure()
        }

        fun configure() {
            val format = formatClass.getConstructor(Int::class.java, Int::class.java, Int::class.java)
                .newInstance(48000, channels, 2) // C.ENCODING_PCM_16BIT
            call("configure", formatClass, args = arrayOf(format))
            flush()
        }

        fun flush() { call("flush") }

        // ---- the in-pipeline ReplayGain stage (#392 phase 3)
        private val long = Long::class.javaPrimitiveType!!
        fun setLevels(levels: Map<String, Double>, live: Boolean = false) {
            call("setLevels", Map::class.java, Boolean::class.javaPrimitiveType!!, args = arrayOf(levels, live))
        }
        fun replaceLevels(levels: Map<String, Double>) { call("replaceLevels", Map::class.java, args = arrayOf(levels)) }
        fun noteSource(message: Map<String, Any?>) { call("noteSource", Map::class.java, args = arrayOf(message)) }
        fun commitSources(replace: Boolean) {
            call("commitSources", Boolean::class.javaPrimitiveType!!, args = arrayOf(replace))
        }
        /** The renderer's onStreamChanged: [offsetUs] belongs to the song tagged [key]. */
        fun stream(offsetUs: Long, key: String?) { call("noteStream", long, String::class.java, args = arrayOf(offsetUs, key)) }
        /** The renderer's onOutputStreamOffsetUsChanged. */
        fun offset(offsetUs: Long) { call("streamOffsetChanged", long, args = arrayOf(offsetUs)) }
        fun appliedDb(): Double = (state()["replayGainAppliedDb"] as Number).toDouble()
        fun currentKey(): String? = state()["replayGainCurrentKey"] as String?
        fun reset() { call("reset") }
        fun setBoost(db: Double, guarded: Boolean) {
            call("setBoost", Double::class.javaPrimitiveType!!, Boolean::class.javaPrimitiveType!!,
                args = arrayOf(db, guarded))
        }
        fun lowerBoost() { call("lowerBoost") }
        fun requested(): Double = (processorClass.getDeclaredField("requestedBoostDb")
            .apply { isAccessible = true }.get(raw) as Number).toDouble()
        fun guarded(): Boolean = call("boostGuarded") as Boolean

        @Suppress("UNCHECKED_CAST")
        fun state(): Map<String, Any?> = call("state") as Map<String, Any?>

        /** Runs [samples] (interleaved) through queueInput and returns the output. */
        fun run(samples: ShortArray): ShortArray {
            val input = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.nativeOrder())
            samples.forEach { input.putShort(it) }
            input.flip()
            call("queueInput", ByteBuffer::class.java, args = arrayOf(input))
            val out = call("getOutput") as ByteBuffer
            val result = ShortArray(out.remaining() / 2)
            out.order(ByteOrder.nativeOrder())
            for (i in result.indices) result[i] = out.getShort()
            return result
        }

        fun constant(value: Int, frames: Int = 480) = run(ShortArray(frames * channels) { value.toShort() })
    }

    @Test fun boostIsAppliedAfterFlushWithTheEqualizerOff() {
        val p = Processor()
        p.setBoost(sixDb, false)
        p.flush() // a flush snaps: no ramp
        val out = p.constant(1000)
        assertTrue("every sample is doubled, got ${out.toList().distinct()}", out.all { it.toInt() == 2000 })
        assertEquals(sixDb, (p.state()["boostAppliedDb"] as Number).toDouble(), 0.001)
        assertEquals(0L, (p.state()["boostClipSamples"] as Number).toLong())
    }

    @Test fun boostRidesOutsideTheEqualizerAutoHeadroom() {
        // +6 dB preamp with auto-headroom is a net -0.5 dB: the bank must not eat the boost.
        val p = Processor(mapOf(
            "enabled" to true, "autoHeadroom" to true, "preampDb" to 6.0, "filters" to emptyList<Any>(),
        ))
        p.setBoost(sixDb, false)
        p.flush()
        val out = p.constant(1000)
        val expected = 1000 * Math.pow(10.0, -0.5 / 20) * 2
        assertTrue("EQ then boost: ${out.toList().distinct()}", out.all { Math.abs(it - expected) <= 1.0 })
    }

    @Test fun aRaiseRampsOverTwentyMillisecondsAndLinearly() {
        val p = Processor()
        p.setBoost(sixDb, false) // requested after the flush: a ramp
        val out = p.constant(1000, frames = 2000)
        assertTrue("first sample is barely raised", out[0] in 1000..1002)
        assertTrue("monotonic", (1 until out.size).all { out[it] >= out[it - 1] })
        assertEquals("960 frames (20 ms at 48 kHz) reach the target", 2000, out[959].toInt())
        assertEquals(2000, out[1999].toInt())
    }

    @Test fun samplesThatHitTheClampAreCountedOnlyWhileBoosting() {
        val boosted = Processor()
        boosted.setBoost(sixDb, false)
        boosted.flush()
        val out = boosted.constant(30000, frames = 100)
        assertTrue(out.all { it.toInt() == 32767 })
        assertEquals(100L, (boosted.state()["boostClipSamples"] as Number).toLong())

        val plain = Processor()
        assertEquals(100, plain.constant(32767, frames = 100).size)
        assertEquals("no boost, no count", 0L, (plain.state()["boostClipSamples"] as Number).toLong())
    }

    @Test fun flushSnapsToTheRequestedBoostAndKeepsIt() {
        val p = Processor()
        p.setBoost(sixDb, true)
        p.flush()
        assertTrue(p.constant(1000).all { it.toInt() == 2000 })
        p.flush()
        assertTrue("requested survives a flush", p.constant(1000).all { it.toInt() == 2000 })
        assertEquals(sixDb, p.requested(), 1e-9)
        assertTrue(p.guarded())
    }

    @Test fun loweringBeforeAFlushPlaysTheNextSongPlain() {
        val p = Processor()
        p.setBoost(sixDb, true)
        p.flush()
        p.lowerBoost()
        p.flush()
        assertTrue(p.constant(1000).all { it.toInt() == 1000 })
        assertEquals(0.0, p.requested(), 0.0)
    }

    @Test fun aRequestIsClampedToZeroAndTwelveDb() {
        val p = Processor()
        p.setBoost(40.0, false)
        p.flush()
        val out = p.constant(1000, frames = 10)
        assertEquals((1000 * Math.pow(10.0, 12.0 / 20)).toInt().toShort(), out[0])
        p.setBoost(-5.0, false)
        p.flush()
        assertTrue("a negative request never cuts", p.constant(1000).all { it.toInt() == 1000 })
    }

    @Test fun resetZeroesTheAppliedBoost() {
        val p = Processor()
        p.setBoost(sixDb, false)
        p.flush()
        p.constant(1000)
        p.reset()
        assertEquals(0.0, (p.state()["boostAppliedDb"] as Number).toDouble(), 0.0)
    }

    @Test fun stereoFramesShareOneGain() {
        val p = Processor(channels = 2)
        p.setBoost(sixDb, false)
        val out = p.run(ShortArray(2400) { 1000 })
        for (frame in 0 until 1200) assertEquals(out[frame * 2], out[frame * 2 + 1])
    }


    // ---- ReplayGain levels: the key switches inside the processor, on the A/B sample boundary

    private val tone = 10000
    private fun amp(db: Double) = Math.round(tone * Math.pow(10.0, db / 20)).toInt()

    /** Every sample of [out] is [tone] at [db] (one count of tolerance for rounding). */
    private fun assertGain(message: String, out: ShortArray, db: Double) {
        assertTrue("$message: expected ${amp(db)}, got ${out.toList().distinct().take(4)}",
            out.isNotEmpty() && out.all { Math.abs(it - amp(db)) <= 1 })
    }

    private val aOffset = 1_000_000_000_000L
    private val bOffset = aOffset + 15_000_000L

    /** A stage playing song "a" at -6 dB, "b" at -12 dB, "c" at +3 dB, steady since its first sample. */
    private fun playingA(): Processor {
        val p = Processor()
        p.replaceLevels(mapOf("a" to -6.0, "b" to -12.0, "c" to 3.0))
        p.stream(aOffset, "a")
        p.offset(aOffset) // the first song: no input yet, so its gain is there for sample 0
        assertGain("first song, first samples", p.constant(tone), -6.0)
        return p
    }

    @Test fun theFirstSongHasItsGainOnItsFirstSample() {
        val p = Processor()
        p.replaceLevels(mapOf("a" to -9.0))
        p.stream(aOffset, "a")
        p.offset(aOffset)
        val out = p.constant(tone, frames = 4)
        assertEquals("-9 dB scales by 0.355", 3548, out[0].toInt())
        assertGain("whole first buffer", out, -9.0)
        assertEquals("a", p.currentKey())
        assertEquals(-9.0, p.appliedDb(), 0.001)
    }

    @Test fun aTwoFlushJoinSwitchesAtTheFirstFlushAfterTheOffsetEvent() {
        val p = playingA()
        p.stream(bOffset, "b")
        p.offset(bOffset) // input has arrived since the last flush: wait for the flush
        assertGain("A's last samples after the offset event", p.constant(tone, frames = 700), -6.0)
        assertEquals("a", p.currentKey())
        p.flush() // flush #1 is the A/B boundary
        assertGain("B's first samples", p.constant(tone, frames = 2000), -12.0)
        assertEquals("b", p.currentKey())
        p.flush() // flush #2 carries no new key
        assertGain("later flush keeps B", p.constant(tone), -12.0)
        assertEquals("b", p.currentKey())
    }

    @Test fun aThreeFlushFormatChangeJoinKeepsTheNewKey() {
        val p = playingA()
        p.stream(bOffset, "b")
        p.offset(bOffset)
        assertGain("A drains to the AudioTrack", p.constant(tone, frames = 5000), -6.0)
        p.flush()
        assertGain("B after flush #1", p.constant(tone), -12.0)
        p.flush()
        p.flush()
        assertGain("B after flushes #2 and #3", p.constant(tone), -12.0)
        assertEquals("b", p.currentKey())
    }

    @Test fun speedOnePointFiveTailAfterTheOffsetEventStillGetsTheOutgoingGain() {
        val p = playingA()
        p.stream(bOffset, "b")
        p.offset(bOffset)
        // Sonic's 13-20 ms tail of A (567-981 frames at 44.1 kHz) arrives before flush #1.
        assertGain("tail", p.constant(tone, frames = 981), -6.0)
        assertEquals("the offset event alone changes nothing", "a", p.currentKey())
        p.flush()
        assertGain("B", p.constant(tone), -12.0)
    }

    @Test fun anExplicitSkipSnapsAtTheOffsetEventBecauseNoInputFollowedTheFlush() {
        val p = playingA()
        p.flush() // the skip flushes first, with A's partial frames
        p.stream(bOffset, "c")
        p.offset(bOffset) // no input since that flush
        assertGain("C's first samples, before the next flush", p.constant(tone, frames = 10), 3.0)
        p.flush() // the later flush with no new key
        assertGain("and after it", p.constant(tone), 3.0)
        assertEquals("c", p.currentKey())
    }

    @Test fun twoStreamChangesBeforeTheFirstOffsetChangeMapEachOffsetToItsOwnKey() {
        val p = playingA()
        p.stream(bOffset, "b")
        p.stream(bOffset + 15_000_000L, "c")
        p.offset(bOffset)
        p.constant(tone, frames = 10) // A's end
        p.flush()
        assertGain("B", p.constant(tone), -12.0)
        p.offset(bOffset + 15_000_000L)
        p.constant(tone, frames = 10) // B's end
        p.flush()
        assertGain("C", p.constant(tone), 3.0)
        assertEquals("c", p.currentKey())
    }

    @Test fun anOffsetNobodyNotedChangesNothing() {
        val p = playingA()
        p.offset(bOffset + 1)
        p.constant(tone, frames = 10)
        p.flush()
        assertGain("still A", p.constant(tone), -6.0)
    }

    @Test fun aFlushWithNoPendingKeyKeepsTheFrozenGainEvenAfterANonLiveMapChange() {
        val p = playingA()
        p.setLevels(mapOf("a" to -12.0)) // a tag correction: not live
        assertGain("the playing song is unchanged", p.constant(tone), -6.0)
        p.flush() // a seek inside the song
        assertGain("seek keeps it", p.constant(tone), -6.0)
        p.flush()
        assertGain("and again", p.constant(tone), -6.0)
        // The new value applies from the song's next start (a repeat-one wrap: same key, new stream).
        p.stream(bOffset, "a")
        p.offset(bOffset)
        p.constant(tone, frames = 10)
        p.flush()
        assertGain("next start", p.constant(tone), -12.0)
    }

    @Test fun aLiveUpdateRampsOverTwentyMilliseconds() {
        val p = playingA()
        p.setLevels(mapOf("a" to -12.0), live = true)
        val out = p.constant(tone, frames = 2000)
        assertTrue("starts near the old value, got ${out[0]}", out[0] in amp(-6.0) - 6..amp(-6.0))
        assertTrue("monotonic", (1 until out.size).all { out[it] <= out[it - 1] })
        assertEquals("960 frames (20 ms at 48 kHz) reach the target", amp(-12.0), out[959].toInt())
        assertTrue(out.drop(959).all { Math.abs(it - amp(-12.0)) <= 1 })
        assertEquals(-12.0, p.appliedDb(), 0.001)
    }

    @Test fun aLiveUpdateBeforeAFlushIsAppliedByThatFlushWithoutARamp() {
        val p = playingA()
        p.setLevels(mapOf("a" to -12.0), live = true)
        p.flush()
        assertGain("a seek after a settings change", p.constant(tone, frames = 5), -12.0)
    }

    @Test fun aNonLiveUpdateLeavesThePlayingGainAloneAndALaterStartUsesIt() {
        val p = playingA()
        p.setLevels(mapOf("b" to -3.0)) // merges: a is still known
        assertGain("a", p.constant(tone), -6.0)
        p.stream(bOffset, "b")
        p.offset(bOffset)
        p.constant(tone, frames = 5)
        p.flush()
        assertGain("b picked up the update", p.constant(tone), -3.0)
    }

    @Test fun anUnknownOrUntaggedKeyPlaysAtZeroDb() {
        val p = playingA()
        p.stream(bOffset, "nobody")
        p.offset(bOffset)
        p.constant(tone, frames = 5)
        p.flush()
        assertGain("unknown", p.constant(tone), 0.0)
        p.stream(bOffset + 1, null) // radio: an HLS source has no tag
        p.offset(bOffset + 1)
        p.constant(tone, frames = 5)
        p.flush()
        assertGain("untagged", p.constant(tone), 0.0)
        assertNull(p.currentKey())
    }

    @Test fun aBoostClampsAtTwelveDbAndCountsClips() {
        val p = Processor()
        p.replaceLevels(mapOf("loud" to 20.0))
        p.stream(aOffset, "loud")
        p.offset(aOffset)
        val out = p.constant(5000, frames = 10)
        assertTrue("+20 is clamped to +12 (5000 -> 19905), got ${out.toList()}", out.all { Math.abs(it - 19905) <= 1 })
        assertEquals(12.0, p.appliedDb(), 0.001)
        assertEquals(0L, (p.state()["boostClipSamples"] as Number).toLong())
        p.flush()
        assertTrue(p.constant(30000, frames = 100).all { it.toInt() == 32767 })
        assertEquals(100L, (p.state()["boostClipSamples"] as Number).toLong())
    }

    @Test fun aCutIsNotCountedAsClipping() {
        val p = Processor()
        p.replaceLevels(mapOf("quiet" to -6.0))
        p.stream(aOffset, "quiet")
        p.offset(aOffset)
        p.constant(32767, frames = 100)
        assertEquals(0L, (p.state()["boostClipSamples"] as Number).toLong())
    }

    @Test fun aRepeatOneWrapSnapsToTheSameValue() {
        val p = playingA()
        p.stream(bOffset, "a")
        p.offset(bOffset)
        assertGain("the tail", p.constant(tone, frames = 20), -6.0)
        p.flush()
        assertGain("the wrap", p.constant(tone), -6.0)
    }

    @Test fun theStageBeforeTheFirstConfigureHoldsTheKeyForTheFlush() {
        val p = Processor(configure = false)
        p.replaceLevels(mapOf("a" to -6.0))
        p.stream(aOffset, "a")
        p.offset(aOffset)
        p.configure() // configure + the flush that starts the song
        assertGain("first samples", p.constant(tone, frames = 4), -6.0)
    }

    @Test fun sourceMessagesSeedTheLevelsAndALoadReplacesThem() {
        val p = Processor()
        p.noteSource(mapOf("id" to "a", "replayGainDb" to -6.0))
        p.noteSource(mapOf("id" to "plain", "replayGainDb" to null))
        p.noteSource(mapOf("id" to "radio")) // no gain, nothing to seed
        p.commitSources(replace = true)
        p.stream(aOffset, "a")
        p.offset(aOffset)
        assertGain("seeded by a load", p.constant(tone), -6.0)
        p.noteSource(mapOf("id" to "b", "replayGainDb" to -12.0))
        p.commitSources(replace = false) // an insert keeps what is queued
        p.stream(bOffset, "b")
        p.offset(bOffset)
        p.constant(tone, frames = 5)
        p.flush()
        assertGain("seeded by an insert", p.constant(tone), -12.0)
        p.noteSource(mapOf("id" to "c", "replayGainDb" to 3.0))
        p.commitSources(replace = true) // a new queue forgets the old one
        p.stream(aOffset + 1, "a")
        p.offset(aOffset + 1)
        p.constant(tone, frames = 5)
        p.flush()
        assertGain("a is unknown after the new load", p.constant(tone), 0.0)
    }

    @Test fun anyThreadMayReplaceTheMapWhileTheStageRuns() {
        val p = playingA()
        val writer = Thread { repeat(2000) { p.setLevels(mapOf("a" to -6.0, "n$it" to it.toDouble())) } }
        writer.start()
        repeat(200) { assertGain("steady", p.constant(tone, frames = 10), -6.0) }
        writer.join()
    }

    @Test fun aFlushSnapsAfterAResetWithoutForgettingTheSong() {
        val p = playingA()
        p.reset()
        assertEquals("reset zeroes the applied gain", 0.0, p.appliedDb(), 0.0)
        p.configure()
        assertGain("the song is still a", p.constant(tone), -6.0)
    }

    @Test fun theLegacyBoostStillRidesOnTopWhileNoLevelsAreSent() {
        val p = Processor()
        p.setBoost(sixDb, false)
        p.flush()
        assertTrue(p.constant(1000).all { it.toInt() == 2000 })
    }

    // ---- the method-channel case

    private fun channelLevels(f: Fixture, vararg entries: Pair<String, Double>, live: Boolean = false) =
        f.channel("setReplayGainLevels", mapOf("byId" to mapOf(*entries), "byUri" to emptyMap<String, Double>(), "live" to live))

    @Test fun setReplayGainLevelsReachesTheProcessor() {
        val f = Fixture()
        channelLevels(f, "a" to -6.0)
        val p = f.processor!!
        p.stream(aOffset, "a")
        p.offset(aOffset)
        assertGain("a", p.constant(tone), -6.0)
        channelLevels(f, "a" to -12.0, live = true)
        p.constant(tone, frames = 1000)
        assertGain("live", p.constant(tone), -12.0)
        assertTrue(f.errors.isEmpty())
    }

    @Test fun setReplayGainLevelsWithoutAProcessorIsIgnored() {
        val f = Fixture(withProcessor = false)
        channelLevels(f, "a" to -6.0)
        assertTrue(f.errors.isEmpty())
    }

    // ---- bridge

    private inner class Fixture(withProcessor: Boolean = true) {
        val bridge: Any = unsafe.allocateInstance(bridgeClass)
        val processor: Processor? = if (withProcessor) Processor() else null
        var index = 0
        var itemCount = 3
        var loopMode = 0
        val log = mutableListOf<String>()
        private val exoClass = Class.forName("androidx.media3.exoplayer.ExoPlayer")
        private val itemClass = Class.forName("androidx.media3.common.MediaItem")

        private fun timeline(): Any {
            val windowClass = Class.forName("androidx.media3.common.Timeline\$Window")
            val windows = (0 until itemCount).map { unsafe.allocateInstance(windowClass).also { w -> put(w, "uid", it) } }
            val immutable = Class.forName("com.google.common.collect.ImmutableList")
            val timeline = unsafe.allocateInstance(Class.forName("androidx.media3.common.Timeline\$RemotableTimeline"))
            put(timeline, "windows", immutable.getMethod("copyOf", Collection::class.java).invoke(null, windows))
            return timeline
        }

        var playWhenReady = true

        /** Every media3 call logs the boost the processor was asking for at that moment. */
        val exo: Any = Proxy.newProxyInstance(exoClass.classLoader, arrayOf(exoClass)) { _, method, args ->
            when (method.name) {
                "getMediaItemCount" -> itemCount
                "getMediaItemAt" -> unsafe.allocateInstance(itemClass)
                "getCurrentMediaItemIndex" -> index
                "getCurrentTimeline" -> timeline()
                "getPlayWhenReady" -> playWhenReady
                "getPlaybackState" -> 3
                "getPauseAtEndOfMediaItems" -> false
                "getCurrentPosition", "getBufferedPosition", "getDuration" -> 10_000L
                else -> {
                    if (method.name == "seekTo") index = args[0] as Int
                    log.add("${method.name} boost=${processor?.requested()}")
                    when (method.returnType) {
                        Boolean::class.javaPrimitiveType -> false
                        Int::class.javaPrimitiveType -> 0
                        Long::class.javaPrimitiveType -> 0L
                        else -> null
                    }
                }
            }
        }

        init {
            put(bridge, "player", exo)
            put(bridge, "playRequested", true)
            put(bridge, "navisEqualizer", processor?.raw)
            val state = Class.forName("com.ryanheise.just_audio.AudioPlayer\$ProcessingState")
            put(bridge, "processingState", state.enumConstants.first { it.toString() == "ready" })
            put(bridge, "eventChannel", unsafe.allocateInstance(
                Class.forName("com.ryanheise.just_audio.BetterEventChannel"),
            ))
            put(bridge, "mediaSources", HashMap<String, Any>())
        }

        private val resultClass = Class.forName("io.flutter.plugin.common.MethodChannel\$Result")
        val errors = mutableListOf<String>()
        val result: Any = Proxy.newProxyInstance(resultClass.classLoader, arrayOf(resultClass)) { _, method, args ->
            if (method.name == "error") errors.add(args[0] as String)
            null
        }

        fun channel(method: String, arguments: Any?) {
            val callClass = Class.forName("io.flutter.plugin.common.MethodCall")
            val call = callClass.getConstructor(String::class.java, Any::class.java).newInstance(method, arguments)
            unwrap {
                bridgeClass.getMethod("onMethodCall", callClass, resultClass).invoke(bridge, call, result)
            }
        }

        fun boost(db: Double, guarded: Boolean, forIndex: Int? = null) = channel(
            "setReplayGainBoost",
            mapOf("currentDb" to db, "guarded" to guarded, "byUri" to emptyMap<String, Double>(), "index" to forIndex),
        )

        /** A discontinuity from the item with window uid [from] to the one with [to]. */
        fun discontinuity(reason: Int, from: Any = "a", to: Any = "a") {
            val infoClass = Class.forName("androidx.media3.common.Player\$PositionInfo")
            fun info(uid: Any) = unsafe.allocateInstance(infoClass).also { put(it, "windowUid", uid) }
            unwrap {
                bridgeClass.getMethod("onPositionDiscontinuity", infoClass, infoClass, Int::class.javaPrimitiveType)
                    .invoke(bridge, info(from), info(to), reason)
            }
        }

        fun load() {
            unwrap {
                bridgeClass.getDeclaredMethod(
                    "load", List::class.java, Class.forName("androidx.media3.exoplayer.source.ShuffleOrder"),
                    Long::class.javaPrimitiveType, Integer::class.java, resultClass,
                ).apply { isAccessible = true }.invoke(bridge, emptyList<Any>(), null, 0L, 0, result)
            }
        }

        fun seek(index: Int?) = unwrap {
            bridgeClass.getMethod("seek", Long::class.javaPrimitiveType, Integer::class.java, resultClass)
                .invoke(bridge, 5000L, index, result)
        }

        fun requested() = processor!!.requested()
    }

    private fun firstLogged(f: Fixture, prefix: String) = f.log.first { it.startsWith(prefix) }

    @Test fun setReplayGainBoostReachesTheProcessor() {
        val f = Fixture()
        f.boost(6.0, true)
        assertEquals(6.0, f.requested(), 0.0)
        assertTrue(f.processor!!.guarded())
        f.boost(3.0, false)
        assertEquals(3.0, f.requested(), 0.0)
        assertTrue("the latch keeps the stage guarded", f.processor.guarded())
        assertTrue(f.errors.isEmpty())
    }

    @Test fun aValueForAnotherSongIsIgnoredAndAZeroIsAlwaysApplied() {
        val f = Fixture()
        f.index = 1
        f.boost(3.0, false, forIndex = 1)
        assertEquals(3.0, f.requested(), 0.0)
        f.boost(8.0, false, forIndex = 0)
        assertEquals("a value computed for song 0 never reaches song 1", 3.0, f.requested(), 0.0)
        f.boost(8.0, false, forIndex = 2)
        assertEquals(3.0, f.requested(), 0.0)
        f.boost(0.0, true, forIndex = 0)
        assertEquals("a 0 is always applied", 0.0, f.requested(), 0.0)
        assertTrue("and its guard flag with it", f.processor!!.guarded())
        f.discontinuity(seek) // a new play of the song ends the latch
        f.boost(5.0, false, forIndex = 1)
        assertEquals(5.0, f.requested(), 0.0)
        f.boost(6.0, false)
        assertEquals("a message without an index is applied as before", 6.0, f.requested(), 0.0)
        assertTrue(f.errors.isEmpty())
    }

    @Test fun aStaleValueAfterASeekToAnotherSongIsIgnored() {
        val f = Fixture()
        f.index = 0
        f.boost(8.0, false, forIndex = 0)
        f.seek(2) // lowers to 0 and ExoPlayer is now on song 2 at once
        assertEquals(0.0, f.requested(), 0.0)
        f.boost(8.0, false, forIndex = 0) // Dart's value for the old song arrives late
        assertEquals("the old song's 8 dB stays out", 0.0, f.requested(), 0.0)
        f.boost(4.0, false, forIndex = 2) // the index event's value for song 2
        assertEquals(4.0, f.requested(), 0.0)
    }

    // ---- the native latch: once a guarded value is applied, nothing above it until the song changes

    private val autoTransition = 0
    private val seek = 1
    private val remove = 4
    private val internal = 5

    @Test fun aGuardedValueLatchesAndALaterUnguardedHigherOneIsClamped() {
        val f = Fixture()
        f.boost(3.0, true, forIndex = 0)
        assertEquals(3.0, f.requested(), 0.0)
        f.boost(9.0, false, forIndex = 0) // Dart forgot the guard
        assertEquals("clamped to the latch", 3.0, f.requested(), 0.0)
        assertTrue("and native knows it is guarded", f.processor!!.guarded())
        f.boost(2.0, true, forIndex = 0)
        assertEquals(2.0, f.requested(), 0.0)
        f.boost(8.0, true, forIndex = 0)
        assertEquals("the latch only ever goes down", 2.0, f.requested(), 0.0)
        f.boost(9.0, false, forIndex = 0)
        assertEquals("and a raised guarded value did not raise it", 2.0, f.requested(), 0.0)
    }

    @Test fun aGuardedValueAppliedWhilePausedLatches() {
        // A seek or a restore while paused into the last 3 s: the net must hold before the
        // first playing tick, not after it.
        val f = Fixture()
        f.playWhenReady = false
        f.boost(3.0, true, forIndex = 0)
        f.playWhenReady = true
        f.boost(9.0, false, forIndex = 0)
        assertEquals(3.0, f.requested(), 0.0)
    }

    @Test fun aStaleIndexZeroIsAppliedButDoesNotLatch() {
        // A's last guarded 0 (the next song was untagged then) lands after the transition to B.
        val f = Fixture()
        f.boost(3.0, true, forIndex = 0)
        f.discontinuity(autoTransition, from = "a", to = "b")
        f.index = 1
        f.boost(0.0, true, forIndex = 0)
        assertEquals("the 0 is still applied", 0.0, f.requested(), 0.0)
        f.boost(9.0, false, forIndex = 1)
        assertEquals("but B is not held at 0 for its whole length", 9.0, f.requested(), 0.0)
    }

    @Test fun aCurrentIndexZeroLatchesAndAMessageWithoutAnIndexToo() {
        for (index in listOf<Int?>(0, null)) {
            val f = Fixture()
            f.boost(0.0, true, forIndex = index)
            f.boost(9.0, false, forIndex = index)
            assertEquals("index $index", 0.0, f.requested(), 0.0)
        }
    }

    @Test fun aZeroIsAlwaysAppliedWhateverTheLatch() {
        val f = Fixture()
        f.boost(3.0, true, forIndex = 0)
        f.boost(0.0, false, forIndex = 0)
        assertEquals(0.0, f.requested(), 0.0)
        f.boost(9.0, false, forIndex = 0)
        assertEquals("the latch survives a 0", 3.0, f.requested(), 0.0)
    }

    @Test fun aNewPlayClearsTheLatch() {
        val clears = listOf<Pair<String, (Fixture) -> Unit>>(
            "auto transition" to { f -> f.discontinuity(autoTransition) },
            "seek" to { f -> f.discontinuity(seek) },
            "another item" to { f -> f.discontinuity(remove, from = "a", to = "b") },
            "internal, another item" to { f -> f.discontinuity(internal, from = "a", to = "b") },
            "load" to { f -> f.load() },
        )
        for ((name, clear) in clears) {
            val f = Fixture()
            f.boost(3.0, true, forIndex = 0)
            f.boost(9.0, false, forIndex = 0)
            assertEquals("$name: clamped before", 3.0, f.requested(), 0.0)
            clear(f)
            f.boost(9.0, false, forIndex = 0)
            assertEquals("$name clears the latch", 9.0, f.requested(), 0.0)
        }
    }

    @Test fun anEditAroundTheSameItemKeepsTheLatch() {
        for (reason in listOf(remove, internal)) {
            val f = Fixture()
            f.boost(3.0, true, forIndex = 0)
            f.discontinuity(reason, from = "a", to = "a")
            f.boost(9.0, false, forIndex = 0)
            assertEquals("reason $reason with the same uid", 3.0, f.requested(), 0.0)
        }
    }

    @Test fun withoutAProcessorTheMessageIsAnError() {
        val f = Fixture(withProcessor = false)
        f.boost(6.0, false)
        assertEquals(listOf("eq_unavailable"), f.errors)
    }

    @Test fun loadLowersBeforeTheNativeLoad() {
        val f = Fixture()
        f.boost(8.0, false)
        f.load()
        assertEquals(0.0, f.requested(), 0.0)
        assertEquals("the ExoPlayer call saw an already-lowered boost", "stop boost=0.0", firstLogged(f, "stop"))
    }

    @Test fun seekToAnotherSongLowersBeforeSeekTo() {
        val f = Fixture()
        f.boost(8.0, false)
        f.seek(2)
        assertEquals(0.0, f.requested(), 0.0)
        assertEquals("seekTo boost=0.0", firstLogged(f, "seekTo"))
    }

    @Test fun seekWithinTheSongKeepsTheBoost() {
        val f = Fixture()
        f.boost(8.0, false)
        f.seek(null)
        f.seek(f.index)
        assertEquals(8.0, f.requested(), 0.0)
    }

    @Test fun removingTheCurrentSongLowersBeforeTheRemoval() {
        val f = Fixture()
        f.index = 1
        f.boost(8.0, false)
        f.channel("concatenatingRemoveRange",
            mapOf("id" to "", "startIndex" to 0, "endIndex" to 1, "shuffleOrder" to listOf(0, 1)))
        assertEquals("a range before the current song keeps the boost", 8.0, f.requested(), 0.0)
        f.channel("concatenatingRemoveRange",
            mapOf("id" to "", "startIndex" to 1, "endIndex" to 2, "shuffleOrder" to listOf(0)))
        assertEquals(0.0, f.requested(), 0.0)
        assertEquals("removeMediaItems boost=0.0", f.log.last { it.startsWith("removeMediaItems") })
    }

    @Test fun guardedBoostLowersBeforeEveryQueueEdit() {
        val edits = listOf<Pair<String, Map<String, Any?>>>(
            "concatenatingInsertAll" to mapOf(
                "id" to "", "index" to 2, "children" to emptyList<Any>(), "shuffleOrder" to listOf(0, 1, 2),
            ),
            "concatenatingMove" to mapOf(
                "id" to "", "currentIndex" to 2, "newIndex" to 1, "shuffleOrder" to listOf(0, 1, 2),
            ),
            "concatenatingRemoveRange" to mapOf(
                "id" to "", "startIndex" to 2, "endIndex" to 3, "shuffleOrder" to listOf(0, 1),
            ),
        )
        for ((method, args) in edits) {
            val calm = Fixture()
            calm.boost(8.0, false)
            calm.channel(method, args)
            assertEquals("$method unguarded keeps the boost", 8.0, calm.requested(), 0.0)

            val guarded = Fixture()
            guarded.boost(8.0, true)
            guarded.channel(method, args)
            assertEquals("$method guarded lowers", 0.0, guarded.requested(), 0.0)
            assertTrue("$method lowered before the ExoPlayer edit",
                guarded.log.first { !it.startsWith("setShuffleOrder") }.endsWith("boost=0.0"))
        }
    }

    @Test fun guardedBoostLowersBeforeALoopOrShuffleChange() {
        val changes = listOf<Pair<String, (Fixture) -> Unit>>(
            "setLoopMode" to { f -> f.channel("setLoopMode", mapOf("loopMode" to 0)) },
            "setShuffleMode" to { f -> f.channel("setShuffleMode", mapOf("shuffleMode" to 1)) },
            "setShuffleOrder" to { f ->
                f.channel("setShuffleOrder", mapOf("audioSource" to mapOf("id" to "none", "type" to "concatenating")))
            },
        )
        for ((name, change) in changes) {
            val calm = Fixture()
            calm.boost(8.0, false)
            change(calm)
            assertEquals("$name unguarded keeps the boost", 8.0, calm.requested(), 0.0)

            val guarded = Fixture()
            guarded.boost(8.0, true)
            change(guarded)
            assertEquals("$name guarded lowers", 0.0, guarded.requested(), 0.0)
        }
    }

    @Test fun loweringBeforeAnEditNeedsNoProcessor() {
        val f = Fixture(withProcessor = false)
        f.channel("setLoopMode", mapOf("loopMode" to 0))
        f.load()
        f.seek(2)
        assertTrue(f.errors.isEmpty())
    }
}
