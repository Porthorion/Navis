import 'dart:async';

/// Owns one cancellable deadline; callers supply current visibility eligibility.
class RecommendationAutoAdvance {
  RecommendationAutoAdvance({required this.onAdvance, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final void Function() onAdvance;
  final DateTime Function() _now;
  Timer? _timer;
  DateTime? _manualDeadline;
  bool _eligible = false;
  bool _disposed = false;

  void setEligible({required bool eligible}) {
    if (_disposed) return;
    _eligible = eligible;
    if (!eligible) {
      _timer?.cancel();
      _timer = null;
    } else {
      _schedule();
    }
  }

  void recordInteraction() {
    if (_disposed) return;
    _manualDeadline = _now().add(const Duration(seconds: 10));
    _timer?.cancel();
    _timer = null;
    _schedule();
  }

  void _schedule() {
    if (_disposed || !_eligible || _timer != null) return;
    var delay = const Duration(seconds: 8);
    final remaining = _manualDeadline?.difference(_now());
    if (remaining != null && remaining > delay) delay = remaining;
    _timer = Timer(delay, () {
      _timer = null;
      if (_disposed || !_eligible) return;
      onAdvance();
      _schedule();
    });
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
