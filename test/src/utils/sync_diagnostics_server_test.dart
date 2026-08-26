import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/song_playback_indicator.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/cache/data/library_cache_reset_service.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/cache/presentation/library_cache_reset_provider.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:dio/dio.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/diagnostics_presentation_controller.dart';
import 'package:navis/src/utils/sync_diagnostics_overrides.dart';
import 'package:navis/src/utils/sync_diagnostics_server.dart';
import 'package:path/path.dart' as p;

import '../../helpers/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('diagnostics API requires its random bearer token', () async {
    final fixture = await _startFixture(SyncDiagnosticsMode.clone);
    addTearDown(fixture.close);

    final unauthorized = await _request(
      fixture.port,
      '/v1/health',
    );
    expect(unauthorized.statusCode, HttpStatus.unauthorized);

    final authorized = await _request(
      fixture.port,
      '/v1/health',
      token: fixture.token,
    );
    expect(authorized.statusCode, HttpStatus.ok);
    expect(authorized.body['mode'], 'clone');
    expect(authorized.body['schemaVersion'], 71);
  });

  test('cache upgrade clears then completes a full library scan', () async {
    final engine = _SuccessfulFullSyncEngine();
    final fixture = await _startFixture(
      SyncDiagnosticsMode.clone,
      librarySyncEngine: engine,
    );
    addTearDown(fixture.close);
    await fixture.database.customStatement('DELETE FROM cache_system_state;');

    final response = await _request(
      fixture.port,
      '/v1/library/cache-upgrade',
      method: 'POST',
      token: fixture.token,
    );

    expect(response.statusCode, HttpStatus.ok);
    expect(response.body['status'], 'succeeded');
    expect(response.body['needsReset'], isFalse);
    expect(
      (response.body['sync'] as Map<String, dynamic>)['status'],
      'succeeded',
    );
    expect(engine.forceFullCalls, 1);
  });

  test(
    'diagnostics server publishes and clears an Android handshake',
    () async {
      final database = createTestDatabase();
      final container = ProviderContainer(
        overrides: [
          navisDatabaseProvider.overrideWith((ref) => database),
        ],
      );
      final published = <Map<String, Object?>>[];
      var clearCount = 0;
      final server = SyncDiagnosticsServer(
        container: container,
        mode: SyncDiagnosticsMode.primaryCertification,
        handshakePath: '/unused/android-handshake.json',
        androidHandshakePublisher: (handshake) async {
          published.add(handshake);
        },
        androidHandshakeClearer: () async {
          clearCount++;
        },
        onShutdown: () async {},
      );
      addTearDown(() async {
        await server.close();
        container.dispose();
        await database.close();
      });

      await server.start();

      expect(published, hasLength(1));
      expect(published.single['port'], isA<int>());
      expect(published.single['pid'], isA<int>());
      expect(published.single['mode'], 'primaryCertification');
      expect(
        published.single['token'],
        matches(RegExp(r'^[A-Za-z0-9_-]{43}$')),
      );

      await server.close();
      expect(clearCount, 1);
    },
  );

  test('primary certification rejects mutation and cancellation', () async {
    final fixture = await _startFixture(
      SyncDiagnosticsMode.primaryCertification,
    );
    addTearDown(fixture.close);

    final cancel = await _request(
      fixture.port,
      '/v1/sync/cancel',
      method: 'POST',
      token: fixture.token,
    );
    expect(cancel.statusCode, HttpStatus.forbidden);

    final maintenance = await _request(
      fixture.port,
      '/v1/cache/maintenance',
      method: 'POST',
      token: fixture.token,
    );
    expect(maintenance.statusCode, HttpStatus.forbidden);

    final corruptCache = await _request(
      fixture.port,
      '/v1/diagnostics/cache/corrupt',
      method: 'POST',
      token: fixture.token,
      body: <String, Object?>{'songId': 'song-1'},
    );
    expect(corruptCache.statusCode, HttpStatus.forbidden);

    final mutation = await _request(
      fixture.port,
      '/v1/diagnostics/local-mutation',
      method: 'POST',
      token: fixture.token,
      body: <String, Object?>{
        'type': 'song',
        'id': 'song-1',
        'field': 'starred',
        'value': true,
      },
    );
    expect(mutation.statusCode, HttpStatus.forbidden);

    final restore = await _request(
      fixture.port,
      '/v1/diagnostics/restore-server-star',
      method: 'POST',
      token: fixture.token,
      body: <String, Object?>{'songId': 'song-1', 'liked': false},
    );
    expect(restore.statusCode, HttpStatus.forbidden);

    final signOut = await _request(
      fixture.port,
      '/v1/session/sign-out',
      method: 'POST',
      token: fixture.token,
    );
    expect(signOut.statusCode, HttpStatus.forbidden);

    final reset = await _request(
      fixture.port,
      '/v1/session/reset-initial-state',
      method: 'POST',
      token: fixture.token,
    );
    expect(reset.statusCode, HttpStatus.forbidden);
  });

  test('target sync diagnostics exercises controller-scoped status', () async {
    final engine = _TargetProgressSyncEngine();
    final fixture = await _startFixture(
      SyncDiagnosticsMode.clone,
      librarySyncEngine: engine,
    );
    addTearDown(fixture.close);

    final start = await _request(
      fixture.port,
      '/v1/sync/target',
      method: 'POST',
      token: fixture.token,
      body: const <String, Object?>{
        'targetKind': 'album',
        'entityId': 'album-1',
      },
    );
    expect(start.statusCode, HttpStatus.accepted);
    await Future<void>.delayed(Duration.zero);
    expect(engine.requestCount, 1);

    final status = await _request(
      fixture.port,
      '/v1/sync/status',
      token: fixture.token,
    );
    expect(status.statusCode, HttpStatus.ok);
    expect(status.body['status'], 'idle');
    expect(status.body['stage'], 'idle');
    expect(status.body, containsPair('nextAutomaticCheckAt', isNull));
    expect(status.body, containsPair('nextRetryAt', isNull));
    expect(status.body, containsPair('deletionCandidateCount', 0));
    expect(status.body, containsPair('durableOperations', isEmpty));
    expect(
      status.body['catalog'],
      <String, int>{'artists': 0, 'albums': 0, 'songs': 0},
    );

    engine.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    final ledger = await _request(
      fixture.port,
      '/v1/sync/ledger',
      token: fixture.token,
    );
    expect(ledger.statusCode, HttpStatus.ok);
    final events = ledger.body['events'] as List<Object?>;
    expect(events, hasLength(3));
    expect(
      events.map((event) => (event! as Map<String, Object?>)['phase']),
      <String>['requested', 'started', 'terminal'],
    );
    final terminal = events.last! as Map<String, Object?>;
    expect(terminal['cause'], 'targetHydration');
    expect(terminal['targetKind'], 'album');
    expect(terminal['result'], 'succeeded');
    expect(terminal.containsKey('endpointRequests'), isTrue);
    expect(ledger.body['durableRuns'], isEmpty);
    expect(ledger.body['durableOperations'], isEmpty);
  });

  test(
    'clone diagnostics can queue but not dispatch an album target fixture',
    () async {
      final fixture = await _startFixture(SyncDiagnosticsMode.clone);
      addTearDown(fixture.close);
      await fixture.container
          .read(serverConfigRepositoryProvider)
          .save(
            const ServerConfigModel(
              url: 'https://music.example.test',
              username: 'listener',
              password: 'secret',
              apiVersion: '1.16.1',
            ),
          );

      final response = await _request(
        fixture.port,
        '/v1/sync/fixture/queue-target',
        method: 'POST',
        token: fixture.token,
        body: const <String, Object?>{
          'targetKind': 'album',
          'entityId': 'album-queued',
        },
      );

      expect(response.statusCode, HttpStatus.accepted);
      expect(response.body['status'], 'queued');
      expect(response.body['targetKind'], 'album');
      expect(response.body['pendingWork'], 1);
      final work = await fixture.database.librarySyncDao.getWork(
        serverId: 1,
        kind: LibrarySyncPlanKind.targetedHydration.name,
        entityId: 'album:album-queued',
      );
      expect(work?.status, 'queued');
    },
  );

  test('primary diagnostics cannot queue a target fixture', () async {
    final fixture = await _startFixture(
      SyncDiagnosticsMode.primaryCertification,
    );
    addTearDown(fixture.close);

    final response = await _request(
      fixture.port,
      '/v1/sync/fixture/queue-target',
      method: 'POST',
      token: fixture.token,
      body: const <String, Object?>{
        'targetKind': 'album',
        'entityId': 'album-queued',
      },
    );

    expect(response.statusCode, HttpStatus.forbidden);
  });

  test(
    'library album observation is authenticated and omits metadata',
    () async {
      final fixture = await _startFixture(SyncDiagnosticsMode.clone);
      addTearDown(fixture.close);
      await fixture.database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist'),
      ]);
      await fixture.database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(
          id: 'album-1',
          name: 'Album title must not be exposed',
          artistId: const Value('artist-1'),
          songsHydrated: const Value(true),
          songCount: const Value(1),
        ),
      ]);

      final missing = await _request(
        fixture.port,
        '/v1/library/album?id=album-1',
      );
      expect(missing.statusCode, HttpStatus.unauthorized);

      final invalid = await _request(
        fixture.port,
        '/v1/library/album',
        token: fixture.token,
      );
      expect(invalid.statusCode, HttpStatus.badRequest);

      final present = await _request(
        fixture.port,
        '/v1/library/album?id=album-1',
        token: fixture.token,
      );
      expect(present.statusCode, HttpStatus.ok);
      expect(
        present.body,
        <String, Object?>{
          'id': 'album-1',
          'exists': true,
          'songsHydrated': true,
          'songCount': 1,
        },
      );
      expect(jsonEncode(present.body), isNot(contains('Album title')));

      final absent = await _request(
        fixture.port,
        '/v1/library/album?id=absent',
        token: fixture.token,
      );
      expect(
        absent.body,
        <String, Object?>{'id': 'absent', 'exists': false},
      );
    },
  );

  test(
    'recent-albums observation returns only ordered identity evidence',
    () async {
      final fixture = await _startFixture(SyncDiagnosticsMode.clone);
      addTearDown(fixture.close);
      await fixture.database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(
          id: 'album-earlier',
          name: 'Private title',
          serverCreatedAt: Value(DateTime.utc(2026, 8, 10)),
        ),
        AlbumsTableCompanion.insert(
          id: 'album-later',
          name: 'Another private title',
          serverCreatedAt: Value(DateTime.utc(2026, 8, 11)),
        ),
      ]);

      final response = await _request(
        fixture.port,
        '/v1/library/recent-albums?limit=2',
        token: fixture.token,
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.body['sort'], 'recentlyAdded');
      expect(
        (response.body['albums'] as List<Object?>)
            .cast<Map<String, Object?>>()
            .map((album) => album['id']),
        <String>['album-later', 'album-earlier'],
      );
      expect(jsonEncode(response.body), isNot(contains('Private title')));
    },
  );

  test('session status exposes only lifecycle activity fields', () async {
    final fixture = await _startFixture(SyncDiagnosticsMode.clone);
    addTearDown(fixture.close);

    final response = await _request(
      fixture.port,
      '/v1/session/status',
      token: fixture.token,
    );

    expect(response.statusCode, HttpStatus.ok);
    expect(response.body.keys, <String>[
      'phase',
      'transition',
      'initialSync',
      'sync',
      'queues',
      'activity',
    ]);
    expect(response.body['queues'], isA<Map<String, dynamic>>());
    expect(response.body['activity'], isA<Map<String, dynamic>>());
    final encoded = jsonEncode(response.body).toLowerCase();
    expect(encoded, isNot(contains('username')));
    expect(encoded, isNot(contains('password')));
    expect(encoded, isNot(contains('token')));
    expect(encoded, isNot(contains('url')));
  });

  test('cache status is authenticated and exposes no file paths', () async {
    final fixture = await _startFixture(SyncDiagnosticsMode.clone);
    addTearDown(fixture.close);

    final response = await _request(
      fixture.port,
      '/v1/cache/status',
      token: fixture.token,
    );

    expect(response.statusCode, HttpStatus.ok);
    expect(response.body.keys, <String>[
      'entries',
      'rollingEntries',
      'permanentEntries',
      'missingFiles',
      'renewalRequired',
    ]);
    expect(response.body['renewalRequired'], isFalse);
  });

  test('clone local mutation remains pending for sync precedence', () async {
    final fixture = await _startFixture(SyncDiagnosticsMode.clone);
    addTearDown(fixture.close);

    final mutation = await _request(
      fixture.port,
      '/v1/diagnostics/local-mutation',
      method: 'POST',
      token: fixture.token,
      body: <String, Object?>{
        'type': 'song',
        'id': 'song-1',
        'field': 'starred',
        'value': true,
      },
    );

    expect(mutation.statusCode, HttpStatus.ok);
    final pending = await fixture.database.starSyncDao.getPendingActions();
    expect(pending, hasLength(1));
    expect(pending.single.itemId, 'song-1');
    expect(pending.single.action, 'star');
  });

  test('clone mode accepts diagnostics override mutations', () async {
    final fixture = await _startFixture(SyncDiagnosticsMode.clone);
    addTearDown(fixture.close);

    final response = await _request(
      fixture.port,
      '/v1/diagnostics/overrides',
      method: 'POST',
      token: fixture.token,
      body: <String, Object?>{
        'networkType': 'cellular',
        'nativeMetered': true,
        'requestReporting': true,
        'cachedListenBrainzPresentation': true,
        'forceSearchRemoteFailure': true,
        'artistTopTracksPresentationFixture': true,
      },
    );

    expect(response.statusCode, HttpStatus.ok);
    expect(response.body['networkType'], 'cellular');
    expect(response.body['requestReporting'], isTrue);
    expect(response.body['cachedListenBrainzPresentation'], isTrue);
    expect(response.body['forceSearchRemoteFailure'], isTrue);
    expect(response.body['artistTopTracksPresentationFixture'], isTrue);

    final cleared = await _request(
      fixture.port,
      '/v1/diagnostics/overrides',
      method: 'POST',
      token: fixture.token,
      body: const <String, Object?>{},
    );
    expect(cleared.statusCode, HttpStatus.ok);
    expect(cleared.body['networkType'], isNull);
    expect(cleared.body['nativeMetered'], isNull);
    expect(cleared.body['forceSearchRemoteFailure'], isFalse);
    expect(cleared.body['artistTopTracksPresentationFixture'], isFalse);
  });

  test(
    'primary certification rejects diagnostics override mutations',
    () async {
      final fixture = await _startFixture(
        SyncDiagnosticsMode.primaryCertification,
      );
      addTearDown(fixture.close);

      final response = await _request(
        fixture.port,
        '/v1/diagnostics/overrides',
        method: 'POST',
        token: fixture.token,
        body: <String, Object?>{'networkType': 'cellular'},
      );

      expect(response.statusCode, HttpStatus.forbidden);
    },
  );

  test('handshake is removed when the diagnostics server closes', () async {
    final fixture = await _startFixture(SyncDiagnosticsMode.clone);
    expect(await fixture.handshake.exists(), isTrue);

    await fixture.close();

    expect(await fixture.handshake.exists(), isFalse);
  });

  test(
    'playback bootstrap status is authenticated and exposes safe state',
    () async {
      final fixture = await _startFixture(SyncDiagnosticsMode.clone);
      addTearDown(fixture.close);

      final unauthorized = await _request(
        fixture.port,
        '/v1/playback/bootstrap/status',
      );
      expect(unauthorized.statusCode, HttpStatus.unauthorized);

      final status = await _request(
        fixture.port,
        '/v1/playback/bootstrap/status',
        token: fixture.token,
      );
      expect(status.statusCode, HttpStatus.ok);
      expect(status.body['status'], 'initializing');
      expect(status.body['attempt'], 0);
      expect(status.body['timedOut'], isFalse);
      expect(status.body['retryScheduled'], isFalse);
      expect(status.body['handlerReady'], isFalse);
    },
  );

  test(
    'playback recovery diagnostics action has a bounded clone-only contract',
    () async {
      final fixture = await _startFixture(SyncDiagnosticsMode.clone);

      final invalid = await _request(
        fixture.port,
        '/v1/presentation/playback-recovery',
        method: 'POST',
        token: fixture.token,
        body: <String, Object?>{'action': 'invalid'},
      );
      expect(invalid.statusCode, HttpStatus.badRequest);
      await fixture.close();

      final primary = await _startFixture(
        SyncDiagnosticsMode.primaryCertification,
      );
      addTearDown(primary.close);
      final forbidden = await _request(
        primary.port,
        '/v1/presentation/playback-recovery',
        method: 'POST',
        token: primary.token,
        body: <String, Object?>{'action': 'retry'},
      );
      expect(forbidden.statusCode, HttpStatus.forbidden);
    },
  );

  test(
    'presentation endpoints use the authenticated clone control plane',
    () async {
      final presentation = _MockPresentationController();
      final navigationDriver = _MockDiagnosticsNavigationDriver();
      var location = '/';
      when(() => navigationDriver.location).thenAnswer((_) => location);
      when(() => navigationDriver.go(any())).thenAnswer((invocation) {
        final requested = invocation.positionalArguments.single as String;
        location = requested == '/redirect' ? '/target' : requested;
      });
      when(() => presentation.status).thenReturn(
        const DiagnosticsPresentationStatus(
          logicalWidth: 1280,
          logicalHeight: 720,
          devicePixelRatio: 1.5,
          screenshotReady: true,
        ),
      );
      when(() => presentation.appReady).thenReturn(true);
      when(presentation.waitForFrame).thenAnswer((_) async {});
      when(
        () => presentation.capture(label: any(named: 'label')),
      ).thenAnswer(
        (_) async => const DiagnosticsScreenshot(
          artifact: 'screenshots/capture.png',
          logicalWidth: 1280,
          logicalHeight: 720,
          pixelWidth: 1280,
          pixelHeight: 720,
          pixelRatio: 1,
          byteCount: 42,
          sha256Digest: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        ),
      );
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        presentationController: presentation,
        navigationDriver: navigationDriver,
      );
      addTearDown(fixture.close);

      for (final unauthorized in <(String, String)>[
        ('GET', '/v1/presentation/window'),
        ('POST', '/v1/presentation/window'),
        ('GET', '/v1/presentation/status'),
        ('POST', '/v1/presentation/navigate'),
        ('POST', '/v1/presentation/library-filter'),
        ('POST', '/v1/presentation/notice'),
        ('POST', '/v1/presentation/search'),
        ('POST', '/v1/presentation/search/play'),
      ]) {
        final response = await _request(
          fixture.port,
          unauthorized.$2,
          method: unauthorized.$1,
        );
        expect(response.statusCode, HttpStatus.unauthorized);
      }

      final status = await _request(
        fixture.port,
        '/v1/presentation/status',
        token: fixture.token,
      );
      expect(status.statusCode, HttpStatus.ok);
      expect(status.body['route'], '/');
      expect(status.body['appReady'], isTrue);
      expect(status.body['screenshotReady'], isTrue);

      final invalidNavigation = await _request(
        fixture.port,
        '/v1/presentation/navigate',
        method: 'POST',
        token: fixture.token,
        body: const <String, Object?>{'location': 'https://example.com'},
      );
      expect(invalidNavigation.statusCode, HttpStatus.badRequest);

      final nonStringNavigation = await _request(
        fixture.port,
        '/v1/presentation/navigate',
        method: 'POST',
        token: fixture.token,
        body: const <String, Object?>{'location': 42},
      );
      expect(nonStringNavigation.statusCode, HttpStatus.badRequest);

      final navigation = await _request(
        fixture.port,
        '/v1/presentation/navigate',
        method: 'POST',
        token: fixture.token,
        body: const <String, Object?>{'location': '/target'},
      );
      expect(navigation.statusCode, HttpStatus.ok);
      expect(navigation.body['requestedLocation'], '/target');
      expect(navigation.body['actualLocation'], '/target');
      verify(presentation.waitForFrame).called(1);

      final redirected = await _request(
        fixture.port,
        '/v1/presentation/navigate',
        method: 'POST',
        token: fixture.token,
        body: const <String, Object?>{'location': '/redirect'},
      );
      expect(redirected.statusCode, HttpStatus.ok);
      expect(redirected.body['actualLocation'], '/target');
      expect(redirected.body['redirected'], isTrue);

      final likedNavigation = await _request(
        fixture.port,
        '/v1/presentation/navigate',
        method: 'POST',
        token: fixture.token,
        body: const <String, Object?>{'location': '/library#liked'},
      );
      expect(likedNavigation.statusCode, HttpStatus.ok);
      expect(likedNavigation.body['actualLocation'], '/library#liked');
      expect(
        fixture.container.read(librarySectionProvider),
        LibrarySection.liked,
      );

      final invalidLibraryFilter = await _request(
        fixture.port,
        '/v1/presentation/library-filter',
        method: 'POST',
        token: fixture.token,
        body: const <String, Object?>{'query': ''},
      );
      expect(invalidLibraryFilter.statusCode, HttpStatus.badRequest);

      final libraryFilter = await _request(
        fixture.port,
        '/v1/presentation/library-filter',
        method: 'POST',
        token: fixture.token,
        body: const <String, Object?>{'query': 'no-match'},
      );
      expect(libraryFilter.statusCode, HttpStatus.ok);
      expect(libraryFilter.body['query'], 'no-match');
      expect(libraryFilter.body['section'], 'liked');
      expect(
        fixture.container.read(libraryTypeFilterDiagnosticsProvider),
        'no-match',
      );

      final invalidNotice = await _request(
        fixture.port,
        '/v1/presentation/notice',
        method: 'POST',
        token: fixture.token,
        body: const <String, Object?>{
          'message': 'Could not save album.',
          'level': 'unknown',
        },
      );
      expect(invalidNotice.statusCode, HttpStatus.badRequest);

      final notice = await _request(
        fixture.port,
        '/v1/presentation/notice',
        method: 'POST',
        token: fixture.token,
        body: const <String, Object?>{
          'message': 'Could not save album.',
          'level': 'error',
        },
      );
      expect(notice.statusCode, HttpStatus.ok);
      expect(notice.body['level'], 'error');
      expect(notice.body['messageLength'], 21);
      expect(
        fixture.container.read(appNoticeDiagnosticsProvider)?.level,
        AppNoticeLevel.error,
      );

      final overlay = await _request(
        fixture.port,
        '/v1/presentation/player-overlay',
        method: 'POST',
        token: fixture.token,
        body: const <String, Object?>{'surface': 'queue', 'visible': true},
      );
      expect(overlay.statusCode, HttpStatus.ok);
      expect(overlay.body['visible'], isTrue);

      final nowPlaying = await _request(
        fixture.port,
        '/v1/presentation/player-overlay',
        method: 'POST',
        token: fixture.token,
        body: const <String, Object?>{
          'surface': 'nowPlaying',
          'visible': true,
        },
      );
      expect(nowPlaying.statusCode, HttpStatus.ok);
      expect(nowPlaying.body['visible'], isTrue);
      expect(nowPlaying.body['desktopNowPlayingVisible'], isTrue);
      expect(
        fixture.container.read(desktopNowPlayingDiagnosticsProvider),
        isTrue,
      );

      when(
        () => presentation.capture(label: 'Bad Label'),
      ).thenThrow(const FormatException('invalid label'));
      final invalidScreenshot = await _request(
        fixture.port,
        '/v1/presentation/screenshot',
        method: 'POST',
        token: fixture.token,
        body: const <String, Object?>{'label': 'Bad Label'},
      );
      expect(invalidScreenshot.statusCode, HttpStatus.badRequest);

      final nonStringScreenshot = await _request(
        fixture.port,
        '/v1/presentation/screenshot',
        method: 'POST',
        token: fixture.token,
        body: const <String, Object?>{'label': <String>[]},
      );
      expect(nonStringScreenshot.statusCode, HttpStatus.badRequest);

      final screenshot = await _request(
        fixture.port,
        '/v1/presentation/screenshot',
        method: 'POST',
        token: fixture.token,
        body: const <String, Object?>{'label': 'target'},
      );
      expect(screenshot.statusCode, HttpStatus.created);
      expect(screenshot.body['artifact'], 'screenshots/capture.png');
      expect(screenshot.body['sha256'], hasLength(64));
      verify(() => presentation.capture(label: 'target')).called(1);
    },
  );

  test(
    'presentation endpoints reject primary mode and missing surfaces',
    () async {
      final primary = await _startFixture(
        SyncDiagnosticsMode.primaryCertification,
      );
      addTearDown(primary.close);
      for (final endpoint in <(String, String)>[
        ('GET', '/v1/presentation/window'),
        ('POST', '/v1/presentation/window'),
        ('GET', '/v1/presentation/status'),
        ('POST', '/v1/presentation/navigate'),
        ('POST', '/v1/presentation/library-filter'),
        ('POST', '/v1/presentation/notice'),
        ('POST', '/v1/presentation/search'),
        ('POST', '/v1/presentation/search/play'),
        ('POST', '/v1/presentation/screenshot'),
      ]) {
        final forbidden = await _request(
          primary.port,
          endpoint.$2,
          method: endpoint.$1,
          token: primary.token,
        );
        expect(forbidden.statusCode, HttpStatus.forbidden);
      }
      final unavailablePrimaryCapture = await _request(
        primary.port,
        '/v1/presentation/screenshot',
        method: 'POST',
        token: primary.token,
        body: const <String, Object?>{'label': 'settings'},
      );
      expect(unavailablePrimaryCapture.statusCode, HttpStatus.forbidden);
      await primary.close();

      final clone = await _startFixture(SyncDiagnosticsMode.clone);
      addTearDown(clone.close);
      for (final endpoint in <(String, String)>[
        ('GET', '/v1/presentation/status'),
        ('POST', '/v1/presentation/navigate'),
        ('POST', '/v1/presentation/library-filter'),
        ('POST', '/v1/presentation/notice'),
        ('POST', '/v1/presentation/search'),
        ('POST', '/v1/presentation/search/play'),
        ('POST', '/v1/presentation/screenshot'),
      ]) {
        final unavailable = await _request(
          clone.port,
          endpoint.$2,
          method: endpoint.$1,
          token: clone.token,
        );
        expect(unavailable.statusCode, HttpStatus.serviceUnavailable);
      }
    },
  );

  test('primary mode permits only app-owned screenshot capture', () async {
    final presentation = _MockPresentationController();
    when(() => presentation.capture(label: 'settings')).thenAnswer(
      (_) async => const DiagnosticsScreenshot(
        artifact: 'screenshots/settings.png',
        logicalWidth: 400,
        logicalHeight: 800,
        pixelWidth: 400,
        pixelHeight: 800,
        pixelRatio: 1,
        byteCount: 42,
        sha256Digest:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
    );
    final primary = await _startFixture(
      SyncDiagnosticsMode.primaryCertification,
      presentationController: presentation,
    );
    addTearDown(primary.close);

    final screenshot = await _request(
      primary.port,
      '/v1/presentation/screenshot',
      method: 'POST',
      token: primary.token,
      body: const <String, Object?>{'label': 'settings'},
    );

    expect(screenshot.statusCode, HttpStatus.created);
    expect(screenshot.body['artifact'], 'screenshots/settings.png');
    verify(() => presentation.capture(label: 'settings')).called(1);
  });

  test(
    'window presentation endpoint reports and selects desktop modes',
    () async {
      final fixture = await _startFixture(SyncDiagnosticsMode.clone);
      addTearDown(fixture.close);

      final initial = await _request(
        fixture.port,
        '/v1/presentation/window',
        token: fixture.token,
      );
      expect(initial.statusCode, HttpStatus.ok);
      expect(initial.body['mode'], 'desktop');

      final mini = await _request(
        fixture.port,
        '/v1/presentation/window',
        method: 'POST',
        token: fixture.token,
        body: const <String, Object?>{'mode': 'miniPlayer'},
      );
      expect(mini.statusCode, HttpStatus.ok);
      expect(mini.body['mode'], 'miniPlayer');

      final pinned = await _request(
        fixture.port,
        '/v1/presentation/window',
        method: 'POST',
        token: fixture.token,
        body: const <String, Object?>{'miniAlwaysOnTop': true},
      );
      expect(pinned.statusCode, HttpStatus.ok);
      expect(pinned.body['miniAlwaysOnTopSupported'], isTrue);
      expect(pinned.body['miniAlwaysOnTop'], isTrue);

      final invalid = await _request(
        fixture.port,
        '/v1/presentation/window',
        method: 'POST',
        token: fixture.token,
        body: const <String, Object?>{'width': 559, 'height': 360},
      );
      expect(invalid.statusCode, HttpStatus.badRequest);
    },
  );

  test(
    'song indicator endpoint is authenticated, validated, and sanitized',
    () async {
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        playbackSnapshot: const PlaybackSnapshot(
          queueSongIds: <String>['song-1'],
          currentSongId: 'song-1',
          currentIndex: 0,
          playing: false,
          processingState: AudioProcessingState.ready,
          position: Duration.zero,
          duration: Duration(minutes: 3),
          bufferedPosition: Duration.zero,
          shuffleMode: AudioServiceShuffleMode.none,
          repeatMode: AudioServiceRepeatMode.none,
        ),
      );
      addTearDown(fixture.close);

      final unauthorized = await _request(
        fixture.port,
        '/v1/presentation/song-indicator?songId=song-1',
      );
      expect(unauthorized.statusCode, HttpStatus.unauthorized);

      final invalid = await _request(
        fixture.port,
        '/v1/presentation/song-indicator',
        token: fixture.token,
      );
      expect(invalid.statusCode, HttpStatus.badRequest);

      expect(
        fixture.container.read(
          songPlaybackIndicatorStateProvider('song-1'),
        ),
        SongPlaybackIndicatorState.current,
      );
      final current = await _request(
        fixture.port,
        '/v1/presentation/song-indicator?songId=song-1',
        token: fixture.token,
      );
      expect(current.statusCode, HttpStatus.ok);
      expect(current.body, <String, Object?>{
        'state': 'current',
        'selected': true,
        'markerRole': 'equalizer',
        'semanticRole': 'nowPlaying',
        'backgroundColorRole': 'primaryTint08',
        'foregroundColorRole': 'primary',
      });

      final inactive = await _request(
        fixture.port,
        '/v1/presentation/song-indicator?songId=song-2',
        token: fixture.token,
      );
      expect(inactive.body['state'], 'inactive');
      expect(inactive.body['selected'], isFalse);
      expect(inactive.body.containsKey('songId'), isFalse);
    },
  );

  test(
    'song indicator endpoint exposes the loading presentation state',
    () async {
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        playbackSnapshot: const PlaybackSnapshot(
          queueSongIds: <String>['song-1', 'song-2'],
          currentSongId: 'song-1',
          currentIndex: 1,
          playing: true,
          processingState: AudioProcessingState.loading,
          position: Duration.zero,
          duration: Duration(minutes: 3),
          bufferedPosition: Duration.zero,
          shuffleMode: AudioServiceShuffleMode.none,
          repeatMode: AudioServiceRepeatMode.none,
          isLoading: true,
          loadingSongId: 'song-2',
        ),
      );
      addTearDown(fixture.close);

      final response = await _request(
        fixture.port,
        '/v1/presentation/song-indicator?songId=song-2',
        token: fixture.token,
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(response.body['state'], 'loading');
      expect(response.body['markerRole'], 'progress');
      expect(response.body['semanticRole'], 'nowPlaying');
    },
  );

  test(
    'volume API uses production controller and persists mute state',
    () async {
      final handler = _MockPlaybackHandler();
      var handlerVolume = 1.0;
      when(() => handler.loadFailureStream).thenAnswer(
        (_) => const Stream<PlaybackLoadFailure>.empty(),
      );
      when(handler.waitUntilReady).thenAnswer((_) async {});
      when(() => handler.setVolume(any())).thenAnswer((invocation) async {
        handlerVolume = invocation.positionalArguments.single as double;
      });
      when(handler.collectPlaybackDiagnostics).thenAnswer(
        (_) => <String, Object?>{
          'userVolume': handlerVolume,
          'effectivePlayerVolume': handlerVolume,
        },
      );
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        handler: handler,
      );
      addTearDown(fixture.close);
      fixture.container
          .read(playbackVolumeProvider.notifier)
          .hydrate(
            volume: 1,
            lastAudibleVolume: 1,
          );

      final invalid = await _request(
        fixture.port,
        '/v1/playback/volume',
        method: 'POST',
        token: fixture.token,
        body: <String, Object?>{'value': 2},
      );
      expect(invalid.statusCode, HttpStatus.badRequest);

      final set = await _request(
        fixture.port,
        '/v1/playback/volume',
        method: 'POST',
        token: fixture.token,
        body: <String, Object?>{'value': 0.37},
      );
      expect(set.statusCode, HttpStatus.ok);
      expect(set.body['volume'], 0.37);
      expect(set.body['persistedVolume'], 0.37);
      expect(set.body['handlerUserVolume'], 0.37);

      final muted = await _request(
        fixture.port,
        '/v1/playback/volume/toggle-mute',
        method: 'POST',
        token: fixture.token,
      );
      expect(muted.statusCode, HttpStatus.ok);
      expect(muted.body['volume'], 0);
      expect(muted.body['lastAudibleVolume'], 0.37);
      expect(muted.body['persistedLastAudibleVolume'], 0.37);
      expect(muted.body['effectivePlayerVolume'], 0);

      final observed = await _request(
        fixture.port,
        '/v1/playback/volume',
        token: fixture.token,
      );
      expect(observed.statusCode, HttpStatus.ok);
      expect(observed.body['persistedVolume'], 0);
    },
  );

  test('primary certification observes volume but rejects mutation', () async {
    final handler = _MockPlaybackHandler();
    when(() => handler.loadFailureStream).thenAnswer(
      (_) => const Stream<PlaybackLoadFailure>.empty(),
    );
    when(handler.waitUntilReady).thenAnswer((_) async {});
    when(handler.collectPlaybackDiagnostics).thenReturn(<String, Object?>{
      'userVolume': 1.0,
      'effectivePlayerVolume': 1.0,
    });
    final fixture = await _startFixture(
      SyncDiagnosticsMode.primaryCertification,
      handler: handler,
    );
    addTearDown(fixture.close);
    fixture.container
        .read(playbackVolumeProvider.notifier)
        .hydrate(volume: 1, lastAudibleVolume: 1);

    final observed = await _request(
      fixture.port,
      '/v1/playback/volume',
      token: fixture.token,
    );
    expect(observed.statusCode, HttpStatus.ok);
    expect(observed.body['desktopPersistenceEnabled'], isTrue);

    final response = await _request(
      fixture.port,
      '/v1/playback/volume',
      method: 'POST',
      token: fixture.token,
      body: <String, Object?>{'value': 0.37},
    );
    expect(response.statusCode, HttpStatus.forbidden);
  });

  test(
    'source audit is authenticated, sanitized, and classifies mixed rows',
    () async {
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        api: _SourceAuditApiClient(),
      );
      addTearDown(fixture.close);
      await fixture.database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(id: 'server-artist', name: 'Local Artist'),
      ]);

      final unauthorized = await _request(
        fixture.port,
        '/v1/search/source-audit',
        method: 'POST',
        body: const <String, Object?>{'query': 'mixed'},
      );
      expect(unauthorized.statusCode, HttpStatus.unauthorized);

      final response = await _request(
        fixture.port,
        '/v1/search/source-audit',
        method: 'POST',
        token: fixture.token,
        body: const <String, Object?>{'query': 'mixed'},
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(response.body['songCount'], 20);
      expect(response.body['songOffset'], 0);
      expect(
        response.body['resultCounts'],
        <String, Object?>{'artists': 1, 'albums': 1, 'songs': 1},
      );
      final records = response.body['records'] as List<dynamic>;
      expect(records, hasLength(3));
      expect(
        records,
        contains(
          containsPair('source', 'remote'),
        ),
      );
      final local = records.cast<Map<String, dynamic>>().singleWhere(
        (record) => record['id'] == 'server-artist',
      );
      expect(local['locallyIndexed'], isTrue);
      expect(local['source'], 'onServer');
      for (final record in records.cast<Map<String, dynamic>>()) {
        expect(
          record.keys,
          unorderedEquals(<String>[
            'kind',
            'id',
            'displayLabel',
            'source',
            'apiIsExternal',
            'locallyIndexed',
            'isProvisional',
          ]),
        );
      }
    },
  );

  test(
    'presentation search drives production providers and returns ranked sources',
    () async {
      var location = '/';
      final navigationDriver = _MockDiagnosticsNavigationDriver();
      when(() => navigationDriver.location).thenAnswer((_) => location);
      when(() => navigationDriver.go(any())).thenAnswer((invocation) {
        location = invocation.positionalArguments.single as String;
      });
      final presentation = _MockPresentationController();
      when(presentation.waitForFrame).thenAnswer((_) async {});
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        api: _SourceAuditApiClient(),
        navigationDriver: navigationDriver,
        presentationController: presentation,
      );
      addTearDown(fixture.close);
      await fixture.database.libraryDao.upsertArtists(
        <ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(
            id: 'server-prefix',
            name: 'Aurora Local',
          ),
        ],
      );

      final response = await _request(
        fixture.port,
        '/v1/presentation/search',
        method: 'POST',
        token: fixture.token,
        body: const <String, Object?>{'query': 'Aurora'},
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.body['route'], '/search');
      final artists = (response.body['artists'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(
        artists.map((record) => record['id']),
        <String>['remote-exact', 'server-prefix', 'remote-prefix'],
      );
      expect(artists.first['relevance'], 'exact');
      expect(artists.first['source'], 'remote');
      expect(artists[1]['source'], 'onServer');
      expect(
        artists.expand((record) => record.keys),
        everyElement(
          isIn(<String>['id', 'source', 'relevance']),
        ),
      );
    },
  );

  test(
    'presentation search result playback uses the production queue path',
    () async {
      var location = '/';
      final navigationDriver = _MockDiagnosticsNavigationDriver();
      when(() => navigationDriver.location).thenAnswer((_) => location);
      when(() => navigationDriver.go(any())).thenAnswer((invocation) {
        location = invocation.positionalArguments.single as String;
      });
      final presentation = _MockPresentationController();
      when(presentation.waitForFrame).thenAnswer((_) async {});
      final handler = _MockPlaybackHandler();
      when(() => handler.loadFailureStream).thenAnswer(
        (_) => const Stream<PlaybackLoadFailure>.empty(),
      );
      when(() => handler.snapshot).thenReturn(const PlaybackSnapshot.idle());
      when(() => handler.snapshotStream).thenAnswer(
        (_) => const Stream<PlaybackSnapshot>.empty(),
      );
      when(
        () => handler.replaceQueueWithData(
          any(),
          startIndex: any(named: 'startIndex'),
          autoPlay: any(named: 'autoPlay'),
          expandMatchFlows: any(named: 'expandMatchFlows'),
        ),
      ).thenAnswer((_) async {});
      when(handler.play).thenAnswer((_) async {});
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        api: _SourceAuditApiClient(),
        handler: handler,
        navigationDriver: navigationDriver,
        presentationController: presentation,
      );
      addTearDown(fixture.close);

      final search = await _request(
        fixture.port,
        '/v1/presentation/search',
        method: 'POST',
        token: fixture.token,
        body: const <String, Object?>{
          'query': 'Remote Song',
          'filter': 'songs',
        },
      );
      expect(search.statusCode, HttpStatus.ok);

      final play = await _request(
        fixture.port,
        '/v1/presentation/search/play',
        method: 'POST',
        token: fixture.token,
        body: const <String, Object?>{'songId': 'provider-song-1'},
      );
      expect(play.statusCode, HttpStatus.accepted);
      expect(play.body['source'], 'remote');
      final persisted = await fixture.database.libraryDao.getSongById(
        'provider-song-1',
      );
      expect(persisted?.isExternal, isTrue);
      verify(
        () => handler.replaceQueueWithData(
          any(),
          startIndex: 0,
          autoPlay: true,
          expandMatchFlows: true,
        ),
      ).called(1);
    },
  );

  test('current diagnostics playback source is resumed, not replaced', () {
    const active = PlaybackSnapshot(
      queueSongIds: <String>['song-1'],
      currentSongId: 'song-1',
      currentIndex: 0,
      playing: false,
      processingState: AudioProcessingState.ready,
      position: Duration(seconds: 12),
      duration: Duration(minutes: 4),
      bufferedPosition: Duration(seconds: 30),
      shuffleMode: AudioServiceShuffleMode.none,
      repeatMode: AudioServiceRepeatMode.none,
    );

    expect(
      canResumeDiagnosticsPlayback(snapshot: active, songId: 'song-1'),
      isTrue,
    );
    expect(
      canResumeDiagnosticsPlayback(snapshot: active, songId: 'song-2'),
      isFalse,
    );
    expect(
      canResumeDiagnosticsPlayback(
        snapshot: const PlaybackSnapshot.idle(),
        songId: 'song-1',
      ),
      isFalse,
    );
  });
}

