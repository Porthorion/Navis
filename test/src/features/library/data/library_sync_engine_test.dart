import '../../../../helpers/library_sync_fakes.dart';
import '../../../../helpers/library_sync_plan.dart';

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/api/sync_request_scope.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/data/adaptive_library_sync_coordinator.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/domain/sync_run_contract.dart';
import 'package:navis/src/utils/connectivity.dart';

import '../../../../helpers/test_database.dart';

final _meteredManualDiscoveryPlan = syncPlanForTest(
  SyncExecutionPlanKind.manualCatalogDiscovery,
  grant: SyncNetworkGrant.boundedMeteredDiscovery,
  networkType: NetworkType.cellular,
);

String _testIndexesFingerprint(Iterable<String> artistIds) {
  final normalized = artistIds.toList(growable: false)..sort();
  return sha1.convert(utf8.encode(normalized.join('\n'))).toString();
}

class _BatchTrackingLibrarySyncApi extends FakeLibrarySyncApi {
  final batchSizes = <int>[];
  int _active = 0;
  bool retryFirstAlbum = false;

  @override
  Future<Album> getAlbum(String id, {int? maxResponseBytes}) async {
    if (_active == 0) batchSizes.add(0);
    batchSizes[batchSizes.length - 1]++;
    _active++;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (retryFirstAlbum && id == 'album-0') {
        final scope = SyncRequestScope.current!;
        final first = scope.beginTransport('getAlbum');
        first.finish(succeeded: false);
        scope
            .beginTransport('getAlbum', retryOf: first)
            .finish(succeeded: true);
      }
      return await super.getAlbum(id, maxResponseBytes: maxResponseBytes);
    } finally {
      _active--;
    }
  }
}

class _BulkPageLibrarySyncApi extends FakeLibrarySyncApi {
  Future<void> Function()? onBulkPage;

  @override
  Future<SearchResult3> searchSongsPage({
    required String query,
    required int size,
    required int offset,
  }) async {
    if (size > 1) await onBulkPage?.call();
    return await super.searchSongsPage(
      query: query,
      size: size,
      offset: offset,
    );
  }
}

class _FailingTargetSyncApi extends FakeLibrarySyncApi {
  new(this.error);
  final Object error;
  @override
  Future<Album> getAlbum(String id, {int? maxResponseBytes}) async =>
      Error.throwWithStackTrace(error, StackTrace.current);
  @override
  Future<Artist> getArtist(String id, {int? maxResponseBytes}) async =>
      Error.throwWithStackTrace(error, StackTrace.current);
  @override
  Future<Playlist> getPlaylist(String id, {int? maxResponseBytes}) async =>
      Error.throwWithStackTrace(error, StackTrace.current);
  @override
  Future<StarredContent> getStarredContent() async =>
      Error.throwWithStackTrace(error, StackTrace.current);
  @override
  Future<List<Playlist>> getPlaylists() async =>
      Error.throwWithStackTrace(error, StackTrace.current);
  @override
  Future<Indexes> getIndexes({
    DateTime? ifModifiedSince,
    bool disableRetry = false,
  }) async => Error.throwWithStackTrace(error, StackTrace.current);
}

