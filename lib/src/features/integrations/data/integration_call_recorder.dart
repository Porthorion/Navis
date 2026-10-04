import 'dart:collection';

import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/utils/app_logger.dart';

/// How an external call ended.
enum IntegrationCallOutcome {
  /// A response with a success status arrived.
  ok,

  /// The request failed or the response had an error status.
  error,

  /// The guard rejected it before it left the device.
  blocked,
}

/// One external call, reduced to what is safe to keep: no query string, no
/// headers, no body and no host.
class IntegrationCallRecord {
  const new({
    required this.service,
    required this.method,
    required this.path,
    required this.durationMs,
    required this.outcome,
    required this.at,
    this.statusCode,
  });

  final IntegrationService service;
  final String method;

  /// The URL path only.
  final String path;
  final int? statusCode;
  final int durationMs;
  final IntegrationCallOutcome outcome;
  final DateTime at;

  Map<String, Object?> toJson() => <String, Object?>{
    'service': service.key,
    'method': method,
    'path': path,
    'status': statusCode,
    'ms': durationMs,
    'outcome': outcome.name,
    'blocked': outcome == IntegrationCallOutcome.blocked,
    'at': at.toUtc().toIso8601String(),
  };
}

/// Running totals for one service.
class IntegrationServiceCounters {
  /// Calls that left the device. Blocked calls are counted separately.
  int requests = 0;
  int blocked = 0;

  /// Sent calls that failed or answered with an error status.
  int errors = 0;

  /// Round-trip time summed over [requests].
  int totalMs = 0;

  Map<String, Object?> toJson() => <String, Object?>{
    'requests': requests,
    'blocked': blocked,
    'errors': errors,
    'totalMs': totalMs,
  };
}

/// A named phase of a pipeline with the sizes it handled, so a slow section
/// can be attributed to Navis or to the service.
class IntegrationSpan {
  const new({
    required this.name,
    required this.counts,
    required this.durationMs,
    required this.at,
  });

  final String name;
  final Map<String, int> counts;
  final int durationMs;
  final DateTime at;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'counts': counts,
    'ms': durationMs,
    'at': at.toUtc().toIso8601String(),
  };
}

/// In-memory ring buffer of external calls and pipeline spans, with
/// per-service counters.
///
/// It exists to answer "is this slow because of Navis or the API" with data.
/// [recordCall] takes a [Uri] and keeps only its path, so a query string such
/// as Last.fm's `api_key` can never reach the buffer, the log or the
/// diagnostics output. Headers and bodies are not accepted at all.
class IntegrationCallRecorder {
  new({
    this.callCapacity = defaultCallCapacity,
    this.spanCapacity = defaultSpanCapacity,
    DateTime Function()? now,
    this._logCalls = true,
  }) : _now = now ?? DateTime.now;

  static const defaultCallCapacity = 200;
  static const defaultSpanCapacity = 100;

  /// The path is capped so an unexpectedly long one cannot grow the buffer.
  static const _maxPathLength = 200;

  final int callCapacity;
  final int spanCapacity;
  final DateTime Function() _now;
  final bool _logCalls;

  final Queue<IntegrationCallRecord> _calls = Queue<IntegrationCallRecord>();
  final Queue<IntegrationSpan> _spans = Queue<IntegrationSpan>();
  final Map<IntegrationService, IntegrationServiceCounters> _counters = {
    for (final service in IntegrationService.values)
      service: IntegrationServiceCounters(),
  };

  void recordCall({
    required IntegrationService service,
    required String method,
    required Uri uri,
    required Duration duration,
    required IntegrationCallOutcome outcome,
    int? statusCode,
  }) {
    final path = uri.path.length > _maxPathLength
        ? uri.path.substring(0, _maxPathLength)
        : uri.path;
    final record = IntegrationCallRecord(
      service: service,
      method: method.toUpperCase(),
      path: path,
      statusCode: statusCode,
      durationMs: duration.inMilliseconds,
      outcome: outcome,
      at: _now(),
    );
    _calls.addLast(record);
    while (_calls.length > callCapacity) {
      _calls.removeFirst();
    }
    final counters = _counters[service]!;
    if (outcome == IntegrationCallOutcome.blocked) {
      counters.blocked++;
    } else {
      counters.requests++;
      counters.totalMs += record.durationMs;
      if (outcome == IntegrationCallOutcome.error) counters.errors++;
    }
    if (_logCalls) {
      AppLogger.info(
        'Integration call: ${service.key} ${record.method} ${record.path} '
        '${outcome.name}'
        '${statusCode == null ? '' : ' status=$statusCode'} '
        '${record.durationMs}ms',
      );
    }
  }

  /// Records a pipeline phase. [counts] holds sizes only, such as tracks
  /// fetched or matched.
  void span(String name, Map<String, int> counts, Duration duration) {
    _spans.addLast(
      IntegrationSpan(
        name: name,
        counts: Map<String, int>.unmodifiable(counts),
        durationMs: duration.inMilliseconds,
        at: _now(),
      ),
    );
    while (_spans.length > spanCapacity) {
      _spans.removeFirst();
    }
  }

  /// Runs [action], records it as a span and returns its result. [counts] is
  /// read after [action] completes, so it can describe what the action found.
  Future<T> timeSpan<T>(
    String name,
    Future<T> Function() action, {
    Map<String, int> Function(T result)? counts,
  }) async {
    final stopwatch = Stopwatch()..start();
    final result = await action();
    stopwatch.stop();
    span(
      name,
      counts?.call(result) ?? const <String, int>{},
      stopwatch.elapsed,
    );
    return result;
  }

  /// The most recent calls, oldest first.
  List<IntegrationCallRecord> recentCalls({int? limit}) => _tail(_calls, limit);

  /// The most recent spans, oldest first.
  List<IntegrationSpan> recentSpans({int? limit}) => _tail(_spans, limit);

  IntegrationServiceCounters countersFor(IntegrationService service) =>
      _counters[service]!;

  void clear() {
    _calls.clear();
    _spans.clear();
    for (final counters in _counters.values) {
      counters
        ..requests = 0
        ..blocked = 0
        ..errors = 0
        ..totalMs = 0;
    }
  }

  /// The diagnostics payload. Oldest entries come first in each list.
  Map<String, Object?> toJson({int callLimit = 100, int spanLimit = 50}) =>
      <String, Object?>{
        'counters': <String, Object?>{
          for (final entry in _counters.entries)
            entry.key.key: entry.value.toJson(),
        },
        'calls': <Map<String, Object?>>[
          for (final call in recentCalls(limit: callLimit)) call.toJson(),
        ],
        'spans': <Map<String, Object?>>[
          for (final span in recentSpans(limit: spanLimit)) span.toJson(),
        ],
      };

  static List<T> _tail<T>(Queue<T> queue, int? limit) {
    final all = queue.toList(growable: false);
    if (limit == null || limit >= all.length) return all;
    if (limit <= 0) return const [];
    return all.sublist(all.length - limit);
  }
}
