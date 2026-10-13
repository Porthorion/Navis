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
        unorderedEquals(songs),
      );
      expect(
        (await database.select(database.albumsTable).get()).map(
          (row) => row.toJson(),
        ),
        albums.map((row) => row.toJson()),
      );
      expect(
        await database.select(database.artistsTable).get(),
        unorderedEquals(artists),
      );
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
          // This fixture loses most of its catalog. Normal deletion safety
          // requires the same complete snapshot twice before promotion.
          expect(first.freshness, LibrarySyncFreshness.repairRecommended);
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
