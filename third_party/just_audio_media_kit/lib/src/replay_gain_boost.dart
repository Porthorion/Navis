import 'dart:math' as math;

import 'package:media_kit/media_kit.dart';

/// How far into a file the held-down gain of a natural join is raised again.
const replayGainBoostRaiseAfter = Duration(milliseconds: 500);

/// The key a source URI has in the boost map: the form media_kit hands to
/// mpv, minus the `\\?\` long-path prefix media_kit adds on Windows.
String replayGainBoostKey(String uri) =>
    Media.normalizeURI(uri.startsWith(r'\\?\') ? uri.substring(4) : uri);

/// The gain, in dB, the `on_load` hook gives the file that is starting.
///
/// An [explicit] switch (load, skip, removing the playing song) has cleared
/// mpv's audio buffer, so the file starts at its own [target]. At a natural
/// join mpv still has the end of the previous file queued and applies the new
/// gain to it, so the file starts at no more than [lastApplied] and is raised
/// afterwards. Never more than the previous file's own boost reaches the
/// previous file's samples.
double hookBoost({
  required bool explicit,
  required double lastApplied,
  required double target,
}) =>
    explicit ? target : math.min(lastApplied, target);

/// How long a switch command may take to reach its `on_load` hook before the
/// expectation is dropped: a command that loads nothing must not make a much
/// later natural join look explicit.
const replayGainBoostSwitchLifetime = Duration(seconds: 5);

/// The ReplayGain boost of one mpv instance: what each queued URI gets and
/// what the loaded file has now. Pure bookkeeping; the player writes the
/// returned values to mpv's `file-local-options/volume-gain`.
///
/// The rule behind every method: mpv applies `volume-gain` to the queued end
/// of the previous file, so after a natural join the loaded file may only go
/// down until it has been heard ([held]); a raise waits for
/// [replayGainBoostRaiseAfter] of its own playback.
class ReplayGainBoostState {
  ReplayGainBoostState({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  Map<String, double> _byKey = const <String, double>{};

  /// The gain, in dB, written for the loaded file.
  double applied = 0;

  /// After a natural join: the loaded file's own boost, not yet allowed on
  /// the queued end of the previous file. Null once it has been heard, and
  /// after an explicit switch (mpv cleared its audio buffer).
  double? held;

  /// The playlist position a switch command (load, jump, removing the playing
  /// entry) will load next. Only the hook for that position is explicit.
  ({int position, DateTime at})? _expected;

  /// The key of the file the `on_load` hook last gave a gain: the file mpv is
  /// decoding, which is not the player's current entry while the end of the
  /// previous file is still queued.
  String? _loadedKey;

  /// A command that will replace the playing file with the entry at
  /// [position] has been sent.
  void expectSwitch(int position) =>
      _expected = (position: position, at: _clock());

  /// The command turned out to load nothing.
  void cancelSwitch() => _expected = null;

  /// Replaces the map. Returns the gain to write now for the loaded file, or
  /// null when nothing changes.
  double? update(Map<String, double> byUri) {
    _byKey = {
      for (final entry in byUri.entries)
        replayGainBoostKey(entry.key): entry.value,
    };
    final loaded = _loadedKey;
    if (loaded == null) return null;
    final target = _byKey[loaded] ?? 0;
    if (held != null) {
      // Lowering is always safe; a raise waits for its time.
      held = target;
      return target < applied ? applied = target : null;
    }
    return target == applied ? null : applied = target;
  }

  /// The `on_load` hook: the gain for the file at [position] loaded from
  /// [path].
  double onLoad({required int position, required String path}) {
    _loadedKey = replayGainBoostKey(path);
    final target = _byKey[_loadedKey] ?? 0;
    final expected = _expected;
    final fresh = expected != null &&
        _clock().difference(expected.at) < replayGainBoostSwitchLifetime;
    if (expected != null && !fresh) _expected = null;
    final explicit = expected != null && fresh && expected.position == position;
    if (explicit) _expected = null;
    final value = hookBoost(
      explicit: explicit,
      lastApplied: applied,
      target: target,
    );
    applied = value;
    held = explicit ? null : target;
    return value;
  }

  /// The gain to write once the loaded file has played to [position], or
  /// null. A seek that landed shows as a position past the gate; one mpv
  /// rejected leaves the early positions and keeps the hold.
  double? raiseDue(Duration position) {
    final target = held;
    if (target == null || position < replayGainBoostRaiseAfter) return null;
    held = null;
    return target == applied ? null : applied = target;
  }
}
