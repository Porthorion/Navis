import 'package:flutter/material.dart';

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

  final overlayState = Overlay.maybeOf(context, rootOverlay: useRootNavigator);
  final overlayBox = overlayState?.context.findRenderObject();
  if (overlayState == null || overlayBox is! RenderBox) {
    return null;
  }

  final overlaySize = overlayBox.size;
  final localAnchor = overlayBox.globalToLocal(anchor);
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

  overlayState.insert(scrimEntry);
  Future<void>.delayed(Duration.zero, () {
    if (!scrimDisposed) {
      scrimOpacity.value = targetScrimOpacity;
    }
  });
  try {
    return await showMenu<T>(
      context: context,
      useRootNavigator: useRootNavigator,
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
      shape:
          shape ??
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
