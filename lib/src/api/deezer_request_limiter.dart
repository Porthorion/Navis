import 'dart:async';
import 'dart:collection';

/// Keeps Navis under Deezer's public quota: at most [maxPerWindow] requests
/// start in any [window], and at most [maxInFlight] run at once.
///
/// Deezer documents about 50 requests per 5 seconds, but from one IP it
/// answered "Quota limit exceeded" (code 4) while Navis started at most 32
/// requests in 5 seconds (8 per second, measured on a fresh cache in
/// 2026-10). Five per second (25 per 5 seconds) leaves room for that
/// stricter real limit.
///
/// One limiter is shared by every request of a `DeezerApiClient`, so the
/// limits hold across all features that call Deezer. When Deezer reports its
/// quota exceeded, [pauseStarts] holds every new start, so concurrent
/// requests stop piling into the quota.
class DeezerRequestLimiter {
  new({
    this.maxPerWindow = 5,
    this.window = const Duration(seconds: 1),
    this.maxInFlight = 4,
    Duration Function()? elapsed,
    Future<void> Function(Duration)? delay,
  }) : _elapsed = elapsed ?? _monotonicElapsed(),
       _delay = delay ?? Future<void>.delayed;

  final int maxPerWindow;
  final Duration window;
  final int maxInFlight;
  final Duration Function() _elapsed;
  final Future<void> Function(Duration) _delay;

  /// When the requests of the current window started, oldest first.
  final Queue<Duration> _starts = Queue<Duration>();
  int _inFlight = 0;
  Completer<void>? _released;

  /// No request starts before this point of [_elapsed].
  Duration _pausedUntil = Duration.zero;

  /// Requests running now.
  int get inFlight => _inFlight;

  /// Holds every request that has not started yet until [duration] from now;
  /// requests already running continue. A pause that ends later than the
  /// current one extends it; an earlier end never shortens it.
  void pauseStarts(Duration duration) {
    final until = _elapsed() + duration;
    if (until > _pausedUntil) _pausedUntil = until;
  }

  /// Runs [request] once a slot is free under both limits and no pause holds
  /// it.
  Future<T> run<T>(Future<T> Function() request) async {
    await _acquire();
    try {
      return await request();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() async {
    while (true) {
      final now = _elapsed();
      if (now < _pausedUntil) {
        await _delay(_pausedUntil - now);
        continue;
      }
      while (_starts.isNotEmpty && now - _starts.first >= window) {
        _starts.removeFirst();
      }
      if (_inFlight < maxInFlight && _starts.length < maxPerWindow) {
        _inFlight++;
        _starts.addLast(now);
        return;
      }
      if (_inFlight >= maxInFlight) {
        await (_released ??= Completer<void>()).future;
      } else {
        await _delay(_starts.first + window - now);
      }
    }
  }

  void _release() {
    _inFlight--;
    final released = _released;
    _released = null;
    released?.complete();
  }

  static Duration Function() _monotonicElapsed() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }
}
