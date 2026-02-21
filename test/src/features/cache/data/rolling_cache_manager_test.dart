import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/cache/data/rolling_cache_manager.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

bool get _sqliteAvailable {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } on Object {
    return false;
  }
}

void main() {
  group('DriftRollingCacheManager', () {
    late NavisDatabase database;
    late DriftRollingCacheManager manager;
    late Directory tempDir;

    setUp(() {
      database = NavisDatabase(NativeDatabase.memory());
      manager = DriftRollingCacheManager(cacheDao: database.cacheDao);
      tempDir = Directory.systemTemp.createTempSync('navis_rolling_cache_');
    });

    tearDown(() async {
      await database.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('registerTrack upserts rolling cache metadata', () async {
      await _insertSong(database, 'song-1');
      final file = File(p.join(tempDir.path, 'song-1.mp3'));
      await file.writeAsBytes(List<int>.filled(64, 1));

      await manager.registerTrack(
        songId: 'song-1',
        filePath: file.path,
        format: 'mp3',
      );

      final row = await database.cacheDao.getCachedTrack('song-1');
      expect(row, isNotNull);
      expect(row!.cacheType, CacheType.rolling);
      expect(row.fileSize, 64);
      expect(row.format, 'mp3');
      expect(row.downloadStatus, DownloadStatus.complete);
    }, skip: !_sqliteAvailable);

    test('enforceBudget evicts oldest rolling items only', () async {
      await _insertSong(database, 'song-1');
      await _insertSong(database, 'song-2');
      await _insertSong(database, 'song-3');

      final file1 = await _writeFile(tempDir, 'song-1.mp3', 100);
      final file2 = await _writeFile(tempDir, 'song-2.mp3', 100);
      final file3 = await _writeFile(tempDir, 'song-3.mp3', 100);

      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'song-1',
          filePath: file1.path,
          fileSize: 100,
          format: 'mp3',
          cacheType: CacheType.rolling,
          downloadStatus: DownloadStatus.complete,
          lastAccessedAt: DateTime.now().subtract(const Duration(hours: 3)),
        ),
      );
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'song-2',
          filePath: file2.path,
          fileSize: 100,
          format: 'mp3',
          cacheType: CacheType.rolling,
          downloadStatus: DownloadStatus.complete,
          lastAccessedAt: DateTime.now().subtract(const Duration(hours: 2)),
        ),
      );
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'song-3',
          filePath: file3.path,
          fileSize: 100,
          format: 'mp3',
          cacheType: CacheType.permanent,
          downloadStatus: DownloadStatus.complete,
          lastAccessedAt: DateTime.now().subtract(const Duration(hours: 1)),
        ),
      );

      await manager.enforceBudget(maxBytes: 150);

      expect(await database.cacheDao.getCachedTrack('song-1'), isNull);
      expect(await database.cacheDao.getCachedTrack('song-2'), isNotNull);
      expect(await database.cacheDao.getCachedTrack('song-3'), isNotNull);

      expect(file1.existsSync(), isFalse);
      expect(file2.existsSync(), isTrue);
      expect(file3.existsSync(), isTrue);
    }, skip: !_sqliteAvailable);

    test('pruneMissingFiles drops stale rolling entries', () async {
      await _insertSong(database, 'song-1');
      await _insertSong(database, 'song-2');
      final keepFile = await _writeFile(tempDir, 'song-2.mp3', 32);

      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'song-1',
          filePath: p.join(tempDir.path, 'missing.mp3'),
          fileSize: 50,
          format: 'mp3',
          cacheType: CacheType.rolling,
          downloadStatus: DownloadStatus.complete,
          lastAccessedAt: DateTime.now(),
        ),
      );
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'song-2',
          filePath: keepFile.path,
          fileSize: 32,
          format: 'mp3',
          cacheType: CacheType.rolling,
          downloadStatus: DownloadStatus.complete,
          lastAccessedAt: DateTime.now(),
        ),
      );

      await manager.pruneMissingFiles();

      expect(await database.cacheDao.getCachedTrack('song-1'), isNull);
      expect(await database.cacheDao.getCachedTrack('song-2'), isNotNull);
    }, skip: !_sqliteAvailable);

    test('touchTrack bumps lastAccessedAt', () async {
      await _insertSong(database, 'song-1');
      final file = await _writeFile(tempDir, 'song-1.mp3', 24);
      final oldDate = DateTime.now().subtract(const Duration(days: 2));

      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'song-1',
          filePath: file.path,
          fileSize: 24,
          format: 'mp3',
          cacheType: CacheType.rolling,
          downloadStatus: DownloadStatus.complete,
          lastAccessedAt: oldDate,
        ),
      );

      await manager.touchTrack('song-1');

      final row = await database.cacheDao.getCachedTrack('song-1');
      expect(row, isNotNull);
      expect(row!.lastAccessedAt.isAfter(oldDate), isTrue);
    }, skip: !_sqliteAvailable);
  });
}

Future<void> _insertSong(NavisDatabase database, String id) {
  return database.libraryDao.upsertSongs(
    <SongsTableCompanion>[
      SongsTableCompanion.insert(
        id: id,
        title: id,
      ),
    ],
  );
}

Future<File> _writeFile(Directory dir, String name, int size) async {
  final file = File(p.join(dir.path, name));
  await file.writeAsBytes(List<int>.filled(size, 7));
  return file;
}
