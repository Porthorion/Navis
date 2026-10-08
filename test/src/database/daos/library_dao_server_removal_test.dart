import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:path/path.dart' as p;

import '../../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;
  late Directory directory;
  late File audio;

  setUp(() async {
    database = createTestDatabase();
    directory = await Directory.systemTemp.createTemp('navis_removal_');
    audio = File(p.join(directory.path, 'song.mp3'));
    await audio.writeAsBytes([1, 2, 3]);
    await database.libraryDao.upsertAlbums([
      AlbumsTableCompanion.insert(id: 'album', name: 'Album'),
    ]);
    await database.libraryDao.upsertSongs([
      SongsTableCompanion.insert(
        id: 'song',
        title: 'Song',
        albumId: const Value('album'),
      ),
    ]);
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  Future<void> cache(CacheType type) => database.cacheDao.upsertCachedTrack(
    CachedTracksTableCompanion.insert(
      songId: 'song',
      filePath: audio.path,
      fileSize: 3,
      format: 'mp3',
      lastAccessedAt: DateTime.utc(2026),
      cacheType: type,
      downloadStatus: DownloadStatus.complete,
    ),
  );

  test('starred missing song retains its rolling cache bytes', () async {
    await database.libraryDao.upsertSongs([
      SongsTableCompanion(
        id: const Value('song'),
        title: const Value('Song'),
        starred: Value(DateTime.utc(2026)),
      ),
    ]);
    await cache(CacheType.rolling);
    final result = await database.libraryDao.retainOrRemoveServerSongs([
      (await database.libraryDao.getSongById('song'))!,
    ]);
    expect(result.retainedUnavailableIds, ['song']);
    expect(result.deferredCacheFiles, isEmpty);
    final row = (await database.libraryDao.getSongById('song'))!;
    expect(row.serverDeletedAt, isNotNull);
    expect(row.catalogAvailability, 'confirmedMissing');
    expect(row.albumId, isNull);
    expect(await database.cacheDao.getCachedTrack('song'), isNotNull);
    await database.libraryDao.cleanupRemovedCacheFiles(
      result.deferredCacheFiles,
    );
    expect(audio.existsSync(), isTrue);
  }, skip: !sqliteAvailable);

  test('unowned missing song removes rows and defers its file', () async {
    await cache(CacheType.rolling);
    final result = await database.libraryDao.retainOrRemoveServerSongs([
      (await database.libraryDao.getSongById('song'))!,
    ]);
    expect(result.deferredCacheFiles, [audio.path]);
    expect(result.retainedUnavailableIds, isEmpty);
    expect(await database.libraryDao.getSongById('song'), isNull);
    expect(await database.cacheDao.getCachedTrack('song'), isNull);
    expect(audio.existsSync(), isTrue);
    await database.libraryDao.cleanupRemovedCacheFiles(
      result.deferredCacheFiles,
    );
    expect(audio.existsSync(), isFalse);
  }, skip: !sqliteAvailable);

  test('valid permanent download survives server removal', () async {
    await cache(CacheType.permanent);
    final result = await database.libraryDao.retainOrRemoveServerSongs([
      (await database.libraryDao.getSongById('song'))!,
    ]);
    expect(result.deferredCacheFiles, isEmpty);
    expect(result.retainedUnavailableIds, isEmpty);
    expect(
      (await database.libraryDao.getSongById('song'))!.serverDeletedAt,
      isNotNull,
    );
    expect(await database.cacheDao.getCachedTrack('song'), isNotNull);
    expect(audio.existsSync(), isTrue);
  }, skip: !sqliteAvailable);

  for (final albumDeletion in [true, false]) {
    test(
      'rollback of ${albumDeletion ? 'album deletion' : 'song reconciliation'} keeps files',
      () async {
        await cache(CacheType.rolling);
        await expectLater(
          database.transaction(() async {
            if (albumDeletion) {
              await database.libraryDao.deleteAlbumsByIds(['album']);
            } else {
              await database.libraryDao.reconcileSongsForAlbumsChunk({
                'album': [],
              });
            }
            expect(audio.existsSync(), isTrue);
            throw StateError('rollback');
          }),
          throwsStateError,
        );
        expect(await database.libraryDao.getSongById('song'), isNotNull);
        expect(await database.cacheDao.getCachedTrack('song'), isNotNull);
        expect(audio.existsSync(), isTrue);
      },
      skip: !sqliteAvailable,
    );
  }
}
