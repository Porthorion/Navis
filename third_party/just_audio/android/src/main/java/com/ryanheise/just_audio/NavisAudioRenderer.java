package com.ryanheise.just_audio;

import android.content.Context;
import android.os.Handler;
import androidx.media3.common.Format;
import androidx.media3.common.Timeline;
import androidx.media3.exoplayer.ExoPlaybackException;
import androidx.media3.exoplayer.audio.AudioRendererEventListener;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.MediaCodecAudioRenderer;
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector;
import androidx.media3.exoplayer.source.MediaSource;

/**
 * Tells {@link NavisEqualizerProcessor} which queue entry the next samples belong to (ReplayGain
 * at the A/B sample boundary, #392). On Media3 1.4.1 the processor does not know the item, but
 * the renderer does: {@code onStreamChanged} carries the period (so the tag, the just_audio
 * source id) and {@code onOutputStreamOffsetUsChanged} marks where that stream's samples start.
 *
 * <p>ponytail: a renderer subclass for Media3 1.4.1. On Media3 1.11+ replace it with
 * {@code AudioProcessor.flush(StreamMetadata)} periodUid/timeline inside the processor.
 */
final class NavisAudioRenderer extends MediaCodecAudioRenderer {
    private final NavisEqualizerProcessor processor;

    NavisAudioRenderer(Context context, MediaCodecSelector selector, boolean enableDecoderFallback,
            Handler handler, AudioRendererEventListener listener, AudioSink sink,
            NavisEqualizerProcessor processor) {
        super(context, selector, enableDecoderFallback, handler, listener, sink);
        this.processor = processor;
    }

    /** The just_audio source id of the window [periodUid] is in; null for an untagged source (HLS). */
    static String tagOf(Timeline timeline, Object periodUid) {
        Timeline.Period period = timeline.getPeriodByUid(periodUid, new Timeline.Period());
        Timeline.Window window = timeline.getWindow(period.windowIndex, new Timeline.Window());
        Object tag = window.mediaItem.localConfiguration == null ? null : window.mediaItem.localConfiguration.tag;
        return tag instanceof String ? (String) tag : null;
    }

    @Override
    protected void onStreamChanged(Format[] formats, long startPositionUs, long offsetUs,
            MediaSource.MediaPeriodId mediaPeriodId) throws ExoPlaybackException {
        String key = null;
        try {
            key = tagOf(getTimeline(), mediaPeriodId.periodUid);
        } catch (RuntimeException e) {
            // An entry that cannot be resolved plays at 0 dB rather than at the outgoing entry's gain.
        }
        processor.noteStream(offsetUs, key);
        super.onStreamChanged(formats, startPositionUs, offsetUs, mediaPeriodId);
    }

    @Override
    protected void onOutputStreamOffsetUsChanged(long outputStreamOffsetUs) {
        super.onOutputStreamOffsetUsChanged(outputStreamOffsetUs);
        processor.streamOffsetChanged(outputStreamOffsetUs);
    }
}
