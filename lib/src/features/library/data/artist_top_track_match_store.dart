import 'dart:async';

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
/// One JSON file per artist in [IntegrationJsonCache] namespace [namespace]:
/// seed key → song id or unmatched, plus when it was checked. An entry is
/// trusted for [freshFor]; the caller still checks the library for unmatched
/// and remote entries and confirms that matched songs exist. Every library
/// sync clears the namespace. Saves merge with what is on disk, so the
/// section (10 songs) and the "This Is" page (50) never drop each other's
/// entries.
class ArtistTopTrackMatchStore {
  new({required this._cache, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  static const namespace = 'top-songs.matches';
  static const freshFor = Duration(hours: 24);

  /// Bumped when the stored layout or the seed key changes.
  static const _formatVersion = 1;

  final IntegrationJsonCache _cache;
  final DateTime Function() _now;
  final Map<String, Future<void>> _saveChains = <String, Future<void>>{};

  DateTime now() => _now();

  /// The key of [seed]: its edition-preserving title and artist, so a source
  /// change (Deezer to Last.fm) keeps the matches.
  static String seedKey(ArtistTopTrackSeed seed) =>
      '${normalizeMetadataKeepingEdition(seed.title)}\u001f'
      '${normalizeMetadata(seed.artist)}';

  bool isFresh(ArtistTopTrackMatchEntry entry) =>
      _now().difference(entry.checkedAt) < freshFor;

  /// The fresh entries for [artistId]; stale and unreadable ones are left out.
  Future<Map<String, ArtistTopTrackMatchEntry>> load(String artistId) async {
    final hit = await _cache.read(namespace, artistId);
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
        if (isFresh(entry)) result[key] = entry;
      } on Object catch (error) {
        AppLogger.debug('Top songs: unreadable match entry: $error');
      }
    }
    return result;
  }

  /// Adds [updates] to the stored entries of [artistId].
  Future<void> save(
    String artistId,
    Map<String, ArtistTopTrackMatchEntry> updates,
  ) {
    if (updates.isEmpty) return Future<void>.value();
    final previous = _saveChains[artistId] ?? Future<void>.value();
    final next = previous.then((_) => _merge(artistId, updates));
    _saveChains[artistId] = next;
    return next.whenComplete(() {
      if (identical(_saveChains[artistId], next)) {
        unawaited(_saveChains.remove(artistId));
      }
    });
  }

  /// Completes when the saves started so far are on disk.
  Future<void> whenSaved() => Future.wait(_saveChains.values.toList());

  Future<void> clear() => _cache.clearNamespace(namespace);

  Future<void> _merge(
    String artistId,
    Map<String, ArtistTopTrackMatchEntry> updates,
  ) async {
    final merged = await load(artistId)
      ..addAll(updates);
    await _cache.write(namespace, artistId, <String, Object?>{
      'v': _formatVersion,
      'keyVersion': metadataKeyVersion,
      'entries': <String, Object?>{
        for (final MapEntry(:key, :value) in merged.entries)
          key: value.toJson(),
      },
    }, ttl: freshFor);
  }
}
