import 'dart:async';
import 'dart:io';

import 'package:navis/src/utils/app_logger.dart';

/// Downloads a stream URI into the rolling-cache file path while playback uses
/// a separate direct stream (desktop/media_kit).
///
/// LockCachingAudioSource is not seekable under libmpv's local proxy, so
/// desktop plays via HTTPS direct stream and fills the rolling cache here.
class RollingCacheSidecarDownloader {
  new({HttpClient Function()? httpClientFactory})
    : _httpClientFactory = httpClientFactory ?? HttpClient.new;

  final HttpClient Function() _httpClientFactory;
  HttpClient? _activeClient;
  int _generation = 0;
  String? _activeSongId;
  String? _activeCacheFilePath;
  int? _activeReceivedBytes;
  void Function()? _activeOnTerminated;

  String? get activeSongId => _activeSongId;

  int? get activeReceivedBytes => _activeReceivedBytes;

  Future<void> start({
    required String songId,
    required Uri uri,
    required String cacheFilePath,
    required void Function(double progress) onProgress,
    required Future<void> Function(File cacheFile) onComplete,
    required void Function() onTerminated,
  }) async {
    if (_activeSongId == songId && _activeCacheFilePath == cacheFilePath) {
      return;
    }
    // Claim ownership before the first await. Otherwise two rapid start calls
    // can resume after cancel in the wrong order.
    _cancelActive();
    final generation = ++_generation;
    _activeSongId = songId;
    _activeCacheFilePath = cacheFilePath;
    _activeReceivedBytes = 0;
    _activeOnTerminated = onTerminated;
    final client = _httpClientFactory();
    _activeClient = client;

    final cacheFile = File(cacheFilePath);
    if (cacheFile.existsSync() && cacheFile.lengthSync() > 0) {
      // Already on disk from a prior play — skip activity churn and
      // re-registration; CacheDao upsert is owned by the first completion.
      client.close(force: true);
      _clearActive(generation);
      return;
    }

    // An older attempt may still be unwinding after cancellation. Give it a
    // distinct file so its cleanup cannot delete this attempt's bytes.
    final partFile = File('$cacheFilePath.part.$pid.$generation');
    try {
      await partFile.parent.create(recursive: true);
      if (!_isCurrent(generation)) return;

      final request = await client.getUrl(uri);
      if (!_isCurrent(generation)) {
        request.abort();
        return;
      }
      final response = await request.close();
      if (!_isCurrent(generation)) {
        return;
      }
      // The stream URI carries credentials, so these errors never include it.
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Sidecar cache download failed with HTTP ${response.statusCode}',
        );
      }
      final contentType = response.headers.contentType;
      if (!_mayBeAudio(contentType)) {
        // A server error document or proxy page, not the song.
        throw HttpException(
          'Sidecar cache download returned ${contentType?.mimeType} '
          'instead of audio',
        );
      }

      final contentLength = response.contentLength;
      final sink = partFile.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          if (!_isCurrent(generation)) {
            break;
          }
          sink.add(chunk);
          received += chunk.length;
          _activeReceivedBytes = received;
          if (contentLength > 0) {
            onProgress((received / contentLength).clamp(0, 1));
          } else {
            onProgress(0);
          }
        }
        await sink.flush();
        await sink.close();
      } on Object {
        await sink.close();
        rethrow;
      }

      if (!_isCurrent(generation)) {
        return;
      }
      if (received <= 0) {
        throw StateError('Sidecar cache download produced an empty file.');
      }
      // Publishing a complete file is a short synchronous critical section.
      // No cancellation can interleave between the final ownership check and
      // the rename. Never delete a newer attempt's completed file.
      if (cacheFile.existsSync()) cacheFile.deleteSync();
      partFile.renameSync(cacheFile.path);
      onProgress(1);
      await onComplete(cacheFile);
    } on Object catch (error, stackTrace) {
      if (_isCurrent(generation)) {
        AppLogger.debug(
          'Sidecar rolling-cache download failed for song=$songId: '
          '$error\n$stackTrace',
        );
      }
    } finally {
      client.close(force: true);
      if (partFile.existsSync()) {
        try {
          await partFile.delete();
        } on Object {
          // Best-effort cleanup of this attempt's file only.
        }
      }
      _clearActive(generation);
    }
  }

  void _cancelActive() {
    _generation++;
    _activeClient?.close(force: true);
    _clearActive(_generation);
  }

  Future<void> cancel() {
    _cancelActive();
    return Future<void>.value();
  }

  Future<void> dispose() async {
    await cancel();
  }

  bool _isCurrent(int generation) => generation == _generation;

  /// Whether a response of [contentType] may be audio. Servers label audio
  /// many ways (including `application/octet-stream`, `text/plain` or no type
  /// at all), so only document types are refused.
  static bool _mayBeAudio(ContentType? contentType) {
    if (contentType == null) {
      return true;
    }
    final subType = contentType.subType;
    final isDocument =
        subType == 'html' ||
        subType == 'json' ||
        subType == 'xml' ||
        subType.endsWith('+json') ||
        subType.endsWith('+xml');
    return !(isDocument &&
        (contentType.primaryType == 'text' ||
            contentType.primaryType == 'application'));
  }

  void _clearActive(int generation) {
    if (!_isCurrent(generation)) {
      return;
    }
    _activeClient = null;
    _activeSongId = null;
    _activeCacheFilePath = null;
    _activeReceivedBytes = null;
    final onTerminated = _activeOnTerminated;
    _activeOnTerminated = null;
    onTerminated?.call();
  }
}
