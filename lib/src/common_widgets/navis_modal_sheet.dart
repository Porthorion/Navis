import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/src/features/player/presentation/now_playing_backdrop.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/settings/domain/sheet_style.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/album_sheet_surface.dart';
import 'package:navis/src/theme/navis_color_style_data.dart';

/// [showModalBottomSheet] with Navis' sheet fill.
///
/// In Album Color mode the app publishes the album tint through
/// `PopupMenuTheme` (see `AlbumSurfaceScope`); it is read once here, so an
/// open sheet keeps its colour across a track change. In Match Now Playing a
/// sheet opened over expanded Now Playing takes its published background
/// instead ([_nowPlayingSheetFill]). Otherwise the fill is null and the
/// theme's `bottomSheetTheme` applies. Every sheet in the app opens through
/// this function (`navis_modal_sheet_audit_test.dart`).
Future<T?> showNavisModalSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  String? barrierLabel,
  double? elevation,
  ShapeBorder? shape,
  Clip? clipBehavior,
  BoxConstraints? constraints,
  Color? barrierColor,
  bool isScrollControlled = false,
  double scrollControlDisabledMaxHeightRatio = 9 / 16,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool? showDragHandle,
  bool useSafeArea = false,
  RouteSettings? routeSettings,
  AnimationController? transitionAnimationController,
  Offset? anchorPoint,
  AnimationStyle? sheetAnimationStyle,
  bool? requestFocus,
}) {
  return showModalBottomSheet<T>(
    context: context,
    builder: builder,
    backgroundColor:
        backgroundColor ??
        PopupMenuTheme.of(context).color ??
        _nowPlayingSheetFill(context),
    barrierLabel: barrierLabel,
    elevation: elevation,
    shape: shape,
    clipBehavior: clipBehavior,
    constraints: constraints,
    barrierColor: barrierColor,
    isScrollControlled: isScrollControlled,
    scrollControlDisabledMaxHeightRatio: scrollControlDisabledMaxHeightRatio,
    useRootNavigator: useRootNavigator,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    showDragHandle: showDragHandle,
    useSafeArea: useSafeArea,
    routeSettings: routeSettings,
    transitionAnimationController: transitionAnimationController,
    anchorPoint: anchorPoint,
    sheetAnimationStyle: sheetAnimationStyle,
    requestFocus: requestFocus,
  );
}

/// Match Now Playing: the sheet fill for a sheet opened while Now Playing is
/// expanded, seeded from the background it published (the Art-Tinted tint, or
/// the Artwork cover average), else null for the theme fill. Nothing is
/// published under Plain/Flat, so those keep the theme. Read once at open.
Color? _nowPlayingSheetFill(BuildContext context) {
  // No scope in isolated widget tests: the theme fill. ProviderScope builds an
  // UncontrolledProviderScope, which lib/main.dart mounts directly.
  if (context.findAncestorWidgetOfExactType<UncontrolledProviderScope>() ==
      null) {
    return null;
  }
  final container = ProviderScope.containerOf(context, listen: false);
  // Cheapest checks first: the settings provider is only touched (and, in
  // isolated tests, instantiated) once a Now Playing backdrop exists.
  if (!container.read(playerSheetExpandedProvider)) return null;
  final backdrop = container.read(nowPlayingPublishedBackdropProvider);
  if (backdrop == null ||
      container.read(sheetStyleProvider) != SheetStyle.matchNowPlaying) {
    return null;
  }
  return albumSheetSurface(
    seed: (backdrop.tintColor ?? backdrop.coverAverage)?.toARGB32(),
    scheme: Theme.of(context).colorScheme,
    style: NavisColorStyleData.of(context),
  );
}
