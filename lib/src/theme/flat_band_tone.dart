import 'dart:math' as math;

import 'package:material_color_utilities/material_color_utilities.dart'
    show Hct;
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_style_schemes.dart';

/// Tone range of the Flat Home band in dark themes (dusky, deep).
const double kFlatBandDarkMinTone = 16;
const double kFlatBandDarkMaxTone = 30;

/// Tone range of the Flat Home band in OLED: still tinted, near black.
const double kFlatBandOledMinTone = 6;
const double kFlatBandOledMaxTone = 10;

/// Tone range of the Flat Home band in light themes (soft, light).
const double kFlatBandLightMinTone = 82;
const double kFlatBandLightMaxTone = 92;

/// Chroma cap for warm hues at dark tones, so they stay wine or mahogany
/// rather than brown (the same cap Immersive applies).
const double _warmDarkMaxChroma = 22;

/// Adapts a cover sample, mixing grey covers toward the theme before adapting.
Color styledCoverSample(
  Color sampled,
  NavisColorStyleData style,
  Color secondaryContainer,
) {
  final adapted = style.adaptArtColor(sampled);
  if (Hct.fromInt(adapted.toARGB32()).chroma >= 6) return adapted;
  return style.adaptArtColor(Color.lerp(sampled, secondaryContainer, 0.25)!);
}

/// Moves the Flat band's sample to a theme tone, retaining hue and chroma.
/// Dark warm hues use the mud guard and chroma cap. Set [adapted] when the
/// sample has already passed through [styledCoverSample].
Color flatBandSample(
  Color sampled,
  NavisColorStyleData style, {
  bool adapted = false,
}) {
  final source = adapted ? sampled : style.adaptArtColor(sampled);
  final hctSample = Hct.fromInt(source.toARGB32());
  if (!style.dark) {
    return hct(
      hctSample.hue,
      hctSample.chroma,
      hctSample.tone.clamp(kFlatBandLightMinTone, kFlatBandLightMaxTone),
    );
  }
  final tone = style.oled
      ? hctSample.tone.clamp(kFlatBandOledMinTone, kFlatBandOledMaxTone)
      : hctSample.tone.clamp(kFlatBandDarkMinTone, kFlatBandDarkMaxTone);
  final chroma = isWarmHue(hctSample.hue)
      ? math.min(hctSample.chroma, _warmDarkMaxChroma)
      : hctSample.chroma;
  return hct(mudGuardHue(hctSample.hue, tone), chroma, tone);
}
