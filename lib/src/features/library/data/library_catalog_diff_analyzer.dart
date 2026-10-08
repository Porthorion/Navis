import 'dart:async';
import 'dart:io';

import 'package:navis/src/database/navis_database.dart';

class CatalogDiffStats {
  const new({
    required this.artistChangedCount,
    required this.artistUnchangedCount,
    required this.albumChangedCount,
    required this.albumUnchangedCount,
    required this.songChangedCount,
    required this.songUnchangedCount,
    required this.pageCount,
    required this.maximumPageSize,
    required this.duration,
    required this.rssGrowthBytes,
    required this.maximumPageLatency,
  });

  final int artistChangedCount;
  final int artistUnchangedCount;
  final int albumChangedCount;
  final int albumUnchangedCount;
  final int songChangedCount;
  final int songUnchangedCount;
  final int pageCount;
  final int maximumPageSize;
  final Duration duration;
  final int rssGrowthBytes;
  final Duration maximumPageLatency;

  int get changedCount =>
      artistChangedCount + albumChangedCount + songChangedCount;
  int get unchangedCount =>
      artistUnchangedCount + albumUnchangedCount + songUnchangedCount;
}

/// Classifies a hidden candidate catalog before the short atomic promotion.
///
/// Classification is durable and intentionally runs outside the final apply
/// transaction. A process restart resumes from the first unclassified row.
class LibraryCatalogDiffAnalyzer {
  const new(
    this._database, {
    this.readActivePlayback,
    this.initialPageSize = 384,
    this.minimumPageSize = 96,
  });

  final NavisDatabase _database;
  final bool Function()? readActivePlayback;
  final int initialPageSize;
  final int minimumPageSize;

  Future<CatalogDiffStats> analyze({
    required int serverId,
    required int generation,
  }) async {
    final startedRss = ProcessInfo.currentRss;
    final stopwatch = Stopwatch()..start();
    var pageSize = initialPageSize;
    var pageCount = 0;
    var maximumPageSize = 0;
    var maximumPageLatency = Duration.zero;
    Future<void> afterPage(Stopwatch pageWatch, int count) async {
      pageCount++;
      if (count > maximumPageSize) {
        maximumPageSize = count;
      }
      final latency = pageWatch.elapsed;
      if (latency > maximumPageLatency) {
        maximumPageLatency = latency;
      }
      final playbackActive = readActivePlayback?.call() ?? false;
      if (latency > const Duration(milliseconds: 100)) {
        pageSize = (pageSize ~/ 2).clamp(minimumPageSize, initialPageSize);
      } else if (latency < Duration(milliseconds: playbackActive ? 80 : 40)) {
        pageSize = (pageSize * 2).clamp(minimumPageSize, initialPageSize);
      }
      await Future<void>.delayed(Duration.zero);
    }

    Future<(int, int)> classifyKind<C, E>({
      required Future<List<C>> Function({
        required int serverId,
        required int generation,
        required int limit,
      })
      read,
      required Future<List<E>> Function(Iterable<String>) readExisting,
      required String Function(C) candidateId,
      required String Function(E) existingId,
      required bool Function(C, E?) needsApply,
      required Future<void> Function({
        required int serverId,
        required int generation,
        required Iterable<String> changedIds,
        required Iterable<String> unchangedIds,
      })
      classify,
    }) async {
      var changedCount = 0;
      var unchangedCount = 0;
      while (true) {
        final pageWatch = Stopwatch()..start();
        final candidates = await read(
          serverId: serverId,
          generation: generation,
          limit: pageSize,
        );
        if (candidates.isEmpty) break;
        final existing = await readExisting(candidates.map(candidateId));
        final existingById = {for (final row in existing) existingId(row): row};
        final changed = <String>[];
        final unchanged = <String>[];
        for (final candidate in candidates) {
          final id = candidateId(candidate);
          (needsApply(candidate, existingById[id]) ? changed : unchanged).add(
            id,
          );
        }
        await classify(
          serverId: serverId,
          generation: generation,
          changedIds: changed,
          unchangedIds: unchanged,
        );
        changedCount += changed.length;
        unchangedCount += unchanged.length;
        await afterPage(pageWatch, candidates.length);
      }
      return (changedCount, unchangedCount);
    }

    final (artistChanged, artistUnchanged) = await classifyKind(
      read: _database.librarySyncCandidateDao.getUnclassifiedArtists,
      readExisting: _database.libraryDao.getArtistsByIds,
      candidateId: (row) => row.id,
      existingId: (row) => row.id,
      needsApply: artistNeedsApply,
      classify: _database.librarySyncCandidateDao.classifyArtists,
    );

    final (albumChanged, albumUnchanged) = await classifyKind(
      read: _database.librarySyncCandidateDao.getUnclassifiedAlbums,
      readExisting: _database.libraryDao.getAlbumsByIds,
      candidateId: (row) => row.id,
      existingId: (row) => row.id,
      needsApply: albumNeedsApply,
      classify: _database.librarySyncCandidateDao.classifyAlbums,
    );

    final (songChanged, songUnchanged) = await classifyKind(
      read: _database.librarySyncCandidateDao.getUnclassifiedSongs,
      readExisting: _database.libraryDao.getSongsByIds,
      candidateId: (row) => row.id,
      existingId: (row) => row.id,
      needsApply: songNeedsApply,
      classify: _database.librarySyncCandidateDao.classifySongs,
    );

    stopwatch.stop();
    return CatalogDiffStats(
      artistChangedCount: artistChanged,
      artistUnchangedCount: artistUnchanged,
      albumChangedCount: albumChanged,
      albumUnchangedCount: albumUnchanged,
      songChangedCount: songChanged,
      songUnchangedCount: songUnchanged,
      pageCount: pageCount,
      maximumPageSize: maximumPageSize,
      duration: stopwatch.elapsed,
      rssGrowthBytes: ProcessInfo.currentRss - startedRss,
      maximumPageLatency: maximumPageLatency,
    );
  }

