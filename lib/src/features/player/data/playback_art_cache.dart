/// Local cover art cache for the system media controls (Android media
/// session and Android Auto, Linux MPRIS, Windows SMTC).
///
/// Downloads the cover art URL via dart:io HttpClient and returns the
/// local file path so `NavisAudioHandler._updateArtCacheFile` can inject it
/// into `MediaItem.extras` under the key `"artCacheFile"`.
///
/// Java's `AudioService.setMetadata` reads `extras["artCacheFile"]` and
/// decodes the bitmap via `BitmapFactory.decodeFile`, populating
/// `METADATA_KEY_ALBUM_ART` + `METADATA_KEY_DISPLAY_ICON` so the AAOS
/// now-playing screen and home-screen widget can display the album art.
///
/// The same file is the system's cover elsewhere: Android publishes it as
/// `content://<package>.artwork/cover/<key>` (`NavisArtworkProvider`, see
/// `AndroidSystemArt`), and the Linux MPRIS and Windows SMTC bridges publish
/// the file, so the token-bearing Subsonic cover URL never leaves the app.
library;

import 'dart:async';
import 'dart:io';

import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/network_usage_meter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class PlaybackArtCache {
  new({
    this._reportNetworkUsage,
    this.bodyIdleTimeout = const Duration(seconds: 30),
  });

  /// The file-name key of [coverArtId]'s cached file
  /// (`<temporary dir>/navis_art_<key>.jpg`). Android's
  /// `NavisArtworkProvider` serves `content://<package>.artwork/cover/<key>`
  /// from the same file and accepts only keys of this form.
  static String fileKey(String coverArtId) =>
      coverArtId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');

  static const Duration _connectionTimeout = Duration(seconds: 10);
  static const Duration _responseTimeout = Duration(seconds: 15);

  /// A body that stops arriving for this long is abandoned; it would
  /// otherwise keep this cover pending for the rest of the session.
  final Duration bodyIdleTimeout;

  final NetworkUsageReporter? _reportNetworkUsage;

  /// Shared client, so consecutive track changes reuse a keep-alive
  /// connection instead of paying a TCP and TLS handshake each time.
  HttpClient? _client;

  /// In-memory map: coverArtId → absolute file path of the cached file.
  ///
  /// Keyed by Subsonic cover-art ID rather than URL so all tracks in the same
  /// album share a single cache entry even if query params differ.
  final Map<String, String> _mem = {};

  /// Completers used to deduplicate concurrent requests for the same cover-art
  /// ID. Using [Completer] (not `Future`) avoids the `unawaited_futures` lint
  /// when removing from the map.
  final Map<String, Completer<String?>> _pending = {};

  /// The local file of [coverArtId]'s cover once this cache has it on disk,
  /// without downloading; `null` otherwise.
  String? cachedPath(String coverArtId) => _mem[coverArtId];

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
      final file = File(
        p.join(cacheDir.path, 'navis_art_${fileKey(coverArtId)}.jpg'),
      );

      // Reuse a previously downloaded file if it is non-empty and already
      // on disk (persists across app sessions so art is immediately available
      // without a network round-trip on subsequent plays).
      // A zero-byte file indicates a prior failed/partial download — delete
      // and re-download it.
      // Keep metadata access asynchronous so storage latency cannot stall UI.
      // ignore: avoid_slow_async_io
      if (await file.exists()) {
        final length = await file.length();
        if (length > 0) {
          _mem[coverArtId] = file.path;
          AppLogger.debug(
            'PlaybackArtCache: art for $coverArtId → ${file.path} (disk cache)',
          );
          return file.path;
        }
        await file.delete();
      }

      // Download using dart:io HttpClient so we use the same platform HTTP
      // stack as the rest of the app (SSL certificates, proxy settings, etc.).
      final client = _client ??= HttpClient()
        ..connectionTimeout = _connectionTimeout;
      try {
        final request = await client.getUrl(artUri).timeout(_connectionTimeout);
        final response = await request.close().timeout(_responseTimeout);

        if (response.statusCode != 200) {
          AppLogger.warning(
            'PlaybackArtCache: HTTP ${response.statusCode} for $coverArtId',
          );
          // Drain so the keep-alive connection can serve the next request.
          await response.drain<void>().timeout(_responseTimeout);
          return null;
        }

        // Reject non-image responses (e.g. HTML/XML Subsonic error pages that
        // arrive with a 200 status but are not decodable by BitmapFactory).
        final contentType = response.headers.contentType?.mimeType ?? '';
        if (!contentType.startsWith('image/')) {
          AppLogger.warning(
            'PlaybackArtCache: unexpected Content-Type "$contentType" '
            'for $coverArtId – skipping',
          );
          await response.drain<void>().timeout(_responseTimeout);
          return null;
        }

        // Write beside the final name and rename once complete: Android's
        // NavisArtworkProvider serves the final name to other apps, and a
        // later launch reuses any non-empty file there as the cover.
        final partial = File('${file.path}.part');
        final int written;
        try {
          final sink = partial.openWrite();
          try {
            // The stream's own timeout fails the pipe, which releases the
            // sink before it is closed here.
            await response.timeout(bodyIdleTimeout).pipe(sink);
          } finally {
            await sink.close().catchError((Object _) {});
          }
          written = await partial.length();
          if (written > 0) await partial.rename(file.path);
        } finally {
          // Keep metadata access asynchronous so storage latency cannot stall UI.
          // ignore: avoid_slow_async_io
          if (await partial.exists()) await partial.delete();
        }

        if (written == 0) {
          AppLogger.warning(
            'PlaybackArtCache: zero bytes written for $coverArtId',
          );
          return null;
        }

        _reportNetworkUsage?.call(
          category: NetworkUsageCategory.coverArt,
          bytes: written,
        );
        _mem[coverArtId] = file.path;
        AppLogger.debug(
          'PlaybackArtCache: art for $coverArtId → ${file.path} ($written bytes)',
        );
        return file.path;
      } on Object {
        // A failed or timed-out exchange may leave the connection unusable.
        _client = null;
        client.close(force: true);
        rethrow;
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

  void dispose() {
    _client?.close();
    _client = null;
  }
}