void main() {
  group('DriftLibrarySyncEngine', () {
    late NavisDatabase database;
    late ServerConfigRepository serverConfigRepository;
    late FakeSyncCredentialStore credentials;
    late FakeLibrarySyncApi api;
    late DriftLibrarySyncEngine engine;

    Future<void> saveSession({
      DateTime? lastSynced,
      DateTime? lastFullSyncedAt,
      String? capabilitiesJson,
    }) {
      return serverConfigRepository.save(
        ServerConfigModel(
          url: 'https://example.com',
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
          capabilitiesJson: capabilitiesJson,
          lastSynced: lastSynced,
          lastFullSyncedAt: lastFullSyncedAt,
        ),
      );
    }

    setUp(() {
      database = NavisDatabase(NativeDatabase.memory());
      credentials = FakeSyncCredentialStore();
      serverConfigRepository = ServerConfigRepository(
        database,
        credentials: credentials,
      );
      api = FakeLibrarySyncApi();
      engine = DriftLibrarySyncEngine(
        api: api,
        database: database,
        serverConfigRepository: serverConfigRepository,
        fallbackArtistConcurrency: 1,
        wifiAlbumConcurrency: 1,
        cellularAlbumConcurrency: 1,
        otherAlbumConcurrency: 1,
        writeChunkSize: 4,
      );
    });

    tearDown(() async {
      await database.close();
    });

    for (final (name, playing, manual, expected) in [
      ('paused automatic', false, false, LibrarySyncStatus.succeeded),
      ('playing automatic', true, false, LibrarySyncStatus.deferred),
      ('playing manual', true, true, LibrarySyncStatus.succeeded),
    ]) {
      test('engine uses admitted playback policy: $name', () async {
        await saveSession(lastSynced: DateTime.utc(2026, 8, 1));
        final playbackEngine = DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          networkType: NetworkType.wifi,
          readActiveSongId: () => 'current-song',
        );
        final coordinator = AdaptiveLibrarySyncCoordinator(
          executor: playbackEngine,
          database: database,
          serverConfigRepository: serverConfigRepository,
          networkType: NetworkType.wifi,
          staleAfter: const Duration(hours: 1),
          readHasActivePlayback: () => playing,
          now: () => DateTime.utc(2026, 8, 4),
        );

        final result = manual
            ? await coordinator.syncNow()
            : await coordinator.syncIfStale();

        expect(result.status, expected);
        expect(api.calls, playing && !manual ? isEmpty : isNotEmpty);
      }, skip: !sqliteAvailable);
    }

    for (final utc in [false, true]) {
      test('hydration maps every album and song field (UTC: $utc)', () async {
        await saveSession();
        final created = utc
            ? DateTime.utc(2025, 2, 3, 4, 5, 6)
            : DateTime(2025, 2, 3, 4, 5, 6);
        final starred = created.add(const Duration(days: 1));
        final song = Song(
          id: 'ext-song',
          title: 'Track',
          albumId: 'ext-album',
          album: 'Release',
          artistId: 'artist-1',
          artist: 'Artist',
          track: 7,
          discNumber: 2,
          year: 2025,
          duration: 321,
          bitRate: 320,
          sampleRate: 96000,
          contentType: 'audio/flac',
          suffix: 'flac',
          size: 123456,
          coverArt: 'song-cover',
          starred: starred,
          musicBrainzId: 'recording',
          userRating: 4,
          playCount: 12,
          created: created,
          isExternal: false,
          replayGain: const ReplayGain(
            trackGain: -4.5,
            albumGain: -3,
            trackPeak: 0.92,
            albumPeak: 0.95,
          ),
        );
        final album = Album(
          id: 'ext-album',
          name: 'Release',
          artistId: 'artist-1',
          artist: 'Artist',
          artists: const [
            ArtistRef(id: 'artist-1', name: 'Artist'),
            ArtistRef(id: 'artist-2', name: 'Guest'),
          ],
          songCount: 1,
          duration: 321,
          year: 2025,
          coverArt: 'album-cover',
          starred: starred,
          userRating: 5,
          playCount: 13,
          created: created,
          musicBrainzId: 'release',
          isExternal: false,
          songs: [song],
        );
        api.albumDetails[album.id] = album;
        final result = await engine.hydrateAlbum(album.id);
        expect(result.status, LibrarySyncStatus.succeeded);
        final storedAlbum = (await database.libraryDao.getAlbumById(album.id))!;
        final storedSong = (await database.libraryDao.getSongById(song.id))!;
        expect(
          [
            storedAlbum.id,
            storedAlbum.name,
            storedAlbum.artistId,
            storedAlbum.artistName,
            storedAlbum.artists,
            storedAlbum.songCount,
            storedAlbum.duration,
            storedAlbum.year,
            storedAlbum.coverArt,
            storedAlbum.starred,
            storedAlbum.userRating,
            storedAlbum.playCount,
            storedAlbum.serverCreatedAt,
            storedAlbum.releaseMbid,
            storedAlbum.isExternal,
            storedAlbum.songsHydrated,
          ],
          [
            album.id,
            album.name,
            album.artistId,
            album.artist,
            album.artists,
            album.songCount,
            album.duration,
            album.year,
            album.coverArt,
            starred.toLocal(),
            album.userRating,
            album.playCount,
            created.toLocal(),
            album.musicBrainzId,
            false,
            true,
          ],
        );
        expect(
          [
            storedSong.id,
            storedSong.title,
            storedSong.albumId,
            storedSong.artistId,
            storedSong.artistName,
            storedSong.albumName,
            storedSong.track,
            storedSong.discNumber,
            storedSong.duration,
            storedSong.bitRate,
            storedSong.sampleRate,
            storedSong.contentType,
            storedSong.suffix,
            storedSong.size,
            storedSong.coverArt,
            storedSong.starred,
            storedSong.recordingMbid,
            storedSong.userRating,
            storedSong.playCount,
            storedSong.createdAt,
            storedSong.isExternal,
            storedSong.replayGainTrackGain,
            storedSong.replayGainAlbumGain,
            storedSong.replayGainTrackPeak,
            storedSong.replayGainAlbumPeak,
          ],
          [
            song.id,
            song.title,
            song.albumId,
            song.artistId,
            song.artist,
            song.album,
            song.track,
            song.discNumber,
            song.duration,
            song.bitRate,
            song.sampleRate,
            song.contentType,
            song.suffix,
            song.size,
            song.coverArt,
            starred.toLocal(),
            song.musicBrainzId,
            song.userRating,
            song.playCount,
            created.toLocal(),
            false,
            -4.5,
            -3.0,
            0.92,
            0.95,
          ],
        );
      }, skip: !sqliteAvailable);
    }

    for (final invalid in <String, Album>{
      'partial count': const Album(
        id: 'a',
        name: 'A',
        songCount: 2,
        songs: [Song(id: 's1', title: 'One', albumId: 'a')],
      ),
      'duplicate identity': const Album(
        id: 'a',
        name: 'A',
        songCount: 2,
        songs: [
          Song(id: 's1', title: 'One'),
          Song(id: 's1', title: 'One'),
        ],
      ),
      'wrong parent': const Album(
        id: 'a',
        name: 'A',
        songCount: 1,
        songs: [Song(id: 's1', title: 'One', albumId: 'other')],
      ),
      'wrong album': const Album(
        id: 'other',
        name: 'A',
        songCount: 1,
        songs: [Song(id: 's1', title: 'One')],
      ),
    }.entries) {
      test('target preserves committed tracks on ${invalid.key}', () async {
        await saveSession();
        await database.libraryDao.upsertAlbums([
          AlbumsTableCompanion.insert(
            id: 'a',
            name: 'A',
            songCount: const Value(2),
          ),
        ]);
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(
            id: 's1',
            title: 'One',
            albumId: const Value('a'),
          ),
          SongsTableCompanion.insert(
            id: 's2',
            title: 'Two',
            albumId: const Value('a'),
          ),
        ]);
        api.albumDetails['a'] = invalid.value;
        final result = await engine.hydrateAlbum('a');
        expect(result.status, LibrarySyncStatus.partial);
        expect(result.pendingHydrationCount, 1);
        expect(await database.libraryDao.getSongById('s2'), isNotNull);
        expect((await database.libraryDao.getAlbumById('a'))!.songCount, 2);
      });
    }

    test(
      'target retains a successful local like newer than its response',
      () async {
        await saveSession();
        await database.libraryDao.upsertAlbums([
          AlbumsTableCompanion.insert(id: 'a', name: 'A'),
        ]);
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(
            id: 's1',
            title: 'One',
            albumId: const Value('a'),
          ),
        ]);
        api.albumCompleter = Completer<Album>();
        final run = engine.hydrateAlbum('a');
        while (api.currentAlbumRequests == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        await database.libraryDao.setEntityStarred(
          'song',
          's1',
          DateTime.now(),
        );
        api.albumCompleter!.complete(
          const Album(
            id: 'a',
            name: 'A',
            songCount: 1,
            songs: [Song(id: 's1', title: 'One', albumId: 'a')],
          ),
        );
        expect((await run).status, LibrarySyncStatus.succeeded);
        expect(await database.libraryDao.getSongStarred('s1'), isNotNull);
      },
    );

    test(
      'starred snapshot materializes unseen external references only',
      () async {
        await saveSession(lastSynced: DateTime.now());
        final starredAt = DateTime.utc(2026);
        api.starredContent = StarredContent(
          artists: [
            Artist(
              id: 'remote-artist',
              name: 'Remote',
              isExternal: true,
              starred: starredAt,
            ),
          ],
          albums: [
            Album(
              id: 'remote-album',
              name: 'Remote',
              artistId: 'remote-artist',
              isExternal: true,
              starred: starredAt,
            ),
          ],
          songs: [
            Song(
              id: 'remote-song',
              title: 'Remote',
              artistId: 'remote-artist',
              albumId: 'remote-album',
              isExternal: true,
              starred: starredAt,
            ),
          ],
        );
        expect(
          (await engine.syncStarredContent()).status,
          LibrarySyncStatus.succeeded,
        );
        expect(
          await database.libraryDao.getStarredIds('song'),
          contains('remote-song'),
        );
        expect(
          await database.libraryDao.getStarredIds('album'),
          contains('remote-album'),
        );
        expect(
          await database.libraryDao.getStarredIds('artist'),
          contains('remote-artist'),
        );
        expect(
          (await database.libraryDao.getSongById('remote-song'))!.isExternal,
          isTrue,
        );
        expect(
          (await database.libraryDao.getSongById('remote-song'))!.isProvisional,
          isTrue,
        );
        expect(await database.libraryDao.watchAllAlbums().first, isEmpty);
        expect(await database.libraryDao.watchAllSongs().first, isEmpty);
      },
    );

    test('partial starred snapshot preserves richer known metadata', () async {
      await saveSession(lastSynced: DateTime.now());
      await database.libraryDao.upsertProvisionalSongs([
        SongsTableCompanion.insert(
          id: 'song-known',
          title: 'Rich Title',
          albumName: const Value('Rich Album'),
        ),
      ]);
      await (database.update(database.songsTable)
            ..where((t) => t.id.equals('song-known')))
          .write(const SongsTableCompanion(duration: Value(200)));
      final starredAt = DateTime.utc(2026);
      // The starred response supplies only an ID and the favorite stamp.
      api.starredContent = StarredContent(
        songs: <Song>[
          Song(id: 'song-known', title: 'song-known', starred: starredAt),
        ],
      );

      final result = await engine.syncStarredContent();

      expect(result.status, LibrarySyncStatus.succeeded);
      final song = await database.libraryDao.getSongById('song-known');
      expect(song!.starred, isNotNull);
      // The favorite is recorded but the richer known fields survive.
      expect(song.title, 'Rich Title');
      expect(song.albumName, 'Rich Album');
      expect(song.duration, 200);
    }, skip: !sqliteAvailable);

    test('incomplete favorites schedule targeted album hydration', () async {
      await saveSession(lastSynced: DateTime.now());
      final starredAt = DateTime.utc(2026);
      api.starredContent = StarredContent(
        songs: <Song>[
          Song(
            id: 'song-inc',
            title: 'Incomplete',
            albumId: 'album-inc',
            album: 'Inc Album',
            starred: starredAt,
          ),
        ],
      );
      api.albumDetails['album-inc'] = const Album(
        id: 'album-inc',
        name: 'Inc Album',
        songs: <Song>[
          Song(
            id: 'song-inc',
            title: 'Incomplete',
            albumId: 'album-inc',
            duration: 180,
          ),
        ],
      );

      final result = await engine.syncStarredContent();

      expect(result.status, LibrarySyncStatus.succeeded);
      // The album of an incomplete favorite was hydrated so the favorite
      // gains catalog-authoritative metadata.
      expect(api.calls, contains('getAlbum:album-inc'));
      final song = await database.libraryDao.getSongById('song-inc');
      expect(song, isNotNull);
      expect(song!.duration, 180);
    }, skip: !sqliteAvailable);

    test(
      'full sync writes metadata and songs using album-list fast path',
      () async {
        await saveSession();
        api.artists.addAll(const <Artist>[
          Artist(id: 'artist-1', name: 'Artist 1'),
          Artist(id: 'artist-2', name: 'Artist 2'),
        ]);
        api.fastPathPages[0] = const <Album>[
          Album(
            id: 'album-1',
            name: 'Album 1',
            artist: 'Artist 1',
            artistId: 'artist-1',
          ),
          Album(
            id: 'album-2',
            name: 'Album 2',
            artist: 'Artist 2',
            artistId: 'artist-2',
          ),
        ];
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          songs: <Song>[
            Song(
              id: 'song-1',
              title: 'Song 1',
              albumId: 'album-1',
              artistId: 'artist-1',
            ),
          ],
        );
        api.albumDetails['album-2'] = const Album(
          id: 'album-2',
          name: 'Album 2',
          songs: <Song>[
            Song(
              id: 'song-2',
              title: 'Song 2',
              albumId: 'album-2',
              artistId: 'artist-2',
            ),
          ],
        );
        api.playlists = const <Playlist>[
          Playlist(id: 'playlist-1', name: 'Favorites', songCount: 2),
        ];

        final state = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );

        await engine.executeSyncPlan(
          syncPlanForTest(
            SyncExecutionPlanKind.auxiliaryRefresh,
            target: const LibrarySyncTarget.playlistHeaders(),
          ),
        );

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(state.mode, LibrarySyncMode.forceFull);
        expect(api.calls, contains('getAlbumListPage:0:500'));
        expect(
          api.calls.where((call) => call.startsWith('getArtist:')),
          isEmpty,
        );

        final artistRows = await database.select(database.artistsTable).get();
        final albumRows = await database.select(database.albumsTable).get();
        final songRows = await database.select(database.songsTable).get();
        final playlistRows = await database
            .select(database.playlistsTable)
            .get();
        final serverConfig = await serverConfigRepository.getActiveServer();

        expect(artistRows.length, 2);
        expect(albumRows.length, 2);
        expect(songRows.length, 2);
        expect(playlistRows.length, 1);
        expect(api.calls, isNot(contains('getGenres')));
        expect(serverConfig?.lastSynced, isNotNull);
        expect(serverConfig?.lastFullSyncedAt, isNotNull);
        final ledger = await database.librarySyncDao
            .getRecentOperationLedgerEntries(serverConfig!.id!);
        expect(ledger, hasLength(1));
        expect(ledger.single.operation, 'catalogPromotion');
        expect(ledger.single.reason, 'validatedFullCandidate');
        expect(jsonDecode(ledger.single.detailsJson), <String, Object?>{
          'generation': 1,
          'before': <String, Object?>{'artists': 0, 'albums': 0, 'songs': 0},
          'after': <String, Object?>{'artists': 2, 'albums': 2, 'songs': 2},
          'changed': 6,
          'unchanged': 0,
          'removed': <String, Object?>{'artists': 0, 'albums': 0, 'songs': 0},
          'retained': <String, Object?>{'artists': 0, 'albums': 0, 'songs': 0},
          'retainedUnavailable': 0,
          'aliases': 0,
          'albumAliases': 0,
          'artistAliases': 0,
          'reviewEntries': 0,
        });
      },
      skip: !sqliteAvailable,
    );

    test(
      'full sync falls back to getIndexes when getArtists is unavailable',
      () async {
        await saveSession();
        api.getArtistsError = const SubsonicNotFoundException(
          message: 'getArtists is unavailable',
        );
        api.indexes = const Indexes(
          indexes: <IndexesIndex>[
            IndexesIndex(
              artists: <Artist>[Artist(id: 'artist-1', name: 'Artist 1')],
            ),
          ],
        );
        api.fastPathPages[0] = const <Album>[
          Album(
            id: 'album-1',
            name: 'Album 1',
            artist: 'Artist 1',
            artistId: 'artist-1',
          ),
        ];
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          songs: <Song>[
            Song(
              id: 'song-1',
              title: 'Song 1',
              albumId: 'album-1',
              artistId: 'artist-1',
            ),
          ],
        );

        final state = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(api.calls, containsAll(<String>['getArtists', 'getIndexes']));
        expect(
          (await database.libraryDao.getArtistById('artist-1'))?.name,
          'Artist 1',
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'full promotion preserves created when changed album details omit it',
      () async {
        await saveSession();
        final created = DateTime.utc(2026, 8, 10);
        await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist'),
        ]);
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'album-1',
            name: 'Album',
            artistId: const Value('artist-1'),
            songCount: const Value(1),
            coverArt: const Value('old-cover'),
            songsHydrated: const Value(true),
            serverCreatedAt: Value(created),
          ),
        ]);
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Song',
            albumId: const Value('album-1'),
            artistId: const Value('artist-1'),
          ),
        ]);
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist'));
        // Both the album-list and detail payload intentionally omit `created`.
        // The cover-art change forces the candidate through promotion.
        api.fastPathPages[0] = const <Album>[
          Album(
            id: 'album-1',
            name: 'Album',
            artistId: 'artist-1',
            artist: 'Artist',
            songCount: 1,
            coverArt: 'new-cover',
          ),
        ];
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album',
          artistId: 'artist-1',
          artist: 'Artist',
          songCount: 1,
          coverArt: 'new-cover',
          songs: <Song>[
            Song(
              id: 'song-1',
              title: 'Song',
              albumId: 'album-1',
              artistId: 'artist-1',
            ),
          ],
        );

        final state = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );

        expect(state.status, LibrarySyncStatus.succeeded);
        final album = await database.libraryDao.getAlbumById('album-1');
        expect(album?.coverArt, 'new-cover');
        expect(album?.serverCreatedAt?.toUtc(), created);
      },
      skip: !sqliteAvailable,
    );

    test(
      'full sync derives artists from album pages when artist endpoints fail',
      () async {
        await saveSession();
        api.getArtistsError = const SubsonicNotFoundException(
          message: 'getArtists is unavailable',
        );
        api.throwOnIndexes = const SubsonicNotFoundException(
          message: 'getIndexes is unavailable',
        );
        api.fastPathPages[0] = const <Album>[
          Album(
            id: 'album-1',
            name: 'Album 1',
            artist: 'Artist 1',
            artistId: 'artist-1',
          ),
        ];
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          songs: <Song>[
            Song(
              id: 'song-1',
              title: 'Song 1',
              albumId: 'album-1',
              artistId: 'artist-1',
            ),
          ],
        );

        final state = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(
          (await database.libraryDao.getArtistById('artist-1'))?.name,
          'Artist 1',
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'full sync keeps the committed catalog visible until one promotion',
      () async {
        await saveSession();
        await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(id: 'artist-1', name: 'Old Artist'),
        ]);
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'album-1',
            name: 'Old Album',
            artistId: const Value('artist-1'),
            songsHydrated: const Value(true),
          ),
        ]);
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Old Song',
            albumId: const Value('album-1'),
            artistId: const Value('artist-1'),
          ),
        ]);
        api.artists.add(const Artist(id: 'artist-1', name: 'New Artist'));
        api.fastPathPages[0] = const <Album>[
          Album(
            id: 'album-1',
            name: 'New Album',
            artistId: 'artist-1',
            songCount: 1,
          ),
        ];
        api.albumCompleter = Completer<Album>();
        api.throwOnStarred = const SubsonicNotFoundException(
          message: 'unsupported',
        );

        final emissions = <List<String>>[];
        final firstEmission = Completer<void>();
        final subscription = database.libraryDao.watchAllAlbums().listen((
          albums,
        ) {
          emissions.add(albums.map((album) => album.name).toList());
          if (!firstEmission.isCompleted) {
            firstEmission.complete();
          }
        });
        addTearDown(subscription.cancel);
        await firstEmission.future;

        final sync = engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );
        while (!api.calls.contains('getAlbum:album-1')) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(
          (await database.libraryDao.getAlbumById('album-1'))?.name,
          'Old Album',
        );
        expect(emissions, <List<String>>[
          <String>['Old Album'],
        ]);
        expect(
          (await database.librarySyncCandidateDao.getAlbums(
            serverId: 1,
            generation: 1,
          )).single.name,
          'New Album',
        );
        await database.libraryDao.setEntityStarred(
          'song',
          'song-1',
          DateTime.utc(2026, 8, 4, 12),
        );

        api.albumCompleter!.complete(
          const Album(
            id: 'album-1',
            name: 'New Album',
            artistId: 'artist-1',
            songCount: 1,
            songs: <Song>[
              Song(
                id: 'song-1',
                title: 'Song 1',
                albumId: 'album-1',
                artistId: 'artist-1',
              ),
            ],
          ),
        );
        final result = await sync;
        await Future<void>.delayed(Duration.zero);

        expect(result.status, LibrarySyncStatus.succeeded);
        expect(
          (await database.libraryDao.getAlbumById('album-1'))?.name,
          'New Album',
        );
        expect(
          (await database.libraryDao.getSongById('song-1'))?.starred,
          isNotNull,
        );
        expect(emissions.last, <String>['New Album']);
        expect(emissions, hasLength(2));
      },
      skip: !sqliteAvailable,
    );

    test('full catalog candidates exclude injected external entries', () async {
      await saveSession();
      api.artists.addAll(const <Artist>[
        Artist(id: 'artist-1', name: 'Server Artist', albumCount: 1),
        Artist(
          id: 'ext-deezer-artist-1',
          name: 'Remote Artist',
          albumCount: 1,
          isExternal: true,
        ),
      ]);
      api.fastPathPages[0] = const <Album>[
        Album(id: 'album-1', name: 'Server Album', artistId: 'artist-1'),
        Album(
          id: 'provider-album-1',
          name: 'Remote Album',
          artistId: 'ext-deezer-artist-1',
          isExternal: true,
        ),
      ];
      api.albumDetails['album-1'] = const Album(
        id: 'album-1',
        name: 'Server Album',
        artistId: 'artist-1',
        songs: <Song>[
          Song(id: 'song-1', title: 'Server Song', albumId: 'album-1'),
          Song(
            id: 'provider-song-1',
            title: 'Injected Song',
            albumId: 'album-1',
            isExternal: true,
          ),
        ],
      );

      final state = await engine.executeSyncPlan(
        syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
      );

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(await database.libraryDao.getArtistById('artist-1'), isNotNull);
      expect(await database.libraryDao.getAlbumById('album-1'), isNotNull);
      expect(await database.libraryDao.getSongById('song-1'), isNotNull);
      expect(
        await database.libraryDao.getArtistById('ext-deezer-artist-1'),
        isNull,
      );
      expect(
        await database.libraryDao.getAlbumById('provider-album-1'),
        isNull,
      );
      expect(await database.libraryDao.getSongById('provider-song-1'), isNull);
    }, skip: !sqliteAvailable);

    test('targeted liked sync confirms server absence twice without overwriting pending local actions', () async {
      await saveSession(lastSynced: DateTime.now());
      final localStarredAt = DateTime(2026, 2, 1);
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(id: 'server-liked', title: 'Server liked'),
        SongsTableCompanion.insert(
          id: 'pending-local',
          title: 'Pending local',
          starred: Value(localStarredAt),
        ),
        SongsTableCompanion.insert(
          id: 'server-unliked',
          title: 'Server unliked',
          starred: Value(DateTime(2026, 1, 1)),
        ),
      ]);
      await database.starSyncDao.queueStarAction(
        itemId: 'pending-local',
        itemType: 'song',
        action: 'star',
      );
      final remoteStarredAt = DateTime(2026, 3, 1);
      api.starredContent = StarredContent(
        songs: <Song>[
          Song(
            id: 'server-liked',
            title: 'Server liked',
            starred: remoteStarredAt,
          ),
        ],
      );

      final state = await engine.syncStarredContent();

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(state.starredSynchronized, isTrue);
      expect(
        await database.libraryDao.getSongStarred('server-liked'),
        remoteStarredAt,
      );
      expect(
        await database.libraryDao.getSongStarred('pending-local'),
        localStarredAt,
      );
      expect(
        await database.libraryDao.getSongStarred('server-unliked'),
        DateTime(2026, 1, 1),
      );

      await engine.syncStarredContent();

      expect(
        await database.libraryDao.getSongStarred('server-unliked'),
        isNull,
      );
      final serverId = (await serverConfigRepository.getActiveServer())!.id!;
      final ledger = await database.librarySyncDao
          .getRecentOperationLedgerEntries(serverId);
      expect(ledger, hasLength(1));
      expect(ledger.single.operation, 'starredReconciliation');
      expect(ledger.single.reason, 'confirmedSecondAbsence');
      expect(jsonDecode(ledger.single.detailsJson), <String, Object?>{
        'before': <String, Object?>{'artists': 0, 'albums': 0, 'songs': 3},
        'after': <String, Object?>{'artists': 0, 'albums': 0, 'songs': 2},
        'removed': <String, Object?>{'artists': 0, 'albums': 0, 'songs': 1},
      });
    }, skip: !sqliteAvailable);

    test('playlist headers preserve membership and queue unversioned or changed content', () async {
      await saveSession(lastSynced: DateTime.now());
      final serverId = (await serverConfigRepository.getActiveServer())!.id!;
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(id: 'song-1', title: 'Song 1'),
      ]);
      await database.playlistDao.upsertPlaylists(<PlaylistsTableCompanion>[
        PlaylistsTableCompanion.insert(
          id: 'stable',
          name: 'Stable',
          songCount: const Value(1),
        ),
        PlaylistsTableCompanion.insert(
          id: 'changed',
          name: 'Changed',
          songCount: const Value(1),
        ),
        PlaylistsTableCompanion.insert(
          id: 'deleted',
          name: 'Deleted',
          songCount: const Value(1),
        ),
      ]);
      for (final playlistId in <String>['stable', 'changed', 'deleted']) {
        await database.playlistDao.replacePlaylistSongs(
          playlistId,
          <PlaylistSongsTableCompanion>[
            PlaylistSongsTableCompanion.insert(
              playlistId: playlistId,
              songId: 'song-1',
              sortOrder: 0,
            ),
          ],
        );
      }
      api.playlists = const <Playlist>[
        Playlist(id: 'stable', name: 'Stable', songCount: 1),
        Playlist(id: 'changed', name: 'Changed', songCount: 2),
        Playlist(id: 'new-empty', name: 'New empty', songCount: 0),
      ];

      final state = await engine.syncPlaylistHeaders();

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(state.playlistHeadersSynchronized, isTrue);
      expect(
        await database.playlistDao.watchPlaylistSongs('stable').first,
        hasLength(1),
      );
      expect(
        await database.playlistDao.watchPlaylistById('deleted').first,
        isNull,
      );
      expect(
        await database.librarySyncDao.getWork(
          serverId: serverId,
          kind: LibrarySyncPlanKind.targetedHydration.name,
          entityId: librarySyncTargetWorkKey(
            const LibrarySyncTarget.playlist('changed'),
          ),
        ),
        isNotNull,
      );
      expect(
        await database.librarySyncDao.getWork(
          serverId: serverId,
          kind: LibrarySyncPlanKind.targetedHydration.name,
          entityId: librarySyncTargetWorkKey(
            const LibrarySyncTarget.playlist('stable'),
          ),
        ),
        isNotNull,
      );
      expect(
        await database.librarySyncDao.getWork(
          serverId: serverId,
          kind: LibrarySyncPlanKind.targetedHydration.name,
          entityId: librarySyncTargetWorkKey(
            const LibrarySyncTarget.playlist('new-empty'),
          ),
        ),
        isNull,
      );
    }, skip: !sqliteAvailable);

    test('targeted album hydration uses one request and auto-merges a cached remote identity', () async {
      await saveSession(lastSynced: DateTime.now());
      await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist 1'),
      ]);
      await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(
          id: 'album-1',
          name: 'Album 1',
          artistId: const Value('artist-1'),
          songsHydrated: const Value(false),
        ),
      ]);
      await database.libraryDao.upsertProvisionalSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(
          id: 'remote-song',
          title: 'Track',
          albumId: const Value('album-1'),
          artistId: const Value('artist-1'),
          recordingMbid: const Value('recording-mbid'),
        ),
      ]);
      api.albumDetails['album-1'] = const Album(
        id: 'album-1',
        name: 'Album 1',
        artistId: 'artist-1',
        songs: <Song>[
          Song(
            id: 'server-song',
            title: 'Track',
            albumId: 'album-1',
            artistId: 'artist-1',
            musicBrainzId: 'recording-mbid',
          ),
        ],
      );

      final state = await engine.hydrateAlbum('album-1');
      final aliases = await database.songIdentityDao.getAliases();

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(state.apiRequests, 1);
      expect(state.dbWriteBatches, 1);
      expect(api.calls, <String>['getAlbum:album-1']);
      expect(aliases.single.oldSongId, 'remote-song');
      expect(aliases.single.canonicalSongId, 'server-song');
      expect(await database.libraryDao.getSongById('remote-song'), isNull);
    }, skip: !sqliteAvailable);

    test('targeted album hydration preserves Recently Added server dates when details omit them', () async {
      await saveSession(lastSynced: DateTime.now());
      final existingCreated = DateTime.utc(2026, 8, 10);
      await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist 1'),
      ]);
      await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(
          id: 'album-old',
          name: 'Old Album',
          artistId: const Value('artist-1'),
          songsHydrated: const Value(false),
          serverCreatedAt: Value(existingCreated),
        ),
        AlbumsTableCompanion.insert(
          id: 'album-new',
          name: 'New Album',
          artistId: const Value('artist-1'),
          songsHydrated: const Value(true),
          serverCreatedAt: Value(DateTime.utc(2026, 8, 11)),
        ),
      ]);
      // Some compatible servers omit the optional `created` field from
      // getAlbum even after a list response supplied it.
      api.albumDetails['album-old'] = const Album(
        id: 'album-old',
        name: 'Old Album',
        artistId: 'artist-1',
        songs: <Song>[
          Song(
            id: 'song-old',
            title: 'Old Song',
            albumId: 'album-old',
            artistId: 'artist-1',
          ),
        ],
      );

      final state = await engine.hydrateAlbum('album-old');
      final albums = await database.libraryDao
          .watchAlbumsSorted(sort: AlbumSortOrder.recentlyAdded)
          .first;

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(
        (await database.libraryDao.getAlbumById('album-old'))?.serverCreatedAt
            ?.toUtc(),
        existingCreated,
      );
      expect(albums.map((album) => album.id), <String>[
        'album-new',
        'album-old',
      ]);
    }, skip: !sqliteAvailable);

    test('incremental sync restores a missing Recently Added server date from the newest feed', () async {
      await saveSession(lastSynced: DateTime.now());
      final restoredCreated = DateTime.utc(2026, 8, 11);
      await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist 1'),
      ]);
      await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(
          id: 'album-missing-date',
          name: 'Missing Date Album',
          artistId: const Value('artist-1'),
          artistName: const Value('Artist 1'),
          songsHydrated: const Value(true),
        ),
        AlbumsTableCompanion.insert(
          id: 'album-older',
          name: 'Older Album',
          artistId: const Value('artist-1'),
          artistName: const Value('Artist 1'),
          songsHydrated: const Value(true),
          serverCreatedAt: Value(DateTime.utc(2026, 8, 10)),
        ),
      ]);
      api.fastPathPages[0] = <Album>[
        Album(
          id: 'album-missing-date',
          name: 'Missing Date Album',
          artistId: 'artist-1',
          artist: 'Artist 1',
          created: restoredCreated,
        ),
      ];

      final state = await engine.executeSyncPlan(
        syncPlanForTest(SyncExecutionPlanKind.manualCatalogDiscovery),
      );
      final albums = await database.libraryDao
          .watchAlbumsSorted(sort: AlbumSortOrder.recentlyAdded)
          .first;

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(
        (await database.libraryDao.getAlbumById('album-missing-date'))
            ?.serverCreatedAt
            ?.toUtc(),
        restoredCreated,
      );
      expect(albums.map((album) => album.id), <String>[
        'album-missing-date',
        'album-older',
      ]);
    }, skip: !sqliteAvailable);

    test('manual 48-album newest probe preserves server order without creation dates', () async {
      await saveSession(lastSynced: DateTime.now());
      final meteredEngine = DriftLibrarySyncEngine(
        api: api,
        database: database,
        serverConfigRepository: serverConfigRepository,
        networkType: NetworkType.cellular,
        readSyncNetworkPolicy: () => const SyncNetworkPolicy(
          networkType: NetworkType.cellular,
          isMetered: true,
          allowsBackgroundSync: false,
          allowsHardProbe: true,
          allowsInteractiveHydration: true,
        ),
        fallbackArtistConcurrency: 1,
        cellularAlbumConcurrency: 1,
        writeChunkSize: 4,
      );
      final newest = List<Album>.generate(
        48,
        (index) => Album(
          id: 'album-$index',
          // Intentionally opposite the server's newest order. Without a
          // persisted feed rank, the current fallback is alphabetical.
          name: 'Album ${(48 - index).toString().padLeft(2, '0')}',
          artistId: 'artist-$index',
          artist: 'Artist ${(48 - index).toString().padLeft(2, '0')}',
          songCount: 1,
        ),
        growable: false,
      );
      api.fastPathPages[0] = newest;
      for (final album in newest.take(3)) {
        api.albumDetails[album.id] = Album(
          id: album.id,
          name: album.name,
          artistId: album.artistId,
          artist: album.artist,
          // Compatible getAlbum responses may omit this optional field.
          songs: <Song>[
            Song(
              id: 'song-${album.id}',
              title: 'Song ${album.id}',
              albumId: album.id,
              artistId: album.artistId,
            ),
          ],
        );
      }

      final state = await meteredEngine.executeSyncPlan(
        _meteredManualDiscoveryPlan,
      );
      final albums = await database.libraryDao
          .watchAlbumsSorted(sort: AlbumSortOrder.recentlyAdded)
          .first;

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(api.calls, contains('getAlbumListPage:0:50'));
      expect(albums.map((album) => album.id), newest.map((album) => album.id));
    }, skip: !sqliteAvailable);

    test('manual newest probe repairs an alphabetical creation-date tie without metadata changes', () async {
      await saveSession(lastSynced: DateTime.now());
      final created = DateTime.utc(2026, 8, 20);
      final newest = <Album>[
        Album(
          id: 'album-zulu',
          name: 'Zulu',
          artistId: 'artist-zulu',
          artist: 'Artist Zulu',
          created: created,
        ),
        Album(
          id: 'album-middle',
          name: 'Middle',
          artistId: 'artist-middle',
          artist: 'Artist Middle',
          created: created,
        ),
        Album(
          id: 'album-alpha',
          name: 'Alpha',
          artistId: 'artist-alpha',
          artist: 'Artist Alpha',
          created: created,
        ),
      ];
      await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
        for (final album in newest)
          ArtistsTableCompanion.insert(
            id: album.artistId!,
            name: album.artist!,
          ),
      ]);
      await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
        for (final album in newest)
          AlbumsTableCompanion.insert(
            id: album.id,
            name: album.name,
            artistId: Value(album.artistId),
            artistName: Value(album.artist),
            serverCreatedAt: Value(created),
          ),
      ]);
      api.fastPathPages[0] = newest;

      final state = await engine.executeSyncPlan(
        syncPlanForTest(SyncExecutionPlanKind.manualCatalogDiscovery),
      );
      final albums = await database.libraryDao
          .watchAlbumsSorted(sort: AlbumSortOrder.recentlyAdded)
          .first;

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(albums.map((album) => album.id), newest.map((album) => album.id));
    }, skip: !sqliteAvailable);

    test(
      'incomplete targeted album response preserves existing tracks',
      () async {
        await saveSession(lastSynced: DateTime.now());
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'album-1',
            name: 'Album 1',
            songsHydrated: const Value(false),
          ),
        ]);
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'existing-song',
            title: 'Existing',
            albumId: const Value('album-1'),
          ),
        ]);
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          songCount: 1,
        );

        final state = await engine.hydrateAlbum('album-1');

        expect(state.status, LibrarySyncStatus.partial);
        expect(
          await database.libraryDao.getSongById('existing-song'),
          isNotNull,
        );
        expect(
          (await database.libraryDao.getAlbumById('album-1'))?.songsHydrated,
          isFalse,
        );
      },
      skip: !sqliteAvailable,
    );

    for (final detail in [
      const Artist(id: 'wrong-artist', name: 'Wrong'),
      const Artist(
        id: 'artist-1',
        name: 'Partial',
        albumCount: 2,
        albums: [Album(id: 'new-album', name: 'New')],
      ),
      const Artist(
        id: 'artist-1',
        name: 'Duplicate',
        albums: [
          Album(id: 'same', name: 'A'),
          Album(id: 'same', name: 'B'),
        ],
      ),
    ]) {
      test(
        'incomplete artist detail preserves existing metadata: ${detail.name}',
        () async {
          await saveSession(lastSynced: DateTime.now());
          await database.libraryDao.upsertArtists([
            ArtistsTableCompanion.insert(id: 'artist-1', name: 'Existing'),
          ]);
          api.artistDetails['artist-1'] = detail;
          final result = await engine.hydrateArtist('artist-1');
          expect(result.status, LibrarySyncStatus.partial);
          expect(
            (await database.libraryDao.getArtistById('artist-1'))!.name,
            'Existing',
          );
          expect(await database.libraryDao.getAlbumById('new-album'), isNull);
        },
        skip: !sqliteAvailable,
      );
    }

    test('external targeted artist and album hydration stays provisional and browsable by exact detail', () async {
      await saveSession(lastSynced: DateTime.now());
      api.artistDetails['ext-deezer-artist-1'] = const Artist(
        id: 'ext-deezer-artist-1',
        name: 'Remote Artist',
        albums: <Album>[
          Album(
            id: 'provider-album-1',
            name: 'Remote Album',
            artistId: 'ext-deezer-artist-1',
          ),
          Album(
            id: 'provider-album-2',
            name: 'Remote Album',
            artistId: 'ext-deezer-artist-1',
          ),
        ],
      );
      api.albumDetails['provider-album-1'] = const Album(
        id: 'provider-album-1',
        name: 'Remote Album',
        artist: 'Remote Artist',
        artistId: 'ext-deezer-artist-1',
        isExternal: true,
        songs: <Song>[
          Song(
            id: 'provider-song-1',
            title: 'Remote Song',
            albumId: 'provider-album-1',
            artistId: 'ext-deezer-artist-1',
          ),
        ],
      );

      final artistState = await engine.hydrateArtist('ext-deezer-artist-1');
      expect(api.calls, <String>['getArtist:ext-deezer-artist-1']);
      expect(
        await database.libraryDao
            .watchAlbumsByArtist('ext-deezer-artist-1')
            .first,
        hasLength(2),
      );
      expect(
        await database.libraryDao
            .watchSongsByArtist('ext-deezer-artist-1')
            .first,
        isEmpty,
      );
      final albumState = await engine.hydrateAlbum('provider-album-1');

      expect(artistState.status, LibrarySyncStatus.succeeded);
      expect(albumState.status, LibrarySyncStatus.succeeded);
      final artist = await database.libraryDao.getArtistById(
        'ext-deezer-artist-1',
      );
      final album = await database.libraryDao.getAlbumById('provider-album-1');
      final song = await database.libraryDao.getSongById('provider-song-1');
      expect(artist?.isExternal, isTrue);
      expect(artist?.isProvisional, isTrue);
      expect(album?.isExternal, isTrue);
      expect(album?.isProvisional, isTrue);
      expect(album?.songsHydrated, isTrue);
      expect(song?.isExternal, isTrue);
      expect(song?.isProvisional, isTrue);
      expect(
        await database.libraryDao.watchSongsByAlbum(album!.id).first,
        hasLength(1),
      );
      expect(
        await database.libraryDao.watchAlbumsByArtist(artist!.id).first,
        hasLength(2),
      );
      expect(await database.libraryDao.watchAllAlbums().first, isEmpty);
      await engine.hydrateArtist('ext-deezer-artist-1');
      expect(
        (await database.libraryDao.getAlbumById('provider-album-1'))!
            .songsHydrated,
        isTrue,
      );
    }, skip: !sqliteAvailable);

    test('remote album detail cannot clear persisted provenance or artist metadata', () async {
      await saveSession(lastSynced: DateTime.now());
      await database.libraryDao.upsertProvisionalArtists(
        <ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(
            id: 'remote-artist',
            name: 'Remote Artist',
            isExternal: const Value(true),
          ),
        ],
      );
      await database.libraryDao.upsertProvisionalAlbums(<AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(
          id: 'remote-album',
          name: 'Remote Album',
          artistId: const Value('remote-artist'),
          artistName: const Value('Remote Artist'),
          isExternal: const Value(true),
        ),
      ]);
      // A partial provider response contradicts the already-persisted
      // remote membership and assigns it to a different artist. Detail is
      // content authority only, so it must not make the release disappear
      // from the artist page that originally exposed it.
      api.albumDetails['remote-album'] = const Album(
        id: 'remote-album',
        name: 'Remote Album',
        artist: 'Incorrect Detail Artist',
        artistId: 'incorrect-detail-artist',
        isExternal: false,
        songs: <Song>[Song(id: 'remote-song', title: 'Remote Song')],
      );

      final state = await engine.hydrateAlbum('remote-album');
      final album = await database.libraryDao.getAlbumById('remote-album');
      final song = await database.libraryDao.getSongById('remote-song');

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(album?.artistId, 'remote-artist');
      expect(album?.artistName, 'Remote Artist');
      expect(album?.isExternal, isTrue);
      expect(album?.isProvisional, isTrue);
      expect(album?.songsHydrated, isTrue);
      expect(song?.isExternal, isTrue);
      expect(song?.isProvisional, isTrue);
      expect(
        await database.libraryDao.watchSongsByAlbum('remote-album').first,
        hasLength(1),
      );
      expect(
        await database.libraryDao.watchAlbumsByArtist('remote-artist').first,
        hasLength(1),
      );
      final artistBuckets = await database.libraryDao
          .watchArtistAlbumBuckets('remote-artist')
          .firstWhere((buckets) => !buckets.isEmpty);
      expect(artistBuckets.primaryAlbums, hasLength(1));
      expect(await database.libraryDao.watchAllAlbums().first, isEmpty);
    }, skip: !sqliteAvailable);

    Future<void> incompleteStarredAlbums() async {
      await saveSession(lastSynced: DateTime.now());
      api.starredContent = StarredContent(
        songs: [
          Song(
            id: 'first-song',
            title: 'First',
            albumId: 'first',
            starred: DateTime.utc(2026),
          ),
          Song(
            id: 'second-song',
            title: 'Second',
            albumId: 'second',
            starred: DateTime.utc(2026),
          ),
        ],
      );
    }

    test('failed first starred hydration stops the album loop', () async {
      await incompleteStarredAlbums();
      api.albumErrors['first'] = StateError('album failed');
      final state = await engine.syncStarredContent();
      // Annotation reconciliation survives failed detail hydration.
      expect(state.status, LibrarySyncStatus.succeeded);
      expect(api.calls.where((call) => call.startsWith('getAlbum:')), [
        'getAlbum:first',
      ]);
    }, skip: !sqliteAvailable);

    test(
      'starred hydration honours cancellation without starting a new run',
      () async {
        await incompleteStarredAlbums();
        final countingApi = _RunCountingSyncApi()
          ..starredContent = api.starredContent;
        countingApi.albumCompleter = Completer<Album>();
        final starredEngine = DriftLibrarySyncEngine(
          api: countingApi,
          database: database,
          serverConfigRepository: serverConfigRepository,
          networkType: NetworkType.wifi,
        );
        final run = starredEngine.syncStarredContent();
        for (
          var turn = 0;
          turn < 5000 && countingApi.currentAlbumRequests == 0;
          turn++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        expect(countingApi.currentAlbumRequests, 1);
        starredEngine.cancelSync();
        final state = await run;
        expect(state.status, LibrarySyncStatus.cancelled);
        expect(countingApi.beginRunCalls, 1);
        expect(countingApi.activeRequestsCancelled, isTrue);
        expect(
          countingApi.calls.where((call) => call.startsWith('getAlbum:')),
          ['getAlbum:first'],
        );
      },
      skip: !sqliteAvailable,
    );

    for (final (error, entityStatus, auxiliaryStatus) in [
      (
        const SyncCancelledException(),
        LibrarySyncStatus.cancelled,
        LibrarySyncStatus.cancelled,
      ),
      (
        const SyncNetworkDeferredException(),
        LibrarySyncStatus.deferred,
        LibrarySyncStatus.deferred,
      ),
      (
        const SubsonicResponseBudgetExceededException(
          maxBytes: 1,
          observedBytes: 2,
        ),
        LibrarySyncStatus.deferred,
        LibrarySyncStatus.deferred,
      ),
      (
        const SubsonicIncompleteResponseException('Incomplete'),
        LibrarySyncStatus.partial,
        LibrarySyncStatus.failed,
      ),
      (
        StateError('Failed'),
        LibrarySyncStatus.failed,
        LibrarySyncStatus.failed,
      ),
    ]) {
      for (final target in [
        'album',
        'artist',
        'playlist',
        'starred',
        'playlistHeaders',
        'probe',
      ]) {
        test('$target terminates ${error.runtimeType} consistently', () async {
          await saveSession();
          final targetEngine = DriftLibrarySyncEngine(
            api: _FailingTargetSyncApi(error),
            database: database,
            serverConfigRepository: serverConfigRepository,
          );
          final progress = <LibrarySyncState>[];
          final state = await switch (target) {
            'album' => targetEngine.hydrateAlbum('a', onProgress: progress.add),
            'artist' => targetEngine.hydrateArtist(
              'a',
              onProgress: progress.add,
            ),
            'playlist' => targetEngine.hydratePlaylist(
              'a',
              onProgress: progress.add,
            ),
            'starred' => targetEngine.syncStarredContent(
              onProgress: progress.add,
            ),
            'playlistHeaders' => targetEngine.syncPlaylistHeaders(
              onProgress: progress.add,
            ),
            _ => targetEngine.probeCatalog(onProgress: progress.add),
          };
          final expected = target == 'probe'
              ? (error is SyncCancelledException
                    ? LibrarySyncStatus.cancelled
                    : LibrarySyncStatus.failed)
              : target == 'starred' || target == 'playlistHeaders'
              ? auxiliaryStatus
              : entityStatus;
          expect(state.status, expected);
          expect(state.stage, LibrarySyncStage.completed);
          expect(state.completedAt, isNotNull);
          expect(state.isHydrating, isFalse);
          expect(progress.first.status, LibrarySyncStatus.running);
          expect(progress.last, same(state));
          if ((target == 'album' || target == 'playlist') &&
              (error is SubsonicIncompleteResponseException ||
                  error is SubsonicResponseBudgetExceededException)) {
            expect(state.pendingHydrationCount, 1);
          }
        }, skip: !sqliteAvailable);
      }
    }

    test('network-deferred album hydration clears its active flag', () async {
      api.albumErrors['album-1'] = const SyncNetworkDeferredException();
      final state = await engine.hydrateAlbum('album-1');
      expect(state.status, LibrarySyncStatus.deferred);
      expect(state.isHydrating, isFalse);
    }, skip: !sqliteAvailable);

    test('cancellation interrupts an active targeted request', () async {
      await saveSession(lastSynced: DateTime.now());
      api.albumCompleter = Completer<Album>();

      final hydration = engine.hydrateAlbum('album-1');
      await Future<void>.delayed(Duration.zero);
      engine.cancelSync();
      final state = await hydration;

      expect(api.activeRequestsCancelled, isTrue);
      expect(state.status, LibrarySyncStatus.cancelled);
      expect(state.isHydrating, isFalse);
    }, skip: !sqliteAvailable);

    test(
      'large snapshot deletion requires a second matching fingerprint',
      () async {
        await saveSession();
        await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(id: 'artist-keep', name: 'Keep'),
          ArtistsTableCompanion.insert(id: 'artist-stale', name: 'Stale'),
        ]);
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'album-keep',
            name: 'Keep',
            artistId: const Value('artist-keep'),
          ),
          AlbumsTableCompanion.insert(
            id: 'album-stale',
            name: 'Stale',
            artistId: const Value('artist-stale'),
          ),
        ]);
        api.artists.add(const Artist(id: 'artist-keep', name: 'Keep'));
        api.fastPathPages[0] = const <Album>[
          Album(id: 'album-keep', name: 'Keep', artistId: 'artist-keep'),
        ];
        api.albumDetails['album-keep'] = const Album(
          id: 'album-keep',
          name: 'Keep',
          artistId: 'artist-keep',
        );

        final first = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );
        expect(first.freshness, LibrarySyncFreshness.repairRecommended);
        expect(
          await database.libraryDao.getAlbumById('album-stale'),
          isNotNull,
        );

        final locallyStarredAt = DateTime.now();
        await database.libraryDao.setEntityStarred(
          'album',
          'album-keep',
          locallyStarredAt,
        );

        final second = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );
        expect(second.status, LibrarySyncStatus.succeeded);
        expect(await database.libraryDao.getAlbumById('album-stale'), isNull);
        expect(await database.libraryDao.getArtistById('artist-stale'), isNull);
        final preservedStarred = (await database.libraryDao.getAlbumById(
          'album-keep',
        ))?.starred;
        expect(preservedStarred, isNotNull);
        expect(
          preservedStarred!.difference(locallyStarredAt).abs(),
          lessThan(const Duration(seconds: 1)),
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'full repair hydrates candidate songs before assessing large deletion',
      () async {
        await saveSession();
        await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(id: 'artist-stale', name: 'Stale'),
        ]);
        await database.batch((batch) {
          for (var index = 0; index < 501; index++) {
            batch.insert(
              database.songsTable,
              SongsTableCompanion.insert(
                id: 'stale-song-$index',
                title: 'Stale song $index',
                artistId: const Value('artist-stale'),
              ),
            );
          }
        });
        api.artists.add(const Artist(id: 'artist-keep', name: 'Keep'));
        api.fastPathPages[0] = const <Album>[
          Album(id: 'album-keep', name: 'Keep', artistId: 'artist-keep'),
        ];
        api.albumDetails['album-keep'] = const Album(
          id: 'album-keep',
          name: 'Keep',
          artistId: 'artist-keep',
          songs: <Song>[
            Song(id: 'song-keep', title: 'Keep', albumId: 'album-keep'),
          ],
        );

        final result = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );
        final candidateSongs =
            await (database.select(database.librarySyncCandidateSongsTable)
                  ..where(
                    (table) =>
                        table.serverId.equals(1) & table.generation.equals(1),
                  ))
                .get();

        expect(result.candidateStatus, 'awaitingDeletionConfirmation');
        expect(api.calls, contains('getAlbum:album-keep'));
        expect(candidateSongs.map((song) => song.id), contains('song-keep'));
      },
      skip: !sqliteAvailable,
    );

    test(
      'catalog promotion retains a stale song protected by playback',
      () async {
        await saveSession();
        await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(id: 'artist-stale', name: 'Artist'),
        ]);
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'album-stale',
            name: 'Album',
            artistId: const Value('artist-stale'),
            songsHydrated: const Value(true),
          ),
        ]);
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'song-playing',
            title: 'Playing',
            albumId: const Value('album-stale'),
            artistId: const Value('artist-stale'),
          ),
        ]);
        final protectedEngine = DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          readActiveSongId: () => 'song-playing',
          readProtectedSongIds: () => const <String>{'song-playing'},
          fallbackArtistConcurrency: 1,
          wifiAlbumConcurrency: 1,
          cellularAlbumConcurrency: 1,
          otherAlbumConcurrency: 1,
          writeChunkSize: 4,
        );

        final first = await protectedEngine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );
        expect(first.freshness, LibrarySyncFreshness.repairRecommended);
        final second = await protectedEngine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );
        expect(second.status, LibrarySyncStatus.succeeded);

        final song = await database.libraryDao.getSongById('song-playing');
        final album = await database.libraryDao.getAlbumById('album-stale');
        final artist = await database.libraryDao.getArtistById('artist-stale');
        expect(song, isNotNull);
        expect(song!.isProvisional, isTrue);
        expect(album?.isProvisional, isTrue);
        expect(artist?.isProvisional, isTrue);
        expect(await database.libraryDao.watchAllAlbums().first, isEmpty);
      },
      skip: !sqliteAvailable,
    );

    test(
      'catalog promotion auto-merges cached identities before cleanup',
      () async {
        await saveSession();
        await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist'),
        ]);
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'album-1',
            name: 'Album',
            artistId: const Value('artist-1'),
            songsHydrated: const Value(true),
          ),
        ]);
        await database.libraryDao.upsertProvisionalSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'cached-remote-song',
            title: 'Track',
            albumId: const Value('album-1'),
            artistId: const Value('artist-1'),
            recordingMbid: const Value('recording-mbid'),
          ),
        ]);
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist'));
        api.fastPathPages[0] = const <Album>[
          Album(
            id: 'album-1',
            name: 'Album',
            artistId: 'artist-1',
            songCount: 1,
          ),
        ];
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album',
          artistId: 'artist-1',
          songCount: 1,
          songs: <Song>[
            Song(
              id: 'server-song',
              title: 'Track',
              albumId: 'album-1',
              artistId: 'artist-1',
              musicBrainzId: 'recording-mbid',
            ),
          ],
        );
        final appliedAliases = <Map<String, String>>[];
        final aliasEngine = DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          onBeforeSongIdentityRemap: (aliases) async {
            expect(
              await database.libraryDao.getSongById('cached-remote-song'),
              isNotNull,
            );
            appliedAliases.add(Map<String, String>.from(aliases));
          },
          fallbackArtistConcurrency: 1,
          wifiAlbumConcurrency: 1,
          cellularAlbumConcurrency: 1,
          otherAlbumConcurrency: 1,
          writeChunkSize: 4,
        );

        final result = await aliasEngine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );
        final aliases = await database.songIdentityDao.getAliases();

        expect(result.status, LibrarySyncStatus.succeeded);
        expect(appliedAliases, <Map<String, String>>[
          <String, String>{'cached-remote-song': 'server-song'},
        ]);
        expect(aliases.single.oldSongId, 'cached-remote-song');
        expect(aliases.single.canonicalSongId, 'server-song');
        expect(
          await database.libraryDao.getSongById('cached-remote-song'),
          isNull,
        );
        expect(await database.libraryDao.getSongById('server-song'), isNotNull);
      },
      skip: !sqliteAvailable,
    );

    test(
      'full promotion persists album and artist MusicBrainz identifiers',
      () async {
        await saveSession();
        api.artists.addAll(const <Artist>[
          Artist(
            id: 'artist-1',
            name: 'Artist 1',
            musicBrainzId: 'artist-mbid-1',
          ),
          Artist(
            id: 'artist-2',
            name: 'Artist 2',
            musicBrainzId: 'artist-mbid-2',
          ),
        ]);
        api.fastPathPages[0] = const <Album>[
          Album(
            id: 'album-1',
            name: 'Album 1',
            artist: 'Artist 1',
            artistId: 'artist-1',
            musicBrainzId: 'release-mbid-1',
          ),
          Album(
            id: 'album-2',
            name: 'Album 2',
            artist: 'Artist 2',
            artistId: 'artist-2',
            musicBrainzId: 'release-mbid-2',
          ),
        ];
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          musicBrainzId: 'release-mbid-1',
          songs: <Song>[
            Song(id: 'song-1', title: 'Song 1', albumId: 'album-1'),
          ],
        );
        api.albumDetails['album-2'] = const Album(
          id: 'album-2',
          name: 'Album 2',
          musicBrainzId: 'release-mbid-2',
          songs: <Song>[
            Song(id: 'song-2', title: 'Song 2', albumId: 'album-2'),
          ],
        );

        final state = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );

        expect(state.status, LibrarySyncStatus.succeeded);
        final album1 = await database.libraryDao.getAlbumById('album-1');
        expect(album1!.releaseMbid, 'release-mbid-1');
        final album2 = await database.libraryDao.getAlbumById('album-2');
        expect(album2!.releaseMbid, 'release-mbid-2');
        final artist1 = await database.libraryDao.getArtistById('artist-1');
        expect(artist1!.artistMbid, 'artist-mbid-1');
        final artist2 = await database.libraryDao.getArtistById('artist-2');
        expect(artist2!.artistMbid, 'artist-mbid-2');
      },
      skip: !sqliteAvailable,
    );

    test(
      'promotion sends contested duplicate-MBID claims to recovery review',
      () async {
        await saveSession();
        await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist'),
        ]);
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'album-1',
            name: 'Album',
            artistId: const Value('artist-1'),
            songsHydrated: const Value(true),
          ),
        ]);
        await database.libraryDao.upsertProvisionalSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'cached-remote-song',
            title: 'Track',
            albumId: const Value('album-1'),
            artistId: const Value('artist-1'),
            recordingMbid: const Value('shared-mbid'),
          ),
        ]);
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist'));
        api.fastPathPages[0] = const <Album>[
          Album(
            id: 'album-1',
            name: 'Album',
            artistId: 'artist-1',
            songCount: 2,
          ),
        ];
        // Two server songs claim the same recording MBID: uniqueness across
        // the complete replacement set is impossible, so neither remap may
        // apply silently and both canonical rows become review cases.
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album',
          artistId: 'artist-1',
          songCount: 2,
          songs: <Song>[
            Song(
              id: 'server-song-a',
              title: 'Track A',
              albumId: 'album-1',
              artistId: 'artist-1',
              musicBrainzId: 'shared-mbid',
            ),
            Song(
              id: 'server-song-b',
              title: 'Track B',
              albumId: 'album-1',
              artistId: 'artist-1',
              musicBrainzId: 'shared-mbid',
            ),
          ],
        );

        final result = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );

        expect(result.status, LibrarySyncStatus.succeeded);
        expect(await database.songIdentityDao.getAliases(), isEmpty);
        final review = await pendingRecoveryReviews(database, 1);
        final contested = review
            .where((entry) => entry.reason == 'ambiguousMatch')
            .toList();
        expect(contested.map((entry) => entry.oldId).toSet(), <String>{
          'server-song-a',
          'server-song-b',
        });
        for (final entry in contested) {
          final details =
              jsonDecode(entry.candidateJson!) as Map<String, dynamic>;
          expect(details['candidateIds'], <String>['cached-remote-song']);
        }
      },
      skip: !sqliteAvailable,
    );

    test('promotion relinks a stale album through its song alias and carries the favorite', () async {
      await saveSession();
      await database.libraryDao.upsertProvisionalAlbums([
        AlbumsTableCompanion.insert(
          id: 'album-stale',
          name: 'Stale Album',
          starred: Value(DateTime.utc(2026, 9, 5)),
        ),
      ]);
      await database.libraryDao.upsertProvisionalSongs([
        SongsTableCompanion.insert(
          id: 'song-old',
          title: 'Track',
          albumId: const Value('album-stale'),
          recordingMbid: const Value('rec-1'),
        ),
      ]);
      api.artists.add(const Artist(id: 'artist-1', name: 'Artist'));
      api.fastPathPages[0] = const <Album>[
        Album(
          id: 'album-new',
          name: 'Stale Album',
          artistId: 'artist-1',
          artist: 'Artist',
          songCount: 1,
        ),
      ];
      api.albumDetails['album-new'] = const Album(
        id: 'album-new',
        name: 'Stale Album',
        artistId: 'artist-1',
        songCount: 1,
        songs: <Song>[
          Song(
            id: 'song-new',
            title: 'Track',
            albumId: 'album-new',
            artistId: 'artist-1',
            musicBrainzId: 'rec-1',
          ),
        ],
      );

      final result = await engine.executeSyncPlan(
        syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
      );

      expect(result.status, LibrarySyncStatus.succeeded);
      // The old album identity is gone, replaced under the new server ID.
      expect(await database.libraryDao.getAlbumById('album-stale'), isNull);
      final album = await database.libraryDao.getAlbumById('album-new');
      expect(album, isNotNull);
      // The album favorite carries forward through the remap.
      expect(album!.starred, isNotNull);
      final aliasRows = await database
          .customSelect(
            'SELECT old_id, new_id FROM entity_identity_aliases '
            "WHERE entity_type = 'album';",
          )
          .get();
      expect(aliasRows, hasLength(1));
      expect(aliasRows.single.read<String>('old_id'), 'album-stale');
      expect(aliasRows.single.read<String>('new_id'), 'album-new');
      // The song relinked through its recording MBID.
      expect(await database.libraryDao.getSongById('song-old'), isNull);
      expect(await database.libraryDao.getSongById('song-new'), isNotNull);
      // The restored album favorite is queued so the server restores it
      // for other clients.
      final pending = await database.starSyncDao.getPendingActions();
      expect(
        pending.where(
          (action) =>
              action.itemType == 'album' &&
              action.itemId == 'album-new' &&
              action.operation == 'star',
        ),
        isNotEmpty,
      );
    }, skip: !sqliteAvailable);

    test('promotion clears absence evidence when the server re-lists a retained song', () async {
      await saveSession();
      // A song the previous catalog validated as absent: retained with
      // typed confirmed-missing evidence.
      await database.libraryDao.upsertProvisionalSongs([
        SongsTableCompanion.insert(id: 'song-return', title: 'Track'),
      ]);
      await (database.update(
        database.songsTable,
      )..where((t) => t.id.equals('song-return'))).write(
        SongsTableCompanion(
          serverDeletedAt: Value(DateTime.utc(2026, 9, 6)),
          catalogAvailability: const Value('confirmedMissing'),
        ),
      );
      api.artists.add(const Artist(id: 'artist-1', name: 'Artist'));
      api.fastPathPages[0] = const <Album>[
        Album(
          id: 'album-1',
          name: 'Album',
          artistId: 'artist-1',
          artist: 'Artist',
          songCount: 1,
        ),
      ];
      api.albumDetails['album-1'] = const Album(
        id: 'album-1',
        name: 'Album',
        artistId: 'artist-1',
        songCount: 1,
        songs: <Song>[
          Song(
            id: 'song-return',
            title: 'Track',
            albumId: 'album-1',
            artistId: 'artist-1',
          ),
        ],
      );

      final result = await engine.executeSyncPlan(
        syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
      );

      expect(result.status, LibrarySyncStatus.succeeded);
      final song = await database.libraryDao.getSongById('song-return');
      expect(song, isNotNull);
      // Snapshot observation proves presence: absence markers clear and
      // the row rejoins its album.
      expect(song!.serverDeletedAt, isNull);
      expect(song.catalogAvailability, isNull);
      expect(song.isProvisional, isFalse);
      expect(song.albumId, 'album-1');
    }, skip: !sqliteAvailable);

    test('compatibility audit rotates at most 24 artists per run', () async {
      final cursor = DateTime.utc(2026, 1, 1);
      await saveSession(
        lastSynced: DateTime.now(),
        capabilitiesJson: jsonEncode(<String, Object?>{
          'navis': <String, Object?>{
            'libraryIndexesCursor': cursor.toIso8601String(),
            'libraryHealthCheckedAt': DateTime.now().toUtc().toIso8601String(),
          },
        }),
      );
      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: const Value(1),
          lastAuxiliarySyncedAt: Value(DateTime.now()),
        ),
      );
      final artists = List<Artist>.generate(
        30,
        (index) => Artist(id: 'artist-$index', name: 'Artist $index'),
      );
      api.indexes = Indexes(lastModified: cursor, shortcut: artists);
      for (final artist in artists) {
        api.artistDetails[artist.id] = artist;
      }

      final first = await engine.executeSyncPlan(
        syncPlanForTest(SyncExecutionPlanKind.compatibilityAudit),
      );
      final firstRequests = api.calls
          .where((call) => call.startsWith('getArtist:'))
          .length;
      final firstState = await database.librarySyncDao.getOrCreateState(1);

      expect(first.status, LibrarySyncStatus.succeeded);
      expect(firstRequests, 24);
      expect(firstState.auditOffset, 24);
      expect(firstState.lastAuditAt, isNotNull);

      api.calls.clear();
      final second = await engine.executeSyncPlan(
        syncPlanForTest(SyncExecutionPlanKind.compatibilityAudit),
      );
      final secondRequests = api.calls
          .where((call) => call.startsWith('getArtist:'))
          .length;
      final secondState = await database.librarySyncDao.getOrCreateState(1);

      expect(second.status, LibrarySyncStatus.succeeded);
      expect(secondRequests, 6);
      expect(secondState.auditOffset, 0);
    }, skip: !sqliteAvailable);

    test('album detail with conflicting parent remains unresolved', () async {
      await saveSession();
      api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
      api.artistDetails['artist-1'] = const Artist(
        id: 'artist-1',
        name: 'Artist 1',
        albums: <Album>[
          Album(id: 'album-1', name: 'Album 1', artistId: 'artist-1'),
        ],
      );
      api.fastPathPages[0] = const <Album>[
        Album(
          id: 'album-1',
          name: 'Album 1',
          artist: 'Artist 1',
          artistId: 'artist-1',
        ),
      ];
      api.albumDetails['album-1'] = const Album(
        id: 'album-1',
        name: 'Album 1',
        songs: <Song>[
          Song(
            id: 'song-1',
            title: 'Song 1',
            albumId: 'missing-album-id',
            artistId: 'artist-1',
          ),
        ],
      );

      final state = await engine.executeSyncPlan(
        syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
      );
      final songRows = await database.select(database.songsTable).get();

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(songRows, isEmpty);
      expect(
        (await database.libraryDao.getAlbumById('album-1'))!.songsHydrated,
        isFalse,
      );
      expect(state.freshness, LibrarySyncFreshness.verificationPending);
    }, skip: !sqliteAvailable);

    test(
      'fast-path metadata sync emits incremental album discovery progress',
      () async {
        await saveSession();
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = const <Album>[
          Album(
            id: 'album-1',
            name: 'Album 1',
            artist: 'Artist 1',
            artistId: 'artist-1',
          ),
          Album(
            id: 'album-2',
            name: 'Album 2',
            artist: 'Artist 1',
            artistId: 'artist-1',
          ),
        ];
        api.fastPathPages[2] = const <Album>[
          Album(
            id: 'album-3',
            name: 'Album 3',
            artist: 'Artist 1',
            artistId: 'artist-1',
          ),
        ];
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          artist: 'Artist 1',
          artistId: 'artist-1',
          songs: <Song>[],
        );
        api.albumDetails['album-2'] = const Album(
          id: 'album-2',
          name: 'Album 2',
          artist: 'Artist 1',
          artistId: 'artist-1',
          songs: <Song>[],
        );
        api.albumDetails['album-3'] = const Album(
          id: 'album-3',
          name: 'Album 3',
          artist: 'Artist 1',
          artistId: 'artist-1',
          songs: <Song>[],
        );

        final localEngine = DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          fallbackArtistConcurrency: 1,
          wifiAlbumConcurrency: 1,
          cellularAlbumConcurrency: 1,
          otherAlbumConcurrency: 1,
          fastPathPageSize: 2,
          writeChunkSize: 4,
        );

        final progress = <LibrarySyncState>[];
        await localEngine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
          onProgress: progress.add,
        );

        final albumStageProgress = progress
            .where((state) => state.stage == LibrarySyncStage.fetchingAlbums)
            .where((state) => state.processed != null && state.total != null)
            .toList(growable: false);

        expect(albumStageProgress.length, greaterThanOrEqualTo(2));
        expect(albumStageProgress.first.processed, 2);
        expect(albumStageProgress.last.processed, 3);
        expect(albumStageProgress.last.total, 3);
      },
      skip: !sqliteAvailable,
    );

    test(
      'continues catalog pagination after a server-capped short album page',
      () async {
        await saveSession();
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        for (var index = 0; index < 5; index++) {
          final albumNumber = index + 1;
          final album = Album(
            id: 'album-$albumNumber',
            name: 'Album $albumNumber',
            artistId: 'artist-1',
          );
          api.fastPathPages
              .putIfAbsent(
                index < 2
                    ? 0
                    : index < 4
                    ? 2
                    : 4,
                () => <Album>[],
              )
              .add(album);
          api.albumDetails[album.id] = Album(
            id: album.id,
            name: album.name,
            songs: <Song>[],
          );
        }
        final cappedPageEngine = DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          fastPathPageSize: 4,
          writeChunkSize: 8,
        );

        final state = await cappedPageEngine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(
          api.calls,
          containsAll(<String>[
            'getAlbumListPage:0:4',
            'getAlbumListPage:2:4',
            'getAlbumListPage:4:4',
            'getAlbumListPage:5:4',
          ]),
        );
        expect(await database.libraryDao.getAllAlbums(), hasLength(5));
      },
      skip: !sqliteAvailable,
    );

    group('album repeated across catalog pages', () {
      // A server whose album list shifts while Navis pages through it (an
      // album added mid-repair, or ties in name order) returns the album at a
      // page boundary on both pages.
      Album header(String id) => Album(id: id, name: id, artistId: 'artist-1');

      DriftLibrarySyncEngine shiftedCatalogEngine() {
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = [header('a'), header('b')];
        api.fastPathPages[2] = [header('b'), header('c')];
        api.fastPathPages[4] = [header('d')];
        api.newestPages[0] = [
          header('d'),
          header('c'),
          header('b'),
          header('a'),
        ];
        for (final id in ['a', 'b', 'c', 'd']) {
          api.albumDetails[id] = Album(
            id: id,
            name: id,
            artistId: 'artist-1',
            songs: const <Song>[],
          );
        }
        return DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          fastPathPageSize: 2,
        );
      }

      Future<Set<String>> albumIds() async =>
          (await database.libraryDao.getAllAlbums())
              .map((album) => album.id)
              .toSet();

      test('still completes the repair', () async {
        await saveSession();
        final localEngine = shiftedCatalogEngine();

        final state = await localEngine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(await albumIds(), {'a', 'b', 'c', 'd'});
      }, skip: !sqliteAvailable);

      test(
        'completes when an interrupted repair resumes its saved pages',
        () async {
          await saveSession();
          final localEngine = shiftedCatalogEngine();
          api.fastPathErrors[4] = const SubsonicConnectionException('offline');
          expect(
            (await localEngine.executeSyncPlan(
              syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
            )).status,
            LibrarySyncStatus.failed,
          );

          api.fastPathErrors.clear();
          final resumed = await localEngine.executeSyncPlan(
            syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
          );

          expect(resumed.status, LibrarySyncStatus.succeeded);
          expect(await albumIds(), {'a', 'b', 'c', 'd'});
          // The middle page came from its saved checkpoint, not a new request.
          expect(
            api.calls.where((call) => call == 'getAlbumListPage:2:2'),
            hasLength(2),
          );
        },
        skip: !sqliteAvailable,
      );

      test('in the newest list keeps its first rank', () async {
        await saveSession();
        final localEngine = shiftedCatalogEngine();
        api.fastPathPages
          ..clear()
          ..[0] = [header('a'), header('b')]
          ..[2] = [header('c'), header('d')];
        // The server caps the first page at two albums, then an album added
        // during the scan shifts the list so 'c' comes back.
        api.newestPages
          ..clear()
          ..[0] = [header('d'), header('c')]
          ..[2] = [header('c'), header('b'), header('a')];

        final state = await localEngine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );

        expect(state.status, LibrarySyncStatus.succeeded);
        final ranks = {
          for (final album in await database.libraryDao.getAllAlbums())
            album.id: album.recentlyAddedRank,
        };
        expect(ranks, {'d': 0, 'c': 1, 'b': 3, 'a': 4});
      }, skip: !sqliteAvailable);

      test('fails a newest list that loops without new albums', () async {
        await saveSession();
        final localEngine = shiftedCatalogEngine();
        api.fastPathPages
          ..clear()
          ..[0] = [header('a'), header('b')]
          ..[2] = [header('c'), header('d')];
        api.newestPages
          ..clear()
          ..[0] = [header('d'), header('c')]
          ..[2] = [header('c'), header('d')];

        final state = await localEngine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );

        expect(state.status, LibrarySyncStatus.failed);
      }, skip: !sqliteAvailable);
    });

    test('catalog snapshot revalidates its boundary before resuming committed pages', () async {
      await saveSession();
      api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
      api.fastPathPages[0] = const <Album>[
        Album(id: 'album-1', name: 'Album 1', artistId: 'artist-1'),
        Album(id: 'album-2', name: 'Album 2', artistId: 'artist-1'),
      ];
      api.fastPathErrors[2] = const SubsonicConnectionException('offline');
      for (final id in <String>['album-1', 'album-2', 'album-3']) {
        api.albumDetails[id] = Album(
          id: id,
          name: id,
          artistId: 'artist-1',
          songs: <Song>[],
        );
      }
      final localEngine = DriftLibrarySyncEngine(
        api: api,
        database: database,
        serverConfigRepository: serverConfigRepository,
        fastPathPageSize: 2,
        fallbackArtistConcurrency: 1,
        wifiAlbumConcurrency: 1,
        cellularAlbumConcurrency: 1,
        otherAlbumConcurrency: 1,
        writeChunkSize: 4,
      );

      final interrupted = await localEngine.executeSyncPlan(
        syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
      );
      expect(interrupted.status, LibrarySyncStatus.failed);
      expect(
        (await database.librarySyncDao.getOrCreateState(1)).currentGeneration,
        0,
      );

      api.fastPathErrors.remove(2);
      api.fastPathPages[2] = const <Album>[
        Album(id: 'album-3', name: 'Album 3', artistId: 'artist-1'),
      ];
      final resumed = await localEngine.executeSyncPlan(
        syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
      );

      expect(resumed.status, LibrarySyncStatus.succeeded);
      expect(
        api.calls.where((call) => call == 'getAlbumListPage:0:2'),
        hasLength(2),
      );
      expect(
        api.calls.where((call) => call == 'getAlbumListPage:2:2'),
        hasLength(2),
      );
      expect(
        (await database.librarySyncDao.getOrCreateState(1)).currentGeneration,
        1,
      );
    }, skip: !sqliteAvailable);

    for (final boundary in [0, 2]) {
      test(
        'changed saved boundary $boundary rebuilds the interrupted candidate',
        () async {
          await saveSession();
          api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
          Album header(String id) =>
              Album(id: id, name: id, artistId: 'artist-1');
          api.fastPathPages[0] = [header('a'), header('b')];
          api.fastPathPages[2] = [header('c'), header('d')];
          api.fastPathErrors[4] = const SubsonicConnectionException('offline');
          for (final id in ['a', 'b', 'c', 'd', 'e', 'replacement']) {
            api.albumDetails[id] = header(id);
          }
          final localEngine = DriftLibrarySyncEngine(
            api: api,
            database: database,
            serverConfigRepository: serverConfigRepository,
            fastPathPageSize: 2,
          );
          expect(
            (await localEngine.executeSyncPlan(
              syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
            )).status,
            LibrarySyncStatus.failed,
          );
          final removed = api.fastPathPages[boundary]!.first.id;
          api.fastPathPages[boundary] = [
            header('replacement'),
            api.fastPathPages[boundary]!.last,
          ];
          api.fastPathErrors.clear();
          api.fastPathPages[4] = [header('e')];
          expect(
            (await localEngine.executeSyncPlan(
              syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
            )).status,
            LibrarySyncStatus.succeeded,
          );
          final ids = (await database.libraryDao.getAllAlbums())
              .map((row) => row.id)
              .toSet();
          expect(ids, hasLength(5));
          expect(ids, contains('replacement'));
          expect(ids, isNot(contains(removed)));
        },
        skip: !sqliteAvailable,
      );
    }

    test(
      'fresh candidate discards stale checkpoints for a reused generation',
      () async {
        await saveSession();
        await database.librarySyncDao.enqueueWork(
          serverId: 1,
          kind: 'catalogAlbumPage',
          entityId: '1:0',
          priority: 40,
        );
        final staleWork = await database.librarySyncDao.getWork(
          serverId: 1,
          kind: 'catalogAlbumPage',
          entityId: '1:0',
        );
        await database.librarySyncDao.updateCheckpoint(
          staleWork!.id,
          checkpointJson: jsonEncode(<String, Object>{
            'count': 1,
            'hasMore': false,
            'signature': 'stale',
          }),
        );
        await database.librarySyncDao.markCompleted(
          staleWork.id,
          preserveCheckpoint: true,
        );
        api.artists.add(
          const Artist(id: 'artist-1', name: 'Artist 1', albumCount: 1),
        );
        api.fastPathPages[0] = const <Album>[
          Album(id: 'album-1', name: 'Album 1', artistId: 'artist-1'),
        ];
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          artistId: 'artist-1',
          songs: <Song>[],
        );

        final state = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );
        final albums = await database.libraryDao.getAllAlbums();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(api.calls, contains('getAlbumListPage:0:500'));
        expect(albums.single.id, 'album-1');
      },
      skip: !sqliteAvailable,
    );

    test(
      'candidate with reported albums cannot promote an empty album catalog',
      () async {
        await saveSession();
        await database.libraryDao.replaceArtists(<ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(id: 'existing-artist', name: 'Artist'),
        ]);
        await database.libraryDao.replaceAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'existing-album',
            name: 'Existing Album',
            artistId: const Value('existing-artist'),
          ),
        ]);
        api.artists.add(
          const Artist(id: 'artist-1', name: 'Artist 1', albumCount: 1),
        );

        final state = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );
        final albums = await database.libraryDao.getAllAlbums();

        expect(state.status, LibrarySyncStatus.failed);
        expect(albums.single.id, 'existing-album');
        expect(
          (await database.librarySyncDao.getOrCreateState(1)).currentGeneration,
          0,
        );
      },
      skip: !sqliteAvailable,
    );

    test('fast-path fallback uses per-artist expansion when endpoint is unsupported', () async {
      await saveSession();
      api.throwOnFastPath = const SubsonicNotFoundException(message: 'missing');
      api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
      api.artistDetails['artist-1'] = const Artist(
        id: 'artist-1',
        name: 'Artist 1',
        albums: <Album>[
          Album(
            id: 'album-1',
            name: 'Album 1',
            artist: 'Artist 1',
            artistId: 'artist-1',
          ),
        ],
      );
      api.albumDetails['album-1'] = const Album(
        id: 'album-1',
        name: 'Album 1',
        songs: <Song>[Song(id: 'song-1', title: 'Song 1')],
      );

      final state = await engine.executeSyncPlan(
        syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
      );

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(api.calls, contains('getArtist:artist-1'));
    }, skip: !sqliteAvailable);

    test('bulk song fast path hydrates songs without per-album requests when compatible', () async {
      await saveSession();
      api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
      api.fastPathPages[0] = List<Album>.generate(
        9,
        (index) => Album(
          id: 'album-${index + 1}',
          name: 'Album ${index + 1}',
          artistId: 'artist-1',
          artist: 'Artist 1',
          songCount: 1,
        ),
      );
      api.bulkSongPages[0] = List<Song>.generate(
        9,
        (index) => Song(
          id: 'song-${index + 1}',
          title: 'Song ${index + 1}',
          albumId: 'album-${index + 1}',
          artistId: 'artist-1',
        ),
      );

      final state = await engine.executeSyncPlan(
        syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
      );
      final songs = await database.select(database.songsTable).get();

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(api.calls, contains('searchSongsPage::0:1'));
      expect(api.calls, contains('searchSongsPage::0:1000'));
      expect(api.calls.where((call) => call.startsWith('getAlbum:')), isEmpty);
      expect(songs.length, 9);
    }, skip: !sqliteAvailable);

    test(
      'bulk song fast path continues after a server silently caps page size',
      () async {
        await saveSession();
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = List<Album>.generate(
          4,
          (index) => Album(
            id: 'album-${index + 1}',
            name: 'Album ${index + 1}',
            artistId: 'artist-1',
            artist: 'Artist 1',
            songCount: 1,
          ),
        );
        api.bulkSongPages[0] = List<Song>.generate(
          2,
          (index) => Song(
            id: 'song-${index + 1}',
            title: 'Song ${index + 1}',
            albumId: 'album-${index + 1}',
            artistId: 'artist-1',
          ),
        );
        api.bulkSongPages[2] = List<Song>.generate(
          2,
          (index) => Song(
            id: 'song-${index + 3}',
            title: 'Song ${index + 3}',
            albumId: 'album-${index + 3}',
            artistId: 'artist-1',
          ),
        );
        final cappedPageEngine = DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          fastPathPageSize: 4,
          bulkSearchPageSize: 3,
          writeChunkSize: 2,
        );

        final state = await cappedPageEngine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );
        final songs = await database.select(database.songsTable).get();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(api.calls, contains('searchSongsPage::0:3'));
        expect(api.calls, contains('searchSongsPage::2:3'));
        expect(
          api.calls.where((call) => call.startsWith('getAlbum:')),
          isEmpty,
        );
        expect(songs, hasLength(4));
      },
      skip: !sqliteAvailable,
    );

    test(
      'bulk song fast path emits incremental hydration progress updates',
      () async {
        await saveSession();
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = List<Album>.generate(
          9,
          (index) => Album(
            id: 'album-${index + 1}',
            name: 'Album ${index + 1}',
            artistId: 'artist-1',
            artist: 'Artist 1',
            songCount: 1,
          ),
        );
        api.bulkSongPages[0] = List<Song>.generate(
          3,
          (index) => Song(
            id: 'song-${index + 1}',
            title: 'Song ${index + 1}',
            albumId: 'album-${index + 1}',
            artistId: 'artist-1',
          ),
        );
        api.bulkSongPages[3] = List<Song>.generate(
          3,
          (index) => Song(
            id: 'song-${index + 4}',
            title: 'Song ${index + 4}',
            albumId: 'album-${index + 4}',
            artistId: 'artist-1',
          ),
        );
        api.bulkSongPages[6] = List<Song>.generate(
          3,
          (index) => Song(
            id: 'song-${index + 7}',
            title: 'Song ${index + 7}',
            albumId: 'album-${index + 7}',
            artistId: 'artist-1',
          ),
        );

        final bulkEngine = DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          fallbackArtistConcurrency: 1,
          wifiAlbumConcurrency: 1,
          cellularAlbumConcurrency: 1,
          otherAlbumConcurrency: 1,
          bulkSearchPageSize: 3,
          writeChunkSize: 4,
        );

        final progress = <LibrarySyncState>[];
        await bulkEngine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
          onProgress: progress.add,
        );

        final hydrationProgress = progress
            .where((state) => state.stage == LibrarySyncStage.fetchingSongs)
            .where((state) => state.processed != null)
            .map((state) => state.processed!)
            .toList(growable: false);

        expect(hydrationProgress, isNotEmpty);
        expect(hydrationProgress.any((count) => count > 0), isTrue);
        expect(hydrationProgress.last, greaterThanOrEqualTo(9));
        final indexedSongs = progress
            .where((state) => state.fastPathActive)
            .map((state) => state.songIndexEntriesScanned)
            .toList(growable: false);
        expect(indexedSongs, containsAllInOrder(<int>[3, 6, 9]));
      },
      skip: !sqliteAvailable,
    );

    test(
      'carries forward a stable bulk-index tail before album-detail fallback',
      () async {
        await saveSession();
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = const <Album>[
          Album(
            id: 'album-1',
            name: 'Album 1',
            artist: 'Artist 1',
            artistId: 'artist-1',
            songCount: 1,
          ),
          Album(
            id: 'album-2',
            name: 'Album 2',
            artist: 'Artist 1',
            artistId: 'artist-1',
            songCount: 1,
          ),
        ];
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          artist: 'Artist 1',
          artistId: 'artist-1',
          songs: <Song>[
            Song(id: 'song-1', title: 'Song 1', artistId: 'artist-1'),
          ],
        );
        api.albumDetails['album-2'] = const Album(
          id: 'album-2',
          name: 'Album 2',
          artist: 'Artist 1',
          artistId: 'artist-1',
          songs: <Song>[
            Song(id: 'song-2', title: 'Song 2', artistId: 'artist-1'),
          ],
        );

        // Seed the committed catalog through the authoritative fallback: the
        // completed bulk index omits both candidate albums.
        api.bulkSongPages[0] = const <Song>[
          Song(
            id: 'unrelated-song',
            title: 'Unrelated song',
            albumId: 'unrelated-album',
            artistId: 'artist-1',
          ),
        ];
        final tailEngine = DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          fallbackArtistConcurrency: 1,
          wifiAlbumConcurrency: 1,
          cellularAlbumConcurrency: 1,
          otherAlbumConcurrency: 1,
          writeChunkSize: 1,
        );
        await tailEngine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );

        // The compatible bulk index now completes but omits album-1, as a
        // capped global song index does. Its unchanged hydrated local songs
        // should be reused without another getAlbum call.
        api.calls.clear();
        final result = await tailEngine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.catalogSnapshot),
        );

        expect(result.status, LibrarySyncStatus.succeeded);
        expect(api.calls, contains('searchSongsPage::0:1000'));
        expect(api.calls.where((call) => call == 'getAlbum:album-1'), isEmpty);
        expect(api.calls.where((call) => call == 'getAlbum:album-2'), isEmpty);
        final songs = await database.select(database.songsTable).get();
        expect(songs.map((song) => song.id), contains('song-1'));

        // Explicit repair re-fetches even an unchanged stable tail.
        api.calls.clear();
        final repair = await tailEngine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );
        expect(repair.status, LibrarySyncStatus.succeeded);
        expect(api.calls, contains('getAlbum:album-1'));
        expect(api.calls, contains('getAlbum:album-2'));
      },
      skip: !sqliteAvailable,
    );

    test(
      'bulk song hydration progress never counts observed albums as complete',
      () async {
        await saveSession();
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = const <Album>[
          Album(
            id: 'album-1',
            name: 'Album 1',
            artist: 'Artist 1',
            artistId: 'artist-1',
            songCount: 2,
          ),
          Album(
            id: 'album-2',
            name: 'Album 2',
            artist: 'Artist 1',
            artistId: 'artist-1',
            songCount: 2,
          ),
        ];
        api.bulkSongPages[0] = const <Song>[
          Song(
            id: 'song-1',
            title: 'Song 1',
            albumId: 'album-1',
            artistId: 'artist-1',
          ),
          Song(
            id: 'song-3',
            title: 'Song 3',
            albumId: 'album-2',
            artistId: 'artist-1',
          ),
        ];
        api.bulkSongPages[2] = const <Song>[
          Song(
            id: 'song-2',
            title: 'Song 2',
            albumId: 'album-1',
            artistId: 'artist-1',
          ),
        ];
        api.albumDetails['album-2'] = const Album(
          id: 'album-2',
          name: 'Album 2',
          artist: 'Artist 1',
          artistId: 'artist-1',
          songs: <Song>[
            Song(id: 'song-3', title: 'Song 3', artistId: 'artist-1'),
            Song(id: 'song-4', title: 'Song 4', artistId: 'artist-1'),
          ],
        );

        final bulkEngine = DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          fallbackArtistConcurrency: 1,
          wifiAlbumConcurrency: 1,
          cellularAlbumConcurrency: 1,
          otherAlbumConcurrency: 1,
          bulkSearchPageSize: 2,
          writeChunkSize: 1,
        );

        final progress = <LibrarySyncState>[];
        final result = await bulkEngine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
          onProgress: progress.add,
        );

        final hydrationProgress = progress
            .where((state) => state.stage == LibrarySyncStage.fetchingSongs)
            .where((state) => state.processed != null)
            .map((state) => state.processed!)
            .toList(growable: false);

        expect(result.status, LibrarySyncStatus.succeeded);
        expect(hydrationProgress, isNotEmpty);
        for (var index = 1; index < hydrationProgress.length; index++) {
          expect(
            hydrationProgress[index],
            greaterThanOrEqualTo(hydrationProgress[index - 1]),
            reason: 'Durable hydration progress must not move backwards.',
          );
        }
      },
      skip: !sqliteAvailable,
    );

    test('bulk song fast path maps pages without detail requests', () async {
      await saveSession();
      api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
      api.fastPathPages[0] = List<Album>.generate(
        9,
        (index) => Album(
          id: 'album-${index + 1}',
          name: 'Album ${index + 1}',
          artistId: 'artist-1',
          artist: 'Artist 1',
          songCount: 1,
        ),
      );
      api.bulkSongPages[0] = List<Song>.generate(
        9,
        (index) => Song(
          id: 'song-${index + 1}',
          title: 'Song ${index + 1}',
          albumId: 'album-${index + 1}',
          artistId: 'artist-1',
        ),
      );

      final bulkEngine = DriftLibrarySyncEngine(
        api: api,
        database: database,
        serverConfigRepository: serverConfigRepository,
        fallbackArtistConcurrency: 1,
        wifiAlbumConcurrency: 1,
        cellularAlbumConcurrency: 1,
        otherAlbumConcurrency: 1,
        writeChunkSize: 4,
      );

      final state = await bulkEngine.executeSyncPlan(
        syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
      );
      final songs = await database.select(database.songsTable).get();

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(api.calls.where((call) => call.startsWith('getAlbum:')), isEmpty);
      expect(songs.length, 9);
    }, skip: !sqliteAvailable);

    test(
      'bulk song fast path with replay gain keeps fast-path hydration active',
      () async {
        await saveSession();
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = List<Album>.generate(
          9,
          (index) => Album(
            id: 'album-${index + 1}',
            name: 'Album ${index + 1}',
            artistId: 'artist-1',
            artist: 'Artist 1',
            songCount: 1,
          ),
        );
        api.bulkSongPages[0] = List<Song>.generate(
          9,
          (index) => Song(
            id: 'song-${index + 1}',
            title: 'Song ${index + 1}',
            albumId: 'album-${index + 1}',
            artistId: 'artist-1',
            replayGain: const ReplayGain(
              trackGain: -4.5,
              albumGain: -3,
              trackPeak: 0.92,
              albumPeak: 0.95,
            ),
          ),
        );

        final bulkEngine = DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          fallbackArtistConcurrency: 1,
          wifiAlbumConcurrency: 1,
          cellularAlbumConcurrency: 1,
          otherAlbumConcurrency: 1,
          writeChunkSize: 4,
        );

        final state = await bulkEngine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );
        final songs = await database.select(database.songsTable).get();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(
          api.calls.where((call) => call.startsWith('getAlbum:')),
          isEmpty,
        );
        expect(songs.length, 9);
        expect(songs.first.replayGainTrackGain, -4.5);
        expect(songs.first.replayGainAlbumGain, -3.0);
        expect(songs.first.replayGainTrackPeak, 0.92);
        expect(songs.first.replayGainAlbumPeak, 0.95);
      },
      skip: !sqliteAvailable,
    );

    test(
      'bulk song fast path gracefully falls back to per-album hydration',
      () async {
        await saveSession();
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = List<Album>.generate(
          9,
          (index) => Album(
            id: 'album-${index + 1}',
            name: 'Album ${index + 1}',
            artistId: 'artist-1',
          ),
        );
        api.throwOnSongSearch = const SubsonicGenericException(
          message: 'search unavailable',
        );
        for (var index = 0; index < 9; index++) {
          final albumId = 'album-${index + 1}';
          api.albumDetails[albumId] = Album(
            id: albumId,
            name: 'Album ${index + 1}',
            songs: <Song>[Song(id: 'song-${index + 1}', title: 'Song')],
          );
        }

        final state = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(
          api.calls.where((call) => call.startsWith('getAlbum:')).length,
          greaterThan(0),
        );
      },
      skip: !sqliteAvailable,
    );

    for (final fails in [false, true]) {
      test(
        'bulk capability writes preserve fresh updates (failure: $fails)',
        () async {
          await saveSession(
            capabilitiesJson: jsonEncode({
              'navis': {'bulkSongSearchWildcardQuery': ''},
            }),
          );
          final bulkApi = _BulkPageLibrarySyncApi();
          bulkApi.artists.add(const Artist(id: 'artist-1', name: 'Artist'));
          bulkApi.fastPathPages[0] = const [
            Album(
              id: 'album-1',
              name: 'Album',
              artistId: 'artist-1',
              songCount: 1,
            ),
          ];
          const song = Song(
            id: 'song-1',
            title: 'Song',
            albumId: 'album-1',
            artistId: 'artist-1',
          );
          bulkApi.bulkSongPages[0] = const [song];
          bulkApi.albumDetails['album-1'] = const Album(
            id: 'album-1',
            name: 'Album',
            songs: [song],
          );
          bulkApi.onBulkPage = () async {
            final config = await serverConfigRepository.getActiveServer();
            final capabilities =
                jsonDecode(config!.capabilitiesJson!) as Map<String, dynamic>;
            capabilities['provider'] = {'retained': true};
            (capabilities['navis'] as Map<String, dynamic>)['duringBulk'] =
                'retained';
            await serverConfigRepository.updateCapabilitiesJson(
              jsonEncode(capabilities),
            );
            if (fails) {
              throw const SubsonicGenericException(message: 'Unsupported');
            }
          };
          final bulkEngine = DriftLibrarySyncEngine(
            api: bulkApi,
            database: database,
            serverConfigRepository: serverConfigRepository,
          );

          final state = await bulkEngine.executeSyncPlan(
            syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
          );

          expect(state.status, LibrarySyncStatus.succeeded);
          final config = await serverConfigRepository.getActiveServer();
          final capabilities =
              jsonDecode(config!.capabilitiesJson!) as Map<String, dynamic>;
          final navis = capabilities['navis'] as Map<String, dynamic>;
          expect(capabilities['provider'], {'retained': true});
          expect(navis['duringBulk'], 'retained');
          expect(navis['bulkSongSearchWildcardQuery'], fails ? isNull : '');
          expect(await database.libraryDao.getSongById('song-1'), isNotNull);
        },
        skip: !sqliteAvailable,
      );
    }

    test(
      'index traversal preserves first raw duplicate and stable fingerprint',
      () async {
        await saveSession();
        api.getArtistsError = const SubsonicNotFoundException(
          message: 'Unsupported',
        );
        api.indexes = Indexes(
          lastModified: DateTime(2026),
          indexes: const [
            IndexesIndex(
              name: 'A',
              artists: [
                Artist(id: ' artist-1 ', name: 'First'),
                Artist(id: ' artist-1 ', name: 'Last'),
              ],
            ),
          ],
          shortcut: const [Artist(id: 'artist-2', name: 'Shortcut')],
          child: const [Artist(id: 'artist-2', name: 'Child')],
        );

        final state = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );

        expect(state.status, LibrarySyncStatus.succeeded);
        final artists = await database.libraryDao.getAllArtists();
        expect(
          {for (final artist in artists) artist.id: artist.name},
          {' artist-1 ': 'First', 'artist-2': 'Shortcut'},
        );
        final config = await serverConfigRepository.getActiveServer();
        final navis =
            (jsonDecode(config!.capabilitiesJson!)
                    as Map<String, dynamic>)['navis']
                as Map<String, dynamic>;
        expect(
          navis['libraryIndexesFingerprint'],
          _testIndexesFingerprint(['artist-1', 'artist-2']),
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'stored bulk-song query is reused for small pending hydration batches',
      () async {
        await saveSession(
          capabilitiesJson: jsonEncode(<String, Object?>{
            'navis': <String, Object?>{'bulkSongSearchWildcardQuery': ''},
          }),
        );
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = const <Album>[
          Album(
            id: 'album-1',
            name: 'Album 1',
            artistId: 'artist-1',
            artist: 'Artist 1',
            songCount: 1,
          ),
        ];
        api.bulkSongPages[0] = const <Song>[
          Song(
            id: 'song-1',
            title: 'Song 1',
            albumId: 'album-1',
            artistId: 'artist-1',
          ),
        ];

        final state = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(api.calls, contains('searchSongsPage::0:1'));
        expect(
          api.calls.where((call) => call.startsWith('getAlbum:')),
          isEmpty,
        );
      },
      skip: !sqliteAvailable,
    );

    test('bulk song fast path hydrates complete albums and falls back for partial albums', () async {
      await saveSession();
      api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
      api.fastPathPages[0] = const <Album>[
        Album(
          id: 'album-1',
          name: 'Album 1',
          artistId: 'artist-1',
          songCount: 2,
        ),
        Album(
          id: 'album-2',
          name: 'Album 2',
          artistId: 'artist-1',
          songCount: 2,
        ),
      ];
      api.bulkSongPages[0] = const <Song>[
        Song(
          id: 'song-1a',
          title: 'Song 1a',
          albumId: 'album-1',
          artistId: 'artist-1',
        ),
        Song(
          id: 'song-2a',
          title: 'Song 2a',
          albumId: 'album-2',
          artistId: 'artist-1',
        ),
        Song(
          id: 'song-2b',
          title: 'Song 2b',
          albumId: 'album-2',
          artistId: 'artist-1',
        ),
      ];
      api.albumDetails['album-1'] = const Album(
        id: 'album-1',
        name: 'Album 1',
        songs: <Song>[
          Song(
            id: 'song-1a',
            title: 'Song 1a',
            albumId: 'album-1',
            artistId: 'artist-1',
          ),
          Song(
            id: 'song-1b',
            title: 'Song 1b',
            albumId: 'album-1',
            artistId: 'artist-1',
          ),
        ],
      );

      final bulkEnabledEngine = DriftLibrarySyncEngine(
        api: api,
        database: database,
        serverConfigRepository: serverConfigRepository,
        fallbackArtistConcurrency: 1,
        wifiAlbumConcurrency: 1,
        cellularAlbumConcurrency: 1,
        otherAlbumConcurrency: 1,
        writeChunkSize: 1,
      );

      final state = await bulkEnabledEngine.executeSyncPlan(
        syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
      );
      final songs = await database.select(database.songsTable).get();

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(api.calls, contains('getAlbum:album-1'));
      expect(api.calls, isNot(contains('getAlbum:album-2')));
      expect(
        songs.map((song) => song.id).toSet(),
        containsAll(<String>{'song-1a', 'song-1b', 'song-2a', 'song-2b'}),
      );
    }, skip: !sqliteAvailable);

    test('bulk song fast path reconciles complete album song sets', () async {
      await saveSession(
        capabilitiesJson: jsonEncode(<String, Object?>{
          'navis': <String, Object?>{'bulkSongSearchWildcardQuery': ''},
        }),
      );
      api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
      await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist 1'),
      ]);
      await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(
          id: 'album-1',
          name: 'Album 1',
          artistId: const Value('artist-1'),
          songCount: const Value(2),
          songsHydrated: const Value(true),
        ),
        AlbumsTableCompanion.insert(
          id: 'album-empty',
          name: 'Album Empty',
          artistId: const Value('artist-1'),
          songCount: const Value(1),
          songsHydrated: const Value(true),
        ),
      ]);
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(
          id: 'song-old',
          title: 'Old Song',
          albumId: const Value('album-1'),
        ),
        SongsTableCompanion.insert(
          id: 'song-empty-old',
          title: 'Empty Old Song',
          albumId: const Value('album-empty'),
        ),
      ]);
      api.fastPathPages[0] = const <Album>[
        Album(
          id: 'album-1',
          name: 'Album 1',
          artistId: 'artist-1',
          songCount: 1,
        ),
        Album(
          id: 'album-empty',
          name: 'Album Empty',
          artistId: 'artist-1',
          songCount: 0,
        ),
      ];
      api.bulkSongPages[0] = const <Song>[
        Song(
          id: 'song-new',
          title: 'New Song',
          albumId: 'album-1',
          artistId: 'artist-1',
        ),
      ];

      final state = await engine.executeSyncPlan(
        syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
      );
      final songs = await database.select(database.songsTable).get();

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(api.calls, contains('searchSongsPage::0:1000'));
      expect(api.calls.where((call) => call.startsWith('getAlbum:')), isEmpty);
      expect(songs.map((song) => song.id).toSet(), <String>{'song-new'});
    }, skip: !sqliteAvailable);

    test(
      'song hydration tolerates unknown artist ids by storing null artistId',
      () async {
        await saveSession();
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = const <Album>[
          Album(
            id: 'album-1',
            name: 'Album 1',
            artistId: 'artist-1',
            artist: 'Artist 1',
          ),
        ];
        api.bulkSongPages[0] = const <Song>[
          Song(
            id: 'song-unknown-artist',
            title: 'Song Unknown Artist',
            albumId: 'album-1',
            artistId: 'artist-missing',
            artist: 'Missing Artist',
          ),
        ];
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          songs: <Song>[
            Song(
              id: 'song-unknown-artist',
              title: 'Song Unknown Artist',
              albumId: 'album-1',
              artistId: 'artist-missing',
              artist: 'Missing Artist',
            ),
          ],
        );

        final state = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );
        final songs = await database.select(database.songsTable).get();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(songs, hasLength(1));
        expect(songs.single.id, 'song-unknown-artist');
        expect(songs.single.artistId, isNull);
        expect(songs.single.artistName, 'Missing Artist');
      },
      skip: !sqliteAvailable,
    );

    test('staleness gate skips sync when session is fresh', () async {
      await saveSession(
        lastSynced: DateTime.now(),
        lastFullSyncedAt: DateTime.now(),
      );

      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: const Value(1),
          currentGeneration: const Value(1),
          providerFingerprint: const Value('https://example.com|1.16.1'),
          lastCheckedAt: Value(DateTime.now()),
          lastAuditAt: Value(DateTime.now()),
          lastAuxiliarySyncedAt: Value(DateTime.now()),
        ),
      );
      for (final target in [
        const LibrarySyncTarget.starred(),
        const LibrarySyncTarget.playlistHeaders(),
      ]) {
        await database.librarySyncDao.enqueueWork(
          serverId: 1,
          kind: LibrarySyncPlanKind.targetedHydration.name,
          entityId: librarySyncTargetWorkKey(target),
          priority: 1,
        );
        final work = await database.librarySyncDao.getWork(
          serverId: 1,
          kind: LibrarySyncPlanKind.targetedHydration.name,
          entityId: librarySyncTargetWorkKey(target),
        );
        await database.librarySyncDao.markCompleted(work!.id);
      }
      final coordinator = AdaptiveLibrarySyncCoordinator(
        executor: engine,
        database: database,
        serverConfigRepository: serverConfigRepository,
        networkType: NetworkType.other,
        staleAfter: const Duration(hours: 1),
        readHasActivePlayback: () => false,
      );
      final state = await coordinator.requestSync(
        const LibrarySyncRequest.automatic(),
      );

      expect(state.status, LibrarySyncStatus.skipped);
      expect(api.calls, isEmpty);
    }, skip: !sqliteAvailable);

    test('incremental sync only requests changed artists/albums', () async {
      await saveSession(
        lastSynced: DateTime.now().subtract(const Duration(hours: 2)),
        lastFullSyncedAt: DateTime.now(),
      );
      await database.libraryDao.replaceArtists(<ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(id: 'artist-old', name: 'Artist Old'),
      ]);
      api.indexes = const Indexes(
        indexes: <IndexesIndex>[
          IndexesIndex(
            name: 'A',
            artists: <Artist>[Artist(id: 'artist-1', name: 'Artist 1')],
          ),
        ],
      );
      api.notFoundArtistIds.add('artist-old');
      api.artistDetails['artist-1'] = const Artist(
        id: 'artist-1',
        name: 'Artist 1',
        albums: <Album>[
          Album(
            id: 'album-1',
            name: 'Album 1',
            artist: 'Artist 1',
            artistId: 'artist-1',
          ),
        ],
      );
      api.albumDetails['album-1'] = const Album(
        id: 'album-1',
        name: 'Album 1',
        songs: <Song>[Song(id: 'song-1', title: 'Song 1', albumId: 'album-1')],
      );

      final state = await engine.executeSyncPlan(
        syncPlanForTest(
          SyncExecutionPlanKind.manualCatalogDiscovery,
          intent: SyncRunIntent.automaticCatalogCheck,
        ),
      );

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(state.mode, LibrarySyncMode.incremental);
      expect(api.calls, contains('getIndexes'));
      expect(api.calls, contains('getArtist:artist-1'));
      expect(api.calls, contains('getArtist:artist-old'));
      expect(api.calls, contains('getAlbum:album-1'));
    }, skip: !sqliteAvailable);

    test(
      'server cursor survives clock skew and advances only after completion',
      () async {
        final serverCursor = DateTime.utc(2020, 1, 2);
        await saveSession(
          lastSynced: DateTime.now().subtract(const Duration(hours: 2)),
          lastFullSyncedAt: DateTime.now(),
        );
        api.indexes = Indexes(lastModified: serverCursor);

        final state = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.manualCatalogDiscovery),
        );
        final config = await serverConfigRepository.getActiveServer();
        final capabilities =
            jsonDecode(config!.capabilitiesJson!) as Map<String, dynamic>;
        final navis = capabilities['navis'] as Map<String, dynamic>;

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(api.requestedIndexesCursors.single, isNull);
        expect(
          DateTime.parse(navis['libraryIndexesCursor'] as String).toUtc(),
          serverCursor,
        );
        expect(config.lastSynced!.isAfter(serverCursor), isTrue);
      },
      skip: !sqliteAvailable,
    );

    test(
      'full index snapshot drains across bounded verification passes',
      () async {
        await saveSession(
          lastSynced: DateTime.now().subtract(const Duration(hours: 2)),
          lastFullSyncedAt: DateTime.now(),
        );
        final artists = List<Artist>.generate(
          170,
          (index) =>
              Artist(id: 'artist-${index + 1}', name: 'Artist ${index + 1}'),
        );
        api.indexes = Indexes(
          lastModified: DateTime.utc(2026, 2, 1),
          indexes: <IndexesIndex>[IndexesIndex(name: 'A', artists: artists)],
        );
        for (final artist in artists) {
          api.artistDetails[artist.id] = artist;
        }

        final first = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.manualCatalogDiscovery),
        );
        final firstArtistCalls = api.calls
            .where((call) => call.startsWith('getArtist:'))
            .length;

        expect(first.status, LibrarySyncStatus.succeeded);
        expect(firstArtistCalls, 48);
        expect(first.remainingVerificationCount, 122);
        expect(first.freshness, LibrarySyncFreshness.verificationPending);
        var config = await serverConfigRepository.getActiveServer();
        var navis =
            jsonDecode(config!.capabilitiesJson!)['navis']
                as Map<String, dynamic>;
        expect(navis['libraryIndexesCursor'], isNull);

        var next = first;
        final continuationCallCounts = <int>[];
        while (next.remainingVerificationCount > 0) {
          api.calls.clear();
          next = await engine.executeSyncPlan(
            syncPlanForTest(
              SyncExecutionPlanKind.manualCatalogDiscovery,
              intent: SyncRunIntent.automaticCatalogCheck,
            ),
          );
          continuationCallCounts.add(
            api.calls.where((call) => call.startsWith('getArtist:')).length,
          );
        }

        expect(continuationCallCounts, <int>[24, 24, 24, 24, 24, 2]);
        expect(next.status, LibrarySyncStatus.succeeded);
        expect(next.remainingVerificationCount, 0);
        expect(next.freshness, LibrarySyncFreshness.current);
        config = await serverConfigRepository.getActiveServer();
        navis =
            jsonDecode(config!.capabilitiesJson!)['navis']
                as Map<String, dynamic>;
        expect(navis['libraryIndexesCursor'], isNotNull);
        expect(api.requestedIndexesCursors, everyElement(isNull));
      },
      skip: !sqliteAvailable,
    );

    test(
      'new cursor preserves the unverified artist tail before restarting audit',
      () async {
        await saveSession(
          lastSynced: DateTime.now().subtract(const Duration(hours: 2)),
          lastFullSyncedAt: DateTime.now(),
        );
        final artists = List<Artist>.generate(
          100,
          (index) => Artist(
            id: 'artist-${index.toString().padLeft(3, '0')}',
            name: 'Artist $index',
          ),
        );
        for (final artist in artists) {
          api.artistDetails[artist.id] = artist;
        }
        api.indexes = Indexes(
          lastModified: DateTime.utc(2026, 2, 1),
          indexes: <IndexesIndex>[IndexesIndex(name: 'A', artists: artists)],
        );

        final first = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.manualCatalogDiscovery),
        );
        final firstIds = api.calls
            .where((call) => call.startsWith('getArtist:'))
            .map((call) => call.substring('getArtist:'.length))
            .toSet();
        expect(first.remainingVerificationCount, 52);

        const added = Artist(id: 'artist-new', name: 'Artist New');
        api.artistDetails[added.id] = added;
        api.indexes = Indexes(
          lastModified: DateTime.utc(2026, 2, 2),
          indexes: <IndexesIndex>[
            IndexesIndex(name: 'A', artists: <Artist>[added, ...artists]),
          ],
        );
        api.calls.clear();

        final second = await engine.executeSyncPlan(
          syncPlanForTest(
            SyncExecutionPlanKind.manualCatalogDiscovery,
            intent: SyncRunIntent.automaticCatalogCheck,
          ),
        );
        final secondIds = api.calls
            .where((call) => call.startsWith('getArtist:'))
            .map((call) => call.substring('getArtist:'.length))
            .toSet();

        expect(second.status, LibrarySyncStatus.succeeded);
        expect(secondIds, contains(added.id));
        expect(secondIds.intersection(firstIds), isEmpty);
        expect(second.remainingVerificationCount, 77);
      },
      skip: !sqliteAvailable,
    );

    test(
      'failed artist stays pending without advancing server cursor',
      () async {
        final previousLastSynced = DateTime.now().subtract(
          const Duration(hours: 2),
        );
        await saveSession(
          lastSynced: previousLastSynced,
          lastFullSyncedAt: DateTime.now(),
        );
        final storedLastSynced =
            (await serverConfigRepository.getActiveServer())!.lastSynced;
        api.indexes = Indexes(
          lastModified: DateTime.utc(2026, 3, 1),
          indexes: const <IndexesIndex>[
            IndexesIndex(
              artists: <Artist>[
                Artist(id: 'missing-detail', name: 'Missing Detail'),
              ],
            ),
          ],
        );

        final state = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.manualCatalogDiscovery),
        );
        final config = await serverConfigRepository.getActiveServer();
        final navis =
            jsonDecode(config!.capabilitiesJson!)['navis']
                as Map<String, dynamic>;
        final diagnostics = jsonDecode(
          navis['librarySyncFailureDiagnostics'] as String,
        ) as List<dynamic>;

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(state.freshness, LibrarySyncFreshness.verificationPending);
        expect(state.remainingVerificationCount, 1);
        expect(navis['libraryIndexesCursor'], isNull);
        expect(config.lastSynced, storedLastSynced);
        expect(diagnostics.single, containsPair('entityId', 'missing-detail'));
        expect(diagnostics.single, containsPair('endpoint', 'getArtist'));
        expect(diagnostics.single, containsPair('errorType', 'StateError'));

        api.artistDetails['missing-detail'] = const Artist(
          id: 'missing-detail',
          name: 'Recovered Detail',
          albums: <Album>[
            Album(
              id: 'album-pending',
              name: 'Pending Album',
              artistId: 'missing-detail',
            ),
          ],
        );
        api.albumErrors['album-pending'] = StateError(
          'malformed album response',
        );
        api.calls.clear();

        final artistRecovered = await engine.executeSyncPlan(
          syncPlanForTest(
            SyncExecutionPlanKind.manualCatalogDiscovery,
            intent: SyncRunIntent.automaticCatalogCheck,
          ),
        );
        final artistRecoveredConfig = await serverConfigRepository
            .getActiveServer();
        final artistRecoveredNavis =
            jsonDecode(artistRecoveredConfig!.capabilitiesJson!)['navis']
                as Map<String, dynamic>;

        expect(artistRecovered.status, LibrarySyncStatus.succeeded);
        expect(
          artistRecovered.freshness,
          LibrarySyncFreshness.verificationPending,
        );
        expect(artistRecovered.remainingVerificationCount, 0);
        expect(artistRecovered.pendingHydrationCount, 1);
        expect(api.calls.where((call) => call.startsWith('getArtist:')), [
          'getArtist:missing-detail',
        ]);
        expect(artistRecoveredNavis['libraryIndexesCursor'], isNull);

        api.albumErrors.remove('album-pending');
        api.albumDetails['album-pending'] = const Album(
          id: 'album-pending',
          name: 'Pending Album',
          artistId: 'missing-detail',
          songs: <Song>[
            Song(
              id: 'recovered-song',
              title: 'Recovered Song',
              albumId: 'album-pending',
            ),
          ],
        );
        api.indexes = Indexes(lastModified: DateTime.utc(2026, 4, 1));
        api.calls.clear();

        final recovered = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.targetHydration),
        );
        final recoveredConfig = await serverConfigRepository.getActiveServer();
        final recoveredNavis =
            jsonDecode(recoveredConfig!.capabilitiesJson!)['navis']
                as Map<String, dynamic>;

        expect(recovered.status, LibrarySyncStatus.succeeded);
        expect(recovered.freshness, LibrarySyncFreshness.current);
        expect(recovered.pendingHydrationCount, 0);
        expect(api.calls.where((call) => call.startsWith('getAlbum:')), [
          'getAlbum:album-pending',
        ]);
        expect(
          api.calls.any(
            (call) => call.startsWith('getArtist:') || call == 'getIndexes',
          ),
          isFalse,
        );
        expect(
          DateTime.parse(recoveredNavis['libraryIndexesCursor'] as String)
              .toUtc(),
          DateTime.utc(2026, 3, 1),
        );
        expect(recoveredNavis['librarySyncFailureDiagnostics'], isNull);
      },
      skip: !sqliteAvailable,
    );

    test('manual check discovers a new album under an existing artist despite a fresh unchanged index', () async {
      final cursor = FakeLibrarySyncApi.defaultIndexesCursor;
      await saveSession(
        lastSynced: DateTime.now().subtract(const Duration(hours: 2)),
        lastFullSyncedAt: DateTime.now(),
        capabilitiesJson: jsonEncode(<String, Object?>{
          'navis': <String, Object?>{
            'libraryIndexesCursor': cursor.toIso8601String(),
            'libraryHealthCheckedAt': DateTime.now().toUtc().toIso8601String(),
          },
        }),
      );
      api.indexes = Indexes(lastModified: cursor);
      await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(
          id: 'artist-existing',
          name: 'Existing Artist',
        ),
      ]);
      api.fastPathPages[0] = const <Album>[
        Album(
          id: 'album-new',
          name: 'New Album',
          artistId: 'artist-existing',
          artist: 'Existing Artist',
        ),
      ];
      api.artistDetails['artist-existing'] = const Artist(
        id: 'artist-existing',
        name: 'Existing Artist',
        albums: <Album>[
          Album(
            id: 'album-new',
            name: 'New Album',
            artistId: 'artist-existing',
            artist: 'Existing Artist',
          ),
        ],
      );
      api.albumDetails['album-new'] = const Album(
        id: 'album-new',
        name: 'New Album',
        artistId: 'artist-existing',
        artist: 'Existing Artist',
        songs: <Song>[Song(id: 'song-new', title: 'New Song')],
      );

      final state = await engine.executeSyncPlan(
        syncPlanForTest(SyncExecutionPlanKind.manualCatalogDiscovery),
      );

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(api.calls, contains('getAlbumListPage:0:100'));
      expect(api.calls, contains('getArtist:artist-existing'));
      expect(await database.libraryDao.getAlbumById('album-new'), isNotNull);
    }, skip: !sqliteAvailable);

    test('manual check scans beyond the first newest-album page', () async {
      final cursor = FakeLibrarySyncApi.defaultIndexesCursor;
      await saveSession(
        lastSynced: DateTime.now().subtract(const Duration(hours: 2)),
        lastFullSyncedAt: DateTime.now(),
        capabilitiesJson: jsonEncode(<String, Object?>{
          'navis': <String, Object?>{
            'libraryIndexesCursor': cursor.toIso8601String(),
            'libraryHealthCheckedAt': DateTime.now().toUtc().toIso8601String(),
          },
        }),
      );
      api.indexes = Indexes(lastModified: cursor);
      await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(
          id: 'artist-existing',
          name: 'Existing Artist',
        ),
      ]);
      final knownAlbums = List<Album>.generate(
        100,
        (index) => Album(
          id: 'album-known-$index',
          name: 'Known Album $index',
          artistId: 'artist-existing',
          artist: 'Existing Artist',
        ),
        growable: false,
      );
      await database.libraryDao.upsertAlbums(
        knownAlbums
            .map(
              (album) => AlbumsTableCompanion.insert(
                id: album.id,
                name: album.name,
                artistId: Value(album.artistId),
                artistName: Value(album.artist),
                songsHydrated: const Value(true),
              ),
            )
            .toList(growable: false),
      );
      api.fastPathPages[0] = knownAlbums;
      api.fastPathPages[100] = const <Album>[
        Album(
          id: 'album-new-on-second-page',
          name: 'New Album',
          artistId: 'artist-existing',
          artist: 'Existing Artist',
        ),
      ];
      api.artistDetails['artist-existing'] = const Artist(
        id: 'artist-existing',
        name: 'Existing Artist',
        albums: <Album>[
          Album(
            id: 'album-new-on-second-page',
            name: 'New Album',
            artistId: 'artist-existing',
            artist: 'Existing Artist',
          ),
        ],
      );
      api.albumDetails['album-new-on-second-page'] = const Album(
        id: 'album-new-on-second-page',
        name: 'New Album',
        artistId: 'artist-existing',
        songs: <Song>[Song(id: 'song-new', title: 'New Song')],
      );

      final state = await engine.executeSyncPlan(
        syncPlanForTest(SyncExecutionPlanKind.manualCatalogDiscovery),
      );

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(api.calls, contains('getAlbumListPage:100:100'));
      expect(
        await database.libraryDao.getAlbumById('album-new-on-second-page'),
        isNotNull,
      );
    }, skip: !sqliteAvailable);

    test(
      'metered manual discovery hydrates only a bounded newest-album subset',
      () async {
        await saveSession(lastSynced: DateTime.now());
        final meteredEngine = DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          networkType: NetworkType.cellular,
          readSyncNetworkPolicy: () => const SyncNetworkPolicy(
            networkType: NetworkType.cellular,
            isMetered: true,
            allowsBackgroundSync: false,
            allowsHardProbe: true,
            allowsInteractiveHydration: true,
          ),
          fallbackArtistConcurrency: 1,
          cellularAlbumConcurrency: 1,
          writeChunkSize: 4,
        );
        api.fastPathPages[0] = List<Album>.generate(
          5,
          (index) => Album(
            id: 'album-metered-$index',
            name: 'Metered Album $index',
            artistId: 'artist-metered',
            artist: 'Metered Artist',
            songCount: 1,
          ),
          growable: false,
        );
        for (var index = 0; index < 5; index++) {
          api.albumDetails['album-metered-$index'] = Album(
            id: 'album-metered-$index',
            name: 'Metered Album $index',
            artistId: 'artist-metered',
            songs: <Song>[
              Song(id: 'song-metered-$index', title: 'Metered song $index'),
            ],
          );
        }

        final state = await meteredEngine.executeSyncPlan(
          _meteredManualDiscoveryPlan,
        );

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(api.calls, contains('getAlbumListPage:0:50'));
        expect(
          api.calls.where((call) => call.startsWith('getArtist:')),
          isEmpty,
        );
        expect(
          api.calls.where((call) => call.startsWith('searchSongsPage:')),
          isEmpty,
        );
        expect(
          api.calls.where(
            (call) =>
                call.startsWith('getStarredContent') ||
                call.startsWith('getPlaylists') ||
                call.startsWith('getGenres'),
          ),
          isEmpty,
        );
        expect(
          api.calls.where((call) => call.startsWith('getAlbum:')),
          hasLength(3),
        );
        expect(
          await database.libraryDao.getSongById('song-metered-0'),
          isNotNull,
        );
        expect(await database.libraryDao.getSongById('song-metered-3'), isNull);
        expect(state.freshness, LibrarySyncFreshness.verificationPending);
      },
      skip: !sqliteAvailable,
    );

    test('capped metered discovery window records discovery debt', () async {
      await saveSession(lastSynced: DateTime.now());
      final meteredEngine = DriftLibrarySyncEngine(
        api: api,
        database: database,
        serverConfigRepository: serverConfigRepository,
        networkType: NetworkType.cellular,
        readSyncNetworkPolicy: () => const SyncNetworkPolicy(
          networkType: NetworkType.cellular,
          isMetered: true,
          allowsBackgroundSync: false,
          allowsHardProbe: true,
          allowsInteractiveHydration: true,
        ),
        fallbackArtistConcurrency: 1,
        cellularAlbumConcurrency: 1,
        writeChunkSize: 4,
      );
      // A full 50-album page of unknown content: the metered window caps
      // without ever reaching known content.
      api.fastPathPages[0] = List<Album>.generate(
        50,
        (index) => Album(
          id: 'album-debt-$index',
          name: 'Debt Album $index',
          artistId: 'artist-debt',
          artist: 'Debt Artist',
          songCount: 1,
        ),
        growable: false,
      );
      for (var index = 0; index < 3; index++) {
        api.albumDetails['album-debt-$index'] = Album(
          id: 'album-debt-$index',
          name: 'Debt Album $index',
          artistId: 'artist-debt',
          songs: <Song>[
            Song(id: 'song-debt-$index', title: 'Debt song $index'),
          ],
        );
      }

      final state = await meteredEngine.executeSyncPlan(
        _meteredManualDiscoveryPlan,
      );

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(state.probeDiscoveryDebtStreak, 1);
      final config = await serverConfigRepository.getActiveServer();
      final capabilities =
          jsonDecode(config!.capabilitiesJson!) as Map<String, dynamic>;
      expect((capabilities['navis'] as Map)['libraryDiscoveryDebtStreak'], '1');
    }, skip: !sqliteAvailable);

    test('reaching known content clears recorded discovery debt', () async {
      await saveSession(lastSynced: DateTime.now());
      final meteredEngine = DriftLibrarySyncEngine(
        api: api,
        database: database,
        serverConfigRepository: serverConfigRepository,
        networkType: NetworkType.cellular,
        readSyncNetworkPolicy: () => const SyncNetworkPolicy(
          networkType: NetworkType.cellular,
          isMetered: true,
          allowsBackgroundSync: false,
          allowsHardProbe: true,
          allowsInteractiveHydration: true,
        ),
        fallbackArtistConcurrency: 1,
        cellularAlbumConcurrency: 1,
        writeChunkSize: 4,
      );
      api.fastPathPages[0] = List<Album>.generate(
        50,
        (index) => Album(
          id: 'album-clear-$index',
          name: 'Clear Album $index',
          artistId: 'artist-clear',
          artist: 'Clear Artist',
          songCount: 1,
        ),
        growable: false,
      );
      for (var index = 0; index < 3; index++) {
        api.albumDetails['album-clear-$index'] = Album(
          id: 'album-clear-$index',
          name: 'Clear Album $index',
          artistId: 'artist-clear',
          songs: <Song>[
            Song(id: 'song-clear-$index', title: 'Clear song $index'),
          ],
        );
      }

      // First pass: everything is unknown, so debt is recorded.
      await meteredEngine.executeSyncPlan(_meteredManualDiscoveryPlan);
      // Second pass: the same window is now known and unchanged, so the
      // probe reaches known content and clears the debt.
      api.calls.clear();
      final state = await meteredEngine.executeSyncPlan(
        _meteredManualDiscoveryPlan,
      );

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(state.probeDiscoveryDebtStreak, 0);
      final config = await serverConfigRepository.getActiveServer();
      final capabilities =
          jsonDecode(config!.capabilitiesJson!) as Map<String, dynamic>;
      expect(
        (capabilities['navis'] as Map).containsKey(
          'libraryDiscoveryDebtStreak',
        ),
        isFalse,
      );
    }, skip: !sqliteAvailable);

    test(
      'a repeated capped window reaches the reconciliation escalation streak',
      () async {
        await saveSession(
          lastSynced: DateTime.now(),
          capabilitiesJson: jsonEncode(<String, Object?>{
            'navis': <String, Object?>{'libraryDiscoveryDebtStreak': '1'},
          }),
        );
        final meteredEngine = DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          networkType: NetworkType.cellular,
          readSyncNetworkPolicy: () => const SyncNetworkPolicy(
            networkType: NetworkType.cellular,
            isMetered: true,
            allowsBackgroundSync: false,
            allowsHardProbe: true,
            allowsInteractiveHydration: true,
          ),
          fallbackArtistConcurrency: 1,
          cellularAlbumConcurrency: 1,
          writeChunkSize: 4,
        );
        api.fastPathPages[0] = List<Album>.generate(
          50,
          (index) => Album(
            id: 'album-escalate-$index',
            name: 'Escalate Album $index',
            artistId: 'artist-escalate',
            artist: 'Escalate Artist',
            songCount: 1,
          ),
          growable: false,
        );
        for (var index = 0; index < 3; index++) {
          api.albumDetails['album-escalate-$index'] = Album(
            id: 'album-escalate-$index',
            name: 'Escalate Album $index',
            artistId: 'artist-escalate',
            songs: <Song>[
              Song(id: 'song-escalate-$index', title: 'Escalate song $index'),
            ],
          );
        }

        final state = await meteredEngine.executeSyncPlan(
          _meteredManualDiscoveryPlan,
        );

        // The stored streak of one increments past the escalation threshold;
        // the coordinator enqueues broad reconciliation for this signal.
        expect(state.probeDiscoveryDebtStreak, 2);
      },
      skip: !sqliteAvailable,
    );

    test('manual changed-index refresh immediately hydrates newest albums in a large library', () async {
      const artistCount = 2000;
      const songsPerAlbum = 25;
      final committedCursor = DateTime.utc(2026, 8, 1);
      final changedCursor = DateTime.utc(2026, 8, 2);
      await saveSession(
        lastSynced: DateTime.now().subtract(const Duration(hours: 2)),
        lastFullSyncedAt: DateTime.now(),
        capabilitiesJson: jsonEncode(<String, Object?>{
          'navis': <String, Object?>{
            'libraryIndexesCursor': committedCursor.toIso8601String(),
            'libraryHealthCheckedAt': DateTime.now().toUtc().toIso8601String(),
          },
        }),
      );

      final artists = List<ArtistsTableCompanion>.generate(
        artistCount,
        (index) => ArtistsTableCompanion.insert(
          id: 'artist-$index',
          name: 'Artist $index',
          albumCount: const Value(1),
        ),
        growable: false,
      );
      final albums = List<AlbumsTableCompanion>.generate(
        artistCount,
        (index) => AlbumsTableCompanion.insert(
          id: 'album-$index',
          name: 'Album $index',
          artistId: Value('artist-$index'),
          artistName: Value('Artist $index'),
          songCount: const Value(songsPerAlbum),
          songsHydrated: const Value(true),
        ),
        growable: false,
      );
      final songs = List<SongsTableCompanion>.generate(
        artistCount * songsPerAlbum,
        (index) {
          final artistIndex = index ~/ songsPerAlbum;
          return SongsTableCompanion.insert(
            id: 'song-$index',
            title: 'Song $index',
            albumId: Value('album-$artistIndex'),
            artistId: Value('artist-$artistIndex'),
          );
        },
        growable: false,
      );
      await database.libraryDao.replaceArtists(artists);
      await database.libraryDao.replaceAlbums(albums);
      await database.libraryDao.replaceSongs(songs);

      api.indexes = Indexes(
        lastModified: changedCursor,
        indexes: <IndexesIndex>[
          IndexesIndex(
            name: 'A',
            artists: List<Artist>.generate(
              artistCount,
              (index) => Artist(
                id: 'artist-$index',
                name: 'Artist $index',
                albumCount: 1,
              ),
              growable: false,
            ),
          ),
        ],
      );
      for (var index = 0; index < artistCount; index++) {
        api.artistDetails['artist-$index'] = Artist(
          id: 'artist-$index',
          name: 'Artist $index',
          albumCount: 1,
          albums: <Album>[
            Album(
              id: 'album-$index',
              name: 'Album $index',
              artistId: 'artist-$index',
              artist: 'Artist $index',
              songCount: songsPerAlbum,
            ),
          ],
        );
      }
      api.fastPathPages[0] = const <Album>[
        Album(
          id: 'album-new',
          name: 'New Album',
          artistId: 'artist-1999',
          artist: 'Artist 1999',
          songCount: 1,
        ),
      ];
      api.albumDetails['album-new'] = const Album(
        id: 'album-new',
        name: 'New Album',
        artistId: 'artist-1999',
        artist: 'Artist 1999',
        songCount: 1,
        songs: <Song>[
          Song(
            id: 'song-new',
            title: 'New Song',
            albumId: 'album-new',
            artistId: 'artist-1999',
          ),
        ],
      );

      final state = await engine.executeSyncPlan(
        syncPlanForTest(SyncExecutionPlanKind.manualCatalogDiscovery),
      );

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(await database.libraryDao.getAlbumById('album-new'), isNotNull);
      expect(
        (await database.libraryDao.watchSongsByAlbum('album-new').first)
            .single
            .id,
        'song-new',
      );
      expect(api.calls, contains('getAlbumListPage:0:100'));
      expect(api.calls, contains('getAlbum:album-new'));
      expect(api.calls, isNot(contains('getArtist:artist-1999')));
    }, skip: !sqliteAvailable);

    test(
      'incremental sync persists play-count-only album metadata changes',
      () async {
        await saveSession(
          lastSynced: DateTime.now().subtract(const Duration(hours: 2)),
          lastFullSyncedAt: DateTime.now(),
        );
        await database.libraryDao.replaceArtists(<ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist 1'),
        ]);
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'album-1',
            name: 'Album 1',
            artistId: const Value('artist-1'),
            artistName: const Value('Artist 1'),
            playCount: const Value(1),
            songsHydrated: const Value(true),
          ),
        ]);
        api.indexes = const Indexes(
          indexes: <IndexesIndex>[
            IndexesIndex(
              name: 'A',
              artists: <Artist>[Artist(id: 'artist-1', name: 'Artist 1')],
            ),
          ],
        );
        api.artistDetails['artist-1'] = const Artist(
          id: 'artist-1',
          name: 'Artist 1',
          albums: <Album>[
            Album(
              id: 'album-1',
              name: 'Album 1',
              artist: 'Artist 1',
              artistId: 'artist-1',
              playCount: 2,
            ),
          ],
        );
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          artist: 'Artist 1',
          artistId: 'artist-1',
          playCount: 2,
          songs: <Song>[],
        );

        final state = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.manualCatalogDiscovery),
        );
        final albums = await database.select(database.albumsTable).get();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(albums.single.playCount, 2);
      },
      skip: !sqliteAvailable,
    );

    test(
      'incremental mode uses bounded verification when indexes are unsupported',
      () async {
        await saveSession(
          lastSynced: DateTime.now().subtract(const Duration(hours: 3)),
          lastFullSyncedAt: DateTime.now(),
        );
        api.throwOnIndexes = const SubsonicNotFoundException(
          message: 'missing',
        );
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.artistDetails['artist-1'] = const Artist(
          id: 'artist-1',
          name: 'Artist 1',
          albums: <Album>[
            Album(id: 'album-1', name: 'Album 1', artistId: 'artist-1'),
          ],
        );
        api.fastPathPages[0] = const <Album>[
          Album(id: 'album-1', name: 'Album 1', artistId: 'artist-1'),
        ];
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          songs: <Song>[Song(id: 'song-1', title: 'Song 1')],
        );

        final state = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.compatibilityAudit),
        );

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(state.mode, LibrarySyncMode.incremental);
        expect(api.calls, contains('getIndexes'));
        expect(api.calls, contains('getArtists'));
        expect(api.calls, contains('getAlbumListPage:0:100'));
        expect(api.calls, isNot(contains('getAlbumListPage:0:500')));
      },
      skip: !sqliteAvailable,
    );

    test(
      'incremental mode bounds changed artist fanout instead of rebaseline',
      () async {
        await saveSession(
          lastSynced: DateTime.now().subtract(const Duration(hours: 3)),
          lastFullSyncedAt: DateTime.now().subtract(const Duration(hours: 2)),
        );
        final noisyArtistIds = List<String>.generate(
          49,
          (index) => 'artist-${index + 1}',
        );
        api.indexes = Indexes(
          indexes: <IndexesIndex>[
            IndexesIndex(
              name: 'A',
              artists: noisyArtistIds
                  .map((id) => Artist(id: id, name: id))
                  .toList(growable: false),
            ),
          ],
        );
        for (final artistId in noisyArtistIds) {
          api.artistDetails[artistId] = Artist(id: artistId, name: artistId);
        }

        final state = await engine.executeSyncPlan(
          syncPlanForTest(
            SyncExecutionPlanKind.manualCatalogDiscovery,
            intent: SyncRunIntent.automaticCatalogCheck,
          ),
        );
        final config = await serverConfigRepository.getActiveServer();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(state.mode, LibrarySyncMode.incremental);
        expect(api.calls, contains('getIndexes'));
        expect(
          api.calls.where((call) => call.startsWith('getArtist:')).length,
          24,
        );
        expect(state.remainingVerificationCount, 25);
        expect(api.calls, isNot(contains('getArtists')));
        expect(api.calls, isNot(contains('getAlbumListPage:0:500')));
        expect(
          config?.lastFullSyncedAt?.isBefore(
            DateTime.now().subtract(const Duration(hours: 1)),
          ),
          isTrue,
        );
      },
      skip: !sqliteAvailable,
    );

    test('incremental mode skips unchanged noisy index fingerprint', () async {
      final noisyArtistIds = List<String>.generate(
        49,
        (index) => 'artist-${index + 1}',
      );
      await saveSession(
        lastSynced: DateTime.now().subtract(const Duration(hours: 3)),
        lastFullSyncedAt: DateTime.now(),
        capabilitiesJson: jsonEncode(<String, Object?>{
          'navis': <String, Object?>{
            'libraryIndexesFingerprint': _testIndexesFingerprint(
              noisyArtistIds,
            ),
            'libraryIndexesCursor': FakeLibrarySyncApi.defaultIndexesCursor
                .toIso8601String(),
            'libraryHealthCheckedAt': DateTime.now().toUtc().toIso8601String(),
          },
        }),
      );
      api.indexes = Indexes(
        indexes: <IndexesIndex>[
          IndexesIndex(
            name: 'A',
            artists: noisyArtistIds
                .map((id) => Artist(id: id, name: id))
                .toList(growable: false),
          ),
        ],
      );

      final state = await engine.executeSyncPlan(
        syncPlanForTest(
          SyncExecutionPlanKind.manualCatalogDiscovery,
          intent: SyncRunIntent.automaticCatalogCheck,
        ),
      );

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(state.mode, LibrarySyncMode.incremental);
      expect(api.calls, contains('getIndexes'));
      expect(api.calls.where((call) => call.startsWith('getArtist:')), isEmpty);
      expect(api.calls, isNot(contains('getArtists')));
      expect(api.calls, isNot(contains('getAlbumListPage:0:500')));
    }, skip: !sqliteAvailable);

    test('incremental sync reports exhausted transient index failures for durable retry', () async {
      await saveSession(
        lastSynced: DateTime.now().subtract(const Duration(hours: 3)),
        lastFullSyncedAt: DateTime.now(),
      );
      api.throwOnIndexes = const SubsonicGenericException(
        code: 530,
        message: 'origin unavailable',
      );

      final state = await engine.executeSyncPlan(
        syncPlanForTest(
          SyncExecutionPlanKind.manualCatalogDiscovery,
          intent: SyncRunIntent.automaticCatalogCheck,
        ),
      );

      expect(state.status, LibrarySyncStatus.failed);
      expect(state.mode, LibrarySyncMode.incremental);
      expect(state.stage, LibrarySyncStage.completed);
      expect(
        state.errorMessage,
        'Server temporarily unavailable. Sync will retry later.',
      );
      expect(api.calls.where((call) => call == 'getIndexes').length, 1);
    }, skip: !sqliteAvailable);

    test('incremental sync skips fresh auxiliary endpoints', () async {
      await saveSession(
        lastSynced: DateTime.now().subtract(const Duration(hours: 2)),
        lastFullSyncedAt: DateTime.now(),
      );
      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: const Value(1),
          lastAuxiliarySyncedAt: Value(DateTime.now()),
        ),
      );

      final state = await engine.executeSyncPlan(
        syncPlanForTest(
          SyncExecutionPlanKind.manualCatalogDiscovery,
          intent: SyncRunIntent.automaticCatalogCheck,
        ),
      );

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(state.mode, LibrarySyncMode.incremental);
      expect(api.calls, contains('getIndexes'));
      expect(api.calls, isNot(contains('getStarredContent')));
      expect(api.calls, isNot(contains('getGenres')));
      expect(api.calls, isNot(contains('getPlaylists')));
    }, skip: !sqliteAvailable);

    test(
      'automatic sync stays incremental after the old rebaseline interval',
      () async {
        await saveSession(
          lastSynced: DateTime.now().subtract(const Duration(hours: 2)),
          lastFullSyncedAt: DateTime.now().subtract(const Duration(hours: 30)),
        );
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.artistDetails['artist-1'] = const Artist(
          id: 'artist-1',
          name: 'Artist 1',
          albums: <Album>[
            Album(id: 'album-1', name: 'Album 1', artistId: 'artist-1'),
          ],
        );
        api.fastPathPages[0] = const <Album>[
          Album(id: 'album-1', name: 'Album 1', artistId: 'artist-1'),
        ];
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          songs: <Song>[Song(id: 'song-1', title: 'Song 1')],
        );

        final state = await engine.executeSyncPlan(
          syncPlanForTest(
            SyncExecutionPlanKind.manualCatalogDiscovery,
            intent: SyncRunIntent.automaticCatalogCheck,
          ),
        );
        final config = await serverConfigRepository.getActiveServer();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(state.mode, LibrarySyncMode.incremental);
        expect(api.calls, contains('getIndexes'));
        expect(api.calls, isNot(contains('getArtists')));
        expect(api.calls, isNot(contains('getAlbumListPage:0:500')));
        expect(config?.lastFullSyncedAt, isNotNull);
        expect(
          config!.lastFullSyncedAt!.isBefore(
            DateTime.now().subtract(const Duration(hours: 1)),
          ),
          isTrue,
        );
      },
      skip: !sqliteAvailable,
    );

    test('incremental sync after old rebaseline interval avoids rehydrating unchanged albums', () async {
      await saveSession(
        lastSynced: DateTime.now().subtract(const Duration(hours: 2)),
        lastFullSyncedAt: DateTime.now().subtract(const Duration(hours: 30)),
      );
      await database.libraryDao.replaceArtists(<ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist 1'),
      ]);
      await database.libraryDao.replaceAlbums(<AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(
          id: 'album-1',
          name: 'Album 1',
          artistId: const Value('artist-1'),
          artistName: const Value('Artist 1'),
          songsHydrated: const Value(true),
          songsVerifiedAt: Value(DateTime.now()),
        ),
      ]);
      await database.libraryDao.replaceSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(
          id: 'song-1',
          title: 'Song 1',
          albumId: const Value('album-1'),
        ),
      ]);

      api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
      api.artistDetails['artist-1'] = const Artist(
        id: 'artist-1',
        name: 'Artist 1',
        albums: <Album>[
          Album(
            id: 'album-1',
            name: 'Album 1',
            artistId: 'artist-1',
            artist: 'Artist 1',
          ),
        ],
      );
      api.fastPathPages[0] = const <Album>[
        Album(
          id: 'album-1',
          name: 'Album 1',
          artistId: 'artist-1',
          artist: 'Artist 1',
        ),
      ];

      final state = await engine.executeSyncPlan(
        syncPlanForTest(
          SyncExecutionPlanKind.manualCatalogDiscovery,
          intent: SyncRunIntent.automaticCatalogCheck,
        ),
      );
      final pending = await database.libraryDao.countPendingHydrationAlbums();
      final songs = await database.select(database.songsTable).get();

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(state.mode, LibrarySyncMode.incremental);
      expect(api.calls, isNot(contains('getAlbum:album-1')));
      expect(pending, 0);
      expect(songs.map((song) => song.id), contains('song-1'));
    }, skip: !sqliteAvailable);

    test(
      'full catalog hydration starts with fast concurrent fallback',
      () async {
        await saveSession();
        api.albumDelay = const Duration(milliseconds: 2);
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = List<Album>.generate(
          18,
          (index) => Album(
            id: 'album-${index + 1}',
            name: 'Album ${index + 1}',
            artistId: 'artist-1',
          ),
        );
        for (var index = 0; index < 18; index++) {
          final albumId = 'album-${index + 1}';
          api.albumDetails[albumId] = Album(
            id: albumId,
            name: 'Album ${index + 1}',
            songs: <Song>[Song(id: 'song-${index + 1}', title: 'Song')],
          );
        }

        final adaptiveEngine = DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          networkType: NetworkType.wifi,
          fallbackArtistConcurrency: 2,
          wifiAlbumConcurrency: 2,
          wifiMaxAlbumConcurrency: 8,
          cellularAlbumConcurrency: 1,
          cellularMaxAlbumConcurrency: 2,
          otherAlbumConcurrency: 2,
          otherMaxAlbumConcurrency: 4,
          writeChunkSize: 18,
        );

        final state = await adaptiveEngine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(api.maxConcurrentAlbumRequests, greaterThanOrEqualTo(8));
        expect(
          api.calls.where((call) => call.startsWith('getAlbum:')).length,
          18,
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'full catalog fallback retains bounded concurrency during playback',
      () async {
        await saveSession();
        api.albumDelay = const Duration(milliseconds: 2);
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = List<Album>.generate(
          12,
          (index) => Album(
            id: 'album-${index + 1}',
            name: 'Album ${index + 1}',
            artistId: 'artist-1',
          ),
        );
        for (var index = 0; index < 12; index++) {
          final albumId = 'album-${index + 1}';
          api.albumDetails[albumId] = Album(
            id: albumId,
            name: 'Album ${index + 1}',
            songs: <Song>[Song(id: 'song-${index + 1}', title: 'Song')],
          );
        }
        final activePlaybackEngine = DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          networkType: NetworkType.wifi,
          readActiveSongId: () => 'song-playing',
          writeChunkSize: 12,
        );

        final state = await activePlaybackEngine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(api.maxConcurrentAlbumRequests, greaterThanOrEqualTo(4));
      },
      skip: !sqliteAvailable,
    );

    test(
      'adaptive hydration does not serialize a high-latency repair',
      () async {
        await saveSession();
        api.albumDelay = const Duration(milliseconds: 2600);
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = List<Album>.generate(
          12,
          (index) => Album(
            id: 'album-${index + 1}',
            name: 'Album ${index + 1}',
            artistId: 'artist-1',
          ),
        );
        for (var index = 0; index < 12; index++) {
          final albumId = 'album-${index + 1}';
          api.albumDetails[albumId] = Album(
            id: albumId,
            name: 'Album ${index + 1}',
            songs: <Song>[Song(id: 'song-${index + 1}', title: 'Song')],
          );
        }

        final adaptiveEngine = DriftLibrarySyncEngine(
          api: api,
          database: database,
          serverConfigRepository: serverConfigRepository,
          networkType: NetworkType.wifi,
          fallbackArtistConcurrency: 2,
          wifiAlbumConcurrency: 2,
          wifiMaxAlbumConcurrency: 8,
          writeChunkSize: 12,
        );

        final state = await adaptiveEngine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(api.maxConcurrentAlbumRequests, greaterThanOrEqualTo(8));
      },
      skip: !sqliteAvailable,
    );

    for (final pressure in ['clean', '503', 'transport retry', '404']) {
      test('adaptive hydration batches respond to $pressure', () async {
        await saveSession();
        final batchApi = _BatchTrackingLibrarySyncApi();
        batchApi.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        batchApi.fastPathPages[0] = List<Album>.generate(
          18,
          (index) => Album(
            id: 'album-$index',
            name: 'Album $index',
            artistId: 'artist-1',
          ),
        );
        for (var index = 0; index < 18; index++) {
          batchApi.albumDetails['album-$index'] = Album(
            id: 'album-$index',
            name: 'Album $index',
            songs: [Song(id: 'song-$index', title: 'Song')],
          );
        }
        if (pressure == '503') {
          batchApi.albumErrors['album-0'] = const SubsonicGenericException(
            message: 'Busy',
            code: 503,
          );
        } else if (pressure == '404') {
          batchApi.notFoundAlbumIds.add('album-0');
        }
        batchApi.retryFirstAlbum = pressure == 'transport retry';
        final batchEngine = DriftLibrarySyncEngine(
          api: batchApi,
          database: database,
          serverConfigRepository: serverConfigRepository,
          networkType: NetworkType.wifi,
          writeChunkSize: 18,
        );
        final scope = SyncRequestScope(
          allowedEndpoints: {
            'getIndexes',
            'getArtists',
            'getAlbumListPage',
            'getNewestAlbumList2',
            'searchSongsPage',
            'getAlbum',
            'getStarredContent',
            'getPlaylists',
          },
          maxRequests: 100,
          maxNewestPages: 0,
          maxAlbumHydrations: 0,
          maxResponseBytes: null,
          maxTotalBytes: null,
          maxConcurrency: 24,
          maxDuration: const Duration(seconds: 30),
          canRequest: () => true,
        );

        final state = await scope.run(
          () => batchEngine.executeSyncPlan(
            syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
          ),
        );

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(
          batchApi.batchSizes,
          pressure == '503' || pressure == 'transport retry'
              ? [8, 6, 4]
              : [8, 10],
        );
        expect(
          state.pendingHydrationCount,
          pressure == '503' || pressure == '404' ? 1 : 0,
        );
        expect(
          batchApi.calls.where((call) => call == 'getAlbum:album-0'),
          hasLength(1),
        );
      }, skip: !sqliteAvailable);
    }

    test('transient album failures are left for durable retry', () async {
      await saveSession();
      api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
      api.fastPathPages[0] = const <Album>[
        Album(id: 'album-1', name: 'Album 1', artistId: 'artist-1'),
      ];
      api.albumDetails['album-1'] = const Album(
        id: 'album-1',
        name: 'Album 1',
        songs: <Song>[Song(id: 'song-1', title: 'Song 1')],
      );
      api.transientAlbumFailures['album-1'] = 2;

      final state = await engine.executeSyncPlan(
        syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
      );

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(api.calls.where((call) => call == 'getAlbum:album-1').length, 1);
      expect(state.pendingHydrationCount, 1);
      expect(state.onlyIncompleteAlbumDetails, isFalse);
    }, skip: !sqliteAvailable);

    test(
      'only incomplete server albums are classified for usable sync',
      () async {
        await saveSession();
        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = const <Album>[
          Album(
            id: 'complete',
            name: 'Complete',
            artistId: 'artist-1',
            songCount: 1,
          ),
          Album(
            id: 'partial',
            name: 'Partial',
            artistId: 'artist-1',
            songCount: 2,
          ),
        ];
        api.albumDetails['complete'] = const Album(
          id: 'complete',
          name: 'Complete',
          songCount: 1,
          songs: [Song(id: 'one', title: 'One', albumId: 'complete')],
        );
        api.albumDetails['partial'] = const Album(
          id: 'partial',
          name: 'Partial',
          songCount: 2,
          songs: [Song(id: 'two', title: 'Two', albumId: 'partial')],
        );

        final first = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );
        expect(first.status, LibrarySyncStatus.succeeded);
        expect(first.pendingHydrationCount, 1);
        expect(first.onlyIncompleteAlbumDetails, isTrue);
        expect((await database.libraryDao.getCatalogCounts()).songs, 1);

        api.albumDetails['partial'] = const Album(
          id: 'partial',
          name: 'Partial',
          songCount: 2,
          songs: [
            Song(id: 'two', title: 'Two', albumId: 'partial'),
            Song(id: 'three', title: 'Three', albumId: 'partial'),
          ],
        );
        final recovered = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.targetHydration),
        );
        expect(recovered.pendingHydrationCount, 0);
        expect(recovered.onlyIncompleteAlbumDetails, isFalse);
        expect((await database.libraryDao.getCatalogCounts()).songs, 3);
      },
      skip: !sqliteAvailable,
    );

    test(
      'fresh session resumes pending song hydration without metadata fetch',
      () async {
        await saveSession(
          lastSynced: DateTime.now(),
          lastFullSyncedAt: DateTime.now(),
        );
        await database.libraryDao.replaceAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'album-1',
            name: 'Album 1',
            songsHydrated: const Value(false),
          ),
        ]);
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          songs: <Song>[
            Song(id: 'song-1', title: 'Song 1', albumId: 'album-1'),
          ],
        );

        final state = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.targetHydration),
        );
        final albums = await database.select(database.albumsTable).get();
        final songs = await database.select(database.songsTable).get();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(api.calls, contains('getAlbum:album-1'));
        expect(api.calls, isNot(contains('getArtists')));
        expect(albums.single.songsHydrated, isTrue);
        expect(songs.single.id, 'song-1');
      },
      skip: !sqliteAvailable,
    );

    test(
      'full sync keeps failed album pending and preserves existing songs',
      () async {
        await saveSession();
        await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist 1'),
        ]);
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'album-1',
            name: 'Old album title',
            artistId: const Value('artist-1'),
            songsHydrated: const Value(true),
          ),
        ]);
        await database
            .into(database.songsTable)
            .insert(
              SongsTableCompanion.insert(
                id: 'existing-song',
                title: 'Existing Song',
                albumId: const Value('album-1'),
                artistId: const Value('artist-1'),
              ),
            );

        api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
        api.fastPathPages[0] = const <Album>[
          Album(id: 'album-1', name: 'Album 1', artistId: 'artist-1'),
        ];
        // Intentionally omit api.albumDetails['album-1'] so hydration fails.

        final state = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );
        final songs = await database.select(database.songsTable).get();
        final pendingAlbums = await database.libraryDao
            .getPendingHydrationAlbumIds();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(state.freshness, LibrarySyncFreshness.verificationPending);
        expect(state.pendingHydrationCount, 1);
        expect(pendingAlbums, ['album-1']);
        expect(songs.any((song) => song.id == 'existing-song'), isTrue);

        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          artistId: 'artist-1',
          songs: <Song>[
            Song(id: 'song-1', title: 'Song 1', albumId: 'album-1'),
          ],
        );
        api.calls.clear();

        final recovered = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.targetHydration),
        );
        final recoveredSongs = await database.select(database.songsTable).get();

        expect(recovered.status, LibrarySyncStatus.succeeded);
        expect(recovered.freshness, LibrarySyncFreshness.current);
        expect(recovered.pendingHydrationCount, 0);
        expect(api.calls.where((call) => call.startsWith('getAlbum:')), [
          'getAlbum:album-1',
        ]);
        expect(recoveredSongs.map((song) => song.id), ['song-1']);
      },
      skip: !sqliteAvailable,
    );

    test('album authentication failure still fails the sync', () async {
      await saveSession(
        lastSynced: DateTime.now(),
        lastFullSyncedAt: DateTime.now(),
      );
      await database.libraryDao.replaceAlbums(<AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(
          id: 'album-1',
          name: 'Album 1',
          songsHydrated: const Value(false),
        ),
      ]);
      api.albumErrors['album-1'] = const SubsonicAuthException(
        message: 'expired',
      );

      final state = await engine.executeSyncPlan(
        syncPlanForTest(SyncExecutionPlanKind.targetHydration),
      );
      final pendingAlbums = await database.libraryDao
          .getPendingHydrationAlbumIds();

      expect(state.status, LibrarySyncStatus.failed);
      expect(
        state.errorMessage,
        'Authentication failed while syncing metadata.',
      );
      expect(pendingAlbums, ['album-1']);
      expect(api.calls.where((call) => call == 'getAlbum:album-1').length, 1);
    }, skip: !sqliteAvailable);

    test(
      '404 on one getAlbum preserves the album as a deletion candidate',
      () async {
        await saveSession(
          lastSynced: DateTime.now(),
          lastFullSyncedAt: DateTime.now(),
        );
        await database.libraryDao.replaceAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'album-1',
            name: 'Album 1',
            songsHydrated: const Value(false),
          ),
          AlbumsTableCompanion.insert(
            id: 'album-stale',
            name: 'Stale Album',
            songsHydrated: const Value(false),
          ),
        ]);
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          songs: <Song>[
            Song(id: 'song-1', title: 'Song 1', albumId: 'album-1'),
          ],
        );
        api.notFoundAlbumIds.add('album-stale');

        final state = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.targetHydration),
        );
        final albums = await database.select(database.albumsTable).get();
        final songs = await database.select(database.songsTable).get();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(albums.map((album) => album.id), contains('album-1'));
        expect(albums.map((album) => album.id), contains('album-stale'));
        expect(state.pendingHydrationCount, 1);
        expect(songs.single.id, 'song-1');
      },
      skip: !sqliteAvailable,
    );

    test(
      'transient album failure in batch leaves album pending but sync succeeds',
      () async {
        await saveSession(
          lastSynced: DateTime.now(),
          lastFullSyncedAt: DateTime.now(),
        );
        await database.libraryDao.replaceAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'album-1',
            name: 'Album 1',
            songsHydrated: const Value(false),
          ),
          AlbumsTableCompanion.insert(
            id: 'album-2',
            name: 'Album 2',
            songsHydrated: const Value(false),
          ),
        ]);
        api.albumDetails['album-1'] = const Album(
          id: 'album-1',
          name: 'Album 1',
          songs: <Song>[
            Song(id: 'song-1', title: 'Song 1', albumId: 'album-1'),
          ],
        );
        api.permanentTransientAlbumIds.add('album-2');

        final state = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.targetHydration),
        );
        final pending = await database.libraryDao.countPendingHydrationAlbums();
        final songs = await database.select(database.songsTable).get();

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(songs.single.id, 'song-1');
        expect(pending, 1);
      },
      skip: !sqliteAvailable,
    );

    test('catalog sync makes no genre request', () async {
      await saveSession(
        lastSynced: DateTime.now().subtract(const Duration(hours: 3)),
        lastFullSyncedAt: DateTime.now(),
      );
      api.indexes = const Indexes(
        shortcut: <Artist>[Artist(id: 'artist-1', name: 'Artist 1')],
      );
      api.artistDetails['artist-1'] = const Artist(
        id: 'artist-1',
        name: 'Artist 1',
        albums: <Album>[],
      );
      final state = await engine.executeSyncPlan(
        syncPlanForTest(
          SyncExecutionPlanKind.manualCatalogDiscovery,
          intent: SyncRunIntent.automaticCatalogCheck,
        ),
      );
      final config = await serverConfigRepository.getActiveServer();

      expect(state.status, LibrarySyncStatus.succeeded);
      expect(config?.lastSynced, isNotNull);
      expect(api.calls, isNot(contains('getGenres')));
    }, skip: !sqliteAvailable);

    test(
      'failed full sync keeps the candidate hidden from the committed catalog',
      () async {
        await saveSession();
        api.artists.addAll(const <Artist>[
          Artist(id: 'artist-1', name: 'Artist 1'),
          Artist(id: 'artist-2', name: 'Artist 2'),
        ]);
        api.throwOnFastPath = const SubsonicNotFoundException(
          message: 'Album list unsupported',
        );
        api.notFoundArtistIds.add('artist-1');
        api.artistDetails['artist-2'] = const Artist(
          id: 'artist-2',
          name: 'Artist 2',
          albums: <Album>[
            Album(id: 'album-2', name: 'Album 2', artistId: 'artist-2'),
          ],
        );
        api.albumDetails['album-2'] = const Album(
          id: 'album-2',
          name: 'Album 2',
          songs: <Song>[
            Song(id: 'song-2', title: 'Song 2', albumId: 'album-2'),
          ],
        );
        await database.libraryDao.replaceArtists(<ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist 1'),
        ]);

        final state = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );
        final artists = await database.select(database.artistsTable).get();

        expect(state.status, LibrarySyncStatus.failed);
        expect(artists.map((artist) => artist.id), contains('artist-1'));
        expect(artists.map((artist) => artist.id), isNot(contains('artist-2')));
        final candidateArtists = await database.librarySyncCandidateDao
            .getArtists(serverId: 1, generation: 1);
        expect(
          candidateArtists.map((artist) => artist.id),
          containsAll(<String>['artist-1', 'artist-2']),
        );
        expect(
          (await database.librarySyncDao.getOrCreateState(1)).candidateStatus,
          'collecting',
        );
        expect(
          (await database.librarySyncDao.getOrCreateState(1)).currentGeneration,
          0,
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'incremental artist detail 404 needs parent deletion confirmation',
      () async {
        await saveSession(
          lastSynced: DateTime.now().subtract(const Duration(hours: 2)),
          lastFullSyncedAt: DateTime.now(),
        );
        await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist 1'),
        ]);
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'album-1',
            name: 'Album 1',
            artistId: const Value('artist-1'),
          ),
        ]);
        api.indexes = const Indexes(
          shortcut: <Artist>[Artist(id: 'artist-1', name: 'Artist 1')],
        );
        api.notFoundArtistIds.add('artist-1');

        final state = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.manualCatalogDiscovery),
        );

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(state.remainingVerificationCount, 1);
        expect(await database.libraryDao.getArtistById('artist-1'), isNotNull);
        expect(await database.libraryDao.getAlbumById('album-1'), isNotNull);
      },
      skip: !sqliteAvailable,
    );

    test(
      'incremental artist detail omission preserves the local album',
      () async {
        await saveSession(
          lastSynced: DateTime.now().subtract(const Duration(hours: 2)),
          lastFullSyncedAt: DateTime.now(),
        );
        await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist 1'),
        ]);
        await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'album-retained',
            name: 'Retained Album',
            artistId: const Value('artist-1'),
            songsHydrated: const Value(true),
          ),
        ]);
        api.indexes = const Indexes(
          shortcut: <Artist>[Artist(id: 'artist-1', name: 'Artist 1')],
        );
        api.artistDetails['artist-1'] = const Artist(
          id: 'artist-1',
          name: 'Artist 1',
          albums: <Album>[
            Album(id: 'album-live', name: 'Live Album', artistId: 'artist-1'),
          ],
        );
        api.albumDetails['album-live'] = const Album(
          id: 'album-live',
          name: 'Live Album',
          songs: <Song>[],
        );

        final state = await engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.manualCatalogDiscovery),
        );

        expect(state.status, LibrarySyncStatus.succeeded);
        expect(
          await database.libraryDao.getAlbumById('album-retained'),
          isNotNull,
        );
        expect(await database.libraryDao.getAlbumById('album-live'), isNotNull);
      },
      skip: !sqliteAvailable,
    );

    test(
      'sync lock returns same in-flight future for concurrent calls',
      () async {
        await saveSession();
        final completer = Completer<List<Artist>>();
        api.artistsCompleter = completer;

        final first = engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );
        final second = engine.executeSyncPlan(
          syncPlanForTest(SyncExecutionPlanKind.repairLibrary),
        );

        completer.complete(const <Artist>[]);
        final firstState = await first;
        final secondState = await second;

        expect(firstState.status, LibrarySyncStatus.succeeded);
        expect(secondState.status, LibrarySyncStatus.succeeded);
        expect(api.calls.where((call) => call == 'getArtists').length, 1);
      },
      skip: !sqliteAvailable,
    );
  });
}

class _RunCountingSyncApi extends FakeLibrarySyncApi {
  int beginRunCalls = 0;

  @override
  void beginRun() {
    beginRunCalls++;
    super.beginRun();
  }
}
