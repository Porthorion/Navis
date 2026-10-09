import 'package:material_ui/material_ui.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

/// Alpha of the translucent fill Now Playing panels use while the Artwork
/// background's blurred cover is shown, so the art stays visible behind them.
const double kNowPlayingArtworkPanelAlpha = 0.45;

/// Marks the subtree below a visible Artwork background layer.
///
/// Panels that normally paint an opaque surface (the split lyrics pane, the
/// right pane, queue and wide side panels) read it through
/// [nowPlayingArtworkPanelFill] and switch to a translucent veil. Without a
/// scope, or under Flat (which draws no Artwork layer), panels stay opaque.
class NowPlayingArtworkLayerScope extends InheritedWidget {
  const new({required this.active, required super.child, super.key});

  /// Whether the blurred cover is drawn behind this subtree.
  final bool active;

  static bool of(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<NowPlayingArtworkLayerScope>()
            ?.active ??
        false;
  }

  @override
  bool updateShouldNotify(NowPlayingArtworkLayerScope oldWidget) =>
      active != oldWidget.active;
}

/// The translucent fill for a Now Playing panel while the Artwork layer is
/// shown, or null when the panel should keep its opaque [fallback] surface.
Color nowPlayingArtworkPanelFill(BuildContext context, Color fallback) {
  if (!NowPlayingArtworkLayerScope.of(context)) return fallback;
  final style = NavisColorStyleData.of(context);
  if (style.flat) return fallback;
  return style
      .nowPlayingArtworkVeilBase(Theme.of(context).colorScheme.surface)
      .withValues(alpha: kNowPlayingArtworkPanelAlpha);
}
