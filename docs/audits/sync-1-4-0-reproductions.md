# Sync 1.4.0 audit reproduction fixtures

Companion evidence for [Sync Improvement Plan — 1.4.0](../plans/Sync_Improvement_Plan_1-4-0.md), audited 2026-09-19.

These 19 **characterization tests assert the defective current behavior**. Passing them confirms the audit reproduction; it does not certify correctness. Do not add them unchanged to release acceptance tests. For a fix, reverse the relevant assertions and move a focused regression into its owning test suite.

The fixtures use in-memory SQLite, fake responses, and example credentials. They do not access the live server. The fake API/credential scaffolding is derived from the repository's existing `library_sync_engine_test.dart`; the audit-specific scenarios are F01–F18 and F24. The full source is retained here so a clean of `build/` does not erase the reproduction.

From the repository root, extract and run:

```bash
python3 - <<'PYTHON'
from pathlib import Path
text = Path('docs/audits/sync-1-4-0-reproductions.md').read_text()
source = text.split('```dart\n', 1)[1].split('\n```', 1)[0]
output = Path('build/sync-audit-1-4-0/audit_reproductions_test.dart')
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(source + '\n')
PYTHON
flutter test build/sync-audit-1-4-0/audit_reproductions_test.dart --reporter expanded
```

Result on the audited working tree: **19 passed**. No runtime application implementation was changed to obtain this result. The assertions may intentionally fail after fixes land; update the plan's resolution record instead of weakening the fixes.

