import 'dart:math' as math;

import 'package:material_color_utilities/material_color_utilities.dart'
    show Hct;
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/navis_color_style.dart';

// OLED surface constants for the Neutral style.
const Color _oledContainer = Color(0xFF0A0A0A);
const Color _oledContainerHighest = Color(0xFF121212);

/// Hue used when the seed has no colour of its own (the default white seed,
/// greys): sea glass, after the Navis wave mark.
const double seaGlassHue = 190;

/// Below this HCT chroma a seed is treated as achromatic.
const double _achromaticChroma = 8;

/// Hue of the error family: a soft rose rather than Material's signal red.
const double _errorHue = 22;

/// Build the [ColorScheme] for [style] from [seed].
///
/// [NavisColorStyle.neutral] reproduces the original Navis schemes, except
/// that dark and OLED primary, secondary and tertiary containers in the muddy
/// band are capped at chroma 20.
/// The other styles use hand-built role tables over HCT so that every role's
/// tone and chroma is chosen deliberately:
///
/// - Containers and surfaces never land in the muddy band (tone 25–50 with
///   high chroma) that Material's fixed tone table produces for saturated
///   seeds, such as brick-red buttons from an orange cover.
/// - Yellow hues are rotated toward warm umber at dark tones so they do not
///   turn khaki (see [mudGuardHue]).
/// - OLED keeps pure black backgrounds in every style.
ColorScheme buildStyledColorScheme({
  required Color seed,
  required Brightness brightness,
  bool oled = false,
  NavisColorStyle style = NavisColorStyle.neutral,
}) {
  final dark = brightness == Brightness.dark || oled;
  if (style == NavisColorStyle.neutral) {
    return _neutralScheme(seed, dark: dark, oled: oled);
  }
  final source = Hct.fromInt(seed.toARGB32());
  final achromatic = source.chroma < _achromaticChroma;
  final recipe = switch (style) {
    NavisColorStyle.pastel => _pastelRecipe(source, achromatic),
    NavisColorStyle.immersive => _immersiveRecipe(source, achromatic),
    NavisColorStyle.night => _nightRecipe(source, achromatic),
    NavisColorStyle.neutral => throw StateError('handled above'),
  };
  return recipe.build(dark: dark, oled: oled);
}

ColorScheme _neutralScheme(
  Color seed, {
  required bool dark,
  required bool oled,
}) {
  if (!dark) {
    return ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
      // Tonal spot retains the selected accent while keeping text, headings,
      // and interactive roles sufficiently dark against light surfaces.
      dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
    );
  }
  final fidelityScheme = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: Brightness.dark,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  );
  // Fidelity keeps the seed's full chroma in the containers, which turns
  // saturated covers into brick-red or olive buttons at tone 25-50.
  final baseScheme = fidelityScheme.copyWith(
    primaryContainer: _deMud(fidelityScheme.primaryContainer),
    secondaryContainer: _deMud(fidelityScheme.secondaryContainer),
    tertiaryContainer: _deMud(fidelityScheme.tertiaryContainer),
  );
  if (!oled) {
    return baseScheme;
  }
  return baseScheme.copyWith(
    surface: Colors.black,
    onSurface: Colors.white,
    surfaceContainerLowest: Colors.black,
    surfaceContainerLow: _oledContainer,
    surfaceContainer: _oledContainer,
    surfaceContainerHigh: _oledContainer,
    surfaceContainerHighest: _oledContainerHighest,
    // Ensure "on" colors for container variants stay readable
    onSurfaceVariant: baseScheme.onSurfaceVariant.withAlpha(230),
  );
}

/// Replace [color] with a low-chroma version of the same hue when it sits in
/// the muddy band (tone 25-50, chroma above 24); other colours are returned
/// unchanged.
Color _deMud(Color color) {
  final source = Hct.fromInt(color.toARGB32());
  if (source.tone < 25 || source.tone > 50 || source.chroma <= 24) {
    return color;
  }
  return hct(mudGuardHue(source.hue, source.tone), 20, source.tone);
}

/// Rotate yellow and yellow-green hues toward warm umber at dark tones.
///
/// Dark yellows read as khaki or olive. Hues near 100° (HCT) are pulled
/// toward 58° with a weight that fades out by 60° and 140°, so neighbouring
/// hues move smoothly instead of jumping. Tones of 40 and above are returned
/// unchanged.
double mudGuardHue(double hue, double tone) {
  if (tone >= 40) {
    return hue;
  }
  final weight = (1 - (hue - 100).abs() / 40).clamp(0.0, 1.0) * 0.9;
  return hue + (58 - hue) * weight;
}