Future<_DiagnosticsFixture> _startFixture(
  SyncDiagnosticsMode mode, {
  SubsonicApiClient? api,
  LibrarySyncEngine? librarySyncEngine,
  NavisPlaybackHandler? handler,
  PlaybackSnapshot? playbackSnapshot,
  DiagnosticsPresentationController? presentationController,
  DiagnosticsNavigationDriver? navigationDriver,
}) async {
  final temp = await Directory.systemTemp.createTemp('navis_diagnostics_test_');
  final database = createTestDatabase();
  final container = ProviderContainer(
    overrides: [
      navisDatabaseProvider.overrideWith((ref) => database),
      libraryCacheResetServiceProvider.overrideWith(
        (ref) => LibraryCacheResetService(database: database),
      ),
      audioHandlerProvider.overrideWith((ref) => handler),
      if (playbackSnapshot != null)
        playerStateProvider.overrideWithValue(playbackSnapshot),
      if (api != null) subsonicApiProvider.overrideWithValue(api),
      if (api != null) searchIsOfflineProvider.overrideWithValue(false),
      if (librarySyncEngine != null)
        librarySyncEngineProvider.overrideWithValue(librarySyncEngine),
    ],
  );
  final handshake = File(p.join(temp.path, 'handshake.json'));
  final server = SyncDiagnosticsServer(
    container: container,
    mode: mode,
    handshakePath: handshake.path,
    presentationController: presentationController,
    navigationDriver: navigationDriver,
    onShutdown: () async {},
  );
  await server.start();
  final value =
      jsonDecode(await handshake.readAsString()) as Map<String, dynamic>;
  return _DiagnosticsFixture(
    server: server,
    container: container,
    database: database,
    temp: temp,
    handshake: handshake,
    port: value['port'] as int,
    token: value['token'] as String,
  );
}

