import 'package:flutter/foundation.dart';

/// User tuning layered on top of any colour style. Positive depth is deeper.
@immutable
class ColorAdjustment {
  const new({int vividness = 0, int depth = 0})
    : vividness = vividness < -5 ? -5 : (vividness > 5 ? 5 : vividness),
      depth = depth < -5 ? -5 : (depth > 5 ? 5 : depth);

  static const none = ColorAdjustment();

  final int vividness;
  final int depth;

  double get chromaFactor => 1 + 0.1 * vividness;

  /// Tone offset shared by scheme surfaces and artwork tone windows.
  double toneShift({required bool dark, bool oled = false}) => oled
      ? -0.6 * depth
      : dark
      ? -1.2 * depth
      : depth > 0
      ? -0.9 * depth
      : -0.8 * depth;

  @override
  bool operator ==(Object other) =>
      other is ColorAdjustment &&
      other.vividness == vividness &&
      other.depth == depth;

  @override
  int get hashCode => Object.hash(vividness, depth);
}
