import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Desktop width buckets used by desktop adaptive UI composition.
enum DesktopLayoutClass {
  compactDesktop,
  standardDesktop,
  ultraWideDesktop,
}

/// Shared width buckets for non-desktop (phone/tablet) adaptive UI.
enum AdaptiveLayoutClass {
  phoneCompact,
  tabletMedium,
  tabletExpanded,
}

/// Shell composition buckets for non-desktop adaptive UI.
enum AdaptiveShellMode {
  phoneBottomNav,
  standardRail,
  compactWideLandscape,
}

bool get isDesktopRuntime {
  if (kIsWeb) {
    return false;
  }
  return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
}

DesktopLayoutClass resolveDesktopLayoutClass(double width) {
  if (width >= 1600) {
    return DesktopLayoutClass.ultraWideDesktop;
  }
  if (width >= 1200) {
    return DesktopLayoutClass.standardDesktop;
  }
  return DesktopLayoutClass.compactDesktop;
}

AdaptiveLayoutClass resolveAdaptiveLayoutClass(double width) {
  if (width >= 840) {
    return AdaptiveLayoutClass.tabletExpanded;
  }
  if (width >= 600) {
    return AdaptiveLayoutClass.tabletMedium;
  }
  return AdaptiveLayoutClass.phoneCompact;
}

AdaptiveShellMode resolveAdaptiveShellMode({
  required bool desktopRuntime,
  required Size viewportSize,
  required EdgeInsets safePadding,
}) {
  if (desktopRuntime) {
    return viewportSize.width >= 600
        ? AdaptiveShellMode.standardRail
        : AdaptiveShellMode.phoneBottomNav;
  }

  final width = viewportSize.width;
  final height = viewportSize.height;
  final shortestSide = width < height ? width : height;
  final isPhoneFormFactor = shortestSide < 600;
  final adaptiveClass = resolveAdaptiveLayoutClass(width);
  final isLandscape = width > height;

  if (!isPhoneFormFactor) {
    if (adaptiveClass == AdaptiveLayoutClass.tabletExpanded) {
      return AdaptiveShellMode.standardRail;
    }
    return AdaptiveShellMode.phoneBottomNav;
  }

  if (!isLandscape || adaptiveClass != AdaptiveLayoutClass.tabletExpanded) {
    return AdaptiveShellMode.phoneBottomNav;
  }

  const shellDestinationCount = 4;
  const navTileEstimatedHeight = 64.0;
  const reservedMiniPlayerHeight = 170.0;
  const railMiniPlayerGap = 6.0;
  const railCutoffSlack = 4.0;
  const phoneRailOuterVerticalPadding = 44.0;

  final estimatedRailHeight =
      height - safePadding.vertical - phoneRailOuterVerticalPadding;
  final minPhoneRailHeight =
      (shellDestinationCount * navTileEstimatedHeight) +
      (reservedMiniPlayerHeight + railMiniPlayerGap) +
      railCutoffSlack;

  if (estimatedRailHeight < minPhoneRailHeight) {
    return AdaptiveShellMode.compactWideLandscape;
  }

  return AdaptiveShellMode.standardRail;
}
