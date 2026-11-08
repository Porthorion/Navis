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

bool configureReplayGainFilter(
        Player player, String Function(String path) filtersFor) =>
    false;

bool nativeSetPropertySync(Player player, String name, String value) => false;

bool nativeCommandSync(Player player, String line) => false;

String? nativeAudioFilters(Player player) => null;

Future<Duration?> nativePosition(Player player) async => null;
