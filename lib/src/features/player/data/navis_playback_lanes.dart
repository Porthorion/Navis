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
/// Execution is still serialized (one at a time, FIFO) — this lane does
/// *not* interrupt Dart async; it merely signals that the result is no
/// longer needed so the operation can skip remaining work.
class _SupersedingLane {
  Future<void> _inFlight = Future<void>.value();
  OperationToken? _currentToken;

  /// Cancels the most recently issued token, if any.
  void cancelCurrent() => _currentToken?.cancel();

  Future<T> run<T>(Future<T> Function(OperationToken token) operation) {
    // Cancel whatever is currently running — it has been superseded.
    _currentToken?.cancel();
    final token = OperationToken();
    _currentToken = token;

    final completer = Completer<T>();

    _inFlight = _inFlight.then((_) async {
      if (token.isCancelled || completer.isCompleted) {
        if (!completer.isCompleted) {
          completer.complete();
        }
        return;
      }
      try {
        final value = await operation(token);
        if (!token.isCancelled && !completer.isCompleted) {
          completer.complete(value);
        } else if (!completer.isCompleted) {
          completer.complete();
        }
      } on OperationCancelledException {
        if (!completer.isCompleted) {
          completer.complete();
        }
      } on Object catch (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      }
    });

    _inFlight = _inFlight.catchError((_) {});

    return completer.future;
  }
}
