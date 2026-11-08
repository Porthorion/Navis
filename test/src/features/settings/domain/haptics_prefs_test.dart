import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/domain/haptics_prefs.dart';

void main() {
  test('each category bit is pinned, because it is stored', () {
    expect(
      {for (final c in HapticCategory.values) c.name: c.bit},
      {
        'playerGestures': 1,
        'playbackButtons': 2,
        'slidersAndRulers': 4,
        'switchesAndSteppers': 8,
        'listsAndMenus': 16,
        'likesAndAlerts': 32,
        'notifications': 64,
      },
    );
  });

  test('the defaults are everything on', () {
    const prefs = HapticsPrefs();
    expect(prefs.enabled, isTrue);
    expect(prefs.disabledBits, 0);
    for (final c in HapticCategory.values) {
      expect(prefs.isOn(c), isTrue);
      expect(prefs.allows(c), isTrue);
    }
  });

  test('fromColumns masks unknown bits instead of throwing', () {
    final prefs = HapticsPrefs.fromColumns(true, 128 | 256 | 2);
    expect(prefs.disabledBits, 2);
    expect(prefs.isOn(HapticCategory.playbackButtons), isFalse);
    expect(prefs.isOn(HapticCategory.playerGestures), isTrue);
    expect(HapticsPrefs.fromColumns(true, -1).disabledBits, 127);
  });

  test('a category off is silent, the others still allow', () {
    final prefs = HapticsPrefs.fromColumns(
      true,
      HapticCategory.listsAndMenus.bit,
    );
    expect(prefs.allows(HapticCategory.listsAndMenus), isFalse);
    expect(prefs.allows(HapticCategory.likesAndAlerts), isTrue);
  });

  test('the notifications category round-trips through the mask', () {
    final off = HapticsPrefs.fromColumns(
      true,
      HapticCategory.notifications.bit,
    );
    expect(off.disabledBits, 64);
    expect(off.allows(HapticCategory.notifications), isFalse);
    expect(off.allows(HapticCategory.likesAndAlerts), isTrue);
    expect(
      HapticsPrefs.fromColumns(true, 0).isOn(HapticCategory.notifications),
      isTrue,
    );
  });

  test('master off allows nothing but keeps the stored choices', () {
    final prefs = HapticsPrefs.fromColumns(
      false,
      HapticCategory.slidersAndRulers.bit,
    );
    for (final c in HapticCategory.values) {
      expect(prefs.allows(c), isFalse);
    }
    expect(prefs.isOn(HapticCategory.slidersAndRulers), isFalse);
    expect(prefs.isOn(HapticCategory.playerGestures), isTrue);
  });

  test('equality compares the master and the mask', () {
    expect(
      HapticsPrefs.fromColumns(true, 4),
      HapticsPrefs.fromColumns(true, 4),
    );
    expect(
      HapticsPrefs.fromColumns(true, 4).hashCode,
      HapticsPrefs.fromColumns(true, 4).hashCode,
    );
    expect(
      HapticsPrefs.fromColumns(true, 4),
      isNot(HapticsPrefs.fromColumns(false, 4)),
    );
    expect(
      HapticsPrefs.fromColumns(true, 4),
      isNot(HapticsPrefs.fromColumns(true, 8)),
    );
  });
}
