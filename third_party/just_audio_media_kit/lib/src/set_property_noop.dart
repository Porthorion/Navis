library just_audio_media_kit;

import 'package:media_kit/media_kit.dart';

Future<void> setProperty(Player player, String key, dynamic value) {
  // noop
  return Future.value();
}

Future<void> verifyPlaybackAdjustments(Player player) async {}

Future<void> verifyOwnedAudioChain(
        Player player, String expected, double pitch) async =>
    throw UnsupportedError('Native audio required');

Future<void> configureNativeSeeking(
    Player player, void Function(bool) onSeeking) async {}

bool configureStartPosition(
        Player player, Duration? Function(int index) startFor) =>
    false;

bool configureReplayGainBoost(
        Player player, double Function(int index, String path) gainFor) =>
    false;

bool writeFileLocalVolumeGain(Player player, double db) => false;

double? nativeVolumeGain(Player player) => null;

int? nativePlaylistPosition(Player player) => null;

Future<Duration?> nativePosition(Player player) async => null;
