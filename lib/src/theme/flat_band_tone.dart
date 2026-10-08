import 'dart:math' as math;

import 'package:material_color_utilities/material_color_utilities.dart'
    show Hct;
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_style_schemes.dart';

/// Tone range of the Flat Home band in dark themes (dusky, deep).
const double kFlatBandDarkMinTone = 16;
const double kFlatBandDarkMaxTone = 30;

/// Tone range of the Flat Home band in light themes (soft, light).
const double kFlatBandLightMinTone = 82;
const double kFlatBandLightMaxTone = 92;

/// Chroma cap for warm hues at dark tones, so they stay wine or mahogany
/// rather than brown (the same cap Immersive applies).
const double _warmDarkMaxChroma = 22;

/// Moves the Flat band's [sampled] cover colour to a tone that sits with the
/// page: dusky in dark themes, soft in light ones.
///
/// The colour is adapted to [style] first, then only its HCT tone is clamped
/// (hue and chroma are kept). In dark themes yellows are rotated with
/// [mudGuardHue] and warm chroma is capped. Feed the result to
/// `captionTintFor(..., adapted: true)`, which picks readable text and nudges the tone if needed.
Color flatBandSample(Color sampled, NavisColorStyleData style) {
  final adapted = Hct.fromInt(style.adaptArtColor(sampled).toARGB32());
  if (!style.dark) {
    return hct(
      adapted.hue,
      adapted.chroma,
      adapted.tone.clamp(kFlatBandLightMinTone, kFlatBandLightMaxTone),
    );
  }
  final tone = adapted.tone.clamp(kFlatBandDarkMinTone, kFlatBandDarkMaxTone);
  final chroma = isWarmHue(adapted.hue)
      ? math.min(adapted.chroma, _warmDarkMaxChroma)
      : adapted.chroma;
  return hct(mudGuardHue(adapted.hue, tone), chroma, tone);
}
