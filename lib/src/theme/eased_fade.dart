import 'package:material_ui/material_ui.dart';

/// A [LinearGradient] of [color] whose alpha follows [points], each a
/// (stop, alpha) pair from stop 0 to stop 1.
///
/// Every segment is eased with smoothstep and sampled [samples] times. A fade
/// built from two or three plain stops changes slope abruptly at each stop, and
/// the eye reads that as a line (a Mach band); the eased ramp starts and ends
/// each segment flat. Use it as a mask (`ShaderMask` with `BlendMode.dstIn`) to
/// fade an image into whatever lies behind it, or as a veil of the page colour.
LinearGradient easedFadeGradient({
  required List<(double, double)> points,
  Color color = Colors.black,
  Alignment begin = Alignment.topCenter,
  Alignment end = Alignment.bottomCenter,
  int samples = 10,
}) {
  assert(points.length >= 2, 'a fade needs at least two points');
  assert(points.first.$1 == 0 && points.last.$1 == 1, 'points span 0 to 1');
  final stops = <double>[];
  final colors = <Color>[];
  for (var i = 0; i < points.length - 1; i++) {
    final (s0, a0) = points[i];
    final (s1, a1) = points[i + 1];
    assert(s1 >= s0, 'point stops must not decrease');
    for (var k = i == 0 ? 0 : 1; k <= samples; k++) {
      final t = k / samples;
      final eased = t * t * (3 - 2 * t);
      stops.add(s0 + (s1 - s0) * t);
      colors.add(color.withValues(alpha: a0 + (a1 - a0) * eased));
    }
  }
  return LinearGradient(begin: begin, end: end, colors: colors, stops: stops);
}
