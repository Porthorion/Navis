import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:navis/src/database/daos/song_identity_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/data/song_identity_reconciler.dart';

/// Outcome of album/artist identity reconciliation during promotion.
class EntityIdentityReconciliationSummary {
  new({
    this.albumAliases = 0,
    this.artistAliases = 0,
    this.albumRestoredLikes = 0,
    this.artistRestoredLikes = 0,
    this.reviewCount = 0,
  });

  int albumAliases;
  int artistAliases;
  int albumRestoredLikes;
  int artistRestoredLikes;
  int reviewCount;

  int get aliases => albumAliases + artistAliases;
}

/// Derives album and artist identities after a promoted catalog snapshot.
///
/// Mapping relies on the evidence classes the plan allows (D4): a unique
/// stable MusicBrainz identifier on both sides, or an unambiguous
/// relationship mapping with compatible metadata derived from how the
/// entity's songs relinked. Everything else is never silently remapped;
/// unresolved rows keep their user state as provisional rows and are routed
/// to recovery review with typed reasons.
///
/// Runs inside the promotion transaction so a crash cannot leave aliases and
/// row moves half-applied.
class EntityIdentityReconciler {
  const new(this._database);

  final NavisDatabase _database;

  Future<EntityIdentityReconciliationSummary> reconcile({
    required int serverId,
    required int generation,
    required List<SongIdentityAlias> songAliases,
    required List<SongsTableData> provisionalSongs,
  }) async {
    final summary = EntityIdentityReconciliationSummary();
    final canonicalSongsById = await _loadCanonicalSongs(
      songAliases,
      provisionalSongs,
    );

    // --- Albums -----------------------------------------------------------
    final provisionalAlbums = await _database.songIdentityDao
        .getProvisionalAlbums();
    // Nothing provisional means nothing to reconcile, so skip reading every
    // candidate row.
    final candidateAlbums = provisionalAlbums.isEmpty
        ? const <LibrarySyncCandidateAlbumsTableData>[]
        : await _database.librarySyncCandidateDao.getAlbums(
            serverId: serverId,
            generation: generation,
          );
    final candidateAlbumsById = <String, LibrarySyncCandidateAlbumsTableData>{
      for (final album in candidateAlbums) album.id: album,
    };

    final albumTargets = _relationshipEvidence(
      provisionalSongs: provisionalSongs,
      songAliases: songAliases,
      canonicalSongsById: canonicalSongsById,
      oldKey: (song) => song.albumId,
      newKey: (song) => song.albumId,
    );

    final provisionalAlbumsById = <String, AlbumsTableData>{
      for (final album in provisionalAlbums) album.id: album,
    };
    final (
      albumAliases,
      albumRestoredLikes,
      albumReviews,
    ) = await _reconcileKind(
      serverId: serverId,
      generation: generation,
      entityType: 'album',
      oldRows: provisionalAlbums,
      metadata: (row) => (row.id, row.name, row.releaseMbid, row.artistName),
      candidates: {
        for (final row in candidateAlbums) row.id: (row.name, row.releaseMbid),
      },
      relationshipTargets: albumTargets,
      needsReview: _albumNeedsReview,
      remap: (oldId, canonicalId, reason) =>
          _database.songIdentityDao.remapAlbumIdentity(
            oldAlbumId: oldId,
            canonicalAlbumId: canonicalId,
            matchReason: reason,
            matchedAt: DateTime.now(),
          ),
    );
    summary.albumAliases = albumAliases.length;
    summary.albumRestoredLikes = albumRestoredLikes;
    summary.reviewCount += albumReviews;

    // --- Artists ----------------------------------------------------------
    final provisionalArtists = await _database.songIdentityDao
        .getProvisionalArtists();
    if (provisionalArtists.isEmpty) return summary;
    final candidateArtists = await _database.librarySyncCandidateDao.getArtists(
      serverId: serverId,
      generation: generation,
    );
    final artistTargets = _relationshipEvidence(
      provisionalSongs: provisionalSongs,
      songAliases: songAliases,
      canonicalSongsById: canonicalSongsById,
      oldKey: (song) => song.artistId,
      newKey: (song) => song.artistId,
    );
    // Album relinks contribute artist evidence: an old album under old
    // artist A relinked to a canonical album under artist B.
    for (final entry in albumAliases.entries) {
      final oldArtistId = provisionalAlbumsById[entry.key]?.artistId;
      final newArtistId = candidateAlbumsById[entry.value]?.artistId;
      if (oldArtistId == null || newArtistId == null) {
        continue;
      }
      (artistTargets[oldArtistId] ??= <String>{}).add(newArtistId);
    }

    final (
      artistAliases,
      artistRestoredLikes,
      artistReviews,
    ) = await _reconcileKind(
      serverId: serverId,
      generation: generation,
      entityType: 'artist',
      oldRows: provisionalArtists,
      metadata: (row) => (row.id, row.name, row.artistMbid, null),
      candidates: {
        for (final row in candidateArtists) row.id: (row.name, row.artistMbid),
      },
      relationshipTargets: artistTargets,
      needsReview: _artistNeedsReview,
      remap: (oldId, canonicalId, reason) =>
          _database.songIdentityDao.remapArtistIdentity(
            oldArtistId: oldId,
            canonicalArtistId: canonicalId,
            matchReason: reason,
            matchedAt: DateTime.now(),
          ),
    );
    summary.artistAliases = artistAliases.length;
    summary.artistRestoredLikes = artistRestoredLikes;
    summary.reviewCount += artistReviews;

    return summary;
  }

