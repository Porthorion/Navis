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

  test('fromMap leaves the counters null for backends without them', () {
    final state = EqualizerStateMessage.fromMap({'enabled': false});
    expect(state.processedFrames, isNull);
    expect(state.levelDeltaDb, isNull);
    expect(state.resetCount, isNull);
    expect(state.tapPrepareCount, isNull);
    expect(state.flushCount, isNull);
    expect(state.transitionGapsMs, isNull);
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
