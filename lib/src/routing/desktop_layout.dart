import 'dart:io';

import 'package:flutter/foundation.dart';

/// Desktop width buckets used by v1 desktop-only UI composition.
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

/// Build-time rollout default for desktop UI v1.
///
/// Accepted values:
/// - `1` or `true`: enabled by default
/// - any other value: disabled by default
const String _desktopUiV1DefaultRaw = String.fromEnvironment(
  'NAVIS_DESKTOP_UI_V1_DEFAULT',
  defaultValue: '0',
);

const bool kDesktopUiV1BuildDefault =
    _desktopUiV1DefaultRaw == '1' || _desktopUiV1DefaultRaw == 'true';

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
