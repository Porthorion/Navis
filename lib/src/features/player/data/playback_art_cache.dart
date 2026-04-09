/// Local artwork cache for Android Auto / AAOS now-playing background art.
///
/// `audio_service` on Android only loads the album-art bitmap into the
/// MediaSession when `MediaItem.extras['artCacheFile']` contains a path to a
/// **local file**.  HTTP/HTTPS `artUri` values are silently ignored:
///
///   ```java
///   String artUri = mediaMetadata.getString(METADATA_KEY_DISPLAY_ICON_URI);
///   if (artUri != null && artUri.startsWith("content:")) {
///       artBitmap = loadArtBitmap(artUri, loadThumbnailUri);
///   } else {
///       artBitmap = null;   // ← HTTP → no art shown
///   }
///   ```
///
/// Without a bitmap in `METADATA_KEY_ALBUM_ART`, AAOS shows a blank
/// background behind the playback controls.
///
/// This cache downloads the cover art URL to a local JPEG file (keyed by
/// cover-art ID so the same file is reused across tracks in the same album),
/// and returns the file path so the handler can inject it as `artCacheFile`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class PlaybackArtCache {
  PlaybackArtCache();

  Directory? _dir;

  /// In-memory map: coverArtId → absolute file path of the cached JPEG.
  final Map<String, String> _mem = {};

  /// Completers used to deduplicate concurrent requests for the same
  /// cover-art ID.  Using [Completer] (not `Future`) avoids lint warnings
  /// about discarding a `Future` return value when calling [Map.remove].
  final Map<String, Completer<String?>> _pending = {};

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 15);

  /// Returns the local file path for [coverArtId], downloading from [artUri]
  /// on the first call.  Returns `null` if the download fails.
  Future<String?> getOrFetch(String coverArtId, Uri artUri) {
    if (_mem.containsKey(coverArtId)) return Future.value(_mem[coverArtId]);

    final existing = _pending[coverArtId];
    if (existing != null) return existing.future;

    final completer = Completer<String?>();
    _pending[coverArtId] = completer;

    // Absorb errors: art download failures are non-fatal.
    unawaited(
      _fetch(coverArtId, artUri).then(
        completer.complete,
        onError: (Object error, StackTrace st) => completer.complete(null),
      ),
    );

    return completer.future;
  }

  Future<Directory> _getDir() async {
    if (_dir != null) return _dir!;
    final tmp = await getTemporaryDirectory();
    return _dir = Directory(p.join(tmp.path, 'artwork'));
  }

  Future<String?> _fetch(String coverArtId, Uri artUri) async {
    try {
      final dir = await _getDir();
      final hash = sha1.convert(utf8.encode(coverArtId)).toString();
      final file = File(p.join(dir.path, '$hash.jpg'));

      if (file.existsSync()) {
        _mem[coverArtId] = file.path;
        return file.path;
      }

      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }

      final request = await _http.getUrl(artUri);
      final response = await request.close();
      if (response.statusCode != 200) {
        AppLogger.warning(
          'PlaybackArtCache: HTTP ${response.statusCode} for $coverArtId',
        );
        return null;
      }

      final bytes = await response.fold<List<int>>(
        <int>[],
        (buf, chunk) => buf..addAll(chunk),
      );
      await file.writeAsBytes(bytes);
      _mem[coverArtId] = file.path;
      return file.path;
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'PlaybackArtCache: failed to fetch art for $coverArtId: '
        '$error\n$stackTrace',
      );
      return null;
    } finally {
      // Completer<String?> is not a Future — removing it does not trigger the
      // unawaited_futures lint.
      _pending.remove(coverArtId);
    }
  }

  void dispose() => _http.close(force: true);
}
