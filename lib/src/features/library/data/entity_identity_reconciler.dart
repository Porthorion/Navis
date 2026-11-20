import 'dart:convert';

import 'package:navis/src/database/daos/song_identity_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/data/song_identity_reconciler.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/search_text.dart';

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
/// entity's songs relinked (names compare case/accent-folded). Two album-only
/// additions (#709): a name-mismatched membership target is applied when the
/// relinked songs cover the whole old album (`membershipFullCoverage`), and an
/// old album kept only by user data matches a new-this-generation candidate
/// by folded name, artist and year/song count (`foldedName`), provided the
/// match is unique in both directions. Everything else is never silently remapped;
/// unresolved rows keep their user state as provisional rows and are routed
/// to recovery review with typed reasons.
///
/// Runs inside the promotion transaction so a crash cannot leave aliases and
/// row moves half-applied.
class EntityIdentityReconciler {
  const new(this._database, {this.owner});

  final NavisDatabase _database;

  /// Username owning the playlists that count as user-chosen references.
  final String? owner;

  Future<EntityIdentityReconciliationSummary> reconcile({
    required int serverId,
    required int generation,
    required List<SongIdentityAlias> songAliases,
    required List<SongsTableData> provisionalSongs,

    /// Candidate album ids that were not live albums before this promotion.
    /// Only these may match by `foldedName`: a candidate that coexisted with
    /// the old row cannot be its re-id.
    Set<String> newAlbumIds = const <String>{},
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

    final mappedAlbumSongs = <String, Set<String>>{};
    final albumTargets = _relationshipEvidence(
      provisionalSongs: provisionalSongs,
      songAliases: songAliases,
      canonicalSongsById: canonicalSongsById,
      oldKey: (song) => song.albumId,
      newKey: (song) => song.albumId,
      mappedSongs: mappedAlbumSongs,
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
      fullCoverage: (oldId, targetId) {
        // Every song of the old album relinked into the target and the sizes
        // agree: strong enough to override a name difference.
        final count = provisionalAlbumsById[oldId]?.songCount;
        final target = candidateAlbumsById[targetId]?.songCount;
        if (count == null || count < 2 || target == null) return false;
        return (mappedAlbumSongs[oldId]?.length ?? 0) == count &&
            (target - count).abs() <= 2;
      },
      refine: (decisions) => _foldedNameTier(
        decisions,
        oldAlbums: provisionalAlbumsById,
        candidates: candidateAlbumsById,
        newAlbumIds: newAlbumIds,
      ),
      needsReview: _albumNeedsReview,
      remap: (oldId, canonicalId, reason) async {
        final restoredLike = await _database.songIdentityDao.remapAlbumIdentity(
          oldAlbumId: oldId,
          canonicalAlbumId: canonicalId,
          matchReason: reason,
          matchedAt: DateTime.now(),
        );
        // Remote copies that moved onto the library album are cleaned up by
        // the per-album identity pass of the pending hydration drain (#707).
        await _database.songIdentityDao.markAlbumPendingIfRemoteCopies(
          canonicalId,
        );
        return restoredLike;
      },
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
    bool Function(String oldId, String targetId)? fullCoverage,
    Future<Map<String, _EntityDecision>> Function(
      Map<String, _EntityDecision> decisions,
    )?
    refine,
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
    // Promotion already refreshed IDs that remain in the snapshot.
    final pending = [
      for (final old in oldRows)
        if (!candidates.containsKey(metadata(old).$1)) old,
    ];
    var decisions = <String, _EntityDecision>{
      for (final old in pending)
        metadata(old).$1: _resolveEntity(
          oldName: metadata(old).$2,
          oldMbid: metadata(old).$3,
          relationshipTargets:
              relationshipTargets[metadata(old).$1] ?? const <String>{},
          candidatesById: candidates,
          mbidIndex: mbidIndex,
          candidateName: (row) => row.$1,
          fullCoverage: fullCoverage == null
              ? null
              : (targetId) => fullCoverage(metadata(old).$1, targetId),
        ),
    };
    if (refine != null) decisions = await refine(decisions);
    for (final old in pending) {
      final (id, name, _, subtitle) = metadata(old);
      final decision = decisions[id]!;
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
      AppLogger.debug(
        'Identity reconciliation: $entityType $id -> $target '
        '(${decision.matchReason}).',
      );
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

    /// Receives, per old id, the old songs that contributed evidence.
    Map<String, Set<String>>? mappedSongs,
  }) {
    final oldRowsById = <String, SongsTableData>{
      for (final song in provisionalSongs) song.id: song,
    };
    final targets = <String, Set<String>>{};
    void addEvidence(String? oldId, String? newId, String oldSongId) {
      if (oldId == null || newId == null || oldId == newId) {
        return;
      }
      (targets[oldId] ??= <String>{}).add(newId);
      mappedSongs?.putIfAbsent(oldId, () => <String>{}).add(oldSongId);
    }

    for (final alias in songAliases) {
      final oldRow = oldRowsById[alias.oldSongId];
      final canonicalRow = canonicalSongsById[alias.canonicalSongId];
      if (oldRow == null || canonicalRow == null) {
        continue;
      }
      addEvidence(oldKey(oldRow), newKey(canonicalRow), oldRow.id);
    }
    for (final oldRow in provisionalSongs) {
      final canonicalRow = canonicalSongsById[oldRow.id];
      if (canonicalRow == null) {
        continue;
      }
      addEvidence(oldKey(oldRow), newKey(canonicalRow), oldRow.id);
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
    bool Function(String targetId)? fullCoverage,
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
      if (candidate != null && (fullCoverage?.call(targetId) ?? false)) {
        return _EntityDecision(
          targetId: targetId,
          matchReason: 'membershipFullCoverage',
        );
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

  /// Case- and accent-folded name equality (the fold the SQL `navis_fold`
  /// wraps); an empty name matches nothing.
  bool _namesCompatible(String a, String b) {
    final folded = _fold(a);
    return folded.isNotEmpty && folded == _fold(b);
  }

  String _fold(String? value) =>
      foldSearchLetters((value ?? '').trim().toLowerCase());

  /// Album-only last tier: an old album kept only by user data (no provisional
  /// songs left) matches a candidate that is new this generation by folded
  /// name and artist plus year (or song count when a year is missing). Both
  /// sides must be unique: one qualifying candidate, claimed by no other old
  /// row (including rows already matched by MBID or membership).
  Future<Map<String, _EntityDecision>> _foldedNameTier(
    Map<String, _EntityDecision> decisions, {
    required Map<String, AlbumsTableData> oldAlbums,
    required Map<String, LibrarySyncCandidateAlbumsTableData> candidates,
    required Set<String> newAlbumIds,
  }) async {
    int? known(int? value) => value == null || value == 0 ? null : value;
    String? mbid(String? value) => normalizeMusicBrainzId(value);
    final qualifying = <String, List<String>>{};
    final claimants = <String, Set<String>>{
      for (final entry in decisions.entries)
        if (entry.value.targetId != null) entry.value.targetId!: {entry.key},
    };
    for (final entry in decisions.entries) {
      final old = oldAlbums[entry.key];
      if (old == null || entry.value.reviewReason != 'missingFromCatalog') {
        continue;
      }
      final name = _fold(old.name);
      final artist = _fold(old.artistName);
      if (name.isEmpty || artist.isEmpty) continue;
      final matches = <String>[
        for (final id in newAlbumIds)
          if (_foldedAlbumMatch(
            old,
            candidates[id],
            name: name,
            artist: artist,
            known: known,
            mbid: mbid,
          ))
            id,
      ];
      // Songs left behind that did not relink are evidence against a match.
      if (matches.isEmpty || await _hasRetainedSongs(old.id)) continue;
      qualifying[entry.key] = matches..sort();
      for (final id in matches) {
        (claimants[id] ??= <String>{}).add(entry.key);
      }
    }
    return <String, _EntityDecision>{
      ...decisions,
      for (final entry in qualifying.entries)
        entry.key:
            entry.value.length == 1 &&
                claimants[entry.value.single]!.length == 1
            ? _EntityDecision(
                targetId: entry.value.single,
                matchReason: 'foldedName',
              )
            : _EntityDecision(
                reviewReason: 'ambiguousMatch',
                candidateJson: _candidateJson(entry.value, 'foldedName'),
              ),
    };
  }

  bool _foldedAlbumMatch(
    AlbumsTableData old,
    LibrarySyncCandidateAlbumsTableData? candidate, {
    required String name,
    required String artist,
    required int? Function(int?) known,
    required String? Function(String?) mbid,
  }) {
    if (candidate == null ||
        _fold(candidate.name) != name ||
        _fold(candidate.artistName) != artist) {
      return false;
    }
    final oldMbid = mbid(old.releaseMbid);
    final newMbid = mbid(candidate.releaseMbid);
    if (oldMbid != null && newMbid != null && oldMbid != newMbid) return false;
    final oldYear = known(old.year);
    final newYear = known(candidate.year);
    if (oldYear != null && newYear != null) return oldYear == newYear;
    final count = known(old.songCount);
    return count != null && count == known(candidate.songCount);
  }

  Future<bool> _hasRetainedSongs(String albumId) async {
    final row =
        await (_database.select(_database.songsTable)
              ..where((t) => t.albumId.equals(albumId))
              ..limit(1))
            .getSingleOrNull();
    return row != null;
  }

  /// A review entry is only worth showing when the user chose something on
  /// the row (starred, rated, or a song in a local or own playlist);
  /// ephemeral provisional parents are garbage collected instead, and
  /// retention itself is unchanged.
  Future<bool> _albumNeedsReview(AlbumsTableData album) => _database
      .librarySyncDao
      .hasUserChosenReference('album', album.id, owner: owner);

  Future<bool> _artistNeedsReview(ArtistsTableData artist) => _database
      .librarySyncDao
      .hasUserChosenReference('artist', artist.id, owner: owner);

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