```dart
import 'package:dio/dio.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/features/library/data/adaptive_library_sync_coordinator.dart';

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/domain/sync_run_contract.dart';
import 'package:navis/src/utils/connectivity.dart';

import '../../test/helpers/test_database.dart';

const _meteredManualDiscoveryPlan = SyncExecutionPlan(
  request: SyncRunRequest(
    contractVersion: SyncRunRequest.currentContractVersion,
    origin: SyncRunOrigin.libraryPullToRefresh,
    intent: SyncRunIntent.manualCatalogCheck,
    target: LibrarySyncTarget.catalog(),
    networkGrant: SyncNetworkGrant.boundedMeteredDiscovery,
    priority: 60,
  ),
  kind: SyncExecutionPlanKind.manualCatalogDiscovery,
  reason: SyncSafeReason.none,
  budget: SyncExecutionBudget(
    allowedEndpoints: <SyncEndpoint>{
      SyncEndpoint.indexes,
      SyncEndpoint.newestAlbums,
      SyncEndpoint.artist,
      SyncEndpoint.album,
    },
    maxNewestPages: 1,
    maxAlbumHydrations: 3,
    maxResponseBytes: 16 * 1024 * 1024,
    maxTotalBytes: null,
    maxConcurrency: 1,
  ),
);

class _FakeCredentialStore implements SecureCredentialStore {
  String? _password;

  @override
  Future<void> clearPassword() async {
    _password = null;
  }

  @override
  Future<String?> readPassword() async => _password;

  @override
  Future<void> savePassword(String password) async {
    _password = password;
  }
}

class _FakeLibrarySyncApi implements LibrarySyncApi {
  static final DateTime defaultIndexesCursor = DateTime.utc(2026, 1, 1);
  final List<String> calls = <String>[];
  final List<DateTime?> requestedIndexesCursors = <DateTime?>[];
  final List<Artist> artists = <Artist>[];
  final Map<String, Artist> artistDetails = <String, Artist>{};
  final Map<String, Album> albumDetails = <String, Album>{};
  final Map<String, Playlist> playlistDetails = <String, Playlist>{};
  final Map<int, List<Album>> fastPathPages = <int, List<Album>>{};
  final Map<int, Object> fastPathErrors = <int, Object>{};
  final Map<int, List<Song>> bulkSongPages = <int, List<Song>>{};
  StarredContent starredContent = const StarredContent();
  List<Genre> genres = <Genre>[];
  List<Playlist> playlists = <Playlist>[];
  Indexes indexes = const Indexes();
  Completer<List<Artist>>? artistsCompleter;

  Exception? throwOnFastPath;
  Exception? throwOnIndexes;
  Exception? throwOnSongSearch;
  Exception? throwOnStarred;
  Exception? throwOnGenres;
  Exception? throwOnPlaylists;
  final Map<String, Object> albumErrors = <String, Object>{};
  final Map<String, Object> artistErrors = <String, Object>{};
  final Set<String> notFoundAlbumIds = <String>{};
  final Set<String> notFoundArtistIds = <String>{};
  final Set<String> permanentTransientAlbumIds = <String>{};
  Object? getArtistsError;
  final Map<String, int> transientAlbumFailures = <String, int>{};
  Duration albumDelay = Duration.zero;
  Completer<Album>? albumCompleter;
  bool activeRequestsCancelled = false;
  int currentAlbumRequests = 0;
  int maxConcurrentAlbumRequests = 0;

  @override
  void beginRun() {
    activeRequestsCancelled = false;
  }

  @override
  void cancelActiveRequests() {
    activeRequestsCancelled = true;
    final completer = albumCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(
        const SubsonicConnectionException('cancelled'),
      );
    }
  }

  @override
  Future<Album> getAlbum(String id, {int? maxResponseBytes}) async {
    calls.add('getAlbum:$id');
    currentAlbumRequests++;
    if (currentAlbumRequests > maxConcurrentAlbumRequests) {
      maxConcurrentAlbumRequests = currentAlbumRequests;
    }
    final transientFailures = transientAlbumFailures[id];
    if (transientFailures != null && transientFailures > 0) {
      transientAlbumFailures[id] = transientFailures - 1;
      currentAlbumRequests--;
      throw const SubsonicConnectionException('transient');
    }
    if (permanentTransientAlbumIds.contains(id)) {
      currentAlbumRequests--;
      throw const SubsonicConnectionException('transient');
    }
    if (notFoundAlbumIds.contains(id)) {
      currentAlbumRequests--;
      throw const SubsonicNotFoundException(message: 'Album not found');
    }
    final albumError = albumErrors[id];
    if (albumError != null) {
      currentAlbumRequests--;
      throw albumError;
    }
    if (albumDelay > Duration.zero) {
      await Future<void>.delayed(albumDelay);
    }
    final completer = albumCompleter;
    if (completer != null) {
      try {
        return await completer.future;
      } finally {
        currentAlbumRequests--;
      }
    }
    final album = albumDetails[id];
    currentAlbumRequests--;
    if (album == null) {
      throw StateError('Missing fake album for id: $id');
    }
    return album;
  }

  @override
  Future<Playlist> getPlaylist(String id, {int? maxResponseBytes}) async {
    calls.add('getPlaylist:$id');
    final playlist = playlistDetails[id];
    if (playlist == null) {
      throw StateError('Missing fake playlist for id: $id');
    }
    return playlist;
  }

  @override
  Future<StarredContent> getStarredContent() async {
    calls.add('getStarredContent');
    final error = throwOnStarred;
    if (error != null) {
      throw error;
    }
    return starredContent;
  }

  @override
  Future<List<Album>> getAlbumListPage({
    required int size,
    required int offset,
  }) async {
    calls.add('getAlbumListPage:$offset:$size');
    final pageError = fastPathErrors[offset];
    if (pageError != null) {
      throw pageError;
    }
    final error = throwOnFastPath;
    if (error != null) {
      throw error;
    }
    return fastPathPages[offset] ?? const <Album>[];
  }

  @override
  Future<List<Album>> getNewestAlbumListPage({
    required int size,
    required int offset,
  }) {
    return getAlbumListPage(size: size, offset: offset);
  }

  @override
  Future<Artist> getArtist(String id, {int? maxResponseBytes}) async {
    calls.add('getArtist:$id');
    if (notFoundArtistIds.contains(id)) {
      throw const SubsonicNotFoundException(message: 'Artist not found');
    }
    final artistError = artistErrors[id];
    if (artistError != null) {
      throw artistError;
    }
    final artist = artistDetails[id];
    if (artist == null) {
      throw StateError('Missing fake artist for id: $id');
    }
    return artist;
  }

  @override
  Future<List<Artist>> getArtists() async {
    calls.add('getArtists');
    final error = getArtistsError;
    if (error != null) {
      throw error;
    }
    final completer = artistsCompleter;
    if (completer != null) {
      return completer.future;
    }
    return artists;
  }

  @override
  Future<List<Genre>> getGenres() async {
    calls.add('getGenres');
    final error = throwOnGenres;
    if (error != null) {
      throw error;
    }
    return genres;
  }

  @override
  Future<Indexes> getIndexes({
    DateTime? ifModifiedSince,
    bool disableRetry = false,
  }) async {
    calls.add('getIndexes');
    requestedIndexesCursors.add(ifModifiedSince);
    final error = throwOnIndexes;
    if (error != null) {
      throw error;
    }
    return indexes.lastModified == null
        ? indexes.copyWith(lastModified: defaultIndexesCursor)
        : indexes;
  }

  @override
  Future<List<Playlist>> getPlaylists() async {
    calls.add('getPlaylists');
    final error = throwOnPlaylists;
    if (error != null) {
      throw error;
    }
    return playlists;
  }

  @override
  Future<SearchResult3> searchSongsPage({
    required String query,
    required int size,
    required int offset,
  }) async {
    calls.add('searchSongsPage:$query:$offset:$size');
    final error = throwOnSongSearch;
    if (error != null) {
      throw error;
    }
    return SearchResult3(songs: bulkSongPages[offset] ?? const <Song>[]);
  }
}

String _testIndexesFingerprint(Iterable<String> artistIds) {
  final normalized = artistIds.toList(growable: false)..sort();
  return sha1.convert(utf8.encode(normalized.join('\n'))).toString();
}

// Audit characterization: assertions describe observed defects, not desired contracts.
class _AuditApi extends _FakeLibrarySyncApi {
  Object? newestError;
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
            'libraryIndexesCursor': _FakeLibrarySyncApi.defaultIndexesCursor
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
    db = NavisDatabase(NativeDatabase.memory());
    repo = ServerConfigRepository(db, credentials: _FakeCredentialStore());
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
  test(
    'F01 nonempty partial detail removes existing track without ledger',
    () async {
      final id = await session();
      await seed();
      api.albumDetails['a'] = album.copyWith(songs: [song1]);
      final result = await engine.hydrateAlbum('a');
      expect(result.status, LibrarySyncStatus.succeeded);
      expect(await db.libraryDao.getSongById('s2'), isNull);
      final ledger = await db
          .customSelect(
            'SELECT count(*) AS n FROM library_sync_operation_ledger WHERE server_id = ?',
            variables: [Variable.withInt(id)],
          )
          .getSingle();
      expect(ledger.read<int>('n'), 0);
    },
  );
  test(
    'F02 fresh audit plus unchanged cursor performs no newest discovery',
    () async {
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
      api.newestPages[0] = [
        const Album(id: 'new', name: 'New', artistId: 'ar', songCount: 1),
      ];
      final result = await coordinator.requestSync(
        const LibrarySyncRequest.automatic(),
      );
      expect(result.planKind, LibrarySyncPlanKind.probe);
      expect(api.calls, ['getIndexes']);
      expect(await db.libraryDao.getAlbumById('new'), isNull);
    },
  );
  test(
    'F03 typed initial snapshot never fetches starred playlists or genres',
    () async {
      await session(initial: true);
      await seed();
      final result = await coordinator.requestSync(
        const LibrarySyncRequest.checkForUpdates(),
      );
      expect(result.status, LibrarySyncStatus.succeeded);
      expect(api.calls, isNot(contains('getStarredContent')));
      expect(api.calls, isNot(contains('getPlaylists')));
      expect(api.calls, isNot(contains('getGenres')));
    },
  );
  test(
    'F04 exhausted transient repair failure is skipped and work completed',
    () async {
      final id = await session();
      api.getArtistsError = const SubsonicConnectionException(
        'fixture offline',
      );
      final result = await coordinator.requestSync(
        const LibrarySyncRequest.repair(),
      );
      expect(result.status, LibrarySyncStatus.skipped);
      final work = await db.librarySyncDao.getWork(
        serverId: id,
        kind: 'fullRepair',
      );
      expect(work!.status, 'completed');
      expect((await db.librarySyncDao.getOrCreateState(id)).failureStreak, 0);
    },
  );
  test(
    'F05 resumed mixed external page advances by filtered row count',
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
      expect((await engine.forceFullSync()).status, LibrarySyncStatus.failed);
      expect(api.calls, contains('getAlbumListPage:1:500'));
    },
  );
  test('F06 bounded newest refresh erases full rank tail', () async {
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
      isNull,
    );
  });
  test(
    'F07 engine ignores typed endpoint allowlist on changed manual discovery',
    () async {
      await session();
      await seed();
      api.newestPages[0] = [album.copyWith(name: 'Changed')];
      api.artistDetails['ar'] = const Artist(
        id: 'ar',
        name: 'Artist',
        albumCount: 1,
        albums: [
          Album(
            id: 'a',
            name: 'Changed',
            artistId: 'ar',
            artist: 'Artist',
            songCount: 2,
          ),
        ],
      );
      final result = await engine.executeSyncExecutionPlan(
        const SyncExecutionPlan(
          request: SyncRunRequest(
            contractVersion: 1,
            origin: SyncRunOrigin.libraryPullToRefresh,
            intent: SyncRunIntent.manualCatalogCheck,
            target: LibrarySyncTarget.catalog(),
            networkGrant: SyncNetworkGrant.none,
            priority: 60,
          ),
          kind: SyncExecutionPlanKind.manualCatalogDiscovery,
          reason: SyncSafeReason.none,
          budget: SyncExecutionBudget(
            allowedEndpoints: {
              SyncEndpoint.indexes,
              SyncEndpoint.newestAlbums,
              SyncEndpoint.artist,
              SyncEndpoint.album,
            },
            maxNewestPages: 1,
            maxAlbumHydrations: 1,
            maxResponseBytes: null,
            maxTotalBytes: null,
            maxConcurrency: 1,
          ),
        ),
      );
      expect(result.status, LibrarySyncStatus.succeeded);
      expect(api.calls, contains('getPlaylists'));
      expect(api.calls, contains('getGenres'));
    },
  );
  test(
    'F08 later playlist change cannot reactivate completed hydration',
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
      expect(work.status, 'completed');
      expect(
        await db.librarySyncDao.getRunnableWork(
          serverId: id,
          now: DateTime.now(),
        ),
        isEmpty,
      );
    },
  );
  test(
    'F09 second coordinator recovers still-running work before lease check',
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
        'queued',
      );
    },
  );
  test(
    'F10 incremental external album is canonicalized by ordinary DAO',
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
      expect((await db.libraryDao.getAlbumById('remote'))!.isExternal, false);
      expect(
        (await db.libraryDao.getSongById('remote-song'))!.isExternal,
        false,
      );
    },
  );
  test('F11 new index evidence cannot reopen completed delta work', () async {
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
    final result = await coordinator.requestSync(
      const LibrarySyncRequest.automatic(),
    );
    expect(result.probeIndexChanged, true);
    expect(
      (await db.librarySyncDao.getWork(
        serverId: id,
        kind: 'deltaReconcile',
      ))!.status,
      'completed',
    );
    expect(
      await db.librarySyncDao.getRunnableWork(
        serverId: id,
        now: DateTime.now(),
      ),
      isEmpty,
    );
  });
  test('F12 newest discovery treats server capped short page as EOF', () async {
    await session();
    await seed();
    api.newestPages[0] = [album];
    api.newestPages[1] = [const Album(id: 'new', name: 'New', songCount: 0)];
    final result = await engine.syncNow();
    expect(result.status, LibrarySyncStatus.succeeded);
    expect(api.calls.where((c) => c.startsWith('newest:')).toList(), [
      'newest:0:100',
    ]);
    expect(await db.libraryDao.getAlbumById('new'), isNull);
  });
  test('F13 background executor cannot resume automatic delta work', () async {
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
    expect(result.status, LibrarySyncStatus.deferred);
    expect(api.calls, isEmpty);
  });
  test(
    'F14 changed song title stays stale through compatibility audit',
    () async {
      final id = await session();
      await seed();
      api.albumDetails['a'] = album.copyWith(
        songs: [
          song1.copyWith(title: 'Corrected'),
          song2,
        ],
      );
      await db.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(id),
          currentGeneration: const Value(1),
          conditionalIndexesMode: const Value('reliable'),
        ),
      );
      final result = await engine.runCompatibilityAudit();
      expect(result.status, LibrarySyncStatus.succeeded);
      expect(api.calls, contains('getArtist:ar'));
      expect(api.calls, isNot(contains('getAlbum:a')));
      expect((await db.libraryDao.getSongById('s1'))!.title, 'One');
    },
  );

  test('F15 standard genre value payload parses as empty success', () async {
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
              'subsonic-response': {
                'status': 'ok',
                'genres': {
                  'genre': [
                    {'value': 'Rock', 'songCount': 2, 'albumCount': 1},
                  ],
                },
              },
            },
          ),
        ),
      ),
    );
    expect(await client.getGenres(), isEmpty);
    client.close();
  });
  test('F16 star wire parameters ignore entity type', () async {
    final dio = Dio();
    late RequestOptions captured;
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
        onRequest: (o, h) {
          captured = o;
          h.resolve(
            Response(
              requestOptions: o,
              statusCode: 200,
              data: {
                'subsonic-response': {'status': 'ok'},
              },
            ),
          );
        },
      ),
    );
    await client.star('album-fixture');
    expect(captured.queryParameters['id'], 'album-fixture');
    expect(captured.queryParameters.containsKey('albumId'), false);
    client.close();
  });
  test(
    'F17 missing playlist response container deletes cached playlists',
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
        LibrarySyncStatus.succeeded,
      );
      expect(await db.playlistDao.getAllPlaylists(), isEmpty);
      client.close();
    },
  );
  test('F18 successful local like during hydration is overwritten by older response', () async {
    await session();
    await seed();
    api.albumCompleter = Completer<Album>();
    final run = engine.hydrateAlbum('a');
    while (api.currentAlbumRequests == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    await db.libraryDao.updateSongStarred('s1', DateTime.now());
    expect(await db.libraryDao.getSongStarred('s1'), isNotNull);
    api.albumCompleter!.complete(album.copyWith(songs: [song1, song2]));
    expect((await run).status, LibrarySyncStatus.succeeded);
    expect(await db.libraryDao.getSongStarred('s1'), isNull);
  });
  test('F24 starred snapshot drops an unseen remote song', () async {
    await session();
    api.starredContent = StarredContent(
      songs: [
        Song(
          id: 'remote-unseen',
          title: 'Remote',
          isExternal: true,
          starred: DateTime.utc(2026, 1, 1),
        ),
      ],
    );
    expect(
      (await engine.syncStarredContent()).status,
      LibrarySyncStatus.succeeded,
    );
    expect(await db.libraryDao.getSongById('remote-unseen'), isNull);
    expect(await db.libraryDao.getStarredSongIds(), isEmpty);
  });
}
```
