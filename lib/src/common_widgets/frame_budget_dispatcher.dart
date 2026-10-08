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
    for (var i = 0; i < perFrame && _queue.isNotEmpty; i++) {
      _queue.removeFirst()();
    }
    _arm();
  }
}

/// The app-wide dispatcher for tint updates.
final frameBudgetDispatcherProvider = Provider<FrameBudgetDispatcher>(
  (ref) => FrameBudgetDispatcher(),
);
