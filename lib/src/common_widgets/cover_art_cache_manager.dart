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

/// Number of requests flutter_cache_manager may hand to the file service.
///
/// This is intentionally higher than the transport connection limit. The
/// coordinator below owns prioritisation and cancellation; the HTTP client
/// remains the hard safety cap for actual sockets.
const int _coverArtMaxScheduledFetches = 64;

enum CoverArtLoadPriority {
  background,
  visible,
  critical,
}

class CoverArtLoadCanceledException implements Exception {
  const CoverArtLoadCanceledException(this.key);

  final String key;

  @override
  String toString() => 'Cover art load canceled before network start: $key';
}

class CoverArtLoadInterest {
  CoverArtLoadInterest._(this._onDispose);

  final void Function() _onDispose;
  var _disposed = false;

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _onDispose();
  }
}

class CoverArtLoadLease {
  CoverArtLoadLease._(this._onRelease);

  final void Function() _onRelease;
  var _released = false;

  void release() {
    if (_released) {
      return;
    }
    _released = true;
    _onRelease();
  }
}

class CoverArtLoadCoordinator {
  CoverArtLoadCoordinator({
    this.maxActiveDownloads = _coverArtMaxConnectionsPerHost,
    this.criticalReserve = 1,
  }) : assert(maxActiveDownloads > 0, 'maxActiveDownloads must be positive'),
       assert(criticalReserve >= 0, 'criticalReserve must not be negative');

  final int maxActiveDownloads;
  final int criticalReserve;
  final Map<String, _CoverArtInterestCounts> _interests =
      <String, _CoverArtInterestCounts>{};
  final Map<String, _ScheduledCoverArtRequest> _requestsByKey =
      <String, _ScheduledCoverArtRequest>{};
  final List<_ScheduledCoverArtRequest> _queued = <_ScheduledCoverArtRequest>[];
  final Set<_ScheduledCoverArtRequest> _active = <_ScheduledCoverArtRequest>{};
  var _nextSequence = 0;

  int get activeCount => _active.length;

  int get queuedCount => _queued.length;

  int interestCount(String key) => _interests[key]?.total ?? 0;

  CoverArtLoadInterest trackInterest(
    String key,
    CoverArtLoadPriority priority,
  ) {
    final counts = _interests.putIfAbsent(
      key,
      _CoverArtInterestCounts.new,
    );
    counts.increment(priority);
    _updateQueuedPriority(key);
    _pump();
    return CoverArtLoadInterest._(() {
      final current = _interests[key];
      if (current == null) {
        return;
      }
      current.decrement(priority);
      if (current.total == 0) {
        _interests.remove(key);
      }
      _cancelStaleQueuedRequests();
      _updateQueuedPriority(key);
      _pump();
    });
  }

  Future<CoverArtLoadLease> acquire(String key) {
    final existing = _requestsByKey[key];
    if (existing != null) {
      existing.refCount++;
      return existing.admitted.future.then((_) {
        return CoverArtLoadLease._(() => _release(existing));
      });
    }

    final priority =
        _interestPriorityFor(key) ?? CoverArtLoadPriority.background;
    final request = _ScheduledCoverArtRequest(
      key: key,
      sequence: _nextSequence++,
      priority: priority,
      requiresLiveInterest: priority != CoverArtLoadPriority.background,
    );
    _requestsByKey[key] = request;
    _queued.add(request);
    _pump();
    return request.admitted.future.then((_) {
      return CoverArtLoadLease._(() => _release(request));
    });
  }

  CoverArtLoadPriority? _interestPriorityFor(String key) {
    return _interests[key]?.priority;
  }

  void _updateQueuedPriority(String key) {
    final request = _requestsByKey[key];
    if (request == null || request.active || request.canceled) {
      return;
    }
    request.priority = _interestPriorityFor(key) ?? request.priority;
  }

  void _cancelStaleQueuedRequests() {
    for (final request in _queued.toList(growable: false)) {
      if (!request.requiresLiveInterest || request.canceled) {
        continue;
      }
      if (_interestPriorityFor(request.key) != null) {
        continue;
      }
      request.canceled = true;
      _queued.remove(request);
      _requestsByKey.remove(request.key);
      request.admitted.completeError(
        CoverArtLoadCanceledException(request.key),
      );
    }
  }

  void _pump() {
    _cancelStaleQueuedRequests();
    while (true) {
      final request = _nextAdmissibleRequest();
      if (request == null) {
        return;
      }
      _queued.remove(request);
      request.active = true;
      _active.add(request);
      request.admitted.complete();
    }
  }

  _ScheduledCoverArtRequest? _nextAdmissibleRequest() {
    _queued.sort((a, b) {
      final priorityCompare = _priorityRank(
        b.priority,
      ).compareTo(_priorityRank(a.priority));
      if (priorityCompare != 0) {
        return priorityCompare;
      }
      return a.sequence.compareTo(b.sequence);
    });
    for (final request in _queued) {
      if (_canAdmit(request)) {
        return request;
      }
    }
    return null;
  }

  bool _canAdmit(_ScheduledCoverArtRequest request) {
    if (_active.length >= maxActiveDownloads) {
      return false;
    }
    if (request.priority == CoverArtLoadPriority.critical) {
      return true;
    }
    final nonCriticalLimit = (maxActiveDownloads - criticalReserve).clamp(
      1,
      maxActiveDownloads,
    );
    final nonCriticalActive = _active
        .where((active) => active.priority != CoverArtLoadPriority.critical)
        .length;
    return nonCriticalActive < nonCriticalLimit;
  }

