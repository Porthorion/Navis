import 'package:flutter/foundation.dart';

/// Fill treatment for interactive controls; plain icons retain scheme ink.
enum NavisControlColor {
  accent,
  white;

  static NavisControlColor parse(String? value) =>
      value == 'white' ? white : accent;
}

/// User tuning layered on top of any colour style. Positive depth is deeper.
@immutable
class ColorAdjustment {
  const new({
    int vividness = 0,
    int depth = 0,
    int tint = 0,
    this.controls = NavisControlColor.accent,
  }) : vividness = vividness < -5 ? -5 : (vividness > 5 ? 5 : vividness),
       depth = depth < -5 ? -5 : (depth > 5 ? 5 : depth),
       tint = tint < 0 ? 0 : (tint > 5 ? 5 : tint);

  static const none = ColorAdjustment();

  final int vividness;
  final int depth;
  final int tint;
  final NavisControlColor controls;

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
      other.depth == depth &&
      other.tint == tint &&
      other.controls == controls;

  @override
  int get hashCode => Object.hash(vividness, depth, tint, controls);
}

/// Persisted tuning with independent Light and Dark/OLED brightness and tint.
@immutable
class ColorTuning {
  const new({
    int vividness = 0,
    int lightDepth = 0,
    int darkDepth = 0,
    int lightTint = 0,
    int darkTint = 0,
    this.controls = NavisControlColor.accent,
  }) : vividness = vividness < -5 ? -5 : (vividness > 5 ? 5 : vividness),
       lightDepth = lightDepth < -5 ? -5 : (lightDepth > 5 ? 5 : lightDepth),
       darkDepth = darkDepth < -5 ? -5 : (darkDepth > 5 ? 5 : darkDepth),
       lightTint = lightTint < 0 ? 0 : (lightTint > 5 ? 5 : lightTint),
       darkTint = darkTint < 0 ? 0 : (darkTint > 5 ? 5 : darkTint);

  static const none = ColorTuning();
  final int vividness;
  final int lightDepth;
  final int darkDepth;
  final int lightTint;
  final int darkTint;
  final NavisControlColor controls;

  ColorAdjustment forMode({required bool dark}) => ColorAdjustment(
    vividness: vividness,
    depth: dark ? darkDepth : lightDepth,
    tint: dark ? darkTint : lightTint,
    controls: controls,
  );

  ColorTuning copyWith({
    int? vividness,
    int? lightDepth,
    int? darkDepth,
    int? lightTint,
    int? darkTint,
    NavisControlColor? controls,
  }) => ColorTuning(
    vividness: vividness ?? this.vividness,
    lightDepth: lightDepth ?? this.lightDepth,
    darkDepth: darkDepth ?? this.darkDepth,
    lightTint: lightTint ?? this.lightTint,
    darkTint: darkTint ?? this.darkTint,
    controls: controls ?? this.controls,
  );

  @override
  bool operator ==(Object other) =>
      other is ColorTuning &&
      other.vividness == vividness &&
      other.lightDepth == lightDepth &&
      other.darkDepth == darkDepth &&
      other.lightTint == lightTint &&
      other.darkTint == darkTint &&
      other.controls == controls;
  @override
  int get hashCode => Object.hash(
    vividness,
    lightDepth,
    darkDepth,
    lightTint,
    darkTint,
    controls,
  );
}
