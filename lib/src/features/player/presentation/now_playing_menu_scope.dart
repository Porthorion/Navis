import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/player/presentation/now_playing_artwork_background.dart';
import 'package:navis/src/features/player/presentation/now_playing_backdrop.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

/// Gives popup menus and MenuAnchor menus the effective menu background while
/// Now Playing is expanded, and publishes the one fill that sheets
/// (`showNavisModalSheet`), Speed & Pitch and the desktop popover read back
/// through `PopupMenuTheme.of(context).color`.
///
/// The fill follows [nowPlayingMenuBackgroundProvider] (Now Playing's own
/// background, or the Menus pick while Customize Queue and Menus is on),
/// resolved against what [NowPlayingBackdrop] published; see
/// [nowPlayingMenuFill]. Outside Now Playing everything uses the plain theme.
///
/// It lives below `MaterialApp`'s theme, not in `ThemeData`: a song change
/// rebuilds only this widget and open menus, never every `Theme.of` listener.
/// Both inherited themes are always inserted, varying only their data, so the
/// element tree stays put when the fill appears or goes. Dialogs are left
/// alone.
class NowPlayingMenuScope extends ConsumerWidget {
  const new({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded = ref.watch(playerSheetExpandedProvider);
    final pick = ref.watch(nowPlayingMenuBackgroundProvider);
    final backdrop = expanded
        ? ref.watch(nowPlayingPublishedBackdropProvider)
        : null;
    final theme = Theme.of(context);
    final style = NavisColorStyleData.of(context);
    final fill = !expanded
        ? null
        : nowPlayingMenuFill(
            layer: resolveNowPlayingLayer(
              pick,
              backdrop,
              flat: style.flatNowPlaying,
            ),
            backdrop: backdrop,
            scheme: theme.colorScheme,
            style: style,
          );
    final menuStyle = theme.menuTheme.style;
    return PopupMenuTheme(
      data: theme.popupMenuTheme.copyWith(color: fill),
      child: MenuTheme(
        data: fill == null
            ? theme.menuTheme
            : MenuThemeData(
                style: (menuStyle ?? const MenuStyle()).merge(
                  MenuStyle(backgroundColor: WidgetStatePropertyAll(fill)),
                ),
              ),
        child: child,
      ),
    );
  }
}
