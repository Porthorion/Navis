import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

void main() {
  test('fromMap reads the Darwin processing counters', () {
    final state = EqualizerStateMessage.fromMap({
      'enabled': true,
      'sampleRate': 44100,
      'headroomDb': -1.5,
      'reason': null,
      'pending': false,
      'processedFrames': 123456,
      'levelDeltaDb': -12.0,
      'resetCount': 3,
    });
    expect(state.resetCount, 3);
    expect(state.processedFrames, 123456);
    expect(state.levelDeltaDb, -12.0);
    expect(state.sampleRate, 44100.0);
  });

  test('fromMap reads the Darwin transition gaps and tap prepare count', () {
    final state = EqualizerStateMessage.fromMap({
      'enabled': true,
      'tapPrepareCount': 1,
      'flushCount': 2,
      'transitionGapsMs': [0.4, -0.2, 3],
    });
    expect(state.tapPrepareCount, 1);
    expect(state.flushCount, 2);
    expect(state.transitionGapsMs, [0.4, -0.2, 3.0]);
  });

  test('fromMap reads the Darwin pitch stage fields', () {
    final state = EqualizerStateMessage.fromMap({
      'enabled': true,
      'pitchCents': 500,
      'pitchActive': true,
      'pitchLatencyFrames': 4096,
      'pitchResetCount': 2,
      'pitchInputHz': 440,
      'pitchOutputHz': 587.5,
      'pitchPullMismatches': 0,
      'pitchReason': 'Pitch cannot be applied to this audio format.',
    });
    expect(state.pitchCents, 500);
    expect(state.pitchActive, isTrue);
    expect(state.pitchLatencyFrames, 4096);
    expect(state.pitchResetCount, 2);
    expect(state.pitchInputHz, 440.0);
    expect(state.pitchOutputHz, 587.5);
    expect(state.pitchPullMismatches, 0);
    expect(state.pitchReason, 'Pitch cannot be applied to this audio format.');
  });

  test('fromMap leaves the counters null for backends without them', () {
    final state = EqualizerStateMessage.fromMap({'enabled': false});
    expect(state.processedFrames, isNull);
    expect(state.levelDeltaDb, isNull);
    expect(state.resetCount, isNull);
    expect(state.tapPrepareCount, isNull);
    expect(state.flushCount, isNull);
    expect(state.transitionGapsMs, isNull);
    expect(state.pitchCents, isNull);
    expect(state.pitchActive, isNull);
    expect(state.pitchLatencyFrames, isNull);
    expect(state.pitchResetCount, isNull);
    expect(state.pitchInputHz, isNull);
    expect(state.pitchOutputHz, isNull);
    expect(state.pitchPullMismatches, isNull);
    expect(state.pitchReason, isNull);
  });

  test('fromMap accepts integral levelDeltaDb and 64-bit frame counts', () {
    final state = EqualizerStateMessage.fromMap({
      'enabled': true,
      'processedFrames': 5000000000,
      'levelDeltaDb': 0,
    });
    expect(state.processedFrames, 5000000000);
    expect(state.levelDeltaDb, 0.0);
  });

  test(
    'the configuration message carries the diagnostics flag only when set',
    () {
      EqualizerConfigurationMessage message({bool diagnostics = false}) =>
          EqualizerConfigurationMessage(
            enabled: true,
            preampDb: 0,
            autoHeadroom: false,
            filters: const [],
            diagnostics: diagnostics,
          );
      expect(message().toMap().containsKey('diagnostics'), isFalse);
      expect(message(diagnostics: true).toMap()['diagnostics'], isTrue);
    },
  );
}
