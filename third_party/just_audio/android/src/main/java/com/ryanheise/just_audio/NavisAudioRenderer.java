package com.ryanheise.just_audio;

import android.content.Context;
import android.os.Handler;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.Timeline;
import androidx.media3.decoder.DecoderInputBuffer;
import androidx.media3.exoplayer.ExoPlaybackException;
import androidx.media3.exoplayer.audio.AudioRendererEventListener;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.MediaCodecAudioRenderer;
import androidx.media3.exoplayer.mediacodec.MediaCodecAdapter;
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector;
import androidx.media3.exoplayer.source.MediaSource;
import java.nio.ByteBuffer;

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
    // Media3's own threshold (its largestQueuedPresentationTimeUs is private): the last input queued
    // to the codec, the point after which an output buffer belongs to the next stream.
    private long largestQueuedUs = C.TIME_UNSET;

    NavisAudioRenderer(Context context, MediaCodecAdapter.Factory codecAdapterFactory,
            MediaCodecSelector selector, boolean enableDecoderFallback, Handler handler,
            AudioRendererEventListener listener, AudioSink sink, NavisEqualizerProcessor processor) {
        super(context, codecAdapterFactory, selector, enableDecoderFallback, handler, listener, sink);
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
        processor.noteStream(offsetUs, key, largestQueuedUs);
        super.onStreamChanged(formats, startPositionUs, offsetUs, mediaPeriodId);
    }

    @Override
    protected void onOutputStreamOffsetUsChanged(long outputStreamOffsetUs) {
        super.onOutputStreamOffsetUsChanged(outputStreamOffsetUs);
        processor.streamOffsetChanged(outputStreamOffsetUs);
    }

    @Override
    protected void onQueueInputBuffer(DecoderInputBuffer buffer) throws ExoPlaybackException {
        largestQueuedUs = Math.max(largestQueuedUs, buffer.timeUs);
        super.onQueueInputBuffer(buffer);
    }

    @Override
    protected void resetCodecStateForFlush() {
        super.resetCodecStateForFlush();
        largestQueuedUs = C.TIME_UNSET;
    }

    /**
     * Media3 hands a buffer to the sink first and only then applies a pending stream change, so on
     * a codec whose last output of the old song stays below the threshold (opus) the new song's first
     * buffer would be written under the old gain. Tell the processor before the sink sees it.
     */
    @Override
    protected boolean processOutputBuffer(long positionUs, long elapsedRealtimeUs, MediaCodecAdapter codec,
            ByteBuffer buffer, int bufferIndex, int bufferFlags, int sampleCount,
            long bufferPresentationTimeUs, boolean isDecodeOnlyBuffer, boolean isLastBuffer, Format format)
            throws ExoPlaybackException {
        processor.outputBuffer(bufferPresentationTimeUs);
        return super.processOutputBuffer(positionUs, elapsedRealtimeUs, codec, buffer, bufferIndex, bufferFlags,
                sampleCount, bufferPresentationTimeUs, isDecodeOnlyBuffer, isLastBuffer, format);
    }

    // Media3 discards its pending stream changes here, so the processor must too.
    @Override
    protected void onPositionReset(long positionUs, boolean joining) throws ExoPlaybackException {
        processor.dropPendingStreams();
        super.onPositionReset(positionUs, joining);
    }

    @Override
    protected void onDisabled() {
        processor.dropPendingStreams();
        super.onDisabled();
    }
}
