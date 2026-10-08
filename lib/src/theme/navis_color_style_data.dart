import 'dart:math' as math;

import 'package:material_color_utilities/material_color_utilities.dart'
    show Hct;
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/navis_color_style.dart';
import 'package:navis/src/theme/navis_style_schemes.dart';

/// The active [NavisColorStyle] and how it treats colours Navis derives from
/// artwork: the Home cover wash and the art-tinted Now Playing background.
///
/// Artwork itself is never recoloured; only the fields drawn from it are.
@immutable
class NavisColorStyleData extends ThemeExtension<NavisColorStyleData> {
  const new({
    required this.style,
    required this.dark,
    this.flat = false,
    this.oled = false,
    this.accentHue = seaGlassHue,
  });

  final NavisColorStyle style;

  /// Whether the theme is dark (Dark or OLED).
  final bool dark;

  /// Whether Flat rendering is on: no glows, gradients, shadows or blur,
  /// solid colour fields instead. Orthogonal to the theme mode and [style].
  final bool flat;

  /// Whether the theme is OLED (pure black backgrounds). Implies [dark].
  final bool oled;

  /// HCT hue of the scheme's accent; tints [artworkScrim] for Pastel and
  /// Immersive.
  final double accentHue;

  static const NavisColorStyleData neutralDark = NavisColorStyleData(
    style: NavisColorStyle.neutral,
    dark: true,
  );

