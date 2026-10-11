import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/lrclib_client.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/downloads/data/download_service.dart';
import 'package:navis/src/features/downloads/data/permanent_download_path_resolver.dart';
import 'package:navis/src/features/downloads/data/permanent_artwork_store.dart';
import 'package:path/path.dart' as p;

import '../../../helpers/test_database.dart';

class _MockCacheManager extends Mock implements BaseCacheManager;

class _MockDio extends Mock implements Dio;

class _MockLrclibClient extends Mock implements LrclibClient;

/// A server whose transfers finish only when the test releases them, and
/// that honours cancellation like Dio does.
class _GatedServer {
  final List<Uri> requests = <Uri>[];
  final Map<String, Completer<void>> _gates = <String, Completer<void>>{};
  int active = 0;
  int peak = 0;
  String contentType = 'audio/mpeg';
  int? failStatus;

  String songOf(Uri uri) => uri.queryParameters['id']!;

  /// Once every gate is released, later transfers finish at once.
  bool open = false;

  Completer<void> gate(String songId) => _gates.putIfAbsent(
    songId,
    () => open ? (Completer<void>()..complete()) : Completer<void>(),
  );

  void release(String songId) {
    final gate = this.gate(songId);
    if (!gate.isCompleted) gate.complete();
  }

  void releaseAll() {
    open = true;
    for (final gate in _gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
  }

  void install(_MockDio dio) {
    when(
      () => dio.downloadUri(
        any<Uri>(),
        any<dynamic>(),
        cancelToken: any<CancelToken?>(named: 'cancelToken'),
        onReceiveProgress: any<ProgressCallback?>(named: 'onReceiveProgress'),
      ),
    ).thenAnswer((invocation) async {
      final uri = invocation.positionalArguments[0] as Uri;
      final savePath = invocation.positionalArguments[1] as String;
      final token = invocation.namedArguments[#cancelToken] as CancelToken?;
      requests.add(uri);
      active++;
      if (active > peak) peak = active;
      try {
        await File(savePath).parent.create(recursive: true);
        await File(savePath).writeAsBytes(<int>[1, 2, 3, 4]);
        await Future.any<void>(<Future<void>>[
          gate(songOf(uri)).future,
          if (token != null) token.whenCancel.then((error) => throw error),
        ]);
      } finally {
        active--;
      }
      if (failStatus case final status?) {
        throw DioException(
          requestOptions: RequestOptions(path: uri.path),
          response: Response<void>(
            requestOptions: RequestOptions(path: uri.path),
            statusCode: status,
          ),
          type: DioExceptionType.badResponse,
        );
      }
      return Response<void>(
        requestOptions: RequestOptions(path: uri.path),
        statusCode: 200,
        headers: Headers.fromMap(<String, List<String>>{
          Headers.contentTypeHeader: <String>[contentType],
        }),
      );
    });
  }
}

class _OfflineArtworkStore extends PermanentArtworkStore {
  new(Directory root)
    : super(readApplicationSupportDirectory: () async => root);

  @override
  Future<bool> ensure(String? coverArtId, SubsonicApiClient api) async => false;
}

void main() {
  late NavisDatabase database;
  late Directory supportDir;
  late _MockDio dio;
  late _GatedServer server;
  late SubsonicApiClient api;
  var onWifi = true;

  setUpAll(() {
    registerFallbackValue(Uri.parse('https://example.com/rest/stream.view'));
    registerFallbackValue(CancelToken());
    registerFallbackValue(Options());
  });

  setUp(() async {
    database = createTestDatabase();
    supportDir = await Directory.systemTemp.createTemp('navis_queue_');
    dio = _MockDio();
    server = _GatedServer()..install(dio);
    onWifi = true;
    // A closed loopback port: background lyrics lookups fail at once.
    api = SubsonicApiClient(
      baseUrl: 'http://127.0.0.1:9',
      authConfig: const SubsonicAuthConfig(
        username: 'alice',
        password: 'secret',
        apiVersion: '1.16.1',
      ),
      enableLogging: false,
    );
  });

  tearDown(() async {
    server.releaseAll();
    await database.close();
    await supportDir.delete(recursive: true);
  });

  DownloadService buildService({
    PermanentArtworkStore? artworkStore,
    bool Function()? customEnabled,
    String? Function()? customPath,
    Future<void> Function(Directory)? validateCustomRoot,
    bool? isAndroid,
    Duration folderRecheckInterval = const Duration(seconds: 5),
  }) {
    final lrclib = _MockLrclibClient();
    final cacheManager = _MockCacheManager();
    when(() => cacheManager.downloadFile(any(), key: any(named: 'key')))
        .thenThrow(StateError('no cover art in this test'));
    final service = DownloadService(
      appSettingsDao: database.appSettingsDao,
      cacheDao: database.cacheDao,
      downloadQueueDao: database.downloadQueueDao,
      libraryDao: database.libraryDao,
      readApiClient: () => api,
      readWifiOnly: () => false,
      readIsWifi: () => onWifi,
      readCustomDownloadFolderEnabled: customEnabled ?? () => false,
      readCustomDownloadFolderPath: customPath ?? () => null,
      validateCustomRoot: validateCustomRoot,
      isAndroid: isAndroid,
      folderRecheckInterval: folderRecheckInterval,
      lrclibClient: lrclib,
      readCoverArtCacheManager: () => cacheManager,
      readApplicationSupportDirectory: () async => supportDir,
      artworkStore: artworkStore ?? _OfflineArtworkStore(supportDir),
      dio: dio,
    );
    addTearDown(service.dispose);
    return service;
  }

  Future<void> addSongs(int count, {String suffix = 'mp3'}) async {
    await database.libraryDao.upsertSongs(<SongsTableCompanion>[
      for (var i = 0; i < count; i++)
        SongsTableCompanion.insert(
          id: 'song-$i',
          title: 'Song $i',
          artistName: const Value('Artist'),
          suffix: Value(suffix),
          bitRate: const Value(1411),
          coverArt: Value('cover-$i'),
        ),
    ]);
  }

  Future<void> waitUntil(bool Function() condition) async {
    for (var i = 0; i < 400 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(condition(), isTrue, reason: 'condition not reached in time');
  }

  Future<List<DownloadQueueTableData>> queue() =>
      database.downloadQueueDao.watchQueue().first;

  test('Android startup holds an unset folder without disabling it', () async {
    await database.appSettingsDao.updateCustomDownloadFolderEnabled(
      enabled: true,
    );
    final service = buildService(customEnabled: () => true, isAndroid: true);
    await service.start();
    expect(service.folderProblem, DownloadFolderProblem.unset);
    expect(
      (await database.appSettingsDao.getSettings())!
          .customDownloadFolderEnabled,
      isTrue,
    );
  }, skip: !sqliteAvailable);

  test('a reconnected folder resumes without a manual queue retry', () async {
    final root = Directory(p.join(supportDir.path, 'removable'));
    final service = buildService(
      customEnabled: () => true,
      customPath: () => root.path,
      folderRecheckInterval: const Duration(milliseconds: 20),
    );
    await service.start();
    await addSongs(1);
    await service.enqueueSong('song-0', quality: '192', format: 'mp3');
    expect(service.folderProblem, DownloadFolderProblem.missing);
    expect(server.requests, isEmpty);
    server.releaseAll();
    await root.create();
    await waitUntil(() => server.requests.isNotEmpty);
    await waitUntil(() => service.folderProblem == null);
    await service.processQueuedDownloads();
    expect(await queue(), isEmpty);
  }, skip: !sqliteAvailable);

  for (final problem in DownloadFolderProblem.values) {
    test(
      'holds queue without retries for $problem and resumes after repair',
      () async {
        var path = problem == DownloadFolderProblem.unset
            ? null
            : problem == DownloadFolderProblem.missing
            ? p.join(supportDir.path, 'disconnected')
            : supportDir.path;
        var denied = problem == DownloadFolderProblem.inaccessible;
        final service = buildService(
          customEnabled: () => true,
          customPath: () => path,
          validateCustomRoot: (_) async {
            if (denied) {
              throw const FileSystemException(
                'Fixture permission denied',
                '',
                OSError('denied', 13),
              );
            }
          },
        );
        final notices = <DownloadFolderProblem>[];
        final subscription = service.folderNotices.listen(notices.add);
        addTearDown(subscription.cancel);
        await service.start();
        await addSongs(2);
        await service.enqueueSong('song-0', quality: '192', format: 'mp3');
        await service.enqueueSong('song-1', quality: '192', format: 'mp3');
        await service.processQueuedDownloads();
        expect(service.folderProblem, problem);
        expect(service.effectiveConcurrency, 0);
        expect(server.requests, isEmpty);
        final held = await queue();
        expect(held, hasLength(2));
        expect(held.map((i) => i.status), everyElement(DownloadStatus.queued));
        expect(held.map((i) => i.retryCount), everyElement(0));
        expect(notices, [problem]);
        denied = false;
        path = supportDir.path;
        server.releaseAll();
        await service.refreshDownloadFolder();
        await service.processQueuedDownloads();
        expect(service.folderProblem, isNull);
        expect(await queue(), isEmpty);
        expect(server.requests, hasLength(2));
      },
      skip: !sqliteAvailable,
    );
  }

  test(
    'switching to app storage resumes a queue held by an unset folder',
    () async {
      var custom = true;
      final service = buildService(customEnabled: () => custom);
      await service.start();
      await addSongs(1);
      await service.enqueueSong('song-0', quality: '192', format: 'mp3');
      await service.processQueuedDownloads();
      expect(service.folderProblem, DownloadFolderProblem.unset);
      custom = false;
      server.releaseAll();
      await service.refreshDownloadFolder();
      await service.processQueuedDownloads();
      expect(await queue(), isEmpty);
      expect(service.folderProblem, isNull);
    },
    skip: !sqliteAvailable,
  );

  test(
    'lost SAF permission holds the queue until app storage is selected',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const channel = MethodChannel('com.navis.app/permanent_download_storage');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => throw PlatformException(
          code: 'PERMISSION_DENIED',
          message: 'Fixture permission lost',
        ),
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      var custom = true;
      final service = buildService(
        customEnabled: () => custom,
        customPath: () => custom ? 'content://fixture/tree/root' : null,
        isAndroid: true,
      );
      await service.start();
      await addSongs(1);
      await service.enqueueSong('song-0', quality: '192', format: 'mp3');
      await service.processQueuedDownloads();
      final item = (await queue()).single;
      expect(service.folderProblem, DownloadFolderProblem.inaccessible);
      expect(item.status, DownloadStatus.queued);
      expect(item.retryCount, 0);
      expect(server.requests, isEmpty);
      custom = false;
      server.releaseAll();
      await service.refreshDownloadFolder();
      await service.processQueuedDownloads();
      expect(await queue(), isEmpty);
    },
    skip: !sqliteAvailable,
  );

  for (final wrapped in [false, true]) {
    test(
      'write permission lost during transfer holds without backoff, wrapped=$wrapped',
      () async {
        var denied = true;
        final service = buildService(
          customEnabled: () => true,
          customPath: () => supportDir.path,
          validateCustomRoot: (_) async {},
        );
        when(
          () => dio.downloadUri(
            any<Uri>(),
            any<dynamic>(),
            cancelToken: any<CancelToken?>(named: 'cancelToken'),
            onReceiveProgress: any<ProgressCallback?>(
              named: 'onReceiveProgress',
            ),
          ),
        ).thenAnswer((i) async {
          if (denied) {
            const error = FileSystemException(
              'Fixture permission lost',
              '',
              OSError('denied', 13),
            );
            if (wrapped) {
              throw DioException(
                requestOptions: RequestOptions(path: '/fixture'),
                error: error,
              );
            }
            throw error;
          }
          await File(i.positionalArguments[1] as String).parent
              .create(recursive: true);
          await File(i.positionalArguments[1] as String)
              .writeAsBytes([1, 2, 3]);
          return Response<void>(
            requestOptions: RequestOptions(path: '/fixture'),
            statusCode: 200,
            headers: Headers.fromMap({
              Headers.contentTypeHeader: ['audio/mpeg'],
            }),
          );
        });
        await service.start();
        await addSongs(1);
        await service.enqueueSong('song-0', quality: '192', format: 'mp3');
        await service.processQueuedDownloads();
        expect(service.folderProblem, DownloadFolderProblem.inaccessible);
        expect((await queue()).single.retryCount, 0);
        expect((await queue()).single.status, DownloadStatus.queued);
        denied = false;
        await service.refreshDownloadFolder();
        await service.processQueuedDownloads();
        expect(await queue(), isEmpty);
      },
      skip: !sqliteAvailable,
    );
  }

  test('runs up to the configured number of downloads at once', () async {
    final service = buildService();
    await service.start();
    await service.setMaxConcurrentDownloads(3);
    await addSongs(6);
    for (var i = 0; i < 6; i++) {
      await service.enqueueSong('song-$i', quality: '192', format: 'mp3');
    }

    await waitUntil(() => server.active == 3);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(server.active, 3);
    expect(service.activeQueueIds, hasLength(3));

    server.releaseAll();
    await service.processQueuedDownloads();
    server.releaseAll();
    await service.processQueuedDownloads();

    expect(server.peak, 3);
    expect(await queue(), isEmpty);
    expect(await database.cacheDao.getPermanentlyCachedSongIds(), hasLength(6));
    // Every finished download got its own file.
    final paths = (await database.cacheDao.getPermanentEntries())
        .map((entry) => entry.filePath)
        .toSet();
    expect(paths, hasLength(6));
    for (final path in paths) {
      expect(File(path).existsSync(), isTrue);
    }
  }, skip: sqliteAvailable ? null : 'sqlite3 not available');

  test('concurrent songs with the same name never share a file', () async {
    final service = buildService();
    await service.start();
    await database.libraryDao.upsertSongs(<SongsTableCompanion>[
      for (final id in const ['twin-a', 'twin-b'])
        SongsTableCompanion.insert(
          id: id,
          title: 'Same Title',
          artistName: const Value('Same Artist'),
          suffix: const Value('mp3'),
        ),
    ]);
    await service.enqueueSong('twin-a', quality: '192', format: 'mp3');
    await service.enqueueSong('twin-b', quality: '192', format: 'mp3');
    await waitUntil(() => server.active == 2);
    server.releaseAll();
    await service.processQueuedDownloads();

    final entries = await database.cacheDao.getPermanentEntries();
    expect(entries, hasLength(2));
    expect(entries.map((e) => e.filePath).toSet(), hasLength(2));
  }, skip: sqliteAvailable ? null : 'sqlite3 not available');

  test('mobile data runs one download at a time', () async {
    onWifi = false;
    final service = buildService();
    await service.start();
    await service.setMaxConcurrentDownloads(4);
    await addSongs(3);
    for (var i = 0; i < 3; i++) {
      await service.enqueueSong('song-$i', quality: '128', format: 'mp3');
    }
    expect(service.effectiveConcurrency, 1);
    await waitUntil(() => server.active == 1);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(server.active, 1);

    for (var i = 0; i < 3; i++) {
      server.release('song-$i');
      await waitUntil(() => server.active <= 1);
    }
    server.releaseAll();
    await service.processQueuedDownloads();
    expect(server.peak, 1);
    expect(await queue(), isEmpty);
  }, skip: sqliteAvailable ? null : 'sqlite3 not available');

  test(
    'pausing returns transfers to the queue and resuming finishes them',
    () async {
      final service = buildService();
      await service.start();
      await addSongs(2);
      await service.enqueueSong('song-0', quality: '192', format: 'mp3');
      await service.enqueueSong('song-1', quality: '192', format: 'mp3');
      await waitUntil(() => server.active == 2);

      await service.setPaused(paused: true);
      await service.processQueuedDownloads();

      expect(server.active, 0);
      expect(service.isPaused, isTrue);
      expect(await database.appSettingsDao.getDownloadsPaused(), isTrue);
      final paused = await queue();
      expect(paused, hasLength(2));
      expect(
        paused.map((item) => item.status),
        everyElement(DownloadStatus.queued),
      );
      expect(await database.cacheDao.getPermanentlyCachedSongIds(), isEmpty);
      // No part file is left behind.
      final leftovers = supportDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.navis-part'));
      expect(leftovers, isEmpty);

      server.releaseAll();
      await service.setPaused(paused: false);
      await service.processQueuedDownloads();
      expect(await queue(), isEmpty);
      expect(
        await database.cacheDao.getPermanentlyCachedSongIds(),
        hasLength(2),
      );
    },
    skip: sqliteAvailable ? null : 'sqlite3 not available',
  );

  test('a paused queue stays paused after a restart', () async {
    await database.appSettingsDao.updateDownloadsPaused(paused: true);
    final service = buildService();
    await service.start();
    await addSongs(1);
    await service.enqueueSong('song-0', quality: '192', format: 'mp3');
    await service.processQueuedDownloads();
    expect(server.requests, isEmpty);
    expect(service.effectiveConcurrency, 0);
  }, skip: sqliteAvailable ? null : 'sqlite3 not available');

  test(
    'cancelling the active download stops it and registers nothing',
    () async {
      final service = buildService();
      await service.start();
      await addSongs(1);
      await service.enqueueSong('song-0', quality: '192', format: 'mp3');
      await waitUntil(() => server.active == 1);
      final id = (await queue()).single.id;

      await service.cancelQueueItem(id);
      await service.processQueuedDownloads();

      expect(await queue(), isEmpty);
      expect(await database.cacheDao.getCachedTrack('song-0'), isNull);
      final files = supportDir.listSync(recursive: true).whereType<File>();
      expect(files.where((f) => f.path.contains('Song 0')), isEmpty);
    },
    skip: sqliteAvailable ? null : 'sqlite3 not available',
  );

  test('clearing the queue stops every transfer', () async {
    final service = buildService();
    await service.start();
    await addSongs(3);
    for (var i = 0; i < 3; i++) {
      await service.enqueueSong('song-$i', quality: '192', format: 'mp3');
    }
    await waitUntil(() => server.active == 2);
    await service.clearQueue();
    await service.processQueuedDownloads();
    expect(await queue(), isEmpty);
    expect(await database.cacheDao.getPermanentlyCachedSongIds(), isEmpty);
  }, skip: sqliteAvailable ? null : 'sqlite3 not available');

  test('a failed download waits out its backoff before retrying', () async {
    server.failStatus = 500;
    final service = buildService();
    await service.start();
    await addSongs(1);
    server.release('song-0');
    await service.enqueueSong('song-0', quality: '192', format: 'mp3');
    await service.processQueuedDownloads();
    // The queue change that returns the item must not restart it at once.
    await service.processQueuedDownloads();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(server.requests, hasLength(1));
    final item = (await queue()).single;
    expect(item.status, DownloadStatus.queued);
    expect(item.retryCount, 1);
  }, skip: sqliteAvailable ? null : 'sqlite3 not available');

  test('transcoded downloads ask for an estimated length; originals use '
      'download.view', () async {
    final service = buildService();
    await service.start();
    await addSongs(2);
    server.releaseAll();
    server.release('song-0');
    server.release('song-1');
    await service.enqueueSong('song-0', quality: '256', format: 'opus');
    await service.enqueueSong('song-1');
    server.contentType = 'audio/ogg';
    await service.processQueuedDownloads();

    final transcoded = server.requests.firstWhere(
      (uri) => uri.queryParameters['id'] == 'song-0',
    );
    expect(transcoded.path, endsWith('/rest/stream.view'));
    expect(transcoded.queryParameters['maxBitRate'], '256');
    expect(transcoded.queryParameters['format'], 'opus');
    expect(transcoded.queryParameters['estimateContentLength'], 'true');
    final original = server.requests.firstWhere(
      (uri) => uri.queryParameters['id'] == 'song-1',
    );
    expect(original.path, endsWith('/rest/download.view'));
    expect(original.queryParameters, isNot(contains('format')));
  }, skip: sqliteAvailable ? null : 'sqlite3 not available');

  test(
    'a server that ignores the requested format stores what it sent',
    () async {
      final service = buildService();
      await service.start();
      await addSongs(1, suffix: 'flac');
      server
        ..contentType = 'audio/flac'
        ..release('song-0');
      await service.enqueueSong('song-0', quality: '192', format: 'opus');
      await service.processQueuedDownloads();

      final cached = (await database.cacheDao.getCachedTrack('song-0'))!;
      expect(cached.format, 'flac');
      expect(cached.bitRate, 1411);
      expect(p.extension(cached.filePath), '.flac');
      expect(File(cached.filePath).existsSync(), isTrue);
    },
    skip: sqliteAvailable ? null : 'sqlite3 not available',
  );

  test('an error document is never registered as audio', () async {
    final service = buildService();
    await service.start();
    await addSongs(1);
    server
      ..contentType = 'text/xml; charset=utf-8'
      ..release('song-0');
    await service.enqueueSong('song-0', quality: '192', format: 'mp3');
    await service.processQueuedDownloads();

    expect(await database.cacheDao.getCachedTrack('song-0'), isNull);
    expect((await queue()).single.retryCount, 1);
  }, skip: sqliteAvailable ? null : 'sqlite3 not available');

  test('an original download counts as original afterwards', () async {
    final service = buildService();
    await service.start();
    await addSongs(1, suffix: 'flac');
    server
      ..contentType = 'audio/flac'
      ..release('song-0');
    await service.enqueueSong('song-0');
    await service.processQueuedDownloads();
    final cached = (await database.cacheDao.getCachedTrack('song-0'))!;
    // Original downloads record the song's bitrate.
    expect(cached.bitRate, 1411);

    await service.enqueueSong('song-0');
    await service.processQueuedDownloads();
    expect(server.requests, hasLength(1));
    expect(await queue(), isEmpty);
  }, skip: sqliteAvailable ? null : 'sqlite3 not available');

  test(
    'a download keeps its cover, and removing it deletes the cover',
    () async {
      final artDio = _MockDio();
      when(
        () => artDio.getUri<List<int>>(
          any<Uri>(),
          options: any(named: 'options'),
        ),
      ).thenAnswer(
        (invocation) async => Response<List<int>>(
          requestOptions: RequestOptions(path: 'cover'),
          statusCode: 200,
          data: <int>[0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3],
        ),
      );
      final store = PermanentArtworkStore(
        readApplicationSupportDirectory: () async => supportDir,
        dio: artDio,
      );
      final service = buildService(artworkStore: store);
      await service.start();
      await addSongs(1);
      server.release('song-0');
      await service.enqueueSong('song-0', quality: '192', format: 'mp3');
      await service.processQueuedDownloads();
      await waitUntil(() => store.loadedFileFor('cover-0') != null);
      final art = (await store.fileFor('cover-0'))!;
      expect(p.extension(art.path), '.jpg');
      expect(art.existsSync(), isTrue);
      expect(await store.count(), 1);

      await service.removeDownloadedTrack('song-0');

      expect(art.existsSync(), isFalse);
      expect(await store.fileFor('cover-0'), isNull);
    },
    skip: sqliteAvailable ? null : 'sqlite3 not available',
  );

  test('a library being rebuilt never loses download covers', () async {
    final artDio = _MockDio();
    when(
      () =>
          artDio.getUri<List<int>>(any<Uri>(), options: any(named: 'options')),
    ).thenAnswer(
      (invocation) async => Response<List<int>>(
        requestOptions: RequestOptions(path: 'cover'),
        statusCode: 200,
        data: <int>[0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3],
      ),
    );
    final store = PermanentArtworkStore(
      readApplicationSupportDirectory: () async => supportDir,
      dio: artDio,
    );
    final service = buildService(artworkStore: store);
    await service.start();
    await addSongs(1);
    server.release('song-0');
    await service.enqueueSong('song-0', quality: '192', format: 'mp3');
    await service.processQueuedDownloads();
    await waitUntil(() => store.loadedFileFor('cover-0') != null);

    // Reset Caches & Rebuild Library deletes library rows but keeps the
    // downloads; until the catalog returns, no cover is provably unused.
    await database.delete(database.songsTable).go();
    await service.pruneDownloadArtwork();

    expect(await store.fileFor('cover-0'), isNotNull);
    expect((await store.fileFor('cover-0'))!.existsSync(), isTrue);
  }, skip: sqliteAvailable ? null : 'sqlite3 not available');
}
