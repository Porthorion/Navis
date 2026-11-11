import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/settings/domain/sheet_style.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/album_sheet_surface.dart';
import 'package:navis/src/theme/dynamic_accent_provider.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

/// Tints popup menus and MenuAnchor menus in Album Color mode, and publishes
/// the one fill that sheets (`showNavisModalSheet`) and the desktop popover
/// read back through `PopupMenuTheme.of(context).color`.
///
/// It lives below `MaterialApp`'s theme, not in `ThemeData`: a song change
/// rebuilds only this widget and open menus, never every `Theme.of` listener.
/// Both inherited themes are always inserted, varying only their data, so the
/// element tree stays put when the mode flips. Watching the seed here also
/// keeps [albumSurfaceSeedProvider] listened (Riverpod pauses providers
/// nobody listens to). Dialogs are left alone.
class AlbumSurfaceScope extends ConsumerWidget {
  const new({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albumColor = ref.watch(sheetStyleProvider) == SheetStyle.albumColor;
    final seed = ref.watch(albumSurfaceSeedProvider);
    final theme = Theme.of(context);
    final tint = albumColor
        ? albumSheetSurface(
            // `.value` keeps the previous album while the next one loads.
            seed: seed.hasError ? null : seed.value,
            scheme: theme.colorScheme,
            style: NavisColorStyleData.of(context),
          )
        : null;
    final menuStyle = theme.menuTheme.style;
    return PopupMenuTheme(
      data: theme.popupMenuTheme.copyWith(color: tint),
      child: MenuTheme(
        data: tint == null
            ? theme.menuTheme
            : MenuThemeData(
                style: (menuStyle ?? const MenuStyle()).merge(
                  MenuStyle(backgroundColor: WidgetStatePropertyAll(tint)),
                ),
              ),
        child: child,
      ),
    );
  }
}
