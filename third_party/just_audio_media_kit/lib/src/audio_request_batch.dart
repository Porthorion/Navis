import 'dart:async';

/// Merges audio setting requests made in the same event-loop turn into one
/// application.
///
/// Speed, pitch and equalizer changes each rebuild mpv's whole audio filter
/// graph. A speed change that also moves pitch arrives as two calls; merged,
/// it rebuilds the graph once and never plays the new speed with the old
/// pitch in between. Every merged caller completes with the shared result.
class AudioRequestBatch<E> {
  AudioRequestBatch(this._apply);

  final Future<void> Function({double? rate, double? pitch, E? equalizer})
      _apply;

  double? _rate;
  double? _pitch;
  E? _equalizer;
  Future<void>? _pending;

  Future<void> request({double? rate, double? pitch, E? equalizer}) {
    if (rate != null) _rate = rate;
    if (pitch != null) _pitch = pitch;
    if (equalizer != null) _equalizer = equalizer;
    return _pending ??= Future<void>.delayed(Duration.zero).then((_) {
      final rate = _rate;
      final pitch = _pitch;
      final equalizer = _equalizer;
      _rate = null;
      _pitch = null;
      _equalizer = null;
      _pending = null;
      return _apply(rate: rate, pitch: pitch, equalizer: equalizer);
    });
  }
}
