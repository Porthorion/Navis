import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/lrclib_client.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/downloads/data/download_service.dart';
import '../../../helpers/test_database.dart';

class _MockCacheManager extends Mock implements BaseCacheManager {}

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
        lrclibClient: LrclibClient(),
        readCoverArtCacheManager: _MockCacheManager.new,
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
      skip: sqliteAvailable ? null : 'sqlite3 not available',
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
      skip: sqliteAvailable ? null : 'sqlite3 not available',
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
      skip: sqliteAvailable ? null : 'sqlite3 not available',
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
      skip: sqliteAvailable ? null : 'sqlite3 not available',
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
      skip: sqliteAvailable ? null : 'sqlite3 not available',
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
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    // -----------------------------------------------------------------------
    // Lyrics backfill on start()
    // -----------------------------------------------------------------------

    test(
      'start() backfill skips songs that already have synced lyrics',
      () async {
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(id: 'song-1', title: 'Lyric Song'),
        ]);
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
        // Pre-seed synced lyrics — the backfill must not touch this song.
        await database.libraryDao.upsertExternalLyricsCache(
          songId: 'song-1',
          source: 'test',
          syncedLyrics: '[00:01.00] la la la',
          ttlSeconds: 3600,
        );

        await expectLater(service.start(), completes);

        // Synced lyrics must be intact.
        final cached = await database.libraryDao.getExternalLyricsCache(
          'song-1',
        );
        expect(cached?.syncedLyrics, '[00:01.00] la la la');
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'start() backfill processes songs with only plain lyrics (upgrade path)',
      () async {
        // When a song has only plain lyrics and the API client is null, the
        // backfill must still attempt the song (pass the lyrics gate) but exit
        // gracefully at the API check. Plain lyrics must be preserved.
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(id: 'song-plain', title: 'Plain Song'),
        ]);
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'song-plain',
            filePath: '/fake/song-plain.mp3',
            fileSize: 500,
            format: 'mp3',
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );
        await database.libraryDao.upsertExternalLyricsCache(
          songId: 'song-plain',
          source: 'serverPlain',
          plainLyrics: 'verse one',
          ttlSeconds: 3600,
        );

        // start() with null API exits before any fetch — plain lyrics survive.
        await expectLater(service.start(), completes);

        final cached = await database.libraryDao.getExternalLyricsCache(
          'song-plain',
        );
        expect(cached?.plainLyrics, 'verse one');
        expect(cached?.syncedLyrics, isNull); // No upgrade happened (no API).
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'start() backfill skips when wifi-only is set and device is not on wifi',
      () async {
        // Build a service that claims wifi-only + not on wifi.
        final wifiOnlyOfflineService = DownloadService(
          cacheDao: database.cacheDao,
          downloadQueueDao: database.downloadQueueDao,
          libraryDao: database.libraryDao,
          readApiClient: () => null,
          readWifiOnly: () => true,
          readIsWifi: () => false,
          lrclibClient: LrclibClient(),
          readCoverArtCacheManager: _MockCacheManager.new,
        );
        addTearDown(wifiOnlyOfflineService.stop);

        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'song-2',
            filePath: '/fake/song-2.mp3',
            fileSize: 500,
            format: 'mp3',
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );

        // No lyrics seeded — if the backfill ran it would try to fetch.
        // Because wifi-only + offline it must not attempt any fetch.
        await expectLater(wifiOnlyOfflineService.start(), completes);

        // Nothing should be cached because the backfill was gated out.
        final cached = await database.libraryDao.getExternalLyricsCache(
          'song-2',
        );
        expect(cached, isNull);
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'start() backfill is a no-op when there are no permanent downloads',
      () async {
        // No cached_tracks entries — backfill should exit early without error.
        await expectLater(service.start(), completes);
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
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
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'stale queued song missing from library is removed instead of retried',
      () async {
        final apiClient = SubsonicApiClient(
          baseUrl: 'https://example.com',
          authConfig: const SubsonicAuthConfig(
            username: 'alice',
            password: 'secret',
            apiVersion: '1.16.1',
          ),
          enableLogging: false,
        );
        final staleService = DownloadService(
          cacheDao: database.cacheDao,
          downloadQueueDao: database.downloadQueueDao,
          libraryDao: database.libraryDao,
          readApiClient: () => apiClient,
          readWifiOnly: () => false,
          readIsWifi: () => true,
          lrclibClient: LrclibClient(),
          readCoverArtCacheManager: _MockCacheManager.new,
        );
        addTearDown(staleService.stop);

        await database.downloadQueueDao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('missing-song'),
            status: DownloadStatus.queued,
            addedAt: DateTime(2025, 1, 1),
          ),
        );

        await staleService.start();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(await database.downloadQueueDao.watchQueue().first, isEmpty);
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );
  });
}
