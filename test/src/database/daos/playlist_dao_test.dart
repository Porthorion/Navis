import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';

import '../../../helpers/test_database.dart';

void main() {
  group('device playlists', () {
    late NavisDatabase database;

    setUp(() async {
      database = createTestDatabase();
      await database.libraryDao.upsertSongs([
        SongsTableCompanion.insert(
          id: 'a',
          title: 'A',
          duration: const Value(12),
          coverArt: const Value('art-a'),
        ),
        SongsTableCompanion.insert(id: 'b', title: 'B'),
      ]);
    });
    tearDown(() => database.close());

    test(
      'creates unique local IDs, allows duplicate names and occurrences',
      () async {
        final dao = database.playlistDao;
        final id = await dao.createLocalPlaylist('Mix', [
          'a',
          'missing',
          'a',
          'b',
        ]);
        final other = await dao.createLocalPlaylist('Mix', []);
        expect(id, matches(RegExp(r'^local:[0-9a-f-]{36}$')));
        expect(other, isNot(id));
        final row = (await dao.watchPlaylistById(id).first)!;
        expect(row.isLocal, isTrue);
        expect(row.songCount, 3);
        expect(row.duration, 24);
        expect(row.coverArt, 'art-a');
        expect((await dao.watchPlaylistSongs(id).first).map((s) => s.id), [
          'a',
          'a',
          'b',
        ]);
      },
    );

    test(
      'rewrites order, skips unknown occurrences and clears empty metadata',
      () async {
        final dao = database.playlistDao;
        final id = await dao.createLocalPlaylist('Mix', ['a']);
        expect(
          await dao.setLocalPlaylistSongs(id, ['gone', 'b', 'a', 'gone', 'a']),
          2,
        );
        var row = (await dao.watchPlaylistById(id).first)!;
        expect((row.songCount, row.duration, row.coverArt), (3, 24, null));
        final joins = await (database.select(
          database.playlistSongsTable,
        )..orderBy([(t) => OrderingTerm.asc(t.sortOrder)])).get();
        expect(joins.map((j) => (j.songId, j.sortOrder)), [
          ('b', 0),
          ('a', 1),
          ('a', 2),
        ]);
        await dao.renamePlaylist(id, 'Renamed');
        expect((await dao.watchPlaylistById(id).first)!.name, 'Renamed');
        expect(await dao.setLocalPlaylistSongs(id, ['gone']), 1);
        row = (await dao.watchPlaylistById(id).first)!;
        expect((row.songCount, row.duration, row.coverArt), (0, 0, null));
        expect(await dao.watchPlaylistSongs(id).first, isEmpty);
      },
    );

    test('renaming only touches device playlists', () async {
      final dao = database.playlistDao;
      await dao.upsertPlaylists([
        PlaylistsTableCompanion.insert(id: 'server', name: 'Server'),
      ]);
      await dao.renamePlaylist('server', 'Renamed');
      expect((await dao.watchPlaylistById('server').first)!.name, 'Server');
    });

    test('a failed join insert rolls back songs and header together', () async {
      final dao = database.playlistDao;
      final id = await dao.createLocalPlaylist('Mix', ['a']);
      await database.customStatement(
        "CREATE TRIGGER reject_b BEFORE INSERT ON playlist_songs WHEN NEW.song_id = 'b' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END",
      );
      await expectLater(
        dao.setLocalPlaylistSongs(id, ['b']),
        throwsA(anything),
      );
      expect((await dao.watchPlaylistSongs(id).first).map((s) => s.id), ['a']);
      final row = (await dao.watchPlaylistById(id).first)!;
      expect((row.songCount, row.duration, row.coverArt), (1, 12, 'art-a'));
      await expectLater(
        dao.createLocalPlaylist('Broken', ['b']),
        throwsA(anything),
      );
      expect((await dao.watchPlaylists().first).map((p) => p.id), [id]);
    });

    test('local replacement refuses missing or server playlists', () async {
      final dao = database.playlistDao;
      await dao.upsertPlaylists([
        PlaylistsTableCompanion.insert(id: 'server', name: 'Server'),
      ]);
      for (final id in ['server', 'missing']) {
        await expectLater(
          dao.setLocalPlaylistSongs(id, ['a']),
          throwsStateError,
        );
      }
      expect(await dao.watchPlaylistSongs('server').first, isEmpty);
      expect((await dao.watchPlaylistById('server').first)!.songCount, isNull);
    });

    test('handles more song IDs than SQLite parameter limits', () async {
      final dao = database.playlistDao;
      final ids = List.generate(1100, (i) => 'song-$i');
      await database.libraryDao.upsertSongs([
        for (final id in ids) SongsTableCompanion.insert(id: id, title: id),
      ]);
      final id = await dao.createLocalPlaylist('Large', ids);
      expect(await dao.watchPlaylistSongs(id).first, hasLength(1100));
    });
  }, skip: !sqliteAvailable);

  test('watchPlaylists mixes local and server names ignoring case', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    await database.playlistDao.upsertPlaylists([
      PlaylistsTableCompanion.insert(id: 'server:z', name: 'Zulu'),
      PlaylistsTableCompanion.insert(
        id: 'local:a',
        name: 'alpha',
        isLocal: const Value(true),
      ),
      PlaylistsTableCompanion.insert(id: 'server:b', name: 'Bravo'),
    ]);
    expect(
      (await database.playlistDao.watchPlaylists().first).map((p) => p.id),
      ['local:a', 'server:b', 'server:z'],
    );
  }, skip: !sqliteAvailable);

  for (final serverIds in <List<String>>[
    [],
    ['server:kept'],
  ]) {
    test(
      'server reconciliation preserves device entries, serverIds=$serverIds',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        await database
            .into(database.songsTable)
            .insert(SongsTableCompanion.insert(id: 'song', title: 'Song'));
        await database.customStatement(
          "INSERT INTO playlists (id, name, is_local) VALUES ('local:list', 'Device list', 1), ('local:empty', 'Empty device list', 1), ('server:stale', 'Stale', 0), ('server:kept', 'Old name', 0)",
        );
        await database.customStatement(
          "INSERT INTO playlist_songs VALUES ('local:list', 'song', 0), ('local:list', 'song', 1), ('server:stale', 'song', 0), ('server:kept', 'song', 0)",
        );
        await database.playlistDao.reconcileServerPlaylists([
          for (final id in serverIds)
            PlaylistsTableCompanion.insert(id: id, name: 'Server list'),
        ], serverIds);
        expect(
          (await database.select(database.playlistsTable).get()).map(
            (p) => p.id,
          ),
          unorderedEquals(['local:list', 'local:empty', ...serverIds]),
        );
        expect(
          (await database.playlistDao.watchPlaylistSongs('local:list').first)
              .map((s) => s.id),
          ['song', 'song'],
        );
        expect(
          await database.playlistDao.watchPlaylistSongs('server:stale').first,
          isEmpty,
        );
        expect(
          await database.playlistDao.watchPlaylistSongs('server:kept').first,
          hasLength(serverIds.isEmpty ? 0 : 1),
        );
        expect(await database.select(database.songsTable).get(), hasLength(1));
        expect(
          (await database.playlistDao.getServerPlaylists()).map((p) => p.id),
          unorderedEquals(serverIds),
        );
      },
      skip: !sqliteAvailable,
    );
  }

  test(
    'playback cleanup keeps songs that device playlists still hold',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      // Both songs are confirmed missing on the server.
      await database.customStatement(
        "INSERT INTO songs (id, title, server_deleted_at) VALUES "
        "('in-device', 'Device song', 1), ('server-only', 'Server song', 1)",
      );
      await database.customStatement(
        "INSERT INTO playlists (id, name, is_local) VALUES "
        "('local:list', 'Device list', 1), ('server:list', 'Server list', 0)",
      );
      await database.customStatement(
        "INSERT INTO playlist_songs VALUES ('local:list', 'in-device', 0), "
        "('server:list', 'server-only', 0)",
      );

      await database.libraryDao.deleteLocalOnlySong('in-device');
      await database.libraryDao.deleteLocalOnlySong('server-only');

      expect(
        (await database.playlistDao.watchPlaylistSongs('local:list').first).map(
          (s) => s.id,
        ),
        ['in-device'],
      );
      expect(
        (await database.select(database.songsTable).get()).map((s) => s.id),
        ['in-device'],
      );
    },
    skip: !sqliteAvailable,
  );
}
