import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/cache/data/rolling_cache_manager.dart';
import 'package:path/path.dart' as p;
import '../../../../helpers/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel(
    'plugins.flutter.io/path_provider',
  );

  group('DriftRollingCacheManager', () {
    late NavisDatabase database;
    late DriftRollingCacheManager manager;
    late Directory tempDir;

    setUp(() async {
      database = NavisDatabase(NativeDatabase.memory());
      tempDir = Directory.systemTemp.createTempSync('navis_rolling_cache_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            pathProviderChannel,
            (call) async => tempDir.path,
          );
      manager = DriftRollingCacheManager(
        cacheDao: database.cacheDao,
        songIdentityDao: database.songIdentityDao,
      );
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, null);
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
    }, skip: !sqliteAvailable);

    test('registerTrack resolves a retired song identity', () async {
      await database.libraryDao.upsertProvisionalSongs(
        <SongsTableCompanion>[
          SongsTableCompanion.insert(id: 'remote-song', title: 'Song'),
        ],
      );
      await _insertSong(database, 'server-song');
      await database.songIdentityDao.remapSongIdentity(
        oldSongId: 'remote-song',
        canonicalSongId: 'server-song',
        matchReason: 'recordingMbid',
      );
      final file = File(p.join(tempDir.path, 'remote-song.mp3'));
      await file.writeAsBytes(List<int>.filled(64, 1));

      await manager.registerTrack(
        songId: 'remote-song',
        filePath: file.path,
        format: 'mp3',
      );

      expect(await database.cacheDao.getCachedTrack('remote-song'), isNull);
      expect(
        (await database.cacheDao.getCachedTrack('server-song'))?.filePath,
        file.path,
      );
    }, skip: !sqliteAvailable);

    test(
      'pruneMissingPermanentFiles preserves a reachable SAF document',
      () async {
        await _insertSong(database, 'saf-song');
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'saf-song',
            filePath: 'content://navis.test/document/root%3Asaf-song.flac',
            storageKind: const Value('androidSaf'),
            fileSize: 64,
            format: 'flac',
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );
        manager = DriftRollingCacheManager(
          cacheDao: database.cacheDao,
          songIdentityDao: database.songIdentityDao,
          entryExists: (entry) async => entry.storageKind == 'androidSaf',
        );

        await manager.pruneMissingPermanentFiles();

        expect(await database.cacheDao.getCachedTrack('saf-song'), isNotNull);
      },
      skip: !sqliteAvailable,
    );

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
    }, skip: !sqliteAvailable);

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
    }, skip: !sqliteAvailable);

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
    }, skip: !sqliteAvailable);

    test(
      'cleanup removes orphaned MIME sidecars without audio or DB rows',
      () async {
        final rollingDirectory = Directory(
          p.join(tempDir.path, 'audio', 'rolling'),
        )..createSync(recursive: true);
        final orphanSidecar = File(
          p.join(rollingDirectory.path, 'orphan.audio.mime'),
        )..writeAsStringSync('audio/mpeg');
        final retainedAudio = File(
          p.join(rollingDirectory.path, 'retained.audio'),
        )..writeAsBytesSync(<int>[1]);
        final retainedSidecar = File('${retainedAudio.path}.mime')
          ..writeAsStringSync('audio/mpeg');
        await _insertSong(database, 'retained-song');
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'retained-song',
            filePath: retainedAudio.path,
            fileSize: 1,
            format: 'mp3',
            cacheType: CacheType.rolling,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );

        await manager.cleanupOrphanedRollingFiles();

        expect(orphanSidecar.existsSync(), isFalse);
        expect(retainedSidecar.existsSync(), isTrue);
      },
      skip: !sqliteAvailable,
    );

    test(
      'cleanup protects recently active orphan audio files',
      () async {
        final rollingDirectory = Directory(
          p.join(tempDir.path, 'audio', 'rolling'),
        )..createSync(recursive: true);
        final activeOrphan = File(
          p.join(rollingDirectory.path, 'active.audio'),
        )..writeAsBytesSync(<int>[1, 2, 3]);

        await manager.cleanupOrphanedRollingFiles();

        expect(activeOrphan.existsSync(), isTrue);
      },
      skip: !sqliteAvailable,
    );

    test(
      'eviction garbage-collects unreferenced provisional metadata',
      () async {
        await database.libraryDao.upsertProvisionalArtists(
          <ArtistsTableCompanion>[
            ArtistsTableCompanion.insert(id: 'remote-artist', name: 'Artist'),
          ],
        );
        await database.libraryDao.upsertProvisionalAlbums(
          <AlbumsTableCompanion>[
            AlbumsTableCompanion.insert(
              id: 'remote-album',
              name: 'Album',
              artistId: const Value('remote-artist'),
            ),
          ],
        );
        await database.libraryDao.upsertProvisionalSongs(
          <SongsTableCompanion>[
            SongsTableCompanion.insert(
              id: 'remote-song',
              title: 'Song',
              albumId: const Value('remote-album'),
              artistId: const Value('remote-artist'),
            ),
          ],
        );
        final file = await _writeFile(tempDir, 'remote.mp3', 100);
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'remote-song',
            filePath: file.path,
            fileSize: 100,
            format: 'mp3',
            cacheType: CacheType.rolling,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );

        await manager.enforceBudget(maxBytes: 1);

        expect(await database.libraryDao.getSongById('remote-song'), isNull);
        expect(await database.libraryDao.getAlbumById('remote-album'), isNull);
        expect(
          await database.libraryDao.getArtistById('remote-artist'),
          isNull,
        );
      },
      skip: !sqliteAvailable,
    );
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
