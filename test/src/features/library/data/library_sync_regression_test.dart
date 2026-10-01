import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';

import 'dart:convert';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
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
  Completer<StarredContent>? starredGate;
  @override
  Future<StarredContent> getStarredContent() async {
    if (starredGate == null) return super.getStarredContent();
    calls.add('getStarredContent');
    return starredGate!.future;
  }

  final Map<int, List<Album>> newestPages = {};
  @override
  Future<List<Album>> getNewestAlbumListPage({
    required int size,
    required int offset,
  }) async {
    calls.add('newest:$offset:$size');
    if (newestError != null) throw newestError!;
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
      isolateThreshold: 1000,
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
  test('incomplete detail survives coordinator as partial and retries incrementally', () async {
    final serverId = await session(initial: true);
    await seed();
    api.albumDetails['a'] = album.copyWith(songs: [song1]);

    final first = await coordinator.requestSync(
      const LibrarySyncRequest.repair(),
    );
    expect(first.status, LibrarySyncStatus.partial);
    expect(first.onlyIncompleteAlbumDetails, isTrue);
    expect(first.pendingHydrationCount, 1);
    expect(
      (await db.librarySyncDao.getOrCreateState(serverId)).currentGeneration,
      greaterThan(0),
    );
    expect((await repo.getActiveServer())!.lastSynced, isNull);

    api.albumDetails['a'] = album.copyWith(songs: [song1, song2]);
    api.calls.clear();
    final recovered = await coordinator.requestSync(
      const LibrarySyncRequest.automatic(),
    );
    expect(recovered.pendingHydrationCount, 0);
    expect(recovered.onlyIncompleteAlbumDetails, isFalse);
    expect(api.calls, contains('getAlbum:a'));
    expect((await repo.getActiveServer())!.lastSynced, isNotNull);
  });

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
      final first = await engine.forceFullSync();
      expect(first.candidateStatus, 'awaitingDeletionConfirmation');
      final original = (await db.librarySyncDao.getOrCreateState(serverId))
          .deletionCandidateFingerprint;
      // Same number of missing albums, different identity: cached first pages
      // would incorrectly reconfirm the old removal here.
      api.fastPathPages[0] = [other];
      api.newestPages[0] = [other];
      final changed = await engine.forceFullSync();
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
      final expired = await engine.forceFullSync();
      expect(expired.candidateStatus, 'awaitingDeletionConfirmation');
      expect(await db.libraryDao.getAlbumById('a'), isNotNull);
      final confirmed = await engine.forceFullSync();
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
        final result = await engine.forceFullSync(
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
          'repair' => await engine.forceFullSync(),
          _ => await engine.syncNow(),
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
      expect((await db.libraryDao.watchSongsByAlbum('a').first), hasLength(2));
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
      expect(api.calls, isNot(contains('getGenres')));
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
          trigger: LibrarySyncTrigger.user,
          intent: LibrarySyncIntent.checkForUpdates,
          target: LibrarySyncTarget.starred(),
        ),
      );
      while (!api.calls.contains('getStarredContent')) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      final queued = coordinator.requestSync(
        const LibrarySyncRequest(
          trigger: LibrarySyncTrigger.user,
          intent: LibrarySyncIntent.checkForUpdates,
          target: LibrarySyncTarget.playlistHeaders(),
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
    expect(api.calls, isNot(contains('getGenres')));
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
          Song(
            id: 'remote-favorite',
            title: 'Favorite',
            isExternal: true,
          ),
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
      expect(api.calls, isNot(contains('getGenres')));
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
          Song(
            id: 'remote-favorite',
            title: 'Favorite',
            isExternal: true,
          ),
        ],
      );
      api.playlists = const [Playlist(id: 'p', name: 'Playlist', songCount: 0)];

      await coordinator.requestSync(const LibrarySyncRequest.checkForUpdates());

      expect(
        api.calls.where((call) => call == 'getStarredContent'),
        hasLength(1),
      );
      expect(api.calls.where((call) => call == 'getPlaylists'), hasLength(1));
      expect(api.calls, isNot(contains('getGenres')));
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
      expect(api.calls, isNot(contains('getGenres')));
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
          trigger: LibrarySyncTrigger.interaction,
          intent: LibrarySyncIntent.checkForUpdates,
          target: LibrarySyncTarget.album('a'),
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
    expect(result.endpointRequests.containsKey('getGenres'), isFalse);
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
  test(
    'F03 initial catalog initializes likes and playlist headers without genres',
    () async {
      final serverId = await session(initial: true);
      api.starredContent = const StarredContent(
        songs: [
          Song(id: 'remote-favorite', title: 'Favorite', isExternal: true),
        ],
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
      expect(api.calls, isNot(contains('getGenres')));
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
      expect(api.calls, isNot(contains('getGenres')));
      expect(api.calls, isNot(contains('getPlaylists')));
    },
  );

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
      expect(api.calls, isNot(contains('getGenres')));
      expect(api.calls, isNot(contains('getPlaylists')));
      api.throwOnStarred = null;
      await db.librarySyncDao.requeue(starred!.id);
      api.calls.clear();
      await coordinator.requestSync(const LibrarySyncRequest.automatic());
      expect(
        api.calls.where((call) => call == 'getStarredContent'),
        hasLength(1),
      );
      expect(api.calls, isNot(contains('getGenres')));
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
      expect((await engine.forceFullSync()).status, LibrarySyncStatus.failed);
      api.calls.clear();
      api.newestError = null;
      api.fastPathErrors[1] = StateError('wrong resumed offset');
      expect(
        (await engine.forceFullSync()).status,
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
    expect((await engine.syncNow()).status, LibrarySyncStatus.succeeded);
    expect(
      (await db.libraryDao.getAlbumById('tail'))!.recentlyAddedRank,
      1,
    );
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
      final result = await engine.syncNow();
      expect(result.status, LibrarySyncStatus.succeeded);
      expect(await db.libraryDao.getAlbumById('remote'), isNull);
      expect(
        await db.libraryDao.getSongById('remote-song'),
        isNull,
      );
    },
  );
  test('F12 newest discovery advances through server capped pages', () async {
    await session();
    await seed();
    api.newestPages[0] = [album];
    api.newestPages[1] = [const Album(id: 'new', name: 'New', songCount: 0)];
    final result = await engine.syncNow();
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
      expect(
        (await e.syncPlaylistHeaders()).status,
        LibrarySyncStatus.failed,
      );
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
        const LibrarySyncRequest.repair(),
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
  test(
    'F09 second coordinator leaves the active lease owner untouched',
    () async {
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
      expect(result.planReason, 'leaseHeld');
      expect(
        (await db.librarySyncDao.getWork(serverId: id, kind: 'probe'))!.status,
        'running',
      );
    },
  );
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
  test(
    'F08 later playlist change reactivates completed hydration',
    () async {
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
    },
  );
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
      expect((await engine.syncNow()).status, LibrarySyncStatus.succeeded);
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
}
