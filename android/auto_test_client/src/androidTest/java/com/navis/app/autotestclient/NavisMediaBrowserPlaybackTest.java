package com.navis.app.autotestclient;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assume.assumeNotNull;

import android.content.ComponentName;
import android.os.SystemClock;
import android.support.v4.media.MediaBrowserCompat;
import android.support.v4.media.MediaMetadataCompat;
import android.support.v4.media.session.MediaControllerCompat;
import android.support.v4.media.session.PlaybackStateCompat;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import org.junit.Test;
import org.junit.runner.RunWith;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Exercises phone-projected media APIs without an activity or accessibility bridge. */
@RunWith(AndroidJUnit4.class)
public final class NavisMediaBrowserPlaybackTest {
    private interface Condition { boolean matches(); }
    private static void await(String message, Condition condition) throws Exception {
        final long deadline = SystemClock.elapsedRealtime() + 10000;
        while (SystemClock.elapsedRealtime() < deadline) {
            if (condition.matches()) return;
            Thread.sleep(50);
        }
        assertTrue(message, condition.matches());
    }
    private static List<MediaBrowserCompat.MediaItem> children(MediaBrowserCompat browser, String parent) throws Exception {
        final CountDownLatch loaded = new CountDownLatch(1);
        final List<MediaBrowserCompat.MediaItem> result = new ArrayList<>();
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> browser.subscribe(parent,
                new MediaBrowserCompat.SubscriptionCallback() {
                    @Override public void onChildrenLoaded(String id, List<MediaBrowserCompat.MediaItem> items) {
                        result.addAll(items); loaded.countDown();
                    }
                }));
        assertTrue("Browse did not load " + parent, loaded.await(10, TimeUnit.SECONDS));
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> browser.unsubscribe(parent));
        return result;
    }
    @Test public void downloadedFixtureBrowsesAndAcceptsNativeTransportCommands() throws Exception {
        final String target = InstrumentationRegistry.getArguments().getString("navisTargetPackage");
        final String song = InstrumentationRegistry.getArguments().getString("navisDownloadedFixtureSong");
        // Existing cold-start runs do not seed downloaded audio. This additional
        // gate is selected explicitly on a disposable fixture profile.
        assumeNotNull(song);
        assertNotNull("Pass navisTargetPackage", target);
        assertTrue("Fixture tests require a Dev sidecar", target.startsWith("com.navis.app.navis.dev"));
        final CountDownLatch connected = new CountDownLatch(1);
        final MediaBrowserCompat[] holder = new MediaBrowserCompat[1];
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            holder[0] = new MediaBrowserCompat(InstrumentationRegistry.getInstrumentation().getTargetContext(),
                    new ComponentName(target, "com.ryanheise.audioservice.AudioService"),
                    new MediaBrowserCompat.ConnectionCallback() {
                        @Override public void onConnected() { connected.countDown(); }
                    }, null);
            holder[0].connect();
        });
        final MediaBrowserCompat browser = holder[0];
        MediaControllerCompat controller = null;
        try {
            assertTrue("External media client did not connect", connected.await(10, TimeUnit.SECONDS));
            assertEquals("root", browser.getRoot());
            final List<MediaBrowserCompat.MediaItem> library = children(browser, "root/library");
            assertTrue("Downloaded fixture must expose Library children", !library.isEmpty());
            assertEquals("library/downloads", library.get(0).getMediaId());
            String selected = null;
            for (MediaBrowserCompat.MediaItem item : children(browser, "library/downloads")) {
                if (item.isPlayable() && item.getMediaId().startsWith("song/" + song + "?")) {
                    selected = item.getMediaId();
                    assertTrue("Downloaded leaf must retain collection context", selected.contains("context=downloads"));
                    break;
                }
            }
            assertNotNull("Downloaded fixture absent from browse tree", selected);
            controller = new MediaControllerCompat(InstrumentationRegistry.getInstrumentation().getTargetContext(), browser.getSessionToken());
            final MediaControllerCompat session = controller;
            session.getTransportControls().playFromMediaId(selected, null);
            await("Browse selection did not play", () -> session.getPlaybackState() != null && session.getPlaybackState().getState() == PlaybackStateCompat.STATE_PLAYING);
            final MediaMetadataCompat metadata = session.getMetadata();
            assertNotNull("Metadata must be published", metadata);
            assertEquals(song, metadata.getString(MediaMetadataCompat.METADATA_KEY_MEDIA_ID));
            assertNotNull("Title must be published", metadata.getString(MediaMetadataCompat.METADATA_KEY_TITLE));
            session.getTransportControls().pause();
            await("Native pause did not arrive", () -> session.getPlaybackState().getState() == PlaybackStateCompat.STATE_PAUSED);
            assertTrue("Seek capability missing", (session.getPlaybackState().getActions() & PlaybackStateCompat.ACTION_SEEK_TO) != 0);
            session.getTransportControls().seekTo(1000);
            await("Paused seek did not reach one second", () -> session.getPlaybackState().getState() == PlaybackStateCompat.STATE_PAUSED && Math.abs(session.getPlaybackState().getPosition() - 1000) <= 250);
            session.getTransportControls().setShuffleMode(PlaybackStateCompat.SHUFFLE_MODE_ALL);
            await("Shuffle did not arrive", () -> session.getShuffleMode() == PlaybackStateCompat.SHUFFLE_MODE_ALL);
            session.getTransportControls().setRepeatMode(PlaybackStateCompat.REPEAT_MODE_ALL);
            await("Repeat did not arrive", () -> session.getRepeatMode() == PlaybackStateCompat.REPEAT_MODE_ALL);
            session.getTransportControls().play();
            await("Resume did not arrive", () -> session.getPlaybackState().getState() == PlaybackStateCompat.STATE_PLAYING);
        } finally {
            if (controller != null) {
                controller.getTransportControls().pause();
                controller.getTransportControls().setShuffleMode(PlaybackStateCompat.SHUFFLE_MODE_NONE);
                controller.getTransportControls().setRepeatMode(PlaybackStateCompat.REPEAT_MODE_NONE);
            }
            InstrumentationRegistry.getInstrumentation().runOnMainSync(browser::disconnect);
        }
    }
}
