import 'package:navis/src/database/daos/song_identity_dao.dart';
import 'package:navis/src/database/navis_database.dart';

final _identityPunctuation = RegExp(
  r'''[!"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~]''',
);
final _identityWhitespace = RegExp(r'\s+');

enum SongIdentityMatchReason {
  sameId,
  recordingMbid,
  exactMetadata,
}

sealed class SongIdentityMatchResult {
  const SongIdentityMatchResult();
}

class SongIdentityMatched extends SongIdentityMatchResult {
  const SongIdentityMatched({
    required this.provisionalSong,
    required this.reason,
  });

  final SongsTableData provisionalSong;
  final SongIdentityMatchReason reason;
}

class SongIdentityAmbiguous extends SongIdentityMatchResult {
  const SongIdentityAmbiguous({
    required this.candidateCount,
    required this.reason,
  });

  final int candidateCount;
  final SongIdentityMatchReason reason;
}

class SongIdentityUnmatched extends SongIdentityMatchResult {
  const SongIdentityUnmatched();
}

class SongIdentityReconciliationSummary {
  const SongIdentityReconciliationSummary({
    this.aliases = const <SongIdentityAlias>[],
    this.canonicalizedSongCount = 0,
    this.ambiguousMatchCount = 0,
    this.retainedProvisionalCount = 0,
  });

  final List<SongIdentityAlias> aliases;
  final int canonicalizedSongCount;
  final int ambiguousMatchCount;
  final int retainedProvisionalCount;
}

class SongIdentityReconciler {
  const SongIdentityReconciler(
    this._identityDao, {
    this.onBeforeRemap,
    this.readActiveSongId,
  });

  final SongIdentityDao _identityDao;
  final Future<void> Function(Map<String, String> aliases)? onBeforeRemap;
  final String? Function()? readActiveSongId;

  SongIdentityMatchResult matchCanonicalSong({
    required SongsTableData canonicalSong,
    required List<SongsTableData> provisionalSongs,
  }) {
    final sameIdMatches = provisionalSongs
        .where((song) => song.id == canonicalSong.id)
        .toList(growable: false);
    if (sameIdMatches.length == 1) {
      return SongIdentityMatched(
        provisionalSong: sameIdMatches.single,
        reason: SongIdentityMatchReason.sameId,
      );
    }

    final canonicalMbid = _normalizeMbid(canonicalSong.recordingMbid);
    if (canonicalMbid != null) {
      final mbidMatches = provisionalSongs
          .where(
            (song) => _normalizeMbid(song.recordingMbid) == canonicalMbid,
          )
          .toList(growable: false);
      if (mbidMatches.length == 1) {
        return SongIdentityMatched(
          provisionalSong: mbidMatches.single,
          reason: SongIdentityMatchReason.recordingMbid,
        );
      }
      if (mbidMatches.length > 1) {
        return SongIdentityAmbiguous(
          candidateCount: mbidMatches.length,
          reason: SongIdentityMatchReason.recordingMbid,
        );
      }
    }

    final canonicalDuration = canonicalSong.duration;
    if (canonicalDuration == null) {
      return const SongIdentityUnmatched();
    }
    final canonicalTitle = _normalizeIdentityMetadata(canonicalSong.title);
    final canonicalArtist = _normalizeIdentityMetadata(
      canonicalSong.artistName ?? '',
    );
    final canonicalAlbum = _normalizeIdentityMetadata(
      canonicalSong.albumName ?? '',
    );
    if (canonicalTitle.isEmpty ||
        canonicalArtist.isEmpty ||
        canonicalAlbum.isEmpty) {
      return const SongIdentityUnmatched();
    }

    final metadataMatches = provisionalSongs
        .where((candidate) {
          final duration = candidate.duration;
          if (duration == null || (duration - canonicalDuration).abs() > 3) {
            return false;
          }
          if (_normalizeIdentityMetadata(candidate.title) != canonicalTitle ||
              _normalizeIdentityMetadata(candidate.artistName ?? '') !=
                  canonicalArtist ||
              _normalizeIdentityMetadata(candidate.albumName ?? '') !=
                  canonicalAlbum) {
            return false;
          }
          return _positionsCompatible(
                canonicalSong.track,
                candidate.track,
              ) &&
              _positionsCompatible(
                canonicalSong.discNumber,
                candidate.discNumber,
              );
        })
        .toList(growable: false);
    if (metadataMatches.length == 1) {
      return SongIdentityMatched(
        provisionalSong: metadataMatches.single,
        reason: SongIdentityMatchReason.exactMetadata,
      );
    }
    if (metadataMatches.length > 1) {
      return SongIdentityAmbiguous(
        candidateCount: metadataMatches.length,
        reason: SongIdentityMatchReason.exactMetadata,
      );
    }
    return const SongIdentityUnmatched();
  }

  Future<SongIdentityReconciliationSummary> reconcileCanonicalSongs(
    Iterable<SongsTableData> canonicalSongs,
  ) async {
    final session = await startSession();
    await session.reconcile(canonicalSongs);
    return session.summary;
  }

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

  String? _normalizeMbid(String? value) {
    final normalized = value?.trim().toLowerCase();
    return normalized == null || normalized.isEmpty ? null : normalized;
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
class SongIdentityReconciliationSession {
  SongIdentityReconciliationSession._(this._reconciler, this._index);

  final SongIdentityReconciler _reconciler;
  final _ProvisionalIdentityIndex _index;
  final List<SongIdentityAlias> _aliases = <SongIdentityAlias>[];
  var _canonicalized = 0;
  var _ambiguous = 0;

  SongIdentityReconciliationSummary get summary =>
      SongIdentityReconciliationSummary(
        aliases: List<SongIdentityAlias>.unmodifiable(_aliases),
        canonicalizedSongCount: _canonicalized,
        ambiguousMatchCount: _ambiguous,
        retainedProvisionalCount: _index.remainingCount,
      );

  Future<void> reconcile(Iterable<SongsTableData> canonicalSongs) async {
    for (final canonicalSong in canonicalSongs) {
      final result = _index.match(canonicalSong);
      switch (result) {
        case SongIdentityMatched():
          if (result.reason == SongIdentityMatchReason.sameId) {
            await _reconciler._identityDao.markCanonical(canonicalSong.id);
          } else {
            final oldSongId = result.provisionalSong.id;
            final wasActive = _reconciler.readActiveSongId?.call() == oldSongId;
            await _reconciler.onBeforeRemap?.call(<String, String>{
              oldSongId: canonicalSong.id,
            });
            final remap = await _reconciler._identityDao.remapSongIdentity(
              oldSongId: oldSongId,
              canonicalSongId: canonicalSong.id,
              matchReason: result.reason.name,
              retainOldCacheFile: wasActive,
            );
            _aliases.add(remap.alias);
          }
          _index.remove(result.provisionalSong);
          _canonicalized++;
        case SongIdentityAmbiguous():
          _ambiguous++;
        case SongIdentityUnmatched():
          break;
      }
    }
  }
}

class _ProvisionalIdentityIndex {
  _ProvisionalIdentityIndex(
    this._reconciler,
    Iterable<SongsTableData> songs,
  ) {
    for (final song in songs) {
      _remaining[song.id] = song;
      final mbid = _reconciler._normalizeMbid(song.recordingMbid);
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
    final mbid = _reconciler._normalizeMbid(canonicalSong.recordingMbid);
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
