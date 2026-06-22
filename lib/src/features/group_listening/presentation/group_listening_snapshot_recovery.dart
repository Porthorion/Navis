import 'dart:async';

import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';

typedef GroupListeningSnapshotRefresher =
    Future<void> Function({required String reason});

/// Coordinates snapshot-required recovery and retry scheduling.
class GroupListeningSnapshotRecovery {
  GroupListeningSnapshotRecovery({
    required GroupListeningSnapshotRefresher refreshSnapshot,
    Duration retryDelay = const Duration(seconds: 5),
  }) : _refreshSnapshot = refreshSnapshot,
       _retryDelay = retryDelay;

  final GroupListeningSnapshotRefresher _refreshSnapshot;
  final Duration _retryDelay;

  Timer? _retryTimer;
  Future<void>? _refreshOperation;
  bool _refreshInFlight = false;
  bool _queuedRefresh = false;
  String? _queuedRefreshReason;

  void dispose() {
    _retryTimer?.cancel();
  }

  void markRequired({
    required String reason,
    GroupListeningErrorState? failure,
  }) {
    _scheduleRetryIfNeeded();
    requestRefresh(reason: reason);
  }

  void requestRefresh({required String reason}) {
    if (_refreshInFlight) {
      _queuedRefresh = true;
      _queuedRefreshReason = reason;
      return;
    }
    _refreshInFlight = true;
    _refreshOperation = _refreshSnapshot(reason: reason).whenComplete(() {
      _refreshInFlight = false;
      if (_queuedRefresh) {
        final queuedReason = _queuedRefreshReason ?? 'queued-refresh';
        _queuedRefresh = false;
        _queuedRefreshReason = null;
        requestRefresh(reason: queuedReason);
      }
    });
  }

  Future<void>? get refreshOperation => _refreshOperation;

  void clearRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _scheduleRetryIfNeeded() {
    if (_retryTimer?.isActive ?? false) {
      return;
    }
    _retryTimer = Timer(_retryDelay, () {
      requestRefresh(reason: 'snapshot-retry-timer');
    });
  }
}
