import 'dart:async';

import 'package:navis/src/api/subsonic_error.dart';

/// Per-operation limits and attribution shared by the executor and transport.
/// Async zones keep concurrent UI/search traffic out of a sync's accounting.
class SyncRequestScope {
  new({
    required this.allowedEndpoints,
    required this.maxRequests,
    required this.maxNewestPages,
    required this.maxAlbumHydrations,
    required this.maxResponseBytes,
    required this.maxTotalBytes,
    required this.maxConcurrency,
    required Duration maxDuration,
    required this.canRequest,
    this.onStop,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _deadline = _now().add(maxDuration);
  }

  final Set<String> allowedEndpoints;
  final int maxRequests;
  final int maxNewestPages;
  final int maxAlbumHydrations;
  final int maxConcurrency;
  final int? maxResponseBytes;
  final int? maxTotalBytes;
  final bool Function() canRequest;
  final void Function()? onStop;
  final DateTime Function() _now;
  late final DateTime _deadline;
  static final _zoneKey = Object();
  static SyncRequestScope? get current =>
      Zone.current[_zoneKey] as SyncRequestScope?;
  final Map<String, int> endpointRequests = {};
  final Map<String, int> logicalRequests = {};
  final List<Completer<void>> _waiting = [];
  int _active = 0;
  bool transportObserved = false;
  int requestCount = 0;
  int byteCount = 0;
  int retryCount = 0;
  int _acceptedAttempts = 0;
  int _failedAttempts = 0;
  final _transportAttempts = <SyncTransportAttempt>[];
  final Map<String, int> endpointBytes = {};
  static const retainedTransportAttempts = 128;
  SubsonicSyncLimitException? _stopped;
  SubsonicSyncLimitException? get stopped => _stopped;
  int get remainingAlbumHydrations => maxAlbumHydrations > 0
      ? maxAlbumHydrations - (logicalRequests['getAlbum'] ?? 0)
      : maxRequests;

  int hydrationBatchLimit(int preferred) {
    check();
    if (remainingAlbumHydrations <= 0) _stop('entityBudget');
    var limit = preferred < maxConcurrency ? preferred : maxConcurrency;
    if (remainingAlbumHydrations < limit) limit = remainingAlbumHydrations;
    // Commit a bounded batch before admitting the next one. A larger nominal
    // DAO chunk must not discard all successful details at the entity limit.
    if (maxTotalBytes != null && maxResponseBytes != null) {
      final affordable = (maxTotalBytes! - byteCount) ~/ maxResponseBytes!;
      if (affordable < limit) limit = affordable < 1 ? 1 : affordable;
    }
    return limit;
  }

  Future<T> run<T>(Future<T> Function() action) async {
    final timer = Timer(_deadline.difference(_now()), () {
      _stopped ??= const SubsonicSyncLimitException('timeBudget');
      onStop?.call();
    });
    try {
      return await runZoned(action, zoneValues: {_zoneKey: this});
    } finally {
      timer.cancel();
    }
  }

  Never _stop(String reason) {
    onStop?.call();
    throw _stopped ??= SubsonicSyncLimitException(reason);
  }

  void check([String? endpoint]) {
    if (_stopped != null) throw _stopped!;
    if (!canRequest()) _stop('networkPolicy');
    if (!_now().isBefore(_deadline)) _stop('timeBudget');
    // The typed scan-status observation rides every plan: the promotion
    // guard records it at collection and promotion time, and it is a tiny
    // read-only call that must never fail an endpoint allowlist.
    if (endpoint != null &&
        endpoint != 'getScanStatus' &&
        !allowedEndpoints.contains(endpoint)) {
      _stop('endpointPolicy');
    }
    if (maxTotalBytes != null && byteCount >= maxTotalBytes!) {
      _stop('byteBudget');
    }
  }

  Future<T> request<T>(String endpoint, Future<T> Function() action) async {
    while (_active >= maxConcurrency) {
      final waiter = Completer<void>();
      _waiting.add(waiter);
      await waiter.future;
    }
    _active++;
    try {
      check(endpoint);
      final count = logicalRequests[endpoint] ?? 0;
      if (endpoint == 'getNewestAlbumList2' &&
          maxNewestPages > 0 &&
          count >= maxNewestPages) {
        _stop('pageBudget');
      }
      if (endpoint == 'getAlbum' &&
          maxAlbumHydrations > 0 &&
          count >= maxAlbumHydrations) {
        _stop('entityBudget');
      }
      if (logicalRequests.values.fold(0, (a, b) => a + b) >= maxRequests) {
        _stop('requestBudget');
      }
      logicalRequests[endpoint] = count + 1;
      return await action();
    } finally {
      _active--;
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
    }
  }

  SyncTransportAttempt beginTransport(
    String endpoint, {
    SyncTransportAttempt? retryOf,
  }) {
    transportObserved = true;
    check(endpoint);
    if (requestCount >= maxRequests) _stop('requestBudget');
    requestCount++;
    if (retryOf != null) retryCount++;
    endpointRequests[endpoint] = (endpointRequests[endpoint] ?? 0) + 1;
    final attempt = SyncTransportAttempt._(
      this,
      endpoint,
      requestCount,
      retryOf?.requestOrdinal ?? requestCount,
      retryOf == null ? 0 : retryOf.retry + 1,
      _now(),
    );
    _transportAttempts.add(attempt);
    if (_transportAttempts.length > retainedTransportAttempts) {
      _transportAttempts.removeAt(0);
    }
    return attempt;
  }

  /// Contains endpoint names and aggregate timings only, never request URLs,
  /// parameters, entity identifiers, response bodies or exception messages.
  Map<String, Object?> transportTelemetry() => {
    'observed': transportObserved,
    'requests': requestCount,
    'retries': retryCount,
    'envelopeAccepted': _acceptedAttempts,
    'failed': _failedAttempts,
    'running': requestCount - _acceptedAttempts - _failedAttempts,
    'bytes': transportObserved ? byteCount : null,
    'endpointRequests': Map<String, int>.of(endpointRequests),
    'endpointBytes': Map<String, int>.of(endpointBytes),
    'omittedAttempts': requestCount - _transportAttempts.length,
    'attempts': [for (final attempt in _transportAttempts) attempt.toJson()],
  };
}

class SyncTransportAttempt {
  new _(
    this.scope,
    this.endpoint,
    this.ordinal,
    this.requestOrdinal,
    this.retry,
    this.startedAt,
  );
  final SyncRequestScope scope;
  final String endpoint;
  final int ordinal;
  final int requestOrdinal;
  final int retry;
  final DateTime startedAt;
  final Stopwatch _duration = Stopwatch()..start();
  String _outcome = 'running';
  int _observed = 0;

