import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/navis_haptics.dart';

/// Records the haptic kinds the app asks Android for. The native channel
/// reports success, so no Flutter fallback fires.
class HapticsSpy {
  HapticsSpy._();

  final List<String> kinds = <String>[];

  /// Installs the spy for one test, and removes it afterwards.
  static HapticsSpy install(WidgetTester tester) {
    final spy = HapticsSpy._();
    NavisHaptics.resetForTest();
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel(navisHapticsChannelName),
      (call) async {
        spy.kinds.add(call.arguments as String);
        return true;
      },
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(
        const MethodChannel(navisHapticsChannelName),
        null,
      );
      NavisHaptics.resetForTest();
      debugDefaultTargetPlatformOverride = null;
    });
    return spy;
  }

  /// Lets the unawaited channel calls complete, then returns and clears the
  /// kinds recorded so far.
  Future<List<String>> take(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    final taken = List<String>.of(kinds);
    kinds.clear();
    return taken;
  }
}
