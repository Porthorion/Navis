import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Runs [body], a `ref.listen` callback that writes provider state, outside
/// any widget build.
///
/// Riverpod flushes stale providers, and with them their listeners, on the
/// first read. At startup that read is `NavisApp.build`, so the listener
/// would run synchronously inside the build and Riverpod's debug check throws
/// "Tried to modify a provider while the widget tree was building", skipping
/// the rest of the callback. The check is debug-only, so only debug builds
/// defer, and only while a build is in progress; release and every other call
/// run [body] synchronously. The deferred run is skipped if [ref] was
/// disposed meanwhile, and runs in the zone that called this helper.
///
/// Gate on `buildOwner.debugBuilding`, not `schedulerPhase`: the first build
/// runs from `scheduleAttachRootWidget` outside a frame, in the idle phase.
void runOutsideWidgetBuild(Ref ref, void Function() body) {
  if (kDebugMode && _debugBuilding) {
    scheduleMicrotask(() {
      if (ref.mounted) body();
    });
    return;
  }
  body();
}

bool get _debugBuilding {
  try {
    return WidgetsBinding.instance.buildOwner?.debugBuilding ?? false;
    // The only way to ask whether a binding exists is to read it.
    // ignore: avoid_catching_errors
  } on FlutterError {
    return false; // No Flutter binding (plain Dart tests): nothing builds.
  }
}
