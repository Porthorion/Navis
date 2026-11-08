package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.BaseAudioProcessor;
import java.nio.ByteBuffer;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Always present in the PCM chain so bypass/enabling never reloads media. It
 * also carries ReplayGain (#392), applied after the EQ bank (whose
 * auto-headroom would cancel a boost) and before the 16-bit clamp.
 *
 * <p>The gain is one signed dB per queue entry, keyed by the just_audio source id
 * ({@code levels}). The renderer ({@link NavisAudioRenderer}) tells this stage which
 * entry the next samples belong to; the key becomes current at the A/B sample
 * boundary, which on Media3 1.4.1 is the first {@link #onFlush} after the new
 * stream's offset event (a natural join drains A through every processor, then
 * flushes). Threads: the method-channel thread calls {@link #replaceLevels},
 * {@link #setLevels}, {@link #commitSources}, {@link #noteSource}, {@link #state};
 * the ExoPlayer playback thread calls
 * {@link #noteStream}, {@link #streamOffsetChanged} and the processor callbacks.
 */
final class NavisEqualizerProcessor extends BaseAudioProcessor {
    private final Object configurationLock = new Object();
    private EqualizerDsp.Configuration configuration;
    private volatile EqualizerDsp.Bank requested;
    private volatile EqualizerDsp.Bank applied;
    private EqualizerDsp.Bank outgoing;
    private int sampleRate, channels, fadeRemaining, fadeFrames;
    private volatile double appliedDb;
    private volatile long boostClipSamples;
    private EqualizerDsp.GainRamp ramp = new EqualizerDsp.GainRamp(1);

    // Signed dB by source id. An immutable map swapped whole: the method-channel thread writes,
    // the playback thread reads. An id that is missing plays at 0 dB.
    private volatile Map<String, Double> levels = Collections.emptyMap();
    private final Map<String, Double> decodedSources = new HashMap<>(); // method-channel thread only
    private final AtomicBoolean liveRefresh = new AtomicBoolean();
    private volatile String currentKey;
    private volatile double currentDb;
    // Playback thread only. offsetUs -> key of the streams Media3 announced, and the key that
    // takes over at the next flush.
    private final Map<Long, String> streamKeys = new LinkedHashMap<Long, String>() {
        @Override protected boolean removeEldestEntry(Map.Entry<Long, String> eldest) {
            return size() > 8;
        }
    };
    private boolean hasPending, inputSinceFlush;
    private String pendingKey;

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

    /** A new queue: [levels] are the only entries that are known. */
    void replaceLevels(Map<String, Double> next) {
        levels = Collections.unmodifiableMap(new HashMap<>(next));
    }

    /**
     * Later values for queued entries (merged: an entry Dart does not mention keeps its value, so an
     * insert racing a push loses nothing). The playing entry is frozen unless [live], which ramps it.
     */
    void setLevels(Map<String, Double> next, boolean live) {
        Map<String, Double> merged = new HashMap<>(levels);
        merged.putAll(next);
        levels = Collections.unmodifiableMap(merged);
        if (live) liveRefresh.set(true);
    }

    /** Remembers the level a decoded source message carries (progressive/dash with a tag id). */
    void noteSource(Map<?, ?> message) {
        Object id = message.get("id"), db = message.get("replayGainDb");
        if (id instanceof String && db instanceof Number) {
            decodedSources.put((String) id, ((Number) db).doubleValue());
        }
    }

    /** Publishes the levels noted since the last commit: a load replaces, an insert merges. */
    void commitSources(boolean replace) {
        Map<String, Double> seeds = new HashMap<>(decodedSources);
        decodedSources.clear();
        if (replace) replaceLevels(seeds); else setLevels(seeds, false);
    }

    /** Playback thread, before a stream's samples: [key] (null if untagged) plays from [offsetUs]. */
    void noteStream(long offsetUs, String key) {
        streamKeys.put(offsetUs, key);
    }

    /**
     * Playback thread: the output stream with [offsetUs] starts. With input already queued the
     * samples before the next flush still belong to the outgoing entry (at speed 1.5 Sonic's tail
     * arrives after this call), so the key waits for that flush. With none queued since the last
     * flush (first song, explicit skip) nothing outgoing is left: switch now.
     */
    void streamOffsetChanged(long offsetUs) {
        if (!streamKeys.containsKey(offsetUs)) return;
        String key = streamKeys.remove(offsetUs);
        if (inputSinceFlush) {
            pendingKey = key;
            hasPending = true;
        } else {
            hasPending = false;
            adopt(key);
            ramp.snap(currentDb);
            appliedDb = ramp.db();
        }
    }

    private void adopt(String key) {
        currentKey = key;
        currentDb = levelOf(key);
    }

    private double levelOf(String key) {
        Double db = key == null ? null : levels.get(key);
        return db == null ? 0 : db;
    }

    Map<String, Object> state() {
        Map<String, Object> result = new HashMap<>();
        EqualizerDsp.Bank actual = applied;
        result.put("enabled", actual != null && actual.enabled);
        result.put("sampleRate", actual == null ? null : actual.sampleRate);
        result.put("headroomDb", actual == null ? 0.0 : actual.headroom);
        result.put("reason", actual == null ? null : actual.reason);
        result.put("pending", requested != actual);
        result.put("replayGainCurrentKey", currentKey);
        result.put("replayGainAppliedDb", appliedDb);
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
        // A flush starts a song or a seek. A new stream's key becomes current here; with none
        // (a seek in the song, a speed change) the frozen gain stays, even if the map changed.
        if (hasPending) {
            hasPending = false;
            adopt(pendingKey);
        } else if (liveRefresh.getAndSet(false)) {
            currentDb = levelOf(currentKey);
        }
        inputSinceFlush = false;
        ramp = new EqualizerDsp.GainRamp(fadeFrames);
        ramp.snap(currentDb);
        appliedDb = ramp.db();
    }

    @Override
    public void queueInput(ByteBuffer input) {
        if (fadeRemaining == 0 && requested != applied) {
            outgoing = applied;
            applied = requested;
            fadeRemaining = outgoing == null ? 0 : fadeFrames;
        }
        EqualizerDsp.Bank current = applied;
        if (input.hasRemaining()) inputSinceFlush = true;
        // A settings change re-reads the playing entry's level here, on the playback thread, so it
        // cannot land on the wrong side of a boundary.
        if (liveRefresh.getAndSet(false)) currentDb = levelOf(currentKey);
        ramp.setTarget(currentDb);
        long clipped = 0;
        ByteBuffer output = replaceOutputBuffer(input.remaining());
        while (input.remaining() >= channels * 2) {
            double gain = ramp.next();
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
        appliedDb = ramp.db();
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
        ramp = new EqualizerDsp.GainRamp(1);
        appliedDb = 0;
        hasPending = false;
        inputSinceFlush = false;
    }
}
