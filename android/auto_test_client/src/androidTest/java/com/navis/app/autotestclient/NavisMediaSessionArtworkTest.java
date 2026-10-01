package com.navis.app.autotestclient;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assume.assumeTrue;

import android.content.ComponentName;
import android.net.Uri;
import android.support.v4.media.MediaBrowserCompat;
import android.support.v4.media.MediaMetadataCompat;
import android.support.v4.media.session.MediaControllerCompat;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import org.junit.Test;
import org.junit.runner.RunWith;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.regex.Pattern;

/**
 * Reads what any MediaController client (Android Auto included) can read from a
 * signed-in, playing Navis sidecar, and requires that it carries no Subsonic
 * account credentials: no stream or cover URL with a `u`, `t`, `s`, `p` or
 * `apiKey` query parameter, and cover art only as Navis's own content URIs.
 *
 * Opt-in (`-e navisArtworkCheck true`): run against a sidecar that is signed in
 * and playing a song with cover art.
 */
@RunWith(AndroidJUnit4.class)
public final class NavisMediaSessionArtworkTest {
    private static final long TIMEOUT_SECONDS = 10;
    private static final String SERVICE_CLASS = "com.ryanheise.audioservice.AudioService";
    private static final Pattern CREDENTIAL = Pattern.compile(
            "[?&](u|t|s|p|apiKey)=", Pattern.CASE_INSENSITIVE);

    @Test
    public void sessionAndBrowseExposeNoCredentials() throws Exception {
        assumeTrue("Pass navisArtworkCheck=true with a signed-in, playing sidecar",
                "true".equals(InstrumentationRegistry.getArguments().getString("navisArtworkCheck")));
        final String target = InstrumentationRegistry.getArguments().getString("navisTargetPackage");
        assertNotNull("Pass navisTargetPackage", target);
        final CountDownLatch connected = new CountDownLatch(1);
        final MediaBrowserCompat[] holder = new MediaBrowserCompat[1];
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            holder[0] = new MediaBrowserCompat(
                    InstrumentationRegistry.getInstrumentation().getTargetContext(),
                    new ComponentName(target, SERVICE_CLASS),
                    new MediaBrowserCompat.ConnectionCallback() {
                        @Override public void onConnected() { connected.countDown(); }
                    },
                    null);
            holder[0].connect();
        });
        assertTrue("MediaBrowser did not connect", connected.await(TIMEOUT_SECONDS, TimeUnit.SECONDS));
        final MediaBrowserCompat browser = holder[0];
        final List<String> published = new ArrayList<>();
        final List<String> contentArt = new ArrayList<>();
        try {
            final MediaControllerCompat controller = new MediaControllerCompat(
                    InstrumentationRegistry.getInstrumentation().getTargetContext(),
                    browser.getSessionToken());
            final MediaMetadataCompat metadata = controller.getMetadata();
            assertNotNull("Play a song before running this test", metadata);
            for (String key : metadata.keySet()) {
                final CharSequence value = metadata.getText(key);
                if (value != null) published.add(key + "=" + value);
            }
            final String icon = metadata.getString(MediaMetadataCompat.METADATA_KEY_DISPLAY_ICON_URI);
            if (icon != null) {
                assertTrue("Session cover art must be a content URI: " + icon,
                        icon.startsWith("content://" + target + ".artwork/"));
                contentArt.add(icon);
            }

            final List<MediaBrowserCompat.MediaItem> items = children(browser, browser.getRoot());
            for (MediaBrowserCompat.MediaItem root : new ArrayList<>(items)) {
                if (root.isBrowsable()) items.addAll(children(browser, root.getMediaId()));
            }
            for (MediaBrowserCompat.MediaItem item : items) {
                final Uri iconUri = item.getDescription().getIconUri();
                if (iconUri == null) continue;
                published.add(item.getMediaId() + " icon=" + iconUri);
                if ("content".equals(iconUri.getScheme())) contentArt.add(iconUri.toString());
            }
        } finally {
            InstrumentationRegistry.getInstrumentation().runOnMainSync(browser::disconnect);
        }
        for (String value : published) {
            assertFalse("Credential published to other apps: " + value,
                    CREDENTIAL.matcher(value).find());
            assertFalse("Subsonic URL published to other apps: " + value,
                    value.contains("/rest/"));
        }
        assertFalse("Expected cover art served as content URIs", contentArt.isEmpty());
    }

    private static List<MediaBrowserCompat.MediaItem> children(
            MediaBrowserCompat browser, String parent) throws InterruptedException {
        final List<MediaBrowserCompat.MediaItem> result = new ArrayList<>();
        final CountDownLatch loaded = new CountDownLatch(1);
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> browser.subscribe(parent,
                new MediaBrowserCompat.SubscriptionCallback() {
                    @Override
                    public void onChildrenLoaded(String id, List<MediaBrowserCompat.MediaItem> items) {
                        result.addAll(items);
                        loaded.countDown();
                    }
                }));
        assertTrue("Browse did not load " + parent, loaded.await(TIMEOUT_SECONDS, TimeUnit.SECONDS));
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> browser.unsubscribe(parent));
        return result;
    }
}
