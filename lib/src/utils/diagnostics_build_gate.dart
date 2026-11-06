import 'dart:io';

import 'package:flutter/foundation.dart';

/// Whether this build may run the authenticated diagnostics API and the
/// diagnostics-only hooks: profile builds, plus debug builds on the iOS
/// simulator (which cannot run profile or release builds). Release builds and
/// debug builds anywhere else, physical iOS devices included, stay off.
bool get diagnosticsBuildEnabled =>
    kProfileMode || (kDebugMode && _debugIosSimulator);

// Lazy, and only read in debug, so profile and release never touch Platform.
final bool _debugIosSimulator = diagnosticsBuildAllowed(
  profileMode: false,
  debugMode: true,
  isIOS: !kIsWeb && Platform.isIOS,
  executablePath: kIsWeb ? '' : Platform.resolvedExecutable,
);

/// The gate's decision for explicit inputs. The simulator runs the app from
/// inside its CoreSimulator device directory; a device runs it from
/// /private/var/containers. (`Platform.environment` is empty on iOS, so the
/// simulator's `SIMULATOR_*` variables are not visible to Dart.)
@visibleForTesting
bool diagnosticsBuildAllowed({
  required bool profileMode,
  required bool debugMode,
  required bool isIOS,
  required String executablePath,
}) =>
    profileMode ||
    (debugMode && isIOS && executablePath.contains('/CoreSimulator/Devices/'));
