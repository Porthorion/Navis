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
  Completer<void>? _activeCancellation;
  bool _receiving = false;
  int _generation = 0;
  Completer<void>? _pauseGate;
  final Stopwatch _activeTime = Stopwatch();
  String? _activeSongId;
  String? _activeCacheFilePath;
  int? _activeReceivedBytes;
  String? _activePartFilePath;
  int? _activeTotalBytes;
  void Function()? _activeOnTerminated;

  bool get isPaused => _pauseGate != null;

  double? get activeBytesPerSecond {
    final bytes = _activeReceivedBytes;
    final micros = _activeTime.elapsedMicroseconds;
    if (bytes == null || micros == 0 || (micros < 2000000 && bytes < 65536)) {
      return null;
    }
    return bytes * 1000000 / micros;
  }

  void pause() {
    if (_activeSongId == null || isPaused) return;
    _pauseGate = Completer<void>();
    _activeTime.stop();
  }

  void resume() {
    final gate = _pauseGate;
    _pauseGate = null;
    gate?.complete();
    if (_receiving) _activeTime.start();
  }

  String? get activeSongId => _activeSongId;

  int? get activeReceivedBytes => _activeReceivedBytes;

  /// The file the running download writes: contiguous from the first byte.
  String? get activePartFilePath => _activePartFilePath;
  /// The response's Content-Length; null for a linear (transcoded) response.
  int? get activeTotalBytes => _activeTotalBytes;

  Future<void> start({
    required String songId,
    required Uri uri,
    required String cacheFilePath,
    required void Function(double progress) onProgress,
    required Future<void> Function(File cacheFile) onComplete,
    required void Function() onTerminated,
    bool isTranscoded = false,
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
    _receiving = false;
    _activeTime.reset();
    _activeOnTerminated = onTerminated;
    final cancellation = Completer<void>();
    _activeCancellation = cancellation;
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
    _activePartFilePath = partFile.path;
    try {
      await partFile.parent.create(recursive: true);
      if (!_isCurrent(generation)) return;

      final request = await client.getUrl(uri);
      if (!_isCurrent(generation)) {
        request.abort();
        return;
      }
      var response = await request.close();
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
      final etag = response.headers.value(HttpHeaders.etagHeader);
      final lastModified = response.headers.value(
        HttpHeaders.lastModifiedHeader,
      );
      final validator = etag != null && !etag.startsWith('W/')
          ? etag
          : lastModified;
      final encoding = response.headers.value(
        HttpHeaders.contentEncodingHeader,
      );
      // ponytail: validator-less origins can replace same-length originals;
      // require origin validators to detect replacements; supplied ones must match.
      final canResume =
          !isTranscoded &&
          contentLength > 0 &&
          response.headers
                  .value(HttpHeaders.acceptRangesHeader)
                  ?.trim()
                  .toLowerCase() !=
              'none' &&
          response.compressionState ==
              HttpClientResponseCompressionState.notCompressed;
      _activeTotalBytes = contentLength > 0 ? contentLength : null;
      final sink = partFile.openWrite();
      var received = 0;
      var retries = 0;
      var retryResetBytes = 0;
      try {
        while (_isCurrent(generation)) {
          try {
            if (retries > 0) {
              final request = await client.getUrl(uri);
              while (_isCurrent(generation) && _pauseGate != null) {
                await _pauseGate!.future;
              }
              if (!_isCurrent(generation)) {
                request.abort();
                return;
              }
              request.headers.set(HttpHeaders.rangeHeader, 'bytes=$received-');
              if (validator != null) {
                request.headers.set(HttpHeaders.ifRangeHeader, validator);
              }
              response = await request.close();
              if (!_isCurrent(generation)) return;
              final resumedEtag = response.headers.value(
                HttpHeaders.etagHeader,
              );
              final resumedModified = response.headers.value(
                HttpHeaders.lastModifiedHeader,
              );
              if (response.statusCode != HttpStatus.partialContent ||
                  response.headers.value(HttpHeaders.contentRangeHeader) !=
                      'bytes $received-${contentLength - 1}/$contentLength' ||
                  (response.contentLength >= 0 &&
                      response.contentLength != contentLength - received) ||
                  response.headers.value(HttpHeaders.contentEncodingHeader) !=
                      encoding ||
                  (validator != null &&
                      (validator == etag ? resumedEtag : resumedModified) !=
                          validator) ||
                  (etag != null &&
                      resumedEtag != null &&
                      resumedEtag != etag) ||
                  (lastModified != null &&
                      resumedModified != null &&
                      resumedModified != lastModified) ||
                  !_mayBeAudio(response.headers.contentType)) {
                throw StateError(
                  'Sidecar cache continuation is not the original range.',
                );
              }
            }
            await for (final chunk in response) {
              while (_isCurrent(generation) && _pauseGate != null) {
                await _pauseGate!.future;
              }
              if (!_isCurrent(generation)) break;
              _receiving = true;
              _activeTime.start();
              if (canResume && received + chunk.length > contentLength) {
                throw StateError(
                  'Sidecar cache continuation exceeds the original length.',
                );
              }
              sink.add(chunk);
              received += chunk.length;
              _activeReceivedBytes = received;
              if (retries > 0 && received - retryResetBytes >= 256 * 1024) {
                retries = 0;
                retryResetBytes = received;
              }
              if (contentLength > 0) {
                onProgress((received / contentLength).clamp(0, 1));
              } else {
                onProgress(0);
              }
            }
            break;
          } on Object catch (error) {
            if (!_isCurrent(generation) ||
                !canResume ||
                received >= contentLength ||
                retries >= 3 ||
                (error is! HttpException &&
                    error is! SocketException &&
                    error is! TlsException)) {
              rethrow;
            }
          }
          _receiving = false;
          _activeTime.stop();
          if (retries == 0) retryResetBytes = received;
          // Commit the contiguous prefix before requesting its next byte.
          await sink.flush();
          final backoff = Completer<void>();
          final timer = Timer(
            Duration(seconds: 1 << retries),
            backoff.complete,
          );
          retries++;
          try {
            await Future.any([backoff.future, cancellation.future]);
          } finally {
            timer.cancel();
          }
          while (_isCurrent(generation) && _pauseGate != null) {
            await _pauseGate!.future;
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      if (!_isCurrent(generation)) {
        return;
      }
      if (received <= 0) {
        throw StateError('Sidecar cache download produced an empty file.');
      }
      if (canResume && received != contentLength) {
        throw StateError('Sidecar cache download is incomplete.');
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
    resume();
    _activeCancellation?.complete();
    _activeCancellation = null;
    _receiving = false;
    _activeTime.stop();
    _activeClient = null;
    _activeSongId = null;
    _activeCacheFilePath = null;
    _activeReceivedBytes = null;
    _activePartFilePath = null;
    _activeTotalBytes = null;
    final onTerminated = _activeOnTerminated;
    _activeOnTerminated = null;
    onTerminated?.call();
  }
}
