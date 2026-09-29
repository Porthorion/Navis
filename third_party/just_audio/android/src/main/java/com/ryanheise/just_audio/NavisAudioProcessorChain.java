package com.ryanheise.just_audio;

import androidx.media3.common.PlaybackParameters;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.common.audio.AudioProcessorChain;
import androidx.media3.exoplayer.audio.DefaultAudioSink;
import java.util.Arrays;

/** Retains Media3 timing/silence semantics and applies EQ after Sonic pitch. */
final class NavisAudioProcessorChain implements AudioProcessorChain {
    private final DefaultAudioSink.DefaultAudioProcessorChain timing =
            new DefaultAudioSink.DefaultAudioProcessorChain();
    private final AudioProcessor[] processors;

    NavisAudioProcessorChain(NavisEqualizerProcessor equalizer) {
        AudioProcessor[] original = timing.getAudioProcessors();
        processors = Arrays.copyOf(original, original.length + 1);
        processors[original.length] = equalizer;
    }

    @Override public AudioProcessor[] getAudioProcessors() { return processors; }
    @Override public PlaybackParameters applyPlaybackParameters(PlaybackParameters parameters) {
        return timing.applyPlaybackParameters(parameters);
    }
    @Override public boolean applySkipSilenceEnabled(boolean enabled) {
        return timing.applySkipSilenceEnabled(enabled);
    }
    @Override public long getMediaDuration(long duration) { return timing.getMediaDuration(duration); }
    @Override public long getSkippedOutputFrameCount() { return timing.getSkippedOutputFrameCount(); }
}
