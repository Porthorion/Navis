import 'dart:async';
import 'dart:math' as math;

import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/daos/scrobble_dao.dart';
import 'package:navis/src/utils/app_logger.dart';

abstract class ScrobbleService {
  void start();

  Future<void> enqueueNowPlaying({
    required String songId,
    required String sessionKey,
  });

  Future<void> enqueueSubmission({
    required String songId,
    required String sessionKey,
  });

  Future<void> flushDue();

  Future<void> dispose();
}

class DriftScrobbleService implements ScrobbleService {
  DriftScrobbleService({
    required ScrobbleDao dao,
    required SubsonicApiClient? Function() readApiClient,
    required bool Function() readScrobbleEnabled,
    required bool Function() readReachable,
    DateTime Function()? now,
    this.nowPlayingRetention = const Duration(hours: 2),
    this.submissionRetention = const Duration(days: 7),
    this.baseRetryDelay = const Duration(seconds: 15),
    this.maxRetryDelay = const Duration(minutes: 30),
    this.dispatchInterval = const Duration(seconds: 30),
  }) : _dao = dao,
       _readApiClient = readApiClient,
       _readScrobbleEnabled = readScrobbleEnabled,
       _readReachable = readReachable,
       _now = now ?? DateTime.now;

  final ScrobbleDao _dao;
  final SubsonicApiClient? Function() _readApiClient;
  final bool Function() _readScrobbleEnabled;
  final bool Function() _readReachable;
  final DateTime Function() _now;

  final Duration nowPlayingRetention;
  final Duration submissionRetention;
  final Duration baseRetryDelay;
  final Duration maxRetryDelay;
  final Duration dispatchInterval;

  Timer? _dispatchTimer;
  bool _isDispatching = false;
  bool _started = false;

  @override
  void start() {
    if (_started) {
      return;
    }
    _started = true;
    unawaited(_syncDispatchTimer());
  }

  @override
  Future<void> enqueueNowPlaying({
    required String songId,
    required String sessionKey,
  }) async {
    if (!_readScrobbleEnabled()) {
      return;
    }
    final now = _now();
    await _dao.enqueue(
      songId: songId,
      submission: false,
      sessionKey: sessionKey,
      createdAt: now,
      nextAttemptAt: now,
      expiresAt: now.add(nowPlayingRetention),
    );
    _ensureDispatchTimer();
  }

  @override
  Future<void> enqueueSubmission({
    required String songId,
    required String sessionKey,
  }) async {
    if (!_readScrobbleEnabled()) {
      return;
    }
    final now = _now();
    await _dao.enqueue(
      songId: songId,
      submission: true,
      sessionKey: sessionKey,
      createdAt: now,
      nextAttemptAt: now,
      expiresAt: now.add(submissionRetention),
    );
    _ensureDispatchTimer();
  }

  @override
  Future<void> flushDue() async {
    if (_isDispatching) {
      return;
    }
    _isDispatching = true;
    try {
      if (!_readScrobbleEnabled()) {
        await _dao.clearAll();
        _stopDispatchTimer();
        return;
      }

      if (!_readReachable()) {
        return;
      }

      final api = _readApiClient();
      if (api == null) {
        return;
      }

      final now = _now();
      await _dao.pruneExpired(now);
      final events = await _dao.getDueEntries(now);

      for (final event in events) {
        try {
          await api.scrobble(
            event.songId,
            submission: event.submission,
          );
          await _dao.markDelivered(event.id);
        } on Object catch (error) {
          final attempts = event.attempts + 1;
          final nextAttemptAt = now.add(_retryDelay(attempts));
          if (!event.expiresAt.isAfter(nextAttemptAt)) {
            await _dao.markDelivered(event.id);
            continue;
          }
          await _dao.reschedule(
            id: event.id,
            attempts: attempts,
            nextAttemptAt: nextAttemptAt,
            lastError: error.toString(),
          );
        }
      }
    } on Object catch (error, stackTrace) {
      AppLogger.warning('Scrobble dispatch failed: $error\n$stackTrace');
    } finally {
      _isDispatching = false;
      await _syncDispatchTimer();
    }
  }

  Duration _retryDelay(int attempts) {
    final exponent = math.max(0, attempts - 1);
    final base = baseRetryDelay.inSeconds * math.pow(2, exponent);
    final capped = math.min(base.toInt(), maxRetryDelay.inSeconds);
    return Duration(seconds: capped);
  }

  @override
  Future<void> dispose() async {
    _stopDispatchTimer();
  }

  void _ensureDispatchTimer() {
    _dispatchTimer ??= Timer.periodic(dispatchInterval, (_) {
      unawaited(flushDue());
    });
  }

  void _stopDispatchTimer() {
    _dispatchTimer?.cancel();
    _dispatchTimer = null;
  }

  Future<void> _syncDispatchTimer() async {
    if (!_started) {
      return;
    }

    final count = await _dao.countEntries();
    if (count > 0) {
      _ensureDispatchTimer();
    } else {
      _stopDispatchTimer();
    }
  }
}
