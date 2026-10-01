package com.navis.android_storage;

import android.content.Context;
import android.net.Uri;
import androidx.annotation.NonNull;
import androidx.documentfile.provider.DocumentFile;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodChannel;

/** Read-only storage availability for engines launched by the media service. */
public final class NavisAndroidStoragePlugin implements FlutterPlugin {
    private MethodChannel channel;

    @Override public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        final Context context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "com.navis.app/permanent_download_playback");
        channel.setMethodCallHandler((call, result) -> {
            if (!"exists".equals(call.method)) {
                result.notImplemented();
                return;
            }
            try {
                final String locator = call.argument("uri");
                if (locator == null) throw new IllegalArgumentException("Document URI is required");
                final Uri uri = Uri.parse(locator);
                if (!"content".equals(uri.getScheme())) throw new IllegalArgumentException("Content URI is required");
                final DocumentFile document = DocumentFile.fromSingleUri(context, uri);
                result.success(document != null && document.exists());
            } catch (Exception error) {
                result.error("SAF_STORAGE_ERROR", error.getMessage(), null);
            }
        });
    }

    @Override public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        channel = null;
    }
}