/// Background hue for Pastel on dark schemes.
///
/// Warm hues (reds through yellows) turn brown at dark tones, so Pastel
/// places warm accents on a dusky plum base instead, the way dark pastel
/// palettes pair warm pastels with a cool backdrop. Cool hues keep their own
/// hue; greens blend between the two.
double pastelDuskHue(double hue) {
  const plum = 340.0;
  final h = _sanitize(hue);
  final double weight;
  if (h >= 320 || h <= 110) {
    weight = 1;
  } else if (h < 150) {
    weight = (150 - h) / 40;
  } else {
    weight = 0;
  }
  var delta = (plum - h) % 360;
  if (delta > 180) {
    delta -= 360;
  }
  return _sanitize(h + delta * weight);
}

/// Pull [hue] toward amber for the Night style and keep it within the warm
/// range (15°–95°), so blues and greens become rose, amber or gold.
double nightHue(double hue) {
  const target = 55.0;
  var delta = (target - hue) % 360;
  if (delta > 180) {
    delta -= 360;
  }
  final pulled = _sanitize(hue + delta * 0.6);
  if (pulled >= 15 && pulled <= 95) {
    return pulled;
  }
  final toLow = _arc(pulled, 15);
  final toHigh = _arc(pulled, 95);
  return toLow <= toHigh ? 15 : 95;
}

/// Light paper hue for Pastel: warm hues (0-75 and 340+) move up to 25°
/// toward peach (55°), which holds more chroma at high tone than red does.
double pastelPaperHue(double hue) {
  final h = _sanitize(hue);
  if (h > 75 && h < 340) {
    return h;
  }
  var delta = 55 - h;
  if (delta > 180) {
    delta -= 360;
  }
  return _sanitize(h + delta.clamp(-25.0, 25.0));
}

double _sanitize(double hue) => ((hue % 360) + 360) % 360;