  // Matches Flutter's Theme.of(context) lookup convention for extensions.
  // ignore: prefer_constructors_over_static_methods
  static NavisColorStyleData of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<NavisColorStyleData>() ??
        NavisColorStyleData(
          style: NavisColorStyle.neutral,
          dark: theme.brightness == Brightness.dark,
          flat: false,
        );
  }

  /// Near-black colour for the legibility scrims behind white text over
  /// artwork. Neutral keeps pure black; the other styles tint it with their
  /// own hue (tone 6-8, so white text contrast is unchanged in practice).
  Color get artworkScrim {
    return switch (style) {
      NavisColorStyle.neutral => Colors.black,
      NavisColorStyle.pastel => hct(pastelDuskHue(accentHue), 10, 7),
      NavisColorStyle.immersive => hct(accentHue, 12, 6),
      NavisColorStyle.night => hct(62, 10, 6),
    };
  }

  /// Map a colour sampled from artwork into the style.
  ///
  /// Neutral returns [raw] unchanged. The other styles keep the colour's hue
  /// (Night moves it into the warm range) and place it at the style's tone
  /// and chroma, so a yellow cover gives a soft butter or umber field rather
  /// than olive.
  Color adaptArtColor(Color raw) {
    if (style == NavisColorStyle.neutral) {
      return raw;
    }
    final source = Hct.fromInt(raw.toARGB32());
    final achromatic = source.chroma < 6;
    final (maxChroma, minTone, maxTone) = switch ((style, dark)) {
      (NavisColorStyle.pastel, true) => (16.0, 24.0, 32.0),
      (NavisColorStyle.pastel, false) => (30.0, 84.0, 90.0),
      (NavisColorStyle.immersive, true) => (32.0, 16.0, 24.0),
      (NavisColorStyle.immersive, false) => (40.0, 78.0, 88.0),
      (NavisColorStyle.night, true) => (20.0, 20.0, 30.0),
      (NavisColorStyle.night, false) => (24.0, 84.0, 90.0),
      (NavisColorStyle.neutral, _) => (0.0, 0.0, 100.0),
    };
    final tone = source.tone.clamp(minTone, maxTone);
    var chroma = achromatic
        ? source.chroma
        : source.chroma.clamp(0.0, maxChroma);
    var hue = style == NavisColorStyle.night && !achromatic
        ? nightHue(source.hue)
        : source.hue;
    if (dark && !achromatic && isWarmHue(hue)) {
      switch (style) {
        case NavisColorStyle.pastel:
          // Warm hues turn brown at dark tones: blend toward the plum dusk
          // so an orange cover reads as rose or plum, like Pastel's scheme.
          // Yellows are the muddiest, so they travel further (60% up to 85%).
          final yellowness = ((hue - 60) / 40).clamp(0.0, 1.0);
          hue = _blendHue(hue, pastelDuskHue(hue), 0.6 + 0.25 * yellowness);
        case NavisColorStyle.immersive:
          // Keep the hue but stop dark warm colours from reading as brown:
          // lower chroma gives wine or mahogany instead of saturated umber.
          if (tone < 35) {
            chroma = math.min(chroma, 22);
          }
        case NavisColorStyle.neutral || NavisColorStyle.night:
          break;
      }
    }
    return hct(mudGuardHue(hue, tone), chroma, tone);
  }

  /// Rotate [from] toward [to] along the shorter arc by [t] (0-1).
  static double _blendHue(double from, double to, double t) {
    var delta = (to - from) % 360;
    if (delta > 180) {
      delta -= 360;
    }
    return from + delta * t;
  }

  /// Opacity of the background veil over the Home cover wash. Lower values
  /// let more of the wash show; the styled washes are already softened by
  /// [adaptArtColor], so they need less veil than raw cover colours.
  double artWashVeil({required bool subtle}) {
    return switch ((style, dark)) {
      (NavisColorStyle.neutral, false) => subtle ? 0.9 : 0.84,
      (NavisColorStyle.neutral, true) => subtle ? 0.78 : 0.66,
      (NavisColorStyle.pastel, false) => subtle ? 0.78 : 0.62,
      (NavisColorStyle.pastel, true) => subtle ? 0.7 : 0.5,
      (NavisColorStyle.immersive, false) => subtle ? 0.74 : 0.56,
      (NavisColorStyle.immersive, true) => subtle ? 0.62 : 0.42,
      (NavisColorStyle.night, false) => subtle ? 0.8 : 0.66,
      (NavisColorStyle.night, true) => subtle ? 0.7 : 0.52,
    };
  }

  /// Opacity of the art tint at the top of the Now Playing background.
  double get nowPlayingTintAlpha {
    return switch (style) {
      NavisColorStyle.neutral => 0.4,
      NavisColorStyle.pastel => 0.75,
      NavisColorStyle.immersive => 0.85,
      NavisColorStyle.night => 0.7,
    };
  }

  /// Colour for confirmed, positive states (a completed download, a
  /// successful connection test). Neutral keeps the original greens; the
  /// other styles use a green at the same tone as their accents so it reads
  /// as part of the palette.
  Color get success {
    return switch ((style, dark)) {
      (NavisColorStyle.neutral, true) => const Color(0xFF81C995),
      (NavisColorStyle.neutral, false) => const Color(0xFF2E7D32),
      (NavisColorStyle.pastel, true) => hct(150, 34, 82),
      (NavisColorStyle.pastel, false) => hct(150, 36, 42),
      (NavisColorStyle.immersive, true) => hct(150, 48, 80),
      (NavisColorStyle.immersive, false) => hct(150, 48, 40),
      (NavisColorStyle.night, true) => hct(125, 30, 80),
      (NavisColorStyle.night, false) => hct(125, 36, 40),
    };
  }

  @override
  NavisColorStyleData copyWith({
    NavisColorStyle? style,
    bool? dark,
    bool? flat,
    bool? oled,
    double? accentHue,
  }) {
    return NavisColorStyleData(
      style: style ?? this.style,
      dark: dark ?? this.dark,
      flat: flat ?? this.flat,
      oled: oled ?? this.oled,
      accentHue: accentHue ?? this.accentHue,
    );
  }

  @override
  NavisColorStyleData lerp(
    ThemeExtension<NavisColorStyleData>? other,
    double t,
  ) {
    if (other is! NavisColorStyleData) {
      return this;
    }
    return t < 0.5 ? this : other;
  }
}
