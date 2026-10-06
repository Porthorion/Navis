import 'dart:async';
import 'dart:collection';

/// Keeps Navis under Deezer's public quota: at most [maxPerWindow] requests
/// start in any [window], at most [maxBackgroundPerWindow] of them
/// background ones, and at most [maxInFlight] run at once.
///
/// Deezer documents about 50 requests per 5 seconds, but from one IP it
/// answered "Quota limit exceeded" (code 4) while Navis started at most 32
/// requests in 5 seconds (8 per second, measured on a fresh cache in
/// 2026-10). At 5 per second, 17 of the 106 requests of a fresh first launch
/// (Home's warm-up with an artist page opened during it) still came back as
/// code 4. The real budget is lower than documented and may be shared with
/// the user's server, which also calls Deezer, so Navis cannot know it:
/// background work starts at most 2 per second, leaving the rest of the 5 to
/// what the user opens.
///
/// One limiter is shared by every request of a `DeezerApiClient`, so the
/// limits hold across all features that call Deezer. When Deezer reports its
/// quota exceeded, [pauseStarts] holds every new start, so concurrent
/// requests stop piling into the quota.
///
/// Waiting requests start in order, except that a foreground request (what
/// the user is looking at) always takes the next free slot before any
/// `background` one (Home's warm-up work). Background requests start
/// whenever no foreground request is waiting and their own rate allows.
class DeezerRequestLimiter {
  new({
    this.maxPerWindow = 5,
    this.window = const Duration(seconds: 1),
    this.maxInFlight = 4,
    this.maxBackgroundPerWindow = 2,
    Duration Function()? elapsed,
    Future<void> Function(Duration)? delay,
  }) : _elapsed = elapsed ?? _monotonicElapsed(),
       _delay = delay ?? Future<void>.delayed;

  final int maxPerWindow;
  final Duration window;
  final int maxInFlight;
  final int maxBackgroundPerWindow;
  final Duration Function() _elapsed;
  final Future<void> Function(Duration) _delay;

  /// When the requests of the current window started, oldest first.
  final Queue<Duration> _starts = Queue<Duration>();

  /// When the background requests of the current window started.
  final Queue<Duration> _backgroundStarts = Queue<Duration>();
  int _inFlight = 0;

  /// Requests waiting for a slot, oldest first.
  final Queue<Completer<void>> _foreground = Queue<Completer<void>>();
  final Queue<Completer<void>> _background = Queue<Completer<void>>();

  /// No request starts before this point of [_elapsed].
  Duration _pausedUntil = Duration.zero;

  /// When the earliest pending timed wake-up (for a window or a pause) is
  /// due, on [_elapsed]; null when none is.
  Duration? _wakeAt;

  /// Requests running now.
  int get inFlight => _inFlight;

  /// Holds every request that has not started yet until [duration] from now;
  /// requests already running continue. A pause that ends later than the
  /// current one extends it; an earlier end never shortens it.
  void pauseStarts(Duration duration) {
    final until = _elapsed() + duration;
    if (until > _pausedUntil) _pausedUntil = until;
  }

  /// Runs [request] once a slot is free under the limits and no pause holds
  /// it. A [background] request waits while any foreground one is waiting,
  /// and for the background rate.
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

  /// Starts waiting requests, foreground first, while the limits allow.
  void _dispatch() {
    while (_foreground.isNotEmpty || _background.isNotEmpty) {
      // A finishing request dispatches again.
      if (_inFlight >= maxInFlight) return;
      final now = _elapsed();
      if (now < _pausedUntil) {
        _wakeAfter(_pausedUntil - now);
        return;
      }
      _forgetOlderThanWindow(_starts, now);
      _forgetOlderThanWindow(_backgroundStarts, now);
      if (_starts.length >= maxPerWindow) {
        _wakeAfter(_starts.first + window - now);
        return;
      }
      final Completer<void> next;
      if (_foreground.isNotEmpty) {
        next = _foreground.removeFirst();
      } else if (_backgroundStarts.length < maxBackgroundPerWindow) {
        next = _background.removeFirst();
        _backgroundStarts.addLast(now);
      } else {
        _wakeAfter(_backgroundStarts.first + window - now);
        return;
      }
      _inFlight++;
      _starts.addLast(now);
      next.complete();
    }
  }

  /// Dispatches again after [wait], unless a wake-up at least as early is
  /// already pending. A background wait (its own rate) can be pending when a
  /// foreground request needs an earlier one (the whole window), so a later
  /// pending wake-up does not stand in for an earlier one; a wake-up that
  /// turns out early just schedules the next.
  void _wakeAfter(Duration wait) {
    final at = _elapsed() + wait;
    final pending = _wakeAt;
    if (pending != null && pending <= at) return;
    _wakeAt = at;
    unawaited(
      _delay(wait).whenComplete(() {
        if (_wakeAt == at) _wakeAt = null;
        _dispatch();
      }),
    );
  }

  void _forgetOlderThanWindow(Queue<Duration> starts, Duration now) {
    while (starts.isNotEmpty && now - starts.first >= window) {
      starts.removeFirst();
    }
  }

  static Duration Function() _monotonicElapsed() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }
}
