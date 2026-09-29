import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';

void main() {
  test(
    'hundredth input never accumulates drift and retains legacy precision',
    () {
      var value = 1.0;
      for (var i = 0; i < 1000; i++) {
        value = stepAdjustment(value, 10);
      }
      expect(value, 101);
      for (var i = 0; i < 1000; i++) {
        value = stepAdjustment(value, -10);
      }
      expect(value, 1);
      expect(stepAdjustment(1.2735, 1), 1.28);
      const legacy = PlaybackAdjustments(speed: 1.2735, pitchSemitones: 2.3456);
      expect(legacy.copyWith(speed: 1.28).pitchSemitones, 2.3456);
      expect(isHundredth(0.99), isTrue);
      expect(isHundredth(1.2735), isFalse);
    },
  );
  test('lock uses exact factors and unlocking freezes the current sound', () {
    for (final entry in {
      0.5: -12.0,
      0.99: -0.17,
      1.0: 0.0,
      1.25: 3.86,
      2.0: 12.0,
    }.entries) {
      final linked = PlaybackAdjustments(
        speed: entry.key,
        lockPitchToSpeed: true,
      );
      expect(linked.pitchFactor, entry.key);
      expect(roundAdjustment(linked.pitchSemitones), entry.value);
      final independent = linked.copyWith(lockPitchToSpeed: false);
      expect(independent.pitchSemitones, linked.pitchSemitones);
      expect(
        independent.copyWith(speed: 1.5).pitchFactor,
        closeTo(linked.pitchFactor, 1e-14),
      );
      expect(independent, isNot(linked));
    }
    expect(const PlaybackAdjustments(lockPitchToSpeed: true).isNone, isFalse);
    const linked = PlaybackPreset(
      id: 'linked',
      name: 'Natural',
      values: PlaybackAdjustments(speed: 1.2735, lockPitchToSpeed: true),
    );
    expect(PlaybackPreset.fromJson(linked.toJson())!.values, linked.values);
    final old = {...linked.toJson()}..remove('lockPitchToSpeed');
    expect(PlaybackPreset.fromJson(old)!.values.lockPitchToSpeed, isFalse);
    expect(PlaybackPreset.fromJson(old)!.values.speed, 1.2735);
  });
  test('ranges account for the other value, mode, and inward rounding', () {
    const desktop = PlaybackAdjustmentCapabilities.mediaKit;
    const independent = PlaybackAdjustments(speed: 0.1, pitchSemitones: 12);
    expect(desktop.speedRange(independent).minimum, 0.02);
    expect(desktop.speedRange(independent).maximum, isNull);
    expect(desktop.pitchRange(independent).maximum, 39.86);
    final linked = independent.copyWith(lockPitchToSpeed: true);
    expect(desktop.speedRange(linked).minimum, 0.01);
    expect(desktop.speedRange(linked).maximum, 100);
    for (final caps in [desktop, PlaybackAdjustmentCapabilities.android]) {
      final speedRange = caps.speedRange(linked);
      expect(caps.supports(linked.copyWith(speed: speedRange.minimum)), isTrue);
      expect(caps.supports(linked.copyWith(speed: speedRange.maximum)), isTrue);
      final pitchRange = caps.pitchRange(independent);
      expect(
        caps.supports(independent.copyWith(pitchSemitones: pitchRange.minimum)),
        isTrue,
      );
      expect(
        caps.supports(independent.copyWith(pitchSemitones: pitchRange.maximum)),
        isTrue,
      );
    }
    expect(AdjustmentRange.inward(0.12345, 3.4567).minimum, 0.13);
    expect(AdjustmentRange.inward(0.12345, 3.4567).maximum, 3.45);
    expect(const PlaybackAdjustmentCapabilities().supports(linked), isFalse);
  });
  test('percent and semitone conversion preserve independent values', () {
    const values = PlaybackAdjustments(speed: 1.2537, pitchSemitones: 12);
    expect(values.speedPercent, closeTo(25.37, 0.000001));
    expect(values.pitchFactor, 2);
    expect(values.copyWith(pitchSemitones: -12).pitchFactor, 0.5);
    expect(values.copyWith(pitchSemitones: 1.37).speed, 1.2537);
    expect(const PlaybackAdjustments().isNone, isTrue);
  });
  test('validate mathematical and actual backend boundaries', () {
    const android = PlaybackAdjustmentCapabilities.android;
    expect(
      android.supports(
        const PlaybackAdjustments(speed: 0.1, pitchSemitones: 36),
      ),
      isTrue,
    );
    expect(android.supports(const PlaybackAdjustments(speed: 0.099)), isFalse);
    expect(android.supports(const PlaybackAdjustments(speed: 8.001)), isFalse);
    expect(
      android.supports(const PlaybackAdjustments(pitchSemitones: -40)),
      isFalse,
    );
    expect(
      android.supports(const PlaybackAdjustments(speed: double.nan)),
      isFalse,
    );
    expect(
      android.supports(
        const PlaybackAdjustments(pitchSemitones: double.infinity),
      ),
      isFalse,
    );
    expect(android.supports(const PlaybackAdjustments(speed: 0)), isFalse);
    expect(
      PlaybackAdjustmentCapabilities.mediaKit.supports(
        const PlaybackAdjustments(speed: 0.005),
      ),
      isFalse,
    );
    expect(
      PlaybackAdjustmentCapabilities.mediaKit.supports(
        const PlaybackAdjustments(speed: 3.75, pitchSemitones: -3.25),
      ),
      isTrue,
    );
    expect(
      const PlaybackAdjustmentCapabilities().supports(
        const PlaybackAdjustments(pitchSemitones: 0.01),
      ),
      isFalse,
    );
  });
  test('preset parsing rejects corrupted and reserved records', () {
    const preset = PlaybackPreset(
      id: 'p1',
      name: 'Nightcore',
      values: PlaybackAdjustments(speed: 1.25, pitchSemitones: 2.5),
    );
    final decoded = PlaybackPreset.fromJson(preset.toJson())!;
    expect(decoded.name, preset.name);
    expect(decoded.values, preset.values);
    expect(
      PlaybackPreset.fromJson({
        'id': 'none',
        'name': 'Other',
        'speed': 1,
        'pitchSemitones': 0,
      }),
      isNull,
    );
    expect(
      PlaybackPreset.fromJson({
        'id': 'p1',
        'name': ' NONE ',
        'speed': 1,
        'pitchSemitones': 0,
      }),
      isNull,
    );
    expect(
      PlaybackPreset.fromJson({
        'id': 'p1',
        'name': 'Other',
        'speed': -1,
        'pitchSemitones': 0,
      }),
      isNull,
    );
    expect(PlaybackPreset.fromJson(null), isNull);
  });
}
