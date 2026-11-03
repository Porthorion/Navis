import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';

import '../../../../helpers/library_sync_fakes.dart';
import '../../../../helpers/library_sync_plan.dart';
import '../../../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;
  late ServerConfigRepository repository;
  late FakeLibrarySyncApi api;

  // Nine single-song albums: enough for the bulk song fast path to apply.
  const taggedSongs = <Song>[
    Song(
      id: 'song-1',
      title: 'Song 1',
      albumId: 'album-1',
      artistId: 'artist-1',
      genres: ['Hip Hop', 'Rock'],
    ),
    Song(
      id: 'song-2',
      title: 'Song 2',
      albumId: 'album-2',
      artistId: 'artist-1',
      genres: ['Jazz'],
    ),
  ];

  List<Song> allSongs([List<Song> tagged = taggedSongs]) => [
    ...tagged,
    for (var n = 3; n <= 9; n++)
      Song(
        id: 'song-$n',
        title: 'Song $n',
        albumId: 'album-$n',
        artistId: 'artist-1',
      ),
  ];

  setUp(() async {
    database = NavisDatabase(NativeDatabase.memory());
    repository = await seedSyncSession(database);
    api = FakeLibrarySyncApi();
    api.artists.add(const Artist(id: 'artist-1', name: 'Artist 1'));
    api.fastPathPages[0] = List<Album>.generate(
      9,
      (index) => Album(
        id: 'album-${index + 1}',
        name: 'Album ${index + 1}',
        artist: 'Artist 1',
        artistId: 'artist-1',
        songCount: 1,
      ),
    );
  });
  tearDown(() => database.close());

  Future<Map<String, List<String>>> indexed() async {
    final rows = await database
        .customSelect(
          'SELECT song_id, genre_key FROM song_genre_index '
          'ORDER BY song_id, genre_key',
        )
        .get();
    final byKey = <String, List<String>>{};
    for (final row in rows) {
      (byKey[row.read<String>('song_id')] ??= []).add(
        row.read<String>('genre_key'),
      );
    }
    return byKey;
  }

  Future<void> expectGenresLanded() async {
    final stored = {
      for (final song in await database.select(database.songsTable).get())
        song.id: song.genres,
    };
    expect(stored, hasLength(9));
    expect(stored['song-1'], ['Hip Hop', 'Rock']);
    expect(stored['song-2'], ['Jazz']);
    expect(stored['song-3'], isEmpty);
    expect(await indexed(), {
      'song-1': ['hiphop', 'rock'],
      'song-2': ['jazz'],
    });
  }

  test('genres land in songs and the index through getAlbum', () async {
    for (final song in allSongs()) {
      api.albumDetails[song.albumId!] = Album(
        id: song.albumId!,
        name: 'Album',
        songs: [song],
      );
    }
    final engine = serialDriftEngine(
      api: api,
      database: database,
      repository: repository,
    );

    final state = await engine.executeSyncPlan(
      syncPlanForTest(LibrarySyncPlanKind.fullRepair),
    );

    expect(state.status, LibrarySyncStatus.succeeded);
    expect(api.calls.where((c) => c.startsWith('getAlbum:')), isNotEmpty);
    await expectGenresLanded();
  }, skip: !sqliteAvailable);

  test('genres land in songs and the index through search3', () async {
    api.bulkSongPages[0] = allSongs();
    final engine = serialDriftEngine(
      api: api,
      database: database,
      repository: repository,
    );

    final state = await engine.executeSyncPlan(
      syncPlanForTest(LibrarySyncPlanKind.fullRepair),
    );

    expect(state.status, LibrarySyncStatus.succeeded);
    expect(api.calls.where((c) => c.startsWith('getAlbum:')), isEmpty);
    await expectGenresLanded();
  }, skip: !sqliteAvailable);

  test(
    'upgrade: rows with null genres are filled by one forced sync',
    () async {
      api.bulkSongPages[0] = allSongs([
        taggedSongs[0],
        taggedSongs[1].copyWith(genres: const []),
      ]);
      final engine = serialDriftEngine(
        api: api,
        database: database,
        repository: repository,
      );
      await engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.fullRepair),
      );
      // Put the library back as the previous release left it.
      await database.customStatement('UPDATE songs SET genres = NULL');
      await database.customStatement('DELETE FROM song_genre_index');

      api.bulkSongPages[0] = allSongs();
      await engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.fullRepair),
      );

      await expectGenresLanded();
      // Untagged songs become [] too, so null never means "untagged" for long.
      final untagged = await (database.select(
        database.songsTable,
      )..where((t) => t.id.equals('song-5'))).getSingle();
      expect(untagged.genres, isNotNull);
      expect(untagged.genres, isEmpty);
    },
    skip: !sqliteAvailable,
  );

  test(
    'a server retag reaches the song and the index on the next sync',
    () async {
      api.bulkSongPages[0] = allSongs();
      final engine = serialDriftEngine(
        api: api,
        database: database,
        repository: repository,
      );
      await engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.fullRepair),
      );

      api.bulkSongPages[0] = [
        taggedSongs[0],
        taggedSongs[1].copyWith(genres: const ['Blues']),
      ];
      await engine.executeSyncPlan(
        syncPlanForTest(LibrarySyncPlanKind.fullRepair),
      );

      expect(await indexed(), {
        'song-1': ['hiphop', 'rock'],
        'song-2': ['blues'],
      });
    },
    skip: !sqliteAvailable,
  );

  test('clearLibraryData empties the genre index', () async {
    api.bulkSongPages[0] = allSongs();
    final engine = serialDriftEngine(
      api: api,
      database: database,
      repository: repository,
    );
    await engine.executeSyncPlan(
      syncPlanForTest(LibrarySyncPlanKind.fullRepair),
    );
    expect(await indexed(), isNotEmpty);

    await database.libraryDao.clearLibraryData();

    expect(await indexed(), isEmpty);
  }, skip: !sqliteAvailable);

  test('external rows are not indexed', () async {
    await database.libraryDao.upsertSongs([
      SongsTableCompanion.insert(
        id: 'remote-1',
        title: 'Remote',
        genres: const Value(['Rock']),
        isExternal: const Value(true),
      ),
      SongsTableCompanion.insert(
        id: 'local-1',
        title: 'Local',
        genres: const Value(['Rock']),
      ),
    ]);

    await database.libraryDao.refreshSongGenreIndex();

    expect(await indexed(), {
      'local-1': ['rock'],
    });
  }, skip: !sqliteAvailable);
}