  void _release(_ScheduledCoverArtRequest request) {
    request.refCount--;
    if (request.refCount > 0) {
      return;
    }
    _active.remove(request);
    _requestsByKey.remove(request.key);
    _pump();
  }

  int _priorityRank(CoverArtLoadPriority priority) {
    switch (priority) {
      case CoverArtLoadPriority.critical:
        return 3;
      case CoverArtLoadPriority.visible:
        return 2;
      case CoverArtLoadPriority.background:
        return 1;
    }
  }
}

class _CoverArtInterestCounts {
  int critical = 0;
  int visible = 0;
  int background = 0;

  int get total => critical + visible + background;

  CoverArtLoadPriority? get priority {
    if (critical > 0) {
      return CoverArtLoadPriority.critical;
    }
    if (visible > 0) {
      return CoverArtLoadPriority.visible;
    }
    if (background > 0) {
      return CoverArtLoadPriority.background;
    }
    return null;
  }

  void increment(CoverArtLoadPriority priority) {
    switch (priority) {
      case CoverArtLoadPriority.critical:
        critical++;
      case CoverArtLoadPriority.visible:
        visible++;
      case CoverArtLoadPriority.background:
        background++;
    }
  }

  void decrement(CoverArtLoadPriority priority) {
    switch (priority) {
      case CoverArtLoadPriority.critical:
        critical--;
      case CoverArtLoadPriority.visible:
        visible--;
      case CoverArtLoadPriority.background:
        background--;
    }
  }
}

class _ScheduledCoverArtRequest {
  _ScheduledCoverArtRequest({
    required this.key,
    required this.sequence,
    required this.priority,
    required this.requiresLiveInterest,
  });

  final String key;
  final int sequence;
  final bool requiresLiveInterest;
  final Completer<void> admitted = Completer<void>();
  CoverArtLoadPriority priority;
  int refCount = 1;
  bool active = false;
  bool canceled = false;
}

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
    CoverArtLoadCoordinator? loadCoordinator,
    Duration connectionTimeout = const Duration(seconds: 15),
    Duration responseTimeout = const Duration(seconds: 20),
    Duration bodyReadTimeout = const Duration(seconds: 20),
  }) : _loadCoordinator = loadCoordinator ?? CoverArtLoadCoordinator(),
       _connectionTimeout = connectionTimeout,
       _responseTimeout = responseTimeout,
       _bodyReadTimeout = bodyReadTimeout;

  late HttpClient _client = _createClient();
  final CoverArtLoadCoordinator _loadCoordinator;
  final Duration _connectionTimeout;
  final Duration _responseTimeout;
  final Duration _bodyReadTimeout;
  var _closed = false;

  @override
  int concurrentFetches = _coverArtMaxScheduledFetches;

  /// Closes all idle connections held by the underlying [HttpClient].
  ///
  /// Call this when the [CacheManager] that owns this service is being
  /// disposed so that file descriptors are released promptly.
  void close({bool force = false}) {
    _closed = true;
    _client.close(force: force);
  }

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse(url);
    final diagnosticUri = _diagnosticUri(uri);
    final loadKey = _loadKey(uri);
    final lease = await _loadCoordinator.acquire(loadKey);
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
        onTimeout: _resetClientAfterTimeout,
        onDone: lease.release,
      );
    } on TimeoutException catch (error) {
      AppLogger.warning(
        'Cover art request timed out for $diagnosticUri: $error',
      );
      _resetClientAfterTimeout();
      lease.release();
      rethrow;
    } on CoverArtLoadCanceledException {
      lease.release();
      rethrow;
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Cover art request failed for $diagnosticUri: $error\n$stackTrace',
      );
      lease.release();
      rethrow;
    }
  }

  HttpClient _createClient() {
    return HttpClient()
      ..maxConnectionsPerHost = _coverArtMaxConnectionsPerHost
      ..connectionTimeout = _connectionTimeout;
  }

  void _resetClientAfterTimeout() {
    if (_closed) {
      return;
    }
    _client.close(force: true);
    _client = _createClient();
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

  static String _loadKey(Uri uri) {
    final id = uri.queryParameters['id']?.trim();
    if (id != null && id.isNotEmpty) {
      final size = int.tryParse(uri.queryParameters['size'] ?? '');
      return coverArtImageCacheKey(id, size);
    }
    return uri.toString();
  }
}

class _CoverArtHttpFileServiceResponse implements FileServiceResponse {
  const _CoverArtHttpFileServiceResponse(
    this._response, {
    required Duration bodyReadTimeout,
    required Uri diagnosticUri,
    required void Function() onTimeout,
    required void Function() onDone,
  }) : _bodyReadTimeout = bodyReadTimeout,
       _diagnosticUri = diagnosticUri,
       _onTimeout = onTimeout,
       _onDone = onDone;

  final HttpClientResponse _response;
  final Duration _bodyReadTimeout;
  final Uri _diagnosticUri;
  final void Function() _onTimeout;
  final void Function() _onDone;

  @override
  int get statusCode => _response.statusCode;

  @override
  Stream<List<int>> get content async* {
    try {
      yield* _response.timeout(
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
          scheduleMicrotask(_onTimeout);
        },
      );
    } finally {
      _onDone();
    }
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
  CoverArtLoadCoordinator? loadCoordinator,
}) {
  final cap = maxNrOfCacheObjects <= 0
      ? _coverArtCacheUnlimited
      : maxNrOfCacheObjects;
  return CacheManager(
    Config(
      coverArtCacheKey,
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: cap,
      fileService:
          fileService ??
          CoverArtHttpFileService(loadCoordinator: loadCoordinator),
    ),
  );
}
