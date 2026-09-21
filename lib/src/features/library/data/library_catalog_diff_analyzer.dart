import 'dart:async';
import 'dart:io';

import 'package:navis/src/database/navis_database.dart';

class CatalogDiffStats {
  const CatalogDiffStats({
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
  const LibraryCatalogDiffAnalyzer(
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
    var artistChanged = 0;
    var artistUnchanged = 0;
    var albumChanged = 0;
    var albumUnchanged = 0;
    var songChanged = 0;
    var songUnchanged = 0;

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

    while (true) {
      final pageWatch = Stopwatch()..start();
      final candidates = await _database.librarySyncCandidateDao
          .getUnclassifiedArtists(
            serverId: serverId,
            generation: generation,
            limit: pageSize,
          );
      if (candidates.isEmpty) {
        break;
      }
      final existing = await _database.libraryDao.getArtistsByIds(
        candidates.map((row) => row.id),
      );
      final existingById = <String, ArtistsTableData>{
        for (final row in existing) row.id: row,
      };
      final changed = <String>[];
      final unchanged = <String>[];
      for (final candidate in candidates) {
        if (artistNeedsApply(candidate, existingById[candidate.id])) {
          changed.add(candidate.id);
        } else {
          unchanged.add(candidate.id);
        }
      }
      await _database.librarySyncCandidateDao.classifyArtists(
        serverId: serverId,
        generation: generation,
        changedIds: changed,
        unchangedIds: unchanged,
      );
      artistChanged += changed.length;
      artistUnchanged += unchanged.length;
      await afterPage(pageWatch, candidates.length);
    }

    while (true) {
      final pageWatch = Stopwatch()..start();
      final candidates = await _database.librarySyncCandidateDao
          .getUnclassifiedAlbums(
            serverId: serverId,
            generation: generation,
            limit: pageSize,
          );
      if (candidates.isEmpty) {
        break;
      }
      final existing = await _database.libraryDao.getAlbumsByIds(
        candidates.map((row) => row.id),
      );
      final existingById = <String, AlbumsTableData>{
        for (final row in existing) row.id: row,
      };
      final changed = <String>[];
      final unchanged = <String>[];
      for (final candidate in candidates) {
        if (albumNeedsApply(candidate, existingById[candidate.id])) {
          changed.add(candidate.id);
        } else {
          unchanged.add(candidate.id);
        }
      }
      await _database.librarySyncCandidateDao.classifyAlbums(
        serverId: serverId,
        generation: generation,
        changedIds: changed,
        unchangedIds: unchanged,
      );
      albumChanged += changed.length;
      albumUnchanged += unchanged.length;
      await afterPage(pageWatch, candidates.length);
    }

    while (true) {
      final pageWatch = Stopwatch()..start();
      final candidates = await _database.librarySyncCandidateDao
          .getUnclassifiedSongs(
            serverId: serverId,
            generation: generation,
            limit: pageSize,
          );
      if (candidates.isEmpty) {
        break;
      }
      final existing = await _database.libraryDao.getSongsByIds(
        candidates.map((row) => row.id),
      );
      final existingById = <String, SongsTableData>{
        for (final row in existing) row.id: row,
      };
      final changed = <String>[];
      final unchanged = <String>[];
      for (final candidate in candidates) {
        if (songNeedsApply(candidate, existingById[candidate.id])) {
          changed.add(candidate.id);
        } else {
          unchanged.add(candidate.id);
        }
      }
      await _database.librarySyncCandidateDao.classifySongs(
        serverId: serverId,
        generation: generation,
        changedIds: changed,
        unchangedIds: unchanged,
      );
      songChanged += changed.length;
      songUnchanged += unchanged.length;
      await afterPage(pageWatch, candidates.length);
    }

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
        existing.genre != candidate.genre ||
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