  void observe(int bytes) {
    if (bytes <= _observed) return;
    final delta = bytes - _observed;
    scope.byteCount += delta;
    scope.endpointBytes[endpoint] =
        (scope.endpointBytes[endpoint] ?? 0) + delta;
    _observed = bytes;
    if ((scope.maxResponseBytes != null && bytes > scope.maxResponseBytes!) ||
        (scope.maxTotalBytes != null &&
            scope.byteCount > scope.maxTotalBytes!)) {
      scope._stop('byteBudget');
    }
  }

  void finish({required bool succeeded}) {
    if (_outcome != 'running') return;
    _duration.stop();
    _outcome = succeeded ? 'envelopeAccepted' : 'failed';
    if (succeeded) {
      scope._acceptedAttempts++;
    } else {
      scope._failedAttempts++;
    }
  }

  Map<String, Object?> toJson() => {
    'ordinal': ordinal,
    'requestOrdinal': requestOrdinal,
    'endpoint': endpoint,
    'retry': retry,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'elapsedMicros': _duration.elapsedMicroseconds,
    'bytes': _observed,
    'outcome': _outcome,
  };
}

String syncEndpointForPath(String path, Map<String, dynamic>? query) =>
    switch (path.split('/').last) {
      'getAlbumList2.view' =>
        query?['type'] == 'newest' ? 'getNewestAlbumList2' : 'getAlbumList2',
      'getStarred2.view' => 'getStarredContent',
      'search3.view' => 'searchSongsPage',
      final name => name.replaceFirst('.view', ''),
    };
