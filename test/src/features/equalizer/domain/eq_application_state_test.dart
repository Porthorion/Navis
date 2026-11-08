import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';

void main() {
  test('diagnostics JSON carries the native processing counters', () {
    final state = EqApplicationState(
      desired: EqConfiguration.flat(),
      applied: EqConfiguration.flat(),
      sampleRate: 44100,
      responseSampleRate: 44100,
      headroomDb: -0.5,
      processedFrames: 4096,
      levelDeltaDb: -12.0,
      resetCount: 2,
      tapPrepareCount: 1,
      flushCount: 2,
      transitionGapsMs: const [0.4, -0.2],
      pitchCents: 500,
      pitchActive: true,
      pitchLatencyFrames: 4096,
      pitchResetCount: 3,
      pitchInputHz: 440,
      pitchOutputHz: 587.5,
      pitchPullMismatches: 0,
      pitchReason: 'no pitch',
      formatStreams: const [
        {
          'sampleRate': 22050,
          'channels': 2,
          'processedFrames': 88200,
          'levelDeltaDb': -12.0,
        },
      ],
      unmatchedFrames: 0,
      overlapBlocks: 0,
      livePipelines: 1,
      prepareCalls: 3,
      unprepareCalls: 2,
      clampedUnprepares: 0,
    );
    final json = state.toDiagnosticsJson();
    expect(json['sampleRate'], 44100);
    expect(json['headroomDb'], -0.5);
    expect(json['pending'], isFalse);
    expect(json['processedFrames'], 4096);
    expect(json['levelDeltaDb'], -12.0);
    expect(json['resetCount'], 2);
    expect(json['tapPrepareCount'], 1);
    expect(json['flushCount'], 2);
    expect(json['transitionGapsMs'], [0.4, -0.2]);
    expect(json['pitchCents'], 500);
    expect(json['pitchActive'], isTrue);
    expect(json['pitchLatencyFrames'], 4096);
    expect(json['pitchResetCount'], 3);
    expect(json['pitchInputHz'], 440);
    expect(json['pitchOutputHz'], 587.5);
    expect(json['pitchPullMismatches'], 0);
    expect(json['pitchReason'], 'no pitch');
    expect(json['formatStreams'], [
      {
        'sampleRate': 22050,
        'channels': 2,
        'processedFrames': 88200,
        'levelDeltaDb': -12.0,
      },
    ]);
    expect(json['unmatchedFrames'], 0);
    expect(json['overlapBlocks'], 0);
    expect(json['livePipelines'], 1);
    expect(json['prepareCalls'], 3);
    expect(json['unprepareCalls'], 2);
    expect(json['clampedUnprepares'], 0);
    expect(json['enabled'], state.applied.enabled);
    expect(json['configuration'], state.applied.toJson());
  });

  test('counters are null when the backend reports none', () {
    final json = EqApplicationState(
      desired: EqConfiguration.flat(),
      applied: EqConfiguration.flat(),
    ).toDiagnosticsJson();
    expect(json.containsKey('processedFrames'), isTrue);
    expect(json['processedFrames'], isNull);
    expect(json['levelDeltaDb'], isNull);
    expect(json['resetCount'], isNull);
    expect(json['tapPrepareCount'], isNull);
    expect(json['flushCount'], isNull);
    expect(json['transitionGapsMs'], isNull);
    for (final key in [
      'pitchCents',
      'pitchActive',
      'pitchLatencyFrames',
      'pitchResetCount',
      'pitchInputHz',
      'pitchOutputHz',
      'pitchPullMismatches',
      'pitchReason',
      'formatStreams',
      'unmatchedFrames',
      'overlapBlocks',
      'livePipelines',
      'prepareCalls',
      'unprepareCalls',
      'clampedUnprepares',
    ]) {
      expect(json.containsKey(key), isTrue);
      expect(json[key], isNull);
    }
  });
}
