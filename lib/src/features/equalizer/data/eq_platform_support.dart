import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

/// Whether the audio backend on this platform can run the equalizer: Android's
/// player, iOS's AVFoundation player (an MTAudioProcessingTap in the vendored
/// just_audio Darwin code, independent of media_kit), or libmpv with its libavfilter audio filters on Linux, Windows and
/// macOS (each bundles Navis's own libmpv build, which includes them).
///
/// A build that turns out to lack the filters at runtime still falls back to
/// "unavailable": the equalizer's filter read-back fails and the player is
/// rebuilt without it.
bool navisEqualizerSupportedOn({
  required bool android,
  required bool ios,
  required bool linux,
  required bool windows,
  required bool macos,
  required bool mediaKitRegistered,
}) => android || ios || ((linux || windows || macos) && mediaKitRegistered);

/// [navisEqualizerSupportedOn] for the running platform; [android] lets the
/// audio handler pass its own runtime flag.
bool navisEqualizerSupported({bool? android}) => navisEqualizerSupportedOn(
  android: android ?? Platform.isAndroid,
  ios: Platform.isIOS,
  linux: Platform.isLinux,
  windows: Platform.isWindows,
  macos: Platform.isMacOS,
  mediaKitRegistered: JustAudioMediaKit.isRegistered,
);

/// Whether transcode-offset fast seeking is available: Linux and Windows
/// always, macOS only when libmpv drives playback (debug builds there use
/// AVFoundation and skip media_kit).
bool navisFastSeekSupportedOn({
  required TargetPlatform platform,
  required bool mediaKitRegistered,
}) =>
    platform == TargetPlatform.linux ||
    platform == TargetPlatform.windows ||
    (platform == TargetPlatform.macOS && mediaKitRegistered);

/// [navisFastSeekSupportedOn] for the running platform.
bool navisFastSeekSupported() =>
    !kIsWeb &&
    navisFastSeekSupportedOn(
      platform: defaultTargetPlatform,
      mediaKitRegistered: JustAudioMediaKit.isRegistered,
    );
