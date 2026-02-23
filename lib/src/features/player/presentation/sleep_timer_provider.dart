import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/providers/app_providers.dart';

enum SleepTimerMode {
  off,
  duration,
  endOfTrack,
}

class SleepTimerState {
  const SleepTimerState({
    this.mode = SleepTimerMode.off,
    this.remaining = Duration.zero,
  });

  final SleepTimerMode mode;
  final Duration remaining;

  bool get isActive => mode != SleepTimerMode.off;
}

class SleepTimerController extends Notifier<SleepTimerState> {
  Timer? _ticker;

  @override
  SleepTimerState build() {
    ref.onDispose(_cancelTimer);
    return const SleepTimerState();
  }

  void setDuration(Duration duration) {
    _cancelTimer();
    state = SleepTimerState(
      mode: SleepTimerMode.duration,
      remaining: duration,
    );
    _startTicker();
  }

  void setEndOfTrack() {
    _cancelTimer();
    state = const SleepTimerState(mode: SleepTimerMode.endOfTrack);
  }

  void cancel() {
    _cancelTimer();
    state = const SleepTimerState();
  }

  void onTrackEnded() {
    if (state.mode == SleepTimerMode.endOfTrack) {
      _pausePlayback();
      cancel();
    }
  }

  void _startTicker() {
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final remaining = state.remaining - const Duration(seconds: 1);
      if (remaining <= Duration.zero) {
        _pausePlayback();
        cancel();
        return;
      }
      state = SleepTimerState(
        mode: SleepTimerMode.duration,
        remaining: remaining,
      );
    });
  }

  void _cancelTimer() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _pausePlayback() {
    final handler = ref.read(audioHandlerProvider);
    handler?.pause();
  }
}

final sleepTimerProvider =
    NotifierProvider<SleepTimerController, SleepTimerState>(
  SleepTimerController.new,
);
