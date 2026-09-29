package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.BaseAudioProcessor;
import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Always present in the PCM chain so bypass/enabling never reloads media. */
final class NavisEqualizerProcessor extends BaseAudioProcessor {
    private final Object configurationLock = new Object();
    private EqualizerDsp.Configuration configuration;
    private volatile EqualizerDsp.Bank requested;
    private volatile EqualizerDsp.Bank applied;
    private EqualizerDsp.Bank outgoing;
    private int sampleRate, channels, fadeRemaining, fadeFrames;

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

    Map<String, Object> state() {
        Map<String, Object> result = new HashMap<>();
        EqualizerDsp.Bank actual = applied;
        result.put("enabled", actual != null && actual.enabled);
        result.put("sampleRate", actual == null ? null : actual.sampleRate);
        result.put("headroomDb", actual == null ? 0.0 : actual.headroom);
        result.put("reason", actual == null ? null : actual.reason);
        result.put("pending", requested != actual);
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
    }

    @Override
    public void queueInput(ByteBuffer input) {
        if (fadeRemaining == 0 && requested != applied) {
            outgoing = applied;
            applied = requested;
            fadeRemaining = outgoing == null ? 0 : fadeFrames;
        }
        EqualizerDsp.Bank current = applied;
        ByteBuffer output = replaceOutputBuffer(input.remaining());
        while (input.remaining() >= channels * 2) {
            double mix = fadeRemaining == 0 ? 1 : 1 - (double) fadeRemaining / fadeFrames;
            for (int channel = 0; channel < channels; channel++) {
                double value = input.getShort() / 32768.0;
                double next = current == null ? value : current.process(value, channel);
                if (fadeRemaining > 0) {
                    double old = outgoing.process(value, channel);
                    next = old + (next - old) * mix;
                }
                output.putShort((short) Math.max(-32768, Math.min(32767, Math.round(next * 32768))));
            }
            if (fadeRemaining > 0 && --fadeRemaining == 0) outgoing = null;
        }
        output.flip();
    }

    @Override
    protected void onReset() {
        synchronized (configurationLock) {
            sampleRate = channels = 0;
            requested = applied = null;
        }
        outgoing = null;
        fadeRemaining = 0;
    }
}
