import 'dart:async';

import 'package:navis/src/api/sync_request_scope.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';

/// Bounded, content-free attempt evidence. Checkpoints run in the owning sync
/// zone, never in a nested transaction inherited from a progress callback.
class SyncAttemptRecorder {
  new({
    required this.requestId,
    required this.attemptId,
    required this.scope,
    required this._write,
    DateTime Function()? now,
    Duration checkpointInterval = const Duration(seconds: 5),
  }) : _now = now ?? DateTime.now,
       _ownerZone = Zone.current {
    _startedAt = _now();
    _phaseStartedAt = _startedAt;
    _timer = Timer.periodic(checkpointInterval, (_) => _queueCheckpoint());
    _queueCheckpoint();
  }

  static const retainedPhases = 32;
  final int requestId;
  final int attemptId;
  final SyncRequestScope scope;
  final Future<void> Function(Map<String, Object?>) _write;
  final DateTime Function() _now;
  final Zone _ownerZone;
  late final DateTime _startedAt;
  late DateTime _phaseStartedAt;
  final Stopwatch _elapsed = Stopwatch()..start();
  Stopwatch _phaseElapsed = Stopwatch()..start();
  final List<Map<String, Object?>> _phases = [];
  LibrarySyncState _state = const LibrarySyncState(
    status: LibrarySyncStatus.running,
    stage: LibrarySyncStage.preparing,
  );
  int _phaseCount = 1;
  int _checkpointFailures = 0;
  late final Timer _timer;
  Future<void>? _drain;
  bool _dirty = false;
  bool _closed = false;
  bool _complete = false;

  void observe(LibrarySyncState state) {
    if (_closed) return;
    final changed =
        state.stage != _state.stage ||
        state.candidateStatus != _state.candidateStatus;
    if (changed) {
      _phases.add(_phaseJson());
      if (_phases.length >= retainedPhases) _phases.removeAt(0);
      _phaseCount++;
      _phaseStartedAt = _now();
      _phaseElapsed = Stopwatch()..start();
    }
    _state = state;
    if (changed) _queueCheckpoint();
  }

  Future<void> fail() => finish(
    _state.copyWith(
      status: LibrarySyncStatus.failed,
      stage: LibrarySyncStage.completed,
    ),
  );

  Future<void> finish(LibrarySyncState state) async {
    observe(state);
    _complete = true;
    await close();
  }

  /// Also called after unexpected interruption; such evidence stays explicitly
  /// incomplete even if the last reported delegate phase looked successful.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer.cancel();
    _elapsed.stop();
    _phaseElapsed.stop();
    _queueCheckpoint();
    await _drain;
  }

  Map<String, Object?> _phaseJson() => {
    'stage': _state.stage.name,
    'candidateStatus': switch (_state.candidateStatus) {
      null => null,
      'collecting' ||
      'validating' ||
      'ready' ||
      'applying' ||
      'awaitingDeletionConfirmation' => _state.candidateStatus,
      _ => 'unknown',
    },
    'startedAt': _phaseStartedAt.toUtc().toIso8601String(),
    'elapsedMicros': _phaseElapsed.elapsedMicroseconds,
  };

  Map<String, Object?> snapshot() => {
    'version': 1,
    'requestId': requestId,
    'attemptId': attemptId,
    'startedAt': _startedAt.toUtc().toIso8601String(),
    'capturedAt': _now().toUtc().toIso8601String(),
    'elapsedMicros': _elapsed.elapsedMicroseconds,
    'captureComplete': _complete,
    'status': _state.status.name,
    'checkpointFailures': _checkpointFailures,
    'omittedPhases': _phaseCount - _phases.length - 1,
    'phases': [..._phases, _phaseJson()],
    'transport': scope.transportTelemetry(),
    'logicalEndpointRequests': Map<String, int>.of(scope.logicalRequests),
    'pending': {
      // Separate axes: work rows can refer to the same albums/artists.
      'workRows': _state.pendingWorkCount,
      'albumHydration': _state.pendingHydrationCount,
      'artistVerification': _state.remainingVerificationCount,
    },
  };

  void _queueCheckpoint() {
    _dirty = true;
    if (_drain != null) return;
    final completion = Completer<void>();
    _drain = completion.future;
    unawaited(
      _ownerZone.run(() async {
        try {
          while (_dirty) {
            _dirty = false;
            try {
              await _write(snapshot());
            } on Object catch (error) {
              // Diagnostics cannot turn a valid catalog commit into a failure.
              // A later checkpoint carries the failure count, and lease fencing
              // still rejects stale owners at the DAO boundary.
              _checkpointFailures++;
              if (_checkpointFailures == 1) {
                AppLogger.warning(
                  'Sync attempt telemetry checkpoint failed (${error.runtimeType}).',
                );
              }
            }
          }
        } finally {
          _drain = null;
          completion.complete();
        }
      }),
    );
  }
}
