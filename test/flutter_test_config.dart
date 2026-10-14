import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

const _secureStorageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

/// Runs for every test file. Visibility callbacks fire without the plugin's
/// 500 ms debounce timer, which would otherwise leave a pending timer behind
/// whenever a widget test builds a [VisibilityDetector] (for example a
/// scrolling album title).
///
/// In files whose widget tests initialised the test binding, secure storage
/// answers as an empty store unless a test installs its own handler. An
/// unanswered channel would leave credential reads waiting on their storage
/// deadline, a pending timer in every widget test that mounts Home or
/// onboarding. Plain test files keep their own binding choice (and real HTTP
/// for loopback servers).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  VisibilityDetectorController.instance.updateInterval = Duration.zero;
  await testMain();
  if (BindingBase.debugBindingType() == null) return;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureStorageChannel, (call) async {
        return switch (call.method) {
          'readAll' => <String, String>{},
          'containsKey' => false,
          _ => null,
        };
      });
}
