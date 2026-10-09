import 'dart:collection';

import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Applies queued UI updates a few per frame.
///
/// Background results (cover tints) often arrive in bursts. Applying them all
/// at once rebuilds many cards and starts many animations in one frame; this
/// queue runs at most [perFrame] callbacks after each frame and carries the
/// rest to the following frames, so no single frame pays for the burst.
class FrameBudgetDispatcher {
  new({this.perFrame = 3, this._binding})
    : assert(perFrame > 0, 'perFrame must be positive');

  final int perFrame;
  final SchedulerBinding? _binding;
  final Queue<VoidCallback> _queue = Queue<VoidCallback>();
  bool _armed = false;
  int _batchSize = 0;

  /// Whether the callback running now is one of several applied in the same
  /// frame, or more are still waiting: updates that arrive as a burst.
  bool get inBurst => _batchSize > 1 || _queue.isNotEmpty;

  /// Callbacks waiting for a later frame.
  int get pending => _queue.length;

  SchedulerBinding get _scheduler => _binding ?? SchedulerBinding.instance;

  /// Runs [callback] after a coming frame, within the per-frame budget.
  void enqueue(VoidCallback callback) {
    _queue.add(callback);
    _arm();
  }

  void _arm() {
    if (_armed || _queue.isEmpty) return;
    _armed = true;
    _scheduler
      ..addPostFrameCallback(_drain)
      ..scheduleFrame();
  }

  void _drain(Duration _) {
    _armed = false;
    _batchSize = _queue.length < perFrame ? _queue.length : perFrame;
    for (var i = 0; i < _batchSize; i++) {
      var completed = false;
      try {
        _queue.removeFirst()();
        completed = true;
      } finally {
        // SchedulerBinding reports the error. Rearm before it escapes.
        if (!completed) {
          _batchSize = 0;
          _arm();
        }
      }
    }
    _batchSize = 0;
    _arm();
  }
}

/// The app-wide dispatcher for tint updates.
final frameBudgetDispatcherProvider = Provider<FrameBudgetDispatcher>(
  (ref) => FrameBudgetDispatcher(),
);
