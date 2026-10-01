import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:file/memory.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/lrclib_client.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/downloads/data/download_service.dart';
import 'package:navis/src/features/player/domain/lyrics_resolution.dart';
import 'package:path/path.dart' as p;

import '../../../helpers/test_database.dart';

class _MockCacheManager extends Mock implements BaseCacheManager {}

class _MockLrclibClient extends Mock implements LrclibClient {}

class _MockDio extends Mock implements Dio {}

void main() {
  group('DownloadService', () {
    late NavisDatabase database;
    late DownloadService service;

    setUpAll(() {
      registerFallbackValue(
        Uri.parse('https://example.com/rest/download.view'),
      );
      registerFallbackValue(CancelToken());
      registerFallbackValue(Options());
    });

    setUp(() {
      database = NavisDatabase(NativeDatabase.memory());
      service = DownloadService(
        appSettingsDao: database.appSettingsDao,
        cacheDao: database.cacheDao,
        downloadQueueDao: database.downloadQueueDao,
        libraryDao: database.libraryDao,
        readApiClient: () => null, // No API client — will skip actual HTTP.
        readWifiOnly: () => false,
        readIsWifi: () => true,
        readCustomDownloadFolderEnabled: () => false,
        readCustomDownloadFolderPath: () => null,
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
      'enqueueSong queues when permanent cache is lower quality than requested',
      () async {
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(id: 'song-1', title: 'Test Song'),
        ]);
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'song-1',
            filePath: '/fake/path/song-1.mp3',
            fileSize: 1000,
            format: 'mp3',
            bitRate: const Value(128),
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );

        await service.enqueueSong(
          'song-1',
          quality: '320',
          format: 'mp3',
        );

        final items = await database.downloadQueueDao.watchQueue().first;
        expect(items, hasLength(1));
        expect(items.first.quality, '320');
        expect(items.first.format, 'mp3');
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
      'start() backfill caches LRCLIB search results for downloaded songs',
      () async {
        final lrclib = _MockLrclibClient();
        final serverCalls = <String>[];
        when(
          () => lrclib.searchLyrics(
            artist: any(named: 'artist'),
            title: any(named: 'title'),
          ),
        ).thenAnswer(
          (_) async => const <LrclibLyrics>[
            LrclibLyrics(
              artistName: 'Evanescence',
              trackName: 'Bring Me To Life',
              duration: 235,
              syncedLyrics: '[00:01.00]wake me up',
            ),
          ],
        );
        when(
          () => lrclib.getLyrics(
            artist: any(named: 'artist'),
            title: any(named: 'title'),
            album: any(named: 'album'),
            duration: any(named: 'duration'),
          ),
        ).thenAnswer((_) async => null);
        final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              serverCalls.add(options.path);
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.badResponse,
                ),
              );
            },
          ),
        );
        final apiClient = SubsonicApiClient(
          baseUrl: 'https://example.com',
          authConfig: const SubsonicAuthConfig(
            username: 'alice',
            password: 'secret',
            apiVersion: '1.16.1',
          ),
          dio: dio,
          enableLogging: false,
        );
        final lrclibFirstService = DownloadService(
          appSettingsDao: database.appSettingsDao,
          cacheDao: database.cacheDao,
          downloadQueueDao: database.downloadQueueDao,
          libraryDao: database.libraryDao,
          readApiClient: () => apiClient,
          readWifiOnly: () => false,
          readIsWifi: () => true,
          readCustomDownloadFolderEnabled: () => false,
          readCustomDownloadFolderPath: () => null,
          lrclibClient: lrclib,
          readCoverArtCacheManager: _MockCacheManager.new,
        );
        addTearDown(lrclibFirstService.stop);

        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'song-lrclib',
            title: 'Bring Me To Life',
            artistName: const Value('Evanescence'),
            duration: const Value(235),
          ),
        ]);
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'song-lrclib',
            filePath: '/fake/song-lrclib.mp3',
            fileSize: 500,
            format: 'mp3',
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );

        await expectLater(lrclibFirstService.start(), completes);

        ExternalLyricsCacheTableData? cached;
        for (var i = 0; i < 20; i++) {
          cached = await database.libraryDao.getExternalLyricsCache(
            'song-lrclib',
          );
          if (cached != null) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }

        expect(cached, isNotNull);
        expect(cached!.source, LyricsSource.lrclibSynced.name);
        expect(cached.syncedLyrics, '[00:01.00]wake me up');
        expect(cached.ttlSeconds, 31536000);
        expect(serverCalls, isEmpty);
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'start() backfill skips when wifi-only is set and device is not on wifi',
      () async {
        // Build a service that claims wifi-only + not on wifi.
        final wifiOnlyOfflineService = DownloadService(
          appSettingsDao: database.appSettingsDao,
          cacheDao: database.cacheDao,
          downloadQueueDao: database.downloadQueueDao,
          libraryDao: database.libraryDao,
          readApiClient: () => null,
          readWifiOnly: () => true,
          readIsWifi: () => false,
          readCustomDownloadFolderEnabled: () => false,
          readCustomDownloadFolderPath: () => null,
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
      'queued item promotes compatible rolling cache during processing',
      () async {
        final supportDir = await Directory.systemTemp.createTemp(
          'navis_support_',
        );
        final rollingDir = await Directory.systemTemp.createTemp(
          'navis_rolling_',
        );
        addTearDown(() => supportDir.delete(recursive: true));
        addTearDown(() => rollingDir.delete(recursive: true));

        final rollingFile = File('${rollingDir.path}/song-1.mp3')
          ..writeAsBytesSync(<int>[1, 2, 3]);
        final rollingService = DownloadService(
          appSettingsDao: database.appSettingsDao,
          cacheDao: database.cacheDao,
          downloadQueueDao: database.downloadQueueDao,
          libraryDao: database.libraryDao,
          readApiClient: () => null,
          readWifiOnly: () => false,
          readIsWifi: () => true,
          readCustomDownloadFolderEnabled: () => false,
          readCustomDownloadFolderPath: () => null,
          lrclibClient: LrclibClient(),
          readCoverArtCacheManager: _MockCacheManager.new,
          readApplicationSupportDirectory: () async => supportDir,
        );
        addTearDown(rollingService.stop);

        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Cached Song',
            artistName: const Value('Cached Artist'),
          ),
        ]);
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'song-1',
            filePath: rollingFile.path,
            fileSize: 3,
            format: 'mp3',
            bitRate: const Value(320),
            cacheType: CacheType.rolling,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );
        await database.downloadQueueDao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-1'),
            quality: const Value('128'),
            format: const Value('mp3'),
            status: DownloadStatus.queued,
            addedAt: DateTime(2025, 1, 1),
          ),
        );

        await rollingService.processQueuedDownloads();

        expect(await database.downloadQueueDao.watchQueue().first, isEmpty);
        final cached = await database.cacheDao.getCachedTrack('song-1');
        expect(cached?.cacheType, CacheType.permanent);
        expect(File(cached!.filePath).existsSync(), isTrue);
        expect(rollingFile.existsSync(), isFalse);
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'rolling promotion pre-caches standard-size cover art',
      () async {
        final supportDir = await Directory.systemTemp.createTemp(
          'navis_support_',
        );
        final rollingDir = await Directory.systemTemp.createTemp(
          'navis_rolling_',
        );
        addTearDown(() => supportDir.delete(recursive: true));
        addTearDown(() => rollingDir.delete(recursive: true));

        final cacheManager = _MockCacheManager();
        final artFile = MemoryFileSystem.test().file('art.jpg')
          ..writeAsBytesSync(<int>[9, 9, 9]);
        when(
          () => cacheManager.downloadFile(
            any(),
            key: any(named: 'key'),
          ),
        ).thenAnswer(
          (invocation) async => FileInfo(
            artFile,
            FileSource.Online,
            DateTime.now().add(const Duration(days: 1)),
            invocation.positionalArguments.first as String,
          ),
        );
        final apiClient = SubsonicApiClient(
          baseUrl: 'https://example.com',
          authConfig: const SubsonicAuthConfig(
            username: 'alice',
            password: 'secret',
            apiVersion: '1.16.1',
          ),
          enableLogging: false,
        );
        final rollingFile = File('${rollingDir.path}/song-1.mp3')
          ..writeAsBytesSync(<int>[1, 2, 3]);
        final rollingService = DownloadService(
          appSettingsDao: database.appSettingsDao,
          cacheDao: database.cacheDao,
          downloadQueueDao: database.downloadQueueDao,
          libraryDao: database.libraryDao,
          readApiClient: () => apiClient,
          readWifiOnly: () => false,
          readIsWifi: () => true,
          readCustomDownloadFolderEnabled: () => false,
          readCustomDownloadFolderPath: () => null,
          lrclibClient: LrclibClient(),
          readCoverArtCacheManager: () => cacheManager,
          readApplicationSupportDirectory: () async => supportDir,
        );
        addTearDown(rollingService.stop);

        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Cached Song',
            artistName: const Value('Cached Artist'),
            coverArt: const Value('cover-1'),
          ),
        ]);
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'song-1',
            filePath: rollingFile.path,
            fileSize: 3,
            format: 'mp3',
            bitRate: const Value(320),
            cacheType: CacheType.rolling,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );
        await database.downloadQueueDao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-1'),
            quality: const Value('128'),
            format: const Value('mp3'),
            status: DownloadStatus.queued,
            addedAt: DateTime(2025, 1, 1),
          ),
        );

        await rollingService.processQueuedDownloads();

        verify(
          () => cacheManager.downloadFile(
            any(that: contains('size=600')),
            key: coverArtImageCacheKey('cover-1', kCoverArtStandardSize),
          ),
        ).called(1);
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'completed download pre-caches standard-size cover art',
      () async {
        final supportDir = await Directory.systemTemp.createTemp(
          'navis_support_',
        );
        addTearDown(() => supportDir.delete(recursive: true));

        final dio = _MockDio();
        when(
          () => dio.downloadUri(
            any<Uri>(),
            any<dynamic>(),
            cancelToken: any<CancelToken?>(named: 'cancelToken'),
            onReceiveProgress: any<ProgressCallback?>(
              named: 'onReceiveProgress',
            ),
          ),
        ).thenAnswer((invocation) async {
          final savePath = invocation.positionalArguments[1] as String;
          await File(savePath).parent.create(recursive: true);
          await File(savePath).writeAsBytes(<int>[1, 2, 3, 4]);
          return Response<void>(
            requestOptions: RequestOptions(path: 'download'),
            statusCode: 200,
          );
        });

        final cacheManager = _MockCacheManager();
        final artFile = MemoryFileSystem.test().file('art.jpg')
          ..writeAsBytesSync(<int>[8, 8, 8]);
        when(
          () => cacheManager.downloadFile(
            any(),
            key: any(named: 'key'),
          ),
        ).thenAnswer(
          (invocation) async => FileInfo(
            artFile,
            FileSource.Online,
            DateTime.now().add(const Duration(days: 1)),
            invocation.positionalArguments.first as String,
          ),
        );
        final apiClient = SubsonicApiClient(
          baseUrl: 'https://example.com',
          authConfig: const SubsonicAuthConfig(
            username: 'alice',
            password: 'secret',
            apiVersion: '1.16.1',
          ),
          enableLogging: false,
        );
        final downloadService = DownloadService(
          appSettingsDao: database.appSettingsDao,
          cacheDao: database.cacheDao,
          downloadQueueDao: database.downloadQueueDao,
          libraryDao: database.libraryDao,
          readApiClient: () => apiClient,
          readWifiOnly: () => false,
          readIsWifi: () => true,
          readCustomDownloadFolderEnabled: () => false,
          readCustomDownloadFolderPath: () => null,
          lrclibClient: LrclibClient(),
          readCoverArtCacheManager: () => cacheManager,
          readApplicationSupportDirectory: () async => supportDir,
          dio: dio,
        );
        addTearDown(downloadService.stop);

        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Downloaded Song',
            artistName: const Value('Downloaded Artist'),
            suffix: const Value('mp3'),
            coverArt: const Value('cover-1'),
          ),
        ]);
        await database.downloadQueueDao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-1'),
            status: DownloadStatus.queued,
            addedAt: DateTime(2025, 1, 1),
          ),
        );

        await downloadService.processQueuedDownloads();

        verify(
          () => cacheManager.downloadFile(
            any(that: contains('size=600')),
            key: coverArtImageCacheKey('cover-1', kCoverArtStandardSize),
          ),
        ).called(1);
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'a sidecar manifest failure keeps the finished download',
      () async {
        final supportDir = await Directory.systemTemp.createTemp(
          'navis_support_',
        );
        addTearDown(() => supportDir.delete(recursive: true));
        // A locked or unusable sidecar: a directory where the file belongs.
        Directory(
          '${supportDir.path}/audio/permanent/.navis-downloads.sqlite',
        ).createSync(recursive: true);

        final dio = _MockDio();
        when(
          () => dio.downloadUri(
            any<Uri>(),
            any<dynamic>(),
            cancelToken: any<CancelToken?>(named: 'cancelToken'),
            onReceiveProgress: any<ProgressCallback?>(
              named: 'onReceiveProgress',
            ),
          ),
        ).thenAnswer((invocation) async {
          final savePath = invocation.positionalArguments[1] as String;
          await File(savePath).parent.create(recursive: true);
          await File(savePath).writeAsBytes(<int>[1, 2, 3, 4]);
          return Response<void>(
            requestOptions: RequestOptions(path: 'download'),
            statusCode: 200,
          );
        });
        final apiClient = SubsonicApiClient(
          baseUrl: 'https://example.com',
          authConfig: const SubsonicAuthConfig(
            username: 'alice',
            password: 'secret',
            apiVersion: '1.16.1',
          ),
          enableLogging: false,
        );
        final downloadService = DownloadService(
          appSettingsDao: database.appSettingsDao,
          cacheDao: database.cacheDao,
          downloadQueueDao: database.downloadQueueDao,
          libraryDao: database.libraryDao,
          readApiClient: () => apiClient,
          readWifiOnly: () => false,
          readIsWifi: () => true,
          readCustomDownloadFolderEnabled: () => false,
          readCustomDownloadFolderPath: () => null,
          lrclibClient: LrclibClient(),
          readCoverArtCacheManager: _MockCacheManager.new,
          readApplicationSupportDirectory: () async => supportDir,
          dio: dio,
        );
        addTearDown(downloadService.stop);

        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Downloaded Song',
            artistName: const Value('Downloaded Artist'),
            suffix: const Value('mp3'),
          ),
        ]);
        await database.downloadQueueDao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-1'),
            status: DownloadStatus.queued,
            addedAt: DateTime(2025, 1, 1),
          ),
        );

        await downloadService.processQueuedDownloads();

        final track = await database.cacheDao.getCachedTrack('song-1');
        expect(track, isNotNull);
        expect(File(track!.filePath).existsSync(), isTrue);
        expect(await database.downloadQueueDao.getQueuedItems(), isEmpty);
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'queued item completes from compatible permanent cache during processing',
      () async {
        final cacheDir = await Directory.systemTemp.createTemp(
          'navis_permanent_cache_',
        );
        addTearDown(() => cacheDir.delete(recursive: true));
        final cachedFile = File('${cacheDir.path}/song-1.mp3')
          ..writeAsBytesSync(<int>[1, 2, 3]);

        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'song-1',
            filePath: cachedFile.path,
            fileSize: 3,
            format: 'mp3',
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );
        await database.downloadQueueDao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-1'),
            status: DownloadStatus.queued,
            addedAt: DateTime(2025, 1, 1),
          ),
        );

        await service.processQueuedDownloads();

        expect(await database.downloadQueueDao.watchQueue().first, isEmpty);
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'stopAndWait prevents a cancelled transfer from recreating queue state',
      () async {
        final supportDir = await Directory.systemTemp.createTemp(
          'navis_cancelled_download_',
        );
        addTearDown(() => supportDir.delete(recursive: true));
        final dio = _MockDio();
        final downloadStarted = Completer<void>();
        when(
          () => dio.downloadUri(
            any<Uri>(),
            any<dynamic>(),
            cancelToken: any<CancelToken?>(named: 'cancelToken'),
            onReceiveProgress: any<ProgressCallback?>(
              named: 'onReceiveProgress',
            ),
          ),
        ).thenAnswer((invocation) async {
          final token = invocation.namedArguments[#cancelToken] as CancelToken;
          final progress =
              invocation.namedArguments[#onReceiveProgress]
                  as ProgressCallback?;
          progress?.call(1, 10);
          if (!downloadStarted.isCompleted) {
            downloadStarted.complete();
          }
          await token.whenCancel;
          throw DioException(
            requestOptions: RequestOptions(path: 'download'),
            type: DioExceptionType.cancel,
          );
        });
        final apiClient = SubsonicApiClient(
          baseUrl: 'https://example.com',
          authConfig: const SubsonicAuthConfig(
            username: 'alice',
            password: 'secret',
            apiVersion: '1.16.1',
          ),
          enableLogging: false,
        );
        final cancellingService = DownloadService(
          appSettingsDao: database.appSettingsDao,
          cacheDao: database.cacheDao,
          downloadQueueDao: database.downloadQueueDao,
          libraryDao: database.libraryDao,
          readApiClient: () => apiClient,
          readWifiOnly: () => false,
          readIsWifi: () => true,
          readCustomDownloadFolderEnabled: () => false,
          readCustomDownloadFolderPath: () => null,
          lrclibClient: LrclibClient(),
          readCoverArtCacheManager: _MockCacheManager.new,
          readApplicationSupportDirectory: () async => supportDir,
          dio: dio,
        );
        addTearDown(cancellingService.stop);
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(id: 'song-1', title: 'Song 1'),
        ]);
        await database.downloadQueueDao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-1'),
            status: DownloadStatus.queued,
            addedAt: DateTime.now(),
          ),
        );

        await cancellingService.start();
        await downloadStarted.future;
        await cancellingService.stopAndWait();
        await database.downloadQueueDao.clearQueue();
        await Future<void>.delayed(Duration.zero);

        expect(await database.downloadQueueDao.watchQueue().first, isEmpty);
        expect(await database.cacheDao.getCachedTrack('song-1'), isNull);
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'queued item remains blocked by wifi-only then processes after trigger',
      () async {
        final cacheDir = await Directory.systemTemp.createTemp(
          'navis_permanent_cache_',
        );
        addTearDown(() => cacheDir.delete(recursive: true));
        final cachedFile = File('${cacheDir.path}/song-1.mp3')
          ..writeAsBytesSync(<int>[1, 2, 3]);
        var wifiOnly = true;
        var isWifi = false;
        final gatedService = DownloadService(
          appSettingsDao: database.appSettingsDao,
          cacheDao: database.cacheDao,
          downloadQueueDao: database.downloadQueueDao,
          libraryDao: database.libraryDao,
          readApiClient: () => null,
          readWifiOnly: () => wifiOnly,
          readIsWifi: () => isWifi,
          readCustomDownloadFolderEnabled: () => false,
          readCustomDownloadFolderPath: () => null,
          lrclibClient: LrclibClient(),
          readCoverArtCacheManager: _MockCacheManager.new,
        );
        addTearDown(gatedService.stop);

        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'song-1',
            filePath: cachedFile.path,
            fileSize: 3,
            format: 'mp3',
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );
        await database.downloadQueueDao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-1'),
            status: DownloadStatus.queued,
            addedAt: DateTime(2025, 1, 1),
          ),
        );

        await gatedService.processQueuedDownloads();
        expect(
          await database.downloadQueueDao.watchQueue().first,
          hasLength(1),
        );

        wifiOnly = false;
        isWifi = false;
        await gatedService.processQueuedDownloads();

        expect(await database.downloadQueueDao.watchQueue().first, isEmpty);
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
          appSettingsDao: database.appSettingsDao,
          cacheDao: database.cacheDao,
          downloadQueueDao: database.downloadQueueDao,
          libraryDao: database.libraryDao,
          readApiClient: () => apiClient,
          readWifiOnly: () => false,
          readIsWifi: () => true,
          readCustomDownloadFolderEnabled: () => false,
          readCustomDownloadFolderPath: () => null,
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

    test(
      'start normalizes hashed permanent downloads into artist folders',
      () async {
        final supportDir = await Directory.systemTemp.createTemp(
          'navis_support_',
        );
        addTearDown(() => supportDir.delete(recursive: true));
        final legacyDir = Directory(
          '${supportDir.path}/audio/permanent',
        )..createSync(recursive: true);
        final legacyFile = File('${legacyDir.path}/song-1_legacy.mp3')
          ..writeAsBytesSync(<int>[1, 2, 3]);

        final normalizingService = DownloadService(
          appSettingsDao: database.appSettingsDao,
          cacheDao: database.cacheDao,
          downloadQueueDao: database.downloadQueueDao,
          libraryDao: database.libraryDao,
          readApiClient: () => null,
          readWifiOnly: () => false,
          readIsWifi: () => true,
          readCustomDownloadFolderEnabled: () => false,
          readCustomDownloadFolderPath: () => null,
          lrclibClient: LrclibClient(),
          readCoverArtCacheManager: _MockCacheManager.new,
          readApplicationSupportDirectory: () async => supportDir,
        );
        addTearDown(normalizingService.stop);

        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Duality',
            artistName: const Value('Slipknot'),
          ),
        ]);
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'song-1',
            filePath: legacyFile.path,
            fileSize: 3,
            format: 'mp3',
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );

        await normalizingService.start();

        final track = await database.cacheDao.getCachedTrack('song-1');
        expect(
          track?.filePath,
          '${legacyDir.path}/Slipknot/Duality.mp3',
        );
        expect(File(track!.filePath).existsSync(), isTrue);
        expect(legacyFile.existsSync(), isFalse);
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'configureCustomDownloadFolder moves permanent downloads to custom root',
      () async {
        final supportDir = await Directory.systemTemp.createTemp(
          'navis_default_support_',
        );
        final customDir = await Directory.systemTemp.createTemp(
          'navis_custom_downloads_',
        );
        addTearDown(() => supportDir.delete(recursive: true));
        addTearDown(() => customDir.delete(recursive: true));

        var customEnabled = false;
        String? customPath;
        final legacyDir = Directory(
          '${supportDir.path}/audio/permanent',
        )..createSync(recursive: true);
        final legacyFile = File('${legacyDir.path}/song-1_legacy.mp3')
          ..writeAsBytesSync(<int>[7, 8, 9]);

        final movingService = DownloadService(
          appSettingsDao: database.appSettingsDao,
          cacheDao: database.cacheDao,
          downloadQueueDao: database.downloadQueueDao,
          libraryDao: database.libraryDao,
          readApiClient: () => null,
          readWifiOnly: () => false,
          readIsWifi: () => true,
          readCustomDownloadFolderEnabled: () => customEnabled,
          readCustomDownloadFolderPath: () => customPath,
          lrclibClient: LrclibClient(),
          readCoverArtCacheManager: _MockCacheManager.new,
          readApplicationSupportDirectory: () async => supportDir,
        );
        addTearDown(movingService.stop);

        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Duality',
            artistName: const Value('Slipknot'),
          ),
        ]);
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'song-1',
            filePath: legacyFile.path,
            fileSize: 3,
            format: 'mp3',
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );

        await movingService.configureCustomDownloadFolder(
          enabled: true,
          path: customDir.path,
        );
        customEnabled = true;
        customPath = customDir.path;

        final track = await database.cacheDao.getCachedTrack('song-1');
        expect(
          track?.filePath,
          '${customDir.path}/Slipknot/Duality.mp3',
        );
        expect(File(track!.filePath).existsSync(), isTrue);
        expect(legacyFile.existsSync(), isFalse);

        final settings = await database.appSettingsDao.getSettings();
        expect(settings?.customDownloadFolderEnabled, isTrue);
        expect(settings?.customDownloadFolderPath, customDir.path);
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'configureCustomDownloadFolder rolls back moved files when relocation fails',
      () async {
        final supportDir = await Directory.systemTemp.createTemp(
          'navis_default_support_',
        );
        final customDir = await Directory.systemTemp.createTemp(
          'navis_custom_downloads_',
        );
        addTearDown(() => supportDir.delete(recursive: true));
        addTearDown(() => customDir.delete(recursive: true));

        final blockingFile = File('${customDir.path}/Slipknot')
          ..writeAsStringSync('not a directory');

        var customEnabled = false;
        String? customPath;
        final legacyDir = Directory(
          '${supportDir.path}/audio/permanent',
        )..createSync(recursive: true);
        final legacyFile = File('${legacyDir.path}/song-1_legacy.mp3')
          ..writeAsBytesSync(<int>[4, 5, 6]);

        final movingService = DownloadService(
          appSettingsDao: database.appSettingsDao,
          cacheDao: database.cacheDao,
          downloadQueueDao: database.downloadQueueDao,
          libraryDao: database.libraryDao,
          readApiClient: () => null,
          readWifiOnly: () => false,
          readIsWifi: () => true,
          readCustomDownloadFolderEnabled: () => customEnabled,
          readCustomDownloadFolderPath: () => customPath,
          lrclibClient: LrclibClient(),
          readCoverArtCacheManager: _MockCacheManager.new,
          readApplicationSupportDirectory: () async => supportDir,
        );
        addTearDown(movingService.stop);

        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Duality',
            artistName: const Value('Slipknot'),
          ),
        ]);
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'song-1',
            filePath: legacyFile.path,
            fileSize: 3,
            format: 'mp3',
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );

        await expectLater(
          () => movingService.configureCustomDownloadFolder(
            enabled: true,
            path: customDir.path,
          ),
          throwsA(isA<FileSystemException>()),
        );

        final track = await database.cacheDao.getCachedTrack('song-1');
        expect(track?.filePath, legacyFile.path);
        expect(legacyFile.existsSync(), isTrue);
        expect(blockingFile.existsSync(), isTrue);

        final settings = await database.appSettingsDao.getSettings();
        expect(settings?.customDownloadFolderEnabled, isFalse);
        expect(settings?.customDownloadFolderPath, isNull);
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'start leaves files inside a custom download folder where they are',
      () async {
        final customDir = await Directory.systemTemp.createTemp(
          'navis_custom_adopted_',
        );
        addTearDown(() => customDir.delete(recursive: true));
        final adopted = File('${customDir.path}/Album X/01 Duality.mp3')
          ..createSync(recursive: true)
          ..writeAsBytesSync(<int>[4, 5, 6]);

        final customService = DownloadService(
          appSettingsDao: database.appSettingsDao,
          cacheDao: database.cacheDao,
          downloadQueueDao: database.downloadQueueDao,
          libraryDao: database.libraryDao,
          readApiClient: () => null,
          readWifiOnly: () => false,
          readIsWifi: () => true,
          readCustomDownloadFolderEnabled: () => true,
          readCustomDownloadFolderPath: () => customDir.path,
          lrclibClient: LrclibClient(),
          readCoverArtCacheManager: _MockCacheManager.new,
        );
        addTearDown(customService.stop);

        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Duality',
            artistName: const Value('Slipknot'),
          ),
        ]);
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'song-1',
            filePath: adopted.path,
            fileSize: 3,
            format: 'mp3',
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );

        await customService.start();

        final track = await database.cacheDao.getCachedTrack('song-1');
        expect(track?.filePath, adopted.path);
        expect(adopted.existsSync(), isTrue);
        expect(Directory('${customDir.path}/Slipknot').existsSync(), isFalse);
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );

    test(
      'startup cleanup keeps downloads stored through the other folder spelling',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('navis_support_');
        addTearDown(() => sandbox.delete(recursive: true));
        final real = Directory('${sandbox.path}/real')..createSync();
        final link = Link('${sandbox.path}/link')..createSync(real.path);
        final file = File('${real.path}/audio/permanent/Artist/Song.mp3')
          ..createSync(recursive: true)
          ..writeAsBytesSync(<int>[1, 2, 3]);
        final orphan = File('${real.path}/audio/permanent/Artist/Stray.mp3')
          ..writeAsBytesSync(<int>[4]);
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'song-1',
            filePath: file.path,
            fileSize: 3,
            format: 'mp3',
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Song',
            artistName: const Value('Artist'),
          ),
        ]);
        final linkedService = DownloadService(
          appSettingsDao: database.appSettingsDao,
          cacheDao: database.cacheDao,
          downloadQueueDao: database.downloadQueueDao,
          libraryDao: database.libraryDao,
          readApiClient: () => null,
          readWifiOnly: () => false,
          readIsWifi: () => true,
          readCustomDownloadFolderEnabled: () => false,
          readCustomDownloadFolderPath: () => null,
          lrclibClient: LrclibClient(),
          readCoverArtCacheManager: _MockCacheManager.new,
          // The app data folder reached through a link.
          readApplicationSupportDirectory: () async => Directory(link.path),
        );
        addTearDown(linkedService.stop);

        await linkedService.start();

        expect(file.existsSync(), isTrue);
        expect(orphan.existsSync(), isFalse);
      },
      skip: !sqliteAvailable || Platform.isWindows,
    );

    group('partial files', () {
      late Directory supportDir;
      late _MockDio dio;
      final savePaths = <String>[];

      DownloadService serviceWith({String? customFolder}) {
        final downloadService = DownloadService(
          appSettingsDao: database.appSettingsDao,
          cacheDao: database.cacheDao,
          downloadQueueDao: database.downloadQueueDao,
          libraryDao: database.libraryDao,
          readApiClient: () => SubsonicApiClient(
            baseUrl: 'https://example.com',
            authConfig: const SubsonicAuthConfig(
              username: 'alice',
              password: 'secret',
              apiVersion: '1.16.1',
            ),
            enableLogging: false,
          ),
          readWifiOnly: () => false,
          readIsWifi: () => true,
          readCustomDownloadFolderEnabled: () => customFolder != null,
          readCustomDownloadFolderPath: () => customFolder,
          lrclibClient: LrclibClient(),
          readCoverArtCacheManager: _MockCacheManager.new,
          readApplicationSupportDirectory: () async => supportDir,
          dio: dio,
        );
        addTearDown(downloadService.stop);
        return downloadService;
      }

      void answerDownload({required bool fail}) {
        when(
          () => dio.downloadUri(
            any<Uri>(),
            any<dynamic>(),
            cancelToken: any<CancelToken?>(named: 'cancelToken'),
            onReceiveProgress: any<ProgressCallback?>(
              named: 'onReceiveProgress',
            ),
          ),
        ).thenAnswer((invocation) async {
          final savePath = invocation.positionalArguments[1] as String;
          savePaths.add(savePath);
          await File(savePath).parent.create(recursive: true);
          await File(savePath).writeAsBytes(<int>[1, 2, 3, 4]);
          final options = RequestOptions(path: 'download');
          if (fail) {
            throw DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
            );
          }
          return Response<void>(requestOptions: options, statusCode: 200);
        });
      }

      Future<void> enqueueSong() async {
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Song',
            artistName: const Value('Artist'),
            suffix: const Value('mp3'),
          ),
        ]);
        await database.downloadQueueDao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-1'),
            status: DownloadStatus.queued,
            addedAt: DateTime(2025, 1, 1),
          ),
        );
      }

      List<String> audioFilesIn(Directory root) => root
          .listSync(recursive: true)
          .whereType<File>()
          .map((file) => p.relative(file.path, from: root.path))
          .where((path) => !path.contains('.navis-downloads'))
          .toList();

      setUp(() async {
        supportDir = await Directory.systemTemp.createTemp('navis_part_');
        dio = _MockDio();
        savePaths.clear();
      });

      tearDown(() async {
        if (await supportDir.exists()) await supportDir.delete(recursive: true);
      });

      test(
        'a download is written under a part name and renamed when complete',
        () async {
          answerDownload(fail: false);
          await enqueueSong();

          await serviceWith().processQueuedDownloads();

          final track = await database.cacheDao.getCachedTrack('song-1');
          expect(savePaths.single, '${track!.filePath}.navis-part');
          expect(File(track.filePath).existsSync(), isTrue);
          expect(File(savePaths.single).existsSync(), isFalse);
        },
        skip: sqliteAvailable ? null : 'sqlite3 not available',
      );

      test(
        'a failed transfer never leaves a file under the song name',
        () async {
          answerDownload(fail: true);
          await enqueueSong();

          await serviceWith().processQueuedDownloads();

          expect(savePaths, isNotEmpty);
          expect(
            audioFilesIn(Directory('${supportDir.path}/audio/permanent')),
            isEmpty,
          );
          expect(await database.cacheDao.getCachedTrack('song-1'), isNull);
        },
        skip: sqliteAvailable ? null : 'sqlite3 not available',
      );

      test(
        'startup removes part files of interrupted downloads in a custom '
        'folder and keeps the user files there',
        () async {
          final custom = Directory('${supportDir.path}/custom')..createSync();
          final part = File('${custom.path}/Other/Old Song.flac.navis-part')
            ..createSync(recursive: true)
            ..writeAsBytesSync(<int>[1]);
          final mine = File('${custom.path}/Artist/Mine.mp3')
            ..createSync(recursive: true)
            ..writeAsBytesSync(<int>[2]);
          final mineLookalike = File(
            '${custom.path}/Artist/notes.navis-partial',
          )..writeAsBytesSync(<int>[3]);
          await enqueueSong();
          final item =
              (await database.downloadQueueDao.getQueuedItems()).single;
          await database.downloadQueueDao.updateStatus(
            item.id,
            DownloadStatus.downloading,
          );
          // Startup resumes the queue; keep that transfer from finishing.
          answerDownload(fail: true);

          await serviceWith(customFolder: custom.path).start();

          expect(part.existsSync(), isFalse);
          expect(mine.existsSync(), isTrue);
          expect(mineLookalike.existsSync(), isTrue);
        },
        skip: sqliteAvailable ? null : 'sqlite3 not available',
      );
    });

    test(
      'removeDownloadedTrack prunes empty artist folders but keeps root folder',
      () async {
        final customDir = await Directory.systemTemp.createTemp(
          'navis_custom_downloads_',
        );
        addTearDown(() => customDir.delete(recursive: true));

        final artistDir = Directory('${customDir.path}/Slipknot')
          ..createSync(recursive: true);
        final trackFile = File('${artistDir.path}/Duality.mp3')
          ..writeAsBytesSync(<int>[1, 2, 3]);

        final pruningService = DownloadService(
          appSettingsDao: database.appSettingsDao,
          cacheDao: database.cacheDao,
          downloadQueueDao: database.downloadQueueDao,
          libraryDao: database.libraryDao,
          readApiClient: () => null,
          readWifiOnly: () => false,
          readIsWifi: () => true,
          readCustomDownloadFolderEnabled: () => true,
          readCustomDownloadFolderPath: () => customDir.path,
          lrclibClient: LrclibClient(),
          readCoverArtCacheManager: _MockCacheManager.new,
        );
        addTearDown(pruningService.stop);

        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'song-1',
            filePath: trackFile.path,
            fileSize: 3,
            format: 'mp3',
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );

        await pruningService.removeDownloadedTrack('song-1');

        expect(trackFile.existsSync(), isFalse);
        expect(artistDir.existsSync(), isFalse);
        expect(customDir.existsSync(), isTrue);
        expect(await database.cacheDao.getCachedTrack('song-1'), isNull);
      },
      skip: sqliteAvailable ? null : 'sqlite3 not available',
    );
  });

  test('progress persistence is limited to whole-percent steps', () {
    expect(shouldPersistDownloadProgress(previous: -1, next: 0), isTrue);
    expect(shouldPersistDownloadProgress(previous: 0, next: 0.004), isFalse);
    expect(shouldPersistDownloadProgress(previous: 0, next: 0.01), isTrue);
    expect(shouldPersistDownloadProgress(previous: 0.5, next: 0.509), isFalse);
    expect(shouldPersistDownloadProgress(previous: 0.995, next: 1), isTrue);
  });
}
