import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';

/// Maps authored EQ parameters independently of output attenuation.
class EqGraphGeometry {
  const EqGraphGeometry(this.plot, {this.limit = 24});

  /// Places the plot inside a canvas, leaving room for the axis labels.
  factory EqGraphGeometry.inside(Size canvas, {double limit = 24}) =>
      EqGraphGeometry(
        Rect.fromLTWH(
          plotInsets.left,
          plotInsets.top,
          math.max(1, canvas.width - plotInsets.horizontal),
          math.max(1, canvas.height - plotInsets.vertical),
        ),
        limit: limit,
      );

  static const plotInsets = EdgeInsets.fromLTRB(32, 10, 10, 22);

  /// Touch radius; overlapping radii are resolved by [target].
  static const hitRadius = 24.0;

  final Rect plot;
  final double limit;

  double x(double hz) =>
      plot.left + plot.width * math.log(hz / 20) / math.log(1000);
  double frequency(double x) =>
      (20 * math.pow(1000, ((x - plot.left) / plot.width).clamp(0, 1)))
          .toDouble();
  double y(double db) => plot.center.dy - db / limit * plot.height / 2;
  double gain(double y) =>
      ((plot.center.dy - y) * 2 * limit / plot.height).clamp(-24, 24);
  Offset handle(EqFilter filter) => Offset(
    x(filter.frequencyHz),
    y(filter.usesGain ? filter.gainDb : 0).clamp(plot.top, plot.bottom),
  );

  List<int> hits(
    List<EqFilter> filters,
    Offset point, {
    double radius = hitRadius,
  }) => [
    for (var i = 0; i < filters.length; i++)
      if ((handle(filters[i]) - point).distance <= radius) i,
  ];

  /// Resolves the band a pointer addresses without guessing between
  /// overlapping handles.
  ///
  /// A drag continues with [selected] when it is under the pointer, so bands
  /// chosen from the band strip can be moved out of a stack. Otherwise a
  /// clearly nearest handle wins; genuinely ambiguous touches return every
  /// candidate for an explicit choice.
  List<int> target(List<EqFilter> filters, Offset point, {int? selected}) {
    final candidates = hits(filters, point);
    if (candidates.length < 2) return candidates;
    if (selected != null && candidates.contains(selected)) return [selected];
    double distance(int i) => (handle(filters[i]) - point).distance;
    final nearest = [...candidates]
      ..sort((a, b) => distance(a).compareTo(distance(b)));
    return distance(nearest[1]) - distance(nearest[0]) >= clearMargin
        ? [nearest.first]
        : candidates;
  }

  static const clearMargin = 12.0;

  EqFilter drag(EqFilter filter, Offset start, Offset delta, EqMode mode) =>
      filter.copyWith(
        frequencyHz: mode == EqMode.advanced && delta.dx != 0
            ? frequency(start.dx + delta.dx)
            : filter.frequencyHz,
        gainDb: filter.usesGain && delta.dy != 0
            ? gain(start.dy + delta.dy)
            : filter.gainDb,
      );

  static double qPosition(double q) => math.log(q / .1) / math.log(200);
  static double qAt(double position) =>
      .1 * math.pow(200, position.clamp(0, 1));
}
