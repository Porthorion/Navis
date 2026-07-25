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
  const SongIdentityReconciler(this._identityDao);

  final SongIdentityDao _identityDao;

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
    final provisional = await _identityDao.getProvisionalSongs();
    if (provisional.isEmpty) {
      return const SongIdentityReconciliationSummary();
    }

    final remaining = <String, SongsTableData>{
      for (final song in provisional) song.id: song,
    };
    final aliases = <SongIdentityAlias>[];
    var canonicalized = 0;
    var ambiguous = 0;
    for (final canonicalSong in canonicalSongs) {
      final result = matchCanonicalSong(
        canonicalSong: canonicalSong,
        provisionalSongs: remaining.values.toList(growable: false),
      );
      switch (result) {
        case SongIdentityMatched():
          if (result.reason == SongIdentityMatchReason.sameId) {
            await _identityDao.markCanonical(canonicalSong.id);
          } else {
            final remap = await _identityDao.remapSongIdentity(
              oldSongId: result.provisionalSong.id,
              canonicalSongId: canonicalSong.id,
              matchReason: result.reason.name,
            );
            aliases.add(remap.alias);
          }
          remaining.remove(result.provisionalSong.id);
          canonicalized++;
        case SongIdentityAmbiguous():
          ambiguous++;
        case SongIdentityUnmatched():
          break;
      }
    }

    return SongIdentityReconciliationSummary(
      aliases: aliases,
      canonicalizedSongCount: canonicalized,
      ambiguousMatchCount: ambiguous,
      retainedProvisionalCount: remaining.length,
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
