import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Shared cover art cache key used by both the cache manager and clear logic.
const String coverArtCacheKey = 'navis_cover_art_cache';

/// Standard cover art size used for all album/artist cover displays outside of
/// the full-screen viewer. Using a single size ensures that navigating from any
/// list or grid to a detail screen (or back) always hits the same cache entry —
/// preventing the blank flash caused by different-size cache misses.
const int kCoverArtStandardSize = 600;

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
/// A [connectionTimeout] of 15 seconds prevents a hung TCP handshake from
/// permanently occupying one of the four download slots.
class CoverArtHttpFileService implements FileService {
  CoverArtHttpFileService() {
    _client = HttpClient()
      ..maxConnectionsPerHost = _coverArtMaxConnectionsPerHost
      ..connectionTimeout = const Duration(seconds: 15);
  }

  late final HttpClient _client;

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
    final request = await _client.getUrl(Uri.parse(url));
    headers?.forEach(request.headers.set);
    final response = await request.close();
    return _CoverArtHttpFileServiceResponse(response);
  }
}

class _CoverArtHttpFileServiceResponse implements FileServiceResponse {
  const _CoverArtHttpFileServiceResponse(this._response);

  final HttpClientResponse _response;

  @override
  int get statusCode => _response.statusCode;

  @override
  Stream<List<int>> get content => _response;

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
/// to [_coverArtMaxConnectionsPerHost] per host (issue #32) and to apply a
/// connection timeout so hung TCP handshakes do not permanently block slots.
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
