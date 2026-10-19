/// A bounded ring buffer of timestamped native-transport events (player index
/// and processing-state changes, source loads, recovery decisions, queue-fill
/// phases), reported by the diagnostics `GET /v1/playback/status`.
///
/// It records nothing, and evaluates no event data, unless diagnostics are
/// compiled in, so production playback pays only an `enabled` check.
class PlaybackTransportTrace {
  new({
    this.enabled = const bool.fromEnvironment('NAVIS_SYNC_DIAGNOSTICS'),
    this.capacity = 200,
    this._clock = DateTime.now,
  });

  final bool enabled;
  final int capacity;
  final DateTime Function() _clock;
  final List<Map<String, Object?>> _entries = <Map<String, Object?>>[];
  int _sequence = 0;

  /// Adds one event. [data] is only called when the trace is enabled.
  void record(String kind, [Map<String, Object?> Function()? data]) {
    if (!enabled) return;
    final now = _clock().toUtc();
    _entries.add(<String, Object?>{
      'seq': ++_sequence,
      'atMs': now.millisecondsSinceEpoch,
      'at': now.toIso8601String(),
      'kind': kind,
      ...?data?.call(),
    });
    if (_entries.length > capacity) {
      _entries.removeRange(0, _entries.length - capacity);
    }
  }

  List<Map<String, Object?>> get entries =>
      List<Map<String, Object?>>.of(_entries);
}