class _MockPlaybackHandler extends Mock implements NavisPlaybackHandler {}

class _MockPresentationController extends Mock
    implements DiagnosticsPresentationController {}

class _MockDiagnosticsNavigationDriver extends Mock
    implements DiagnosticsNavigationDriver {}

class _TargetProgressSyncEngine extends LibrarySyncEngine {
  final Completer<LibrarySyncState> _completion = Completer<LibrarySyncState>();
  int requestCount = 0;

  @override
  Future<LibrarySyncState> requestSync(
    LibrarySyncRequest request, {
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) {
    requestCount++;
    onProgress?.call(
      const LibrarySyncState(
        status: LibrarySyncStatus.running,
        stage: LibrarySyncStage.fetchingSongs,
      ),
    );
    return _completion.future;
  }

  void complete() {
    _completion.complete(
      const LibrarySyncState(
        status: LibrarySyncStatus.succeeded,
        stage: LibrarySyncStage.completed,
      ),
    );
  }

  @override
  Future<LibrarySyncState> continueVerification({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) => _completion.future;

  @override
  Future<LibrarySyncState> forceFullSync({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) => _completion.future;

  @override
  Future<LibrarySyncState> probeCatalog({
    LibrarySyncProgressCallback? onProgress,
  }) => _completion.future;

  @override
  Future<LibrarySyncState> syncIfStale({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) => _completion.future;

  @override
  Future<LibrarySyncState> syncNow({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) => _completion.future;
}

class _SuccessfulFullSyncEngine extends LibrarySyncEngine {
  int forceFullCalls = 0;

  static const LibrarySyncState _succeeded = LibrarySyncState(
    status: LibrarySyncStatus.succeeded,
    stage: LibrarySyncStage.completed,
  );

  @override
  Future<LibrarySyncState> forceFullSync({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
    bool allowMeteredBroadOverride = false,
  }) async {
    forceFullCalls += 1;
    onProgress?.call(
      const LibrarySyncState(
        status: LibrarySyncStatus.running,
        stage: LibrarySyncStage.fetchingArtists,
      ),
    );
    return _succeeded;
  }

  @override
  Future<LibrarySyncState> continueVerification({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) async => _succeeded;

  @override
  Future<LibrarySyncState> probeCatalog({
    LibrarySyncProgressCallback? onProgress,
  }) async => _succeeded;

  @override
  Future<LibrarySyncState> syncIfStale({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) async => _succeeded;

  @override
  Future<LibrarySyncState> syncNow({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
    bool allowMeteredBroadOverride = false,
  }) async => _succeeded;
}

class _SourceAuditApiClient extends SubsonicApiClient {
  _SourceAuditApiClient()
    : super(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'test',
          password: 'test',
          apiVersion: '1.16.1',
        ),
      );

  @override
  Future<SearchResult3> search3({
    required String query,
    int artistCount = 20,
    int artistOffset = 0,
    int albumCount = 20,
    int albumOffset = 0,
    int songCount = 20,
    int songOffset = 0,
    CancelToken? cancelToken,
  }) async {
    if (query == 'Aurora') {
      return const SearchResult3(
        artists: <Artist>[
          Artist(id: 'remote-prefix', name: 'Aurora Remote', isExternal: true),
          Artist(id: 'remote-exact', name: 'Aurora', isExternal: true),
          Artist(id: 'server-prefix', name: 'Aurora Local', isExternal: false),
        ],
      );
    }
    return const SearchResult3(
      artists: <Artist>[
        Artist(
          id: 'server-artist',
          name: 'Local Artist',
          isExternal: false,
        ),
      ],
      albums: <Album>[
        Album(id: 'ext-deezer-album-1', name: 'Remote Album'),
      ],
      songs: <Song>[
        Song(
          id: 'provider-song-1',
          title: 'Remote Song',
          isExternal: true,
        ),
      ],
    );
  }
}

Future<_Response> _request(
  int port,
  String path, {
  String method = 'GET',
  String? token,
  Map<String, Object?>? body,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    return _Response(
      statusCode: response.statusCode,
      body: jsonDecode(text) as Map<String, dynamic>,
    );
  } finally {
    client.close(force: true);
  }
}

class _DiagnosticsFixture {
  _DiagnosticsFixture({
    required this.server,
    required this.container,
    required this.database,
    required this.temp,
    required this.handshake,
    required this.port,
    required this.token,
  });

  final SyncDiagnosticsServer server;
  final ProviderContainer container;
  final dynamic database;
  final Directory temp;
  final File handshake;
  final int port;
  final String token;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await server.close();
    container.dispose();
    await database.close();
    await temp.delete(recursive: true);
  }
}

class _Response {
  const _Response({required this.statusCode, required this.body});

  final int statusCode;
  final Map<String, dynamic> body;
}
