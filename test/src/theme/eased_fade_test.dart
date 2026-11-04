import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/eased_fade.dart';

void main() {
  const veil = 0.4;
  final gradient = easedFadeGradient(
    color: Colors.black,
    points: const <(double, double)>[(0, 1), (0.18, veil), (0.7, veil), (1, 1)],
  );
  final stops = gradient.stops!;
  final alphas = gradient.colors.map((c) => c.a).toList();

  test('stops are monotonic and span 0 to 1', () {
    expect(stops.first, 0);
    expect(stops.last, closeTo(1, 1e-12));
    for (var i = 1; i < stops.length; i++) {
      expect(stops[i], greaterThanOrEqualTo(stops[i - 1]));
    }
    expect(gradient.colors, hasLength(stops.length));
  });

  test('alpha hits every point exactly and stays between its neighbours', () {
    expect(alphas.first, closeTo(1, 1e-6));
    expect(alphas[stops.indexOf(0.18)], closeTo(veil, 1e-6));
    expect(alphas.last, closeTo(1, 1e-6));
    for (var i = 1; i < alphas.length; i++) {
      final delta = alphas[i] - alphas[i - 1];
      if (stops[i] <= 0.18) {
        expect(delta, lessThanOrEqualTo(1e-9));
      } else if (stops[i] <= 0.7) {
        expect(delta, closeTo(0, 1e-9));
      } else {
        expect(delta, greaterThanOrEqualTo(-1e-9));
      }
    }
  });

  test('segments are eased: flat at both ends, steepest in the middle', () {
    // First segment, 0 -> 0.18: ten samples.
    final steps = <double>[
      for (var i = 1; i <= 10; i++) (alphas[i] - alphas[i - 1]).abs(),
    ];
    expect(steps.first, lessThan(steps[4] / 3));
    expect(steps.last, lessThan(steps[4] / 3));
    // A linear ramp would step evenly.
    expect(steps[4], greaterThan(steps.first * 3));
  });
}
