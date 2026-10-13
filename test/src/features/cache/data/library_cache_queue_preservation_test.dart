import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/cache/data/cache_system_upgrade_service.dart';
import 'package:navis/src/features/cache/data/library_cache_reset_service.dart';
import 'package:navis/src/features/cache/data/rolling_cache_manager.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/domain/streaming_quality.dart';

import '../../../../helpers/library_sync_fakes.dart';
import '../../../../helpers/library_sync_plan.dart';
import '../../../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;
  late LibraryCacheResetService reset;

  setUp(() {
    database = createTestDatabase();
    reset = LibraryCacheResetService(database: database);
  });
  tearDown(() => database.close());

  Future<void> seedLibrary() async {
    await database.libraryDao.upsertArtists([
      for (final id in ['song-artist', 'album-artist', 'unrelated-artist'])
        ArtistsTableCompanion.insert(id: id, name: id),
    ]);
    await database.libraryDao.upsertAlbums([
      AlbumsTableCompanion.insert(
        id: 'album',
        name: 'Old album',
        artistId: const Value('album-artist'),
      ),
      AlbumsTableCompanion.insert(
        id: 'unrelated-album',
        name: 'Unrelated album',
        artistId: const Value('unrelated-artist'),
      ),
    ]);
    await database.libraryDao.upsertSongs([
      for (final id in ['a', 'b', 'c', 'unqueued-sibling'])
        SongsTableCompanion.insert(
          id: id,
          title: 'Old $id',
          albumId: const Value('album'),
          artistId: const Value('song-artist'),
          artistName: const Value('Old artist'),
          albumName: const Value('Old album'),
          duration: const Value(100),
          bitRate: const Value(320),
          coverArt: const Value('old-cover'),
          replayGainTrackGain: const Value(-6),
        ),
      SongsTableCompanion.insert(
        id: 'unrelated',
        title: 'Unrelated',
        albumId: const Value('unrelated-album'),
        artistId: const Value('unrelated-artist'),
      ),
      SongsTableCompanion.insert(id: 'loose', title: 'Loose'),
    ]);
  }

  Future<void> saveQueue() => database.playQueueDao.saveQueue(
    songIds: ['a', 'b', 'a', 'c', 'loose'],
    currentIndex: 2,
    shuffleMode: ShuffleMode.all,
    repeatMode: RepeatMode.one,
    positionMs: 12345,
    originalOrder: [2, 0, 3, 1, 4],
  );

  CacheSystemUpgradeService upgrade(Future<bool> Function() scan) =>
      CacheSystemUpgradeService(
        database: database,
        cacheResetService: reset,
        triggerFullLibraryScan: scan,
        currentEpoch: () async => 1005,
        hasCommittedCatalog: () async => true,
      );

  group('saved queue across library reset', () {
    test('reset retains exactly queued songs and their parent chain', () async {
      await seedLibrary();
      await saveQueue();
      final items = await database.select(database.playQueueItemsTable).get();
      final state = await database.playQueueDao.getQueueState();
      final songs = await (database.select(
        database.songsTable,
      )..where((table) => table.id.isIn(['a', 'b', 'c', 'loose']))).get();
      final albums = await (database.select(
        database.albumsTable,
      )..where((table) => table.id.equals('album'))).get();
      final artists =
          await (database.select(database.artistsTable)..where(
                (table) => table.id.isIn(['song-artist', 'album-artist']),
              ))
              .get();

      await reset.reset();

      expect(await database.select(database.playQueueItemsTable).get(), items);
      expect(await database.playQueueDao.getQueueState(), state);
      expect(
        await database.select(database.songsTable).get(),
        unorderedEquals([
          for (final song in songs)
            song.copyWith(
              isProvisional: true,
              catalogAvailability: const Value('pendingRebuild'),
            ),
        ]),
      );
      expect(
        (await database.select(database.albumsTable).get()).map(
          (row) => row.toJson(),
        ),
        albums.map((row) => row.copyWith(isProvisional: true).toJson()),
      );
      expect(
        await database.select(database.artistsTable).get(),
        unorderedEquals([
          for (final artist in artists) artist.copyWith(isProvisional: true),
        ]),
      );
      expect(await database.libraryDao.getAllSongs(), isEmpty);
      expect(await database.libraryDao.searchSongsLocal('Old'), isEmpty);
      expect(await database.libraryDao.searchSongsLocal(''), isEmpty);
      expect(await database.libraryDao.searchSongsLocal('Loose'), isEmpty);
      expect(await database.libraryDao.countSongsByAlbum('album'), 0);
      expect(await database.libraryDao.watchAlbumCount().first, 0);
      expect(await database.libraryDao.countArtists(), 0);
      expect(await database.libraryDao.getAllAlbums(), isEmpty);
      expect(await database.libraryDao.getAllArtists(), isEmpty);
      expect(
        await database.customSelect('PRAGMA foreign_key_check').get(),
        isEmpty,
      );
    });

    test('reset with an empty queue clears the entire library', () async {
      await seedLibrary();
      await saveQueue();
      await database.playQueueDao.clearQueue();

      await reset.reset();

      expect(await database.select(database.songsTable).get(), isEmpty);
      expect(await database.select(database.albumsTable).get(), isEmpty);
      expect(await database.select(database.artistsTable).get(), isEmpty);
      expect(await database.playQueueDao.getQueueItems(), isEmpty);
      expect(await database.playQueueDao.getQueueState(), isNull);
    });

    test(
      'legacy tree preservation cannot hide reset rows from reconciliation',
      () async {
        await seedLibrary();
        await saveQueue();
        await reset.reset();
        final preserved = await database.libraryDao
            .preserveCachedLegacyRowsAsProvisional(
              staleArtistIds: ['song-artist'],
              staleAlbumIds: ['album'],
              protectedSongIds: ['b'],
            );
        expect(preserved.songIds, contains('b'));
        final stale = await database.librarySyncCandidateDao.getStaleSongsPage(
          serverId: 1,
          generation: 1,
          afterId: '',
          limit: 10,
        );
        expect(stale.map((song) => song.id), ['a', 'b', 'c', 'loose']);
        expect(stale.every((song) => song.isProvisional), isTrue);
      },
    );

    test(
      'pending album hydration does not reconfirm reset references',
      () async {
        await seedLibrary();
        await saveQueue();
        await (database.update(
          database.albumsTable,
        )..where((table) => table.id.equals('album'))).write(
          const AlbumsTableCompanion(
            songsHydrated: Value(true),
            songCount: Value(3),
          ),
        );
        final album = (await database.libraryDao.getAlbumById('album'))!;
        await reset.reset();
        await database.librarySyncCandidateDao.upsertAlbums(
          serverId: 1,
          generation: 1,
          albums: [
            album
                .toCompanion(false)
                .copyWith(songsHydrated: const Value(false)),
          ],
        );
        expect(
          await database.librarySyncCandidateDao.carryForwardPendingAlbums(
            serverId: 1,
            generation: 1,
          ),
          isEmpty,
        );
        final stale = await database.librarySyncCandidateDao.getStaleSongsPage(
          serverId: 1,
          generation: 1,
          afterId: '',
          limit: 10,
        );
        // Parentless references have no unresolved album protecting them.
        expect(stale.map((song) => song.id), ['loose']);
        expect(
          (await database.libraryDao.getSongById('a'))!.catalogAvailability,
          'pendingRebuild',
        );
        expect(await database.libraryDao.getAllSongs(), isEmpty);
      },
    );

    test(
      'isolated 404 suspicion keeps queued search references searchable',
      () async {
        await database.libraryDao.upsertProvisionalSongs([
          SongsTableCompanion.insert(id: 'reference', title: 'Reference'),
        ]);
        await database.playQueueDao.saveQueue(songIds: ['reference']);
        await database.libraryDao.markSongsSuspectedMissing(['reference']);
        expect(
          (await database.libraryDao.searchSongsLocal('Reference'))
              .map((song) => song.id),
          ['reference'],
        );
      },
    );

    for (final succeeds in [false, true]) {
      test(
        'scan completion leaves live queue changes intact: $succeeds',
        () async {
          await seedLibrary();
          await saveQueue();
          final service = upgrade(() async {
            expect(
              (await database.playQueueDao.getQueueItems()).map(
                (song) => song.id,
              ),
              ['a', 'b', 'a', 'c', 'loose'],
            );
            await database.playQueueDao.saveQueue(
              songIds: ['c', 'a'],
              currentIndex: 1,
              shuffleMode: ShuffleMode.all,
              originalOrder: [1, 0],
              positionMs: 54321,
            );
            return succeeds;
          });
          if (succeeds) {
            await service.resetAndMarkCurrent();
          } else {
            await expectLater(service.resetAndMarkCurrent(), throwsStateError);
          }
          final entries = await database.playQueueDao.getQueueEntries();
          expect(entries.map((entry) => entry.song.id), ['c', 'a']);
          expect(entries.map((entry) => entry.originalOrder), [1, 0]);
          final state = (await database.playQueueDao.getQueueState())!;
          expect(state.currentIndex, 1);
          expect(state.shuffleMode, ShuffleMode.all);
          expect(state.positionMs, 54321);
        },
      );
    }

    test('a queue cleared during a rescan stays cleared', () async {
      await seedLibrary();
      await saveQueue();
      await upgrade(() async {
        await database.playQueueDao.clearQueue();
        return true;
      }).resetAndMarkCurrent();
      expect(await database.playQueueDao.getQueueItems(), isEmpty);
      expect(await database.playQueueDao.getQueueState(), isNull);
    });

    for (final rating in [4, null]) {
      test('rebuild refreshes retained ratings to $rating', () async {
        final repository = await seedSyncSession(database);
        await database.libraryDao.upsertArtists([
          ArtistsTableCompanion.insert(
            id: 'artist',
            name: 'Artist',
            albumCount: const Value(1),
          ),
        ]);
        await database.libraryDao.upsertAlbums([
          AlbumsTableCompanion.insert(
            id: 'album',
            name: 'Album',
            artistId: const Value('artist'),
            artistName: const Value('Artist'),
            songCount: const Value(1),
            songsHydrated: const Value(true),
            userRating: const Value(1),
          ),
        ]);
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(
            id: 'song',
            title: 'Song',
            albumId: const Value('album'),
            artistId: const Value('artist'),
            artistName: const Value('Artist'),
            albumName: const Value('Album'),
            userRating: const Value(1),
          ),
        ]);
        await database.playQueueDao.saveQueue(songIds: ['song', 'song']);
        final items = await database.select(database.playQueueItemsTable).get();
        await reset.reset();
        final album = Album(
          id: 'album',
          name: 'Album',
          artistId: 'artist',
          artist: 'Artist',
          songCount: 1,
          userRating: rating,
          songs: [
            Song(
              id: 'song',
              title: 'Song',
              albumId: 'album',
              artistId: 'artist',
              artist: 'Artist',
              album: 'Album',
              userRating: rating,
            ),
          ],
        );
        final api = FakeLibrarySyncApi()
          ..artists.add(
            const Artist(id: 'artist', name: 'Artist', albumCount: 1),
          )
          ..fastPathPages[0] = [album]
          ..albumDetails['album'] = album;
        final result = await serialDriftEngine(
          api: api,
          database: database,
          repository: repository,
        ).executeSyncPlan(syncPlanForTest(LibrarySyncPlanKind.fullRepair));
        expect(result.freshness, LibrarySyncFreshness.current);
        final song = (await database.libraryDao.getSongById('song'))!;
        final refreshedAlbum = (await database.libraryDao.getAlbumById(
          'album',
        ))!;
        expect(song.userRating, rating);
        expect(refreshedAlbum.userRating, rating);
        expect(song.isProvisional, isFalse);
        expect(song.catalogAvailability, isNull);
        expect(refreshedAlbum.isProvisional, isFalse);
        expect(
          await database.select(database.playQueueItemsTable).get(),
          items,
        );
      });
    }

    test(
      'missing downloaded queued song remains playable after rebuild',
      () async {
        await seedLibrary();
        await saveQueue();
        final repository = await seedSyncSession(database);
        final directory = await Directory.systemTemp.createTemp(
          'navis-reset-download-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final file = File.fromUri(directory.uri.resolve('b.mp3'));
        await file.writeAsBytes([1, 2, 3]);
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'b',
            filePath: file.path,
            fileSize: 3,
            format: 'mp3',
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );
        final items = await database.select(database.playQueueItemsTable).get();
        final resolver = PlaybackSourceResolver(
          cacheDao: database.cacheDao,
          libraryDao: database.libraryDao,
          rollingCacheManager: RollingCacheManager(cacheDao: database.cacheDao),
          readApiClient: () => null,
          readStreamingQuality: () => const StreamingQuality(label: 'wifi'),
          readRollingCacheDirectory: () async => directory,
        );
        await reset.reset();
        expect(
          (await resolver.resolveForSong(
            (await database.libraryDao.getSongById('b'))!,
          )).uri,
          file.uri,
        );
        final result = await serialDriftEngine(
          api: FakeLibrarySyncApi(),
          database: database,
          repository: repository,
        ).executeSyncPlan(syncPlanForTest(LibrarySyncPlanKind.fullRepair));
        expect(result.freshness, LibrarySyncFreshness.current);
        final missing = (await database.libraryDao.getSongById('b'))!;
        expect(missing.serverDeletedAt, isNotNull);
        expect(missing.catalogAvailability, 'confirmedMissing');
        expect(await database.libraryDao.searchSongsLocal('Old b'), isEmpty);
        expect((await resolver.resolveForSong(missing)).uri, file.uri);
        expect(file.existsSync(), isTrue);
        expect(
          await database.select(database.playQueueItemsTable).get(),
          items,
        );
      },
    );

    for (final albumRemoved in [false, true]) {
      test(
        'full rescan reconciles missing queued songs: albumRemoved=$albumRemoved',
        () async {
          await seedLibrary();
          await saveQueue();
          final repository = await seedSyncSession(database);
          await reset.reset();
          final api = FakeLibrarySyncApi();
          const song = Song(
            id: 'a',
            title: 'Fresh a',
            albumId: 'album',
            artistId: 'song-artist',
            artist: 'Fresh artist',
            album: 'Fresh album',
            duration: 200,
          );
          final album = Album(
            id: albumRemoved ? 'new-album' : 'album',
            name: 'Fresh album',
            artistId: 'song-artist',
            songCount: 1,
            songs: [
              if (albumRemoved)
                song.copyWith(id: 'new', albumId: 'new-album')
              else
                song,
            ],
          );
          api.artists.add(
            const Artist(id: 'song-artist', name: 'Fresh artist'),
          );
          api.fastPathPages[0] = [album];
          api.albumDetails[album.id] = album;
          final engine = serialDriftEngine(
            api: api,
            database: database,
            repository: repository,
          );
          final plan = syncPlanForTest(LibrarySyncPlanKind.fullRepair);
          final first = await engine.executeSyncPlan(plan);
          expect(first.status, LibrarySyncStatus.succeeded);
          // Reset references are outside the canonical catalog; the complete
          // rebuild can publish without deleting their queue occurrences.
          expect(first.freshness, LibrarySyncFreshness.current);
          final result = await engine.executeSyncPlan(plan);
          expect(result.status, LibrarySyncStatus.succeeded);
          expect(result.freshness, LibrarySyncFreshness.current);
          final missing = (await database.libraryDao.getSongById('b'))!;
          expect(missing.serverDeletedAt, isNotNull);
          expect(
            missing.catalogAvailability,
            CatalogAvailability.confirmedMissing.name,
          );
          expect(
            (await database.libraryDao.getAllSongs()).map((song) => song.id),
            isNot(contains('b')),
          );
          final loose = (await database.libraryDao.getSongById('loose'))!;
          expect(loose.albumId, isNull);
          expect(loose.artistId, isNull);
          expect(loose.serverDeletedAt, isNotNull);
          expect(loose.catalogAvailability, 'confirmedMissing');
          expect(await database.libraryDao.searchSongsLocal('Loose'), isEmpty);
          expect(await database.libraryDao.searchSongsLocal('Old b'), isEmpty);
          expect(
            (await database.playQueueDao.getQueueEntries()).map(
              (entry) => entry.song.id,
            ),
            ['a', 'b', 'a', 'c', 'loose'],
          );
          if (!albumRemoved) {
            final refreshed = (await database.libraryDao.getSongById('a'))!;
            expect(refreshed.title, 'Fresh a');
            expect(refreshed.artistName, 'Fresh artist');
            expect(refreshed.albumName, 'Fresh album');
            expect(refreshed.duration, 200);
            expect(refreshed.bitRate, isNull);
            expect(refreshed.coverArt, isNull);
            expect(refreshed.replayGainTrackGain, isNull);
            expect(refreshed.serverDeletedAt, isNull);
            expect(refreshed.isProvisional, isFalse);
          }
          // Startup restore uses this resolver. An absent song without a
          // permanent download is pruned through the existing cascade.
          final resolver = PlaybackSourceResolver(
            cacheDao: database.cacheDao,
            libraryDao: database.libraryDao,
            rollingCacheManager: RollingCacheManager(
              cacheDao: database.cacheDao,
            ),
            readApiClient: () => null,
            readStreamingQuality: () => const StreamingQuality(label: 'wifi'),
            readRollingCacheDirectory: () async => Directory.systemTemp,
          );
          await expectLater(
            resolver.resolveForSong(missing),
            throwsA(isA<PlaybackSourceUnavailableException>()),
          );
          expect(await database.libraryDao.getSongById('b'), isNull);
          expect(
            (await database.playQueueDao.getQueueItems()).map(
              (song) => song.id,
            ),
            isNot(contains('b')),
          );
        },
      );
    }
  }, skip: !sqliteAvailable);
}
