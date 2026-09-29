library just_audio_media_kit;

import 'package:media_kit/media_kit.dart';

Future<void> setProperty(Player player, String key, dynamic value) async {
  if (player.platform is! NativePlayer) return;
  await (player.platform as NativePlayer).setProperty(key, value);
}

/// Reads the actual mpv properties because media_kit logs setter errors without
/// throwing them. This prevents a failed filter change being shown as applied.
Future<void> verifyPlaybackAdjustments(Player player) async {
  final native = player.platform;
  if (native is! NativePlayer) return;
  final actualPitch = double.tryParse(await native.getProperty('speed'));
  final filters = await native.getProperty('af');
  final expectedRatio = player.state.rate / player.state.pitch;
  final scale =
      RegExp(r'scale[=:](?:%[0-9]+%)?"?([0-9.eE+\-]+)').firstMatch(filters);
  final actualScale = scale == null ? null : double.tryParse(scale.group(1)!);
  if (actualPitch == null ||
      (actualPitch - player.state.pitch).abs() > 0.000001 ||
      actualScale == null ||
      (actualScale - expectedRatio).abs() >
          0.000001 * expectedRatio.abs().clamp(1, double.infinity)) {
    throw StateError(
        'The audio backend did not apply the requested speed/pitch pair');
  }
}

Future<void> verifyOwnedAudioChain(
    Player player, String expected, double pitch) async {
  final native = player.platform;
  if (native is! NativePlayer) throw UnsupportedError('Native audio required');
  final actualPitch = double.tryParse(await native.getProperty('speed'));
  final actualFilters = await native.getProperty('af');
  final expectedScale = RegExp(r'scale=([0-9.eE+\-]+)').firstMatch(expected);
  final actualScale = RegExp(r'scale[=:](?:%[0-9]+%)?"?([0-9.eE+\-]+)')
      .firstMatch(actualFilters);
  final requested = double.parse(expectedScale!.group(1)!);
  final actual = double.tryParse(actualScale?.group(1) ?? '');
  const marker = '@navis_eq:lavfi=[';
  final equalizerStart = expected.indexOf(marker);
  final expectsEqualizer = equalizerStart >= 0;
  final graph = expectsEqualizer
      ? expected.substring(equalizerStart + marker.length, expected.length - 1)
      : null;
  if (actualPitch == null ||
      (actualPitch - pitch).abs() > .000001 ||
      actual == null ||
      (actual - requested).abs() > .000001 ||
      actualFilters.contains('navis_eq') != expectsEqualizer ||
      (graph != null && !actualFilters.contains(graph))) {
    throw StateError(
        'The audio backend did not apply the requested filter chain');
  }
}
