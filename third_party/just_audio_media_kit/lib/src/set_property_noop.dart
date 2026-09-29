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
