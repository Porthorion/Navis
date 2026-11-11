import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/navis_haptics.dart';
import 'package:navis/src/features/settings/domain/haptics_prefs.dart';

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

  const c = HapticCategory.playerGestures;
  final vocabulary = <String, ({void Function() fire, String fallback})>{
    'toggleOn': (
      fire: () => NavisHaptics.toggle(c, true),
      fallback: 'HapticFeedbackType.lightImpact',
    ),
    'toggleOff': (
      fire: () => NavisHaptics.toggle(c, false),
      fallback: 'HapticFeedbackType.selectionClick',
    ),
    'press': (
      fire: () => NavisHaptics.press(c),
      fallback: 'HapticFeedbackType.lightImpact',
    ),
    'release': (
      fire: () => NavisHaptics.release(c),
      fallback: 'HapticFeedbackType.selectionClick',
    ),
    'firm': (
      fire: () => NavisHaptics.firm(c),
      fallback: 'HapticFeedbackType.mediumImpact',
    ),
    'tick': (
      fire: () => NavisHaptics.tick(c),
      fallback: 'HapticFeedbackType.selectionClick',
    ),
    'frequentTick': (
      fire: () => NavisHaptics.frequentTick(c),
      fallback: 'HapticFeedbackType.selectionClick',
    ),
    'contextClick': (
      fire: () => NavisHaptics.contextClick(c),
      fallback: 'HapticFeedbackType.selectionClick',
    ),
    'confirm': (
      fire: () => NavisHaptics.confirm(c),
      fallback: 'HapticFeedbackType.lightImpact',
    ),
    'reject': (
      fire: () => NavisHaptics.reject(c),
      fallback: 'HapticFeedbackType.heavyImpact',
    ),
    'thresholdOn': (
      fire: () => NavisHaptics.thresholdOn(c),
      fallback: 'HapticFeedbackType.mediumImpact',
    ),
    'thresholdOff': (
      fire: () => NavisHaptics.thresholdOff(c),
      fallback: 'HapticFeedbackType.selectionClick',
    ),
    'dragStart': (
      fire: () => NavisHaptics.dragStart(c),
      fallback: 'HapticFeedbackType.mediumImpact',
    ),
    'dragEnd': (
      fire: () => NavisHaptics.dragEnd(c),
      fallback: 'HapticFeedbackType.lightImpact',
    ),
    'longPress': (
      fire: () => NavisHaptics.longPress(c),
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
    NavisHaptics.tick(c);
    await settle();
    NavisHaptics.tick(c);
    NavisHaptics.confirm(c);
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
    NavisHaptics.reject(c);
    await settle();
    expect(fallbacks, ['HapticFeedbackType.heavyImpact']);
  });

  test('iOS asks the native channel for every kind, like Android', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    nativeAnswers(true);
    for (final entry in vocabulary.entries) {
      kinds.clear();
      entry.value.fire();
      await settle();
      expect(kinds, [entry.key], reason: entry.key);
    }
    expect(fallbacks, isEmpty);
  });

  test('iOS falls back to the Flutter primitive without the channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    messenger.setMockMessageHandler(channel.name, (message) async => null);
    NavisHaptics.toggle(c, true);
    await settle();
    expect(fallbacks, ['HapticFeedbackType.lightImpact']);
    messenger.setMockMessageHandler(channel.name, null);
  });

  test('iOS honours the prefs gate before the channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    nativeAnswers(true);
    NavisHaptics.prefs = const HapticsPrefs(enabled: false);
    NavisHaptics.confirm(c);
    await settle();
    expect(kinds, isEmpty);
    expect(fallbacks, isEmpty);
  });

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

  group('prefs gate', () {
    test('a category off plays nothing while the others still play', () async {
      nativeAnswers(true);
      NavisHaptics.prefs = HapticsPrefs.fromColumns(
        true,
        HapticCategory.listsAndMenus.bit,
      );
      NavisHaptics.longPress(HapticCategory.listsAndMenus);
      NavisHaptics.tick(HapticCategory.likesAndAlerts);
      await settle();
      expect(kinds, ['tick']);
      expect(fallbacks, isEmpty);
    });

    test('master off plays nothing, but masterToggle still clicks', () async {
      nativeAnswers(true);
      NavisHaptics.prefs = const HapticsPrefs(enabled: false);
      for (final category in HapticCategory.values) {
        NavisHaptics.firm(category);
      }
      await settle();
      expect(kinds, isEmpty);
      NavisHaptics.masterToggle(true);
      NavisHaptics.masterToggle(false);
      await settle();
      expect(kinds, ['toggleOn', 'toggleOff']);
    });

    test('allows agrees with the prefs', () {
      NavisHaptics.prefs = HapticsPrefs.fromColumns(
        true,
        HapticCategory.slidersAndRulers.bit,
      );
      expect(NavisHaptics.allows(HapticCategory.slidersAndRulers), isFalse);
      expect(NavisHaptics.allows(HapticCategory.playerGestures), isTrue);
      NavisHaptics.prefs = const HapticsPrefs(enabled: false);
      expect(NavisHaptics.allows(HapticCategory.playerGestures), isFalse);
    });

    test('resetForTest restores everything on', () {
      NavisHaptics.prefs = const HapticsPrefs(enabled: false, disabledBits: 63);
      NavisHaptics.resetForTest();
      expect(NavisHaptics.prefs, const HapticsPrefs());
    });

    test('a desktop platform stays silent even when allowed', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      nativeAnswers(true);
      NavisHaptics.masterToggle(true);
      await settle();
      expect(kinds, isEmpty);
    });
  });
}
