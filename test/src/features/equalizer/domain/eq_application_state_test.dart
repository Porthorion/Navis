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
    );
    final json = state.toDiagnosticsJson();
    expect(json['sampleRate'], 44100);
    expect(json['headroomDb'], -0.5);
    expect(json['pending'], isFalse);
    expect(json['processedFrames'], 4096);
    expect(json['levelDeltaDb'], -12.0);
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
  });
}
