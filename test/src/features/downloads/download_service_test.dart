import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/downloads/data/download_service.dart';
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
  group('DownloadService', () {
    late NavisDatabase database;
    late DownloadService service;

    setUp(() {
      database = NavisDatabase(NativeDatabase.memory());
      service = DownloadService(
        cacheDao: database.cacheDao,
        downloadQueueDao: database.downloadQueueDao,
        libraryDao: database.libraryDao,
        readApiClient: () => null, // No API client — will skip actual HTTP.
        readWifiOnly: () => false,
        readIsWifi: () => true,
      );
    });

    tearDown(() async {
      await service.stop();
      await database.close();
    });

    // -----------------------------------------------------------------------
    // Dedup: enqueueSong should not insert duplicates
    // -----------------------------------------------------------------------

    test(
      'enqueueSong skips if song is already queued',
      () async {
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(id: 'song-1', title: 'Test Song'),
        ]);

        await service.enqueueSong('song-1');
        await service.enqueueSong('song-1'); // Should be deduped.

        final items = await database.downloadQueueDao.watchQueue().first;
        expect(items, hasLength(1));
      },
      skip: _sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'enqueueSong skips if song is already permanently cached',
      () async {
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(id: 'song-1', title: 'Test Song'),
        ]);

        // Insert a permanent cache entry.
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'song-1',
            filePath: '/fake/path/song-1.mp3',
            fileSize: 1000,
            format: 'mp3',
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );

        await service.enqueueSong('song-1');

        final items = await database.downloadQueueDao.watchQueue().first;
        expect(items, isEmpty);
      },
      skip: _sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'enqueueSong replaces a previously failed item',
      () async {
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(id: 'song-1', title: 'Test Song'),
        ]);

        // Insert a failed queue entry manually.
        final id = await database.downloadQueueDao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-1'),
            status: DownloadStatus.failed,
            addedAt: DateTime(2025, 1, 1),
          ),
        );
        expect(id, greaterThan(0));

        // enqueueSong should remove the failed entry and add a new one.
        await service.enqueueSong('song-1');

        final items = await database.downloadQueueDao.watchQueue().first;
        expect(items, hasLength(1));
        expect(items.first.status, DownloadStatus.queued);
      },
      skip: _sqliteAvailable ? null : 'sqlite3 not available',
    );

    // -----------------------------------------------------------------------
    // enqueueAlbum
    // -----------------------------------------------------------------------

    test(
      'enqueueAlbum queues all songs for an album',
      () async {
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(id: 'album-1', name: 'Test Album'),
        ]);
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Song 1',
            albumId: const Value('album-1'),
          ),
          SongsTableCompanion.insert(
            id: 'song-2',
            title: 'Song 2',
            albumId: const Value('album-1'),
          ),
        ]);

        final count = await service.enqueueAlbum('album-1');
        expect(count, 2);

        final items = await database.downloadQueueDao.watchQueue().first;
        expect(items, hasLength(2));
      },
      skip: _sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'enqueueAlbum skips already-permanently-cached songs',
      () async {
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(id: 'album-1', name: 'Test Album'),
        ]);
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Song 1',
            albumId: const Value('album-1'),
          ),
          SongsTableCompanion.insert(
            id: 'song-2',
            title: 'Song 2',
            albumId: const Value('album-1'),
          ),
        ]);

        // Permanently cache song-1.
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'song-1',
            filePath: '/fake/song-1.mp3',
            fileSize: 1000,
            format: 'mp3',
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );

        final count = await service.enqueueAlbum('album-1');
        expect(count, 1); // Only song-2 should be queued.
      },
      skip: _sqliteAvailable ? null : 'sqlite3 not available',
    );

    // -----------------------------------------------------------------------
    // enqueuePlaylist
    // -----------------------------------------------------------------------

    test(
      'enqueuePlaylist queues specified songs',
      () async {
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(id: 'song-a', title: 'Song A'),
          SongsTableCompanion.insert(id: 'song-b', title: 'Song B'),
        ]);

        final count = await service.enqueuePlaylist(
          'playlist-1',
          ['song-a', 'song-b'],
        );
        expect(count, 2);

        final items = await database.downloadQueueDao.watchQueue().first;
        expect(items, hasLength(2));
      },
      skip: _sqliteAvailable ? null : 'sqlite3 not available',
    );

    // -----------------------------------------------------------------------
    // start() recovers stuck downloads
    // -----------------------------------------------------------------------

    test(
      'start recovers items stuck in downloading status',
      () async {
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(id: 'song-1', title: 'Song 1'),
        ]);

        // Simulate an item stuck in downloading (app was killed).
        final id = await database.downloadQueueDao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-1'),
            status: DownloadStatus.downloading,
            addedAt: DateTime(2025, 1, 1),
          ),
        );
        await database.downloadQueueDao.updateProgress(id, 0.5);

        // Start the service — should requeue the stuck item.
        await service.start();

        // Give the stream subscription a tick to fire.
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final items = await database.downloadQueueDao.watchQueue().first;
        expect(items, hasLength(1));
        // The item should now be failed (because there's no API client)
        // or queued (if requeue happened and no processing cycle ran
        // successfully). Since our readApiClient returns null, the service
        // will mark it as failed after attempted processing.
        expect(
          items.first.status,
          anyOf(DownloadStatus.queued, DownloadStatus.failed),
        );
      },
      skip: _sqliteAvailable ? null : 'sqlite3 not available',
    );
  });
}
