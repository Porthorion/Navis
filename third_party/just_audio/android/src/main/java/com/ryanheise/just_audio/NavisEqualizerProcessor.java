package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.BaseAudioProcessor;
import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Always present in the PCM chain so bypass/enabling never reloads media. It
 * also carries the ReplayGain boost, applied after the EQ bank (whose
 * auto-headroom would cancel it) and before the 16-bit clamp.
 */
final class NavisEqualizerProcessor extends BaseAudioProcessor {
    private final Object configurationLock = new Object();
    private EqualizerDsp.Configuration configuration;
    private volatile EqualizerDsp.Bank requested;
    private volatile EqualizerDsp.Bank applied;
    private EqualizerDsp.Bank outgoing;
    private int sampleRate, channels, fadeRemaining, fadeFrames;
    // The boost the app asked for (any thread), and what the playback thread applies.
    private volatile double requestedBoostDb;
    private volatile boolean boostGuarded;
    private volatile double appliedBoostDb;
    private volatile long boostClipSamples;
    private EqualizerDsp.BoostRamp boost = new EqualizerDsp.BoostRamp(1);

    NavisEqualizerProcessor(Map<?, ?> initial) {
        configuration = decode(initial);
    }

    private static EqualizerDsp.Configuration decode(Map<?, ?> raw) {
        List<?> rawFilters = (List<?>) raw.get("filters");
        if (rawFilters == null || rawFilters.size() > 32) {
            throw new IllegalArgumentException("Invalid EQ filter list");
        }
        EqualizerDsp.Filter[] filters = new EqualizerDsp.Filter[rawFilters.size()];
        for (int i = 0; i < filters.length; i++) {
            Map<?, ?> f = (Map<?, ?>) rawFilters.get(i);
            filters[i] = new EqualizerDsp.Filter((String) f.get("type"),
                    ((Number) f.get("frequencyHz")).doubleValue(),
                    ((Number) f.get("gainDb")).doubleValue(),
                    ((Number) f.get("q")).doubleValue(), (Boolean) f.get("enabled"));
        }
        return new EqualizerDsp.Configuration((Boolean) raw.get("enabled"),
                (Boolean) raw.get("autoHeadroom"), ((Number) raw.get("preampDb")).doubleValue(), filters);
    }

    Map<String, Object> setConfiguration(Map<?, ?> raw) {
        EqualizerDsp.Configuration next = decode(raw);
        synchronized (configurationLock) {
            if (configuration.sameAs(next)) return state();
            configuration = next;
            // Coefficients and history buffers are prepared off the realtime
            // processing thread for live edits. The block boundary swaps them.
            if (sampleRate > 0) requested = new EqualizerDsp.Bank(next, sampleRate, channels);
        }
        return state();
    }

    /** Asks for [db] of boost. [guarded] marks a value lowered for the song that plays next. */
    void setBoost(double db, boolean guarded) {
        boostGuarded = guarded;
        requestedBoostDb = db;
    }

    /** Drops the boost request to 0 before a command that can change the next song. */
    void lowerBoost() {
        requestedBoostDb = 0;
    }

    boolean boostGuarded() {
        return boostGuarded;
    }

    Map<String, Object> state() {
        Map<String, Object> result = new HashMap<>();
        EqualizerDsp.Bank actual = applied;
        result.put("enabled", actual != null && actual.enabled);
        result.put("sampleRate", actual == null ? null : actual.sampleRate);
        result.put("headroomDb", actual == null ? 0.0 : actual.headroom);
        result.put("reason", actual == null ? null : actual.reason);
        result.put("pending", requested != actual);
        result.put("boostRequestedDb", requestedBoostDb);
        result.put("boostAppliedDb", appliedBoostDb);
        result.put("boostGuarded", boostGuarded);
        result.put("boostClipSamples", boostClipSamples);
        return result;
    }

    @Override
    protected AudioFormat onConfigure(AudioFormat input) throws UnhandledAudioFormatException {
        if (input.encoding != C.ENCODING_PCM_16BIT) {
            throw new UnhandledAudioFormatException(input);
        }
        synchronized (configurationLock) {
            sampleRate = input.sampleRate;
            channels = input.channelCount;
            requested = new EqualizerDsp.Bank(configuration, sampleRate, channels);
        }
        return input;
    }

    @Override
    protected void onFlush() {
        synchronized (configurationLock) {
            if (sampleRate > 0) {
                requested = new EqualizerDsp.Bank(configuration, sampleRate, channels);
            }
            applied = requested;
        }
        outgoing = null;
        fadeRemaining = 0;
        fadeFrames = Math.max(1, sampleRate / 50);
        // A flush starts a song (or a seek): play it at the boost asked for, with no ramp.
        boost = new EqualizerDsp.BoostRamp(fadeFrames);
        boost.snap(requestedBoostDb);
        appliedBoostDb = boost.db();
    }

    @Override
    public void queueInput(ByteBuffer input) {
        if (fadeRemaining == 0 && requested != applied) {
            outgoing = applied;
            applied = requested;
            fadeRemaining = outgoing == null ? 0 : fadeFrames;
        }
        EqualizerDsp.Bank current = applied;
        boost.setTarget(requestedBoostDb);
        long clipped = 0;
        ByteBuffer output = replaceOutputBuffer(input.remaining());
        while (input.remaining() >= channels * 2) {
            double gain = boost.next();
            double mix = fadeRemaining == 0 ? 1 : 1 - (double) fadeRemaining / fadeFrames;
            for (int channel = 0; channel < channels; channel++) {
                double value = input.getShort() / 32768.0;
                double next = current == null ? value : current.process(value, channel);
                if (fadeRemaining > 0) {
                    double old = outgoing.process(value, channel);
                    next = old + (next - old) * mix;
                }
                long scaled = Math.round(next * gain * 32768);
                if (scaled > 32767 || scaled < -32768) {
                    if (gain > 1) clipped++;
                    scaled = Math.max(-32768, Math.min(32767, scaled));
                }
                output.putShort((short) scaled);
            }
            if (fadeRemaining > 0 && --fadeRemaining == 0) outgoing = null;
        }
        output.flip();
        appliedBoostDb = boost.db();
        if (clipped > 0) boostClipSamples += clipped;
    }

    @Override
    protected void onReset() {
        synchronized (configurationLock) {
            sampleRate = channels = 0;
            requested = applied = null;
        }
        outgoing = null;
        fadeRemaining = 0;
        boost = new EqualizerDsp.BoostRamp(1);
        appliedBoostDb = 0;
    }
}
