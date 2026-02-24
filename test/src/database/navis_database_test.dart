import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import '../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;

  setUp(() {
    database = NavisDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  test(
    'creates all core tables',
    () async {
      final rows = await database
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table'",
          )
          .get();

      final names = rows.map((row) => row.read<String>('name')).toSet();

      expect(names, contains('server_config'));
      expect(names, contains('artists'));
      expect(names, contains('albums'));
      expect(names, contains('songs'));
      expect(names, contains('play_queue'));
    },
    skip: !sqliteAvailable,
  );

  test(
    'enforces foreign keys',
    () async {
      await expectLater(
        database
            .into(database.playlistSongsTable)
            .insert(
              PlaylistSongsTableCompanion.insert(
                playlistId: 'missing-playlist',
                songId: 'missing-song',
                sortOrder: 0,
              ),
            ),
        throwsA(isA<Exception>()),
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'reactive artist stream emits after replace',
    () async {
      final emitted = database.libraryDao.watchArtists().firstWhere(
        (artists) => artists.isNotEmpty,
      );

      await database.libraryDao.replaceArtists(
        <ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(
            id: 'a1',
            name: 'Artist One',
          ),
        ],
      );

      final artists = await emitted;
      expect(artists.single.id, 'a1');
      expect(artists.single.name, 'Artist One');
    },
    skip: !sqliteAvailable,
  );

  test(
    'play queue dao persists and restores queue',
    () async {
      await database
          .into(database.songsTable)
          .insert(
            SongsTableCompanion.insert(
              id: 's1',
              title: 'Song 1',
            ),
          );

      await database.playQueueDao.saveQueue(
        currentIndex: 0,
        songIds: const <String>['s1'],
        shuffleMode: ShuffleMode.off,
        repeatMode: RepeatMode.off,
        positionMs: 4200,
      );

      final state = await database.playQueueDao.watchQueueState().firstWhere(
        (value) => value != null,
      );
      final items = await database.playQueueDao.watchQueueItems().firstWhere(
        (value) => value.isNotEmpty,
      );

      expect(state?.currentIndex, 0);
      expect(state?.positionMs, 4200);
      expect(items.single.id, 's1');
    },
    skip: !sqliteAvailable,
  );

  test(
    'play queue state updates without rewriting queue items',
    () async {
      await database
          .into(database.songsTable)
          .insert(SongsTableCompanion.insert(id: 's1', title: 'Song 1'));
      await database
          .into(database.songsTable)
          .insert(SongsTableCompanion.insert(id: 's2', title: 'Song 2'));

      await database.playQueueDao.saveQueue(
        currentIndex: 0,
        songIds: const <String>['s1', 's2'],
        shuffleMode: ShuffleMode.off,
        repeatMode: RepeatMode.off,
        positionMs: 1000,
      );

      await database.playQueueDao.savePlaybackState(
        currentIndex: 1,
        shuffleMode: ShuffleMode.all,
        repeatMode: RepeatMode.one,
        positionMs: 9200,
      );

      final state = await database.playQueueDao.getQueueState();
      final items = await database.playQueueDao.getQueueItems();

      expect(state?.currentIndex, 1);
      expect(state?.positionMs, 9200);
      expect(state?.shuffleMode, ShuffleMode.all);
      expect(state?.repeatMode, RepeatMode.one);
      expect(items.map((song) => song.id).toList(), <String>['s1', 's2']);
    },
    skip: !sqliteAvailable,
  );

  test(
    'albums paging returns SQL-sorted deterministic page',
    () async {
      await database.libraryDao.replaceAlbums(
        <AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'a-2024-b',
            name: 'Beta',
            year: const Value(2024),
          ),
          AlbumsTableCompanion.insert(
            id: 'a-2025-a',
            name: 'Alpha',
            year: const Value(2025),
          ),
          AlbumsTableCompanion.insert(
            id: 'a-2024-a',
            name: 'Alpha',
            year: const Value(2024),
          ),
        ],
      );

      final page = await database.libraryDao
          .watchAlbumsPage(sort: AlbumSortOrder.newest, limit: 2)
          .first;
      expect(page.length, 2);
      expect(page[0].id, 'a-2025-a');
      expect(page[1].id, 'a-2024-a');
    },
    skip: !sqliteAvailable,
  );

  test(
    'pending hydration query returns only non-hydrated albums',
    () async {
      await database.libraryDao.replaceAlbums(
        <AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'hydrated',
            name: 'Hydrated',
            songsHydrated: const Value(true),
          ),
          AlbumsTableCompanion.insert(
            id: 'pending-1',
            name: 'Pending 1',
            songsHydrated: const Value(false),
          ),
          AlbumsTableCompanion.insert(
            id: 'pending-2',
            name: 'Pending 2',
            songsHydrated: const Value(false),
          ),
        ],
      );

      final pendingCount = await database.libraryDao
          .countPendingHydrationAlbums();
      final pendingRows = await database.libraryDao.getPendingHydrationAlbums(
        limit: 10,
      );
      final pendingIds = pendingRows.map((row) => row.id).toSet();

      expect(pendingCount, 2);
      expect(pendingIds, containsAll(<String>{'pending-1', 'pending-2'}));
      expect(pendingIds, isNot(contains('hydrated')));
    },
    skip: !sqliteAvailable,
  );
}
