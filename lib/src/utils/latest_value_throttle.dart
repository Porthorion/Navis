import 'dart:async';

/// Publishes a frequently updated value at most once per [interval].
///
/// Urgent values publish immediately. Other values publish immediately when
/// the interval has passed; otherwise the latest one is held and published
/// when it does. [close] drops any held value.
class LatestValueThrottle<T> {
  LatestValueThrottle({
    required this.interval,
    required this.onPublish,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration interval;
  final void Function(T value) onPublish;
  final DateTime Function() _now;

  DateTime? _lastPublishedAt;
  Timer? _trailing;
  T? _pending;
  bool _hasPending = false;
  bool _closed = false;

  void add(T value, {bool urgent = false}) {
    if (_closed) return;
    final last = _lastPublishedAt;
    final elapsed = last == null ? interval : _now().difference(last);
    if (urgent || elapsed >= interval) {
      _publish(value);
      return;
    }
    _pending = value;
    _hasPending = true;
    _trailing ??= Timer(interval - elapsed, () {
      _trailing = null;
      if (_closed || !_hasPending) return;
      _publish(_pending as T);
    });
  }

  void close() {
    _closed = true;
    _trailing?.cancel();
    _trailing = null;
    _hasPending = false;
    _pending = null;
  }

  void _publish(T value) {
    _trailing?.cancel();
    _trailing = null;
    _hasPending = false;
    _pending = null;
    _lastPublishedAt = _now();
    onPublish(value);
  }
}
