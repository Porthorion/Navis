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

/// The ReplayGain boost of one mpv instance: what each queued URI gets and
/// what the playing file has now. Pure bookkeeping; the player writes the
/// returned values to mpv's `file-local-options/volume-gain`.
class ReplayGainBoostState {
  Map<String, double> _byKey = const <String, double>{};

  /// The gain, in dB, written for the file that is playing.
  double applied = 0;

  /// A natural join that started below its target and is raised at
  /// [replayGainBoostRaiseAfter] into that file.
  ({int index, double target})? armed;

  /// Set before a command that replaces the playing file; the next `on_load`
  /// consumes it. The first load is explicit.
  bool explicitSwitch = true;

  /// The key of the file the `on_load` hook last gave a gain: the file mpv is
  /// decoding, which is not the player's current entry while the end of the
  /// previous file is still queued.
  String? _loadedKey;

  /// Replaces the map. Returns the gain to write now for the loaded file, or
  /// null when nothing changes.
  double? update(Map<String, double> byUri) {
    _byKey = {
      for (final entry in byUri.entries)
        replayGainBoostKey(entry.key): entry.value,
    };
    final loaded = _loadedKey;
    final target = loaded == null ? 0.0 : (_byKey[loaded] ?? 0);
    final pending = armed;
    if (pending != null) {
      // Lowering is always safe; a raise waits for its time.
      if (target < applied) {
        armed = null;
        return applied = target;
      }
      armed = (index: pending.index, target: target);
      return null;
    }
    if (target == applied) return null;
    return applied = target;
  }

  /// The `on_load` hook: the gain for the file at [index] loaded from [path].
  double onLoad({required int index, required String path}) {
    _loadedKey = replayGainBoostKey(path);
    final target = _byKey[_loadedKey] ?? 0;
    final value = hookBoost(
      explicit: explicitSwitch,
      lastApplied: applied,
      target: target,
    );
    explicitSwitch = false;
    applied = value;
    armed = value < target ? (index: index, target: target) : null;
    return value;
  }

  /// The gain to write once file [index] has played for [position], or null.
  double? raiseDue(int index, Duration position) {
    final pending = armed;
    if (pending == null ||
        pending.index != index ||
        position < replayGainBoostRaiseAfter) {
      return null;
    }
    return raiseNow();
  }

  /// Ends a held-down join at once (after a seek in the same file, whose
  /// audio buffer is empty), returning the gain to write or null.
  double? raiseNow() {
    final pending = armed;
    if (pending == null) return null;
    armed = null;
    return applied = pending.target;
  }
}
