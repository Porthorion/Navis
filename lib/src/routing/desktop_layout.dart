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

/// Shared adaptive context resolved once and consumed by shell composition.
class AdaptiveContext {
  const AdaptiveContext({
    required this.desktopRuntime,
    required this.desktopWide,
    required this.desktopLayoutClass,
    required this.adaptiveLayoutClass,
    required this.adaptiveShellMode,
    required this.isPhoneFormFactor,
    required this.useDesktopShell,
    required this.useStandardRailNavigation,
    required this.useCompactWideLandscape,
    required this.useRailNavigation,
  });

  final bool desktopRuntime;
  final bool desktopWide;
  final DesktopLayoutClass desktopLayoutClass;
  final AdaptiveLayoutClass adaptiveLayoutClass;
  final AdaptiveShellMode adaptiveShellMode;
  final bool isPhoneFormFactor;
  final bool useDesktopShell;
  final bool useStandardRailNavigation;
  final bool useCompactWideLandscape;
  final bool useRailNavigation;
}

/// Shared adaptive input policy resolved from [AdaptiveContext].
///
/// This keeps focus traversal, keyboard dismissal precedence, and pointer
/// affordance behavior deterministic across desktop and tablet widths.
class AdaptiveInputPolicy {
  const AdaptiveInputPolicy({
    required this.enableDeterministicTraversal,
    required this.enableEscapeOverlayPriority,
    required this.enableDesktopPointerAffordances,
    required this.enableSecondaryClickMenus,
    required this.enableDesktopCommandShortcuts,
  });

  final bool enableDeterministicTraversal;
  final bool enableEscapeOverlayPriority;
  final bool enableDesktopPointerAffordances;
  final bool enableSecondaryClickMenus;
  final bool enableDesktopCommandShortcuts;
}

/// Provides a shared [AdaptiveContext] to descendants.
class AdaptiveContextScope extends InheritedWidget {
  const AdaptiveContextScope({
    required this.adaptiveContext,
    required super.child,
    super.key,
  });

  final AdaptiveContext adaptiveContext;

  static AdaptiveContext? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<AdaptiveContextScope>()
        ?.adaptiveContext;
  }

  @override
  bool updateShouldNotify(covariant AdaptiveContextScope oldWidget) {
    return oldWidget.adaptiveContext != adaptiveContext;
  }
}

/// Provides a shared [AdaptiveInputPolicy] to descendants.
class AdaptiveInputPolicyScope extends InheritedWidget {
  const AdaptiveInputPolicyScope({
    required this.policy,
    required super.child,
    super.key,
  });

  final AdaptiveInputPolicy policy;

  static AdaptiveInputPolicy? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<AdaptiveInputPolicyScope>()
        ?.policy;
  }

  @override
  bool updateShouldNotify(covariant AdaptiveInputPolicyScope oldWidget) {
    return oldWidget.policy != policy;
  }
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
      // Widescreen landscape displays (aspect ratio > 1.65, e.g. 16:9 car
      // screens like Android Automotive OS) suit the compact icon rail better
      // than the wide standard rail.  Regular tablets in landscape are at most
      // ~1.6:1, so this only triggers for car-like ultra-wide displays.
      final aspectRatio = height > 0 ? width / height : 1.0;
      if (isLandscape && aspectRatio > 1.65) {
        return AdaptiveShellMode.compactWideLandscape;
      }
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
  const minPhoneRailHeight =
      (shellDestinationCount * navTileEstimatedHeight) +
      (reservedMiniPlayerHeight + railMiniPlayerGap) +
      railCutoffSlack;

  if (estimatedRailHeight < minPhoneRailHeight) {
    return AdaptiveShellMode.compactWideLandscape;
  }

  return AdaptiveShellMode.standardRail;
}

