import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:navis/src/features/settings/domain/color_name_table.g.dart';

// Top-level finals initialize lazily: convert the table once, on first use.
final _tableLab = kColorNameTable.map((entry) => _labForRgb(entry.$2)).toList();

/// Returns the nearest colour name using CIE76 ΔE in CIELAB (sRGB, D65).
///
/// Alpha does not affect the name. Equal distances keep the first table entry.
String nameForColor(Color color) {
  final target = _labForRgb(color.toARGB32());
  var bestDistance = double.infinity;
  var bestIndex = 0;
  for (var i = 0; i < _tableLab.length; i++) {
    final candidate = _tableLab[i];
    final l = target.$1 - candidate.$1;
    final a = target.$2 - candidate.$2;
    final b = target.$3 - candidate.$3;
    // Squared ΔE preserves ordering without a square root per candidate.
    final distance = l * l + a * a + b * b;
    if (distance < bestDistance) {
      bestDistance = distance;
      bestIndex = i;
    }
  }
  return kColorNameTable[bestIndex].$1;
}

(double, double, double) _labForRgb(int rgb) {
  final r = _linearChannel((rgb >> 16) & 0xff);
  final g = _linearChannel((rgb >> 8) & 0xff);
  final b = _linearChannel(rgb & 0xff);
  // Linear sRGB → XYZ, normalized by the D65 reference white.
  final x = _labCurve(
    (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047,
  );
  final y = _labCurve(0.2126729 * r + 0.7151522 * g + 0.0721750 * b);
  final z = _labCurve(
    (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883,
  );
  return (116 * y - 16, 500 * (x - y), 200 * (y - z));
}

double _linearChannel(int channel) {
  final value = channel / 255;
  return value <= 0.04045
      ? value / 12.92
      : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
}

double _labCurve(double value) {
  // CIELAB's linear segment avoids instability near black.
  return value > 216 / 24389
      ? math.pow(value, 1 / 3).toDouble()
      : ((24389 / 27) * value + 16) / 116;
}
