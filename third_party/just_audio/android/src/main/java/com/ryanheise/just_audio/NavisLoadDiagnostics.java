package com.ryanheise.just_audio;

import android.util.Log;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.exoplayer.analytics.AnalyticsListener;
import androidx.media3.exoplayer.source.LoadEventInfo;
import androidx.media3.exoplayer.source.MediaLoadData;
import java.io.IOException;

/**
 * Navis diagnostics only: logs Media3 loads, load errors and position
 * discontinuities under {@link #TAG}. Switch off with ENABLED = false.
 */
final class NavisLoadDiagnostics implements AnalyticsListener {
    static final boolean ENABLED = true;
    static final String TAG = "NavisExoDiag";

    private static String at(EventTime t) {
        return "w=" + t.windowIndex + " pos=" + t.currentPlaybackPositionMs
            + " buf=" + t.totalBufferedDurationMs;
    }

    private static String spec(LoadEventInfo i) {
        return "uri=" + i.uri + " dsPos=" + i.dataSpec.position + " dsLen=" + i.dataSpec.length
            + " bytes=" + i.bytesLoaded + " loadMs=" + i.loadDurationMs;
    }

    @Override
    public void onLoadStarted(EventTime t, LoadEventInfo i, MediaLoadData d) {
        Log.i(TAG, "loadStarted " + at(t) + " " + spec(i));
    }

    @Override
    public void onLoadCompleted(EventTime t, LoadEventInfo i, MediaLoadData d) {
        Log.i(TAG, "loadCompleted " + at(t) + " " + spec(i) + " headers=" + i.responseHeaders);
    }

    @Override
    public void onLoadCanceled(EventTime t, LoadEventInfo i, MediaLoadData d) {
        Log.i(TAG, "loadCanceled " + at(t) + " " + spec(i));
    }

    @Override
    public void onLoadError(EventTime t, LoadEventInfo i, MediaLoadData d, IOException e, boolean wasCanceled) {
        Throwable c = e.getCause();
        StackTraceElement[] st = e.getStackTrace();
        Log.e(TAG, "loadError " + at(t) + " " + spec(i) + " wasCanceled=" + wasCanceled
            + " exc=" + e.getClass().getName() + ": " + e.getMessage()
            + " cause=" + (c == null ? "none" : c.getClass().getName() + ": " + c.getMessage())
            + " top=" + (st.length > 0 ? st[0] : "?") + " headers=" + i.responseHeaders);
    }

    @Override
    public void onPositionDiscontinuity(EventTime t, Player.PositionInfo o, Player.PositionInfo n, int reason) {
        Log.i(TAG, "discontinuity " + at(t) + " reason=" + reason
            + " old=" + o.mediaItemIndex + "@" + o.positionMs + " new=" + n.mediaItemIndex + "@" + n.positionMs);
    }

    @Override
    public void onPlaybackStateChanged(EventTime t, int state) {
        Log.i(TAG, "state " + at(t) + " state=" + state);
    }

    @Override
    public void onIsLoadingChanged(EventTime t, boolean loading) {
        Log.i(TAG, "isLoading " + at(t) + " loading=" + loading);
    }

    @Override
    public void onPlayerError(EventTime t, PlaybackException e) {
        Log.e(TAG, "playerError " + at(t) + " " + e.getErrorCodeName() + " " + e.getMessage());
    }
}
