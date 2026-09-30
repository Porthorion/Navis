import 'package:flutter/material.dart';
import 'package:navis/src/theme/navis_tokens.dart';

/// Shows a desktop popup menu with a lightweight scrim and root-overlay
/// anchoring so right-click context menus feel modal and placement stays
/// stable across nested navigators.
Future<T?> showDesktopContextMenu<T>({
  required BuildContext context,
  required Offset anchor,
  required List<PopupMenuEntry<T>> items,
  BoxConstraints? constraints,
  ShapeBorder? shape,
  Color? color,
  Color? surfaceTintColor,
  bool useRootNavigator = true,
}) async {
  const fadeInDuration = Duration(milliseconds: 130);
  const fadeOutDuration = Duration(milliseconds: 90);
  const targetScrimOpacity = 0.22;

  final host = await _resolveDesktopContextMenuHost(
    context,
    useRootNavigator: useRootNavigator,
  );
  if (host == null) {
    return null;
  }
  if (!context.mounted) return null;

  final overlaySize = host.overlayBox.size;
  final localAnchor = host.overlayBox.globalToLocal(anchor);
  final clampedX = localAnchor.dx.clamp(8.0, overlaySize.width - 8.0);
  final clampedY = localAnchor.dy.clamp(8.0, overlaySize.height - 8.0);
  final menuPosition = RelativeRect.fromLTRB(
    clampedX,
    clampedY,
    overlaySize.width - clampedX,
    overlaySize.height - clampedY,
  );

  final scrimOpacity = ValueNotifier<double>(0);
  var scrimDisposed = false;
  final scrimEntry = OverlayEntry(
    builder: (context) => IgnorePointer(
      child: ValueListenableBuilder<double>(
        valueListenable: scrimOpacity,
        builder: (context, opacity, _) {
          return AnimatedOpacity(
            duration: opacity > 0 ? fadeInDuration : fadeOutDuration,
            curve: opacity > 0 ? Curves.easeOutCubic : Curves.easeInCubic,
            opacity: opacity,
            child: const ColoredBox(color: Colors.black),
          );
        },
      ),
    ),
  );

  host.overlayState.insert(scrimEntry);
  Future<void>.delayed(Duration.zero, () {
    if (!scrimDisposed) {
      scrimOpacity.value = targetScrimOpacity;
    }
  });
  try {
    return await showMenu<T>(
      context: context,
      useRootNavigator: useRootNavigator,
      requestFocus: true,
      position: menuPosition,
      popUpAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 170),
        reverseDuration: Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
      constraints:
          constraints ??
          BoxConstraints(
            minWidth: 200,
            maxWidth: 320,
            maxHeight: overlaySize.height - 24,
          ),
      shape: shape ?? RoundedRectangleBorder(borderRadius: NavisRadius.mdAll),
      color: color,
      surfaceTintColor: surfaceTintColor,
      items: items,
    );
  } finally {
    scrimOpacity.value = 0;
    await Future<void>.delayed(fadeOutDuration);
    scrimEntry.remove();
    scrimDisposed = true;
    scrimOpacity.dispose();
  }
}

class _DesktopContextMenuHost {
  const _DesktopContextMenuHost({
    required this.overlayState,
    required this.overlayBox,
  });

  final OverlayState overlayState;
  final RenderBox overlayBox;
}

/// Resolves the exact overlay that [showMenu] will use.
///
/// A shell branch can be mounted before its root navigator has finished its
/// first layout. Retrying once at the end of that frame prevents the first
/// More or secondary-click action from silently losing its popup.
Future<_DesktopContextMenuHost?> _resolveDesktopContextMenuHost(
  BuildContext context, {
  required bool useRootNavigator,
}) async {
  final initialHost = _findDesktopContextMenuHost(
    context,
    useRootNavigator: useRootNavigator,
  );
  if (initialHost != null) return initialHost;

  await WidgetsBinding.instance.endOfFrame;
  if (!context.mounted) return null;
  return _findDesktopContextMenuHost(
    context,
    useRootNavigator: useRootNavigator,
  );
}

_DesktopContextMenuHost? _findDesktopContextMenuHost(
  BuildContext context, {
  required bool useRootNavigator,
}) {
  final navigator = Navigator.maybeOf(
    context,
    rootNavigator: useRootNavigator,
  );
  final overlayState = navigator?.overlay;
  final overlayBox = overlayState?.context.findRenderObject();
  if (overlayState != null &&
      overlayBox is RenderBox &&
      overlayBox.attached &&
      overlayBox.hasSize &&
      overlayBox.size.width > 0 &&
      overlayBox.size.height > 0) {
    return _DesktopContextMenuHost(
      overlayState: overlayState,
      overlayBox: overlayBox,
    );
  }
  return null;
}
