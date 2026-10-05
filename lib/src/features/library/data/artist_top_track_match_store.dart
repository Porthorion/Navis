import 'dart:async';
import 'dart:convert';

import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/features/integrations/data/integration_json_cache.dart';
import 'package:navis/src/features/library/domain/artist_top_track.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/metadata_normalization.dart';

/// How an artist's top song was last matched to the library.
class ArtistTopTrackMatchEntry {
  const new({required this.checkedAt, this.songId, this.remoteSong});

  /// No confident match was found.
  const new unmatched({required this.checkedAt})
    : songId = null,
      remoteSong = null;

  factory fromJson(Map<String, dynamic> json) {
    final song = json['song'];
    return ArtistTopTrackMatchEntry(
      songId: json['songId'] as String?,
      remoteSong: song is Map
          ? Song.fromJson(Map<String, dynamic>.from(song))
          : null,
      checkedAt: DateTime.parse(json['checkedAt'] as String),
    );
  }

  /// The matched song's id, or null when unmatched.
  final String? songId;

  /// The whole song for a match the server offers from a remote source and
  /// the library may not hold, so it can be shown without a search.
  final Song? remoteSong;
  final DateTime checkedAt;

  bool get isMatched => songId != null;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'songId': ?songId,
    if (remoteSong case final song?) 'song': song.toJson(),
    'checkedAt': checkedAt.toUtc().toIso8601String(),
  };
}

/// Remembers per library artist how each top song matched, so reopening an
/// artist does not search the server again.
///
/// One JSON file per server account ([accountScope]) and artist in
/// [IntegrationJsonCache] namespace [namespace]:
/// seed key → song id or unmatched, plus when it was checked. An entry is
/// trusted for [freshFor]; the caller still checks the library for unmatched
/// and remote entries and confirms that matched songs exist. Entries are
/// kept for [keepFor] (by default the same [freshFor]), so a store that keeps
/// them longer, like Home's Trending Now, can recheck an older remote match
/// on the server without losing it. Every library sync clears the artist top
/// songs' namespace. Saves merge with what is on disk, so the section (10
/// songs) and the "This Is" page (50) never drop each other's entries.
class ArtistTopTrackMatchStore {
  new({
    required this._cache,
    this.accountScope = '',
    this.namespace = topSongsNamespace,
    Duration? keepFor,
    DateTime Function()? now,
  }) : keepFor = keepFor ?? freshFor,
       _now = now ?? DateTime.now;

  /// The artist top songs' matches; every library sync clears it.
  static const topSongsNamespace = 'top-songs.matches';
  static const freshFor = Duration(hours: 24);

  /// The [IntegrationJsonCache] namespace of this store's files.
  final String namespace;

  /// How long an entry is kept, at least [freshFor].
  final Duration keepFor;

  /// Bumped when the stored layout or the seed key changes.
  static const _formatVersion = 2;

  final IntegrationJsonCache _cache;

  /// A non-credential identity of the signed-in server account. Library ids
  /// (and the constant chart key) are only unique within one server, so
  /// another account never reads these matches.
  final String accountScope;

  final DateTime Function() _now;
  final Map<String, Future<void>> _saveChains = <String, Future<void>>{};

  DateTime now() => _now();

  /// The key of [seed]: its edition-preserving title and artist, so a source
  /// change (Deezer to Last.fm) keeps the matches.
  static String seedKey(ArtistTopTrackSeed seed) =>
      '${normalizeMetadataKeepingEdition(seed.title)}\u001f'
      '${normalizeMetadata(seed.artist)}';

  String _fileKey(String artistId) =>
      jsonEncode(<String>[accountScope, artistId]);

  bool isFresh(ArtistTopTrackMatchEntry entry) =>
      _now().difference(entry.checkedAt) < freshFor;

  bool _isKept(ArtistTopTrackMatchEntry entry) =>
      _now().difference(entry.checkedAt) < keepFor;

  /// The entries for [artistId] younger than [keepFor]; older and unreadable
  /// ones are left out. With the default [keepFor] they are all fresh.
  Future<Map<String, ArtistTopTrackMatchEntry>> load(String artistId) async {
    final hit = await _cache.read(namespace, _fileKey(artistId));
    final value = hit?.value;
    if (value is! Map ||
        value['v'] != _formatVersion ||
        value['keyVersion'] != metadataKeyVersion) {
      return <String, ArtistTopTrackMatchEntry>{};
    }
    final entries = value['entries'];
    if (entries is! Map) return <String, ArtistTopTrackMatchEntry>{};
    final result = <String, ArtistTopTrackMatchEntry>{};
    for (final MapEntry(:key, :value) in entries.entries) {
      if (key is! String || value is! Map) continue;
      try {
        final entry = ArtistTopTrackMatchEntry.fromJson(
          Map<String, dynamic>.from(value),
        );
        if (_isKept(entry)) result[key] = entry;
      } on Object catch (error) {
        AppLogger.debug('Top songs: unreadable match entry: $error');
      }
    }
    return result;
  }

  /// Advances on every [clear] and [invalidate]. A resolution captures it
  /// when it starts and passes it to [save], so results computed before a
  /// library sync or an account change cannot land afterwards.
  int get generation => _generation;
  int _generation = 0;

  /// Drops saves still pending from resolutions that started before now;
  /// called when this store's account leaves.
  void invalidate() => _generation++;

  /// Adds [updates] to the stored entries of [artistId], unless the store
  /// was cleared since [generation] was read.
  Future<void> save(
    String artistId,
    Map<String, ArtistTopTrackMatchEntry> updates, {
    required int generation,
  }) {
    if (updates.isEmpty || generation != _generation) {
      return Future<void>.value();
    }
    final previous = _saveChains[artistId] ?? Future<void>.value();
    final next = previous.then((_) => _merge(artistId, updates, generation));
    _saveChains[artistId] = next;
    return next.whenComplete(() {
      if (identical(_saveChains[artistId], next)) {
        unawaited(_saveChains.remove(artistId));
      }
    });
  }

  /// Completes when the saves started so far are on disk.
  Future<void> whenSaved() => Future.wait(_saveChains.values.toList());

  /// Forgets every artist's entries. Saves already queued are dropped, and a
  /// save already writing finishes before the files are deleted.
  Future<void> clear() async {
    _generation++;
    await whenSaved();
    await _cache.clearNamespace(namespace);
  }

  Future<void> _merge(
    String artistId,
    Map<String, ArtistTopTrackMatchEntry> updates,
    int generation,
  ) async {
    if (generation != _generation) return;
    final merged = await load(artistId)
      ..addAll(updates);
    if (generation != _generation) return;
    await _cache.write(namespace, _fileKey(artistId), <String, Object?>{
      'v': _formatVersion,
      'keyVersion': metadataKeyVersion,
      'entries': <String, Object?>{
        for (final MapEntry(:key, :value) in merged.entries)
          key: value.toJson(),
      },
    }, ttl: keepFor);
  }
}
