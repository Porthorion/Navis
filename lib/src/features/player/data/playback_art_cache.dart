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
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/network_usage_meter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class PlaybackArtCache {
  new({
    NetworkUsageReporter? reportNetworkUsage,
    this._readPermanentArtwork,
    Duration bodyIdleTimeout = const Duration(seconds: 30),
    CoverArtHttpFileService? fileService,
  }) : _fileService =
           fileService ??
           CoverArtHttpFileService(
             connectionTimeout: _connectionTimeout,
             responseTimeout: _responseTimeout,
             bodyReadTimeout: bodyIdleTimeout,
             reportNetworkUsage: reportNetworkUsage,
           );

  static List<int>? _keySecret;
  static Future<void>? _keyInitialization;

  /// Loads the per-install key before Android publishes any content URIs.
  static Future<void> initializeKey({Directory? supportDirectory}) {
    return _keyInitialization ??= _loadKey(supportDirectory)
        .catchError((Object error, StackTrace stackTrace) {
          _keyInitialization = null;
          Error.throwWithStackTrace(error, stackTrace);
        });
  }

  static Future<void> _loadKey(Directory? supportDirectory) async {
    final directory =
        supportDirectory ?? await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, 'navis_art_key'));
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.blockingExclusive);
      // Keep every operation on the locked handle: a separate handle can
      // violate Windows locks, and closing it releases POSIX process locks.
      await handle.setPosition(0);
      List<int> secret;
      if (await handle.length() == 32) {
        secret = await handle.read(32);
      } else {
        final random = Random.secure();
        secret = List<int>.generate(32, (_) => random.nextInt(256));
        await handle.truncate(0);
        await handle.setPosition(0);
        await handle.writeFrom(secret);
        await handle.flush();
      }
      _keySecret = List<int>.unmodifiable(secret);
    } finally {
      await handle.close();
    }
  }

  /// An opaque 128-bit HMAC key shared with Android's artwork provider.
  static String fileKey(String coverArtId) {
    final secret = _keySecret;
    if (secret == null) throw StateError('Artwork key is not initialized.');
    return Hmac(
      sha256,
      secret,
    ).convert(utf8.encode(coverArtId)).toString().substring(0, 32);
  }

  @visibleForTesting
  static void resetKeyForTesting() {
    _keySecret = null;
    _keyInitialization = null;
  }

  static const Duration _connectionTimeout = Duration(seconds: 10);
  static const Duration _responseTimeout = Duration(seconds: 15);

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
      await initializeKey();
      final cacheDir = await getTemporaryDirectory();
      final file = File(
        p.join(cacheDir.path, 'navis_art_v2_${fileKey(coverArtId)}.jpg'),
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
