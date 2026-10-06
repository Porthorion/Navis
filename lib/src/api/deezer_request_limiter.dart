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
///
/// Waiting requests start in order, except that a foreground request (what
/// the user is looking at) always takes the next free slot before any
/// `background` one (Home's warm-up work). Background requests start
/// whenever no foreground request is waiting.
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

  /// Requests waiting for a slot, oldest first.
  final Queue<Completer<void>> _foreground = Queue<Completer<void>>();
  final Queue<Completer<void>> _background = Queue<Completer<void>>();

  /// No request starts before this point of [_elapsed].
  Duration _pausedUntil = Duration.zero;

  /// Whether a timed wake-up is pending (for the window or a pause).
  bool _wakeScheduled = false;

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
  /// it. A [background] request waits while any foreground one is waiting.
  Future<T> run<T>(
    Future<T> Function() request, {
    bool background = false,
  }) async {
    final slot = Completer<void>();
    (background ? _background : _foreground).addLast(slot);
    _dispatch();
    await slot.future;
    try {
      return await request();
    } finally {
      _inFlight--;
      _dispatch();
    }
  }

  /// Starts waiting requests, foreground first, while both limits allow.
  void _dispatch() {
    while (_foreground.isNotEmpty || _background.isNotEmpty) {
      // A finishing request dispatches again.
      if (_inFlight >= maxInFlight) return;
      final now = _elapsed();
      if (now < _pausedUntil) {
        _wakeAfter(_pausedUntil - now);
        return;
      }
      while (_starts.isNotEmpty && now - _starts.first >= window) {
        _starts.removeFirst();
      }
      if (_starts.length >= maxPerWindow) {
        _wakeAfter(_starts.first + window - now);
        return;
      }
      _inFlight++;
      _starts.addLast(now);
      final next = _foreground.isNotEmpty
          ? _foreground.removeFirst()
          : _background.removeFirst();
      next.complete();
    }
  }

  /// Dispatches again after [wait]. Only one wake-up is pending at a time:
  /// the window's oldest start only ages and a pause only extends, so a
  /// pending one is never later than needed.
  void _wakeAfter(Duration wait) {
    if (_wakeScheduled) return;
    _wakeScheduled = true;
    unawaited(
      _delay(wait).whenComplete(() {
        _wakeScheduled = false;
        _dispatch();
      }),
    );
  }

  static Duration Function() _monotonicElapsed() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }
}
