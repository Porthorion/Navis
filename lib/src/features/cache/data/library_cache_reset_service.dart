import 'dart:io';

import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';

/// Clears the recoverable, server-derived local library state while retaining
/// permanent downloads, account credentials, and device settings.
class LibraryCacheResetService {
  new({required this._database, this._clearCoverArt});

  final NavisDatabase _database;
  final Future<void> Function()? _clearCoverArt;

  Future<void> reset() async {
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
    await _database.libraryDao.clearLibraryData();
  }
}
