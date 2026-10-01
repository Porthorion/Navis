import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Desktop width buckets used by desktop adaptive UI composition.
enum DesktopLayoutClass {
  compactDesktop,
  standardDesktop,
  ultraWideDesktop,
}

/// Smallest logical viewport that can present the full desktop workspace.
const Size kDesktopViewMinimumSize = Size(800, 600);

/// Smallest supported logical viewport for the desktop Mini Player.
const Size kDesktopMiniPlayerMinimumSize = Size(560, 360);

/// Initial logical size used when the user enters the desktop Mini Player.
const Size kDesktopMiniPlayerDefaultSize = Size(720, 405);

// Compatibility boundary for leaf widgets rendered without AppShell. The
// production desktop contract is defined by kDesktopViewMinimumSize instead.
const double _legacyUnscopedDesktopShellWidth = 1200;

bool supportsDesktopView(Size viewportSize) {
  return viewportSize.width >= kDesktopViewMinimumSize.width &&
      viewportSize.height >= kDesktopViewMinimumSize.height;
}

bool supportsMiniPlayer(Size viewportSize) {
  return viewportSize.width >= kDesktopMiniPlayerMinimumSize.width &&
      viewportSize.height >= kDesktopMiniPlayerMinimumSize.height;
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

  // Value equality lets [AdaptiveContextScope] notify dependents only when
  // the adaptive layout actually changes, not on every shell build.
  @override
  bool operator ==(Object other) =>
      other is AdaptiveContext &&
      other.desktopRuntime == desktopRuntime &&
      other.desktopWide == desktopWide &&
      other.desktopLayoutClass == desktopLayoutClass &&
      other.adaptiveLayoutClass == adaptiveLayoutClass &&
      other.adaptiveShellMode == adaptiveShellMode &&
      other.isPhoneFormFactor == isPhoneFormFactor &&
      other.useDesktopShell == useDesktopShell &&
      other.useStandardRailNavigation == useStandardRailNavigation &&
      other.useCompactWideLandscape == useCompactWideLandscape &&
      other.useRailNavigation == useRailNavigation;

  @override
  int get hashCode => Object.hash(
    desktopRuntime,
    desktopWide,
    desktopLayoutClass,
    adaptiveLayoutClass,
    adaptiveShellMode,
    isPhoneFormFactor,
    useDesktopShell,
    useStandardRailNavigation,
    useCompactWideLandscape,
    useRailNavigation,
  );
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

  @override
  bool operator ==(Object other) =>
      other is AdaptiveInputPolicy &&
      other.enableDeterministicTraversal == enableDeterministicTraversal &&
      other.enableEscapeOverlayPriority == enableEscapeOverlayPriority &&
      other.enableDesktopPointerAffordances ==
          enableDesktopPointerAffordances &&
      other.enableSecondaryClickMenus == enableSecondaryClickMenus &&
      other.enableDesktopCommandShortcuts == enableDesktopCommandShortcuts;

  @override
  int get hashCode => Object.hash(
    enableDeterministicTraversal,
    enableEscapeOverlayPriority,
    enableDesktopPointerAffordances,
    enableSecondaryClickMenus,
    enableDesktopCommandShortcuts,
  );
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

/// Exposes the currently visible desktop navigation treatment to a workspace.
///
/// Desktop pages use this to avoid duplicating orientation chrome when the
/// persistent rail already has labels, while still providing a compact header
/// whenever the rail is icon-only.
class DesktopNavigationPresentationScope extends InheritedWidget {
  const DesktopNavigationPresentationScope({
    required this.iconsOnly,
    required super.child,
    super.key,
  });

  final bool iconsOnly;

  static bool iconsOnlyOf(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<
              DesktopNavigationPresentationScope
            >()
            ?.iconsOnly ??
        false;
  }

  @override
  bool updateShouldNotify(covariant DesktopNavigationPresentationScope old) {
    return old.iconsOnly != iconsOnly;
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
  if (width >= 1008) {
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
    return AdaptiveShellMode.standardRail;
  }

  final width = viewportSize.width;
  final height = viewportSize.height;
  final shortestSide = width < height ? width : height;
  final isPhoneFormFactor = shortestSide < 600;
  final adaptiveClass = resolveAdaptiveLayoutClass(width);
  final isLandscape = width > height;

  if (!isPhoneFormFactor) {
    // Tablets are at least 600dp tall, which always fits the standard rail,
    // whatever their aspect ratio: a 16:9 tablet is still a tablet. Only a
    // short viewport (below) gets the compact icon rail.
    return adaptiveClass == AdaptiveLayoutClass.tabletExpanded
        ? AdaptiveShellMode.standardRail
        : AdaptiveShellMode.phoneBottomNav;
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

  // Phone/tablet composition remains size-first. Desktop runtimes deliberately
  // never inherit those shells: an undersized desktop window is handled by the
  // explicit Mini Player transition instead.
  final adaptiveShellMode = resolveAdaptiveShellMode(
    desktopRuntime: desktopRuntime,
    viewportSize: viewportSize,
    safePadding: safePadding,
  );
  final desktopLayoutClass = resolveDesktopLayoutClass(width);
  final isPhoneFormFactor = !desktopRuntime && shortestSide < 600;
  final desktopWide = desktopRuntime;
  final useDesktopShell = desktopRuntime;
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
/// Falls back to the legacy size-gated host resolution when a screen is
/// rendered outside [AdaptiveContextScope] (for example direct component
/// tests).
///
/// Production routes are hosted by [AppShell], which always installs the
/// authoritative runtime scope. Keeping the unscoped behavior compatible with
/// isolated leaf components prevents them from silently adopting the complete
/// desktop workspace without its host. Callers that intentionally exercise the
/// new desktop contract can pass [desktopRuntimeOverride] or install an
/// [AdaptiveContextScope].
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

  final desktopRuntime =
      desktopRuntimeOverride ??
      (isDesktopRuntime &&
          mediaQuery.size.width >= _legacyUnscopedDesktopShellWidth);
  return resolveAdaptiveContext(
    desktopRuntime: desktopRuntime,
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
