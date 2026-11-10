import 'package:media_kit/media_kit.dart';

/// The key a source URI has in the level map: the form media_kit hands to
/// mpv, minus the `\\?\` long-path prefix media_kit adds on Windows.
String replayGainBoostKey(String uri) =>
    Media.normalizeURI(uri.startsWith(r'\\?\') ? uri.substring(4) : uri);

/// The ReplayGain of one mpv instance in dB (signed: cut and boost together):
/// what each queued file gets and what the loaded file has now. Pure
/// bookkeeping; the player writes the values into its `@navis_rg` filter.
///
/// The `on_load` hook is a plain lookup: every file starts at its own level
/// whether it follows by a natural join, a jump or a seek, and a file outside
/// the map (radio) plays at 0 dB. The playing file's level is frozen: only a
/// `live` update moves it.
class ReplayGainLevels {
  final _byKey = <String, double>{};

  /// The same levels by queue entry (the source message id, unique per
  /// entry), which tells apart one file queued at two positions. [_byKey]
  /// stays the fallback for a file the entry list does not name.
  final _byId = <String, double>{};

  /// The [replayGainBoostKey] of the file each [_byId] entry was seeded for,
  /// so a stale playlist index cannot lend one file another's level.
  final _idKeys = <String, String>{};

  /// The key of the file the `on_load` hook last gave a level: the file mpv is
  /// decoding, which is not the player's current entry while the end of the
  /// previous file is still queued.
  String? _loadedKey;
  String? _loadedId;

  /// The level, in dB, the loaded file plays at.
  double current = 0;

  /// Forgets the queue's levels, for a new queue. The loaded file keeps its
  /// level until the next hook, as it is still playing, and no live push can
  /// move it meanwhile: its key is not in the new queue.
  void clear() {
    _byKey.clear();
    _byId.clear();
    _idKeys.clear();
    _loadedKey = null;
    _loadedId = null;
  }

  /// Records the level a source message carried for [uri].
  // ponytail: levels of removed songs stay until the next load; bounded by the
  // queue edits of one queue.
  void seed(String uri, double db, {String? id}) {
    _byKey[replayGainBoostKey(uri)] = _safe(db);
    if (id != null) {
      _byId[id] = _safe(db);
      _idKeys[id] = replayGainBoostKey(uri);
    }
  }

  /// Adds the levels of a push. Returns the playing file's new level when
  /// [live] moved it, else null.
  double? update(
    Map<String, double> byUri, {
    Map<String, double> byId = const {},
    required bool live,
  }) {
    for (final entry in byUri.entries) {
      seed(entry.key, entry.value);
    }
    for (final entry in byId.entries) {
      _byId[entry.key] = _safe(entry.value);
    }
    final loaded = _loadedKey;
    if (!live || loaded == null) return null;
    final next = _lookup(loaded, _loadedId);
    return next == current ? null : current = next;
  }

  /// The `on_load` hook: the level of the file loaded from [path], which is
  /// queue entry [id] when the hook knows it.
  // ponytail: repeat-one's wrap and a jump to the entry already playing fire
  // no `on_load`, so a non-live change (tag correction, Smart pair) waits for
  // the next real load there; add a seek-time lookup if that is ever heard.
  double onLoad(String path, {String? id}) {
    final key = _loadedKey = replayGainBoostKey(path);
    _loadedId = id;
    return current = _lookup(key, id);
  }

  double _lookup(String key, String? id) =>
      (id != null && _idKeys[id] == key ? _byId[id] : null) ?? _byKey[key] ?? 0;

  static double _safe(double db) => db.isFinite ? db : 0;
}
