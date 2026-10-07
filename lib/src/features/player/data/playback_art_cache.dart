/// Local cover art cache for the system media controls (Android media
/// session and Android Auto, Linux MPRIS, Windows SMTC).
///
/// Downloads cover art through the shared guarded artwork transport and
/// returns the local file path so `NavisAudioHandler._updateArtCacheFile`
/// can inject it into `MediaItem.extras` under the key `"artCacheFile"`.
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
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/utils/network_usage_meter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class PlaybackArtCache {
  new({
    NetworkUsageReporter? reportNetworkUsage,
    this._readPermanentArtwork,
    this.bodyIdleTimeout = const Duration(seconds: 30),
    CoverArtHttpFileService? fileService,
  }) : _fileService =
           fileService ??
           CoverArtHttpFileService(
             connectionTimeout: _connectionTimeout,
             responseTimeout: _responseTimeout,
             bodyReadTimeout: bodyIdleTimeout,
             reportNetworkUsage: reportNetworkUsage,
           );

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

  /// The durable cover of a downloaded song, used before any network fetch
  /// so downloaded music shows its cover offline (Bluetooth/AVRCP, Android
  /// Auto, MPRIS, SMTC).
  final Future<File?> Function(String coverArtId)? _readPermanentArtwork;

  /// Shared client, so consecutive track changes reuse a keep-alive
  /// connection instead of paying a TCP and TLS handshake each time.
  final CoverArtHttpFileService _fileService;

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

      final permanent = await _readPermanentArtwork?.call(coverArtId);
      if (permanent != null) {
        // Copied beside the final name and renamed, like a download, so the
        // provider never serves a half-copied cover.
        final partial = File('${file.path}.part');
        try {
          await permanent.copy(partial.path);
          await partial.rename(file.path);
          _mem[coverArtId] = file.path;
          AppLogger.debug(
            'PlaybackArtCache: art for $coverArtId → ${file.path} '
            '(download artwork)',
          );
          return file.path;
        } on FileSystemException catch (error) {
          AppLogger.warning(
            'PlaybackArtCache: download artwork copy failed: $error',
          );
          // Keep metadata access asynchronous so storage latency cannot stall UI.
          // ignore: avoid_slow_async_io
          if (await partial.exists()) await partial.delete();
        }
      }

      final response = await _fileService.get(artUri.toString());
      if (response.statusCode != HttpStatus.ok) {
        await response.content.drain<void>();
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
          // The shared transport owns the body timeout and failure recording.
          await response.content.pipe(sink);
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

      _mem[coverArtId] = file.path;
      AppLogger.debug(
        'PlaybackArtCache: art for $coverArtId → ${file.path} ($written bytes)',
      );
      return file.path;
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
    _fileService.close();
  }
}
