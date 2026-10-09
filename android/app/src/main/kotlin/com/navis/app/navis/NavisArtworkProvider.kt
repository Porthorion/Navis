package com.navis.app.navis

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileNotFoundException

/**
 * Serves cached cover art read-only as `content://<applicationId>.artwork/cover/<key>`.
 *
 * Navis caches the current song's cover (and covers of Android Auto browse
 * items) in the app cache as `navis_art_v2_<key>.jpg` (Dart `PlaybackArtCache`).
 * The media session, notification and Android Auto receive this URI instead
 * of the Subsonic cover URL, which carries the account token. Android Auto
 * runs in another process, so the provider is exported; it exposes nothing
 * but those cover files, and only keys of the cache's own form.
 */
class NavisArtworkProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("Cover art is read-only")
        val file = coverFile(uri) ?: throw FileNotFoundException(uri.toString())
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri): String? = coverKey(uri)?.let { "image/jpeg" }

    private fun coverFile(uri: Uri): File? {
        val key = coverKey(uri) ?: return null
        val cacheDir = context?.cacheDir ?: return null
        val file = File(cacheDir, "navis_art_v2_$key.jpg")
        return file.takeIf { it.isFile && it.length() > 0L }
    }

    private fun coverKey(uri: Uri): String? {
        val segments = uri.pathSegments
        if (segments.size != 2 || segments[0] != "cover") return null
        return segments[1].takeIf { COVER_KEY.matches(it) }
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    private companion object {
        /** `PlaybackArtCache.fileKey`: no path separators or dots. */
        val COVER_KEY = Regex("[a-f0-9]{32}")
    }
}
