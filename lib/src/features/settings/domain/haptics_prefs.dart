import 'package:flutter/foundation.dart';

/// The places a haptic is felt, one switch each in Settings → Haptics.
///
/// The bit of each category is stored (`hapticsDisabled`), so every bit is
/// pinned explicitly: never derive it from the index, or reordering the enum
/// would remap saved choices.
enum HapticCategory {
  /// Dragging the player open or closed, and swiping to skip.
  playerGestures(1),

  /// Play, pause, skip, repeat and shuffle.
  playbackButtons(2),

  /// Seek bar, speed, pitch and colour rulers, and the equalizer.
  slidersAndRulers(4),

  /// Switches, and the − and + buttons.
  switchesAndSteppers(8),

  /// Long-press menus, reordering, swiping a queue row away, pull to refresh.
  listsAndMenus(16),

  /// Likes, ratings, downloads, copying and actions that aren't available.
  likesAndAlerts(32);

  const HapticCategory(this.bit);

  final int bit;
}

/// The haptics choices: a master switch and the categories switched off.
///
/// The mask stores what is **off**, so 0 (the column default) means every
/// category is on, and a category added later starts on without a migration.
/// The master is separate so turning it off keeps the category choices.
@immutable
class HapticsPrefs {
  const new({this.enabled = true, this.disabledBits = 0});

  /// Decodes the stored columns. Unknown bits are dropped instead of
  /// throwing, because a read must never crash.
  factory fromColumns(bool enabled, int bits) =>
      HapticsPrefs(enabled: enabled, disabledBits: bits & _knownBits);

  static final int _knownBits = HapticCategory.values.fold(
    0,
    (mask, category) => mask | category.bit,
  );

  final bool enabled;
  final int disabledBits;

  /// The stored choice for [category], shown on its tile even while the
  /// master is off.
  bool isOn(HapticCategory category) => disabledBits & category.bit == 0;

  /// Whether a haptic of [category] should play.
  bool allows(HapticCategory category) => enabled && isOn(category);

  @override
  bool operator ==(Object other) =>
      other is HapticsPrefs &&
      enabled == other.enabled &&
      disabledBits == other.disabledBits;

  @override
  int get hashCode => Object.hash(enabled, disabledBits);
}
