package com.navis.app.autotestclient;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import android.content.ComponentName;
import android.os.Bundle;
import android.support.v4.media.MediaBrowserCompat;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import org.junit.Test;
import org.junit.runner.RunWith;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * Connects to Navis exactly as an Android Auto head unit does.
 *
 * This app deliberately contains no activity and runs outside Navis's process.
 * The harness force-stops Navis immediately before this test, proving that the
 * media service can create the Flutter engine and answer browse requests before
 * MainActivity has ever been launched.
 */
@RunWith(AndroidJUnit4.class)
public final class NavisMediaBrowserColdStartTest {
    private static final long CONNECTION_TIMEOUT_SECONDS = 10;
    private static final String SERVICE_CLASS =
            "com.ryanheise.audioservice.AudioService";
    private static final String ROOT_ID = "root";

    @Test
    public void coldServiceStartConnectsAndExposesTheFourRootTabs() throws Exception {
        final String targetPackage = InstrumentationRegistry.getArguments()
                .getString("navisTargetPackage");
        assertNotNull("Pass -e navisTargetPackage <Navis dev package>", targetPackage);

        final CountDownLatch connected = new CountDownLatch(1);
        final CountDownLatch connectionFailed = new CountDownLatch(1);
        final CountDownLatch childrenLoaded = new CountDownLatch(1);
        final List<MediaBrowserCompat.MediaItem> rootChildren = new ArrayList<>();

        final MediaBrowserCompat[] browserHolder = new MediaBrowserCompat[1];
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            final MediaBrowserCompat browser = new MediaBrowserCompat(
                    InstrumentationRegistry.getInstrumentation().getTargetContext(),
                    new ComponentName(targetPackage, SERVICE_CLASS),
                    new MediaBrowserCompat.ConnectionCallback() {
                        @Override
                        public void onConnected() {
                            connected.countDown();
                        }

                        @Override
                        public void onConnectionFailed() {
                            connectionFailed.countDown();
                        }

                        @Override
                        public void onConnectionSuspended() {
                            connectionFailed.countDown();
                        }
                    },
                    null
            );
            browserHolder[0] = browser;
            browser.connect();
        });
        assertTrue(
                "MediaBrowser did not connect to a cold Navis service within 10 seconds",
                connected.await(CONNECTION_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        );
        final MediaBrowserCompat browser = browserHolder[0];
        assertEquals("Navis exposed an unexpected media-browser root", ROOT_ID, browser.getRoot());

        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            browser.subscribe(ROOT_ID, new MediaBrowserCompat.SubscriptionCallback() {
                @Override
                public void onChildrenLoaded(String parentId, List<MediaBrowserCompat.MediaItem> children) {
                    rootChildren.addAll(children);
                    childrenLoaded.countDown();
                }
            });
        });
        assertTrue(
                "Navis did not load root children within 10 seconds",
                childrenLoaded.await(CONNECTION_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        );
        assertEquals(4, rootChildren.size());

        final List<String> rootIds = new ArrayList<>();
        for (MediaBrowserCompat.MediaItem item : rootChildren) {
            assertTrue("Every Navis root item must be browsable",
                    item.isBrowsable() && !item.isPlayable());
            rootIds.add(item.getMediaId());
        }
        assertEquals(
                Arrays.asList("root/liked", "root/recent", "root/playlists", "root/library"),
                rootIds
        );

        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            browser.unsubscribe(ROOT_ID);
            browser.disconnect();
        });
        assertEquals("MediaBrowser connection unexpectedly failed", 1, connectionFailed.getCount());
    }
}
