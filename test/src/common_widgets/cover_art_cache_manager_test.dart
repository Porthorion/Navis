import 'dart:async';
import 'dart:io';

import 'package:mocktail/mocktail.dart';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/common_widgets/cover_art_recovery.dart';
import 'package:navis/src/database/navis_database.dart';

import '../../helpers/test_database.dart';

class _MockCacheManager extends Mock implements CacheManager {}

void main() {
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

      await expectLater(
        queued,
        throwsA(isA<CoverArtLoadCanceledException>()),
      );
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

      await expectLater(
        service.get(url),
        throwsA(isA<TimeoutException>()),
      );

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
      final service = CoverArtHttpFileService(
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
        expect(
          coverArtImageCacheKey('al-1', 600, revision: 2),
          'al-1:r2:600',
        );
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

    test(
      'failure taxonomy classifies the five plan categories',
      () {
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
          classifyCoverArtFailure(
            TimeoutException('timed out'),
          ),
          CoverArtFailureCategory.networkTimeout,
        );
        expect(
          classifyCoverArtFailure(
            const CoverArtInvalidResponseException('text/html'),
          ),
          CoverArtFailureCategory.invalidPayload,
        );
        expect(
          classifyCoverArtFailure(
            const FormatException('cannot decode'),
          ),
          CoverArtFailureCategory.transport,
        );
        expect(
          classifyCoverArtFailure(
            const CoverArtFetchException(
              CoverArtFailureCategory.decodeFailure,
            ),
          ),
          CoverArtFailureCategory.decodeFailure,
        );
      },
    );
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
              "SELECT id FROM albums WHERE name = "
              "'NieR:Automata Original Soundtrack';",
            )
            .get();
        expect(rows, hasLength(2));
      },
      skip: !sqliteAvailable,
    );
  });
}

const _tinyJpeg = <int>[0xff, 0xd8, 0xff, 0xd9];

String _coverArtUrl(HttpServer server, {required String id}) {
  return Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: server.port,
    path: '/rest/getCoverArt.view',
    queryParameters: <String, String>{
      'id': id,
      'size': '600',
      't': 'redacted',
    },
  ).toString();
}
