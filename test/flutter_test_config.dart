import 'dart:async';

import 'package:visibility_detector/visibility_detector.dart';

/// Runs for every test file. Visibility callbacks fire without the plugin's
/// 500 ms debounce timer, which would otherwise leave a pending timer behind
/// whenever a widget test builds a [VisibilityDetector] (for example a
/// scrolling album title).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  VisibilityDetectorController.instance.updateInterval = Duration.zero;
  await testMain();
}
