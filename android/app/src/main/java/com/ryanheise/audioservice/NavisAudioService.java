package com.ryanheise.audioservice;

import android.content.ComponentName;
import android.content.Intent;
import android.util.Log;
import java.lang.reflect.Field;
import java.util.List;

/** Repairs the listener when Android recreates the service around a live engine. */
public class NavisAudioService extends AudioService {
    @Override
    public void onCreate() {
        super.onCreate();
        restoreListener();
    }

    // Keep all dependency-private access here. The JVM contract test protects
    // the field names; a runtime upgrade mismatch must leave the service alive.
    static boolean restoreListener() {
        try {
            Field listenerField = AudioService.class.getDeclaredField("listener");
            Field handlerField = AudioServicePlugin.class.getDeclaredField("audioHandlerInterface");
            listenerField.setAccessible(true);
            handlerField.setAccessible(true);
            ServiceListener handler = (ServiceListener) handlerField.get(null);
            if (listenerField.get(null) != null || handler == null) return false;
            AudioService.init(handler);
            handler.onCustomAction("navisServiceRecreated", null);
            return true;
        } catch (ReflectiveOperationException | RuntimeException error) {
            Log.w("NavisAudioService", "Media listener recovery unavailable");
            return false;
        }
    }

    /**
     * audio_service 0.18.19 acquires its wakelock on play but releases it on
     * pause only when androidStopForegroundOnPause is true. Navis keeps the
     * notification while paused, so release the lock on every not-playing state.
     */
    @Override
    void setState(List<MediaControl> controls, long actionBits, int[] compactActionIndices, AudioProcessingState processingState, boolean playing, long position, long bufferedPosition, float speed, long updateTime, Integer errorCode, String errorMessage, int repeatMode, int shuffleMode, boolean captioningEnabled, Long queueIndex) {
        super.setState(controls, actionBits, compactActionIndices, processingState, playing, position, bufferedPosition, speed, updateTime, errorCode, errorMessage, repeatMode, shuffleMode, captioningEnabled, queueIndex);
        if (!shouldReleaseWakeLock(playing)) return;
        try {
            releaseWakeLock();
        } catch (RuntimeException error) {
            // A one-off release failure must not reach the channel; the next paused state retries.
            Log.w("NavisAudioService", "Wakelock release failed");
        }
    }

    public static boolean shouldReleaseWakeLock(boolean playing) { return !playing; }

    public static Object serviceIdentityForDiagnostics() { return AudioService.instance; }

    public static Object engineIdentityForDiagnostics(android.content.Context context) {
        return AudioServicePlugin.getFlutterEngine(context);
    }

    /** audio_service 0.18.19 starts its hard-coded component when promoting. */
    @Override
    public ComponentName startForegroundService(Intent intent) {
        return super.startForegroundService(redirect(intent, getPackageName()));
    }

    @Override
    public ComponentName startService(Intent intent) {
        return super.startService(redirect(intent, getPackageName()));
    }

    public static Intent redirect(Intent intent, String packageName) {
        ComponentName component = intent.getComponent();
        if (component == null || !packageName.equals(component.getPackageName())
                || !AudioService.class.getName().equals(component.getClassName())) return intent;
        return new Intent(intent).setComponent(new ComponentName(packageName, NavisAudioService.class.getName()));
    }
}
