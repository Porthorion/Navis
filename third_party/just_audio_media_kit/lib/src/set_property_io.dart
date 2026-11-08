library just_audio_media_kit;

import 'dart:ffi';

import 'package:media_kit/ffi/ffi.dart';
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
  final requested = double.tryParse(expectedScale?.group(1) ?? '');
  final actual = double.tryParse(actualScale?.group(1) ?? '');
  final expectsGain = expected.contains('@navis_rg');
  const marker = '@navis_eq:lavfi=[';
  final equalizerStart = expected.indexOf(marker);
  final expectsEqualizer = equalizerStart >= 0;
  final graph = expectsEqualizer
      ? expected.substring(equalizerStart + marker.length, expected.length - 1)
      : null;
  if (actualPitch == null ||
      (actualPitch - pitch).abs() > .000001 ||
      // No tempo expected (no EQ pipeline at 1x): none may be left over.
      (requested == null
          ? actualFilters.contains('navis_tempo')
          : actual == null || (actual - requested).abs() > .000001) ||
      actualFilters.contains('navis_eq') != expectsEqualizer ||
      // The label only: the level changes under live updates between the
      // write and this read.
      actualFilters.contains('navis_rg') != expectsGain ||
      (graph != null && !actualFilters.contains(graph))) {
    throw StateError(
        'The audio backend did not apply the requested filter chain');
  }
}

/// Enables MP3 table-of-contents seeks and observes native seek completion.
///
/// FFmpeg otherwise builds a precise MP3 index by reading from the beginning,
/// which can stall an uncached HTTP seek. This option belongs only to its MP3
/// demuxer; the existing protocol and streaming options remain intact.
Future<void> configureNativeSeeking(
    Player player, void Function(bool) onSeeking) async {
  final native = player.platform;
  if (native is! NativePlayer) return;
  // Mutate the native list directly. String round-tripping loses escaping in
  // values such as the comma-separated protocol whitelist.
  await native.command(['change-list', 'demuxer-lavf-o', 'append', 'usetoc=1']);
  await native.observeProperty('seeking', (value) async {
    onSeeking(value == 'yes');
  });
}

/// Starts the playlist entry mpv is about to load at the position [startFor]
/// returns for its index, through mpv's `start` option.
///
/// mpv applies `start` before playback begins, so nothing from the beginning
/// of the song is heard first and the position cannot be lost the way a
/// `seek` sent before the file has loaded is (mpv rejects those, and media_kit
/// only logs the error). media_kit's `on_unload` hook resets `start`, so other
/// entries still begin at zero. Returns whether the backend supports it.
bool configureStartPosition(
    Player player, Duration? Function(int index) startFor) {
  final native = player.platform;
  if (native is! NativePlayer) return false;
  native.onLoadHooks.add(() async {
    // Hooks run inside media_kit's serialized event handler: only synchronous
    // libmpv calls are safe here, as awaiting a reply event would deadlock.
    final index = int.tryParse(_readString(native, 'playlist-pos') ?? '');
    final position = index == null ? null : startFor(index);
    if (position == null) return;
    final name = 'start'.toNativeUtf8();
    final value = (position.inMicroseconds / Duration.microsecondsPerSecond)
        .toStringAsFixed(3)
        .toNativeUtf8();
    native.mpv.mpv_set_property_string(native.ctx, name.cast(), value.cast());
    calloc.free(name);
    calloc.free(value);
  });
  return true;
}

/// Writes the global `af` of every playlist entry mpv is about to load from
/// [filtersFor] (given its `path`), so the entry's chain, with its own
/// ReplayGain level, is built from the first sample. Returns whether the
/// backend supports it.
bool configureReplayGainFilter(
    Player player, String Function(String path) filtersFor) {
  final native = player.platform;
  if (native is! NativePlayer) return false;
  native.onLoadHooks.add(() async {
    // Synchronous libmpv calls only, as in [configureStartPosition].
    final path = _readString(native, 'path');
    if (path == null) return;
    nativeSetPropertySync(player, 'af', filtersFor(path));
  });
  return true;
}

/// Writes [value] to the mpv property [name] with a synchronous libmpv call,
/// so a write cannot land on a later file the way an awaited property set
/// can. Returns whether mpv accepted it.
bool nativeSetPropertySync(Player player, String name, String value) {
  final native = player.platform;
  if (native is! NativePlayer) return false;
  final key = name.toNativeUtf8();
  final text = value.toNativeUtf8();
  final result =
      native.mpv.mpv_set_property_string(native.ctx, key.cast(), text.cast());
  calloc.free(key);
  calloc.free(text);
  return result >= 0;
}

/// Runs the mpv command [line] with a synchronous libmpv call. Returns
/// whether mpv accepted it.
bool nativeCommandSync(Player player, String line) {
  final native = player.platform;
  if (native is! NativePlayer) return false;
  final text = line.toNativeUtf8();
  final result = native.mpv.mpv_command_string(native.ctx, text.cast());
  calloc.free(text);
  return result >= 0;
}

/// mpv's own audio filter chain right now, or null when unreadable.
String? nativeAudioFilters(Player player) {
  final native = player.platform;
  if (native is! NativePlayer) return null;
  return _readString(native, 'af');
}

/// mpv's current playback position, or null while no file is initialized.
Future<Duration?> nativePosition(Player player) async {
  final native = player.platform;
  if (native is! NativePlayer) return null;
  final seconds = double.tryParse(_readString(native, 'time-pos') ?? '');
  return seconds == null
      ? null
      : Duration(
          microseconds: (seconds * Duration.microsecondsPerSecond).round());
}

String? _readString(NativePlayer native, String property) {
  final name = property.toNativeUtf8();
  final value = native.mpv.mpv_get_property_string(native.ctx, name.cast());
  calloc.free(name);
  if (value == nullptr) return null;
  final result = value.cast<Utf8>().toDartString();
  native.mpv.mpv_free(value.cast());
  return result;
}
