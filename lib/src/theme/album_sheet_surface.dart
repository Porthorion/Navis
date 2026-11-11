import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/caption_tint.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

/// Seed shares tried in order, strongest first; OLED stays near black.
const _steps = <double>[0.16, 0.10, 0.05];
const _oledSteps = <double>[0.08, 0.05, 0.03];

/// Fill for sheets and menus in Album Color mode: the playing album's [seed]
/// mixed into the sheet's own surface (`surfaceContainerLow`, OLED
/// `surfaceContainer`), or `null` when the theme surface should be used.
///
/// The strongest share that keeps `onSurface` and `onSurfaceVariant` readable
/// wins. "Readable" is relative: [kCaptionMinContrast], or the ratio the
/// untinted surface already has when a colour style leaves it lower, so the
/// tint never makes text worse than the plain theme.
Color? albumSheetSurface({
  required int? seed,
  required ColorScheme scheme,
  required NavisColorStyleData style,
}) {
  if (seed == null) return null;
  final base = style.oled
      ? scheme.surfaceContainer
      : scheme.surfaceContainerLow;
  final tint = Color(seed).withValues(alpha: 1);
  double floor(Color text) {
    final baseline = captionContrast(text, base);
    return baseline < kCaptionMinContrast ? baseline : kCaptionMinContrast;
  }

  final bodyFloor = floor(scheme.onSurface);
  final variantFloor = floor(scheme.onSurfaceVariant);
  for (final step in style.oled ? _oledSteps : _steps) {
    final fill = Color.lerp(base, tint, step)!;
    if (captionContrast(scheme.onSurface, fill) >= bodyFloor &&
        captionContrast(scheme.onSurfaceVariant, fill) >= variantFloor) {
      return fill;
    }
  }
  return null;
}