double _arc(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

/// A colour at [hue], [chroma] and [tone] in HCT. Chroma is reduced if the
/// combination falls outside sRGB; hue and tone are kept.
Color hct(double hue, double chroma, double tone) {
  return Color(Hct.from(_sanitize(hue), chroma, tone).toInt());
}

/// A tone ladder for one hue: [at] applies [mudGuardHue] for dark tones.
class _Hue {
  const new(this.hue);

  final double hue;

  Color at(double chroma, double tone) {
    return hct(mudGuardHue(hue, tone), chroma, tone);
  }
}

/// Role table inputs for one style. Each recipe defines the hues and
/// chromas; [build] places them at the tones for dark, light and OLED.
class _Recipe {
  const new({
    required this.accent,
    required this.accentChroma,
    required this.secondaryChroma,
    required this.tertiary,
    required this.tertiaryChroma,
    required this.neutral,
    this.darkNeutral,
    this.lightNeutral,
    required this.darkSurfaceChroma,
    required this.lightSurfaceChroma,
    required this.containerChromaDark,
    required this.containerChromaLight,
    required this.lightAccentChroma,
    required this.lightSurfaceTone,
    required this.textHue,
    required this.textChroma,
    this.errorChroma = 44,
  });

  final _Hue accent;

  /// Chroma of accent fills on dark schemes (tone 80–82).
  final double accentChroma;
  final double secondaryChroma;
  final _Hue tertiary;
  final double tertiaryChroma;

  /// Hue of backgrounds and text.
  final _Hue neutral;

  /// Hue of backgrounds on dark schemes, when it differs from [neutral].
  final _Hue? darkNeutral;

  /// Hue of backgrounds on light schemes, when it differs from [neutral].
  final _Hue? lightNeutral;
  final double darkSurfaceChroma;
  final double lightSurfaceChroma;

  /// Chroma of primary/secondary/tertiary containers.
  final double containerChromaDark;
  final double containerChromaLight;

  /// Chroma of accent ink on light schemes (tone 40–42).
  final double lightAccentChroma;

  /// Tone of the light-scheme background.
  final double lightSurfaceTone;

  /// Hue and chroma of body text.
  final _Hue textHue;
  final double textChroma;
  final double errorChroma;

  ColorScheme build({required bool dark, required bool oled}) {
    return dark ? _dark(oled: oled) : _light();
  }

  ColorScheme _dark({required bool oled}) {
    final n = darkNeutral ?? neutral;
    final s = darkSurfaceChroma;
    final c = containerChromaDark;
    const error = _Hue(_errorHue);
    const black = Colors.black;
    // OLED keeps pure black backgrounds; cards and sheets step up through
    // near-black tones that still carry the style's hue.
    final oledStep = math.min<double>(s, 8);
    return ColorScheme(
      brightness: Brightness.dark,
      primary: accent.at(accentChroma, 82),
      onPrimary: accent.at(math.min<double>(accentChroma, 18), 14),
      primaryContainer: accent.at(c, 26),
      onPrimaryContainer: accent.at(accentChroma * 0.7, 90),
      primaryFixed: accent.at(accentChroma * 0.7, 90),
      primaryFixedDim: accent.at(accentChroma, 80),
      onPrimaryFixed: accent.at(16, 12),
      onPrimaryFixedVariant: accent.at(c, 24),
      secondary: accent.at(secondaryChroma, 80),
      onSecondary: accent.at(math.min<double>(secondaryChroma, 14), 16),
      secondaryContainer: accent.at(c, 24),
      onSecondaryContainer: accent.at(secondaryChroma, 90),
      secondaryFixed: accent.at(secondaryChroma, 90),
      secondaryFixedDim: accent.at(secondaryChroma, 80),
      onSecondaryFixed: accent.at(12, 12),
      onSecondaryFixedVariant: accent.at(c, 24),
      tertiary: tertiary.at(tertiaryChroma, 82),
      onTertiary: tertiary.at(math.min<double>(tertiaryChroma, 18), 14),
      tertiaryContainer: tertiary.at(c, 26),
      onTertiaryContainer: tertiary.at(tertiaryChroma * 0.7, 90),
      tertiaryFixed: tertiary.at(tertiaryChroma * 0.7, 90),
      tertiaryFixedDim: tertiary.at(tertiaryChroma, 80),
      onTertiaryFixed: tertiary.at(16, 12),
      onTertiaryFixedVariant: tertiary.at(c, 24),
      error: error.at(errorChroma, 80),
      onError: error.at(16, 16),
      errorContainer: error.at(math.min<double>(errorChroma, 18), 26),
      onErrorContainer: error.at(errorChroma * 0.6, 90),
      surface: oled ? black : n.at(s, 12),
      onSurface: textHue.at(textChroma, 92),
      surfaceDim: oled ? black : n.at(s, 10),
      surfaceBright: oled ? n.at(oledStep, 14) : n.at(s, 26),
      surfaceContainerLowest: oled ? black : n.at(s, 8),
      surfaceContainerLow: oled ? n.at(oledStep, 4) : n.at(s, 14),
      surfaceContainer: oled ? n.at(oledStep, 6) : n.at(s, 16),
      surfaceContainerHigh: oled ? n.at(oledStep, 8) : n.at(s, 20),
      surfaceContainerHighest: oled ? n.at(oledStep, 11) : n.at(s, 24),
      onSurfaceVariant: textHue.at(textChroma + 8, 78),
      outline: n.at(s + 2, 58),
      outlineVariant: n.at(s, oled ? 22 : 30),
      shadow: black,
      scrim: black,
      inverseSurface: n.at(math.min<double>(s, 8), 90),
      onInverseSurface: n.at(math.min<double>(s, 10), 20),
      inversePrimary: accent.at(lightAccentChroma, 40),
      surfaceTint: accent.at(accentChroma, 82),
    );
  }

  ColorScheme _light() {
    final n = lightNeutral ?? neutral;
    final s = lightSurfaceChroma;
    final c = containerChromaLight;
    const error = _Hue(_errorHue);
    final ink = lightAccentChroma;
    final t = lightSurfaceTone;
    return ColorScheme(
      brightness: Brightness.light,
      primary: accent.at(ink, 42),
      onPrimary: Colors.white,
      primaryContainer: accent.at(c, 88),
      onPrimaryContainer: accent.at(math.min<double>(ink, 24), 20),
      primaryFixed: accent.at(c, 88),
      primaryFixedDim: accent.at(c + 4, 78),
      onPrimaryFixed: accent.at(16, 12),
      onPrimaryFixedVariant: accent.at(math.min<double>(ink, 24), 22),
      secondary: accent.at(secondaryChroma + 4, 42),
      onSecondary: Colors.white,
      secondaryContainer: accent.at(
        math.max<double>(secondaryChroma, c * 0.75),
        90,
      ),
      onSecondaryContainer: accent.at(16, 20),
      secondaryFixed: accent.at(secondaryChroma, 90),
      secondaryFixedDim: accent.at(secondaryChroma, 80),
      onSecondaryFixed: accent.at(12, 12),
      onSecondaryFixedVariant: accent.at(16, 22),
      tertiary: tertiary.at(math.min<double>(tertiaryChroma, ink), 42),
      onTertiary: Colors.white,
      tertiaryContainer: tertiary.at(c, 88),
      onTertiaryContainer: tertiary.at(
        math.min<double>(tertiaryChroma, 24),
        20,
      ),
      tertiaryFixed: tertiary.at(c, 88),
      tertiaryFixedDim: tertiary.at(c + 4, 78),
      onTertiaryFixed: tertiary.at(16, 12),
      onTertiaryFixedVariant: tertiary.at(
        math.min<double>(tertiaryChroma, 24),
        22,
      ),
      error: error.at(errorChroma + 12, 42),
      onError: Colors.white,
      errorContainer: error.at(math.min<double>(errorChroma, 26), 90),
      onErrorContainer: error.at(24, 20),
      surface: n.at(s, t),
      onSurface: textHue.at(textChroma + 4, 14),
      surfaceDim: n.at(s + 2, t - 8),
      surfaceBright: n.at(s, math.min<double>(t + 1, 99)),
      surfaceContainerLowest: n.at(s * 0.4, math.min<double>(t + 2, 99.5)),
      surfaceContainerLow: n.at(s + 1, t - 2),
      surfaceContainer: n.at(s + 2, t - 4),
      surfaceContainerHigh: n.at(s + 3, t - 6),
      surfaceContainerHighest: n.at(s + 4, t - 8),
      onSurfaceVariant: textHue.at(textChroma + 10, 34),
      outline: n.at(s + 4, 52),
      outlineVariant: n.at(s + 4, 82),
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: n.at(math.min<double>(s, 10), 20),
      onInverseSurface: n.at(math.min<double>(s, 8), 94),
      inversePrimary: accent.at(accentChroma, 82),
      surfaceTint: accent.at(ink, 42),
    );
  }
}

/// Chalk pastels on tinted paper: soft accents, gently tinted backgrounds,
/// and a pastel family that shares one tone.
_Recipe _pastelRecipe(Hct source, bool achromatic) {
  final hue = achromatic ? seaGlassHue : source.hue;
  final chroma = achromatic ? 36.0 : source.chroma.clamp(28.0, 44.0);
  return _Recipe(
    accent: _Hue(hue),
    accentChroma: chroma,
    secondaryChroma: 18,
    tertiary: _Hue(hue + 48),
    tertiaryChroma: chroma * 0.85,
    neutral: _Hue(hue),
    darkNeutral: _Hue(pastelDuskHue(hue)),
    lightNeutral: _Hue(pastelPaperHue(hue)),
    darkSurfaceChroma: 10,
    // Warm hues are gamut-limited at this tone; the paper takes what fits.
    lightSurfaceChroma: 12,
    containerChromaDark: 14,
    containerChromaLight: 28,
    // Light accents double as text, so they stay at ink tone; enough chroma
    // keeps warm hues coral or rose instead of brown.
    lightAccentChroma: math.max<double>(chroma, 48),
    lightSurfaceTone: 95,
    textHue: _Hue(hue),
    textChroma: 4,
    errorChroma: 40,
  );
}

/// The accent fills the room: backgrounds take the accent hue in deep jewel
/// tones on dark schemes and clear tints on light ones, while the accent
/// keeps the seed's full chroma.
_Recipe _immersiveRecipe(Hct source, bool achromatic) {
  final hue = achromatic ? seaGlassHue : source.hue;
  final chroma = achromatic ? 48.0 : math.max<double>(source.chroma, 32);
  return _Recipe(
    accent: _Hue(hue),
    accentChroma: chroma,
    secondaryChroma: 24,
    tertiary: _Hue(hue + 40),
    tertiaryChroma: chroma * 0.8,
    neutral: _Hue(hue),
    darkSurfaceChroma: math.min<double>(chroma * 0.5, 20),
    lightSurfaceChroma: math.min<double>(chroma * 0.4, 16),
    containerChromaDark: 24,
    containerChromaLight: math.min<double>(chroma, 40),
    lightAccentChroma: chroma,
    lightSurfaceTone: 95,
    textHue: _Hue(hue),
    textChroma: 6,
    errorChroma: 56,
  );
}

/// Warm, low-blue colours: umber backgrounds and warm-white text on dark
/// schemes, sepia paper on light ones, and accents moved into the
/// rose-to-gold range.
_Recipe _nightRecipe(Hct source, bool achromatic) {
  final hue = achromatic ? 55.0 : nightHue(source.hue);
  final chroma = achromatic ? 36.0 : source.chroma.clamp(24.0, 40.0);
  return _Recipe(
    accent: _Hue(hue),
    accentChroma: chroma,
    secondaryChroma: 18,
    tertiary: _Hue(nightHue(hue + 30)),
    tertiaryChroma: chroma * 0.8,
    neutral: const _Hue(62),
    darkSurfaceChroma: 9,
    lightSurfaceChroma: 12,
    containerChromaDark: 16,
    containerChromaLight: 26,
    lightAccentChroma: math.min<double>(chroma, 40),
    lightSurfaceTone: 95,
    textHue: const _Hue(70),
    textChroma: 10,
    errorChroma: 40,
  );
}
