import 'dart:async';

import 'package:navis/src/utils/constants.dart';

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:file/file.dart' as files;
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/common_widgets/cover_art_recovery.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/integrations/data/integration_call_recorder.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';

import '../../helpers/test_database.dart';

class _MockCacheManager extends Mock implements CacheManager;

class _TestCacheFileSystem implements FileSystem {
  new(this.directory);

  final Directory directory;
  final files.FileSystem _fileSystem = const LocalFileSystem();

  @override
  Future<files.File> createFile(String name) async =>
      _fileSystem.file(_fileSystem.path.join(directory.path, name));
}

class _FailingCacheRepository extends JsonCacheInfoRepository {
  new({required super.path});

  @override
  Future<CacheObject> insert(
    CacheObject cacheObject, {
    bool setTouchedToNow = true,
  }) async => throw StateError('Metadata write failed');
}

void main() {
  group('external artwork recording', () {
    late HttpServer server;
    late IntegrationCallRecorder recorder;
    var requests = 0;
    String? userAgent;
    var status = HttpStatus.ok;
    var imageBody = true;
    List<int>? payload;

    setUp(() async {
      requests = 0;
      status = HttpStatus.ok;
      imageBody = true;
      payload = null;
      recorder = IntegrationCallRecorder(logCalls: false);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests++;
        userAgent = request.headers.value(HttpHeaders.userAgentHeader);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        request.response
          ..statusCode = status
          ..headers.contentType = ContentType('image', 'jpeg')
          ..add(
            payload ??
                (imageBody ? <int>[0xff, 0xd8, 0xff, 1] : <int>[1, 2, 3]),
          );
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
    });

    CoverArtHttpFileService build({bool allowed = true, bool own = false}) {
      final service = CoverArtHttpFileService(
        recorder: recorder,
        allowUri: (_) => allowed,
        isServerUri: (_) => own,
      );
      addTearDown(service.close);
      return service;
    }

    String url() =>
        'http://fixture-user:fixture-password@127.0.0.1:'
        '${server.port}/users/private/cover.jpg?token=fixture-secret#fragment';

    test(
      'allowed external art records status duration and redacted path',
      () async {
        final response = await build().get(url());
        await response.content.drain<void>();
        expect(userAgent, AppConstants.userAgent);
        final call = recorder.recentCalls().single;
        expect(call.service, IntegrationFeature.artworkServerLinked.service);
        expect(call.method, 'GET');
        expect(call.outcome, IntegrationCallOutcome.ok);
        expect(call.statusCode, HttpStatus.ok);
        expect(call.durationMs, greaterThanOrEqualTo(10));
        expect(call.path, '/users/*/cover.jpg');
        final json = recorder.toJson().toString();
        for (final secret in [
          'fixture-user',
          'fixture-password',
          'fixture-secret',
          'private',
          'fragment',
        ]) {
          expect(json, isNot(contains(secret)));
        }
        expect(
          recorder
              .countersFor(IntegrationFeature.artworkServerLinked.service)
              .requests,
          1,
        );
      },
    );

    test('refused external art records blocked without dispatch', () async {
      await expectLater(
        build(allowed: false).get(url()),
        throwsA(isA<CoverArtBlockedException>()),
      );
      expect(requests, 0);
      expect(
        recorder.recentCalls().single.outcome,
        IntegrationCallOutcome.blocked,
      );
      expect(
        recorder
            .countersFor(IntegrationFeature.artworkServerLinked.service)
            .requests,
        0,
      );
      expect(
        recorder
            .countersFor(IntegrationFeature.artworkServerLinked.service)
            .blocked,
        1,
      );
    });

    for (final brand in [
      'avif',
      'avis',
      'heic',
      'heix',
      'hevc',
      'mif1',
      'msf1',
    ]) {
      for (final compatible in [false, true]) {
        test('accepts ISO-BMFF $brand (compatible=$compatible)', () async {
          payload = [
            0,
            0,
            0,
            if (compatible) 24 else 16,
            ...'ftyp'.codeUnits,
            ...(compatible ? 'isom' : brand).codeUnits,
            0,
            0,
            0,
            0,
            if (compatible) ...'isom$brand'.codeUnits,
          ];
          final response = await build().get(url());
          expect(
            await response.content.expand((chunk) => chunk).toList(),
            payload,
          );
          expect(
            recorder.recentCalls().single.outcome,
            IntegrationCallOutcome.ok,
          );
        });
      }
    }
    for (final signature in [
      <int>[0x49, 0x49, 0x2a, 0],
      <int>[0x4d, 0x4d, 0, 0x2a],
    ]) {
      test('accepts TIFF signature $signature', () async {
        payload = signature;
        final response = await build().get(url());
        expect(
          await response.content.expand((chunk) => chunk).toList(),
          payload,
        );
      });
    }
    test('rejects non-image ISO-BMFF brands', () async {
      payload = [0, 0, 0, 16, ...'ftypisom'.codeUnits, 0, 0, 0, 0];
      final response = await build().get(url());
      await expectLater(
        response.content.drain<void>(),
        throwsA(isA<CoverArtInvalidResponseException>()),
      );
    });

    test('invalid image bytes record a failed HTTP success', () async {
      imageBody = false;
      final response = await build().get(url());
      await expectLater(
        response.content.drain<void>(),
        throwsA(isA<CoverArtInvalidResponseException>()),
      );
      final call = recorder.recentCalls().single;
      expect(call.statusCode, HttpStatus.ok);
      expect(call.outcome, IntegrationCallOutcome.error);
    });

    test('connection failures record an error without a status', () async {
      final unused = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = unused.port;
      await unused.close(force: true);
      await expectLater(
        build().get('http://127.0.0.1:$port/cover.jpg?token=fixture-secret'),
        throwsA(isA<SocketException>()),
      );
      final call = recorder.recentCalls().single;
      expect(call.statusCode, isNull);
      expect(call.outcome, IntegrationCallOutcome.error);
      expect(call.path, '/cover.jpg');
    });

    test('own-server art is excluded', () async {
      final response = await build(own: true).get(url());
      await response.content.drain<void>();
      expect(requests, 1);
      expect(recorder.recentCalls(), isEmpty);
    });

    test('external HTTP failures are recorded once', () async {
      status = HttpStatus.notFound;
      await expectLater(
        build().get(url()),
        throwsA(isA<CoverArtFetchException>()),
      );
      final call = recorder.recentCalls().single;
      expect(call.outcome, IntegrationCallOutcome.error);
      expect(call.statusCode, HttpStatus.notFound);
      expect(
        recorder
            .countersFor(IntegrationFeature.artworkServerLinked.service)
            .errors,
        1,
      );
    });
  });

  group('cover-art cache persistence', () {
    late Directory directory;
    late String metadataPath;
    late _TestCacheFileSystem fileSystem;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'navis-art-persistence-',
      );
      metadataPath = directory.uri.resolve('metadata.json').toFilePath();
      fileSystem = _TestCacheFileSystem(directory);
    });
    tearDown(() => directory.delete(recursive: true));

    CacheManager createManager(CacheInfoRepository repository) => CacheManager(
      Config('art-persistence-test', repo: repository, fileSystem: fileSystem),
    );

    test(
      'metadata survives immediate close and reopen after putFile',
      () async {
        final manager = createManager(
          JsonCacheInfoRepository(path: metadataPath),
        );
        await manager.putFile(
          'https://example.com/cover',
          Uint8List.fromList(<int>[1, 2, 3]),
          key: 'cover-1:600',
        );
        await manager.dispose();

        final reopened = createManager(
          JsonCacheInfoRepository(path: metadataPath),
        );
        addTearDown(reopened.dispose);
        final cached = await reopened.getFileFromCache('cover-1:600');
        expect(cached, isNotNull);
        expect(await cached!.file.readAsBytes(), <int>[1, 2, 3]);
      },
    );

    for (final streamed in <bool>[false, true]) {
      test(
        '${streamed ? 'putFileStream' : 'putFile'} exposes metadata write failure',
        () async {
          final manager = createManager(
            _FailingCacheRepository(path: metadataPath),
          );
          addTearDown(manager.dispose);
          final operation = streamed
              ? manager.putFileStream(
                  'https://example.com/cover',
                  Stream<List<int>>.value(<int>[1, 2, 3]),
                  key: 'cover-1:600',
                )
              : manager.putFile(
                  'https://example.com/cover',
                  Uint8List.fromList(<int>[1, 2, 3]),
                  key: 'cover-1:600',
                );
          await expectLater(operation, throwsStateError);
        },
      );
    }
  });

  group('coverArtImageCacheKey', () {
    test('uses stable cover-art ID and size instead of URL salt', () {
      expect(coverArtImageCacheKey(' cover-1 ', 600), 'cover-1:600');
      expect(coverArtImageCacheKey('cover-1', null), 'cover-1:0');
    });

    test('revision zero keeps the legacy key layout', () {
      expect(coverArtImageCacheKey('cover-1', 600, revision: 0), 'cover-1:600');
      expect(
        coverArtImageCacheKey('cover-1', 600, revision: null),
        'cover-1:600',
      );
    });

    test('a bumped revision produces a distinct targeted key', () {
      expect(
        coverArtImageCacheKey('cover-1', 600, revision: 1),
        'cover-1:r1:600',
      );
      expect(
        coverArtImageCacheKey('cover-1', 600, revision: 1),
        isNot(coverArtImageCacheKey('cover-1', 600, revision: 2)),
      );
    });
  });

  group('CoverArtLoadCoordinator', () {
    test('cancels older offscreen requests before network admission', () async {
      final coordinator = CoverArtLoadCoordinator(
        maxActiveDownloads: 1,
        criticalReserve: 0,
      );
      final blocker = await coordinator.acquire('blocker');
      final interest = coordinator.trackInterest(
        'cover-1:600',
        CoverArtLoadPriority.visible,
      );
      final queued = coordinator.acquire('cover-1:600');
      unawaited(queued.then<void>((_) {}, onError: (_, _) {}));

      interest.dispose();

      await expectLater(queued, throwsA(isA<CoverArtLoadCanceledException>()));
      expect(coordinator.queuedCount, 0);

      blocker.release();
    });

    test(
      'newly visible requests jump ahead of older background work',
      () async {
        final coordinator = CoverArtLoadCoordinator(
          maxActiveDownloads: 1,
          criticalReserve: 0,
        );
        final blocker = await coordinator.acquire('blocker');
        final background = coordinator.acquire('background:600');
        coordinator.trackInterest('visible:600', CoverArtLoadPriority.visible);
        final visible = coordinator.acquire('visible:600');

        blocker.release();
        final visibleLease = await visible.timeout(const Duration(seconds: 1));

        expect(coordinator.activeCount, 1);
        visibleLease.release();
        final backgroundLease = await background.timeout(
          const Duration(seconds: 1),
        );
        backgroundLease.release();
      },
    );

    test('critical requests use reserved capacity', () async {
      final coordinator = CoverArtLoadCoordinator(maxActiveDownloads: 2);
      coordinator.trackInterest('visible-1:600', CoverArtLoadPriority.visible);
      coordinator.trackInterest('visible-2:600', CoverArtLoadPriority.visible);
      coordinator.trackInterest('critical:600', CoverArtLoadPriority.critical);

      final visible1 = await coordinator.acquire('visible-1:600');
      final visible2 = coordinator.acquire('visible-2:600');
      final critical = await coordinator
          .acquire('critical:600')
          .timeout(const Duration(seconds: 1));

      expect(coordinator.activeCount, 2);
      await expectLater(
        visible2.timeout(const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()),
      );

      critical.release();
      visible1.release();
      final visible2Lease = await visible2.timeout(const Duration(seconds: 1));
      visible2Lease.release();
    });

    test('duplicate widgets share one pending and active request', () async {
      final coordinator = CoverArtLoadCoordinator(
        maxActiveDownloads: 1,
        criticalReserve: 0,
      );
      final blocker = await coordinator.acquire('blocker');
      final firstInterest = coordinator.trackInterest(
        'cover-1:600',
        CoverArtLoadPriority.visible,
      );
      final secondInterest = coordinator.trackInterest(
        'cover-1:600',
        CoverArtLoadPriority.visible,
      );

      final first = coordinator.acquire('cover-1:600');
      final second = coordinator.acquire('cover-1:600');

      expect(coordinator.queuedCount, 1);
      blocker.release();
      final firstLease = await first.timeout(const Duration(seconds: 1));
      final secondLease = await second.timeout(const Duration(seconds: 1));

      expect(coordinator.activeCount, 1);
      firstLease.release();
      expect(coordinator.activeCount, 1);
      secondLease.release();
      expect(coordinator.activeCount, 0);

      firstInterest.dispose();
      secondInterest.dispose();
    });
  });

  group('CoverArtHttpFileService', () {
    test('times out stalled response headers', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final service = CoverArtHttpFileService(
        connectionTimeout: const Duration(milliseconds: 50),
        responseTimeout: const Duration(milliseconds: 50),
        bodyReadTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(service.close);
      addTearDown(() => server.close(force: true));

      server.listen((request) {
        if (request.uri.queryParameters['id'] == 'cover-ok') {
          request.response.headers.contentType = ContentType('image', 'jpeg');
          request.response.add(<int>[0xff, 0xd8, 0xff, 0xd9]);
          unawaited(request.response.close());
          return;
        }
        // Intentionally leave the response open without headers.
      });

      final url = _coverArtUrl(server, id: 'cover-1');

      await expectLater(service.get(url), throwsA(isA<TimeoutException>()));

      final response = await service.get(_coverArtUrl(server, id: 'cover-ok'));

      expect(response.statusCode, HttpStatus.ok);
      expect(
        await response.content.expand((bytes) => bytes).toList(),
        hasLength(4),
      );
    });

    test(
      'recovers after stalled requests fill every connection slot',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final service = CoverArtHttpFileService(
          connectionTimeout: const Duration(milliseconds: 50),
          responseTimeout: const Duration(milliseconds: 50),
          bodyReadTimeout: const Duration(milliseconds: 50),
        );
        addTearDown(service.close);
        addTearDown(() => server.close(force: true));

        server.listen((request) {
          if (request.uri.queryParameters['id'] == 'cover-ok') {
            request.response.headers.contentType = ContentType('image', 'jpeg');
            request.response.add(<int>[0xff, 0xd8, 0xff, 0xd9]);
            unawaited(request.response.close());
            return;
          }
          // Intentionally leave the response open without headers.
        });

        final stalledRequests = List<Future<Object?>>.generate(4, (index) {
          return service
              .get(_coverArtUrl(server, id: 'cover-stalled-$index'))
              .then<Object?>(
                (_) => null,
                onError: (Object error, StackTrace _) => error,
              );
        });

        final failures = await Future.wait(stalledRequests);
        expect(failures.whereType<TimeoutException>(), isNotEmpty);
        expect(failures.where((failure) => failure != null), hasLength(4));

        final response = await service.get(
          _coverArtUrl(server, id: 'cover-ok'),
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(
          await response.content.expand((bytes) => bytes).toList(),
          hasLength(4),
        );
      },
    );

    test('times out stalled response bodies', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final recorder = IntegrationCallRecorder(logCalls: false);
      final service = CoverArtHttpFileService(
        recorder: recorder,
        isServerUri: (_) => false,
        connectionTimeout: const Duration(milliseconds: 50),
        responseTimeout: const Duration(milliseconds: 50),
        bodyReadTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(service.close);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        if (request.uri.queryParameters['id'] == 'cover-ok') {
          request.response.headers.contentType = ContentType('image', 'jpeg');
          request.response.add(<int>[0xff, 0xd8, 0xff, 0xd9]);
          unawaited(request.response.close());
          return;
        }
        request.response.headers.contentType = ContentType('image', 'jpeg');
        request.response.add(<int>[0xff, 0xd8]);
        await request.response.flush();
        // Intentionally leave the body open so the client must time out.
      });

      final url = _coverArtUrl(server, id: 'cover-2');

      final response = await service.get(url);

      expect(response.statusCode, HttpStatus.ok);
      await expectLater(
        response.content.drain<void>(),
        throwsA(isA<TimeoutException>()),
      );

      expect(
        recorder.recentCalls().single.outcome,
        IntegrationCallOutcome.error,
      );
      expect(recorder.recentCalls().single.statusCode, HttpStatus.ok);
      final nextResponse = await service.get(
        _coverArtUrl(server, id: 'cover-ok'),
      );

      expect(nextResponse.statusCode, HttpStatus.ok);
      expect(
        await nextResponse.content.expand((bytes) => bytes).toList(),
        hasLength(4),
      );
    });

    test(
      'unconsumed not-modified responses release coordinator slots',
      () async {
        final coordinator = CoverArtLoadCoordinator();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final service = CoverArtHttpFileService(
          loadCoordinator: coordinator,
          connectionTimeout: const Duration(milliseconds: 50),
          responseTimeout: const Duration(milliseconds: 50),
          bodyReadTimeout: const Duration(milliseconds: 50),
        );
        addTearDown(service.close);
        addTearDown(() => server.close(force: true));

        server.listen((request) {
          final id = request.uri.queryParameters['id'] ?? '';
          if (id == 'cover-ok') {
            request.response.headers.contentType = ContentType('image', 'jpeg');
            request.response.add(_tinyJpeg);
            unawaited(request.response.close());
            return;
          }
          request.response.statusCode = HttpStatus.notModified;
          request.response.headers.set(HttpHeaders.etagHeader, '"$id"');
          unawaited(request.response.close());
        });

        final notModified = await Future.wait(
          List<Future<FileServiceResponse>>.generate(4, (index) {
            return service.get(
              _coverArtUrl(server, id: 'cover-not-modified-$index'),
            );
          }),
        );

        expect(
          notModified.map((response) => response.statusCode),
          everyElement(HttpStatus.notModified),
        );
        expect(coordinator.activeCount, 0);

        final nextResponse = await service
            .get(_coverArtUrl(server, id: 'cover-ok'))
            .timeout(const Duration(seconds: 1));

        expect(nextResponse.statusCode, HttpStatus.ok);
        expect(
          await nextResponse.content.expand((bytes) => bytes).toList(),
          hasLength(4),
        );
      },
    );

    test('unconsumed invalid responses do not exhaust slots', () async {
      final coordinator = CoverArtLoadCoordinator();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final service = CoverArtHttpFileService(
        loadCoordinator: coordinator,
        connectionTimeout: const Duration(milliseconds: 50),
        responseTimeout: const Duration(milliseconds: 50),
        bodyReadTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(service.close);
      addTearDown(() => server.close(force: true));

      server.listen((request) {
        final id = request.uri.queryParameters['id'] ?? '';
        if (id == 'cover-ok') {
          request.response.headers.contentType = ContentType('image', 'jpeg');
          request.response.add(_tinyJpeg);
          unawaited(request.response.close());
          return;
        }
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('missing $id');
        unawaited(request.response.close());
      });

      // A typed missing-reference failure surfaces for every 404 while all
      // coordinator slots are released.
      final missing = await Future.wait(
        List<Future<Object?>>.generate(8, (index) {
          return service
              .get(_coverArtUrl(server, id: 'cover-missing-$index'))
              .then<Object?>((response) => response)
              .catchError((Object error) => error);
        }),
      );

      expect(missing.whereType<CoverArtFetchException>(), hasLength(8));
      expect(
        missing.whereType<CoverArtFetchException>().map(
          (error) => error.category,
        ),
        everyElement(CoverArtFailureCategory.missingCoverReference),
      );
      expect(coordinator.activeCount, 0);

      final nextResponse = await service
          .get(_coverArtUrl(server, id: 'cover-ok'))
          .timeout(const Duration(seconds: 1));

      expect(nextResponse.statusCode, HttpStatus.ok);
      expect(
        await nextResponse.content.expand((bytes) => bytes).toList(),
        hasLength(4),
      );
    });

    test('rapid stale visible requests do not reach the server', () async {
      final coordinator = CoverArtLoadCoordinator(
        maxActiveDownloads: 1,
        criticalReserve: 0,
      );
      final service = CoverArtHttpFileService(
        loadCoordinator: coordinator,
        connectionTimeout: const Duration(milliseconds: 100),
        responseTimeout: const Duration(milliseconds: 100),
        bodyReadTimeout: const Duration(milliseconds: 100),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      late HttpResponse blockerResponse;
      addTearDown(service.close);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        final id = request.uri.queryParameters['id'] ?? '';
        requests.add(id);
        request.response.headers.contentType = ContentType('image', 'jpeg');
        if (id == 'blocker') {
          blockerResponse = request.response;
          request.response.add(<int>[0xff, 0xd8]);
          await request.response.flush();
          return;
        }
        request.response.add(_tinyJpeg);
        unawaited(request.response.close());
      });

      final blocker = await service.get(_coverArtUrl(server, id: 'blocker'));
      final queued = <Future<FileServiceResponse>>[];
      for (var index = 0; index < 8; index++) {
        final id = 'stale-$index';
        final key = coverArtImageCacheKey(id, 600);
        final interest = coordinator.trackInterest(
          key,
          CoverArtLoadPriority.visible,
        );
        final future = service.get(_coverArtUrl(server, id: id));
        unawaited(future.then<void>((_) {}, onError: (_, _) {}));
        queued.add(future);
        interest.dispose();
      }

      for (final future in queued) {
        await expectLater(
          future,
          throwsA(isA<CoverArtLoadCanceledException>()),
        );
      }
      await blockerResponse.close();
      await blocker.content.drain<void>();

      expect(requests, <String>['blocker']);
    });

    test('visible requests are started before older background work', () async {
      final coordinator = CoverArtLoadCoordinator(
        maxActiveDownloads: 1,
        criticalReserve: 0,
      );
      final service = CoverArtHttpFileService(
        loadCoordinator: coordinator,
        connectionTimeout: const Duration(milliseconds: 100),
        responseTimeout: const Duration(milliseconds: 100),
        bodyReadTimeout: const Duration(milliseconds: 100),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      late HttpResponse blockerResponse;
      addTearDown(service.close);
      addTearDown(() => server.close(force: true));

      server.listen((request) async {
        final id = request.uri.queryParameters['id'] ?? '';
        requests.add(id);
        request.response.headers.contentType = ContentType('image', 'jpeg');
        if (id == 'blocker') {
          blockerResponse = request.response;
          request.response.add(<int>[0xff, 0xd8]);
          await request.response.flush();
          return;
        }
        request.response.add(_tinyJpeg);
        unawaited(request.response.close());
      });

      final blocker = await service.get(_coverArtUrl(server, id: 'blocker'));
      final background = service.get(_coverArtUrl(server, id: 'background'));
      final visibleInterest = coordinator.trackInterest(
        coverArtImageCacheKey('visible', 600),
        CoverArtLoadPriority.visible,
      );
      final visible = service.get(_coverArtUrl(server, id: 'visible'));

      await blockerResponse.close();
      await blocker.content.drain<void>();
      final visibleResponse = await visible.timeout(const Duration(seconds: 1));
      await visibleResponse.content.drain<void>();
      final backgroundResponse = await background.timeout(
        const Duration(seconds: 1),
      );
      await backgroundResponse.content.drain<void>();
      visibleInterest.dispose();

      expect(requests.take(2), <String>['blocker', 'visible']);
      expect(requests, contains('background'));
    });
  });

  group('CoverArtRecoveryCoordinator', () {
    test(
      'corrupt entries are evicted exactly once per key and never loop',
      () async {
        final coordinator = CoverArtRecoveryCoordinator();
        final manager = _MockCacheManager();
        var removals = 0;
        when(() => manager.removeFile(any()))
            .thenAnswer((_) async => removals++);

        final first = await coordinator.handleInvalidCacheEntry(
          cacheKey: 'al-1:r2:600',
          cacheManager: manager,
        );
        final second = await coordinator.handleInvalidCacheEntry(
          cacheKey: 'al-1:r2:600',
          cacheManager: manager,
        );

        expect(first, isTrue);
        // The repeated build is bounded: no second eviction, no refetch loop.
        expect(second, isFalse);
        expect(removals, 1);
        verify(() => manager.removeFile('al-1:r2:600')).called(1);
        expect(coverArtImageCacheKey('al-1', 600, revision: 2), 'al-1:r2:600');
      },
      skip: !sqliteAvailable,
    );

    test(
      'missing cover references coalesce into one refresh with a cooldown',
      () async {
        var refreshes = 0;
        final coordinator = CoverArtRecoveryCoordinator(
          refreshEntityForCover: (coverArtId) async {
            refreshes++;
            await Future<void>.delayed(const Duration(milliseconds: 5));
          },
        );

        // Repeated builds of the same cover share one in-flight refresh and
        // are cooldown-bounded to a single refresh per session.
        await Future.wait(<Future<void>>[
          coordinator.handleMissingCover('al-nier-a'),
          coordinator.handleMissingCover('al-nier-a'),
          coordinator.handleMissingCover('al-nier-a'),
        ]);
        await coordinator.handleMissingCover('al-nier-a');

        expect(refreshes, 1);
      },
      skip: !sqliteAvailable,
    );

    test('failure taxonomy classifies the five plan categories', () {
      expect(
        classifyCoverArtFailure(
          const CoverArtFetchException(
            CoverArtFailureCategory.missingCoverReference,
            statusCode: 404,
          ),
        ),
        CoverArtFailureCategory.missingCoverReference,
      );
      expect(
        classifyCoverArtFailure(
          const CoverArtFetchException(
            CoverArtFailureCategory.authRejection,
            statusCode: 403,
          ),
        ),
        CoverArtFailureCategory.authRejection,
      );
      expect(
        classifyCoverArtFailure(TimeoutException('timed out')),
        CoverArtFailureCategory.networkTimeout,
      );
      expect(
        classifyCoverArtFailure(
          const CoverArtInvalidResponseException('text/html'),
        ),
        CoverArtFailureCategory.invalidPayload,
      );
      expect(
        classifyCoverArtFailure(const FormatException('cannot decode')),
        CoverArtFailureCategory.transport,
      );
      expect(
        classifyCoverArtFailure(
          const CoverArtFetchException(CoverArtFailureCategory.decodeFailure),
        ),
        CoverArtFailureCategory.decodeFailure,
      );
    });
  });

  group('HTTP 200 non-image payloads (Navidrome missing artwork)', () {
    final recoveredIds = <String>[];
    late CoverArtLoadCoordinator coordinator;
    late CoverArtHttpFileService service;
    late HttpServer server;

    setUp(() async {
      recoveredIds.clear();
      coordinator = CoverArtLoadCoordinator();
      service = CoverArtHttpFileService(
        loadCoordinator: coordinator,
        connectionTimeout: const Duration(milliseconds: 100),
        responseTimeout: const Duration(milliseconds: 100),
        bodyReadTimeout: const Duration(milliseconds: 100),
        onMissingCover: recoveredIds.add,
      );
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(service.close);
      addTearDown(() => server.close(force: true));
    });

    void serve({
      required String id,
      required ContentType contentType,
      required List<int> body,
      int status = HttpStatus.ok,
    }) {
      server.listen((request) {
        request.response.statusCode = status;
        request.response.headers.contentType = contentType;
        request.response.add(body);
        unawaited(request.response.close());
      });
    }

    final errorDocumentBody = <int>[
      ...'{"subsonic-response":{"status":"failed","version":"1.16.1"},'
              '"error":{"code":0,"message":"not found"}}'
          .codeUnits,
    ];

    test('a Subsonic error document under HTTP 200 triggers missing-cover recovery', () async {
      serve(
        id: 'cover-doc',
        contentType: ContentType('application', 'json'),
        body: errorDocumentBody,
      );

      await expectLater(
        service.get(_coverArtUrl(server, id: 'cover-doc')),
        throwsA(
          isA<CoverArtFetchException>().having(
            (error) => error.category,
            'category',
            CoverArtFailureCategory.missingCoverReference,
          ),
        ),
      );
      expect(recoveredIds, ['cover-doc']);
      expect(coordinator.activeCount, 0);
    });

    test(
      'a non-image success body without an error envelope stays invalidPayload',
      () async {
        serve(
          id: 'cover-html',
          contentType: ContentType.html,
          body: '<html><body>proxy login</body></html>'.codeUnits,
        );

        await expectLater(
          service.get(_coverArtUrl(server, id: 'cover-html')),
          throwsA(isA<CoverArtInvalidResponseException>()),
        );
        expect(recoveredIds, isEmpty);
        expect(coordinator.activeCount, 0);
      },
    );

    test(
      'a spoofed image content type with error-document bytes rejects on read',
      () async {
        serve(
          id: 'cover-spoofed-error',
          contentType: ContentType('image', 'jpeg'),
          body: errorDocumentBody,
        );

        final response = await service
            .get(_coverArtUrl(server, id: 'cover-spoofed-error'))
            .timeout(const Duration(seconds: 1));
        await expectLater(
          response.content.expand((chunk) => chunk).toList(),
          throwsA(
            isA<CoverArtFetchException>().having(
              (error) => error.category,
              'category',
              CoverArtFailureCategory.missingCoverReference,
            ),
          ),
        );
        expect(recoveredIds, ['cover-spoofed-error']);
      },
    );

    test('a spoofed image content type with garbage bytes rejects without recovery', () async {
      serve(
        id: 'cover-spoofed-garbage',
        contentType: ContentType('image', 'jpeg'),
        body: 'this is definitely not artwork'.codeUnits,
      );

      final response = await service
          .get(_coverArtUrl(server, id: 'cover-spoofed-garbage'))
          .timeout(const Duration(seconds: 1));
      await expectLater(
        response.content.expand((chunk) => chunk).toList(),
        throwsA(isA<CoverArtInvalidResponseException>()),
      );
      expect(recoveredIds, isEmpty);
    });

    test('an empty success body rejects as an invalid payload', () async {
      serve(
        id: 'cover-empty',
        contentType: ContentType('image', 'jpeg'),
        body: const <int>[],
      );

      final response = await service
          .get(_coverArtUrl(server, id: 'cover-empty'))
          .timeout(const Duration(seconds: 1));
      await expectLater(
        response.content.expand((chunk) => chunk).toList(),
        throwsA(isA<CoverArtInvalidResponseException>()),
      );
      expect(recoveredIds, isEmpty);
    });

    test('image bytes keep flowing to the consumer', () async {
      serve(
        id: 'cover-ok',
        contentType: ContentType('image', 'jpeg'),
        body: _tinyJpeg,
      );

      final response = await service
          .get(_coverArtUrl(server, id: 'cover-ok'))
          .timeout(const Duration(seconds: 1));
      expect(
        await response.content.expand((chunk) => chunk).toList(),
        _tinyJpeg,
      );
      expect(recoveredIds, isEmpty);
    });
  });

  group('NieR shared-title artwork identity (plan F9)', () {
    test(
      'two releases sharing a title keep distinct artwork identities',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        await database.serverDao.saveServer(
          ServerConfigTableCompanion.insert(
            url: 'https://example.test',
            username: 'fixture',
            apiVersion: '1.16.1',
          ),
        );
        // Two distinct releases with the identical album title.
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'al-nier-a',
            name: 'NieR:Automata Original Soundtrack',
            coverArt: const Value('al-nier-a'),
          ),
          AlbumsTableCompanion.insert(
            id: 'al-nier-b',
            name: 'NieR:Automata Original Soundtrack',
            coverArt: const Value('al-nier-b'),
          ),
        ]);

        // Distinct cover IDs produce distinct cache keys, so neither
        // release's artwork can satisfy the other's request.
        final keyA = coverArtImageCacheKey('al-nier-a', 600);
        final keyB = coverArtImageCacheKey('al-nier-b', 600);
        expect(keyA, isNot(keyB));

        // A targeted revision bump on one release cannot leak into the
        // other: the revision is scoped between the ID and the size.
        final keyA2 = coverArtImageCacheKey('al-nier-a', 600, revision: 1);
        expect(keyA2, isNot(keyA));
        expect(keyA2, isNot(keyB));

        // Row-level distinctness survives: no identity merge occurred.
        final rows = await database
            .customSelect(
              'SELECT id FROM albums WHERE name = '
              "'NieR:Automata Original Soundtrack';",
            )
            .get();
        expect(rows, hasLength(2));
      },
      skip: !sqliteAvailable,
    );
  });

  group('integration policy at the file service', () {
    final recoveredIds = <String>[];
    late HttpServer server;
    var requests = 0;

    setUp(() async {
      recoveredIds.clear();
      requests = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        requests++;
        request.response.statusCode = HttpStatus.notFound;
        unawaited(request.response.close());
      });
      addTearDown(() => server.close(force: true));
    });

    CoverArtHttpFileService build({
      bool Function(Uri uri)? allowUri,
      bool Function(Uri uri)? isServerUri,
    }) {
      final service = CoverArtHttpFileService(
        connectionTimeout: const Duration(milliseconds: 500),
        responseTimeout: const Duration(milliseconds: 500),
        bodyReadTimeout: const Duration(milliseconds: 500),
        onMissingCover: recoveredIds.add,
        allowUri: allowUri,
        isServerUri: isServerUri,
      );
      addTearDown(service.close);
      return service;
    }

    test('policy is rechecked after waiting for a slot', () async {
      var allowed = true;
      final coordinator = CoverArtLoadCoordinator(
        maxActiveDownloads: 1,
        criticalReserve: 0,
      );
      final blocker = await coordinator.acquire('blocker');
      final service = CoverArtHttpFileService(
        loadCoordinator: coordinator,
        allowUri: (_) => allowed,
      );
      addTearDown(service.close);
      final pending = service.get(_coverArtUrl(server, id: 'queued'));
      final rejected = expectLater(
        pending,
        throwsA(isA<CoverArtBlockedException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.queuedCount, 1);
      allowed = false;
      blocker.release();
      await rejected;
      expect(requests, 0);
      expect(coordinator.activeCount, 0);
    });

    test(
      'the requesting feature is rechecked after waiting for a slot',
      () async {
        var featureAllowed = true;
        final checked = <String>[];
        final coordinator = CoverArtLoadCoordinator(
          maxActiveDownloads: 1,
          criticalReserve: 0,
        );
        final blocker = await coordinator.acquire('blocker');
        final service = CoverArtHttpFileService(
          loadCoordinator: coordinator,
          allowUri: (_) => true,
          allowFeatureUri: (uri, feature) {
            checked.add(feature);
            return featureAllowed;
          },
        );
        addTearDown(service.close);
        final pending = service.get(
          _coverArtUrl(server, id: 'queued'),
          headers: coverArtFeatureHeaders('radio.nowPlaying'),
        );
        final rejected = expectLater(
          pending,
          throwsA(isA<CoverArtBlockedException>()),
        );
        await Future<void>.delayed(Duration.zero);
        expect(coordinator.queuedCount, 1);
        featureAllowed = false;
        blocker.release();
        await rejected;
        expect(requests, 0);
        expect(coordinator.activeCount, 0);
        expect(checked, everyElement('radio.nowPlaying'));
        expect(checked.length, greaterThanOrEqualTo(2));
      },
    );

    group('feature-tagged and untagged loads of one URL', () {
      late CacheManager manager;
      late CoverArtLoadCoordinator coordinator;
      late CoverArtLoadLease blocker;
      var featureAllowed = true;
      late String url;
      late String taggedKey;

      setUp(() async {
        featureAllowed = true;
        coordinator = CoverArtLoadCoordinator(
          maxActiveDownloads: 1,
          criticalReserve: 0,
        );
        blocker = await coordinator.acquire('blocker');
        final directory = await Directory.systemTemp.createTemp('navis-tag-');
        final service = CoverArtHttpFileService(
          loadCoordinator: coordinator,
          allowUri: (_) => true,
          allowFeatureUri: (_, _) => featureAllowed,
        );
        manager = CacheManager(
          Config(
            'tag-test',
            repo: JsonCacheInfoRepository(
              path: directory.uri.resolve('m.json').toFilePath(),
            ),
            fileSystem: _TestCacheFileSystem(directory),
            fileService: service,
          ),
        );
        addTearDown(() async {
          service.close(force: true);
          await manager.dispose();
          await directory.delete(recursive: true);
        });
        url = _coverArtUrl(server, id: 'shared');
        taggedKey = coverArtFeatureCacheKey('radio.nowPlaying', url);
      });

      Future<File> tagged() => manager.getSingleFile(
        url,
        key: taggedKey,
        headers: coverArtFeatureHeaders('radio.nowPlaying'),
      );

      Future<File> untagged() => manager.getSingleFile(url);

      test('a radio load does not join a queued untagged download', () async {
        final first = expectLater(
          untagged(),
          throwsA(isA<CoverArtFetchException>()),
        );
        final second = expectLater(
          tagged(),
          throwsA(isA<CoverArtBlockedException>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        featureAllowed = false;
        blocker.release();
        await Future.wait<void>([first, second]);
        // Only the untagged load reached the server.
        expect(requests, 1);
      });

      test('an untagged load does not inherit a radio refusal', () async {
        final first = expectLater(
          tagged(),
          throwsA(isA<CoverArtBlockedException>()),
        );
        final second = expectLater(
          untagged(),
          throwsA(isA<CoverArtFetchException>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        featureAllowed = false;
        blocker.release();
        await Future.wait<void>([first, second]);
        expect(requests, 1);
      });
    });

    test('a request without a feature skips the feature check', () async {
      final service = CoverArtHttpFileService(
        allowUri: (_) => true,
        allowFeatureUri: (_, _) => false,
      );
      addTearDown(service.close);
      await expectLater(
        service.get(_coverArtUrl(server, id: 'cover-1')),
        throwsA(isA<CoverArtFetchException>()),
      );
      expect(requests, 1);
    });

    test('the feature header is consumed and never sent', () async {
      final seen = <String?>[];
      final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => probe.close(force: true));
      probe.listen((request) {
        seen.add(request.headers.value(coverArtFeatureHeader));
        request.response.statusCode = HttpStatus.notFound;
        unawaited(request.response.close());
      });
      final service = CoverArtHttpFileService(
        allowUri: (_) => true,
        allowFeatureUri: (_, _) => true,
      );
      addTearDown(service.close);
      await expectLater(
        service.get(
          _coverArtUrl(probe, id: 'cover-1'),
          headers: coverArtFeatureHeaders('radio.nowPlaying'),
        ),
        throwsA(isA<CoverArtFetchException>()),
      );
      expect(seen, [null]);
    });

    test('each redirect is checked and rejection releases its slot', () async {
      final redirects = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => redirects.close(force: true));
      var hops = 0;
      redirects.listen((request) {
        hops++;
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          hops == 1 ? '/second' : 'http://localhost:${server.port}/refused',
        );
        unawaited(request.response.close());
      });
      final coordinator = CoverArtLoadCoordinator();
      final service = CoverArtHttpFileService(
        loadCoordinator: coordinator,
        allowUri: (uri) => uri.host == '127.0.0.1',
      );
      addTearDown(service.close);
      await expectLater(
        service.get('http://127.0.0.1:${redirects.port}/first'),
        throwsA(isA<CoverArtBlockedException>()),
      );
      expect(hops, 2);
      expect(requests, 0);
      expect(coordinator.activeCount, 0);
    });

    test('a refused URL throws before any request is made', () async {
      final service = build(allowUri: (_) => false);
      await expectLater(
        service.get(_coverArtUrl(server, id: 'cover-1')),
        throwsA(isA<CoverArtBlockedException>()),
      );
      expect(requests, 0);
      expect(recoveredIds, isEmpty);
    });

    test('an allowed URL is requested', () async {
      final service = build(allowUri: (_) => true, isServerUri: (_) => true);
      await expectLater(
        service.get(_coverArtUrl(server, id: 'cover-1')),
        throwsA(isA<CoverArtFetchException>()),
      );
      expect(requests, 1);
    });

    test('a missing cover on the server host triggers recovery', () async {
      final service = build(isServerUri: (_) => true);
      await expectLater(
        service.get(_coverArtUrl(server, id: 'cover-1')),
        throwsA(isA<CoverArtFetchException>()),
      );
      expect(recoveredIds, ['cover-1']);
    });

    test('a 404 from an external host never triggers recovery', () async {
      // The id in an external URL means nothing to the user's server.
      final service = build(isServerUri: (_) => false);
      await expectLater(
        service.get(_coverArtUrl(server, id: 'cover-1')),
        throwsA(isA<CoverArtFetchException>()),
      );
      expect(requests, 1);
      expect(recoveredIds, isEmpty);
    });
  });
}

const _tinyJpeg = <int>[0xff, 0xd8, 0xff, 0xd9];

String _coverArtUrl(HttpServer server, {required String id}) {
  return Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: server.port,
    path: '/rest/getCoverArt.view',
    queryParameters: <String, String>{'id': id, 'size': '600', 't': 'redacted'},
  ).toString();
}
