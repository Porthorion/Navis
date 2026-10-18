import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/cache/data/cache_system_upgrade_service.dart';
import 'package:navis/src/features/cache/data/library_cache_reset_service.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';

import '../../../../helpers/library_sync_fakes.dart';
import '../../../../helpers/library_sync_plan.dart';
import '../../../../helpers/test_database.dart';

const _ownedIds = ['history', 'scrobble', 'feedback'];

void main() {
  late NavisDatabase database;

  setUp(() => database = createTestDatabase());
  tearDown(() => database.close());

  Future<void> seed() async {
    await database.libraryDao.upsertArtists([
      for (final id in ['artist', 'album-artist', 'unused'])
        ArtistsTableCompanion.insert(id: id, name: id),
    ]);
    await database.libraryDao.upsertAlbums([
      for (final id in ['album', 'unused'])
        AlbumsTableCompanion.insert(
          id: id,
          name: id,
          artistId: Value(id == 'album' ? 'album-artist' : 'unused'),
        ),
    ]);
    await database.libraryDao.upsertSongs([
      for (final id in [..._ownedIds, 'unreferenced'])
        SongsTableCompanion.insert(
          id: id,
          title: id,
          albumId: const Value('album'),
          artistId: const Value('artist'),
        ),
      SongsTableCompanion.insert(
        id: 'unused',
        title: 'Unused',
        albumId: const Value('unused'),
        artistId: const Value('unused'),
      ),
    ]);
    final now = DateTime(2026, 10, 18);
    await database
        .into(database.playHistoryTable)
        .insert(
          PlayHistoryTableCompanion.insert(songId: 'history', playedAt: now),
        );
    await database
        .into(database.scrobbleQueueTable)
        .insert(
          ScrobbleQueueTableCompanion.insert(
            songId: 'scrobble',
            provider: const Value('lastfm'),
            submission: true,
            trackTitle: const Value('Captured title'),
            createdAt: now,
            nextAttemptAt: now,
            expiresAt: now.add(const Duration(days: 7)),
            sessionKey: 'fixture',
            attempts: const Value(2),
          ),
        );
    await database
        .into(database.listenBrainzFeedbackQueueTable)
        .insert(
          ListenBrainzFeedbackQueueTableCompanion.insert(
            songId: 'feedback',
            score: 1,
            title: 'Captured feedback',
            artist: 'Artist',
            queuedAt: now,
            nextAttemptAt: now,
            attempts: const Value(3),
          ),
        );
  }

  Future<List<Object>> userRows() async => [
    ...await database.select(database.playHistoryTable).get(),
    ...await database.select(database.scrobbleQueueTable).get(),
    ...await database.select(database.listenBrainzFeedbackQueueTable).get(),
  ];

  Future<void> expectRetained() async {
    final songs = await database.select(database.songsTable).get();
    expect(songs.map((song) => song.id), unorderedEquals(_ownedIds));
    expect(songs.every((song) => song.isProvisional), isTrue);
    expect(
      songs.every((song) => song.catalogAvailability == 'pendingRebuild'),
      isTrue,
    );
    expect(
      (await database.select(database.albumsTable).get()).single.isProvisional,
      isTrue,
    );
    final artists = await database.select(database.artistsTable).get();
    expect(
      artists.map((artist) => artist.id),
      unorderedEquals(['artist', 'album-artist']),
    );
    expect(artists.every((artist) => artist.isProvisional), isTrue);
    expect(
      await database.customSelect('PRAGMA foreign_key_check').get(),
      isEmpty,
    );
  }

  for (final entry in [
    'clearLibraryData',
    'Reset Caches',
    'upgrade 1004 → 1005',
  ]) {
    test('$entry preserves listening history and queued submissions', () async {
      await seed();
      final before = await userRows();
      final reset = LibraryCacheResetService(database: database);
      switch (entry) {
        case 'clearLibraryData':
          await database.libraryDao.clearLibraryData();
        case 'Reset Caches':
          await reset.reset();
        default:
          await database.cacheSystemStateDao.markVersion(1004);
          final upgrade = CacheSystemUpgradeService(
            database: database,
            cacheResetService: reset,
            currentEpoch: () async => 1005,
            hasCommittedCatalog: () async => true,
            triggerFullLibraryScan: () async {
              expect(await userRows(), before);
              await expectRetained();
              expect(await database.cacheSystemStateDao.getVersion(), 1004);
              return true;
            },
          );
          expect(await upgrade.needsReset(), isTrue);
          await upgrade.resetAndMarkCurrent();
          expect(await database.cacheSystemStateDao.getVersion(), 1005);
          expect(await upgrade.needsReset(), isFalse);
      }
      expect(await userRows(), before);
      await expectRetained();
      // Repeated resets and the existing provisional GC must also be safe.
      await reset.reset();
      await database.songIdentityDao
          .garbageCollectUnreferencedProvisionalMetadata();
      expect(await userRows(), before);
      await expectRetained();
    }, skip: !sqliteAvailable);
  }

  test(
    'rescan reconfirms history and submission songs, retains missing ones',
    () async {
      await seed();
      final before = await userRows();
      final repository = await seedSyncSession(database);
      await LibraryCacheResetService(database: database).reset();
      final album = Album(
        id: 'album',
        name: 'Fresh album',
        artistId: 'artist',
        artist: 'Fresh artist',
        songCount: _ownedIds.length,
        songs: [
          for (final id in _ownedIds)
            Song(
              id: id,
              title: 'Fresh $id',
              albumId: 'album',
              album: 'Fresh album',
              artistId: 'artist',
              artist: 'Fresh artist',
            ),
        ],
      );
      final api = FakeLibrarySyncApi()
        ..artists.add(
          const Artist(id: 'artist', name: 'Fresh artist', albumCount: 1),
        )
        ..fastPathPages[0] = [album]
        ..albumDetails['album'] = album;
      final engine = serialDriftEngine(
        api: api,
        database: database,
        repository: repository,
      );
      final result = await engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.fullRepair),
      );
      expect(result.freshness, LibrarySyncFreshness.current);
      expect(await userRows(), before);
      for (final id in _ownedIds) {
        final song = (await database.libraryDao.getSongById(id))!;
        expect(song.title, 'Fresh $id');
        expect(song.isProvisional, isFalse);
        expect(song.catalogAvailability, isNull);
      }
      expect(
        (await database.libraryDao.getAlbumById('album'))!.isProvisional,
        isFalse,
      );
      expect(
        (await database.libraryDao.getArtistById('artist'))!.isProvisional,
        isFalse,
      );

      await LibraryCacheResetService(database: database).reset();
      final missing = await serialDriftEngine(
        api: FakeLibrarySyncApi(),
        database: database,
        repository: repository,
      ).executeSyncPlan(syncPlanForTest(LibrarySyncPlanKind.fullRepair));
      expect(missing.freshness, LibrarySyncFreshness.current);
      expect(await userRows(), before);
      for (final id in _ownedIds) {
        final song = (await database.libraryDao.getSongById(id))!;
        expect(song.isProvisional, isTrue);
        expect(song.serverDeletedAt, isNotNull);
        expect(song.catalogAvailability, 'confirmedMissing');
      }
      expect(await database.libraryDao.getAllSongs(), isEmpty);
      expect(
        await database.customSelect('PRAGMA foreign_key_check').get(),
        isEmpty,
      );
    },
    skip: !sqliteAvailable,
  );
}
