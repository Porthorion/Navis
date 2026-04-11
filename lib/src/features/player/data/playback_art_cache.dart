/// Local artwork cache for Android Auto / AAOS now-playing background art.
///
/// Downloads the cover art URL via [dart:io] [HttpClient] directly, then
/// returns the local file path so the audio handler can replace
/// [MediaItem.artUri] with a `file://` URI.
///
/// When audio_service's listener sees a `file`-scheme artUri it calls
/// `sendToPlatform(artUri.toFilePath())` synchronously — bypassing the async
/// `artFetchOperationId` cancellation path — which injects `artCacheFile` into
/// the platform MediaItem. Java's AudioService reads `artCacheFile` and decodes
/// the bitmap via `BitmapFactory.decodeFile`, loading it into
/// `METADATA_KEY_ALBUM_ART` so the AAOS home screen widget can display it.
library;

import 'dart:async';
import 'dart:io';

import 'package:navis/src/utils/app_logger.dart';
import 'package:path_provider/path_provider.dart';

class PlaybackArtCache {
  PlaybackArtCache();

  /// In-memory map: coverArtId → absolute file path of the cached file.
  ///
  /// Keyed by Subsonic cover-art ID rather than URL so all tracks in the same
  /// album share a single cache entry even if query params differ.
  final Map<String, String> _mem = {};

  /// Completers used to deduplicate concurrent requests for the same cover-art
  /// ID. Using [Completer] (not `Future`) avoids the `unawaited_futures` lint
  /// when removing from the map.
  final Map<String, Completer<String?>> _pending = {};

  /// Returns the local file path for [coverArtId], downloading from [artUri]
  /// on the first call. Returns `null` if the download fails.
  Future<String?> getOrFetch(String coverArtId, Uri artUri) {
    if (_mem.containsKey(coverArtId)) return Future.value(_mem[coverArtId]);

    final existing = _pending[coverArtId];
    if (existing != null) return existing.future;

    final completer = Completer<String?>();
    _pending[coverArtId] = completer;

    unawaited(
      _fetch(coverArtId, artUri).then(
        completer.complete,
        onError: (Object error, StackTrace st) => completer.complete(null),
      ),
    );

    return completer.future;
  }

  Future<String?> _fetch(String coverArtId, Uri artUri) async {
    try {
      final cacheDir = await getTemporaryDirectory();
      // Sanitise coverArtId for use as a file name component.
      final safeName = coverArtId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
      final file = File('${cacheDir.path}/navis_art_$safeName.jpg');

      // Reuse a previously downloaded file if it exists (persists across
      // app sessions so art is immediately available without a network round
      // trip on subsequent plays).
      if (await file.exists()) {
        _mem[coverArtId] = file.path;
        AppLogger.debug(
          'PlaybackArtCache: art for $coverArtId → ${file.path} (cached on disk)',
        );
        return file.path;
      }

      // Download using dart:io HttpClient so we use the same platform HTTP
      // stack as the rest of the app (SSL certificates, proxy settings, etc.).
      final client = HttpClient();
      try {
        final request = await client.getUrl(artUri);
        final response = await request.close();

        if (response.statusCode != 200) {
          AppLogger.warning(
            'PlaybackArtCache: HTTP ${response.statusCode} for $coverArtId',
          );
          return null;
        }

        final sink = file.openWrite();
        await response.pipe(sink);

        _mem[coverArtId] = file.path;
        AppLogger.debug('PlaybackArtCache: art for $coverArtId → ${file.path}');
        return file.path;
      } finally {
        client.close();
      }
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'PlaybackArtCache: failed to fetch art for $coverArtId: '
        '$error\n$stackTrace',
      );
      return null;
    } finally {
      _pending.remove(coverArtId);
    }
  }

  void dispose() {}
}
