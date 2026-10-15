package com.navis.app.navis;

import android.app.Application;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.Handler;
import android.os.Looper;
import com.ryanheise.audioservice.NavisAudioService;

/** Routes the plugin's explicit browser binding to the app-owned service. */
public class NavisApplication extends Application {
    private Intent mediaIntent;
    private ServiceConnection mediaConnection;
    private int mediaFlags;

    @Override
    public boolean bindService(Intent intent, ServiceConnection connection, int flags) {
        Intent redirected = NavisAudioService.redirect(intent, getPackageName());
        boolean bound = super.bindService(redirected, connection, flags);
        if (bound && redirected.getComponent() != null &&
                NavisAudioService.class.getName().equals(redirected.getComponent().getClassName())) {
            mediaIntent = redirected;
            mediaConnection = connection;
            mediaFlags = flags;
        }
        return bound;
    }

    @Override
    public void unbindService(ServiceConnection connection) {
        super.unbindService(connection);
        if (connection == mediaConnection) { mediaConnection = null; mediaIntent = null; }
    }

    /** Clone fixture: order actual service destruction/recreation around a live activity. */
    public void recreateMediaServiceForDiagnostics(Runnable success, Runnable failure) {
        final Intent intent = mediaIntent;
        final ServiceConnection connection = mediaConnection;
        final int flags = mediaFlags;
        final Object original = NavisAudioService.serviceIdentityForDiagnostics();
        if (connection == null || intent == null || original == null) { failure.run(); return; }
        final Object engine = NavisAudioService.engineIdentityForDiagnostics(this);
        super.unbindService(connection);
        // Deliver the same browser suspension Android delivers on binder death.
        connection.onServiceDisconnected(intent.getComponent());
        stopService(intent);
        final Handler handler = new Handler(Looper.getMainLooper());
        handler.post(new Runnable() {
            int polls;
            boolean rebound;
            @Override public void run() {
                Object current = NavisAudioService.serviceIdentityForDiagnostics();
                if (!rebound && current == null) {
                    rebound = NavisApplication.super.bindService(intent, connection, flags);
                    if (!rebound) { failure.run(); return; }
                } else if (rebound && current != null && current != original) {
                    if (engine == NavisAudioService.engineIdentityForDiagnostics(NavisApplication.this)) success.run();
                    else failure.run();
                    return;
                }
                if (++polls >= 100) {
                    if (!rebound) NavisApplication.super.bindService(intent, connection, flags);
                    failure.run();
                    return;
                }
                handler.postDelayed(this, 50);
            }
        });
    }
}