  Future<(Map<String, String>, int, int)> _reconcileKind<T>({
    required int serverId,
    required int generation,
    required String entityType,
    required List<T> oldRows,
    required (String, String, String?, String?) Function(T) metadata,
    required Map<String, (String, String?)> candidates,
    required Map<String, Set<String>> relationshipTargets,
    required Future<bool> Function(T) needsReview,
    required Future<bool> Function(String, String, String) remap,
  }) async {
    // Candidate evidence stays fixed across the whole kind's reconciliation.
    final mbidIndex = _indexMbidCandidates(
      candidatesById: candidates,
      candidateMbid: (row) => row.$2,
    );
    final aliases = <String, String>{};
    var restoredLikes = 0;
    var reviews = 0;
    for (final old in oldRows) {
      final (id, name, mbid, subtitle) = metadata(old);
      // Promotion already refreshed IDs that remain in the snapshot.
      if (candidates.containsKey(id)) continue;
      final decision = _resolveEntity(
        oldName: name,
        oldMbid: mbid,
        relationshipTargets: relationshipTargets[id] ?? const <String>{},
        candidatesById: candidates,
        mbidIndex: mbidIndex,
        candidateName: (row) => row.$1,
      );
      final target = decision.targetId;
      if (target == null) {
        if (await needsReview(old)) {
          await _database.librarySyncDao.recordRecoveryReview(
            serverId: serverId,
            entityType: entityType,
            oldId: id,
            savedTitle: name,
            savedSubtitle: subtitle,
            reason: decision.reviewReason!,
            evidenceGeneration: generation,
            candidateJson: decision.candidateJson,
          );
          reviews++;
        }
        continue;
      }
      aliases[id] = target;
      if (await remap(id, target, decision.matchReason!)) restoredLikes++;
    }
    return (aliases, restoredLikes, reviews);
  }

  Future<Map<String, SongsTableData>> _loadCanonicalSongs(
    List<SongIdentityAlias> songAliases,
    List<SongsTableData> provisionalSongs,
  ) async {
    final ids = <String>{
      for (final alias in songAliases) alias.canonicalSongId,
      // Same-ID songs were canonicalized in place; their promoted row carries
      // the fresh album/artist references and contributes relationship
      // evidence for the old album/artist rows they abandoned.
      ...provisionalSongs.map((song) => song.id),
    };
    if (ids.isEmpty) {
      return const <String, SongsTableData>{};
    }
    final rows = await _database.libraryDao.getSongsByIds(ids);
    return <String, SongsTableData>{for (final row in rows) row.id: row};
  }

  /// Groups the target IDs observed through song-level relinking.
  Map<String, Set<String>> _relationshipEvidence({
    required List<SongsTableData> provisionalSongs,
    required List<SongIdentityAlias> songAliases,
    required Map<String, SongsTableData> canonicalSongsById,
    required String? Function(SongsTableData) oldKey,
    required String? Function(SongsTableData) newKey,
  }) {
    final oldRowsById = <String, SongsTableData>{
      for (final song in provisionalSongs) song.id: song,
    };
    final targets = <String, Set<String>>{};
    void addEvidence(String? oldId, String? newId) {
      if (oldId == null || newId == null || oldId == newId) {
        return;
      }
      (targets[oldId] ??= <String>{}).add(newId);
    }

    for (final alias in songAliases) {
      final oldRow = oldRowsById[alias.oldSongId];
      final canonicalRow = canonicalSongsById[alias.canonicalSongId];
      if (oldRow == null || canonicalRow == null) {
        continue;
      }
      addEvidence(oldKey(oldRow), newKey(canonicalRow));
    }
    for (final oldRow in provisionalSongs) {
      final canonicalRow = canonicalSongsById[oldRow.id];
      if (canonicalRow == null) {
        continue;
      }
      addEvidence(oldKey(oldRow), newKey(canonicalRow));
    }
    return targets;
  }

