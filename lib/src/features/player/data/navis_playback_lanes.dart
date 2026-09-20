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

/// A serialization lane where each new [run] call cancels the token of
/// the previous in-flight operation.  The cancelled operation should check
/// [OperationToken.isCancelled] / [OperationToken.checkCancelled] at
/// async boundaries and bail out early.
///
/// Execution is still serialized. At most one replacement waits behind the
/// active operation; newer requests settle and discard older pending work.
/// This lane does *not* interrupt Dart async or native playback commands.
class NavisSupersedingLane {
  _SupersedingWork? _active;
  _SupersedingWork? _pending;
  bool _draining = false;

  int get pendingCount => _pending == null ? 0 : 1;

  /// Retires the active operation and discards the one pending replacement.
  /// The active operation still owns the lane until its awaited backend call
  /// returns or times out, so another operation cannot touch the same player.
  void cancelCurrent() {
    _active?.cancel();
    _pending?.cancel();
    _pending = null;
  }

  Future<void> run(Future<void> Function(OperationToken token) operation) {
    cancelCurrent();
    final work = _SupersedingWork(operation);
    _pending = work;
    if (!_draining) {
      _draining = true;
      unawaited(_drain());
    }
    return work.future;
  }

  Future<void> _drain() async {
    while (_pending != null) {
      final work = _pending!;
      _pending = null;
      _active = work;
      await work.execute();
      _active = null;
    }
    _draining = false;
  }
}

class _SupersedingWork {
  _SupersedingWork(this._operation);

  final Future<void> Function(OperationToken token) _operation;
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
