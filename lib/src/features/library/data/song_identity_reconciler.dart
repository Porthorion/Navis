import 'package:flutter/foundation.dart';

import 'package:navis/src/database/daos/song_identity_dao.dart';
import 'package:navis/src/database/navis_database.dart';

final _identityPunctuation = RegExp(
  r'''[!"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~]''',
);
final _identityWhitespace = RegExp(r'\s+');

/// Normalizes optional MusicBrainz identifiers across songs, albums and artists.
String? normalizeMusicBrainzId(String? value) {
  final normalized = value?.trim().toLowerCase();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

enum SongIdentityMatchReason { sameId, recordingMbid, exactMetadata }

sealed class SongIdentityMatchResult {
  const new();
}

class SongIdentityMatched extends SongIdentityMatchResult {
  const new({required this.provisionalSong, required this.reason});

  final SongsTableData provisionalSong;
  final SongIdentityMatchReason reason;
}

class SongIdentityAmbiguous extends SongIdentityMatchResult {
  const new({
    required this.candidateCount,
    required this.reason,
    this.canonicalSongId,
    this.candidateIds = const <String>[],
  });

  final int candidateCount;
  final SongIdentityMatchReason reason;

  /// Set when ambiguity was observed while streaming canonical rows, so the
  /// caller can persist a review entry instead of only counting the case.
  final String? canonicalSongId;
  final List<String> candidateIds;
}

class SongIdentityUnmatched extends SongIdentityMatchResult {
  const new();
}

class SongIdentityReconciliationSummary {
  const new({
    this.aliases = const <SongIdentityAlias>[],
    this.canonicalizedSongCount = 0,
    this.ambiguousMatchCount = 0,
    this.retainedProvisionalCount = 0,
    this.restoredLikeCount = 0,
    this.ambiguousCases = const <SongIdentityAmbiguous>[],
  });

  final List<SongIdentityAlias> aliases;
  final int canonicalizedSongCount;
  final int ambiguousMatchCount;
  final int retainedProvisionalCount;

  /// Recovered likes that were re-queued for server dispatch.
  final int restoredLikeCount;

  /// Observed ambiguity with the involved IDs, for recovery review entries.
  final List<SongIdentityAmbiguous> ambiguousCases;
}

class SongIdentityReconciler {
  const new(
    this._identityDao, {
    this.onBeforeRemap,
    this.readActiveSongId,
    this.deferredFileDeletions,
  });

  final SongIdentityDao _identityDao;
  final Future<void> Function(Map<String, String> aliases)? onBeforeRemap;
  final String? Function()? readActiveSongId;

  /// When set, cache files that lose a remap are collected here instead of
  /// deleted: the reconciler runs inside a transaction whose owner deletes
  /// them after it commits.
  final List<String>? deferredFileDeletions;

  @visibleForTesting
  SongIdentityMatchResult matchCanonicalSong({
    required SongsTableData canonicalSong,
    required List<SongsTableData> provisionalSongs,
  }) => _ProvisionalIdentityIndex(this, provisionalSongs).match(canonicalSong);

  Future<SongIdentityReconciliationSession> startSession({
    List<SongsTableData>? provisionalSongs,
  }) async {
    final provisional =
        provisionalSongs ?? await _identityDao.getProvisionalSongs();
    return SongIdentityReconciliationSession._(
      this,
      _ProvisionalIdentityIndex(this, provisional),
    );
  }

  /// Two nonempty but different recording MBIDs are contradictory evidence:
  /// metadata similarity alone must never merge such rows automatically.
  bool _mbidsConflict(String? a, String? b) {
    final left = normalizeMusicBrainzId(a);
    final right = normalizeMusicBrainzId(b);
    return left != null && right != null && left != right;
  }

  bool _positionsCompatible(int? canonical, int? provisional) {
    return canonical == null || provisional == null || canonical == provisional;
  }

  String _normalizeIdentityMetadata(String value) {
    return value
        .toLowerCase()
        .trim()
        .replaceAll(_identityPunctuation, ' ')
        .replaceAll(_identityWhitespace, ' ')
        .trim();
  }
}

/// Retains a bounded provisional-song index while canonical rows are streamed
/// in pages. This avoids rescanning every provisional row for every catalog
/// song and keeps ambiguity decisions stable across page boundaries.
///
/// Matched claims are buffered until [SongIdentityReconciliationSession.finalize]
/// so uniqueness can be established across the complete replacement set: a
/// candidate contended for by more than one canonical row resolves as
/// ambiguous for every claimant regardless of page arrival order, instead of
/// silently honoring whichever row streamed first.
class SongIdentityReconciliationSession {
  new _(this._reconciler, this._index);

  final SongIdentityReconciler _reconciler;
  final _ProvisionalIdentityIndex _index;
  final List<SongIdentityAlias> _aliases = <SongIdentityAlias>[];
  final List<SongIdentityAmbiguous> _ambiguousCases = <SongIdentityAmbiguous>[];
  final List<_ClaimDecision> _claims = <_ClaimDecision>[];
  var _canonicalized = 0;
  var _ambiguous = 0;
  var _restoredLikes = 0;

  SongIdentityReconciliationSummary get summary =>
      SongIdentityReconciliationSummary(
        aliases: List<SongIdentityAlias>.unmodifiable(_aliases),
        canonicalizedSongCount: _canonicalized,
        ambiguousMatchCount: _ambiguous,
        retainedProvisionalCount: _index.remainingCount,
        restoredLikeCount: _restoredLikes,
        ambiguousCases: List<SongIdentityAmbiguous>.unmodifiable(
          _ambiguousCases,
        ),
      );

  Future<void> reconcile(Iterable<SongsTableData> canonicalSongs) async {
    for (final canonicalSong in canonicalSongs) {
      final result = _index.match(canonicalSong);
      switch (result) {
        case SongIdentityMatched():
          _claims.add(
            _ClaimDecision(
              canonical: canonicalSong,
              provisional: result.provisionalSong,
              reason: result.reason,
            ),
          );
        case SongIdentityAmbiguous():
          _ambiguous++;
          _ambiguousCases.add(result);
        case SongIdentityUnmatched():
          break;
      }
    }
  }

  /// Applies the buffered claims once every canonical row has been streamed.
  ///
  /// Two-sided uniqueness: candidates claimed by exactly one canonical row
  /// remap through the same transaction as before; a candidate claimed by
  /// more than one canonical row is uncertain under the complete replacement
  /// set, so every claimant becomes a review case and nothing is remapped.
  /// A same-identity claim is authoritative evidence that the provisional row
  /// belongs to that canonical song and keeps precedence over contested
  /// weaker claims.
  Future<void> finalize() async {
    final claimsByCandidate = <String, List<_ClaimDecision>>{};
    for (final claim in _claims) {
      claimsByCandidate.putIfAbsent(claim.provisional.id, () => []).add(claim);
    }
    for (final entry in claimsByCandidate.entries) {
      final claims = entry.value;
      if (claims.length == 1) {
        await _applyDecision(claims.single);
        continue;
      }
      final sameIdClaims = claims
          .where((claim) => claim.reason == SongIdentityMatchReason.sameId)
          .toList(growable: false);
      final sameIdClaim = sameIdClaims.length == 1 ? sameIdClaims.single : null;
      if (sameIdClaim != null) {
        await _applyDecision(sameIdClaim);
      }
      for (final claim in claims) {
        if (identical(claim, sameIdClaim)) {
          continue;
        }
        _recordContestedClaim(claim);
      }
    }
    _claims.clear();
  }

  Future<void> _applyDecision(_ClaimDecision decision) async {
    final canonicalSong = decision.canonical;
    if (decision.reason == SongIdentityMatchReason.sameId) {
      await _reconciler._identityDao.markCanonical(canonicalSong.id);
    } else {
      final oldSongId = decision.provisional.id;
      final wasActive = _reconciler.readActiveSongId?.call() == oldSongId;
      await _reconciler.onBeforeRemap?.call(<String, String>{
        oldSongId: canonicalSong.id,
      });
      final remap = await _reconciler._identityDao.remapSongIdentity(
        oldSongId: oldSongId,
        canonicalSongId: canonicalSong.id,
        matchReason: decision.reason.name,
        retainOldCacheFile: wasActive,
        deferredFileDeletions: _reconciler.deferredFileDeletions,
      );
      _aliases.add(remap.alias);
      if (remap.restoredLike) {
        _restoredLikes++;
      }
    }
    _index.remove(decision.provisional);
    _canonicalized++;
  }

  void _recordContestedClaim(_ClaimDecision claim) {
    _ambiguous++;
    _ambiguousCases.add(
      SongIdentityAmbiguous(
        candidateCount: 1,
        reason: claim.reason,
        canonicalSongId: claim.canonical.id,
        candidateIds: <String>[claim.provisional.id],
      ),
    );
  }
}

class _ClaimDecision {
  const new({
    required this.canonical,
    required this.provisional,
    required this.reason,
  });

  final SongsTableData canonical;
  final SongsTableData provisional;
  final SongIdentityMatchReason reason;
}

class _ProvisionalIdentityIndex {
  new(this._reconciler, Iterable<SongsTableData> songs) {
    for (final song in songs) {
      _remaining[song.id] = song;
      final mbid = normalizeMusicBrainzId(song.recordingMbid);
      if (mbid != null) {
        (_byMbid[mbid] ??= <SongsTableData>[]).add(song);
      }
      final metadata = _metadataKey(song);
      if (metadata != null) {
        (_byMetadata[metadata] ??= <SongsTableData>[]).add(song);
      }
    }
  }

  final SongIdentityReconciler _reconciler;
  final Map<String, SongsTableData> _remaining = <String, SongsTableData>{};
  final Map<String, List<SongsTableData>> _byMbid =
      <String, List<SongsTableData>>{};
  final Map<String, List<SongsTableData>> _byMetadata =
      <String, List<SongsTableData>>{};

  int get remainingCount => _remaining.length;

  SongIdentityMatchResult match(SongsTableData canonicalSong) {
    final sameId = _remaining[canonicalSong.id];
    if (sameId != null) {
      return SongIdentityMatched(
        provisionalSong: sameId,
        reason: SongIdentityMatchReason.sameId,
      );
    }
    final mbid = normalizeMusicBrainzId(canonicalSong.recordingMbid);
    if (mbid != null) {
      final matches = _active(_byMbid[mbid]);
      if (matches.length == 1) {
        return SongIdentityMatched(
          provisionalSong: matches.single,
          reason: SongIdentityMatchReason.recordingMbid,
        );
      }
      if (matches.length > 1) {
        return SongIdentityAmbiguous(
          candidateCount: matches.length,
          reason: SongIdentityMatchReason.recordingMbid,
        );
      }
    }
    final duration = canonicalSong.duration;
    final key = _metadataKey(canonicalSong);
    if (duration == null || key == null) {
      return const SongIdentityUnmatched();
    }
    final matches = _active(_byMetadata[key])
        .where(
          (candidate) =>
              !_reconciler._mbidsConflict(
                canonicalSong.recordingMbid,
                candidate.recordingMbid,
              ) &&
              candidate.duration != null &&
              (candidate.duration! - duration).abs() <= 3 &&
              _reconciler._positionsCompatible(
                canonicalSong.track,
                candidate.track,
              ) &&
              _reconciler._positionsCompatible(
                canonicalSong.discNumber,
                candidate.discNumber,
              ),
        )
        .toList(growable: false);
    if (matches.length == 1) {
      return SongIdentityMatched(
        provisionalSong: matches.single,
        reason: SongIdentityMatchReason.exactMetadata,
      );
    }
    if (matches.length > 1) {
      return SongIdentityAmbiguous(
        candidateCount: matches.length,
        reason: SongIdentityMatchReason.exactMetadata,
        canonicalSongId: canonicalSong.id,
        candidateIds: matches.map((song) => song.id).toList(growable: false),
      );
    }
    return const SongIdentityUnmatched();
  }

  void remove(SongsTableData song) {
    _remaining.remove(song.id);
  }

  List<SongsTableData> _active(List<SongsTableData>? candidates) {
    if (candidates == null || candidates.isEmpty) {
      return const <SongsTableData>[];
    }
    return candidates
        .where((song) => _remaining.containsKey(song.id))
        .toList(growable: false);
  }

  String? _metadataKey(SongsTableData song) {
    final title = _reconciler._normalizeIdentityMetadata(song.title);
    final artist = _reconciler._normalizeIdentityMetadata(
      song.artistName ?? '',
    );
    final album = _reconciler._normalizeIdentityMetadata(song.albumName ?? '');
    if (title.isEmpty || artist.isEmpty || album.isEmpty) {
      return null;
    }
    return '$title\u0000$artist\u0000$album';
  }
}
