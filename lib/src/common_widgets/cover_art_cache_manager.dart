import 'dart:async';
import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Shared cover art cache key used by both the cache manager and clear logic.
const String coverArtCacheKey = 'navis_cover_art_cache';

/// Standard cover art size used for all album/artist cover displays outside of
/// the full-screen viewer. Using a single size ensures that navigating from any
/// list or grid to a detail screen (or back) always hits the same cache entry —
/// preventing the blank flash caused by different-size cache misses.
const int kCoverArtStandardSize = 600;

/// Stable cache key for Subsonic cover art.
///
/// Subsonic token auth embeds a fresh salt in every media URL, so the URL is
/// not a stable cache identity. Key by cover-art ID and requested size instead.
String coverArtImageCacheKey(String coverArtId, int? size) {
  return '${coverArtId.trim()}:${size ?? 0}';
}

/// Sentinel value meaning «no object-count cap» — enough covers even for a
/// 100 k-track library where every album has a unique thumbnail at three sizes.
const int _coverArtCacheUnlimited = 999999;

/// Maximum concurrent HTTP connections per host for cover art image loading.
///
/// Limiting this prevents rapid library-grid scrolling from saturating the
/// HTTP connection pool and blocking detail-page images from starting promptly.
/// Four concurrent connections is enough to fill a 2 × 2 album grid quickly
/// while keeping slots available for higher-priority detail-page requests.
const int _coverArtMaxConnectionsPerHost = 4;

// ---------------------------------------------------------------------------
// Connection-limited FileService (dart:io only, no package:http dependency)
// ---------------------------------------------------------------------------

/// [FileService] backed by a connection-limited [HttpClient].
///
/// Injected into every [CacheManager] created by [createCoverArtCacheManager]
/// so that at most [_coverArtMaxConnectionsPerHost] cover-art downloads run
/// concurrently per host.  Excess requests are queued by [HttpClient] and
/// start as soon as a connection slot becomes free, ensuring that a detail
/// page opened after rapid grid scrolling does not have to wait behind 20+
/// in-progress thumbnail downloads (issue #32).
///
/// A 15-second connection timeout prevents a hung TCP handshake from
/// permanently occupying one of the four download slots.
class CoverArtHttpFileService implements FileService {
  CoverArtHttpFileService({
    Duration connectionTimeout = const Duration(seconds: 15),
    Duration responseTimeout = const Duration(seconds: 20),
    Duration bodyReadTimeout = const Duration(seconds: 20),
  }) : _connectionTimeout = connectionTimeout,
       _responseTimeout = responseTimeout,
       _bodyReadTimeout = bodyReadTimeout {
    _client = HttpClient()
      ..maxConnectionsPerHost = _coverArtMaxConnectionsPerHost
      ..connectionTimeout = connectionTimeout;
  }

  late final HttpClient _client;
  final Duration _connectionTimeout;
  final Duration _responseTimeout;
  final Duration _bodyReadTimeout;

  @override
  int concurrentFetches = _coverArtMaxConnectionsPerHost;

  /// Closes all idle connections held by the underlying [HttpClient].
  ///
  /// Call this when the [CacheManager] that owns this service is being
  /// disposed so that file descriptors are released promptly.
  void close() => _client.close(force: false);

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse(url);
    final diagnosticUri = _diagnosticUri(uri);
    AppLogger.debug('Cover art request start: $diagnosticUri');
    try {
      final request = await _client.getUrl(uri).timeout(_connectionTimeout);
      headers?.forEach(request.headers.set);
      final response = await request.close().timeout(_responseTimeout);
      AppLogger.debug(
        'Cover art response: status=${response.statusCode} '
        'length=${response.contentLength} uri=$diagnosticUri',
      );
      return _CoverArtHttpFileServiceResponse(
        response,
        bodyReadTimeout: _bodyReadTimeout,
        diagnosticUri: diagnosticUri,
      );
    } on TimeoutException catch (error) {
      AppLogger.warning(
        'Cover art request timed out for $diagnosticUri: $error',
      );
      rethrow;
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Cover art request failed for $diagnosticUri: $error\n$stackTrace',
      );
      rethrow;
    }
  }

  static Uri _diagnosticUri(Uri uri) {
    final id = uri.queryParameters['id'];
    final size = uri.queryParameters['size'];
    return uri.replace(
      queryParameters: <String, String>{
        'id': ?id,
        'size': ?size,
      },
    );
  }
}

class _CoverArtHttpFileServiceResponse implements FileServiceResponse {
  const _CoverArtHttpFileServiceResponse(
    this._response, {
    required Duration bodyReadTimeout,
    required Uri diagnosticUri,
  }) : _bodyReadTimeout = bodyReadTimeout,
       _diagnosticUri = diagnosticUri;

  final HttpClientResponse _response;
  final Duration _bodyReadTimeout;
  final Uri _diagnosticUri;

  @override
  int get statusCode => _response.statusCode;

  @override
  Stream<List<int>> get content {
    return _response.timeout(
      _bodyReadTimeout,
      onTimeout: (sink) {
        final error = TimeoutException(
          'Timed out reading cover art response body from $_diagnosticUri',
          _bodyReadTimeout,
        );
        AppLogger.warning('$error');
        sink
          ..addError(error)
          ..close();
      },
    );
  }

  @override
  int? get contentLength {
    final cl = _response.contentLength;
    return cl < 0 ? null : cl;
  }

  @override
  String? get eTag => _response.headers.value(HttpHeaders.etagHeader);

  @override
  DateTime get validTill {
    // Honour Cache-Control: max-age when present.
    final cc = _response.headers.value(HttpHeaders.cacheControlHeader);
    if (cc != null) {
      final match = RegExp(r'max-age=(\d+)').firstMatch(cc);
      if (match != null) {
        final maxAge = int.tryParse(match.group(1)!);
        if (maxAge != null) {
          return DateTime.now().add(Duration(seconds: maxAge));
        }
      }
    }
    final expires = _response.headers.expires;
    if (expires != null) return expires;
    // Fall back to the same 30-day stale period used by the cache config.
    return DateTime.now().add(const Duration(days: 30));
  }

  @override
  String get fileExtension {
    final ct = _response.headers.contentType;
    if (ct == null) return '';
    return '.${ct.subType}'; // '.jpeg', '.png', etc.
  }
}

// ---------------------------------------------------------------------------
// Cache manager factory
// ---------------------------------------------------------------------------

/// Creates a [CacheManager] for cover art images.
///
/// [maxNrOfCacheObjects] controls how many image files are stored on disk.
/// Pass `0` (the default) for an effectively unlimited cache.
///
/// [fileService] allows injecting a specific [CoverArtHttpFileService] so the
/// caller can hold a reference to it for cleanup when the manager is disposed.
/// If omitted a new service instance is created internally.
///
/// Every instance uses [CoverArtHttpFileService] to cap concurrent downloads
/// to [_coverArtMaxConnectionsPerHost] per host (issue #32) and to apply
/// request/response/body timeouts so stalled image requests do not permanently
/// block slots.
CacheManager createCoverArtCacheManager({
  int maxNrOfCacheObjects = 0,
  CoverArtHttpFileService? fileService,
}) {
  final cap = maxNrOfCacheObjects <= 0
      ? _coverArtCacheUnlimited
      : maxNrOfCacheObjects;
  return CacheManager(
    Config(
      coverArtCacheKey,
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: cap,
      fileService: fileService ?? CoverArtHttpFileService(),
    ),
  );
}
