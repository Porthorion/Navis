part of 'navis_audio_handler.dart';

class OperationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;

  /// Throws [OperationCancelledException] if this token has been cancelled.
  void checkCancelled() {
    if (_cancelled) throw OperationCancelledException();
  }
}

class OperationCancelledException implements Exception {
  @override
  String toString() => 'OperationCancelledException';
}

class PlaybackLoadTimeoutException extends TimeoutException {
  PlaybackLoadTimeoutException({
    required this.operation,
    this.songId,
    this.timeoutDuration,
  }) : super(
         'Playback operation timed out: $operation'
         '${songId == null ? '' : ' (song=$songId)'}',
         timeoutDuration,
       );

  final String operation;
  final String? songId;
  final Duration? timeoutDuration;
}

/// A single-lane serialization queue that ensures operations execute one at a
/// time in FIFO order.  Used to prevent concurrent mutations of shared state
/// (e.g. the playback queue or the transport layer).
class _SerializationLane {
  Future<void> _inFlight = Future<void>.value();

  Future<T> run<T>(Future<T> Function() operation) {
    final completer = Completer<T>();

    _inFlight = _inFlight.then((_) async {
      if (completer.isCompleted) {
        return;
      }
      try {
        final value = await operation();
        completer.complete(value);
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });

    _inFlight = _inFlight.catchError((_) {});

    return completer.future;
  }
}

/// How a unit of work on a [NavisSupersedingLane] treats the work around it.
enum NavisLaneWorkKind {
  /// Replaces the queue or transport outright (replace, clear, restore,
  /// radio). Cancels the active operation and everything waiting.
  supersede,

  /// Moves playback to another item. Cancels active and waiting replacement,
  /// navigation, and idle work, but never an edit: edits are short, keep
  /// their FIFO order, and a cancelled edit would silently lose the user's
  /// change.
  navigate,

  /// Changes queue contents (add, play next, remove, reorder, merges).
  /// Waits in FIFO order behind the active work and cancels only idle work.
  edit,

  /// Opportunistic background work (releasing more of a deferred queue).
  /// Admitted only when the lane is empty; any other submission cancels it.
  idle,
}

/// A serialization lane where each new [run] call cancels the token of
/// the previous in-flight operation.  The cancelled operation should check
/// [OperationToken.isCancelled] / [OperationToken.checkCancelled] at
/// async boundaries and bail out early.
///
/// Execution is always serialized: at most one operation runs at a time.
/// [run] keeps its original superseding behaviour; [navigate], [enqueue] and
/// [tryRunIdle] add the other [NavisLaneWorkKind]s. A cancelled caller's
/// future still completes normally.
/// This lane does *not* interrupt Dart async or native playback commands.
class NavisSupersedingLane {
  _SupersedingWork? _active;
  final List<_SupersedingWork> _waiting = <_SupersedingWork>[];
  bool _draining = false;

  /// Called whenever the lane becomes empty, so owners can offer idle work.
  void Function()? onDrained;

  int get pendingCount =>
      _waiting.where((work) => work.kind != NavisLaneWorkKind.idle).length;

  /// Whether nothing is running or waiting.
  bool get isIdle => _active == null && _waiting.isEmpty;

  /// Retires the active operation and discards all waiting work.
  /// The active operation still owns the lane until its awaited backend call
  /// returns or times out, so another operation cannot touch the same player.
  void cancelCurrent() {
    _active?.cancel();
    for (final work in _waiting) {
      work.cancel();
    }
    _waiting.clear();
  }

  /// Cancels what a navigation supersedes: active and waiting work that is
  /// not an edit. Edits finish first, in order.
  void cancelForNavigation() {
    if (_active case final active? when active.kind != NavisLaneWorkKind.edit) {
      active.cancel();
    }
    _cancelWaitingWhere((kind) => kind != NavisLaneWorkKind.edit);
  }

  /// Runs [operation] as [NavisLaneWorkKind.supersede] work.
  Future<void> run(Future<void> Function(OperationToken token) operation) {
    cancelCurrent();
    return _submit(_SupersedingWork(operation, NavisLaneWorkKind.supersede));
  }

  /// Runs [operation] as [NavisLaneWorkKind.navigate] work.
  Future<void> navigate(
    Future<void> Function(OperationToken token) operation,
  ) {
    cancelForNavigation();
    return _submit(_SupersedingWork(operation, NavisLaneWorkKind.navigate));
  }

  /// Runs [operation] as [NavisLaneWorkKind.edit] work.
  Future<void> enqueue(Future<void> Function(OperationToken token) operation) {
    _cancelIdle();
    return _submit(_SupersedingWork(operation, NavisLaneWorkKind.edit));
  }

  /// Starts [operation] as [NavisLaneWorkKind.idle] work if the lane is
  /// empty. Returns null, without running it, when anything else is active or
  /// waiting.
  Future<void>? tryRunIdle(
    Future<void> Function(OperationToken token) operation,
  ) {
    if (!isIdle) return null;
    return _submit(_SupersedingWork(operation, NavisLaneWorkKind.idle));
  }

  void _cancelIdle() {
    if (_active case final active? when active.kind == NavisLaneWorkKind.idle) {
      active.cancel();
    }
    _cancelWaitingWhere((kind) => kind == NavisLaneWorkKind.idle);
  }

  void _cancelWaitingWhere(bool Function(NavisLaneWorkKind kind) test) {
    _waiting.removeWhere((work) {
      if (!test(work.kind)) return false;
      work.cancel();
      return true;
    });
  }

  Future<void> _submit(_SupersedingWork work) {
    _waiting.add(work);
    if (!_draining) {
      _draining = true;
      unawaited(_drain());
    }
    return work.future;
  }

  Future<void> _drain() async {
    while (_waiting.isNotEmpty) {
      final work = _waiting.removeAt(0);
      _active = work;
      await work.execute();
      _active = null;
    }
    _draining = false;
    // The drain runs unawaited, so a throwing listener would otherwise
    // surface as an unhandled zone error.
    try {
      onDrained?.call();
    } on Object catch (error, stackTrace) {
      AppLogger.warning('Queue lane drain listener failed. $error\n$stackTrace');
    }
  }
}

class _SupersedingWork {
  _SupersedingWork(this._operation, this.kind);

  final Future<void> Function(OperationToken token) _operation;
  final NavisLaneWorkKind kind;
  final OperationToken token = OperationToken();
  final Completer<void> _completion = Completer<void>();

  Future<void> get future => _completion.future;

  void cancel() {
    token.cancel();
    if (!_completion.isCompleted) _completion.complete();
  }

  Future<void> execute() async {
    if (token.isCancelled) return;
    try {
      await _operation(token);
      if (!_completion.isCompleted) _completion.complete();
    } on OperationCancelledException {
      if (!_completion.isCompleted) _completion.complete();
    } on Object catch (error, stackTrace) {
      if (!_completion.isCompleted) {
        _completion.completeError(error, stackTrace);
      }
    }
  }
}
