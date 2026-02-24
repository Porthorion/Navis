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
  static const _fadeDuration = Duration(seconds: 30);

  Timer? _ticker;
  bool _isFading = false;

  @override
  SleepTimerState build() {
    ref.onDispose(_cancelTimer);
    return const SleepTimerState();
  }

  void setDuration(Duration duration) {
    _cancelTimer();
    _restoreVolume();
    state = SleepTimerState(
      mode: SleepTimerMode.duration,
      remaining: duration,
    );
    _startTicker();
  }

  void setEndOfTrack() {
    _cancelTimer();
    _restoreVolume();
    state = const SleepTimerState(mode: SleepTimerMode.endOfTrack);
  }

  void cancel() {
    _cancelTimer();
    _restoreVolume();
    state = const SleepTimerState();
  }

  void onTrackEnded() {
    if (state.mode == SleepTimerMode.endOfTrack) {
      _pauseAndStop();
    }
  }

  void _startTicker() {
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final remaining = state.remaining - const Duration(seconds: 1);
      if (remaining <= Duration.zero) {
        _pauseAndStop();
        return;
      }

      // Fade volume over the final 30 seconds.
      if (remaining <= _fadeDuration && !_isFading) {
        _isFading = true;
      }
      if (_isFading) {
        final fraction = remaining.inSeconds / _fadeDuration.inSeconds;
        final handler = ref.read(audioHandlerProvider);
        handler?.setVolume(fraction.clamp(0.0, 1.0));
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
    _isFading = false;
  }

  void _restoreVolume() {
    final handler = ref.read(audioHandlerProvider);
    handler?.setVolume(1);
  }

  void _pauseAndStop() {
    final handler = ref.read(audioHandlerProvider);
    handler?.pause();
    _cancelTimer();
    // Restore volume so next play starts at full volume.
    handler?.setVolume(1);
    state = const SleepTimerState();
  }
}

final sleepTimerProvider =
    NotifierProvider<SleepTimerController, SleepTimerState>(
      SleepTimerController.new,
    );
