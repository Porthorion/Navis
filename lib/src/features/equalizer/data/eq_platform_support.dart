import 'dart:io';

import 'package:just_audio_media_kit/just_audio_media_kit.dart';

/// Whether the audio backend on this platform can run the equalizer: Android's
/// player, or libmpv with its libavfilter audio filters on Linux, Windows and
/// macOS (each bundles Navis's own libmpv build, which includes them).
///
/// A build that turns out to lack the filters at runtime still falls back to
/// "unavailable": the equalizer's filter read-back fails and the player is
/// rebuilt without it.
bool navisEqualizerSupportedOn({
  required bool android,
  required bool linux,
  required bool windows,
  required bool macos,
  required bool mediaKitRegistered,
}) => android || ((linux || windows || macos) && mediaKitRegistered);

/// [navisEqualizerSupportedOn] for the running platform; [android] lets the
/// audio handler pass its own runtime flag.
bool navisEqualizerSupported({bool? android}) => navisEqualizerSupportedOn(
  android: android ?? Platform.isAndroid,
  linux: Platform.isLinux,
  windows: Platform.isWindows,
  macos: Platform.isMacOS,
  mediaKitRegistered: JustAudioMediaKit.isRegistered,
);
