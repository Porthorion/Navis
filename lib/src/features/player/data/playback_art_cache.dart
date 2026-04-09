/// Local artwork cache for Android Auto / AAOS now-playing background art.
///
/// Downloads the cover art URL via [AudioService.cacheManager] — the same
/// flutter_cache_manager instance used by audio_service's own art pre-loading
/// — then returns the local file path so the audio handler can replace
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

import 'package:audio_service/audio_service.dart';
import 'package:navis/src/utils/app_logger.dart';

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
      // Reuse audio_service's cache manager so we share HTTP client config,
      // SSL settings, and any art already fetched by audio_service's own
      // _loadArtwork pass for the same URL.
      final file = await AudioService.cacheManager.getSingleFile(
        artUri.toString(),
      );
      final path = file.path;
      _mem[coverArtId] = path;
      AppLogger.debug('PlaybackArtCache: art for $coverArtId → $path');
      return path;
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

  // flutter_cache_manager lifecycle is managed by audio_service.
  void dispose() {}
}
