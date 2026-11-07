import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/navis_haptics.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  const channel = MethodChannel(navisHapticsChannelName);
  late List<String> kinds;
  late List<Object?> fallbacks;
  var channelCalls = 0;

  void mockFlutterHaptics() {
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        fallbacks.add(call.arguments);
      }
      return null;
    });
  }

  setUp(() {
    kinds = <String>[];
    fallbacks = <Object?>[];
    channelCalls = 0;
    NavisHaptics.resetForTest();
    mockFlutterHaptics();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  void nativeAnswers(bool? answer) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      kinds.add(call.arguments as String);
      return answer;
    });
  }

  final vocabulary = <String, ({void Function() fire, String fallback})>{
    'toggleOn': (
      fire: () => NavisHaptics.toggle(true),
      fallback: 'HapticFeedbackType.lightImpact',
    ),
    'toggleOff': (
      fire: () => NavisHaptics.toggle(false),
      fallback: 'HapticFeedbackType.selectionClick',
    ),
    'press': (
      fire: NavisHaptics.press,
      fallback: 'HapticFeedbackType.lightImpact',
    ),
    'release': (
      fire: NavisHaptics.release,
      fallback: 'HapticFeedbackType.selectionClick',
    ),
    'firm': (
      fire: NavisHaptics.firm,
      fallback: 'HapticFeedbackType.mediumImpact',
    ),
    'tick': (
      fire: NavisHaptics.tick,
      fallback: 'HapticFeedbackType.selectionClick',
    ),
    'frequentTick': (
      fire: NavisHaptics.frequentTick,
      fallback: 'HapticFeedbackType.selectionClick',
    ),
    'contextClick': (
      fire: NavisHaptics.contextClick,
      fallback: 'HapticFeedbackType.selectionClick',
    ),
    'confirm': (
      fire: NavisHaptics.confirm,
      fallback: 'HapticFeedbackType.lightImpact',
    ),
    'reject': (
      fire: NavisHaptics.reject,
      fallback: 'HapticFeedbackType.heavyImpact',
    ),
    'thresholdOn': (
      fire: NavisHaptics.thresholdOn,
      fallback: 'HapticFeedbackType.mediumImpact',
    ),
    'thresholdOff': (
      fire: NavisHaptics.thresholdOff,
      fallback: 'HapticFeedbackType.selectionClick',
    ),
    'dragStart': (
      fire: NavisHaptics.dragStart,
      fallback: 'HapticFeedbackType.mediumImpact',
    ),
    'dragEnd': (
      fire: NavisHaptics.dragEnd,
      fallback: 'HapticFeedbackType.lightImpact',
    ),
    'longPress': (
      fire: NavisHaptics.longPress,
      fallback: 'HapticFeedbackType.heavyImpact',
    ),
  };

  test('every vocabulary entry asks Android for its own kind', () async {
    nativeAnswers(true);
    for (final entry in vocabulary.entries) {
      kinds.clear();
      entry.value.fire();
      await settle();
      expect(kinds, [entry.key], reason: entry.key);
    }
    expect(fallbacks, isEmpty);
  });

  test('an unsupported kind falls back to its Flutter primitive', () async {
    nativeAnswers(false);
    for (final entry in vocabulary.entries) {
      fallbacks.clear();
      entry.value.fire();
      await settle();
      expect(fallbacks, [entry.value.fallback], reason: entry.key);
    }
  });

  test('a missing channel costs one failed call, then goes straight to '
      'the fallback', () async {
    messenger.setMockMessageHandler(channel.name, (message) async {
      channelCalls++;
      return null;
    });
    NavisHaptics.tick();
    await settle();
    NavisHaptics.tick();
    NavisHaptics.confirm();
    await settle();
    expect(channelCalls, 1);
    expect(fallbacks, [
      'HapticFeedbackType.selectionClick',
      'HapticFeedbackType.selectionClick',
      'HapticFeedbackType.lightImpact',
    ]);
    messenger.setMockMessageHandler(channel.name, null);
  });

  test('a throwing channel never throws and falls back', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'boom');
    });
    NavisHaptics.reject();
    await settle();
    expect(fallbacks, ['HapticFeedbackType.heavyImpact']);
  });

  test(
    'iOS uses the Flutter primitives and never the Android channel',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      nativeAnswers(true);
      NavisHaptics.toggle(true);
      await settle();
      expect(kinds, isEmpty);
      expect(fallbacks, ['HapticFeedbackType.lightImpact']);
    },
  );

  for (final platform in [
    TargetPlatform.linux,
    TargetPlatform.windows,
    TargetPlatform.macOS,
  ]) {
    test('${platform.name} desktop is silent', () async {
      debugDefaultTargetPlatformOverride = platform;
      nativeAnswers(true);
      for (final entry in vocabulary.values) {
        entry.fire();
      }
      await settle();
      expect(kinds, isEmpty);
      expect(fallbacks, isEmpty);
    });
  }
}
