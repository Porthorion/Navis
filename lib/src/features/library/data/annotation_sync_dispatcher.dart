import 'package:uuid/uuid.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/database/daos/star_sync_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/utils/app_logger.dart';

/// One network writer for local likes and ratings. Only acknowledgement of the
/// current queue version removes it; every failure retains the user's intent.
class AnnotationSyncDispatcher {
  AnnotationSyncDispatcher({
    required StarSyncDao dao,
    required SubsonicApiClient? Function() readClient,
    required Future<String?> Function() readAccountIdentity,
    required bool Function() canConnect,
    DateTime Function()? now,
  }) : _dao = dao,
       _readClient = readClient,
       _readAccountIdentity = readAccountIdentity,
       _canConnect = canConnect,
       _now = now ?? DateTime.now;

  final StarSyncDao _dao;
  final SubsonicApiClient? Function() _readClient;
  final Future<String?> Function() _readAccountIdentity;
  final bool Function() _canConnect;
  final DateTime Function() _now;
  StreamSubscription<List<StarSyncQueueTableData>>? _subscription;
  Timer? _timer;
  Timer? _leaseHeartbeat;
  Future<void>? _inFlight;
  CancelToken? _cancelToken;
  bool _disposed = false;
  String? _activeOwner;

  void start() {
    _subscription ??= _dao.watchPendingActions().listen((_) => _kick());
    _kick();
  }

  void _kick() {
    if (_disposed) return;
    unawaited(
      flush().catchError((Object error) {
        AppLogger.warning(
          'Annotation dispatch deferred: ${error.runtimeType}.',
        );
      }),
    );
  }

  Future<void> sessionChanged() async {
    if (_disposed) return;
    _cancelToken?.cancel();
    await _dao.releaseAuthenticationFailures();
    await flush();
  }

  Future<void> flush() {
    if (_disposed) return Future<void>.value();
    return _inFlight ??= Future<void>(_drain).whenComplete(() async {
      _inFlight = null;
      await _scheduleNext();
    });
  }

  Future<void> _drain() async {
    if (_disposed || !_canConnect() || _readClient() == null) return;
    if (await _dao.nextDue(_now()) == null || _disposed) return;
    if (await _readAccountIdentity() == null || _disposed) return;
    final owner = const Uuid().v4();
    if (!await _dao.acquireDispatchLease(owner, _now())) return;
    if (_disposed) {
      await _dao.releaseDispatchLease(owner);
      return;
    }
    _activeOwner = owner;
    var owned = true;
    final heartbeat = _leaseHeartbeat = Timer.periodic(
      const Duration(seconds: 10),
      (_) async {
        try {
          owned = await _dao.renewDispatchLease(owner, _now());
        } on Object {
          owned = false;
        }
        if (!owned && _activeOwner == owner) _cancelToken?.cancel();
      },
    );
    try {
      await _drainOwned(owner, () => owned);
    } finally {
      heartbeat.cancel();
      if (identical(_leaseHeartbeat, heartbeat)) _leaseHeartbeat = null;
      if (_activeOwner == owner) _activeOwner = null;
      await _dao.releaseDispatchLease(owner);
    }
  }

  Future<void> _drainOwned(String owner, bool Function() stillOwned) async {
    // Bound one wake-up; a persisted remainder is picked up by the timer.
    for (
      var count = 0;
      count < 50 && !_disposed && stillOwned() && _canConnect();
      count++
    ) {
      final client = _readClient();
      final account = await _readAccountIdentity();
      if (client == null || account == null) return;
      final entry = await _dao.nextDue(_now());
      if (entry == null || _disposed) return;
      if (!await _dao.isCurrent(entry.id)) continue;
      if (!await _dao.renewDispatchLease(owner, _now())) return;
      final token = CancelToken();
      _cancelToken = token;
      try {
        if (entry.operation == 'rating') {
          await client.setRating(
            entry.itemId,
            int.parse(entry.action),
            cancelToken: token,
          );
        } else if (entry.action == 'star') {
          await client.star(
            entry.itemId,
            itemType: entry.itemType,
            cancelToken: token,
          );
        } else {
          await client.unstar(
            entry.itemId,
            itemType: entry.itemType,
            cancelToken: token,
          );
        }
        if (_disposed ||
            !identical(client, _readClient()) ||
            account != await _readAccountIdentity())
          return;
        if (!await _dao.withDispatchLease(owner, _now(), () async {
          await _dao.removeAction(entry.id);
        }))
          return;
      } on Object catch (error) {
        if (_disposed ||
            !identical(client, _readClient()) ||
            account != await _readAccountIdentity())
          return;
        final authentication = error is SubsonicAuthException;
        final delay = authentication
            ? const Duration(days: 1)
            : Duration(
                seconds: math.min(
                  3600,
                  15 * (1 << math.min(entry.attemptCount, 8)),
                ),
              );
        if (!await _dao.withDispatchLease(
          owner,
          _now(),
          () => _dao.recordFailure(
            entry,
            errorType: authentication
                ? 'authentication'
                : error.runtimeType.toString(),
            retryAt:
                error is SubsonicApiException &&
                    error.retryAt != null &&
                    error.retryAt!.isAfter(_now().add(delay))
                ? error.retryAt!
                : _now().add(delay),
          ),
        ))
          return;
        if (authentication || error is SubsonicConnectionException) return;
      } finally {
        if (identical(_cancelToken, token)) _cancelToken = null;
      }
    }
  }

  Future<void> _scheduleNext() async {
    _timer?.cancel();
    if (_disposed) return;
    final pending = await _dao.getPendingActions();
    if (_disposed || pending.isEmpty) return;
    final now = _now();
    final next = pending
        .map((row) => row.notBefore ?? now)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final delay = next.difference(now);
    _timer = Timer(
      delay > Duration.zero ? delay : const Duration(seconds: 30),
      _kick,
    );
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _leaseHeartbeat?.cancel();
    _cancelToken?.cancel();
    unawaited(_subscription?.cancel());
  }
}
