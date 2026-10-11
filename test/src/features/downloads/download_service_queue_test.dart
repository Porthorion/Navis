import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

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
  Object? failure;
  void Function()? beforeResponse;
  List<int> bytes = [1, 2, 3, 4];
  int? contentLength;

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
        await File(savePath).writeAsBytes(bytes);
        await Future.any<void>(<Future<void>>[
          gate(songOf(uri)).future,
          if (token != null) token.whenCancel.then((error) => throw error),
        ]);
      } finally {
        active--;
      }
      beforeResponse?.call();
      if (failure case final Exception error) throw error;
      if (failure case final Error error) throw error;
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
          if (contentLength != null)
            Headers.contentLengthHeader: ['$contentLength'],
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
  var online = true;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
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
    online = true;
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
    Dio? transport,
    bool Function()? customEnabled,
    String? Function()? customPath,
    Future<void> Function(Directory)? validateCustomRoot,
    bool? isAndroid,
    Future<int?> Function(String)? readFreeBytes,
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
      readIsOnline: () => online,
      readFreeBytes: readFreeBytes ?? (_) async => null,
      readCustomDownloadFolderEnabled: customEnabled ?? () => false,
      readCustomDownloadFolderPath: customPath ?? () => null,
      validateCustomRoot: validateCustomRoot,
      isAndroid: isAndroid,
      folderRecheckInterval: folderRecheckInterval,
      lrclibClient: lrclib,
      readCoverArtCacheManager: () => cacheManager,
      readApplicationSupportDirectory: () async => supportDir,
      artworkStore: artworkStore ?? _OfflineArtworkStore(supportDir),
      dio: transport ?? dio,
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

  test('capacity reservations hold new workers while an admitted transfer finishes', () async {
    final service = buildService(readFreeBytes: (_) async => 30 * 1024 * 1024);
    await service.start();
    await database.libraryDao.upsertSongs([
      for (final id in ['song-0', 'song-1'])
        SongsTableCompanion.insert(
          id: id,
          title: id,
          size: const Value(8 * 1024 * 1024),
        ),
    ]);
    await service.enqueueSong('song-0');
    await waitUntil(() => server.active == 1);
    await service.enqueueSong('song-1');
    await waitUntil(
      () => service.folderProblem == DownloadFolderProblem.noSpace,
    );
    expect(server.requests, hasLength(1));
    server.release('song-0');
    await waitUntil(() => service.activeQueueIds.isEmpty);
    expect(await database.cacheDao.getCachedTrack('song-0'), isNotNull);
    expect((await queue()).single.songId, 'song-1');
    server.releaseAll();
    await service.processQueuedDownloads();
    expect(await queue(), isEmpty);
  }, skip: !sqliteAvailable);

  for (final uploaded in [false, true]) {
    test(
      'SAF finish journal reconciles a crash ${uploaded ? 'after' : 'before'} upload',
      () async {
        const tree = 'content://fixture/tree/root';
        const locator = 'content://fixture/document/audio';
        const channel = MethodChannel(
          'com.navis.app/permanent_download_storage',
        );
        const playback = MethodChannel(
          'com.navis.app/permanent_download_playback',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        await database.appSettingsDao.updateDownloadsPaused(paused: true);
        await addSongs(1);
        final staging = File(
          p.join(
            supportDir.path,
            'audio',
            'permanent',
            '.navis-saf-transfer.mp3',
          ),
        );
        await staging.parent.create(recursive: true);
        await staging.writeAsBytes([1, 2, 3, 4]);
        final materialized = File(p.join(supportDir.path, 'provider-copy.tmp'));
        messenger.setMockMethodCallHandler(
          channel,
          (call) async => switch (call.method) {
            'validateWritableTree' => {
              'uri': tree,
              'canRead': true,
              'canWrite': true,
              'canReplace': true,
            },
            'findDocument' =>
              (call.arguments as Map)['relativePath'] == 'Artist/Song.mp3' &&
                      uploaded
                  ? locator
                  : null,
            'materialize' => (await staging.copy(materialized.path)).path,
            'listRecursively' => [],
            _ => null,
          },
        );
        messenger.setMockMethodCallHandler(playback, (_) async => uploaded);
        addTearDown(() {
          messenger.setMockMethodCallHandler(channel, null);
          messenger.setMockMethodCallHandler(playback, null);
        });
        final id = await database.downloadQueueDao.enqueue(
          DownloadQueueTableCompanion.insert(
            songId: const Value('song-0'),
            status: DownloadStatus.downloading,
            addedAt: DateTime(2026),
          ),
        );
        await database.downloadQueueDao.writeFinishJournal(
          id,
          jsonEncode({
            'path': staging.path,
            'size': 4,
            'sha256': sha256.convert([1, 2, 3, 4]).toString(),
            'format': 'mp3',
            'bitRate': 192,
            'treeUri': tree,
            'relativePath': 'Artist/Song.mp3',
          }),
        );
        final service = buildService(
          isAndroid: true,
          customEnabled: () => true,
          customPath: () => tree,
        );
        await service.start();
        if (uploaded) {
          expect(await queue(), isEmpty);
          final row = (await database.cacheDao.getCachedTrack('song-0'))!;
          expect(row.storageKind, 'androidSaf');
          expect(row.filePath, locator);
        } else {
          expect((await queue()).single.status, DownloadStatus.queued);
          expect((await queue()).single.finishJournal, isNull);
          expect(await database.cacheDao.getCachedTrack('song-0'), isNull);
        }
        expect(staging.existsSync(), isFalse);
        expect(materialized.existsSync(), isFalse);
        expect(server.requests, isEmpty);
      },
      skip: !sqliteAvailable,
    );
  }

  test(
    'a full custom root probe retains the no-space classification',
    () async {
      final service = buildService(
        customEnabled: () => true,
        customPath: () => supportDir.path,
        validateCustomRoot: (_) async => throw const FileSystemException(
          'Fixture full',
          '',
          OSError('ENOSPC', 28),
        ),
      );
      await service.start();
      await addSongs(1);
      await service.enqueueSong('song-0');
      await service.processQueuedDownloads();
      expect(service.folderProblem, DownloadFolderProblem.noSpace);
      expect(
        (await queue()).single.failureReason,
        DownloadFailureReason.noSpace,
      );
      expect((await queue()).single.retryCount, 0);
      expect(server.requests, isEmpty);
    },
    skip: !sqliteAvailable || Platform.isWindows,
  );

  for (final code in [404, 410, 500, 503, 403]) {
    test(
      'HTTP $code persists its reason with the correct retry policy',
      () async {
        server.failStatus = code;
        server.releaseAll();
        final service = buildService();
        await service.start();
        await addSongs(1);
        await service.enqueueSong('song-0');
        await service.processQueuedDownloads();
        await service.processQueuedDownloads();
        final item = (await queue()).single;
        final reason = code == 403
            ? DownloadFailureReason.permission
            : code >= 500
            ? DownloadFailureReason.serverError
            : DownloadFailureReason.notFound;
        expect(item.failureReason, reason);
        expect(item.failureDetail, 'HTTP $code');
        expect(item.retryCount, code >= 500 ? 1 : 0);
        expect(
          item.status,
          code == 404 || code == 410
              ? DownloadStatus.failed
              : DownloadStatus.queued,
        );
        expect(server.requests, hasLength(1));
      },
      skip: !sqliteAvailable,
    );
  }

  for (final type in [
    DioExceptionType.connectionError,
    DioExceptionType.receiveTimeout,
    DioExceptionType.unknown,
  ]) {
    test('$type persists a transient reason and stops at the cap', () async {
      server.failure = DioException(
        requestOptions: RequestOptions(path: '/fixture'),
        type: type,
      );
      server.releaseAll();
      final service = buildService();
      await service.start();
      await addSongs(1);
      await database.downloadQueueDao.enqueue(
        DownloadQueueTableCompanion.insert(
          songId: const Value('song-0'),
          status: DownloadStatus.queued,
          addedAt: DateTime(2026),
          retryCount: const Value(maxRetries),
        ),
      );
      await service.processQueuedDownloads();
      final item = (await queue()).single;
      expect(
        item.failureReason,
        type == DioExceptionType.connectionError
            ? DownloadFailureReason.network
            : type == DioExceptionType.receiveTimeout
            ? DownloadFailureReason.timeout
            : DownloadFailureReason.unknown,
      );
      expect(item.retryCount, maxRetries);
      expect(item.status, DownloadStatus.failed);
      await service.setPaused(paused: true);
      await database.downloadQueueDao.retry(item.id);
      final retried = (await queue()).single;
      expect(retried.failureReason, isNull);
      expect(retried.failureDetail, isNull);
      expect(retried.retryCount, 0);
    }, skip: !sqliteAvailable);
  }

  test('offline waits without attempts, reconnect resumes and success clears the failure', () async {
    server.failure = DioException(
      requestOptions: RequestOptions(path: '/fixture'),
      type: DioExceptionType.connectionError,
    );
    server.beforeResponse = () => online = false;
    server.releaseAll();
    final service = buildService();
    await service.start();
    await addSongs(1);
    await service.enqueueSong('song-0');
    await service.processQueuedDownloads();
    final item = (await queue()).single;
    expect(item.failureReason, DownloadFailureReason.network);
    expect(item.retryCount, 0);
    expect(service.effectiveConcurrency, 0);
    await service.processQueuedDownloads();
    expect(server.requests, hasLength(1));
    server.failure = null;
    server.beforeResponse = null;
    online = true;
    await service.processQueuedDownloads();
    expect(server.requests, hasLength(2));
    expect(await queue(), isEmpty);
    expect(await database.cacheDao.getCachedTrack('song-0'), isNotNull);
  }, skip: !sqliteAvailable);

  test('an already offline queue never starts a transfer', () async {
    online = false;
    final service = buildService();
    await service.start();
    await addSongs(1);
    await service.enqueueSong('song-0');
    await service.processQueuedDownloads();
    expect(server.requests, isEmpty);
    expect((await queue()).single.retryCount, 0);
    online = true;
    server.releaseAll();
    await service.processQueuedDownloads();
    expect(await queue(), isEmpty);
  }, skip: !sqliteAvailable);

  for (final empty in [false, true]) {
    test(
      'real native gzip transport ${empty ? 'rejects empty audio' : 'registers complete original audio'}',
      () async {
        final previousHttp = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() => HttpOverrides.global = previousHttp);
        final payload = empty ? <int>[] : List<int>.filled(4096, 7);
        final compressed = gzip.encode(payload);
        expect(compressed.length, isNot(payload.length));
        final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var downloads = 0;
        final subscription = http.listen((request) async {
          if (request.uri.path.endsWith('/download.view')) {
            downloads++;
            request.response.headers.set(
              HttpHeaders.contentTypeHeader,
              'audio/mpeg',
            );
            request.response.headers.set(
              HttpHeaders.contentEncodingHeader,
              'gzip',
            );
            request.response.contentLength = compressed.length;
            request.response.add(compressed);
          } else {
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'subsonic-response': {'status': 'ok', 'version': '1.16.1'},
              }),
            );
          }
          await request.response.close();
        });
        addTearDown(() async {
          await subscription.cancel();
          await http.close(force: true);
        });
        api = SubsonicApiClient(
          baseUrl: 'http://127.0.0.1:${http.port}',
          authConfig: const SubsonicAuthConfig(
            username: 'fixture',
            password: 'fixture',
            apiVersion: '1.16.1',
          ),
          enableLogging: false,
        );
        final transport = Dio();
        addTearDown(() => transport.close(force: true));
        // Dio's real IOHttpClientAdapter and Dart's auto-decompression are used.
        final service = buildService(transport: transport);
        await service.start();
        await addSongs(1);
        await service.enqueueSong('song-0');
        await service.processQueuedDownloads();
        expect(downloads, 1);
        final cached = await database.cacheDao.getCachedTrack('song-0');
        if (empty) {
          expect(cached, isNull);
          expect(
            (await queue()).single.failureReason,
            DownloadFailureReason.truncated,
          );
        } else {
          expect(await queue(), isEmpty);
          expect(cached, isNotNull);
          expect(File(cached!.filePath).readAsBytesSync(), payload);
          expect(cached.fileSize, payload.length);
        }
      },
      skip: !sqliteAvailable,
    );
  }

  for (final empty in [false, true]) {
    test(
      'detects ${empty ? 'empty transcode' : 'truncated original'} before registration',
      () async {
        server.contentLength = empty ? null : 10;
        if (empty) server.bytes = [];
        server.releaseAll();
        final service = buildService();
        await service.start();
        await addSongs(1);
        await service.enqueueSong('song-0', quality: empty ? '192' : null);
        await service.processQueuedDownloads();
        final item = (await queue()).single;
        expect(item.failureReason, DownloadFailureReason.truncated);
        expect(item.failureDetail, empty ? 'Empty file' : '4 / 10 bytes');
        expect(item.retryCount, 1);
        expect(await database.cacheDao.getCachedTrack('song-0'), isNull);
        expect(
          supportDir
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.navis-part')),
          isEmpty,
        );
      },
      skip: !sqliteAvailable,
    );
  }

  test(
    'exact original size registers; estimated transcode length need not match',
    () async {
      final service = buildService();
      await service.start();
      await addSongs(2);
      server.contentLength = 4;
      server.releaseAll();
      await service.enqueueSong('song-0');
      await service.processQueuedDownloads();
      expect(await database.cacheDao.getCachedTrack('song-0'), isNotNull);
      server.contentLength = 100;
      await service.enqueueSong('song-1', quality: '192');
      await service.processQueuedDownloads();
      expect(await database.cacheDao.getCachedTrack('song-1'), isNotNull);
    },
    skip: !sqliteAvailable,
  );

  test('free space preflight holds all items and automatically resumes after space is freed', () async {
    var free = 1;
    final paths = <String>[];
    final service = buildService(
      readFreeBytes: (path) async {
        paths.add(path);
        return free;
      },
      folderRecheckInterval: const Duration(milliseconds: 20),
    );
    await service.start();
    await addSongs(2);
    await service.enqueueSong('song-0');
    await service.enqueueSong('song-1');
    await service.processQueuedDownloads();
    expect(service.folderProblem, DownloadFolderProblem.noSpace);
    expect(server.requests, isEmpty);
    expect(
      (await queue()).map((i) => i.failureReason),
      everyElement(DownloadFailureReason.noSpace),
    );
    expect((await queue()).map((i) => i.retryCount), everyElement(0));
    expect(paths, everyElement(p.join(supportDir.path, 'audio', 'permanent')));
    free = 1024 * 1024 * 1024;
    server.releaseAll();
    await waitUntil(() => server.requests.length == 2);
    await service.processQueuedDownloads();
    expect(await queue(), isEmpty);
  }, skip: !sqliteAvailable);

  test('SAF provider ENOSPC stays held across automatic rechecks and repeated failures', () async {
    const tree = 'content://fixture/tree/root';
    const channel = MethodChannel('com.navis.app/permanent_download_storage');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var writes = 0;
    var full = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'validateWritableTree':
          return {
            'uri': tree,
            'canRead': true,
            'canWrite': true,
            'canReplace': true,
          };
        case 'findDocument':
          return null;
        case 'writeFromFile':
          if ((call.arguments as Map)['relativePath'] ==
              '.navis-downloads.sqlite') {
            return 'content://fixture/document/index';
          }
          writes++;
          if (full) throw PlatformException(code: 'NO_SPACE');
          return 'content://fixture/document/audio';
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    server.releaseAll();
    final service = buildService(
      isAndroid: true,
      customEnabled: () => true,
      customPath: () => tree,
      readFreeBytes: (_) async => 1024 * 1024 * 1024,
      folderRecheckInterval: const Duration(milliseconds: 10),
    );
    await service.start();
    await addSongs(1);
    await service.enqueueSong('song-0');
    await service.processQueuedDownloads();
    expect(writes, 1);
    final finish = jsonDecode((await queue()).single.finishJournal!) as Map;
    expect(finish['phase'], 'verified');
    expect(
      finish['partPath'],
      isNull,
      reason: 'Renaming does not create another part file',
    );
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await service.processQueuedDownloads();
    }
    expect(
      writes,
      1,
      reason: 'Private staging space cannot clear provider exhaustion',
    );
    expect(server.requests, hasLength(1));
    expect(service.folderProblem, DownloadFolderProblem.noSpace);
    expect((await queue()).single.retryCount, 0);
    expect((await queue()).single.failureReason, DownloadFailureReason.noSpace);
    // Explicit repair may try once, but a repeated provider failure holds again.
    await service.refreshDownloadFolder();
    await service.processQueuedDownloads();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await service.processQueuedDownloads();
    expect(writes, 2);
    expect(server.requests, hasLength(2));
    expect((await queue()).single.retryCount, 0);
    full = false;
    await service.refreshDownloadFolder();
    await service.processQueuedDownloads();
    expect(writes, 3);
    expect(await queue(), isEmpty);
    expect(
      (await database.cacheDao.getCachedTrack('song-0'))!.storageKind,
      'androidSaf',
    );
  }, skip: !sqliteAvailable);

  test(
    'playlist warns through the existing notice when its estimate cannot fit',
    () async {
      final service = buildService(
        readFreeBytes: (_) async => 20 * 1024 * 1024,
      );
      final notices = <DownloadFolderProblem>[];
      final subscription = service.folderNotices.listen(notices.add);
      addTearDown(subscription.cancel);
      await service.setPaused(paused: true);
      await service.start();
      await database.libraryDao.upsertSongs([
        for (final id in ['a', 'b'])
          SongsTableCompanion.insert(
            id: id,
            title: id,
            size: const Value(8 * 1024 * 1024),
          ),
      ]);
      await service.enqueuePlaylist('playlist', ['a', 'b']);
      await Future<void>.delayed(Duration.zero);
      expect(notices, [DownloadFolderProblem.noSpace]);
      expect((await queue()).map((i) => i.retryCount), everyElement(0));
    },
    skip: !sqliteAvailable,
  );

  for (final wrapper in ['none', 'dio', 'folder']) {
    test(
      'write ENOSPC holds remaining items without retries, wrapper=$wrapper',
      () async {
        const error = FileSystemException(
          'Fixture full',
          '',
          OSError('ENOSPC', 28),
        );
        server.failure = switch (wrapper) {
          'dio' => DioException(
            requestOptions: RequestOptions(path: '/fixture'),
            error: error,
          ),
          'folder' => DownloadFolderUnavailableException(
            DownloadFolderProblem.inaccessible,
            osError: error.osError,
          ),
          _ => error,
        };
        server.releaseAll();
        final service = buildService();
        await service.start();
        await service.setMaxConcurrentDownloads(1);
        await addSongs(2);
        await service.enqueueSong('song-0');
        await service.enqueueSong('song-1');
        await service.processQueuedDownloads();
        expect(service.folderProblem, DownloadFolderProblem.noSpace);
        expect(server.requests, hasLength(1));
        expect((await queue()).map((i) => i.retryCount), everyElement(0));
        expect(
          (await queue()).map((i) => i.failureReason),
          everyElement(DownloadFailureReason.noSpace),
        );
      },
      skip: !sqliteAvailable,
    );
  }

  for (final phase in [
    'before rename',
    'after rename',
    'corrupt final',
    'missing final',
  ]) {
    test('startup recovers crash $phase using the finish journal', () async {
      await database.appSettingsDao.updateDownloadsPaused(paused: true);
      await addSongs(1);
      final root = Directory(p.join(supportDir.path, 'audio', 'permanent'));
      await root.create(recursive: true);
      final finalFile = File(p.join(root.path, 'Artist', 'Song 0.mp3'));
      await finalFile.parent.create();
      final part = File('${finalFile.path}.navis-part');
      await part.writeAsBytes([1, 2, 3, 4]);
      final id = await database.downloadQueueDao.enqueue(
        DownloadQueueTableCompanion.insert(
          songId: const Value('song-0'),
          status: DownloadStatus.downloading,
          addedAt: DateTime(2026),
        ),
      );
      await database.downloadQueueDao.writeFinishJournal(
        id,
        jsonEncode({
          'path': finalFile.path,
          'size': 4,
          'sha256': sha256.convert([1, 2, 3, 4]).toString(),
          'format': 'mp3',
          'bitRate': 192,
        }),
      );
      if (phase != 'before rename') await part.rename(finalFile.path);
      if (phase == 'corrupt final') await finalFile.writeAsBytes([4, 3, 2, 1]);
      if (phase == 'missing final') await finalFile.delete();
      final service = buildService();
      await service.start();
      if (phase == 'after rename') {
        expect(await queue(), isEmpty);
        expect(
          (await database.cacheDao.getCachedTrack('song-0'))!.filePath,
          finalFile.path,
        );
        expect(finalFile.existsSync(), isTrue);
      } else {
        expect((await queue()).single.status, DownloadStatus.queued);
        expect(
          (await queue()).single.finishJournal,
          phase == 'corrupt final' ? isNotNull : isNull,
        );
        expect(await database.cacheDao.getCachedTrack('song-0'), isNull);
        expect(finalFile.existsSync(), phase == 'corrupt final');
      }
      expect(part.existsSync(), isFalse);
      expect(server.requests, isEmpty);
      // Repeating startup is harmless.
      await service.stop();
      await service.start();
      expect(server.requests, isEmpty);
    }, skip: !sqliteAvailable);
  }

  for (final phase in ['verified', 'published']) {
    for (final saf in [false, true]) {
      test(
        'finish recovery preserves a foreign ${saf ? 'SAF' : 'filesystem'} replacement at phase $phase',
        () async {
          await database.appSettingsDao.updateDownloadsPaused(paused: true);
          await addSongs(1);
          const tree = 'content://fixture/tree/root';
          const replacement = 'content://fixture/document/replacement';
          const channel = MethodChannel(
            'com.navis.app/permanent_download_storage',
          );
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          final root = Directory(p.join(supportDir.path, 'custom'));
          await root.create();
          final file = File(p.join(root.path, 'replacement.mp3'));
          final deleted = <String>[];
          messenger.setMockMethodCallHandler(
            channel,
            (call) async => switch (call.method) {
              'validateWritableTree' => {
                'uri': tree,
                'canRead': true,
                'canWrite': true,
                'canReplace': true,
              },
              'findDocument' => replacement,
              'materialize' => (await file.copy(
                p.join(supportDir.path, 'copy.tmp'),
              )).path,
              'delete' => deleted.add((call.arguments as Map)['uri'] as String),
              _ => null,
            },
          );
          addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
          final id = await database.downloadQueueDao.enqueue(
            DownloadQueueTableCompanion.insert(
              songId: const Value('song-0'),
              status: DownloadStatus.downloading,
              addedAt: DateTime(2026),
            ),
          );
          await database.downloadQueueDao.writeFinishJournal(
            id,
            jsonEncode({
              'phase': phase,
              'path': saf
                  ? p.join(supportDir.path, 'audio', 'permanent', 'staging.mp3')
                  : file.path,
              'size': 4,
              'sha256': sha256.convert([1, 2, 3, 4]).toString(),
              'format': 'mp3',
              if (saf) 'treeUri': tree,
              if (saf) 'relativePath': 'Artist/Song.mp3',
              if (saf && phase == 'published')
                'publicationLocator': 'content://fixture/document/original',
            }),
          );
          await file.writeAsBytes([9, 8, 7, 6]);
          final service = buildService(
            isAndroid: saf,
            customEnabled: () => true,
            customPath: () => saf ? tree : root.path,
          );
          await service.start();
          expect(file.readAsBytesSync(), [9, 8, 7, 6]);
          expect(deleted, isEmpty);
          expect(await database.cacheDao.getCachedTrack('song-0'), isNull);
          expect((await queue()).single.status, DownloadStatus.queued);
          await service.stop();
          await service.start();
          expect(file.readAsBytesSync(), [9, 8, 7, 6]);
          expect(deleted, isEmpty);
        },
        skip: !sqliteAvailable,
      );
    }
  }

  test(
    'sign-out drains deferred recovery and rejects stale registration',
    () async {
      const tree = 'content://fixture/tree/root';
      const locator = 'content://fixture/document/audio';
      const channel = MethodChannel('com.navis.app/permanent_download_storage');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var accessible = false;
      final entered = Completer<void>();
      final release = Completer<void>();
      final materialized = File(p.join(supportDir.path, 'materialized.mp3'));
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'validateWritableTree':
            if (!accessible) throw PlatformException(code: 'PERMISSION_DENIED');
            return {
              'uri': tree,
              'canRead': true,
              'canWrite': true,
              'canReplace': true,
            };
          case 'findDocument':
            return locator;
          case 'materialize':
            entered.complete();
            await release.future;
            await materialized.writeAsBytes([1, 2, 3, 4]);
            return materialized.path;
          default:
            return null;
        }
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await database.appSettingsDao.updateDownloadsPaused(paused: true);
      await addSongs(1);
      final id = await database.downloadQueueDao.enqueue(
        DownloadQueueTableCompanion.insert(
          songId: const Value('song-0'),
          status: DownloadStatus.downloading,
          addedAt: DateTime(2026),
        ),
      );
      await database.downloadQueueDao.writeFinishJournal(
        id,
        jsonEncode({
          'phase': 'published',
          'publicationLocator': locator,
          'path': p.join(supportDir.path, 'audio', 'permanent', 'stage.mp3'),
          'treeUri': tree,
          'relativePath': 'Artist/Song.mp3',
          'size': 4,
          'sha256': sha256.convert([1, 2, 3, 4]).toString(),
          'format': 'mp3',
        }),
      );
      final service = buildService(
        isAndroid: true,
        customEnabled: () => true,
        customPath: () => tree,
      );
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      await service.start();
      accessible = true;
      final recovering = service.processQueuedDownloads();
      await entered.future;
      var stopped = false;
      final stopping = service.stopAndWait().then((_) {
        stopped = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final drainedEarly = stopped;
      release.complete();
      await stopping;
      // Draining alone is insufficient: a stale recovery must not register
      // even before the caller clears the server's data.
      expect(await database.cacheDao.getCachedTrack('song-0'), isNull);
      // Sign-out clears data only after the download service has drained.
      await database.downloadQueueDao.clearQueue();
      await database.cacheDao.removeCachedTrack('song-0');
      await recovering;
      expect(drainedEarly, isFalse);
      expect(await database.cacheDao.getCachedTrack('song-0'), isNull);
      expect(await queue(), isEmpty);
      expect(materialized.existsSync(), isFalse);
    },
    skip: !sqliteAvailable,
  );

  for (final localOnly in [false, true]) {
    test(
      'startup retains an inaccessible artist subtree, localOnly=$localOnly',
      () async {
        final custom = Directory(p.join(supportDir.path, 'custom'));
        final artist = Directory(p.join(custom.path, 'Artist'));
        await artist.create(recursive: true);
        final file = File(p.join(artist.path, 'Song.mp3'));
        await file.writeAsBytes([1, 2, 3, 4]);
        if (!localOnly) await addSongs(1);
        await database.appSettingsDao.updateDownloadsPaused(paused: true);
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'song-0',
            filePath: file.path,
            fileSize: 4,
            format: 'mp3',
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime(2026),
          ),
        );
        addTearDown(() async {
          await Process.run('chmod', ['700', artist.path]);
        });
        expect((await Process.run('chmod', ['000', artist.path])).exitCode, 0);
        // Establish the real dart:io behavior that triggered this regression.
        expect(file.statSync().type, FileSystemEntityType.notFound);
        final service = buildService(
          customEnabled: () => true,
          customPath: () => custom.path,
        );
        await service.start();
        final retained = await database.cacheDao.getCachedTrack('song-0');
        expect(retained, isNotNull);
        expect(retained!.filePath, file.path);
        expect(await queue(), isEmpty);
        expect(service.folderProblem, DownloadFolderProblem.inaccessible);
        expect((await Process.run('chmod', ['700', artist.path])).exitCode, 0);
        await service.refreshDownloadFolder();
        expect(service.folderProblem, isNull);
        expect(
          (await database.cacheDao.getCachedTrack('song-0'))!.filePath,
          file.path,
        );
        expect(file.readAsBytesSync(), [1, 2, 3, 4]);
        expect(server.requests, isEmpty);
      },
      skip: !sqliteAvailable || !Platform.isLinux,
    );
  }

  test(
    'startup requeues a registered download whose file is missing',
    () async {
      await database.appSettingsDao.updateDownloadsPaused(paused: true);
      await addSongs(1);
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'song-0',
          filePath: p.join(supportDir.path, 'audio', 'permanent', 'gone.mp3'),
          fileSize: 4,
          format: 'mp3',
          bitRate: const Value(192),
          cacheType: CacheType.permanent,
          downloadStatus: DownloadStatus.complete,
          lastAccessedAt: DateTime(2026),
        ),
      );
      final service = buildService();
      await service.start();
      expect(await database.cacheDao.getCachedTrack('song-0'), isNull);
      expect((await queue()).single.songId, 'song-0');
      expect((await queue()).single.quality, '192');
    },
    skip: !sqliteAvailable,
  );

  test(
    'custom cleanup preserves foreign suffix files without ownership',
    () async {
      final custom = Directory(p.join(supportDir.path, 'custom'));
      await custom.create();
      final part = File(p.join(custom.path, 'old.mp3.navis-part'));
      final foreign = File(p.join(custom.path, 'foreign.mp3'));
      final outside = File(p.join(supportDir.path, 'outside.mp3.navis-part'));
      await part.writeAsBytes([1]);
      await foreign.writeAsBytes([2]);
      await outside.writeAsBytes([3]);
      await Link(p.join(custom.path, 'linked.navis-part')).create(outside.path);
      final service = buildService(
        customEnabled: () => true,
        customPath: () => custom.path,
      );
      await service.start();
      expect(part.readAsBytesSync(), [1]);
      expect(foreign.readAsBytesSync(), [2]);
      expect(outside.existsSync(), isTrue);
      expect(
        Link(p.join(custom.path, 'linked.navis-part')).existsSync(),
        isTrue,
      );
    },
    skip: !sqliteAvailable || Platform.isWindows,
  );

  test('SAF startup preserves foreign suffix documents and checks staging capacity', () async {
    const channel = MethodChannel('com.navis.app/permanent_download_storage');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final deleted = <String>[];
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => switch (call.method) {
        'validateWritableTree' => {
          'uri': 'content://fixture/tree/root',
          'canRead': true,
          'canWrite': true,
          'canReplace': true,
        },
        'listRecursively' => [
          for (final name in ['old.mp3.navis-part', 'foreign.mp3'])
            {
              'uri': 'content://fixture/$name',
              'relativePath': name,
              'displayName': name,
              'size': 4,
            },
        ],
        'delete' => deleted.add((call.arguments as Map)['uri'] as String),
        _ => null,
      },
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final queried = <String>[];
    final service = buildService(
      isAndroid: true,
      customEnabled: () => true,
      customPath: () => 'content://fixture/tree/root',
      readFreeBytes: (path) async {
        queried.add(path);
        return 0;
      },
    );
    await service.start();
    expect(deleted, isEmpty);
    await addSongs(1);
    await service.enqueueSong('song-0');
    await service.processQueuedDownloads();
    expect(
      queried,
      everyElement(p.join(supportDir.path, 'audio', 'permanent')),
    );
    expect(service.folderProblem, DownloadFolderProblem.noSpace);
    expect(server.requests, isEmpty);
  }, skip: !sqliteAvailable);

  test('custom cleanup removes only the persisted owned part path', () async {
    await database.appSettingsDao.updateDownloadsPaused(paused: true);
    await addSongs(1);
    final custom = Directory(p.join(supportDir.path, 'custom'));
    await custom.create();
    final part = File(p.join(custom.path, 'owned.mp3.navis-part'));
    final foreign = File(p.join(custom.path, 'foreign.mp3.navis-part'));
    final id = await database.downloadQueueDao.enqueue(
      DownloadQueueTableCompanion.insert(
        songId: const Value('song-0'),
        status: DownloadStatus.downloading,
        addedAt: DateTime(2026),
      ),
    );
    await database.downloadQueueDao.writeFinishJournal(
      id,
      jsonEncode({'phase': 'transferring', 'partPath': part.path}),
    );
    await part.writeAsBytes([1]);
    await foreign.writeAsBytes([2]);
    final service = buildService(
      customEnabled: () => true,
      customPath: () => custom.path,
    );
    await service.start();
    expect(part.existsSync(), isFalse);
    expect(foreign.readAsBytesSync(), [2]);
    expect((await queue()).single.status, DownloadStatus.queued);
  }, skip: !sqliteAvailable);

  test(
    'a pre-existing transfer part name is preserved and never downloaded over',
    () async {
      await addSongs(1);
      final custom = Directory(p.join(supportDir.path, 'custom'));
      final part = File(p.join(custom.path, 'Artist', 'Song 0.mp3.navis-part'));
      await part.parent.create(recursive: true);
      await part.writeAsBytes([9, 8, 7, 6]);
      final service = buildService(
        customEnabled: () => true,
        customPath: () => custom.path,
      );
      await service.start();
      await service.enqueueSong('song-0');
      await service.processQueuedDownloads();
      expect(part.readAsBytesSync(), [9, 8, 7, 6]);
      expect(server.requests, isEmpty);
      expect(await database.cacheDao.getCachedTrack('song-0'), isNull);
    },
    skip: !sqliteAvailable,
  );

  test(
    'part ownership is journaled before the transfer writes bytes',
    () async {
      await addSongs(1);
      final service = buildService();
      await service.start();
      await service.enqueueSong('song-0');
      await waitUntil(() => server.active == 1);
      final journal = jsonDecode((await queue()).single.finishJournal!) as Map;
      expect(journal['phase'], 'transferring');
      expect(File(journal['partPath'] as String).existsSync(), isTrue);
      await service.stopAndWait();
    },
    skip: !sqliteAvailable,
  );

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

  for (final problem in [
    DownloadFolderProblem.unset,
    DownloadFolderProblem.missing,
    DownloadFolderProblem.inaccessible,
  ]) {
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
        expect(
          held.map((i) => i.failureReason),
          everyElement(
            problem == DownloadFolderProblem.inaccessible
                ? DownloadFailureReason.permission
                : DownloadFailureReason.folderUnavailable,
          ),
        );
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
    expect((await queue()).single.retryCount, 0);
    expect(
      (await queue()).single.failureReason,
      DownloadFailureReason.notAudio,
    );
    expect((await queue()).single.status, DownloadStatus.failed);
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
