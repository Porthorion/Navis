import 'package:material_color_utilities/material_color_utilities.dart'
    show Hct;
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';
import 'package:navis/src/theme/navis_style_schemes.dart';

/// Minimum WCAG contrast the caption text must reach against its fill.
const double kCaptionMinContrast = 4.5;

/// Alpha of the light caption's subtitle, shared with the near-black ink.
const double kCaptionSubtitleAlpha = 0.82;

/// Fill and text colours for an album caption drawn over a cover.
@immutable
class CaptionTint {
  const new({required this.fill, required this.text, required this.subtext});

  factory lerp(CaptionTint a, CaptionTint b, double t) => CaptionTint(
    fill: Color.lerp(a.fill, b.fill, t)!,
    text: Color.lerp(a.text, b.text, t)!,
    subtext: Color.lerp(a.subtext, b.subtext, t)!,
  );

  /// Opaque colour the caption gradient fades into.
  final Color fill;

  /// Title colour.
  final Color text;

  /// Subtitle colour; translucent, so contrast is judged after compositing.
  final Color subtext;

  @override
  bool operator ==(Object other) =>
      other is CaptionTint &&
      other.fill == fill &&
      other.text == text &&
      other.subtext == subtext;

  @override
  int get hashCode => Object.hash(fill, text, subtext);
}

/// WCAG contrast ratio of [foreground] over [background]; a translucent
/// foreground is composited onto the (opaque) background first.
double captionContrast(Color foreground, Color background) {
  final shown = Color.alphaBlend(foreground, background);
  final a = shown.computeLuminance();
  final b = background.computeLuminance();
  final lighter = a > b ? a : b;
  final darker = a > b ? b : a;
  return (lighter + 0.05) / (darker + 0.05);
}

/// Near-black caption ink, derived from a neutral HCT tone rather than a
/// literal so it follows the same colour science as the rest of the theme.
final Color _ink = hct(0, 0, 8);

/// Derives the caption colours for a cover whose bottom edge averages
/// [sampled], in [style].
///
/// The sampled colour is adapted to the style, then white or near-black text
/// is chosen by whichever contrasts more with it. The fill's HCT tone is then
/// moved (hue and chroma kept) away from the text until both the title and
/// the subtitle reach [kCaptionMinContrast].
///
/// Set [adapted] when [sampled] already went through
/// [NavisColorStyleData.adaptArtColor], so the style is applied only once.
CaptionTint captionTintFor(
  Color sampled,
  NavisColorStyleData style, {
  bool adapted = false,
}) {
  final base = adapted ? sampled : style.adaptArtColor(sampled);
  const white = Colors.white;
  final whiteSub = white.withValues(alpha: kCaptionSubtitleAlpha);
  final inkSub = _ink.withValues(alpha: kCaptionSubtitleAlpha);

  final lightText = captionContrast(white, base) >= captionContrast(_ink, base);
  final text = lightText ? white : _ink;
  final subtext = lightText ? whiteSub : inkSub;

  bool passes(Color fill) =>
      captionContrast(text, fill) >= kCaptionMinContrast &&
      captionContrast(subtext, fill) >= kCaptionMinContrast;

  var fill = Color(base.toARGB32() | 0xFF000000);
  if (!passes(fill)) {
    final source = Hct.fromInt(fill.toARGB32());
    // Light text wants a darker fill and vice versa.
    final step = lightText ? -1.0 : 1.0;
    var tone = source.tone;
    while (!passes(fill) && tone > 0 && tone < 100) {
      tone = (tone + step).clamp(0.0, 100.0);
      fill = Color(Hct.from(source.hue, source.chroma, tone).toInt());
    }
  }
  return CaptionTint(fill: fill, text: text, subtext: subtext);
}
