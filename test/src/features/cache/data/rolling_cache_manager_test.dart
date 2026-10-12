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
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  group('RollingCacheManager', () {
    late NavisDatabase database;
    late RollingCacheManager manager;
    late Directory tempDir;

    setUp(() async {
      database = NavisDatabase(NativeDatabase.memory());
      tempDir = Directory.systemTemp.createTempSync('navis_rolling_cache_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            pathProviderChannel,
            (call) async => tempDir.path,
          );
      manager = RollingCacheManager(
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
      await database.libraryDao.upsertProvisionalSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(id: 'remote-song', title: 'Song'),
      ]);
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
        manager = RollingCacheManager(
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

      await _seedCachedTrack(
        database,
        'song-1',
        file1.path,
        100,
        lastAccessedAt: DateTime.now().subtract(const Duration(hours: 3)),
      );
      await _seedCachedTrack(
        database,
        'song-2',
        file2.path,
        100,
        lastAccessedAt: DateTime.now().subtract(const Duration(hours: 2)),
      );
      await _seedCachedTrack(
        database,
        'song-3',
        file3.path,
        100,
        cacheType: CacheType.permanent,
        lastAccessedAt: DateTime.now().subtract(const Duration(hours: 1)),
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

      await _seedCachedTrack(
        database,
        'song-1',
        p.join(tempDir.path, 'missing.mp3'),
        50,
      );
      await _seedCachedTrack(database, 'song-2', keepFile.path, 32);

      await manager.pruneMissingFiles();

      expect(await database.cacheDao.getCachedTrack('song-1'), isNull);
      expect(await database.cacheDao.getCachedTrack('song-2'), isNotNull);
    }, skip: !sqliteAvailable);

    test('registerTrack discards a cached server error document', () async {
      for (final (index, document) in _errorDocuments.indexed) {
        final songId = 'error-song-$index';
        await _insertSong(database, songId);
        final file = File(p.join(tempDir.path, '$songId.flac'));
        await file.writeAsString(document);
        final mime = File('${file.path}.mime');
        await mime.writeAsString('application/json');

        await manager.registerTrack(
          songId: songId,
          filePath: file.path,
          format: 'flac',
        );

        expect(await database.cacheDao.getCachedTrack(songId), isNull);
        expect(file.existsSync(), isFalse);
        expect(mime.existsSync(), isFalse);
      }
    }, skip: !sqliteAvailable);

    test('pruneMissingFiles removes error documents cached as audio', () async {
      await _insertSong(database, 'poisoned');
      await _insertSong(database, 'audio');
      final poisoned = File(p.join(tempDir.path, 'poisoned.flac'));
      await poisoned.writeAsString(_errorDocuments.first);
      final audio = await _writeFile(tempDir, 'audio.flac', 32);
      for (final (songId, file) in [('poisoned', poisoned), ('audio', audio)]) {
        await _seedCachedTrack(
          database,
          songId,
          file.path,
          file.lengthSync(),
          format: 'flac',
        );
      }

      await manager.pruneMissingFiles();

      expect(await database.cacheDao.getCachedTrack('poisoned'), isNull);
      expect(poisoned.existsSync(), isFalse);
      expect(await database.cacheDao.getCachedTrack('audio'), isNotNull);
      expect(audio.existsSync(), isTrue);
    }, skip: !sqliteAvailable);

    test('touchTrack bumps lastAccessedAt', () async {
      await _insertSong(database, 'song-1');
      final file = await _writeFile(tempDir, 'song-1.mp3', 24);
      final oldDate = DateTime.now().subtract(const Duration(days: 2));

      await _seedCachedTrack(
        database,
        'song-1',
        file.path,
        24,
        lastAccessedAt: oldDate,
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
        await _seedCachedTrack(
          database,
          'retained-song',
          retainedAudio.path,
          1,
        );

        await manager.cleanupOrphanedRollingFiles();

        expect(orphanSidecar.existsSync(), isFalse);
        expect(retainedSidecar.existsSync(), isTrue);
      },
      skip: !sqliteAvailable,
    );

    test('cleanup protects recently active orphan audio files', () async {
      final rollingDirectory = Directory(
        p.join(tempDir.path, 'audio', 'rolling'),
      )..createSync(recursive: true);
      final activeOrphan = File(p.join(rollingDirectory.path, 'active.audio'))
        ..writeAsBytesSync(<int>[1, 2, 3]);

      await manager.cleanupOrphanedRollingFiles();

      expect(activeOrphan.existsSync(), isTrue);
    }, skip: !sqliteAvailable);

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
        await database.libraryDao.upsertProvisionalSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'remote-song',
            title: 'Song',
            albumId: const Value('remote-album'),
            artistId: const Value('remote-artist'),
          ),
        ]);
        final file = await _writeFile(tempDir, 'remote.mp3', 100);
        await _seedCachedTrack(database, 'remote-song', file.path, 100);

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

/// What Navidrome sends with HTTP 200 for a stream it cannot serve.
const _errorDocuments = <String>[
  '{"subsonic-response":{"status":"failed","version":"1.16.1",'
      '"type":"navidrome","error":{"code":70,"message":"data not found"}}}',
  '<?xml version="1.0" encoding="UTF-8"?>'
      '<subsonic-response xmlns="http://subsonic.org/restapi" '
      'status="failed" version="1.16.1">'
      '<error code="70" message="data not found"/></subsonic-response>',
];

Future<void> _insertSong(NavisDatabase database, String id) {
  return database.libraryDao.upsertSongs(<SongsTableCompanion>[
    SongsTableCompanion.insert(id: id, title: id),
  ]);
}

Future<File> _writeFile(Directory dir, String name, int size) async {
  final file = File(p.join(dir.path, name));
  await file.writeAsBytes(List<int>.filled(size, 7));
  return file;
}

Future<void> _seedCachedTrack(
  NavisDatabase database,
  String songId,
  String filePath,
  int fileSize, {
  String format = 'mp3',
  CacheType cacheType = CacheType.rolling,
  DateTime? lastAccessedAt,
}) {
  return database.cacheDao.upsertCachedTrack(
    CachedTracksTableCompanion.insert(
      songId: songId,
      filePath: filePath,
      fileSize: fileSize,
      format: format,
      cacheType: cacheType,
      downloadStatus: DownloadStatus.complete,
      lastAccessedAt: lastAccessedAt ?? DateTime.now(),
    ),
  );
}
