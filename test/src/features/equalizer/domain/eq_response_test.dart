import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/domain/eq_response.dart';

void main() {
  EqResponse response(List<EqFilter> filters, {double preamp = 0}) =>
      EqResponse(
        EqConfiguration(
          mode: EqMode.advanced,
          filters: filters,
          preampDb: preamp,
        ),
      );

  test('flat is exactly unity without protective attenuation', () {
    final flat = EqResponse(EqConfiguration.flat());
    for (final frequency in [20.0, 63.0, 1000.0, 16000.0, 20000.0]) {
      expect(flat.effectiveDbAt(frequency), 0);
    }
    expect(flat.headroomDb, 0);
  });

  test('peaking center has authored gain for multiple Q values', () {
    for (final q in [0.1, 0.7, 1.41, 6.0, 20.0]) {
      final curve = response([
        EqFilter(frequencyHz: 1234.5, gainDb: 9.3, q: q),
      ]);
      expect(curve.curveDbAt(1234.5), closeTo(9.3, 0.00001));
      expect(curve.maximumBoostDb, closeTo(9.3, 0.001));
      expect(curve.effectiveDbAt(1234.5), closeTo(-0.5, 0.001));
    }
  });

  test(
    'headroom accounts for overlapping filters rather than highest band',
    () {
      final curve = response(const [
        EqFilter(frequencyHz: 1000, gainDb: 6),
        EqFilter(frequencyHz: 1000, gainDb: 6),
      ]);
      expect(curve.maximumBoostDb, closeTo(12, 0.001));
      expect(curve.headroomDb, closeTo(-12.5, 0.001));
    },
  );

  test('negative imported preamp is retained without extra gain', () {
    final curve = response(
      const [EqFilter(frequencyHz: 1000, gainDb: 6)],
      preamp: -7.3,
    );
    expect(curve.headroomDb, 0);
    expect(curve.effectivePreampDb, -7.3);
    final unprotected = EqResponse(
      curve.configuration.copyWith(autoHeadroom: false, preampDb: 1),
    );
    expect(unprotected.headroomDb, 0);
    expect(unprotected.effectiveDbAt(1000), closeTo(7, 0.00001));
  });

  test('shelf reference values follow AutoEQ Q shelf convention', () {
    // Reference values evaluated independently from the AutoEQ coefficient
    // equations with complex transfer-function evaluation at 48 kHz.
    final low = response(const [
      EqFilter(
        type: EqFilterType.lowShelf,
        frequencyHz: 105,
        gainDb: 6,
        q: 0.7,
      ),
    ]);
    expect(low.curveDbAt(105), closeTo(3, 0.00001));
    expect(low.curveDbAt(20), closeTo(5.987, 0.02));
    expect(low.curveDbAt(1000), closeTo(0.005, 0.02));
    final high = response(const [
      EqFilter(
        type: EqFilterType.highShelf,
        frequencyHz: 10000,
        gainDb: -6,
        q: 0.7,
      ),
    ]);
    expect(high.curveDbAt(10000), closeTo(-3, 0.00001));
    expect(high.curveDbAt(100), closeTo(0, 0.001));
    expect(high.curveDbAt(23000), closeTo(-6, 0.01));
  });

  test('low/high pass are minus three dB at Butterworth cutoff', () {
    for (final type in [EqFilterType.lowPass, EqFilterType.highPass]) {
      final curve = response([
        EqFilter(type: type, frequencyHz: 1000, q: 0.7071067811865476),
      ]);
      expect(curve.curveDbAt(1000), closeTo(-3.0102999566, 0.00001));
    }
  });

  test('notch rejects center and disabled filters are identity', () {
    final notch = response(const [
      EqFilter(type: EqFilterType.notch, frequencyHz: 1000),
    ]);
    expect(notch.curveDbAt(1000), lessThan(-200));
    final disabled = response(const [
      EqFilter(type: EqFilterType.notch, frequencyHz: 1000, enabled: false),
    ]);
    expect(disabled.curveDbAt(1000), 0);
  });

  test('unsupported sample rates reject complete curve', () {
    expect(
      () => EqResponse(EqConfiguration.flat(), sampleRate: 22050),
      throwsFormatException,
    );
  });
}
