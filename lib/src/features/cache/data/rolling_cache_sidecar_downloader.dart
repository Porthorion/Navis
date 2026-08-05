import 'dart:async';
import 'dart:io';

import 'package:navis/src/utils/app_logger.dart';

/// Downloads a stream URI into the rolling-cache file path while playback uses
/// a separate direct stream (desktop/media_kit).
///
/// LockCachingAudioSource is not seekable under libmpv's local proxy, so
/// desktop plays via HTTPS direct stream and fills the rolling cache here.
class RollingCacheSidecarDownloader {
  RollingCacheSidecarDownloader({
    HttpClient? httpClient,
  }) : _httpClient = httpClient ?? HttpClient();

  final HttpClient _httpClient;
  int _generation = 0;
  String? _activeSongId;
  String? _activeCacheFilePath;

  String? get activeSongId => _activeSongId;

  Future<void> start({
    required String songId,
    required Uri uri,
    required String cacheFilePath,
    required void Function(double progress) onProgress,
    required Future<void> Function(File cacheFile) onComplete,
  }) async {
    if (_activeSongId == songId && _activeCacheFilePath == cacheFilePath) {
      return;
    }
    await cancel();
    final generation = ++_generation;
    _activeSongId = songId;
    _activeCacheFilePath = cacheFilePath;

    final cacheFile = File(cacheFilePath);
    if (cacheFile.existsSync() && cacheFile.lengthSync() > 0) {
      // Already on disk from a prior play — skip activity churn and
      // re-registration; CacheDao upsert is owned by the first completion.
      _clearActive(generation);
      return;
    }

    final partFile = File('$cacheFilePath.part');
    try {
      if (partFile.existsSync()) {
        await partFile.delete();
      }
      await partFile.parent.create(recursive: true);

      final request = await _httpClient.getUrl(uri);
      final response = await request.close();
      if (!_isCurrent(generation)) {
        await response.drain<void>();
        return;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Sidecar cache download failed with HTTP ${response.statusCode}',
          uri: uri,
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
        if (partFile.existsSync()) {
          await partFile.delete();
        }
        return;
      }
      if (received <= 0) {
        throw StateError('Sidecar cache download produced an empty file.');
      }
      if (cacheFile.existsSync()) {
        await cacheFile.delete();
      }
      await partFile.rename(cacheFile.path);
      onProgress(1);
      await onComplete(cacheFile);
      _clearActive(generation);
    } on Object catch (error, stackTrace) {
      AppLogger.debug(
        'Sidecar rolling-cache download failed for song=$songId: '
        '$error\n$stackTrace',
      );
      if (partFile.existsSync()) {
        try {
          await partFile.delete();
        } on Object {
          // Best-effort cleanup.
        }
      }
      _clearActive(generation);
    }
  }

  Future<void> cancel() async {
    _generation++;
    _activeSongId = null;
    _activeCacheFilePath = null;
  }

  Future<void> dispose() async {
    await cancel();
    _httpClient.close(force: true);
  }

  bool _isCurrent(int generation) => generation == _generation;

  void _clearActive(int generation) {
    if (!_isCurrent(generation)) {
      return;
    }
    _activeSongId = null;
    _activeCacheFilePath = null;
  }
}