  Map<String, Set<String>> _indexMbidCandidates<C>({
    required Map<String, C> candidatesById,
    required String? Function(C) candidateMbid,
  }) {
    final index = <String, Set<String>>{};
    for (final entry in candidatesById.entries) {
      final value = normalizeMusicBrainzId(candidateMbid(entry.value));
      if (value == null || value.isEmpty) {
        continue;
      }
      (index[value] ??= <String>{}).add(entry.key);
    }
    return index;
  }

  _EntityDecision _resolveEntity<C>({
    required String oldName,
    required String? oldMbid,
    required Set<String> relationshipTargets,
    required Map<String, C> candidatesById,
    required Map<String, Set<String>> mbidIndex,
    required String Function(C) candidateName,
  }) {
    // 1. Unique stable MusicBrainz identifier on both sides.
    final normalizedMbid = normalizeMusicBrainzId(oldMbid);
    if (normalizedMbid != null && normalizedMbid.isNotEmpty) {
      final matchedIds = mbidIndex[normalizedMbid] ?? const <String>{};
      if (matchedIds.length == 1) {
        final targetId = matchedIds.single;
        final candidate = candidatesById[targetId];
        if (candidate != null &&
            _namesCompatible(candidateName(candidate), oldName)) {
          return _EntityDecision(targetId: targetId, matchReason: 'stableMbid');
        }
        return _EntityDecision(
          reviewReason: 'ambiguousMatch',
          candidateJson: _candidateJson(<String>[targetId], 'stableMbid'),
        );
      }
      if (matchedIds.length > 1) {
        // Duplicate identifiers cannot prove one replacement.
        return _EntityDecision(
          reviewReason: 'conflictingMbid',
          candidateJson: _candidateJson(matchedIds.toList(), 'stableMbid'),
        );
      }
    }

    // 2. Unambiguous, complete relationship mapping with compatible metadata.
    if (relationshipTargets.length == 1) {
      final targetId = relationshipTargets.single;
      final candidate = candidatesById[targetId];
      if (candidate != null &&
          _namesCompatible(candidateName(candidate), oldName)) {
        return _EntityDecision(targetId: targetId, matchReason: 'membership');
      }
      return _EntityDecision(
        reviewReason: 'ambiguousMatch',
        candidateJson: _candidateJson(<String>[targetId], 'membership'),
      );
    }
    if (relationshipTargets.length > 1) {
      return _EntityDecision(
        reviewReason: 'ambiguousMatch',
        candidateJson: _candidateJson(
          relationshipTargets.toList(),
          'membership',
        ),
      );
    }

    // 3. No evidence at all: the entity needs explicit review.
    return _EntityDecision(reviewReason: 'missingFromCatalog');
  }

  bool _namesCompatible(String a, String b) {
    return a.trim().toLowerCase() == b.trim().toLowerCase();
  }

  /// A review entry is only worth showing when the row still carries user
  /// state or live references; ephemeral provisional parents are garbage
  /// collected instead.
  Future<bool> _albumNeedsReview(AlbumsTableData album) async {
    if (album.starred != null || album.userRating != null) {
      return true;
    }
    final referencing = await _database
        .customSelect(
          'SELECT COUNT(*) AS amount FROM songs WHERE album_id = ? LIMIT 1;',
          variables: <Variable<Object>>[Variable<String>(album.id)],
        )
        .getSingle();
    return referencing.read<int>('amount') > 0;
  }

  Future<bool> _artistNeedsReview(ArtistsTableData artist) async {
    if (artist.starred != null) {
      return true;
    }
    final row = await _database
        .customSelect(
          'SELECT EXISTS(SELECT 1 FROM songs WHERE artist_id = ?1) '
          'OR EXISTS(SELECT 1 FROM albums WHERE artist_id = ?1) AS needs_review',
          variables: [Variable<String>(artist.id)],
          readsFrom: {_database.songsTable, _database.albumsTable},
        )
        .getSingle();
    return row.read<bool>('needs_review');
  }

  String _candidateJson(List<String> candidateIds, String matchReason) {
    return jsonEncode(<String, Object?>{
      'candidateIds': candidateIds,
      'matchReason': matchReason,
    });
  }
}

class _EntityDecision {
  const new({
    this.targetId,
    this.matchReason,
    this.reviewReason,
    this.candidateJson,
  });

  final String? targetId;
  final String? matchReason;
  final String? reviewReason;
  final String? candidateJson;
}