AdaptiveContext resolveAdaptiveContext({
  required bool desktopRuntime,
  required Size viewportSize,
  required EdgeInsets safePadding,
}) {
  final width = viewportSize.width;
  final shortestSide = viewportSize.shortestSide;
  final adaptiveLayoutClass = resolveAdaptiveLayoutClass(width);

  // Keep existing shell breakpoint behavior for this ACP slice by resolving
  // the shared shell mode through the non-desktop branch for all runtimes.
  final adaptiveShellMode = resolveAdaptiveShellMode(
    desktopRuntime: false,
    viewportSize: viewportSize,
    safePadding: safePadding,
  );
  final desktopLayoutClass = resolveDesktopLayoutClass(width);
  final isPhoneFormFactor = shortestSide < 600;
  final desktopWide = desktopRuntime && width >= 1200;
  final useDesktopShell = desktopWide;
  final useCompactWideLandscape =
      !useDesktopShell &&
      adaptiveShellMode == AdaptiveShellMode.compactWideLandscape;
  final useStandardRailNavigation =
      !useDesktopShell && adaptiveShellMode == AdaptiveShellMode.standardRail;
  final useRailNavigation =
      useStandardRailNavigation || useCompactWideLandscape;

  return AdaptiveContext(
    desktopRuntime: desktopRuntime,
    desktopWide: desktopWide,
    desktopLayoutClass: desktopLayoutClass,
    adaptiveLayoutClass: adaptiveLayoutClass,
    adaptiveShellMode: adaptiveShellMode,
    isPhoneFormFactor: isPhoneFormFactor,
    useDesktopShell: useDesktopShell,
    useStandardRailNavigation: useStandardRailNavigation,
    useCompactWideLandscape: useCompactWideLandscape,
    useRailNavigation: useRailNavigation,
  );
}

AdaptiveInputPolicy resolveAdaptiveInputPolicy({
  required AdaptiveContext adaptiveContext,
}) {
  final enableDeterministicTraversal =
      adaptiveContext.desktopRuntime ||
      adaptiveContext.adaptiveLayoutClass != AdaptiveLayoutClass.phoneCompact;
  return AdaptiveInputPolicy(
    enableDeterministicTraversal: enableDeterministicTraversal,
    enableEscapeOverlayPriority: enableDeterministicTraversal,
    enableDesktopPointerAffordances: adaptiveContext.desktopRuntime,
    enableSecondaryClickMenus: adaptiveContext.desktopRuntime,
    enableDesktopCommandShortcuts: adaptiveContext.desktopRuntime,
  );
}

/// Returns the current [AdaptiveContext] from scope when available.
///
/// Falls back to resolving context from [MediaQuery] when a screen is rendered
/// outside [AdaptiveContextScope] (for example direct widget tests).
AdaptiveContext resolveAdaptiveContextFor(
  BuildContext context, {
  bool? desktopRuntimeOverride,
}) {
  final scopedContext = AdaptiveContextScope.maybeOf(context);
  if (scopedContext != null) {
    return scopedContext;
  }

  final mediaQuery = MediaQuery.maybeOf(context);
  if (mediaQuery == null) {
    throw FlutterError(
      'resolveAdaptiveContextFor requires MediaQuery when '
      'AdaptiveContextScope is unavailable.',
    );
  }

  return resolveAdaptiveContext(
    desktopRuntime: desktopRuntimeOverride ?? isDesktopRuntime,
    viewportSize: mediaQuery.size,
    safePadding: mediaQuery.padding,
  );
}

/// Returns the current [AdaptiveInputPolicy] from scope when available.
///
/// Falls back to policy resolution from [AdaptiveContext] when the scope is
/// absent (for example in direct widget tests).
AdaptiveInputPolicy resolveAdaptiveInputPolicyFor(
  BuildContext context, {
  bool? desktopRuntimeOverride,
}) {
  final scoped = AdaptiveInputPolicyScope.maybeOf(context);
  if (scoped != null) {
    return scoped;
  }

  final adaptiveContext = resolveAdaptiveContextFor(
    context,
    desktopRuntimeOverride: desktopRuntimeOverride,
  );
  return resolveAdaptiveInputPolicy(adaptiveContext: adaptiveContext);
}
