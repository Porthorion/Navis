import 'dart:io';

import 'package:drift/drift.dart';
import 'package:navis/src/database/daos/play_queue_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';

/// Clears the recoverable, server-derived local library state while retaining
/// permanent downloads, account credentials, and device settings.
class LibraryCacheResetService {
  new({
    required this._database,
    this._clearCoverArt,
    this._clearIntegrationMatches,
  });

  final NavisDatabase _database;
  final Future<void> Function()? _clearCoverArt;
  final Future<void> Function()? _clearIntegrationMatches;

  /// Returns a flow-owned saved queue to restore only after a successful scan.
  Future<LibraryCacheQueueSnapshot?> reset() async {
    final rollingTracks = await _database.cacheDao
        .watchCachedTracksByType(CacheType.rolling)
        .first;
    for (final track in rollingTracks) {
      for (final suffix in <String>['', '.part', '.mime']) {
        try {
          final file = File('${track.filePath}$suffix');
          if (file.existsSync()) {
            await file.delete();
          }
        } on FileSystemException {
          // Cache cleanup is best-effort; remove the database entry below so
          // the source resolver never treats a missing file as usable.
        }
      }
    }
    if (rollingTracks.isNotEmpty) {
      await _database.cacheDao.deleteCachedTracksBySongIds(
        rollingTracks.map((track) => track.songId),
      );
    }
    await _clearCoverArt?.call();
    final snapshot = await _database.transaction(() async {
      final state = await _database.playQueueDao.getQueueState();
      final entries = await _database.playQueueDao.getQueueEntries();
      final snapshot = state == null || entries.isEmpty
          ? null
          : LibraryCacheQueueSnapshot._(_database, state, [
              for (final entry in entries)
                (songId: entry.song.id, originalOrder: entry.originalOrder),
            ]);
      // Song deletion cascades to queue items. Clear the header too so a
      // failed scan cannot leave a stale current index and resume position.
      await _database.playQueueDao.clearQueue();
      await _database.libraryDao.clearLibraryData();
      return snapshot;
    });
    await _clearIntegrationMatches?.call();
    return snapshot;
  }
}

/// An in-memory queue snapshot owned by one cache reset and scan flow.
class LibraryCacheQueueSnapshot {
  new _(this._database, this._state, this._entries);

  final NavisDatabase _database;
  final PlayQueueTableData _state;
  final List<({String songId, int? originalOrder})> _entries;

  /// Restores surviving occurrences without loading or changing live playback.
  Future<void> restore() => _database.transaction(() async {
    // A live handler may have saved a new queue while the scan was running.
    // Its latest queue takes precedence over the pre-reset snapshot.
    if ((await _database.playQueueDao.getQueueEntries()).isNotEmpty) return;
    final existingIds = <String>{};
    final ids = _entries.map((entry) => entry.songId).toSet().toList();
    for (var offset = 0; offset < ids.length; offset += 500) {
      final songs = await (_database.select(
        _database.songsTable,
      )..where((table) => table.id.isIn(ids.skip(offset).take(500)))).get();
      existingIds.addAll(songs.map((song) => song.id));
    }
    final survivingIndices = [
      for (var i = 0; i < _entries.length; i++)
        if (existingIds.contains(_entries[i].songId)) i,
    ];
    if (survivingIndices.isEmpty) {
      await _database.playQueueDao.clearQueue();
      return;
    }
    // Preserve the current occurrence, including repeated song IDs. State-only
    // writes from a live handler still refer to the pre-reset queue order.
    final state = await _database.playQueueDao.getQueueState() ?? _state;
    final oldIndex = state.currentIndex;
    final currentIndex = oldIndex == null
        ? null
        : survivingIndices.contains(oldIndex)
        ? survivingIndices.indexOf(oldIndex)
        : oldIndex.clamp(0, survivingIndices.length - 1);
    await _database.playQueueDao.saveQueue(
      songIds: [for (final i in survivingIndices) _entries[i].songId],
      currentIndex: currentIndex,
      shuffleMode: state.shuffleMode,
      repeatMode: state.repeatMode,
      positionMs: state.positionMs,
      originalOrder:
          survivingIndices.every((i) => _entries[i].originalOrder != null)
          ? [for (final i in survivingIndices) _entries[i].originalOrder!]
          : null,
    );
    // Keep each nullable original rank exactly as saved, including legacy rows.
    if (survivingIndices.any((i) => _entries[i].originalOrder == null)) {
      await _database.batch((batch) {
        for (var i = 0; i < survivingIndices.length; i++) {
          final originalOrder = _entries[survivingIndices[i]].originalOrder;
          if (originalOrder == null) continue;
          batch.update(
            _database.playQueueItemsTable,
            PlayQueueItemsTableCompanion(originalOrder: Value(originalOrder)),
            where: (table) =>
                table.queueId.equals(PlayQueueDao.primaryQueueId) &
                table.sortOrder.equals(i),
          );
        }
      });
    }
  });
}