  static bool artistNeedsApply(
    LibrarySyncCandidateArtistsTableData candidate,
    ArtistsTableData? existing,
  ) {
    return existing == null ||
        existing.isProvisional ||
        existing.name != candidate.name ||
        existing.albumCount != candidate.albumCount ||
        existing.coverArt != candidate.coverArt ||
        existing.artistMbid != candidate.artistMbid ||
        // A previously absent row the server re-lists must be rewritten so
        // the stale availability marker clears with snapshot evidence.
        existing.catalogAvailability != null;
  }

  static bool albumNeedsApply(
    LibrarySyncCandidateAlbumsTableData candidate,
    AlbumsTableData? existing,
  ) {
    return existing == null ||
        existing.isProvisional ||
        existing.name != candidate.name ||
        existing.artistId != candidate.artistId ||
        existing.artistName != candidate.artistName ||
        !_artistListsEqual(existing.artists, candidate.artists) ||
        existing.songCount != candidate.songCount ||
        existing.duration != candidate.duration ||
        existing.year != candidate.year ||
        existing.coverArt != candidate.coverArt ||
        existing.songsHydrated != candidate.songsHydrated ||
        existing.playCount != candidate.playCount ||
        existing.releaseMbid != candidate.releaseMbid ||
        existing.catalogAvailability != null ||
        (candidate.serverCreatedAt != null &&
            existing.serverCreatedAt != candidate.serverCreatedAt);
  }

  static bool songNeedsApply(
    LibrarySyncCandidateSongsTableData candidate,
    SongsTableData? existing,
  ) {
    return existing == null ||
        existing.isProvisional ||
        existing.serverDeletedAt != null ||
        existing.catalogAvailability != null ||
        existing.title != candidate.title ||
        existing.albumId != candidate.albumId ||
        existing.artistId != candidate.artistId ||
        existing.artistName != candidate.artistName ||
        existing.albumName != candidate.albumName ||
        existing.track != candidate.track ||
        existing.discNumber != candidate.discNumber ||
        existing.duration != candidate.duration ||
        existing.bitRate != candidate.bitRate ||
        existing.sampleRate != candidate.sampleRate ||
        existing.contentType != candidate.contentType ||
        existing.suffix != candidate.suffix ||
        existing.size != candidate.size ||
        existing.coverArt != candidate.coverArt ||
        existing.recordingMbid != candidate.recordingMbid ||
        existing.playCount != candidate.playCount ||
        existing.createdAt != candidate.createdAt ||
        existing.replayGainTrackGain != candidate.replayGainTrackGain ||
        existing.replayGainAlbumGain != candidate.replayGainAlbumGain ||
        existing.replayGainTrackPeak != candidate.replayGainTrackPeak ||
        existing.replayGainAlbumPeak != candidate.replayGainAlbumPeak;
  }

  static bool _artistListsEqual(List<Object> left, List<Object> right) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }
}
