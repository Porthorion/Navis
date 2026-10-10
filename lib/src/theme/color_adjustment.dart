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

/// Persisted tuning with independent Light and Dark/OLED brightness.
@immutable
class ColorTuning {
  const new({int vividness = 0, int lightDepth = 0, int darkDepth = 0})
    : vividness = vividness < -5 ? -5 : (vividness > 5 ? 5 : vividness),
      lightDepth = lightDepth < -5 ? -5 : (lightDepth > 5 ? 5 : lightDepth),
      darkDepth = darkDepth < -5 ? -5 : (darkDepth > 5 ? 5 : darkDepth);

  static const none = ColorTuning();
  final int vividness;
  final int lightDepth;
  final int darkDepth;

  ColorAdjustment forMode({required bool dark}) => ColorAdjustment(
    vividness: vividness,
    depth: dark ? darkDepth : lightDepth,
  );

  @override
  bool operator ==(Object other) =>
      other is ColorTuning &&
      other.vividness == vividness &&
      other.lightDepth == lightDepth &&
      other.darkDepth == darkDepth;
  @override
  int get hashCode => Object.hash(vividness, lightDepth, darkDepth);
}
