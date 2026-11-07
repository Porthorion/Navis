import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native channel that plays an Android haptic constant by kind name.
const String navisHapticsChannelName = 'com.navis.app/haptics';

/// The haptic vocabulary: one named feel per kind of action, so every control
/// of a kind feels alike and different kinds feel different.
///
/// Android plays the richest system constant the device supports through
/// `View.performHapticFeedback` (`MainActivity.kt`), which honours the user's
/// touch-feedback setting. When the device lacks the constant, or the native
/// channel is missing, the Flutter primitive named beside each entry plays
/// instead (iOS always uses it). Desktop is silent, so shared widgets can call
/// this without checking the platform. Nothing here ever throws.
///
/// New code calls these methods, never `HapticFeedback` directly.
/// `AdjustmentRuler` keeps its own tuned primitives and is the reference feel
/// for [tick] (a ruler line) and [firm] (the neutral line).
abstract final class NavisHaptics {
  static const MethodChannel _channel = MethodChannel(navisHapticsChannelName);
  static bool _channelMissing = false;

  /// A switch turned on (lighter, brighter) or off (softer).
  static void toggle(bool on) =>
      _play(on ? _Haptic.toggleOn : _Haptic.toggleOff);

  /// A transport button pressed to start something (Play).
  static void press() => _play(_Haptic.press);

  /// A transport button pressed to stop something (Pause); softer than [press].
  static void release() => _play(_Haptic.release);

  /// A firm tap: a track skip, or the neutral line of a ruler or graph.
  static void firm() => _play(_Haptic.firm);

  /// One light step: a ruler line, a cycle step, a seek landing.
  static void tick() => _play(_Haptic.tick);

  /// A fine progress tick while pulling or dragging.
  static void frequentTick() => _play(_Haptic.frequentTick);

  /// Picking one thing out of several (an equalizer band).
  static void contextClick() => _play(_Haptic.contextClick);

  /// An action went through: a like, a download started, a refresh finished.
  static void confirm() => _play(_Haptic.confirm);

  /// An action was refused: a tap on a disabled heart.
  static void reject() => _play(_Haptic.reject);

  /// A pull or swipe crossed the point where letting go triggers its action.
  static void thresholdOn() => _play(_Haptic.thresholdOn);

  /// The pull or swipe went back before the trigger point.
  static void thresholdOff() => _play(_Haptic.thresholdOff);

  /// A row was picked up to be reordered.
  static void dragStart() => _play(_Haptic.dragStart);

  /// A drag or sheet gesture ended and settled.
  static void dragEnd() => _play(_Haptic.dragEnd);

  /// A long press opened a menu.
  static void longPress() => _play(_Haptic.longPress);

  /// Forgets that the native channel was missing, for tests.
  @visibleForTesting
  static void resetForTest() => _channelMissing = false;

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static void _play(_Haptic haptic) {
    if (!_android && (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS)) {
      return;
    }
    unawaited(_perform(haptic));
  }

  static Future<void> _perform(_Haptic haptic) async {
    try {
      if (_android && !_channelMissing) {
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

/// Kind names are the strings `MainActivity.kt` maps to Android constants.
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
