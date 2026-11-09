package com.navis.app.navis

import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Proxy
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Test
import sun.misc.Unsafe

/**
 * ReplayGain on Android (#392): the processor's per-entry gain stage and the
 * `setReplayGainLevels` channel case. The real vendored classes run, with no
 * Looper, audio device or media3 player.
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
        private val unset = Long.MIN_VALUE + 1 // C.TIME_UNSET
        fun setLevels(levels: Map<String, Double>, live: Boolean = false) {
            call("setLevels", Map::class.java, Boolean::class.javaPrimitiveType!!, args = arrayOf(levels, live))
        }
        fun replaceLevels(levels: Map<String, Double>) { call("replaceLevels", Map::class.java, args = arrayOf(levels)) }
        fun noteSource(message: Map<String, Any?>) { call("noteSource", Map::class.java, args = arrayOf(message)) }
        fun commitSources(replace: Boolean) {
            call("commitSources", Boolean::class.javaPrimitiveType!!, args = arrayOf(replace))
        }
        /** The renderer's onStreamChanged: [offsetUs] belongs to the song tagged [key]. */
        fun stream(offsetUs: Long, key: String?, thresholdUs: Long = unset) {
            call("noteStream", long, String::class.java, long, args = arrayOf(offsetUs, key, thresholdUs))
        }
        /** The renderer's processOutputBuffer, just before the sink gets a buffer with [ptsUs]. */
        fun outputBuffer(ptsUs: Long) { call("outputBuffer", long, args = arrayOf(ptsUs)) }
        /** The renderer's onPositionReset / onDisabled: Media3 drops its pending stream changes. */
        fun dropPendingStreams() { call("dropPendingStreams") }
        /** The renderer's onOutputStreamOffsetUsChanged. */
        fun offset(offsetUs: Long) { call("streamOffsetChanged", long, args = arrayOf(offsetUs)) }
        fun appliedDb(): Double = (state()["replayGainAppliedDb"] as Number).toDouble()
        fun currentKey(): String? = state()["replayGainCurrentKey"] as String?
        fun reset() { call("reset") }
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

    /** A stage already playing a song of the given [db] (steady since its first sample). */
    private fun playing(db: Double, config: Map<String, Any?>? = null, channels: Int = 1): Processor {
        val p = if (config == null) Processor(channels = channels) else Processor(config, channels)
        p.replaceLevels(mapOf("k" to db))
        p.stream(1L, "k")
        p.offset(1L)
        return p
    }

    @Test fun aBoostIsAppliedAfterAFlushWithTheEqualizerOff() {
        val p = playing(sixDb)
        val out = p.constant(1000)
        assertTrue("every sample is doubled, got ${out.toList().distinct()}", out.all { it.toInt() == 2000 })
        assertEquals(sixDb, p.appliedDb(), 0.001)
        assertEquals(0L, (p.state()["boostClipSamples"] as Number).toLong())
    }

    @Test fun aBoostRidesOutsideTheEqualizerAutoHeadroom() {
        // +6 dB preamp with auto-headroom is a net -0.5 dB: the bank must not eat the boost.
        val p = playing(sixDb, mapOf(
            "enabled" to true, "autoHeadroom" to true, "preampDb" to 6.0, "filters" to emptyList<Any>(),
        ))
        val out = p.constant(1000)
        val expected = 1000 * Math.pow(10.0, -0.5 / 20) * 2
        assertTrue("EQ then boost: ${out.toList().distinct()}", out.all { Math.abs(it - expected) <= 1.0 })
    }

    @Test fun stereoFramesShareOneGain() {
        val p = playing(sixDb, channels = 2)
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

    @Test fun aRepeatOneWrapPicksUpAChangedValue() {
        // A tag correction (non-live) is frozen for the rest of the stream and applies at the wrap.
        val p = playingA()
        p.setLevels(mapOf("a" to -12.0))
        assertGain("frozen", p.constant(tone, frames = 20), -6.0)
        p.stream(bOffset, "a")
        p.offset(bOffset)
        assertGain("the tail", p.constant(tone, frames = 20), -6.0)
        p.flush()
        assertGain("the wrap", p.constant(tone), -12.0)
    }

    @Test fun theRendererNotesTheStreamBeforeSuperFiresTheOffsetEvent() {
        // In Media3 1.4.1 super.onStreamChanged can fire onOutputStreamOffsetUsChanged at once (first
        // song, skips). The key must already be recorded, or the skip keeps the outgoing gain. Here
        // super fails on the bare instance, so only a note made BEFORE super survives.
        val p = playingA()
        val rendererClass = Class.forName("com.ryanheise.just_audio.NavisAudioRenderer")
        val renderer = unsafe.allocateInstance(rendererClass)
        put(renderer, "processor", p.raw)
        val periodId = Class.forName("androidx.media3.exoplayer.source.MediaSource\$MediaPeriodId")
            .getConstructor(Any::class.java).newInstance("period")
        val onStreamChanged = rendererClass.declaredMethods.first { it.name == "onStreamChanged" }
            .apply { isAccessible = true }
        try {
            val formats = java.lang.reflect.Array.newInstance(Class.forName("androidx.media3.common.Format"), 0)
            onStreamChanged.invoke(renderer, formats, 0L, bOffset, periodId)
        } catch (expected: InvocationTargetException) {
            // super cannot run without a real renderer
        }
        p.offset(bOffset)
        p.flush() // the unresolved entry is key null: 0 dB, not a's -6
        assertGain("the new stream's key was noted first", p.constant(tone), 0.0)
    }

    // ---- an opus join (#392): Media3 reports the new stream only after H's first buffer reached the sink

    private val lDb = 7.0
    private val hDb = -3.0
    private val joinUs = 1_000_030_006_500L
    private val thresholdUs = joinUs - 13_000L // L's last queued input

    /** A stage playing L (+7 dB) with H announced at [joinUs]; the sink has seen L input, so a switch must wait for a flush. */
    private fun playingLWithHAnnounced(threshold: Long = thresholdUs): Processor {
        val p = Processor()
        p.replaceLevels(mapOf("l" to lDb, "h" to hDb))
        p.stream(aOffset, "l")
        p.offset(aOffset)
        p.constant(tone, frames = 960) // L's samples: input since the last flush
        p.stream(joinUs, "h", threshold)
        return p
    }

    private fun assertHAtMinusThree(p: Processor) {
        val out = p.run(ShortArray(648) { 29645 }) // H's first 648 frames, near full scale
        assertTrue("H at -3 dB (20987), got ${out.toList().distinct().take(4)}",
            out.all { Math.abs(it - 20987) <= 1 })
        assertEquals(0L, (p.state()["boostClipSamples"] as Number).toLong())
    }

    @Test fun anOpusJoinSwitchesBeforeTheNewStreamsFirstBuffer() {
        val p = playingLWithHAnnounced()
        p.outputBuffer(joinUs - 40_000) // L's decoded tail
        assertGain("L's tail", p.constant(tone, frames = 100), lDb)
        p.outputBuffer(joinUs) // H's first buffer: the offset event has not come yet
        p.flush() // the codec format flush before H's samples
        assertEquals("h", p.currentKey())
        assertHAtMinusThree(p)
        p.offset(joinUs) // Media3's own, late event
        p.flush()
        assertEquals("h", p.currentKey())
        assertGain("still H", p.constant(tone), hDb)
    }

    @Test fun theRendererSignalsANewStreamsBufferBeforeSuperHandsItToTheSink() {
        val rendererClass = Class.forName("com.ryanheise.just_audio.NavisAudioRenderer")
        val processBuffer = rendererClass.declaredMethods.first { it.name == "processOutputBuffer" }
            .apply { isAccessible = true }
        fun hand(p: Processor, ptsUs: Long) {
            val renderer = unsafe.allocateInstance(rendererClass)
            put(renderer, "processor", p.raw)
            // positionUs, elapsedRealtimeUs, codec, buffer, index, flags, sampleCount, pts, decodeOnly, last, format
            val args = processBuffer.parameterTypes.mapIndexed<Class<*>, Any?> { i, t ->
                when {
                    i == 7 -> ptsUs
                    t == java.lang.Long.TYPE -> 0L
                    t == Integer.TYPE -> 0
                    t == java.lang.Boolean.TYPE -> false
                    else -> null
                }
            }
            try {
                processBuffer.invoke(renderer, *args.toTypedArray())
            } catch (expected: InvocationTargetException) {
                // super cannot run without a real renderer: only the note made BEFORE it counts
            }
        }
        val early = playingLWithHAnnounced()
        hand(early, joinUs - 1)
        early.flush()
        assertGain("a buffer before H's start is still L", early.constant(tone), lDb)
        val p = playingLWithHAnnounced()
        hand(p, joinUs)
        p.flush()
        assertHAtMinusThree(p)
    }

    @Test fun theRendererDropsThePendingStreamsOnAPositionReset() {
        val rendererClass = Class.forName("com.ryanheise.just_audio.NavisAudioRenderer")
        val p = playingLWithHAnnounced()
        val renderer = unsafe.allocateInstance(rendererClass)
        put(renderer, "processor", p.raw)
        val reset = rendererClass.declaredMethods.first { it.name == "onPositionReset" }.apply { isAccessible = true }
        try {
            reset.invoke(renderer, 0L, false)
        } catch (expected: InvocationTargetException) {
            // super cannot run without a real renderer
        }
        p.outputBuffer(joinUs + 5_000)
        p.flush()
        assertGain("a seek after read-ahead keeps L", p.constant(tone), lDb)
    }

    @Test fun anOtherCodecJoinStillWaitsForTheFlush() {
        val p = playingLWithHAnnounced()
        p.outputBuffer(thresholdUs) // L's last buffer: pts == threshold, not past it
        p.offset(joinUs) // Media3's event, before H's buffers
        assertGain("L's last buffer", p.constant(tone, frames = 480), lDb)
        p.flush()
        assertGain("H", p.constant(tone), hDb)
    }

    @Test fun lsLastBufferRightAfterAFlushKeepsLsGain() {
        val p = playingLWithHAnnounced()
        p.flush() // e.g. a speed change
        p.outputBuffer(thresholdUs)
        assertGain("L", p.constant(tone), lDb)
    }

    @Test fun aSeekInsideTheSongDoesNotSwitch() {
        val p = playingA()
        p.flush()
        p.outputBuffer(Long.MAX_VALUE / 2) // nothing announced
        assertGain("still A", p.constant(tone), -6.0)
        assertEquals("a", p.currentKey())
    }

    @Test fun aSeekAfterReadAheadDropsThePendingStream() {
        val p = playingLWithHAnnounced()
        p.dropPendingStreams()
        p.flush()
        p.outputBuffer(joinUs + 5_000)
        assertGain("L", p.constant(tone), lDb)
        p.offset(joinUs) // a stale event matches nothing either
        p.flush()
        assertGain("still L", p.constant(tone), lDb)
    }

    @Test fun anOverrunningLTailKeepsLsGain() {
        // L's decoded tail runs past its declared end: every L buffer is at or before L's last input.
        val p = playingLWithHAnnounced(threshold = joinUs + 20_000)
        p.outputBuffer(joinUs + 10_000)
        p.flush()
        assertGain("L's overrun", p.constant(tone), lDb)
        assertEquals("l", p.currentKey())
    }

    @Test fun anUnsetThresholdNeverSignalsEarly() {
        val p = playingLWithHAnnounced(threshold = Long.MIN_VALUE + 1)
        p.outputBuffer(joinUs + 100_000)
        p.flush()
        assertGain("L", p.constant(tone), lDb)
    }

    @Test fun aRepeatOneFileWrapViaTheBufferKeepsTheGain() {
        val p = playingLWithHAnnounced()
        p.stream(joinUs, "l", thresholdUs) // the wrap: a new stream of the same song
        p.outputBuffer(joinUs)
        p.flush()
        assertGain("same gain, no ramp", p.run(ShortArray(10) { tone.toShort() }), lDb)
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
        // live = true too, so the playback side keeps re-reading the map while it is swapped.
        val writer = Thread { repeat(2000) { p.setLevels(mapOf("a" to -6.0, "n$it" to it.toDouble()), live = true) } }
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

    @Test fun aKnownSourceIdSentAgainStillSeedsItsLevel() {
        // getAudioSource returns a cached MediaSource for an id it decoded before and skips the decode.
        val p = Processor()
        val bridge = unsafe.allocateInstance(bridgeClass)
        put(bridge, "navisEqualizer", p.raw)
        val sourceClass = Class.forName("androidx.media3.exoplayer.source.MediaSource")
        val cached = Proxy.newProxyInstance(sourceClass.classLoader, arrayOf(sourceClass)) { _, _, _ -> null }
        put(bridge, "mediaSources", HashMap<String, Any>().apply { put("a", cached) })
        val getAudioSource = bridgeClass.getDeclaredMethod("getAudioSource", Any::class.java).apply { isAccessible = true }
        val commit = bridgeClass.getDeclaredMethod("commitReplayGainLevels", Boolean::class.javaPrimitiveType)
            .apply { isAccessible = true }
        unwrap { getAudioSource.invoke(bridge, mapOf("id" to "a", "type" to "progressive", "replayGainDb" to -6.0)) }
        unwrap { commit.invoke(bridge, true) }
        p.stream(aOffset, "a")
        p.offset(aOffset)
        assertGain("re-sent id", p.constant(tone), -6.0)
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

        // onMethodCall only needs a non-null player to skip building a real one.
        private val exoClass = Class.forName("androidx.media3.exoplayer.ExoPlayer")
        private val exo: Any = Proxy.newProxyInstance(exoClass.classLoader, arrayOf(exoClass)) { _, _, _ -> null }

        init {
            put(bridge, "player", exo)
            put(bridge, "navisEqualizer", processor?.raw)
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
    }
}
