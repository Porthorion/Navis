import '../../../../helpers/library_sync_plan.dart';

import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';

import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/data/adaptive_library_sync_coordinator.dart';
import 'package:navis/src/features/library/domain/sync_run_contract.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/utils/connectivity.dart';

import '../../../../helpers/test_database.dart';
import '../../../../helpers/library_sync_fakes.dart';

class _AuditApi extends FakeLibrarySyncApi {
  Object? newestError;
  void Function()? onNewestPage;
  Completer<StarredContent>? starredGate;
  @override
  Future<StarredContent> getStarredContent() async {
    if (starredGate == null) return await super.getStarredContent();
    calls.add('getStarredContent');
    return await starredGate!.future;
  }

  final Map<int, List<Album>> newestPages = {};
  @override
  Future<List<Album>> getNewestAlbumListPage({
    required int size,
    required int offset,
  }) async {
    calls.add('newest:$offset:$size');
    onNewestPage?.call();
    if (newestError != null) {
      Error.throwWithStackTrace(newestError!, StackTrace.current);
    }
    return newestPages[offset] ?? const [];
  }
}

void main() {
  late NavisDatabase db;
  late ServerConfigRepository repo;
  late _AuditApi api;
  late DriftLibrarySyncEngine engine;
  late AdaptiveLibrarySyncCoordinator coordinator;
  const album = Album(
    id: 'a',
    name: 'Album',
    artistId: 'ar',
    artist: 'Artist',
    songCount: 2,
  );
  const song1 = Song(id: 's1', title: 'One', albumId: 'a', artistId: 'ar');
  const song2 = Song(id: 's2', title: 'Two', albumId: 'a', artistId: 'ar');
  Future<int> session({bool initial = false}) async {
    await repo.save(
      ServerConfigModel(
        url: 'https://example.com',
        username: 'fixture',
        password: 'fixture',
        apiVersion: '1.16.1',
        lastSynced: initial
            ? null
            : DateTime.now().subtract(const Duration(days: 1)),
        capabilitiesJson: jsonEncode({
          'navis': {
            'libraryIndexesCursor': FakeLibrarySyncApi.defaultIndexesCursor
                .toIso8601String(),
            'libraryFreshness': 'current',
          },
        }),
      ),
    );
    return (await repo.getActiveServer())!.id!;
  }

  Future<void> seed() async {
    await db.libraryDao.upsertArtists([
      ArtistsTableCompanion.insert(
        id: 'ar',
        name: 'Artist',
        albumCount: const Value(1),
      ),
    ]);
    await db.libraryDao.upsertAlbums([
      AlbumsTableCompanion.insert(
        id: 'a',
        name: 'Album',
        artistId: const Value('ar'),
        artistName: const Value('Artist'),
        songCount: const Value(2),
        songsHydrated: const Value(true),
        songsVerifiedAt: Value(DateTime.now()),
        recentlyAddedRank: const Value(123),
      ),
    ]);
    await db.libraryDao.upsertSongs([
      SongsTableCompanion.insert(
        id: 's1',
        title: 'One',
        albumId: const Value('a'),
        artistId: const Value('ar'),
      ),
      SongsTableCompanion.insert(
        id: 's2',
        title: 'Two',
        albumId: const Value('a'),
        artistId: const Value('ar'),
      ),
    ]);
    api.artists.add(const Artist(id: 'ar', name: 'Artist', albumCount: 1));
    api.indexes = const Indexes(
      indexes: [
        IndexesIndex(
          artists: [Artist(id: 'ar', name: 'Artist', albumCount: 1)],
        ),
      ],
    );
    api.artistDetails['ar'] = const Artist(
      id: 'ar',
      name: 'Artist',
      albumCount: 1,
      albums: [album],
    );
    api.albumDetails['a'] = album.copyWith(songs: [song1, song2]);
    api.fastPathPages[0] = [album];
    api.newestPages[0] = [album];
  }

  setUp(() {
    db = createTestDatabase();
    repo = ServerConfigRepository(db, credentials: FakeSyncCredentialStore());
    api = _AuditApi();
    engine = DriftLibrarySyncEngine(
      api: api,
      database: db,
      serverConfigRepository: repo,
      networkType: NetworkType.wifi,
      writeChunkSize: 4,
    );
    coordinator = AdaptiveLibrarySyncCoordinator(
      executor: engine,
      database: db,
      serverConfigRepository: repo,
      networkType: NetworkType.wifi,
      staleAfter: const Duration(hours: 1),
      readHasActivePlayback: () => false,
    );
  });
  tearDown(() async {
    await db.close();
  });
  for (final (name, network, request) in [
    (
      'wifi check',
      NetworkType.wifi,
      const LibrarySyncRequest.checkForUpdates(),
    ),
    (
      'wifi repair',
      NetworkType.wifi,
      const LibrarySyncRequest(
        origin: SyncRunOrigin.settingsRepair,
        intent: SyncRunIntent.repairLibrary,
      ),
    ),
    (
      'bounded mobile check',
      NetworkType.cellular,
      const LibrarySyncRequest.checkForUpdates(),
    ),
    (
      'broad mobile check',
      NetworkType.cellular,
      const LibrarySyncRequest.checkForUpdates(
        grant: SyncNetworkGrant.broadMeteredOnce,
      ),
    ),
    (
      'broad mobile repair',
      NetworkType.cellular,
      const LibrarySyncRequest(
        origin: SyncRunOrigin.settingsRepair,
        intent: SyncRunIntent.repairLibrary,
        grant: SyncNetworkGrant.broadMeteredOnce,
      ),
    ),
  ]) {
    test('explicit sync continues after the app is hidden: $name', () async {
      await session();
      await seed();
      var foreground = true;
      api.onNewestPage = () => foreground = false;
      final hiddenEngine = DriftLibrarySyncEngine(
        api: api,
        database: db,
        serverConfigRepository: repo,
        networkType: network,
      );
      final hiddenCoordinator = AdaptiveLibrarySyncCoordinator(
        executor: hiddenEngine,
        database: db,
        serverConfigRepository: repo,
        networkType: network,
        staleAfter: const Duration(hours: 1),
        readIsForeground: () => foreground,
        readHasActivePlayback: () => true,
      );

      final result = await hiddenCoordinator.requestSync(request);

      expect(foreground, isFalse);
      expect(result.status, LibrarySyncStatus.succeeded);
      if (network == NetworkType.wifi ||
          request.grant == SyncNetworkGrant.broadMeteredOnce) {
        expect(api.calls, containsAll(['getStarredContent', 'getPlaylists']));
      } else {
        expect(api.calls, isNot(contains('getStarredContent')));
        expect(api.calls, isNot(contains('getPlaylists')));
      }
    });
  }

  for (final (name, backgroundAllowed, boundedGrant, broadGrant, queued) in [
    ('background enabled', true, false, false, false),
    ('bounded queued delta', false, true, false, true),
    ('broad grant', false, false, true, false),
  ]) {
    test('automatic mobile delta reaches engine checkpoints: $name', () async {
      final serverId = await session();
      await seed();
      await db.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(serverId),
          currentGeneration: const Value(1),
          lastAuditAt: Value(DateTime.now()),
          lastAuxiliarySyncedAt: Value(DateTime.now()),
        ),
      );
      if (queued) {
        await db.librarySyncDao.enqueueWork(
          serverId: serverId,
          kind: LibrarySyncPlanKind.deltaReconcile.name,
          priority: 20,
        );
      }
      final policy = resolveSyncNetworkPolicy(
        networkType: NetworkType.cellular,
        nativeMetered: true,
        backgroundSyncUnmeteredOnly: !backgroundAllowed,
      );
      final mobileEngine = DriftLibrarySyncEngine(
        api: api,
        database: db,
        serverConfigRepository: repo,
        readSyncNetworkPolicy: () => policy,
      );
      final mobileCoordinator = AdaptiveLibrarySyncCoordinator(
        executor: mobileEngine,
        database: db,
        serverConfigRepository: repo,
        readSyncNetworkPolicy: () => policy,
        staleAfter: const Duration(hours: 1),
        readIsForeground: () => true,
        readHasActivePlayback: () => false,
      );

      final result = await mobileCoordinator.requestSync(
        LibrarySyncRequest(
          intent: SyncRunIntent.automaticCatalogCheck,
          origin: SyncRunOrigin.timer,
          grant: broadGrant
              ? SyncNetworkGrant.broadMeteredOnce
              : boundedGrant
              ? SyncNetworkGrant.boundedMeteredDiscovery
              : SyncNetworkGrant.none,
        ),
      );

      expect(result.planKind, LibrarySyncPlanKind.deltaReconcile);
      expect(result.status, LibrarySyncStatus.succeeded);
      expect(api.calls, contains('newest:0:100'));
      if (queued) {
        expect(
          (await db.librarySyncDao.getWork(
            serverId: serverId,
            kind: LibrarySyncPlanKind.deltaReconcile.name,
          ))?.status,
          'completed',
        );
      }
    });
  }

  test(
    'incomplete detail succeeds through coordinator and retries incrementally',
    () async {
      final serverId = await session(initial: true);
      await seed();
      api.albumDetails['a'] = album.copyWith(songs: [song1]);

      final first = await coordinator.requestSync(
        const LibrarySyncRequest(
          origin: SyncRunOrigin.settingsRepair,
          intent: SyncRunIntent.repairLibrary,
        ),
      );
      expect(first.status, LibrarySyncStatus.succeeded);
      expect(first.onlyIncompleteAlbumDetails, isTrue);
      expect(first.pendingHydrationCount, 1);
      expect(
        (await db.librarySyncDao.getOrCreateState(serverId)).currentGeneration,
        greaterThan(0),
      );
      expect((await repo.getActiveServer())!.lastSynced, isNotNull);

      api.albumDetails['a'] = album.copyWith(songs: [song1, song2]);
      api.calls.clear();
      final recovered = await coordinator.requestSync(
        const LibrarySyncRequest.automatic(),
      );
      expect(recovered.pendingHydrationCount, 0);
      expect(recovered.onlyIncompleteAlbumDetails, isFalse);
      expect(api.calls, contains('getAlbum:a'));
      expect((await repo.getActiveServer())!.lastSynced, isNotNull);
    },
  );

  test(
    'F22 fresh deletion observations compare identities and expire',
    () async {
      final serverId = await session();
      await seed();
      await db.libraryDao.upsertAlbums([
        AlbumsTableCompanion.insert(
          id: 'b',
          name: 'Other',
          artistId: const Value('ar'),
          songCount: const Value(0),
          songsHydrated: const Value(true),
        ),
      ]);
      const other = Album(id: 'b', name: 'Other', artistId: 'ar', songCount: 0);
      api.albumDetails['b'] = other;
      final first = await engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.fullRepair),
      );
      expect(first.candidateStatus, 'awaitingDeletionConfirmation');
      final original = (await db.librarySyncDao.getOrCreateState(serverId))
          .deletionCandidateFingerprint;
      // Same number of missing albums, different identity: cached first pages
      // would incorrectly reconfirm the old removal here.
      api.fastPathPages[0] = [other];
      api.newestPages[0] = [other];
      final changed = await engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.fullRepair),
      );
      expect(changed.candidateStatus, 'awaitingDeletionConfirmation');
      expect(await db.libraryDao.getAlbumById('a'), isNotNull);
      expect(await db.libraryDao.getAlbumById('b'), isNotNull);
      expect(
        (await db.librarySyncDao.getOrCreateState(serverId))
            .deletionCandidateFingerprint,
        isNot(original),
      );
      await db.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(serverId),
          candidateStartedAt: Value(
            DateTime.now().subtract(const Duration(days: 2)),
          ),
        ),
      );
      final expired = await engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.fullRepair),
      );
      expect(expired.candidateStatus, 'awaitingDeletionConfirmation');
      expect(await db.libraryDao.getAlbumById('a'), isNotNull);
      final confirmed = await engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.fullRepair),
      );
      expect(confirmed.status, LibrarySyncStatus.succeeded);
      expect(confirmed.candidateStatus, isNull);
      expect(await db.libraryDao.getAlbumById('a'), isNull);
      expect(await db.libraryDao.getAlbumById('b'), isNotNull);
    },
  );

  for (final boundary in [
    LibrarySyncStage.applyingCandidate,
    LibrarySyncStage.cleaningCandidate,
  ]) {
    test(
      'F37 ${boundary.name} reports the actual publication boundary',
      () async {
        await session();
        await seed();
        final changed = album.copyWith(
          name: 'Changed album',
          songs: [song1, song2],
        );
        api.fastPathPages[0] = [changed];
        api.newestPages[0] = [changed];
        api.albumDetails['a'] = changed;
        final progress = <LibrarySyncState>[];
        final result = await engine.executeSyncPlan(
          syncPlanForTest(LibrarySyncPlanKind.fullRepair),
          onProgress: (state) {
            progress.add(state);
            if (state.stage == boundary) {
              throw StateError('Stop exactly at the reported boundary');
            }
          },
        );
        expect(result.status, LibrarySyncStatus.failed);
        expect(
          progress.any(
            (state) =>
                state.stage == LibrarySyncStage.validatingCandidate &&
                state.candidateStatus == 'ready',
          ),
          isTrue,
        );
        final published = boundary == LibrarySyncStage.cleaningCandidate;
        expect(
          (await db.libraryDao.getAlbumById('a'))!.name,
          published ? 'Changed album' : 'Album',
        );
        final reported = progress.firstWhere(
          (state) => state.stage == boundary,
        );
        expect(reported.candidateStatus, published ? isNull : 'applying');
        if (published) expect(reported.candidateGeneration, isNull);
      },
    );
  }

  for (final path in ['target', 'incremental', 'repair']) {
    test(
      'F34 $path validates mixed detail before canonical projection',
      () async {
        await session();
        await seed();
        const remote = Song(
          id: 'remote-track',
          title: 'Remote',
          albumId: 'remote-parent',
          album: 'Remote album',
          isExternal: true,
        );
        final mixed = album.copyWith(
          songCount: 3,
          songs: [song1, song2, remote],
        );
        api.albumDetails['a'] = mixed;
        api.artistDetails['ar'] = api.artistDetails['ar']!.copyWith(
          albums: [mixed],
        );
        api.newestPages[0] = [mixed];
        api.fastPathPages[0] = [mixed];
        final result = switch (path) {
          'target' => await engine.hydrateAlbum('a'),
          'repair' => await engine.executeSyncPlan(
            syncPlanForTest(LibrarySyncPlanKind.fullRepair),
          ),
          _ => await engine.executeSyncPlan(
            syncPlanForTest(LibrarySyncPlanKind.deltaReconcile),
          ),
        };
        expect(result.status, LibrarySyncStatus.succeeded);
        expect((await db.libraryDao.getAlbumById('a'))!.songsHydrated, isTrue);
        expect(
          (await db.libraryDao.watchSongsByAlbum('a').first).map((s) => s.id),
          unorderedEquals(['s1', 's2']),
        );
        expect(
          (await db.libraryDao.getAllSongs()).map((song) => song.id),
          unorderedEquals(['s1', 's2']),
        );
        final reference = await db.libraryDao.getSongById('remote-track');
        if (path == 'target') {
          expect(reference?.isExternal, isTrue);
          expect(reference?.isProvisional, isTrue);
          expect(reference?.albumId, 'remote-parent');
        } else {
          expect(reference, isNull);
        }
      },
    );
  }
  test(
    'F34 truncated mixed detail still cannot replace local membership',
    () async {
      await session();
      await seed();
      api.albumDetails['a'] = album.copyWith(
        songCount: 3,
        songs: [
          song1,
          const Song(
            id: 'remote-track',
            title: 'Remote',
            albumId: 'remote-parent',
            isExternal: true,
          ),
        ],
      );
      expect(
        (await engine.hydrateAlbum('a')).status,
        LibrarySyncStatus.partial,
      );
      expect(await db.libraryDao.watchSongsByAlbum('a').first, hasLength(2));
      expect(await db.libraryDao.getSongById('remote-track'), isNull);
    },
  );
  test(
    'F35 promoted initial continuation obeys its incremental plan',
    () async {
      final id = await session(initial: true);
      await seed();
      await db.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(id),
          currentGeneration: const Value(1),
          lastAuditAt: Value(DateTime.now()),
        ),
      );
      final result = await coordinator.requestSync(
        const LibrarySyncRequest.checkForUpdates(),
      );
      expect(result.status, LibrarySyncStatus.succeeded);
      expect(result.failureCategory, isNull);
      expect(
        api.calls.where((call) => call.startsWith('getAlbumListPage')),
        isEmpty,
      );
      expect(api.calls, isNot(contains('getArtists')));
      expect((await repo.getActiveServer())!.lastSynced, isNotNull);
    },
  );

  test('F27 duplicate playlist entries retain order across refresh', () async {
    await session();
    await seed();
    api.playlistDetails['p'] = Playlist(
      id: 'p',
      name: 'Repeats',
      songCount: 3,
      entries: [song1, song1, song2],
    );
    final first = await engine.hydratePlaylist('p');
    expect(first.status, LibrarySyncStatus.succeeded);
    expect(
      (await db.playlistDao.watchPlaylistSongs('p').first).map((row) => row.id),
      ['s1', 's1', 's2'],
    );
    api.playlistDetails['p'] = Playlist(
      id: 'p',
      name: 'Repeats',
      songCount: 3,
      entries: [song2, song1, song1],
    );
    await engine.hydratePlaylist('p');
    expect(
      (await db.playlistDao.watchPlaylistSongs('p').first).map((row) => row.id),
      ['s2', 's1', 's1'],
    );
  });

  test('F10 explicit newest source evidence repairs old pollution and permits later import', () async {
    final serverId = await session();
    await seed();
    api.newestPages[0] = [album.copyWith(isExternal: true)];
    api.artistDetails['ar'] = api.artistDetails['ar']!.copyWith(albums: []);
    await coordinator.requestSync(const LibrarySyncRequest.checkForUpdates());
    expect((await db.libraryDao.getAlbumById('a'))!.isExternal, isTrue);
    expect(await db.libraryDao.getAllAlbums(), isEmpty);
    expect(await db.libraryDao.getSongById('s1'), isNotNull);
    final ledger = await db.librarySyncDao.getRecentOperationLedgerEntries(
      serverId,
    );
    expect(
      ledger.any((row) => row.operation == 'sourceEvidenceRepair'),
      isTrue,
    );
    api.newestPages[0] = [album.copyWith(isExternal: false)];
    api.artistDetails['ar'] = api.artistDetails['ar']!.copyWith(
      albums: [album],
    );
    await coordinator.requestSync(const LibrarySyncRequest.checkForUpdates());
    expect((await db.libraryDao.getAlbumById('a'))!.isProvisional, isFalse);
  });

  test('F14 unchanged headers still verify old track metadata', () async {
    await session();
    await seed();
    await db.customStatement('UPDATE albums SET songs_verified_at = NULL');
    api.albumDetails['a'] = album.copyWith(
      songs: [
        song1.copyWith(title: 'Corrected track title'),
        song2,
      ],
    );
    final first = await coordinator.requestSync(
      const LibrarySyncRequest.checkForUpdates(),
    );
    expect(first.status, LibrarySyncStatus.succeeded);
    expect(
      (await db.libraryDao.getSongById('s1'))!.title,
      'Corrected track title',
    );
    expect((await db.libraryDao.getAlbumById('a'))!.songsVerifiedAt, isNotNull);
    api.calls.clear();
    await coordinator.requestSync(const LibrarySyncRequest.checkForUpdates());
    expect(api.calls.where((call) => call.startsWith('getAlbum:')), isEmpty);
  });

  test(
    'cancellation waits for auxiliary cleanup and starts no later domain',
    () async {
      await session();
      await seed();
      api.starredGate = Completer<StarredContent>();
      final run = coordinator.requestSync(
        const LibrarySyncRequest.checkForUpdates(),
      );
      while (!api.calls.contains('getStarredContent')) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      var settled = false;
      final cancellation = coordinator.cancelAndWait().then(
        (_) => settled = true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(settled, isFalse);
      api.starredGate!.complete(const StarredContent());
      await cancellation;
      await run;
      expect(settled, isTrue);
      expect(api.calls, isNot(contains('getPlaylists')));
    },
  );

  test(
    'F33 cancellation suppresses an already queued coordinator request',
    () async {
      final id = await session();
      await seed();
      api.starredGate = Completer<StarredContent>();
      final active = coordinator.requestSync(
        const LibrarySyncRequest(
          intent: SyncRunIntent.manualCatalogCheck,
          target: LibrarySyncTarget.starred(),
          origin: SyncRunOrigin.libraryPullToRefresh,
        ),
      );
      while (!api.calls.contains('getStarredContent')) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      final queued = coordinator.requestSync(
        const LibrarySyncRequest(
          intent: SyncRunIntent.manualCatalogCheck,
          target: LibrarySyncTarget.playlistHeaders(),
          origin: SyncRunOrigin.libraryPullToRefresh,
        ),
      );
      while (await db.librarySyncDao.getWork(
            serverId: id,
            kind: 'targetedHydration',
            entityId: '@playlistHeaders',
          ) ==
          null) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      coordinator.cancelSync();
      api.starredGate!.complete(const StarredContent());
      await active;
      expect((await queued).status, LibrarySyncStatus.cancelled);
      expect(api.calls, isNot(contains('getPlaylists')));
      expect(
        (await db.librarySyncDao.getWork(
          serverId: id,
          kind: 'targetedHydration',
          entityId: '@playlistHeaders',
        ))!.status,
        'cancelled',
      );
    },
  );

  test('scheduled auxiliary work defers during playback', () async {
    final id = await session();
    await seed();
    final playing = AdaptiveLibrarySyncCoordinator(
      executor: engine,
      database: db,
      serverConfigRepository: repo,
      networkType: NetworkType.wifi,
      staleAfter: const Duration(hours: 1),
      readHasActivePlayback: () => true,
    );
    await playing.requestSync(const LibrarySyncRequest.automatic());
    final history = await db.librarySyncDao.getRecentSyncRunHistory(id);
    final auxiliary = history.where(
      (row) => row.intent.name == 'auxiliaryRefresh',
    );
    expect(auxiliary, hasLength(2));
    expect(auxiliary.every((row) => row.requestCount == 0), isTrue);
    expect(api.calls, isNot(contains('getStarredContent')));
    expect(api.calls, isNot(contains('getPlaylists')));
  });

  test(
    'F43 manual sync refreshes likes and playlists during playback',
    () async {
      final id = await session();
      await seed();
      for (final target in const <LibrarySyncTarget>[
        LibrarySyncTarget.starred(),
        LibrarySyncTarget.playlistHeaders(),
      ]) {
        await db.librarySyncDao.enqueueWork(
          serverId: id,
          kind: LibrarySyncPlanKind.targetedHydration.name,
          entityId: librarySyncTargetWorkKey(target),
          priority: 20,
        );
        final work = await db.librarySyncDao.getWork(
          serverId: id,
          kind: LibrarySyncPlanKind.targetedHydration.name,
          entityId: librarySyncTargetWorkKey(target),
        );
        await db.librarySyncDao.markCompleted(work!.id);
      }
      api.starredContent = const StarredContent(
        songs: [
          Song(id: 'remote-favorite', title: 'Favorite', isExternal: true),
        ],
      );
      api.playlists = const [Playlist(id: 'p', name: 'Playlist', songCount: 0)];
      final playing = AdaptiveLibrarySyncCoordinator(
        executor: engine,
        database: db,
        serverConfigRepository: repo,
        networkType: NetworkType.wifi,
        staleAfter: const Duration(hours: 1),
        readHasActivePlayback: () => true,
      );

      await playing.requestSync(const LibrarySyncRequest.checkForUpdates());

      expect(api.calls, contains('getStarredContent'));
      expect(api.calls, contains('getPlaylists'));
      expect(
        (await db.libraryDao.getSongById('remote-favorite'))?.starred,
        isNotNull,
      );
      expect((await db.playlistDao.getAllPlaylists()).single.id, 'p');
      expect(
        (await db.librarySyncDao.getWork(
          serverId: id,
          kind: LibrarySyncPlanKind.targetedHydration.name,
          entityId: '@starred',
        ))?.status,
        'completed',
      );
      expect(
        (await db.librarySyncDao.getWork(
          serverId: id,
          kind: LibrarySyncPlanKind.targetedHydration.name,
          entityId: '@playlistHeaders',
        ))?.status,
        'completed',
      );
    },
  );

  test(
    'F43 auxiliary completion is not hidden behind hydration backlog',
    () async {
      final id = await session();
      await seed();
      for (var index = 0; index < 65; index++) {
        await db.librarySyncDao.enqueueWork(
          serverId: id,
          kind: LibrarySyncPlanKind.targetedHydration.name,
          entityId: librarySyncTargetWorkKey(
            LibrarySyncTarget.album('backlog-$index'),
          ),
          priority: 100,
          workClass: 'interactive',
        );
      }
      api.starredContent = const StarredContent(
        songs: [
          Song(id: 'remote-favorite', title: 'Favorite', isExternal: true),
        ],
      );
      api.playlists = const [Playlist(id: 'p', name: 'Playlist', songCount: 0)];

      await coordinator.requestSync(const LibrarySyncRequest.checkForUpdates());

      expect(
        api.calls.where((call) => call == 'getStarredContent'),
        hasLength(1),
      );
      expect(api.calls.where((call) => call == 'getPlaylists'), hasLength(1));
      expect(
        (await db.librarySyncDao.getWork(
          serverId: id,
          kind: LibrarySyncPlanKind.targetedHydration.name,
          entityId: '@starred',
        ))?.status,
        'completed',
      );
      expect(
        (await db.librarySyncDao.getWork(
          serverId: id,
          kind: LibrarySyncPlanKind.targetedHydration.name,
          entityId: '@playlistHeaders',
        ))?.status,
        'completed',
      );
      expect(
        (await db.librarySyncDao.getOrCreateState(id)).lastAuxiliarySyncedAt,
        isNotNull,
      );
    },
  );

  test(
    'F43 scheduled incremental sync refreshes each due companion domain',
    () async {
      final id = await session();
      await seed();
      final stale = DateTime.now().subtract(const Duration(hours: 13));
      for (final target in const <LibrarySyncTarget>[
        LibrarySyncTarget.starred(),
        LibrarySyncTarget.playlistHeaders(),
      ]) {
        await db.librarySyncDao.enqueueWork(
          serverId: id,
          kind: LibrarySyncPlanKind.targetedHydration.name,
          entityId: librarySyncTargetWorkKey(target),
          priority: 20,
        );
        final work = await db.librarySyncDao.getWork(
          serverId: id,
          kind: LibrarySyncPlanKind.targetedHydration.name,
          entityId: librarySyncTargetWorkKey(target),
        );
        await db.librarySyncDao.markCompleted(work!.id, now: stale);
      }
      api.starredContent = const StarredContent(
        songs: [
          Song(
            id: 'scheduled-favorite',
            title: 'Scheduled favorite',
            isExternal: true,
          ),
        ],
      );
      api.playlists = const [
        Playlist(id: 'scheduled-playlist', name: 'Scheduled', songCount: 0),
      ];

      await coordinator.requestSync(const LibrarySyncRequest.automatic());

      expect(
        api.calls.where((call) => call == 'getStarredContent'),
        hasLength(1),
      );
      expect(api.calls.where((call) => call == 'getPlaylists'), hasLength(1));
      expect(
        (await db.libraryDao.getSongById('scheduled-favorite'))?.starred,
        isNotNull,
      );
      expect(
        (await db.playlistDao.getAllPlaylists()).single.id,
        'scheduled-playlist',
      );
      expect(
        (await db.librarySyncDao.getOrCreateState(id)).lastAuxiliarySyncedAt,
        isNotNull,
      );
    },
  );

  test(
    'F30 due discovery hydrates the new arrival ahead of an older backlog',
    () async {
      final id = await session();
      await seed();
      for (var i = 0; i < 35; i++) {
        final albumId = 'older-$i';
        await db.libraryDao.upsertAlbums([
          AlbumsTableCompanion.insert(
            id: albumId,
            name: albumId,
            songCount: const Value(1),
          ),
        ]);
        api.albumDetails[albumId] = Album(
          id: albumId,
          name: albumId,
          songCount: 1,
          songs: [Song(id: 'song-$i', title: 'Old', albumId: albumId)],
        );
      }
      const newest = Album(
        id: 'zzz-newest',
        name: 'New arrival',
        artistId: 'ar',
        songCount: 1,
      );
      api.newestPages[0] = [newest, album];
      api.albumDetails[newest.id] = newest.copyWith(
        songs: [
          const Song(
            id: 'new-track',
            title: 'New',
            albumId: 'zzz-newest',
            artistId: 'ar',
          ),
        ],
      );
      await db.librarySyncDao.enqueueWork(
        serverId: id,
        kind: LibrarySyncPlanKind.targetedHydration.name,
        priority: 100,
      );
      final result = await coordinator.requestSync(
        const LibrarySyncRequest.automatic(),
      );
      expect(
        api.calls.where((call) => call.startsWith('getAlbum:')).first,
        'getAlbum:zzz-newest',
      );
      expect(await db.libraryDao.getSongById('new-track'), isNotNull);
      expect(result.planKind, LibrarySyncPlanKind.deltaReconcile);
      expect(await db.libraryDao.countPendingHydrationAlbums(), 4);
    },
  );

  test(
    'F31 remote reference albums never become a canonical hydration backlog',
    () async {
      await session();
      await seed();
      await db.libraryDao.upsertProvisionalAlbums([
        AlbumsTableCompanion.insert(
          id: 'external-reference',
          name: 'Remote',
          starred: Value(DateTime.now()),
          isExternal: const Value(true),
        ),
        AlbumsTableCompanion.insert(
          id: 'unknown-reference',
          name: 'Unclassified',
        ),
      ]);
      expect(await db.libraryDao.countPendingHydrationAlbums(), 0);
      expect(await db.libraryDao.getPendingHydrationAlbumIds(), isEmpty);
      expect(
        await db.libraryDao.getPendingHydrationAlbumsByIds([
          'external-reference',
          'unknown-reference',
        ], limit: 10),
        isEmpty,
      );
      api.starredContent = const StarredContent(
        albums: [
          Album(id: 'external-reference', name: 'Remote', isExternal: true),
        ],
      );
      final result = await coordinator.requestSync(
        const LibrarySyncRequest.checkForUpdates(),
      );
      expect(result.status, LibrarySyncStatus.succeeded);
      expect(api.calls.where((call) => call.startsWith('getAlbum:')), isEmpty);
      expect(await db.libraryDao.getAlbumById('external-reference'), isNotNull);
    },
  );

  test(
    'F32 timestamp precision does not rehydrate unchanged newest albums',
    () async {
      await session();
      await seed();
      final created = DateTime.utc(2026, 1, 1, 0, 0, 0, 123);
      await (db.update(db.albumsTable)..where((row) => row.id.equals('a')))
          .write(AlbumsTableCompanion(serverCreatedAt: Value(created)));
      api.newestPages[0] = [album.copyWith(created: created)];
      for (var i = 0; i < 2; i++) {
        await coordinator.requestSync(
          const LibrarySyncRequest.checkForUpdates(),
        );
      }
      expect(api.calls.where((call) => call.startsWith('getAlbum:')), isEmpty);
      expect(await db.libraryDao.countPendingHydrationAlbums(), 0);
    },
  );

  test(
    'F32 header-only newest changes preserve verified track membership',
    () async {
      await session();
      await seed();
      final changed = album.copyWith(year: 2026, playCount: 4);
      api.newestPages[0] = [changed];
      api.artistDetails['ar'] = api.artistDetails['ar']!.copyWith(
        albums: [changed],
      );
      await coordinator.requestSync(const LibrarySyncRequest.checkForUpdates());
      expect(api.calls.where((call) => call.startsWith('getAlbum:')), isEmpty);
      expect((await db.libraryDao.getAlbumById('a'))!.year, 2026);
      expect(await db.libraryDao.watchSongsByAlbum('a').first, hasLength(2));
      expect(await db.libraryDao.countPendingHydrationAlbums(), 0);
    },
  );

  test(
    'F07 automatic hydration commits its budget and resumes the remainder',
    () async {
      final serverId = await session();
      await seed();
      await db.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(serverId),
          currentGeneration: const Value(1),
          lastCheckedAt: Value(DateTime.now()),
          lastAuditAt: Value(DateTime.now()),
        ),
      );
      for (var index = 0; index < 35; index++) {
        final id = 'pending-$index';
        await db.libraryDao.upsertAlbums([
          AlbumsTableCompanion.insert(
            id: id,
            name: id,
            songCount: const Value(1),
          ),
        ]);
        api.albumDetails[id] = Album(
          id: id,
          name: id,
          songCount: 1,
          songs: [Song(id: 'song-$index', title: 'Track', albumId: id)],
        );
      }
      await db.librarySyncDao.enqueueWork(
        serverId: serverId,
        kind: LibrarySyncPlanKind.targetedHydration.name,
        priority: 30,
      );
      final work = await db.librarySyncDao.getWork(
        serverId: serverId,
        kind: LibrarySyncPlanKind.targetedHydration.name,
      );
      await db.librarySyncDao.markCompleted(work!.id);
      final first = await coordinator.requestSync(
        const LibrarySyncRequest.automatic(),
      );
      expect(first.status, LibrarySyncStatus.deferred);
      expect(first.failureCategory, 'entityBudget');
      expect(
        api.calls.where((call) => call.startsWith('getAlbum:')),
        hasLength(32),
      );
      expect(await db.libraryDao.countPendingHydrationAlbums(), 3);
      expect(
        (await db.librarySyncDao.getWork(
          serverId: serverId,
          kind: LibrarySyncPlanKind.targetedHydration.name,
        ))!.status,
        'queued',
      );
      api.calls.clear();
      final second = await coordinator.requestSync(
        const LibrarySyncRequest.automatic(),
      );
      expect(second.status, LibrarySyncStatus.succeeded);
      expect(await db.libraryDao.countPendingHydrationAlbums(), 0);
      expect(
        api.calls.where((call) => call.startsWith('getAlbum:')),
        hasLength(3),
      );
    },
  );

  test(
    'F44 manual discovery reports committed budget-limited work as partial',
    () async {
      final serverId = await session();
      await seed();
      final automaticDeadline = DateTime.now()
          .add(const Duration(hours: 1))
          .toUtc();
      await db.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(serverId),
          currentGeneration: const Value(1),
          lastCheckedAt: Value(DateTime.now()),
          lastAuditAt: Value(DateTime.now()),
          failureStreak: const Value(1),
          nextEligibleAt: Value(
            DateTime.now().add(const Duration(minutes: 15)),
          ),
        ),
      );
      await db.librarySyncDao.setNextAutomaticCheckAt(
        serverId: serverId,
        nextAutomaticCheckAt: automaticDeadline,
      );
      for (var index = 0; index < 65; index++) {
        final id = 'manual-pending-$index';
        await db.libraryDao.upsertAlbums([
          AlbumsTableCompanion.insert(
            id: id,
            name: id,
            songCount: const Value(1),
          ),
        ]);
        api.albumDetails[id] = Album(
          id: id,
          name: id,
          songCount: 1,
          songs: [Song(id: 'manual-song-$index', title: 'Track', albumId: id)],
        );
      }
      await db.librarySyncDao.enqueueWork(
        serverId: serverId,
        kind: LibrarySyncPlanKind.targetedHydration.name,
        priority: 30,
      );
      final work = await db.librarySyncDao.getWork(
        serverId: serverId,
        kind: LibrarySyncPlanKind.targetedHydration.name,
      );
      await db.librarySyncDao.markCompleted(work!.id);

      final first = await coordinator.requestSync(
        const LibrarySyncRequest.checkForUpdates(),
      );

      expect(first.status, LibrarySyncStatus.partial);
      expect(first.failureCategory, 'entityBudget');
      expect(
        api.calls.where((call) => call.startsWith('getAlbum:')),
        hasLength(64),
      );
      expect(await db.libraryDao.countPendingHydrationAlbums(), 1);
      expect(
        (await db.librarySyncDao.getWork(
          serverId: serverId,
          kind: LibrarySyncPlanKind.deltaReconcile.name,
        ))!.status,
        'queued',
      );
      final history = await db.librarySyncDao.getRecentSyncRunHistory(serverId);
      final firstHistory = history.singleWhere(
        (entry) => entry.requestId == first.runRequestId,
      );
      expect(firstHistory.outcome, SyncRunOutcomeKind.partial);
      expect(firstHistory.reason, SyncSafeReason.responseBudgetExceeded);
      // A budget stop is a successful bounded check, not a failure: the
      // continuation stays queued without a cooldown, the failure circuit
      // closes, and the controller-owned automatic deadline is untouched.
      final afterBudget = await db.librarySyncDao.getOrCreateState(serverId);
      expect(first.nextRetryAt, isNull);
      expect(afterBudget.nextEligibleAt, isNull);
      expect(afterBudget.failureStreak, 0);
      expect(
        afterBudget.nextAutomaticCheckAt!.difference(automaticDeadline).abs(),
        lessThan(const Duration(seconds: 1)),
      );

      api.calls.clear();
      final resumed = await coordinator.requestSync(
        const LibrarySyncRequest.checkForUpdates(),
      );
      expect(resumed.status, LibrarySyncStatus.succeeded);
      expect(await db.libraryDao.countPendingHydrationAlbums(), 0);
      expect(
        api.calls.where((call) => call.startsWith('getAlbum:')),
        hasLength(1),
      );
    },
  );

  test(
    'F28 artist checkpoint survives a following hydration budget stop',
    () async {
      await session();
      await seed();
      final discovered = List.generate(
        35,
        (index) => Album(
          id: 'discovered-$index',
          name: 'Discovered $index',
          artistId: 'ar',
          artist: 'Artist',
          songCount: 1,
        ),
      );
      api.indexes = Indexes(
        lastModified: DateTime.utc(2026, 2, 1),
        indexes: [
          const IndexesIndex(
            artists: [Artist(id: 'ar', name: 'Artist', albumCount: 36)],
          ),
        ],
      );
      api.artistDetails['ar'] = Artist(
        id: 'ar',
        name: 'Artist',
        albumCount: 36,
        albums: [album, ...discovered],
      );
      for (final value in discovered) {
        api.albumDetails[value.id] = value.copyWith(
          songs: [
            Song(
              id: 'song-${value.id}',
              title: 'Track',
              albumId: value.id,
              artistId: 'ar',
            ),
          ],
        );
      }
      final first = await coordinator.requestSync(
        const LibrarySyncRequest.automatic(),
      );
      expect(first.status, LibrarySyncStatus.deferred);
      expect(first.failureCategory, 'entityBudget');
      expect(api.calls.where((call) => call == 'getArtist:ar'), hasLength(1));
      expect(await db.libraryDao.countPendingHydrationAlbums(), 3);
      expect(first.remainingVerificationCount, 0);
      api.calls.clear();
      final second = await coordinator.requestSync(
        const LibrarySyncRequest.automatic(),
      );
      expect(second.status, LibrarySyncStatus.succeeded);
      expect(await db.libraryDao.countPendingHydrationAlbums(), 0);
      expect(api.calls.where((call) => call.startsWith('getArtist:')), isEmpty);
      expect(
        api.calls.where((call) => call.startsWith('getAlbum:')),
        hasLength(3),
      );
    },
  );

  test(
    'F09 a detail response arriving after ownership changes cannot commit',
    () async {
      final serverId = await session();
      await seed();
      api.albumCompleter = Completer<Album>();
      final pending = coordinator.requestSync(
        const LibrarySyncRequest(
          intent: SyncRunIntent.manualCatalogCheck,
          target: LibrarySyncTarget.album('a'),
          origin: SyncRunOrigin.interaction,
        ),
      );
      for (var i = 0; i < 100 && !api.calls.contains('getAlbum:a'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(api.calls, contains('getAlbum:a'));
      await db.customStatement(
        'UPDATE library_sync_execution_lease SET owner_token = ? WHERE server_id = ?',
        ['replacement-owner', serverId],
      );
      await db.libraryDao.upsertSongs([
        SongsTableCompanion.insert(id: 's1', title: 'Newer owner edit'),
      ]);
      api.albumCompleter!.complete(album.copyWith(songs: [song1, song2]));
      final result = await pending;
      expect(result.status, LibrarySyncStatus.deferred);
      expect(result.planReason, 'leaseHeld');
      expect(
        (await db.libraryDao.getSongById('s1'))?.title,
        'Newer owner edit',
      );
      expect(
        (await db.librarySyncDao.getExecutionLease(serverId))?.ownerToken,
        'replacement-owner',
      );
    },
  );
  test('F02 scheduled discovery hydrates new albums with an unchanged artist index', () async {
    final serverId = await session();
    await seed();
    await db.librarySyncDao.writeState(
      LibrarySyncStateTableCompanion(
        serverId: Value(serverId),
        currentGeneration: const Value(1),
        lastAuditAt: Value(DateTime.now()),
        lastCheckedAt: Value(DateTime.now().subtract(const Duration(days: 1))),
        conditionalIndexesMode: const Value('reliable'),
      ),
    );
    const discovered = Album(
      id: 'b',
      name: 'New album',
      artistId: 'ar',
      artist: 'Artist',
      songCount: 1,
    );
    api.newestPages[0] = [discovered];
    api.artistDetails['ar'] = const Artist(
      id: 'ar',
      name: 'Artist',
      albumCount: 2,
      albums: [album, discovered],
    );
    api.albumDetails['b'] = discovered.copyWith(
      songs: const [
        Song(id: 's3', title: 'New track', albumId: 'b', artistId: 'ar'),
      ],
    );
    final result = await coordinator.requestSync(
      const LibrarySyncRequest.automatic(),
    );
    expect(result.planReason, 'automaticCatalogDiscovery');
    expect(result.status, LibrarySyncStatus.succeeded);
    expect(result.endpointRequests['getAlbum'], 1);
    expect((await db.libraryDao.getAlbumById('b'))?.songsHydrated, isTrue);
    expect((await db.libraryDao.getSongById('s3'))?.albumId, 'b');
    expect(
      api.calls.where((call) => call.startsWith('newest:')).length,
      lessThanOrEqualTo(2),
    );
    expect(
      api.calls.where((call) => call.startsWith('searchSongsPage')),
      isEmpty,
    );
    api.calls.clear();
    await coordinator.requestSync(const LibrarySyncRequest.automatic());
    expect(api.calls.where((call) => call.startsWith('newest:')), isEmpty);
  });
  test('F03 initial catalog initializes likes and playlist headers', () async {
    final serverId = await session(initial: true);
    api.starredContent = const StarredContent(
      songs: [Song(id: 'remote-favorite', title: 'Favorite', isExternal: true)],
    );
    api.playlists = const [Playlist(id: 'p', name: 'Playlist', songCount: 0)];
    final result = await coordinator.requestSync(
      const LibrarySyncRequest.automatic(),
    );
    expect(result.status, LibrarySyncStatus.succeeded);
    expect(
      api.calls.where((call) => call == 'getStarredContent'),
      hasLength(1),
    );
    expect(api.calls.where((call) => call == 'getPlaylists'), hasLength(1));
    expect(
      (await db.libraryDao.getSongById('remote-favorite'))?.starred,
      isNotNull,
    );
    expect(
      (await db.libraryDao.watchAllStarredSongs().first).single.id,
      'remote-favorite',
    );
    expect(await db.libraryDao.getAllSongs(), isEmpty);
    expect((await db.playlistDao.getAllPlaylists()).single.id, 'p');
    final state = await db.librarySyncDao.getOrCreateState(serverId);
    expect(state.lastAuxiliarySyncedAt, isNotNull);
    api.calls.clear();
    await coordinator.requestSync(const LibrarySyncRequest.automatic());
    expect(api.calls, isNot(contains('getStarredContent')));
    expect(api.calls, isNot(contains('getPlaylists')));
  });

  test(
    'F03 auxiliary failure retains its retry without suppressing other domains',
    () async {
      final serverId = await session(initial: true);
      api.throwOnStarred = DioException(
        requestOptions: RequestOptions(path: '/getStarred2'),
        type: DioExceptionType.connectionError,
      );
      final result = await coordinator.requestSync(
        const LibrarySyncRequest.automatic(),
      );
      expect(result.status, LibrarySyncStatus.succeeded);
      final starred = await db.librarySyncDao.getWork(
        serverId: serverId,
        kind: LibrarySyncPlanKind.targetedHydration.name,
        entityId: '@starred',
      );
      expect(starred?.status, 'failed');
      expect(starred?.notBefore, isNotNull);
      expect(
        (await db.librarySyncDao.getOrCreateState(serverId))
            .lastAuxiliarySyncedAt,
        isNull,
      );
      api.calls.clear();
      await coordinator.requestSync(const LibrarySyncRequest.automatic());
      expect(api.calls, isNot(contains('getStarredContent')));
      expect(api.calls, isNot(contains('getPlaylists')));
      api.throwOnStarred = null;
      await db.librarySyncDao.requeue(starred!.id);
      api.calls.clear();
      await coordinator.requestSync(const LibrarySyncRequest.automatic());
      expect(
        api.calls.where((call) => call == 'getStarredContent'),
        hasLength(1),
      );
      expect(api.calls, isNot(contains('getPlaylists')));
      expect(
        (await db.librarySyncDao.getOrCreateState(serverId))
            .lastAuxiliarySyncedAt,
        isNotNull,
      );
    },
  );
  test(
    'F05 resumed mixed external page uses the raw transport offset',
    () async {
      await session();
      await seed();
      api.fastPathPages[0] = [
        album,
        const Album(id: 'remote', name: 'External', isExternal: true),
      ];
      api.newestError = StateError('interrupt after page collection');
      expect(
        (await engine.executeSyncPlan(
          syncPlanForTest(LibrarySyncPlanKind.fullRepair),
        )).status,
        LibrarySyncStatus.failed,
      );
      api.calls.clear();
      api.newestError = null;
      api.fastPathErrors[1] = StateError('wrong resumed offset');
      expect(
        (await engine.executeSyncPlan(
          syncPlanForTest(LibrarySyncPlanKind.fullRepair),
        )).status,
        LibrarySyncStatus.succeeded,
      );
      expect(api.calls, isNot(contains('getAlbumListPage:1:500')));
    },
  );
  test('F06 bounded newest refresh preserves full rank tail', () async {
    await session();
    await seed();
    await db.libraryDao.upsertAlbums([
      AlbumsTableCompanion.insert(
        id: 'tail',
        name: 'Tail',
        songsHydrated: const Value(true),
        recentlyAddedRank: const Value(800),
      ),
    ]);
    expect(
      (await engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.deltaReconcile),
      )).status,
      LibrarySyncStatus.succeeded,
    );
    expect((await db.libraryDao.getAlbumById('tail'))!.recentlyAddedRank, 1);
  });
  test(
    'F10 incremental external album never enters canonical catalog',
    () async {
      await session();
      await seed();
      api.indexes = api.indexes.copyWith(
        lastModified: DateTime.utc(2026, 2, 1),
      );
      api.artistDetails['ar'] = const Artist(
        id: 'ar',
        name: 'Artist',
        albumCount: 2,
        albums: [
          album,
          Album(
            id: 'remote',
            name: 'Remote',
            artistId: 'ar',
            songCount: 1,
            isExternal: true,
          ),
        ],
      );
      api.albumDetails['remote'] = const Album(
        id: 'remote',
        name: 'Remote',
        artistId: 'ar',
        songCount: 1,
        isExternal: true,
        songs: [
          Song(
            id: 'remote-song',
            title: 'Remote',
            albumId: 'remote',
            isExternal: true,
          ),
        ],
      );
      final result = await engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.deltaReconcile),
      );
      expect(result.status, LibrarySyncStatus.succeeded);
      expect(await db.libraryDao.getAlbumById('remote'), isNull);
      expect(await db.libraryDao.getSongById('remote-song'), isNull);
    },
  );
  test('F12 newest discovery advances through server capped pages', () async {
    await session();
    await seed();
    api.newestPages[0] = [album];
    api.newestPages[1] = [const Album(id: 'new', name: 'New', songCount: 0)];
    final result = await engine.executeSyncPlan(
      syncPlanForTest(LibrarySyncPlanKind.deltaReconcile),
    );
    expect(result.status, LibrarySyncStatus.succeeded);
    expect(api.calls.where((c) => c.startsWith('newest:')).toList(), [
      'newest:0:100',
      'newest:1:100',
      'newest:2:100',
    ]);
    expect(await db.libraryDao.getAlbumById('new'), isNotNull);
  });
  test(
    'F17 missing playlist response container preserves cached playlists',
    () async {
      await session();
      await db.playlistDao.upsertPlaylists([
        PlaylistsTableCompanion.insert(id: 'p', name: 'Kept'),
      ]);
      final dio = Dio();
      final client = SubsonicApiClient(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'fixture',
          password: 'fixture',
          apiVersion: '1.16.1',
        ),
        dio: dio,
        enableLogging: false,
      );
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) => h.resolve(
            Response(
              requestOptions: o,
              statusCode: 200,
              data: {
                'subsonic-response': {'status': 'ok'},
              },
            ),
          ),
        ),
      );
      final e = DriftLibrarySyncEngine(
        api: SubsonicLibrarySyncApi(client),
        database: db,
        serverConfigRepository: repo,
      );
      expect((await e.syncPlaylistHeaders()).status, LibrarySyncStatus.failed);
      expect(await db.playlistDao.getAllPlaylists(), hasLength(1));
      client.close();
    },
  );
  test(
    'F04 exhausted transient repair failure remains retryable durable work',
    () async {
      final id = await session();
      api.getArtistsError = const SubsonicConnectionException(
        'fixture offline',
      );
      final result = await coordinator.requestSync(
        const LibrarySyncRequest(
          origin: SyncRunOrigin.settingsRepair,
          intent: SyncRunIntent.repairLibrary,
        ),
      );
      expect(result.status, LibrarySyncStatus.failed);
      final work = await db.librarySyncDao.getWork(
        serverId: id,
        kind: 'fullRepair',
      );
      expect(work!.status, 'failed');
      expect(work.notBefore, isNotNull);
      expect(
        (await db.librarySyncDao.getOrCreateState(id)).lastCheckedAt,
        isNull,
      );
      expect((await db.librarySyncDao.getOrCreateState(id)).failureStreak, 1);
    },
  );
  test('F09 a foreground coordinator takes over a worker lease and recovers its running probe', () async {
    final id = await session();
    await seed();
    await db.librarySyncDao.writeState(
      LibrarySyncStateTableCompanion(
        serverId: Value(id),
        currentGeneration: const Value(1),
        lastAuditAt: Value(DateTime.now()),
        lastAuxiliarySyncedAt: Value(DateTime.now()),
      ),
    );
    await db.librarySyncDao.enqueueWork(
      serverId: id,
      kind: 'probe',
      priority: 10,
    );
    final work = (await db.librarySyncDao.getWork(
      serverId: id,
      kind: 'probe',
    ))!;
    await db.librarySyncDao.markRunning(work.id);
    await db.librarySyncDao.acquireExecutionLease(
      serverId: id,
      ownerToken: 'fixture-owner',
      ownerKind: 'androidWorker',
      now: DateTime.now(),
      ttl: const Duration(minutes: 10),
    );
    final result = await coordinator.requestSync(
      const LibrarySyncRequest.automatic(),
    );
    expect(result.planReason, isNot('leaseHeld'));
    expect(
      (await db.librarySyncDao.getWork(serverId: id, kind: 'probe'))!.status,
      isNot('running'),
    );
    expect(await db.librarySyncDao.getExecutionLease(id), isNull);
  });
  test('F09 a second foreground coordinator leaves the active foreground owner untouched', () async {
    final id = await session();
    await seed();
    await db.librarySyncDao.writeState(
      LibrarySyncStateTableCompanion(
        serverId: Value(id),
        currentGeneration: const Value(1),
        lastAuditAt: Value(DateTime.now()),
        lastAuxiliarySyncedAt: Value(DateTime.now()),
      ),
    );
    await db.librarySyncDao.enqueueWork(
      serverId: id,
      kind: 'probe',
      priority: 10,
    );
    final work = (await db.librarySyncDao.getWork(
      serverId: id,
      kind: 'probe',
    ))!;
    await db.librarySyncDao.markRunning(work.id);
    await db.librarySyncDao.acquireExecutionLease(
      serverId: id,
      ownerToken: 'fixture-owner',
      ownerKind: 'foreground',
      now: DateTime.now(),
      ttl: const Duration(minutes: 10),
    );
    final result = await coordinator.requestSync(
      const LibrarySyncRequest.automatic(),
    );
    expect(result.planReason, 'leaseHeld');
    expect(
      (await db.librarySyncDao.getWork(serverId: id, kind: 'probe'))!.status,
      'running',
    );
    final lease = await db.librarySyncDao.getExecutionLease(id);
    expect(lease?.ownerToken, 'fixture-owner');
    expect(lease?.ownerKind, 'foreground');
  });
  test(
    'F13 background executor can resume admitted automatic delta work',
    () async {
      final id = await session();
      await seed();
      await db.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(id),
          currentGeneration: const Value(1),
        ),
      );
      await db.librarySyncDao.enqueueWork(
        serverId: id,
        kind: 'deltaReconcile',
        priority: 50,
      );
      final worker = AdaptiveLibrarySyncCoordinator(
        executor: engine,
        database: db,
        serverConfigRepository: repo,
        networkType: NetworkType.wifi,
        staleAfter: const Duration(hours: 1),
        readHasActivePlayback: () => false,
        readIsForeground: () => false,
        isBackgroundExecution: true,
        executionOwnerKind: 'androidWorker',
      );
      final result = await worker.requestSync(
        const LibrarySyncRequest.automatic(),
      );
      expect(result.status, isNot(LibrarySyncStatus.deferred));
      expect(api.calls, isNotEmpty);
    },
  );
  test('F08 later playlist change reactivates completed hydration', () async {
    final id = await session();
    api.playlists = [const Playlist(id: 'p', name: 'First', songCount: 1)];
    await engine.syncPlaylistHeaders();
    var work = (await db.librarySyncDao.getWork(
      serverId: id,
      kind: 'targetedHydration',
      entityId: 'playlist:p',
    ))!;
    await db.librarySyncDao.markCompleted(work.id);
    api.playlists = [const Playlist(id: 'p', name: 'Changed', songCount: 2)];
    await engine.syncPlaylistHeaders();
    work = (await db.librarySyncDao.getWork(
      serverId: id,
      kind: 'targetedHydration',
      entityId: 'playlist:p',
    ))!;
    expect(work.status, 'queued');
    expect(
      await db.librarySyncDao.getRunnableWork(
        serverId: id,
        now: DateTime.now(),
      ),
      isNotEmpty,
    );
  });
  test('F11 new index evidence reopens completed delta work', () async {
    final id = await session();
    await seed();
    await db.librarySyncDao.writeState(
      LibrarySyncStateTableCompanion(
        serverId: Value(id),
        currentGeneration: const Value(1),
        conditionalIndexesMode: const Value('reliable'),
        lastAuditAt: Value(DateTime.now()),
        lastAuxiliarySyncedAt: Value(DateTime.now()),
      ),
    );
    await db.librarySyncDao.enqueueWork(
      serverId: id,
      kind: 'deltaReconcile',
      priority: 50,
    );
    final work = (await db.librarySyncDao.getWork(
      serverId: id,
      kind: 'deltaReconcile',
    ))!;
    await db.librarySyncDao.markCompleted(work.id);
    api.indexes = api.indexes.copyWith(lastModified: DateTime.utc(2026, 2, 1));
    final probeCoordinator = AdaptiveLibrarySyncCoordinator(
      executor: engine,
      database: db,
      serverConfigRepository: repo,
      networkType: NetworkType.cellular,
      staleAfter: const Duration(hours: 1),
      readHasActivePlayback: () => false,
    );
    final result = await probeCoordinator.requestSync(
      const LibrarySyncRequest.automatic(),
    );
    expect(result.probeIndexChanged, true);
    expect(
      (await db.librarySyncDao.getWork(
        serverId: id,
        kind: 'deltaReconcile',
      ))!.status,
      'queued',
    );
    expect(
      await db.librarySyncDao.getRunnableWork(
        serverId: id,
        now: DateTime.now(),
      ),
      isNotEmpty,
    );
  });
  test(
    'F25 newest metadata cannot mark an unhydrated album complete',
    () async {
      await session();
      await seed();
      const discovered = Album(
        id: 'new-album',
        name: 'New',
        artistId: 'ar',
        artist: 'Artist',
        songCount: 1,
        duration: 10,
      );
      api.newestPages[0] = [discovered, album];
      api.artistDetails['ar'] = const Artist(
        id: 'ar',
        name: 'Artist',
        albumCount: 2,
        albums: [album, discovered],
      );
      api.albumDetails['new-album'] = discovered.copyWith(
        songs: [
          const Song(
            id: 'new-song',
            title: 'New',
            albumId: 'new-album',
            artistId: 'ar',
          ),
        ],
      );
      expect(
        (await engine.executeSyncPlan(
          syncPlanForTest(LibrarySyncPlanKind.deltaReconcile),
        )).status,
        LibrarySyncStatus.succeeded,
      );
      expect(api.calls, contains('getAlbum:new-album'));
      expect(
        (await db.libraryDao.getAlbumById('new-album'))!.songsHydrated,
        isTrue,
      );
      expect(
        await db.libraryDao.watchSongsByAlbum('new-album').first,
        hasLength(1),
      );
    },
  );

  group('worker hand-off', () {
    const albumIds = ['a', 'b', 'c', 'd', 'e', 'f'];
    const pageOffsets = [0, 2, 4, 6];
    late FakeLibrarySyncApi apiW;
    late FakeLibrarySyncApi apiF;
    late DriftLibrarySyncEngine engineW;
    late DriftLibrarySyncEngine engineF;
    late AdaptiveLibrarySyncCoordinator worker;
    late AdaptiveLibrarySyncCoordinator fg;
    late int serverId;
    late LibrarySyncStateTableData baseline;
    // Started workers, so a failing test lets them finish before the database
    // closes.
    final workerRuns = <Future<void>>[];

    String artistOf(String id) => switch (id) {
      'a' || 'b' || 'g' => 'ar',
      'c' || 'd' => 'ar2',
      _ => 'ar3',
    };
    Album albumOf(String id) => id == 'a'
        ? album
        : Album(
            id: id,
            name: 'Album $id',
            artistId: artistOf(id),
            artist: 'Artist ${artistOf(id)}',
            songCount: 1,
          );
    List<Song> songsOf(String id) => id == 'a'
        ? [song1, song2]
        : [
            Song(
              id: 's-$id',
              title: 'Song $id',
              albumId: id,
              artistId: artistOf(id),
            ),
          ];

    // Three artists, six albums in pages of two (the empty page at offset 6
    // ends the listing), every album with songs. The newest feed lists only
    // the live baseline album, so a delta check has nothing new to hydrate and
    // newest-feed calls never count as album-list pages.
    void serve(FakeLibrarySyncApi api) {
      api.artists.addAll(const [
        Artist(id: 'ar', name: 'Artist ar', albumCount: 2),
        Artist(id: 'ar2', name: 'Artist ar2', albumCount: 2),
        Artist(id: 'ar3', name: 'Artist ar3', albumCount: 2),
      ]);
      const layout = {
        0: ['a', 'b'],
        2: ['c', 'd'],
        4: ['e', 'f'],
      };
      layout.forEach((offset, ids) {
        api.fastPathPages[offset] = [for (final id in ids) albumOf(id)];
      });
      for (final id in albumIds) {
        api.albumDetails[id] = albumOf(id).copyWith(songs: songsOf(id));
      }
      api.newestPages[0] = [album];
    }

    DriftLibrarySyncEngine newEngine(
      FakeLibrarySyncApi api, {
      Future<void> Function(Map<String, String> aliases)? onBeforeRemap,
    }) => serialDriftEngine(
      api: api,
      database: db,
      repository: repo,
      networkType: NetworkType.wifi,
      fastPathPageSize: 2,
      // One album per hydration batch, so a hydrated album is committed
      // before the next one is requested.
      writeChunkSize: 1,
      onBeforeSongIdentityRemap: onBeforeRemap,
    );
    AdaptiveLibrarySyncCoordinator newWorker(DriftLibrarySyncEngine engine) =>
        AdaptiveLibrarySyncCoordinator(
          executor: engine,
          database: db,
          serverConfigRepository: repo,
          networkType: NetworkType.wifi,
          staleAfter: const Duration(hours: 1),
          readHasActivePlayback: () => false,
          readIsForeground: () => false,
          isBackgroundExecution: true,
          executionOwnerKind: 'androidWorker',
          executionLeaseHeartbeatInterval: const Duration(milliseconds: 50),
          executionLeaseTtl: const Duration(seconds: 10),
        );
    AdaptiveLibrarySyncCoordinator newForeground(
      DriftLibrarySyncEngine engine,
    ) => AdaptiveLibrarySyncCoordinator(
      executor: engine,
      database: db,
      serverConfigRepository: repo,
      networkType: NetworkType.wifi,
      staleAfter: const Duration(hours: 1),
      readHasActivePlayback: () => false,
    );

    setUp(() async {
      serverId = await session();
      await seed();
      final now = DateTime.now();
      await db.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(serverId),
          currentGeneration: const Value(1),
          lastAuditAt: Value(now),
          lastAuxiliarySyncedAt: Value(now),
        ),
      );
      baseline = await db.librarySyncDao.getOrCreateState(serverId);
      apiW = FakeLibrarySyncApi();
      apiF = FakeLibrarySyncApi();
      serve(apiW);
      serve(apiF);
      engineW = newEngine(apiW);
      engineF = newEngine(apiF);
      worker = newWorker(engineW);
      fg = newForeground(engineF);
    });
    tearDown(() async {
      for (final api in [apiW, apiF]) {
        for (final gate in [
          ...api.pageGates.values,
          ...api.albumGates.values,
        ]) {
          if (!gate.isCompleted) gate.complete();
        }
        final artists = api.artistsCompleter;
        if (artists != null && !artists.isCompleted) {
          artists.complete(api.artists);
        }
      }
      await Future.wait(
        workerRuns,
      ).timeout(const Duration(seconds: 10), onTimeout: () => const <void>[]);
      workerRuns.clear();
    });

    int callCount(FakeLibrarySyncApi api, String call) =>
        api.calls.where((c) => c == call).length;
    Map<int, int> pages(FakeLibrarySyncApi api) => {
      for (final o in pageOffsets)
        o: api.calls.where((c) => c.startsWith('getAlbumListPage:$o:')).length,
    };
    Map<String, int> fetches(
      FakeLibrarySyncApi api, [
      List<String> ids = albumIds,
    ]) => {for (final id in ids) id: callCount(api, 'getAlbum:$id')};
    Map<String, int> only(Map<String, int> some, [List<String>? ids]) => {
      for (final id in ids ?? albumIds) id: some[id] ?? 0,
    };

    Future<void> until(bool Function() done, String what) async {
      for (var i = 0; i < 500 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(done(), isTrue, reason: 'timed out waiting for $what');
    }

    Future<void> queueCatalog() => db.librarySyncDao.enqueueWork(
      serverId: serverId,
      kind: 'catalogSnapshot',
      priority: 50,
    );
    // The realistic route into a catalog snapshot: a queued snapshot row that a
    // background automatic request resumes.
    Future<LibrarySyncState> startWorker() {
      final run = () async {
        await queueCatalog();
        return await worker.requestSync(const LibrarySyncRequest.automatic());
      }();
      workerRuns.add(run.then((_) {}, onError: (Object _) {}));
      return run;
    }

    // The foreground's first request only runs the once-per-process recovery
    // block (everything is fresh, so the plan is skipped), so a later takeover
    // happens at the execution acquire and not in the recovery block.
    Future<void> warmUp() async {
      await db.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(serverId),
          lastCheckedAt: Value(DateTime.now()),
        ),
      );
      final result = await fg.requestSync(const LibrarySyncRequest.automatic());
      expect(result.status, LibrarySyncStatus.skipped);
      await db.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(serverId),
          lastCheckedAt: const Value(null),
        ),
      );
      apiF.calls.clear();
    }

    Future<LibrarySyncWorkTableData?> catalogWork() =>
        db.librarySyncDao.getWork(serverId: serverId, kind: 'catalogSnapshot');
    Future<LibrarySyncWorkTableData?> pageWork(int offset) =>
        db.librarySyncDao.getWork(
          serverId: serverId,
          kind: 'catalogAlbumPage',
          entityId: '2:$offset',
        );
    Future<void> expectNothingRunning() async {
      expect(
        (await db.select(db.librarySyncWorkTable).get()).where(
          (w) => w.status == 'running',
        ),
        isEmpty,
      );
      expect(
        (await db.select(db.librarySyncRunAttemptTable).get()).where(
          (a) => a.status == 0,
        ),
        isEmpty,
      );
    }

    // The assertions every takeover shares. [worker] is null when no worker is
    // involved. [workerMayFinish] relaxes the worker-side ledger checks for
    // cases where the worker can complete before the takeover lands.
    // [leaseLost] is the exact number of executionLeaseLost ledger rows, or
    // null for "at most one".
    Future<void> expectHandedOff(
      LibrarySyncState foreground,
      LibrarySyncState? workerResult, {
      Set<String> albums = const {'a', 'b', 'c', 'd', 'e', 'f'},
      int generationAdvance = 1,
      bool workerMayFinish = false,
      int? leaseLost = 1,
    }) async {
      expect(foreground.planReason, isNot('leaseHeld'));
      expect(
        foreground.status,
        anyOf(LibrarySyncStatus.succeeded, LibrarySyncStatus.partial),
      );
      expect(foreground.failureCategory, isNull);

      final state = await db.librarySyncDao.getOrCreateState(serverId);
      expect(
        state.currentGeneration,
        baseline.currentGeneration + generationAdvance,
      );
      final liveAlbums = (await db.libraryDao.getAllAlbums()).map((a) => a.id);
      expect(liveAlbums.toList()..sort(), albums.toList()..sort());
      final expectedSongs = [
        for (final id in albums)
          ...apiF.albumDetails[id]!.songs.map((s) => s.id),
      ]..sort();
      final liveSongs = (await db.libraryDao.getAllSongs()).map((s) => s.id);
      expect(liveSongs.toList()..sort(), expectedSongs);

      expect(await db.librarySyncDao.getExecutionLease(serverId), isNull);
      await expectNothingRunning();

      final attempts = await db.select(db.librarySyncRunAttemptTable).get();
      final outcomes = await db.select(db.librarySyncRunOutcomeTable).get();
      final workerAttempts = {
        for (final a in attempts)
          if (a.ownerKind == 1) a.id,
      };
      if (!workerMayFinish) {
        expect(
          outcomes.where((o) => workerAttempts.contains(o.attemptId)),
          isEmpty,
          reason: 'a fenced-out worker must not write an outcome',
        );
      }
      final perRequest = <int, int>{};
      for (final o in outcomes) {
        perRequest[o.requestId] = (perRequest[o.requestId] ?? 0) + 1;
      }
      expect(perRequest.values.where((n) => n > 1), isEmpty);
      final mine = outcomes.where(
        (o) => o.requestId == foreground.runRequestId,
      );
      expect(mine, hasLength(1));
      expect(mine.single.attemptId, foreground.runAttemptId);
      expect(workerAttempts, isNot(contains(foreground.runAttemptId)));

      if (workerResult != null) {
        expect(
          workerResult.planReason == 'leaseHeld' ||
              workerResult.status == LibrarySyncStatus.cancelled ||
              (workerMayFinish &&
                  (workerResult.status == LibrarySyncStatus.succeeded ||
                      workerResult.status == LibrarySyncStatus.partial)),
          isTrue,
          reason:
              'worker ended ${workerResult.status} ${workerResult.planReason}',
        );
      }
      expect(state.failureStreak, baseline.failureStreak);
      expect(state.nextEligibleAt, baseline.nextEligibleAt);

      final lost = (await db.librarySyncDao.getRecentOperationLedgerEntries(
        serverId,
      )).where((e) => e.operation == 'executionLeaseLost').length;
      if (leaseLost == null) {
        expect(lost, lessThanOrEqualTo(1));
      } else {
        expect(lost, leaseLost);
      }
    }

    const check = LibrarySyncRequest.checkForUpdates();

    test(
      '14 takeover before the first page starts a fresh generation',
      () async {
        apiW.artistsCompleter = Completer<List<Artist>>();
        final w = startWorker();
        await until(
          () => apiW.calls.contains('getArtists'),
          'worker at artists',
        );
        expect(
          (await db.librarySyncDao.getOrCreateState(serverId)).candidateStatus,
          'collecting',
        );

        final f = await fg.requestSync(check);
        apiW.artistsCompleter!.complete(apiW.artists);
        final workerResult = await w;

        await expectHandedOff(f, workerResult);
        expect(pages(apiW), {0: 0, 2: 0, 4: 0, 6: 0});
        // No completed page to re-verify, so no boundary request either.
        expect(pages(apiF), {0: 1, 2: 1, 4: 1, 6: 1});
        expect(fetches(apiW), only({}));
        expect(fetches(apiF), only({for (final id in albumIds) id: 1}));
      },
    );

    for (final warm in [false, true]) {
      test(
        '15${warm ? 'w' : ''} takeover after page 0 resumes the same candidate generation${warm ? ' (warm foreground)' : ''}',
        () async {
          if (warm) await warmUp();
          apiW.pageGates[2] = Completer<void>();
          final w = startWorker();
          await until(
            () => apiW.calls.any((c) => c.startsWith('getAlbumListPage:2:')),
            'worker at page 2',
          );
          final pageZero = (await pageWork(0))!;
          expect(pageZero.status, 'completed');
          expect(await pageWork(2), isNull);

          final LibrarySyncState f;
          if (warm) {
            // The takeover happens at the execution acquire, after the
            // foreground planned: it runs its own plan and only requeues the
            // worker's catalog row.
            final first = await fg.requestSync(check);
            expect(first.planReason, isNot('leaseHeld'));
            expect(first.planKind, isNot(LibrarySyncPlanKind.catalogSnapshot));
            await expectNothingRunning();
            expect((await catalogWork())!.status, 'queued');
            expect(pages(apiF), {0: 0, 2: 0, 4: 0, 6: 0});
            f = await fg.requestSync(check);
          } else {
            f = await fg.requestSync(check);
          }
          apiW.pageGates[2]!.complete();
          final workerResult = await w;

          await expectHandedOff(f, workerResult);
          expect(pages(apiW), {0: 1, 2: 1, 4: 0, 6: 0});
          // Page 0 is the boundary re-check; page 2 was in flight in W.
          expect(pages(apiF), {0: 1, 2: 1, 4: 1, 6: 1});
          expect(fetches(apiW), only({}));
          expect(fetches(apiF), only({for (final id in albumIds) id: 1}));
          // The page row is the one the worker committed, not a rebuilt one.
          expect((await pageWork(0))!.id, pageZero.id);
        },
      );
    }

    test('16 takeover after all pages, before promotion', () async {
      var scanCalls = 0;
      final gate = Completer<void>();
      apiW.onGetScanStatus = () async {
        if (++scanCalls == 2) await gate.future;
        return null;
      };
      final w = startWorker();
      await until(() => scanCalls >= 2, 'worker at the promotion scan check');
      expect(
        (await db.librarySyncDao.getOrCreateState(serverId)).candidateStatus,
        'ready',
      );
      final pageTwo = (await pageWork(2))!;

      final f = await fg.requestSync(check);
      gate.complete();
      final workerResult = await w;

      await expectHandedOff(f, workerResult);
      expect(pages(apiW), {0: 1, 2: 1, 4: 1, 6: 1});
      // Only the first and last completed pages (offset 6 is the empty
      // terminal page) are re-verified.
      expect(pages(apiF), {0: 1, 2: 0, 4: 0, 6: 1});
      expect(fetches(apiW), only({for (final id in albumIds) id: 1}));
      expect(fetches(apiF), only({}));
      expect((await pageWork(2))!.id, pageTwo.id);
    });

    test(
      '17 takeover during promotion waits for the worker transaction',
      () async {
        // A provisional song matched by recording id makes the promotion
        // transaction call the remap hook, which pauses the worker inside it.
        const remapped = Song(
          id: 's-f',
          title: 'Song f',
          albumId: 'f',
          artistId: 'ar3',
          musicBrainzId: 'recording-mbid',
        );
        for (final api in [apiW, apiF]) {
          api.albumDetails['f'] = albumOf('f').copyWith(songs: [remapped]);
        }
        await db.libraryDao.upsertProvisionalSongs([
          SongsTableCompanion.insert(
            id: 'cached-remote-song',
            title: 'Song f',
            albumId: const Value('a'),
            artistId: const Value('ar'),
            recordingMbid: const Value('recording-mbid'),
          ),
        ]);
        final inTransaction = Completer<void>();
        final release = Completer<void>();
        engineW = newEngine(
          apiW,
          onBeforeRemap: (_) async {
            inTransaction.complete();
            await release.future;
          },
        );
        worker = newWorker(engineW);
        final w = startWorker();
        await inTransaction.future.timeout(const Duration(seconds: 20));

        var finished = false;
        final fFuture = fg
            .requestSync(check)
            .whenComplete(() => finished = true);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        // Same connection: the worker's open transaction holds everything back,
        // and nothing of the promotion is visible before it commits.
        expect(finished, isFalse);
        expect(apiF.calls, isEmpty);
        release.complete();
        final f = await fFuture;
        final workerResult = await w;

        await expectHandedOff(
          f,
          workerResult,
          workerMayFinish: true,
          leaseLost: null,
        );
        expect(pages(apiW), {0: 1, 2: 1, 4: 1, 6: 1});
        expect(fetches(apiW), only({for (final id in albumIds) id: 1}));
        // Promoted once: the foreground neither resumes nor promotes again.
        expect(pages(apiF), {0: 0, 2: 0, 4: 0, 6: 0});
        expect(fetches(apiF), only({}));
        expect(await db.libraryDao.getSongById('cached-remote-song'), isNull);
      },
    );

    test('18 takeover mid album hydration keeps hydrated albums', () async {
      // Hydration fills the candidate before promotion, tracked by the
      // candidate's own pending-hydration markers while the catalog work row
      // stays running.
      apiW.albumGates['c'] = Completer<void>();
      final w = startWorker();
      await until(() => apiW.calls.contains('getAlbum:c'), 'worker at album c');

      final f = await fg.requestSync(check);
      apiW.albumGates['c']!.complete();
      final workerResult = await w;

      await expectHandedOff(f, workerResult);
      expect(pages(apiW), {0: 1, 2: 1, 4: 1, 6: 1});
      expect(pages(apiF), {0: 1, 2: 0, 4: 0, 6: 1});
      expect(fetches(apiW), only({'a': 1, 'b': 1, 'c': 1}));
      // The album in flight in the worker is fetched again, once.
      expect(fetches(apiF), only({'c': 1, 'd': 1, 'e': 1, 'f': 1}));
    });

    test('19 takeover while the worker is finishing', () async {
      await warmUp();
      final workerResult = await startWorker();
      expect(workerResult.status, LibrarySyncStatus.succeeded);
      expect(await db.librarySyncDao.getExecutionLease(serverId), isNull);
      // The worker's promotion is committed and only its lease release is
      // pending: nothing is running, but the lease is still live.
      await db.librarySyncDao.acquireExecutionLease(
        serverId: serverId,
        ownerToken: 'finishing-worker',
        ownerKind: 'androidWorker',
        now: DateTime.now(),
        ttl: const Duration(minutes: 10),
      );

      final f = await fg.requestSync(check);

      await expectHandedOff(
        f,
        workerResult,
        workerMayFinish: true,
        leaseLost: 0,
      );
      expect(pages(apiW), {0: 1, 2: 1, 4: 1, 6: 1});
      expect(fetches(apiW), only({for (final id in albumIds) id: 1}));
      // The foreground ran its own plan and fetched no catalog pages.
      expect(pages(apiF), {0: 0, 2: 0, 4: 0, 6: 0});
      expect(fetches(apiF), only({}));
    });

    test('20 the heartbeat stops a worker whose lease was taken', () async {
      await warmUp();
      apiW.pageGates[2] = Completer<void>();
      final w = startWorker();
      await until(
        () => apiW.calls.any((c) => c.startsWith('getAlbumListPage:2:')),
        'worker at page 2',
      );
      expect(apiW.activeRequestsCancelled, isFalse);

      final first = await fg.requestSync(check);
      expect(first.planReason, isNot('leaseHeld'));
      await until(
        () => apiW.activeRequestsCancelled,
        'the worker engine to be cancelled by its heartbeat',
      );
      final callsAtTakeover = apiW.calls.length;
      apiW.pageGates[2]!.complete();
      final workerResult = await w;

      expect(apiW.calls, hasLength(callsAtTakeover));
      expect(
        workerResult.planReason == 'leaseHeld' ||
            workerResult.status == LibrarySyncStatus.cancelled,
        isTrue,
      );
      expect(await db.librarySyncDao.getExecutionLease(serverId), isNull);
      await expectNothingRunning();
      expect((await catalogWork())!.status, 'queued');
      final state = await db.librarySyncDao.getOrCreateState(serverId);
      expect(state.currentGeneration, baseline.currentGeneration);
      expect(state.failureStreak, baseline.failureStreak);
    });

    test('21 a second foreground request joins the takeover run', () async {
      apiW.pageGates[2] = Completer<void>();
      final w = startWorker();
      await until(
        () => apiW.calls.any((c) => c.startsWith('getAlbumListPage:2:')),
        'worker at page 2',
      );
      apiF.pageGates[4] = Completer<void>();
      final first = fg.requestSync(check);
      await until(
        () => apiF.calls.any((c) => c.startsWith('getAlbumListPage:4:')),
        'foreground at page 4',
      );

      final second = fg.requestSync(check);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      apiF.pageGates[4]!.complete();
      final f = await first;
      final joined = await second;
      apiW.pageGates[2]!.complete();
      final workerResult = await w;

      await expectHandedOff(f, workerResult);
      expect(joined.planReason, isNot('leaseHeld'));
      expect(joined.status, isNot(LibrarySyncStatus.deferred));
      final outcomes = await db.select(db.librarySyncRunOutcomeTable).get();
      expect(
        outcomes.where((o) => o.safeReason == SyncSafeReason.leaseHeld.index),
        isEmpty,
      );
      expect(pages(apiF), {0: 1, 2: 1, 4: 1, 6: 1});
    });

    test(
      '22 a second foreground coordinator leaves the first untouched',
      () async {
        final apiF2 = FakeLibrarySyncApi();
        serve(apiF2);
        final fg2 = newForeground(newEngine(apiF2));
        await queueCatalog();
        apiF.pageGates[2] = Completer<void>();
        final first = fg.requestSync(check);
        await until(
          () => apiF.calls.any((c) => c.startsWith('getAlbumListPage:2:')),
          'first foreground at page 2',
        );
        final lease = (await db.librarySyncDao.getExecutionLease(serverId))!;
        expect(lease.ownerKind, 'foreground');
        final requests = await db.select(db.librarySyncRunRequestTable).get();

        final second = await fg2.requestSync(check);

        expect(second.planReason, 'leaseHeld');
        expect(apiF2.calls, isEmpty);
        final after = (await db.librarySyncDao.getExecutionLease(serverId))!;
        expect(after.ownerToken, lease.ownerToken);
        expect((await catalogWork())!.status, 'running');
        expect(
          (await db.select(db.librarySyncRunAttemptTable).get()).map(
            (a) => a.status,
          ),
          [0],
        );
        expect(
          (await db.select(db.librarySyncRunRequestTable).get()).map(
            (r) => (r.id, r.status),
          ),
          requests.map((r) => (r.id, r.status)),
        );

        apiF.pageGates[2]!.complete();
        final f = await first;
        await expectHandedOff(f, null, leaseLost: 0);
        expect(pages(apiF), {0: 1, 2: 1, 4: 1, 6: 1});
      },
    );

    test(
      '23 an expiring lease during the takeover behaves like preemption',
      () async {
        await warmUp();
        apiW.pageGates[2] = Completer<void>();
        final w = startWorker();
        await until(
          () => apiW.calls.any((c) => c.startsWith('getAlbumListPage:2:')),
          'worker at page 2',
        );
        final pageZero = (await pageWork(0))!;
        await db.customStatement(
          'UPDATE library_sync_execution_lease SET expires_at = ? '
          'WHERE server_id = ?',
          [
            DateTime.now()
                    .subtract(const Duration(minutes: 1))
                    .millisecondsSinceEpoch ~/
                1000,
            serverId,
          ],
        );

        final first = await fg.requestSync(check);
        expect(first.planReason, isNot('leaseHeld'));
        await expectNothingRunning();
        expect((await catalogWork())!.status, 'queued');
        final f = await fg.requestSync(check);
        apiW.pageGates[2]!.complete();
        final workerResult = await w;

        await expectHandedOff(f, workerResult);
        expect(pages(apiW), {0: 1, 2: 1, 4: 0, 6: 0});
        expect(pages(apiF), {0: 1, 2: 1, 4: 1, 6: 1});
        expect(fetches(apiF), only({for (final id in albumIds) id: 1}));
        expect((await pageWork(0))!.id, pageZero.id);
      },
    );

    test(
      '24 an OS cancel racing the takeover leaves one consistent outcome',
      () async {
        apiW.pageGates[2] = Completer<void>();
        final w = startWorker();
        await until(
          () => apiW.calls.any((c) => c.startsWith('getAlbumListPage:2:')),
          'worker at page 2',
        );

        // The cancel is flagged while the worker is still paused, so the
        // takeover lands before the worker can write anything.
        final cancel = worker.cancelAndWait();
        final fFuture = fg.requestSync(check);
        final f = await fFuture;
        apiW.pageGates[2]!.complete();
        await cancel;
        final workerResult = await w;

        await expectHandedOff(f, workerResult);
        expect(pages(apiW), {0: 1, 2: 1, 4: 0, 6: 0});
        expect(pages(apiF), {0: 1, 2: 1, 4: 1, 6: 1});
      },
    );

    test(
      '24b an OS cancel and the foreground request start together',
      () async {
        apiW.pageGates[2] = Completer<void>();
        final w = startWorker();
        await until(
          () => apiW.calls.any((c) => c.startsWith('getAlbumListPage:2:')),
          'worker at page 2',
        );

        final cancel = worker.cancelAndWait();
        apiW.pageGates[2]!.complete();
        final f = await fg.requestSync(check);
        await cancel;
        final workerResult = await w;

        // Whichever side wins, the ledger and the lease stay consistent. If
        // the cancel committed first the worker parks the catalog work as
        // cancelled and the foreground's check must not resume it.
        final state = await db.librarySyncDao.getOrCreateState(serverId);
        final promoted = state.currentGeneration > baseline.currentGeneration;
        await expectHandedOff(
          f,
          workerResult,
          albums: promoted ? {'a', 'b', 'c', 'd', 'e', 'f'} : {'a'},
          generationAdvance: promoted ? 1 : 0,
          workerMayFinish: true,
          leaseLost: null,
        );
      },
    );

    test('25 a server catalog that changed since the worker starts a new candidate', () async {
      apiW.pageGates[2] = Completer<void>();
      final w = startWorker();
      await until(
        () => apiW.calls.any((c) => c.startsWith('getAlbumListPage:2:')),
        'worker at page 2',
      );
      final pageZero = (await pageWork(0))!;
      // Album b is replaced by g on the server after the worker committed
      // page 0.
      apiF.albumDetails['g'] = albumOf('g').copyWith(songs: songsOf('g'));
      apiF.fastPathPages[0] = [albumOf('a'), albumOf('g')];

      final f = await fg.requestSync(check);
      apiW.pageGates[2]!.complete();
      final workerResult = await w;

      await expectHandedOff(
        f,
        workerResult,
        albums: {'a', 'c', 'd', 'e', 'f', 'g'},
      );
      expect(pages(apiW), {0: 1, 2: 1, 4: 0, 6: 0});
      // The boundary check fails, so page 0 is requested again for the new
      // candidate.
      expect(pages(apiF), {0: 2, 2: 1, 4: 1, 6: 1});
      expect(fetches(apiW, [...albumIds, 'g']), only({}, [...albumIds, 'g']));
      expect(
        fetches(apiF, [...albumIds, 'g']),
        only(
          {'a': 1, 'c': 1, 'd': 1, 'e': 1, 'f': 1, 'g': 1},
          [...albumIds, 'g'],
        ),
      );
      expect(
        await db.librarySyncCandidateDao.getAlbumIds(
          serverId: serverId,
          generation: 2,
        ),
        isEmpty,
      );
      expect((await pageWork(0))!.id, isNot(pageZero.id));
    });

    // Two production-style engines (own connection, 5 s busy wait) on one
    // file. The worker's promotion transaction outlasts the foreground's busy
    // wait, so the foreground defers; then the worker's lock is released and
    // the foreground retries. [workerDies] makes the worker roll back instead
    // of committing the promotion.
    Future<void> crossConnectionHold({required bool workerDies}) async {
      final directory = await Directory.systemTemp.createTemp('navis-xconn-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/fixture.sqlite';
      final credentials = FakeSyncCredentialStore();

      // A plain read: getOrCreateState opens a write transaction, which would
      // wait on the worker's lock like any other write.
      Future<LibrarySyncStateTableData> readState() => (db.select(
        db.librarySyncStateTable,
      )..where((t) => t.serverId.equals(serverId))).getSingle();

      await db.close();
      db = NavisDatabase.atPath(path);
      repo = ServerConfigRepository(db, credentials: credentials);
      serverId = await session();
      await seed();
      final seededAt = DateTime.now();
      await db.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(serverId),
          currentGeneration: const Value(1),
          lastAuditAt: Value(seededAt),
          lastAuxiliarySyncedAt: Value(seededAt),
        ),
      );
      baseline = await readState();
      final workerDb = NavisDatabase.atPath(path);
      addTearDown(workerDb.close);
      final workerRepo = ServerConfigRepository(
        workerDb,
        credentials: credentials,
      );

      // A provisional song matched by recording id makes the promotion
      // transaction call the remap hook, which holds the worker's lock.
      const remapped = Song(
        id: 's-f',
        title: 'Song f',
        albumId: 'f',
        artistId: 'ar3',
        musicBrainzId: 'recording-mbid',
      );
      for (final api in [apiW, apiF]) {
        api.albumDetails['f'] = albumOf('f').copyWith(songs: [remapped]);
      }
      await db.libraryDao.upsertProvisionalSongs([
        SongsTableCompanion.insert(
          id: 'cached-remote-song',
          title: 'Song f',
          albumId: const Value('a'),
          artistId: const Value('ar'),
          recordingMbid: const Value('recording-mbid'),
        ),
      ]);
      final inTransaction = Completer<void>();
      final release = Completer<void>();
      worker = AdaptiveLibrarySyncCoordinator(
        executor: serialDriftEngine(
          api: apiW,
          database: workerDb,
          repository: workerRepo,
          networkType: NetworkType.wifi,
          fastPathPageSize: 2,
          writeChunkSize: 1,
          onBeforeSongIdentityRemap: (_) async {
            inTransaction.complete();
            await release.future;
          },
        ),
        database: workerDb,
        serverConfigRepository: workerRepo,
        networkType: NetworkType.wifi,
        staleAfter: const Duration(hours: 1),
        readHasActivePlayback: () => false,
        readIsForeground: () => false,
        isBackgroundExecution: true,
        executionOwnerKind: 'androidWorker',
        executionLeaseHeartbeatInterval: const Duration(milliseconds: 50),
        executionLeaseTtl: const Duration(seconds: 10),
      );
      fg = newForeground(newEngine(apiF));
      await warmUp();

      final w = startWorker();
      await inTransaction.future.timeout(const Duration(seconds: 20));
      final candidate = (await readState()).candidateGeneration;
      expect(candidate, baseline.currentGeneration + 1);

      // The foreground's writes queue behind the worker for the full 5 s busy
      // wait: contention, not a failure.
      final busy = await fg.requestSync(check);

      expect(busy.status, LibrarySyncStatus.deferred);
      expect(busy.planReason, 'leaseHeld');
      var state = await readState();
      expect(state.failureStreak, baseline.failureStreak);
      expect(state.nextEligibleAt, baseline.nextEligibleAt);
      // The provider retries a live worker lease at its 30 s floor, not at
      // the heartbeat-extended expiry.
      final lease = (await db.librarySyncDao.getExecutionLease(serverId))!;
      expect(lease.ownerKind, 'androidWorker');
      expect(lease.expiresAt.isAfter(DateTime.now().toUtc()), isTrue);
      expect(apiF.calls, isEmpty);

      if (workerDies) {
        // A killed process: the connection closes under the open transaction,
        // which rolls back and frees the lock, but the worker's lease and
        // running rows are left behind for the takeover to recover.
        await workerDb.close().timeout(const Duration(seconds: 20));
      }
      release.complete();
      final workerResult = await w.catchError(
        (Object _) => const LibrarySyncState(
          status: LibrarySyncStatus.failed,
          stage: LibrarySyncStage.completed,
        ),
      );
      if (workerDies) {
        // The promotion rolled back: the candidate and its pages survive.
        expect(workerResult.status, isNot(LibrarySyncStatus.succeeded));
        expect(
          (await readState()).currentGeneration,
          baseline.currentGeneration,
        );
      } else {
        expect(workerResult.status, LibrarySyncStatus.succeeded);
      }

      var retried = await fg.requestSync(check);
      if (workerDies) {
        // As test 15w: a warm foreground's first request takes over the dead
        // worker's lease and requeues its catalog row; the next one continues
        // the candidate.
        expect(retried.planReason, isNot('leaseHeld'));
        expect((await catalogWork())!.status, 'queued');
        await expectNothingRunning();
        retried = await fg.requestSync(check);
      }

      expect(retried.planReason, isNot('leaseHeld'));
      expect(
        retried.status,
        anyOf(
          LibrarySyncStatus.succeeded,
          LibrarySyncStatus.partial,
          LibrarySyncStatus.skipped,
        ),
      );
      state = await readState();
      // Exactly one promotion, of the very candidate the worker built.
      expect(state.currentGeneration, candidate);
      final liveAlbums = (await db.libraryDao.getAllAlbums()).map((a) => a.id);
      expect(liveAlbums.toList()..sort(), albumIds);
      expect(await db.librarySyncDao.getExecutionLease(serverId), isNull);
      await expectNothingRunning();
      expect(
        (await db.select(db.librarySyncRunRequestTable).get()).where(
          (r) => r.status == 1,
        ),
        isEmpty,
      );
      // No second download of anything the worker already fetched.
      expect(fetches(apiF), only({}));
      expect(pages(apiF).values.reduce((a, b) => a + b), lessThanOrEqualTo(2));
      await workerDb.close();
    }

    test(
      '26 a worker transaction past the busy wait defers the foreground, '
      'which then finds the single promotion',
      () => crossConnectionHold(workerDies: false),
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      '27 a worker that dies in its transaction hands the same candidate '
      'generation to the retrying foreground',
      () => crossConnectionHold(workerDies: true),
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });
}
