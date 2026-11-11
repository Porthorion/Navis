import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:navis/src/features/settings/domain/haptics_prefs.dart';

/// Native channel that plays a haptic by kind name: an Android constant or an
/// iOS feedback generator.
const String navisHapticsChannelName = 'com.navis.app/haptics';

/// The haptic vocabulary: one named feel per kind of action, so every control
/// of a kind feels alike and different kinds feel different.
///
/// Android plays the richest system constant the device supports through
/// `View.performHapticFeedback` (`MainActivity.kt`), which honours the user's
/// touch-feedback setting. When the device lacks the constant, or the native
/// channel is missing, the Flutter primitive named beside each entry plays
/// instead. iOS plays each kind's own feedback generator through the same
/// channel (`HapticKinds.swift`). Desktop is silent, so shared widgets can call
/// this without checking the platform. Nothing here ever throws.
///
/// Every method takes the [HapticCategory] of its call site, and plays only
/// when Settings → Haptics allows that category ([prefs], kept current by an
/// app-root listener).
///
/// New code calls these methods, never `HapticFeedback` directly.
/// `AdjustmentRuler` keeps its own tuned primitives, gated by [allows], and is
/// the reference feel for [tick] (a ruler line) and [firm] (the neutral line).
abstract final class NavisHaptics {
  static const MethodChannel _channel = MethodChannel(navisHapticsChannelName);
  static bool _channelMissing = false;
  static HapticsPrefs _prefs = const HapticsPrefs();

  /// The Haptics settings in force. Pushed from the settings stream at the app
  /// root; a plain static because haptics fire from callbacks without a `ref`.
  static HapticsPrefs get prefs => _prefs;
  static set prefs(HapticsPrefs value) => _prefs = value;

  /// Whether a haptic of [category] would play, for the raw-primitive callers.
  static bool allows(HapticCategory category) => _prefs.allows(category);

  /// The Haptics master tile's own click, played whatever the preferences, so
  /// the user feels that switch work in both directions.
  static void masterToggle(bool on) =>
      _playAlways(on ? _Haptic.toggleOn : _Haptic.toggleOff);

  /// A switch turned on (lighter, brighter) or off (softer).
  static void toggle(HapticCategory category, bool on) =>
      _play(category, on ? _Haptic.toggleOn : _Haptic.toggleOff);

  /// A transport button pressed to start something (Play).
  static void press(HapticCategory category) => _play(category, _Haptic.press);

  /// A transport button pressed to stop something (Pause); softer than [press].
  static void release(HapticCategory category) =>
      _play(category, _Haptic.release);

  /// A firm tap: a track skip, or the neutral line of a ruler or graph.
  static void firm(HapticCategory category) => _play(category, _Haptic.firm);

  /// One light step: a ruler line, a cycle step, a seek landing.
  static void tick(HapticCategory category) => _play(category, _Haptic.tick);

  /// A fine progress tick while pulling or dragging.
  static void frequentTick(HapticCategory category) =>
      _play(category, _Haptic.frequentTick);

  /// Picking one thing out of several (an equalizer band).
  static void contextClick(HapticCategory category) =>
      _play(category, _Haptic.contextClick);

  /// An action went through: a like, a download started, a refresh finished.
  static void confirm(HapticCategory category) =>
      _play(category, _Haptic.confirm);

  /// An action was refused: a tap on a disabled heart.
  static void reject(HapticCategory category) =>
      _play(category, _Haptic.reject);

  /// A pull or swipe crossed the point where letting go triggers its action.
  static void thresholdOn(HapticCategory category) =>
      _play(category, _Haptic.thresholdOn);

  /// The pull or swipe went back before the trigger point.
  static void thresholdOff(HapticCategory category) =>
      _play(category, _Haptic.thresholdOff);

  /// A row was picked up to be reordered.
  static void dragStart(HapticCategory category) =>
      _play(category, _Haptic.dragStart);

  /// A drag or sheet gesture ended and settled.
  static void dragEnd(HapticCategory category) =>
      _play(category, _Haptic.dragEnd);

  /// A long press opened a menu.
  static void longPress(HapticCategory category) =>
      _play(category, _Haptic.longPress);

  /// Forgets that the native channel was missing and restores every haptic on,
  /// for tests.
  @visibleForTesting
  static void resetForTest() {
    _channelMissing = false;
    _prefs = const HapticsPrefs();
  }

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get _ios =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static void _play(HapticCategory category, _Haptic haptic) {
    if (!_prefs.allows(category)) return;
    _playAlways(haptic);
  }

  static void _playAlways(_Haptic haptic) {
    if (!_android && !_ios) return;
    unawaited(_perform(haptic));
  }

  static Future<void> _perform(_Haptic haptic) async {
    try {
      if (!_channelMissing) {
        try {
          if (await _channel.invokeMethod<bool>('perform', haptic.name) ??
              false) {
            return;
          }
        } on MissingPluginException {
          // Cached so a missing channel costs one failed call, not one per tap.
          _channelMissing = true;
        } on PlatformException {
          // The native call failed; the Flutter primitive still plays.
        }
      }
      await haptic.fallback();
    } on Object {
      // Haptics are decoration: never let one break an action.
    }
  }
}

/// Kind names are the strings `HapticKinds.kt` and `HapticKinds.swift` map to
/// the Android constants and iOS feedback.
enum _Haptic {
  toggleOn(HapticFeedback.lightImpact),
  toggleOff(HapticFeedback.selectionClick),
  press(HapticFeedback.lightImpact),
  release(HapticFeedback.selectionClick),
  firm(HapticFeedback.mediumImpact),
  tick(HapticFeedback.selectionClick),
  frequentTick(HapticFeedback.selectionClick),
  contextClick(HapticFeedback.selectionClick),
  confirm(HapticFeedback.lightImpact),
  reject(HapticFeedback.heavyImpact),
  thresholdOn(HapticFeedback.mediumImpact),
  thresholdOff(HapticFeedback.selectionClick),
  dragStart(HapticFeedback.mediumImpact),
  dragEnd(HapticFeedback.lightImpact),
  longPress(HapticFeedback.heavyImpact);

  const _Haptic(this.fallback);

  final Future<void> Function() fallback;
}

/// Gives a long-press callback its haptic. A null stays null, so a disabled
/// control stays silent.
///
/// Pair it with `enableFeedback: false` on the `InkWell`, `InkResponse` or
/// `ListTile`, or the framework plays its own vibration as well and the master
/// switch could not silence it.
VoidCallback? withLongPressHaptic(VoidCallback? onLongPress) {
  if (onLongPress == null) return null;
  return () {
    NavisHaptics.longPress(HapticCategory.listsAndMenus);
    onLongPress();
  };
}
