import 'dart:math' as math;

/// Whether [position] counts as a played-through song: half of [duration],
/// capped at four minutes. Shared by scrobbling and Same Vibes.
bool reachedScrobbleThreshold({
  Duration? duration,
  required Duration position,
}) {
  if (duration == null || duration <= Duration.zero) {
    return false;
  }
  final thresholdMs = math.min(
    duration.inMilliseconds ~/ 2,
    const Duration(minutes: 4).inMilliseconds,
  );
  return position.inMilliseconds >= thresholdMs;
}
