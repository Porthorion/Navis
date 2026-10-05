import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/common_widgets/cover_art_recovery.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/network_usage_meter.dart';

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
///
/// [revision] is the targeted refresh revision: zero/null keeps the legacy
/// key layout so existing offline artwork survives cache-key migration, and a
/// bumped revision loads the refetched bytes without clearing any other cache
/// entry.
String coverArtImageCacheKey(String coverArtId, int? size, {int? revision}) {
  final normalizedRevision = revision ?? 0;
  if (normalizedRevision <= 0) {
    return '${coverArtId.trim()}:${size ?? 0}';
  }
  return '${coverArtId.trim()}:r$normalizedRevision:${size ?? 0}';
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

/// Upper bound on how much of a non-image success body is buffered for
/// classification before it is rejected.
const int _coverArtErrorDocumentSampleBytes = 64 * 1024;

/// Redirect hops followed per artwork request; each is policy-checked.
const int _coverArtMaxRedirects = 5;

/// Request header naming the integration feature an artwork load belongs to
/// (for example `radio.nowPlaying`). [CoverArtHttpFileService] consumes it to
/// check that feature's switches at dispatch time and never sends it.
const String coverArtFeatureHeader = 'x-navis-artwork-feature';

/// Image-request headers that tie a load to the integration feature
/// [featureKey], so a download queued for that feature is refused once the
/// feature is switched off.
Map<String, String> coverArtFeatureHeaders(String featureKey) =>
    <String, String>{coverArtFeatureHeader: featureKey};

/// True when the payload head carries a known image signature (JPEG, PNG,
/// GIF, WebP, BMP, ICO). Content types are untrusted: some servers answer
/// missing artwork with HTTP 200 and a non-image body.
bool _looksLikeImagePayload(List<int> head) {
  if (head.length >= 2 && head[0] == 0xFF && head[1] == 0xD8) {
    return true; // JPEG (SOI)
  }
  if (head.length >= 8 &&
      head[0] == 0x89 &&
      head[1] == 0x50 &&
      head[2] == 0x4E &&
      head[3] == 0x47 &&
      head[4] == 0x0D &&
      head[5] == 0x0A &&
      head[6] == 0x1A &&
      head[7] == 0x0A) {
    return true; // PNG
  }
  if (head.length >= 6 &&
      head[0] == 0x47 &&
      head[1] == 0x49 &&
      head[2] == 0x46 &&
      head[3] == 0x38 &&
      (head[4] == 0x37 || head[4] == 0x39) &&
      head[5] == 0x61) {
    return true; // GIF87a / GIF89a
  }
  if (head.length >= 12 &&
      head[0] == 0x52 &&
      head[1] == 0x49 &&
      head[2] == 0x46 &&
      head[3] == 0x46 &&
      head[8] == 0x57 &&
      head[9] == 0x45 &&
      head[10] == 0x42 &&
      head[11] == 0x50) {
    return true; // WebP (RIFF....WEBP)
  }
  if (head.length >= 2 && head[0] == 0x42 && head[1] == 0x4D) {
    return true; // BMP
  }
  if (head.length >= 4 &&
      head[0] == 0x00 &&
      head[1] == 0x00 &&
      head[2] == 0x01 &&
      head[3] == 0x00) {
    return true; // ICO
  }
  return false;
}

enum CoverArtLoadPriority { background, visible, critical }

/// An image URL was refused by the integration policy before any request.
class CoverArtBlockedException implements Exception {
  const new(this.host);

  final String host;

  @override
  String toString() => 'Cover art load blocked by integration policy: $host';
}

class CoverArtLoadCanceledException implements Exception {
  const new(this.key);

  final String key;

  @override
  String toString() => 'Cover art load canceled before network start: $key';
}

/// The server answered an artwork request with an HTTP success whose body is
/// not an image (a Subsonic XML error, a proxy login page, or HTML). The
/// bytes are rejected before the cache manager can persist them.
class CoverArtInvalidResponseException implements Exception {
  const new(this.contentType);

  final String contentType;

  @override
  String toString() =>
      'Cover art response was not an image (content-type: $contentType)';
}

class CoverArtLoadInterest {
  new _(this._onDispose);

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
  new _(this._onRelease);

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
  new({
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
    final counts = _interests.putIfAbsent(key, _CoverArtInterestCounts.new);
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
      final priorityCompare = _priorityRank(b.priority)
          .compareTo(_priorityRank(a.priority));
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
  new({
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
  new({
    CoverArtLoadCoordinator? loadCoordinator,
    this._reportNetworkUsage,
    this.onMissingCover,
    this._allowUri,
    this._allowFeatureUri,
    this._isServerUri,
    this._connectionTimeout = const Duration(seconds: 15),
    this._responseTimeout = const Duration(seconds: 20),
    this._bodyReadTimeout = const Duration(seconds: 20),
  }) : _loadCoordinator = loadCoordinator ?? CoverArtLoadCoordinator();

  late HttpClient _client = _createClient();
  final CoverArtLoadCoordinator _loadCoordinator;
  final NetworkUsageReporter? _reportNetworkUsage;

  /// Invoked when the server answers that a cover-art reference does not
  /// exist so the caller can schedule one coalesced entity-metadata refresh
  /// (plan F7).
  final void Function(String coverArtId)? onMissingCover;

  /// Integration policy check run before any request. A refused URL throws
  /// [CoverArtBlockedException] without touching the network. Null allows
  /// everything.
  final bool Function(Uri uri)? _allowUri;

  /// Feature-level policy check for requests that carry
  /// [coverArtFeatureHeader]: whether [Uri] may load for the feature named by
  /// the second argument. It runs next to [_allowUri] at every point the
  /// request could be dispatched, so a feature switched off while the download
  /// waited in a queue is refused. Null allows everything [_allowUri] allows.
  final bool Function(Uri uri, String featureKey)? _allowFeatureUri;

  /// Whether [Uri] points at the user's own server. Missing-cover recovery
  /// asks that server to refresh a cover id, so it only runs for its URLs; an
  /// external 404 must not trigger it. Null treats every URL as the server's.
  final bool Function(Uri uri)? _isServerUri;

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
    final originalUri = Uri.parse(url);
    var uri = originalUri;
    final featureKey = headers?[coverArtFeatureHeader];
    // The feature header is ours: it is never forwarded to any host.
    final requestHeaders = headers == null || featureKey == null
        ? headers
        : (<String, String>{...headers}..remove(coverArtFeatureHeader));
    bool allowed() =>
        (_allowUri?.call(uri) ?? true) &&
        (featureKey == null ||
            (_allowFeatureUri?.call(uri, featureKey) ?? true));
    void checkAllowed() {
      if (!allowed()) {
        throw CoverArtBlockedException(uri.host);
      }
    }

    checkAllowed();
    var diagnosticUri = _diagnosticUri(uri);
    final loadKey = _loadKey(uri);
    final lease = await _loadCoordinator.acquire(loadKey);
    AppLogger.debug('Cover art request start: $diagnosticUri');
    try {
      // Redirects are followed here, not by HttpClient, so every hop is
      // checked against the policy. The check also runs after each wait
      // (a download slot, a connection), since the policy can change
      // meanwhile, and always before the request is sent.
      HttpClientResponse response;
      for (var hop = 0; ; hop++) {
        checkAllowed();
        final request = await _client.getUrl(uri).timeout(_connectionTimeout);
        request.followRedirects = false;
        // Caller headers never travel to a different origin.
        if (uri.origin == originalUri.origin) {
          requestHeaders?.forEach(request.headers.set);
        }
        if (!allowed()) {
          request.abort();
          throw CoverArtBlockedException(uri.host);
        }
        response = await request.close().timeout(_responseTimeout);
        if (!response.isRedirect) break;
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>().timeout(_bodyReadTimeout);
        if (location == null || hop >= _coverArtMaxRedirects) {
          throw const HttpException('Cover art redirect refused');
        }
        uri = uri.resolve(location);
        diagnosticUri = _diagnosticUri(uri);
      }
      final missingCoverHook = (_isServerUri?.call(uri) ?? true)
          ? onMissingCover
          : null;
      AppLogger.debug(
        'Cover art response: status=${response.statusCode} '
        'length=${response.contentLength} uri=$diagnosticUri',
      );
      final contentType = response.headers.contentType;
      // Typed failure taxonomy (plan F5): a missing reference and an
      // authentication rejection are distinguishable surface conditions.
      final missingCover =
          response.statusCode == HttpStatus.notFound ||
          response.statusCode == HttpStatus.gone;
      final authRejected =
          response.statusCode == HttpStatus.unauthorized ||
          response.statusCode == HttpStatus.forbidden;
      if (missingCover || authRejected) {
        lease.release();
        final category = classifyCoverArtFailure(
          null,
          statusCode: response.statusCode,
        );
        AppLogger.info(
          'Cover art $category for $diagnosticUri '
          '(status ${response.statusCode})',
        );
        if (missingCover) {
          final coverId = uri.queryParameters['id'];
          if (coverId != null && coverId.isNotEmpty) {
            missingCoverHook?.call(coverId);
          }
        }
        // Drain so the keep-alive connection is not poisoned for the next
        // queued request before the typed failure propagates.
        try {
          await response.drain<void>().timeout(_bodyReadTimeout);
        } on Object {
          // The rejection itself must not be masked by a drain failure.
        }
        throw CoverArtFetchException(category, statusCode: response.statusCode);
      }
      if ((response.statusCode == HttpStatus.ok ||
              response.statusCode == HttpStatus.accepted) &&
          contentType != null &&
          contentType.primaryType != 'image') {
        // HTTP-success but not artwork: a Subsonic error document, a proxy
        // login page, or HTML. Classify a bounded body sample so a server
        // that reports missing artwork through an error document (Navidrome)
        // triggers the missing-cover recovery, then reject so nothing
        // invalid is cached.
        lease.release();
        final sample = await _drainBoundedSample(
          response,
          timeout: _bodyReadTimeout,
        );
        if (looksLikeSubsonicErrorDocument(sample)) {
          final coverId = uri.queryParameters['id'];
          if (coverId != null && coverId.isNotEmpty) {
            missingCoverHook?.call(coverId);
          }
          AppLogger.info(
            'Cover art missingCoverReference reported through an error '
            'document for $diagnosticUri',
          );
          throw CoverArtFetchException(
            CoverArtFailureCategory.missingCoverReference,
            statusCode: response.statusCode,
          );
        }
        final description = contentType.toString();
        throw CoverArtInvalidResponseException(description);
      }
      return _CoverArtHttpFileServiceResponse(
        response,
        bodyReadTimeout: _bodyReadTimeout,
        diagnosticUri: diagnosticUri,
        coverArtId: uri.queryParameters['id'],
        onMissingCover: missingCoverHook,
        onTimeout: _resetClientAfterTimeout,
        onDone: lease.release,
        onBytesRead: (bytes) {
          _reportNetworkUsage?.call(
            category: NetworkUsageCategory.coverArt,
            bytes: bytes,
          );
        },
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
    } on CoverArtBlockedException {
      // An expected policy refusal, not a failure worth a warning.
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

  /// Reads the response body in a single pass, buffering at most
  /// [_coverArtErrorDocumentSampleBytes] for classification while still
  /// consuming the remainder so the keep-alive connection is not poisoned
  /// for the next queued request. Body-read failures never mask the pending
  /// classification.
  static Future<List<int>> _drainBoundedSample(
    HttpClientResponse response, {
    required Duration timeout,
  }) async {
    final buffer = BytesBuilder(copy: false);
    try {
      await for (final chunk in response.timeout(
        timeout,
        onTimeout: (sink) => sink.close(),
      )) {
        if (buffer.length < _coverArtErrorDocumentSampleBytes) {
          buffer.add(chunk);
        }
      }
    } on Object {
      // The caller's classification must not be masked by a body-read
      // failure.
    }
    return buffer.takeBytes();
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
      queryParameters: <String, String>{'id': ?id, 'size': ?size},
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
  new(
    this._response, {
    required this._bodyReadTimeout,
    required this._diagnosticUri,
    required this._onTimeout,
    required this._onDone,
    required this._onBytesRead,
    this.coverArtId,
    this.onMissingCover,
  }) {
    if (!_expectsConsumedBody) {
      _releaseOnce();
      unawaited(_discardBody());
    }
  }

  final HttpClientResponse _response;
  final Duration _bodyReadTimeout;
  final Uri _diagnosticUri;
  final void Function() _onTimeout;
  final void Function() _onDone;
  final void Function(int bytes) _onBytesRead;

  /// Cover-art identity of the request, used to route missing-cover
  /// evidence discovered while reading the body.
  final String? coverArtId;

  /// Missing-cover recovery hook, shared with [CoverArtHttpFileService].
  final void Function(String coverArtId)? onMissingCover;

  @override
  int get statusCode => _response.statusCode;

  @override
  Stream<List<int>> get content async* {
    if (!_expectsConsumedBody) {
      return;
    }
    var bytesRead = 0;
    var inspectedHead = false;
    var headIsImage = false;
    var headIsErrorDocument = false;
    try {
      await for (final chunk in _response.timeout(
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
      )) {
        bytesRead += chunk.length;
        if (!inspectedHead) {
          inspectedHead = true;
          headIsImage = _looksLikeImagePayload(chunk);
          headIsErrorDocument =
              !headIsImage && looksLikeSubsonicErrorDocument(chunk);
        }
        if (!headIsImage) {
          // Consume the remainder (keeps the connection reusable) but
          // yield nothing, so the cache manager never persists a
          // non-image payload.
          continue;
        }
        yield chunk;
      }
    } finally {
      if (bytesRead > 0) {
        _onBytesRead(bytesRead);
      }
      _releaseOnce();
    }
    if (!inspectedHead) {
      throw const CoverArtInvalidResponseException('empty body');
    }
    if (!headIsImage) {
      if (headIsErrorDocument) {
        final id = coverArtId;
        if (id != null && id.isNotEmpty) {
          onMissingCover?.call(id);
        }
        AppLogger.info(
          'Cover art missingCoverReference reported through an error '
          'document for $_diagnosticUri',
        );
        throw CoverArtFetchException(
          CoverArtFailureCategory.missingCoverReference,
          statusCode: _response.statusCode,
        );
      }
      throw CoverArtInvalidResponseException('non-image payload bytes');
    }
  }

  bool get _expectsConsumedBody {
    return statusCode == HttpStatus.ok || statusCode == HttpStatus.accepted;
  }

  bool _released = false;

  void _releaseOnce() {
    if (_released) {
      return;
    }
    _released = true;
    _onDone();
  }

  Future<void> _discardBody() async {
    try {
      await _response
          .timeout(
            _bodyReadTimeout,
            onTimeout: (sink) {
              final error = TimeoutException(
                'Timed out discarding cover art response body from $_diagnosticUri',
                _bodyReadTimeout,
              );
              AppLogger.warning('$error');
              sink.close();
              scheduleMicrotask(_onTimeout);
            },
          )
          .drain<void>();
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Cover art response discard failed for $_diagnosticUri: '
        '$error\n$stackTrace',
      );
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
  String cacheKey = coverArtCacheKey,
  CoverArtHttpFileService? fileService,
  CoverArtLoadCoordinator? loadCoordinator,
  NetworkUsageReporter? reportNetworkUsage,
}) {
  final cap = maxNrOfCacheObjects <= 0
      ? _coverArtCacheUnlimited
      : maxNrOfCacheObjects;
  return CacheManager(
    Config(
      cacheKey,
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: cap,
      fileService:
          fileService ??
          CoverArtHttpFileService(
            loadCoordinator: loadCoordinator,
            reportNetworkUsage: reportNetworkUsage,
          ),
    ),
  );
}
