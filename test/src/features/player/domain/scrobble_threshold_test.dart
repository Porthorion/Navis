import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/domain/scrobble_threshold.dart';

void main() {
  test('reached at half of the song', () {
    const d = Duration(minutes: 3);
    expect(
      reachedScrobbleThreshold(
        duration: d,
        position: const Duration(seconds: 89),
      ),
      isFalse,
    );
    expect(
      reachedScrobbleThreshold(
        duration: d,
        position: const Duration(seconds: 90),
      ),
      isTrue,
    );
  });

  test('capped at four minutes for long songs', () {
    const d = Duration(minutes: 20);
    expect(
      reachedScrobbleThreshold(
        duration: d,
        position: const Duration(minutes: 3, seconds: 59),
      ),
      isFalse,
    );
    expect(
      reachedScrobbleThreshold(
        duration: d,
        position: const Duration(minutes: 4),
      ),
      isTrue,
    );
  });

  test('never reached for an unknown or zero duration', () {
    const p = Duration(minutes: 10);
    expect(reachedScrobbleThreshold(duration: null, position: p), isFalse);
    expect(
      reachedScrobbleThreshold(duration: Duration.zero, position: p),
      isFalse,
    );
  });
}
