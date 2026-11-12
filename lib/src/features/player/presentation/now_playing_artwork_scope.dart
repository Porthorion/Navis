import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/player/presentation/now_playing_artwork_background.dart';
import 'package:navis/src/features/player/presentation/now_playing_backdrop.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
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
  const new({
    required this.active,
    required super.child,
    this.accent,
    this.tinted = false,
    this.background = NowPlayingBackground.plain,
    super.key,
  });

  /// Whether the blurred cover is drawn behind this subtree.
  final bool active;

  /// The accent-coloured title's colour over the veiled cover (see
  /// `nowPlayingArtworkAccent`), or null to keep the theme's primary.
  final Color? accent;

  /// The Art-Tinted gradient is painted behind this subtree (the phone queue
  /// overlay), so panels go fully transparent rather than veiled.
  final bool tinted;

  /// The layer this scope's surface paints behind the subtree (Plain when it
  /// paints none); [queuePanelFill] compares the queue's pick with it.
  final NowPlayingBackground background;

  static NowPlayingBackground? backgroundOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<NowPlayingArtworkLayerScope>()
      ?.background;

  static bool tintedOf(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<NowPlayingArtworkLayerScope>()
            ?.tinted ??
        false;
  }

  static bool of(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<NowPlayingArtworkLayerScope>()
            ?.active ??
        false;
  }

  /// The title accent to use here: the scope's adapted colour, else the
  /// theme's primary.
  static Color accentOf(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<NowPlayingArtworkLayerScope>()
            ?.accent ??
        Theme.of(context).colorScheme.primary;
  }

  @override
  bool updateShouldNotify(NowPlayingArtworkLayerScope oldWidget) =>
      active != oldWidget.active ||
      accent != oldWidget.accent ||
      tinted != oldWidget.tinted ||
      background != oldWidget.background;
}

/// The translucent fill for a Now Playing panel while the Artwork layer is
/// shown, or null when the panel should keep its opaque [fallback] surface.
Color nowPlayingArtworkPanelFill(BuildContext context, Color fallback) {
  if (!NowPlayingArtworkLayerScope.of(context)) return fallback;
  if (NowPlayingArtworkLayerScope.tintedOf(context)) return Colors.transparent;
  final style = NavisColorStyleData.of(context);
  if (style.flatNowPlaying) return fallback;
  return style
      .nowPlayingArtworkVeilBase(Theme.of(context).colorScheme.surface)
      .withValues(alpha: kNowPlayingArtworkPanelAlpha);
}

/// The fill of a queue panel for the effective queue background [pick].
///
/// With no surrounding scope the opaque [fallback]. A pick equal to the layer
/// drawn behind the panel keeps that layer's see-through fill; Plain stays
/// opaque; any other pick takes the same solid fill as menus.
// ponytail: a different pick is one solid colour, not the blurred cover;
// paint the layer through the overlay's surface widget if that is wanted here.
Color queuePanelFill(
  BuildContext context,
  NowPlayingBackground pick,
  NowPlayingPublishedBackdrop? backdrop,
  Color fallback,
) {
  final behind = NowPlayingArtworkLayerScope.backgroundOf(context);
  if (behind == null) return fallback;
  final style = NavisColorStyleData.of(context);
  final layer = nowPlayingQueueLayer(
    pick,
    backdrop,
    flat: style.flatNowPlaying,
  );
  if (layer == behind) return nowPlayingArtworkPanelFill(context, fallback);
  if (layer == NowPlayingBackground.plain) return fallback;
  return nowPlayingMenuFill(
        layer: layer,
        backdrop: backdrop,
        scheme: Theme.of(context).colorScheme,
        style: style,
      ) ??
      fallback;
}
