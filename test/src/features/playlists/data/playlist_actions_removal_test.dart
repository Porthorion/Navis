import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/models/playlist.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/playlists/data/playlist_actions.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/reachability_fakes.dart';
import '../../../../helpers/stub_library_sync_engine.dart';
import '../../../../helpers/test_database.dart';

class _MockApi extends Mock implements SubsonicApiClient;

const _server = ServerConfigModel(
  url: 'https://example.com',
  username: 'alice',
  password: 'secret',
  apiVersion: '1.16.1',
);
const _pl = PlaylistsTableData(isLocal: false, id: 'p', name: 'Mix');

/// The invisible row a Navidrome 0.64.2 multi-id add leaves behind.
const _ghost = '\u0000ghost';

/// A Navidrome 0.64.2 stand-in behind the real [PlaylistActions], sync
/// controller and database. Like the real server, a multi-index removal is
/// a silent no-op; a multi-id add adds nothing visible but inserts one hidden
/// row ([_ghost]) that `getPlaylist` omits while `songIndexToRemove` still
/// counts it; an empty replace is a no-op, and a hydration snapshots the
/// server when it starts and writes it when its gate opens (a slow
/// `getPlaylist`). [server] holds every row, hidden ones included; [visible]
/// is what `getPlaylist` returns.
class _Fixture {
  new(this.db, this.server) {
    when(
      () => api.updatePlaylist(
        id: 'p',
        songIndexesToRemove: any(named: 'songIndexesToRemove'),
      ),
    ).thenAnswer((i) async {
      final idx = i.namedArguments[#songIndexesToRemove] as List<int>;
      removeCalls.add(idx);
      if (idx.length == 1 && idx.single < server.length) {
        server.removeAt(idx.single);
      }
      return const Playlist(id: 'p', name: 'Mix');
    });
    when(
      () => api.updatePlaylist(
        id: 'p',
        songIdsToAdd: any(named: 'songIdsToAdd'),
      ),
    ).thenAnswer((i) async {
      final ids = i.namedArguments[#songIdsToAdd] as List<String>;
      multiAdds += ids.length > 1 ? 1 : 0;
      if (ids.length > 1) {
        server.add(_ghost);
      } else {
        server.addAll(ids);
      }
      return const Playlist(id: 'p', name: 'Mix');
    });
    when(
      () => api.replacePlaylistSongs(
        playlistId: 'p',
        songIds: any(named: 'songIds'),
      ),
    ).thenAnswer((i) async {
      final ids = i.namedArguments[#songIds] as List<String>;
      replaceCalls.add(ids);
      if (ids.isEmpty) return;
      server
        ..clear()
        ..addAll(ids);
    });
    when(() => api.getPlaylist('p')).thenAnswer(
      (_) async => Playlist(
        id: 'p',
        name: 'Mix',
        songCount: visible.length,
        entries: [for (final id in visible) Song(id: id, title: id)],
      ),
    );
    engine = StubLibrarySyncEngine((request, {onProgress}) async {
      if (request.target.kind != LibrarySyncTargetKind.playlist) {
        return const LibrarySyncState(
          status: LibrarySyncStatus.skipped,
          stage: LibrarySyncStage.completed,
        );
      }
      final snapshot = visible;
      final gate = Completer<void>();
      gates.add(gate);
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      await gate.future;
      await hydrate(db, snapshot);
      return LibrarySyncState(
        status: LibrarySyncStatus.succeeded,
        stage: LibrarySyncStage.completed,
        completedAt: DateTime.now(),
      );
    });
    container = ProviderContainer(
      overrides: [
        ...withTestDatabase(db),
        syncIntervalMinutesProvider.overrideWithValue(0),
        subsonicApiProvider.overrideWithValue(api),
        serverConfigStateProvider.overrideWithValue(const AsyncData(_server)),
        serverReachabilityControllerProvider.overrideWith(
          () => StaticReachabilityController(
            const ServerReachabilityState(
              status: ServerReachabilityStatus.online,
            ),
          ),
        ),
        librarySyncEngineProvider.overrideWithValue(engine),
        playlistSyncProvider.overrideWith((ref) async {}),
      ],
    );
    addTearDown(container.dispose);
    songs = container.listen(playlistSongsProvider('p'), (_, _) {});
    actions = container.read(playlistActionsProvider);
  }

  final NavisDatabase db;
  final List<String> server;
  final api = _MockApi();
  final removeCalls = <List<int>>[];
  final replaceCalls = <List<String>>[];
  int multiAdds = 0;
  final gates = <Completer<void>>[];
  late final StubLibrarySyncEngine engine;
  late final ProviderContainer container;
  late final ProviderSubscription<AsyncValue<List<SongsTableData>>> songs;
  late final PlaylistActions actions;

  List<String> get visible => [
    for (final id in server)
      if (id != _ghost) id,
  ];

  List<String> get shown =>
      songs.read().asData!.value.map((s) => s.id).toList();

  int get playlistRequests => engine.requests
      .where((r) => r.target.kind == LibrarySyncTargetKind.playlist)
      .length;

  /// Lets every hydration still waiting on its gate land, in start order.
  Future<void> landHydrations() async {
    var landed = 0;
    while (landed < gates.length) {
      final gate = gates[landed++];
      if (!gate.isCompleted) gate.complete();
      await pump();
    }
  }

  static Future<void> hydrate(NavisDatabase db, List<String> ids) =>
      db.playlistDao.replaceHydratedPlaylist(
        PlaylistsTableCompanion.insert(
          id: 'p',
          name: 'Mix',
          songCount: Value(ids.length),
        ),
        [for (final id in ids) SongsTableCompanion.insert(id: id, title: id)],
        [
          for (var i = 0; i < ids.length; i++)
            PlaylistSongsTableCompanion.insert(
              playlistId: 'p',
              songId: ids[i],
              sortOrder: i,
            ),
        ],
      );
}

/// A song the library already holds, as one picked from it is.
Future<void> _knowSong(NavisDatabase db, String id) =>
    db.libraryDao.upsertSongs([SongsTableCompanion.insert(id: id, title: id)]);

Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 50));

Future<_Fixture> _open(
  List<String> ids, {
  bool hydrating = true,
  int ghosts = 0,
}) async {
  final db = createTestDatabase();
  addTearDown(db.close);
  await _Fixture.hydrate(db, ids);
  final f = _Fixture(db, [for (var i = 0; i < ghosts; i++) _ghost, ...ids]);
  await pump();
  if (hydrating) {
    // What the open screen does: the detail sync starts a hydration.
    f.container.listen(playlistDetailSyncProvider('p'), (_, _) {});
    await pump();
    expect(f.playlistRequests, 1, reason: 'open hydration in flight');
  }
  return f;
}

void main() {
  test('removing B then C while a pre-removal hydration is in flight ends at [A, D]', () async {
    final f = await _open(['A', 'B', 'C', 'D']);
    await f.actions.removeAt(_pl, songId: 'B', occurrence: 0, copies: 1);
    await pump();
    expect(f.shown, ['A', 'C', 'D'], reason: 'list updated without waiting');
    await f.actions.removeAt(_pl, songId: 'C', occurrence: 0, copies: 1);
    await f.landHydrations();
    expect(f.server, ['A', 'D']);
    expect(f.shown, ['A', 'D']);
    // Each removal asked for its own hydration instead of joining the one
    // that started before it.
    expect(f.playlistRequests, 3);
    expect(f.removeCalls, [
      [1],
      [1],
    ]);
    expect(f.replaceCalls, isEmpty);
  }, skip: !sqliteAvailable);

  test('removes the chosen occurrence of a duplicated song', () async {
    final f = await _open(['A', 'B', 'A', 'C', 'A'], hydrating: false);
    await f.actions.removeAt(_pl, songId: 'A', occurrence: 1, copies: 3);
    await pump();
    expect(f.removeCalls, [
      [2],
    ]);
    expect(f.replaceCalls, isEmpty);
    expect(f.server, ['A', 'B', 'C', 'A']);
    expect(f.shown, ['A', 'B', 'C', 'A']);
  }, skip: !sqliteAvailable);

  test('a missing occurrence removes nothing', () async {
    final f = await _open(['A', 'B', 'A'], hydrating: false);
    await f.actions.removeAt(_pl, songId: 'A', occurrence: 5, copies: 2);
    expect(f.server, ['A', 'B', 'A']);
  }, skip: !sqliteAvailable);

  test('removing the same duplicate row twice keeps the other copy', () async {
    final f = await _open(['A', 'B', 'A'], hydrating: false);
    // The second tap comes from the screen that still showed two copies.
    final results = await Future.wait([
      f.actions
          .removeAt(_pl, songId: 'A', occurrence: 1, copies: 2)
          .then<Object?>((_) => null, onError: (Object e) => e),
      f.actions
          .removeAt(_pl, songId: 'A', occurrence: 1, copies: 2)
          .then<Object?>((_) => null, onError: (Object e) => e),
    ]);
    expect(results[0], isNull);
    expect(results[1], isA<PlaylistChangedException>());
    await f.landHydrations();
    expect(f.server, ['A', 'B']);
    expect(f.shown, ['A', 'B']);
  }, skip: !sqliteAvailable);

  test(
    'a double tap on the first of two copies removes only that copy',
    () async {
      final f = await _open(['A', 'B', 'A'], hydrating: false);
      final first = f.actions.removeAt(
        _pl,
        songId: 'A',
        occurrence: 0,
        copies: 2,
      );
      final repeat = expectLater(
        f.actions.removeAt(_pl, songId: 'A', occurrence: 0, copies: 2),
        throwsA(isA<PlaylistChangedException>()),
      );
      await first;
      await repeat;
      await f.landHydrations();
      expect(f.server, ['B', 'A']);
      expect(f.shown, ['B', 'A']);
    },
    skip: !sqliteAvailable,
  );

  test('a copy removed elsewhere makes a duplicate removal refuse', () async {
    final f = await _open(['A', 'B', 'A', 'A'], hydrating: false);
    f.server.removeAt(0);
    await expectLater(
      f.actions.removeAt(_pl, songId: 'A', occurrence: 1, copies: 3),
      throwsA(isA<PlaylistChangedException>()),
    );
    expect(f.removeCalls, isEmpty);
    expect(f.replaceCalls, isEmpty);
    expect(f.server, ['B', 'A', 'A']);
    // The edit still refreshes, so the screen shows the real list.
    await f.landHydrations();
    expect(f.shown, ['B', 'A', 'A']);
  }, skip: !sqliteAvailable);

  test('two fast removals both land on the chosen songs', () async {
    final f = await _open(['A', 'B', 'C', 'D'], hydrating: false);
    await Future.wait([
      f.actions.removeAt(_pl, songId: 'B', occurrence: 0, copies: 1),
      f.actions.removeAt(_pl, songId: 'C', occurrence: 0, copies: 1),
    ]);
    await f.landHydrations();
    expect(f.server, ['A', 'D']);
    expect(f.shown, ['A', 'D']);
  }, skip: !sqliteAvailable);

  test('a removal racing an add runs after it and keeps both', () async {
    final f = await _open(['A', 'B', 'C'], hydrating: false);
    await Future.wait([
      f.actions.addSongs(_pl, ['X']),
      f.actions.removeAt(_pl, songId: 'B', occurrence: 0, copies: 1),
    ]);
    await f.landHydrations();
    expect(f.server, ['A', 'C', 'X']);
    expect(f.shown, ['A', 'C', 'X']);
  }, skip: !sqliteAvailable);

  test('a song already removed elsewhere removes nothing else', () async {
    final f = await _open(['A', 'B', 'C'], hydrating: false);
    f.server.remove('B');
    await f.actions.removeAt(_pl, songId: 'B', occurrence: 0, copies: 1);
    expect(f.removeCalls, isEmpty);
    expect(f.replaceCalls, isEmpty);
    expect(f.server, ['A', 'C']);
  }, skip: !sqliteAvailable);

  test('a failed removal leaves the list and server untouched', () async {
    final f = await _open(['A', 'B'], hydrating: false);
    when(
      () => f.api.updatePlaylist(
        id: 'p',
        songIndexesToRemove: any(named: 'songIndexesToRemove'),
      ),
    ).thenThrow(StateError('boom'));
    await expectLater(
      f.actions.removeAt(_pl, songId: 'A', occurrence: 0, copies: 1),
      throwsStateError,
    );
    expect(f.shown, ['A', 'B']);
    // The failed edit may have changed the server: the screen still refreshes.
    expect(f.playlistRequests, 1);
  }, skip: !sqliteAvailable);

  test(
    'a reorder from a list that missed a removal throws and writes nothing',
    () async {
      final f = await _open(['A', 'B', 'C', 'D']);
      await f.actions.removeAt(_pl, songId: 'B', occurrence: 0, copies: 1);
      // Only the hydration that started before the removal lands: the screen
      // shows the removed song again.
      f.gates.first.complete();
      await pump();
      expect(f.shown, ['A', 'B', 'C', 'D']);
      await expectLater(
        f.actions.reorder(_pl, f.shown, 3, 0),
        throwsA(isA<PlaylistChangedException>()),
      );
      expect(f.server, ['A', 'C', 'D']);
      await f.landHydrations();
      expect(f.shown, ['A', 'C', 'D']);
    },
    skip: !sqliteAvailable,
  );

  test(
    'a reorder from a list that missed an add keeps the added song',
    () async {
      final f = await _open(['A', 'B']);
      await _knowSong(f.db, 'X');
      await f.actions.addSongs(_pl, ['X']);
      f.gates.first.complete();
      await pump();
      expect(f.shown, ['A', 'B']);
      await expectLater(
        f.actions.reorder(_pl, f.shown, 1, 0),
        throwsA(isA<PlaylistChangedException>()),
      );
      expect(f.server, ['A', 'B', 'X']);
    },
    skip: !sqliteAvailable,
  );

  test(
    'a reorder from the current list replaces and shows the new order',
    () async {
      final f = await _open(['A', 'B', 'C'], hydrating: false);
      await f.actions.reorder(_pl, f.shown, 2, 0);
      await pump();
      expect(f.server, ['C', 'A', 'B']);
      expect(f.shown, ['C', 'A', 'B']);
      await f.landHydrations();
      expect(f.shown, ['C', 'A', 'B']);
    },
    skip: !sqliteAvailable,
  );

  test(
    'an add while the open hydration is in flight shows the new song',
    () async {
      final f = await _open(['A', 'B']);
      await _knowSong(f.db, 'X');
      await f.actions.addSongs(_pl, ['X']);
      await pump();
      expect(f.shown, ['A', 'B', 'X'], reason: 'stored without waiting');
      await f.landHydrations();
      expect(f.server, ['A', 'B', 'X']);
      expect(f.shown, ['A', 'B', 'X']);
      expect(f.playlistRequests, 2, reason: 'own hydration, not the open one');
    },
    skip: !sqliteAvailable,
  );

  group('Navidrome 0.64 ghost row (#268)', () {
    test('an album add never sends a multi-id request', () async {
      final f = await _open(['A'], hydrating: false);
      for (final id in ['X', 'Y', 'Z']) {
        await _knowSong(f.db, id);
      }
      expect(await f.actions.addSongs(_pl, ['X', 'Y', 'Z']), (
        added: 3,
        alreadyThere: 0,
        failed: 0,
      ));
      expect(f.multiAdds, 0);
      expect(f.server, ['A', 'X', 'Y', 'Z'], reason: 'no hidden row left');
    }, skip: !sqliteAvailable);

    for (final (label, ids, song, occurrence, copies, after)
        in <(String, List<String>, String, int, int, List<String>)>[
          ('first', ['A', 'B', 'C', 'D'], 'A', 0, 1, ['B', 'C', 'D']),
          ('middle', ['A', 'B', 'C', 'D'], 'C', 0, 1, ['A', 'B', 'D']),
          ('last', ['A', 'B', 'C', 'D'], 'D', 0, 1, ['A', 'B', 'C']),
          (
            'second copy of a duplicate',
            ['A', 'B', 'C', 'B', 'D'],
            'B',
            1,
            2,
            ['A', 'B', 'C', 'D'],
          ),
        ]) {
      test(
        'removing the $label row deletes that row despite a ghost on top',
        () async {
          final f = await _open(ids, hydrating: false, ghosts: 1);
          await f.actions.removeAt(
            _pl,
            songId: song,
            occurrence: occurrence,
            copies: copies,
          );
          await f.landHydrations();
          expect(f.visible, after);
          expect(f.shown, after);
        },
        skip: !sqliteAvailable,
      );
    }

    test('a clean playlist makes one index call and no replace', () async {
      final f = await _open(['A', 'B', 'C'], hydrating: false);
      await f.actions.removeAt(_pl, songId: 'B', occurrence: 0, copies: 1);
      expect(f.server, ['A', 'C']);
      expect(f.removeCalls, [
        [1],
      ]);
      expect(f.replaceCalls, isEmpty);
    }, skip: !sqliteAvailable);

    test('a repair makes the next removal one exact index call', () async {
      final f = await _open(['A', 'B', 'C', 'D'], hydrating: false, ghosts: 1);
      await f.actions.removeAt(_pl, songId: 'A', occurrence: 0, copies: 1);
      expect(f.replaceCalls, [
        ['B', 'C', 'D'],
      ]);
      expect(f.server, ['B', 'C', 'D'], reason: 'ghost dropped');
      f.removeCalls.clear();
      await f.actions.removeAt(_pl, songId: 'C', occurrence: 0, copies: 1);
      expect(f.removeCalls, [
        [1],
      ]);
      expect(f.replaceCalls.length, 1);
      expect(f.server, ['B', 'D']);
    }, skip: !sqliteAvailable);

    test('a repair the server does not apply throws', () async {
      final f = await _open(['A', 'B', 'C'], hydrating: false, ghosts: 1);
      when(
        () => f.api.replacePlaylistSongs(
          playlistId: 'p',
          songIds: any(named: 'songIds'),
        ),
      ).thenAnswer((_) async {});
      await expectLater(
        f.actions.removeAt(_pl, songId: 'B', occurrence: 0, copies: 1),
        throwsStateError,
      );
    }, skip: !sqliteAvailable);

    for (final ghosts in [1, 2]) {
      test(
        'removing the last song behind $ghosts ghost(s) empties the playlist',
        () async {
          final f = await _open(['A'], hydrating: false, ghosts: ghosts);
          await f.actions.removeAt(_pl, songId: 'A', occurrence: 0, copies: 1);
          await f.landHydrations();
          expect(f.server, isEmpty);
          expect(f.shown, isEmpty);
          expect(f.removeCalls.length, ghosts + 1);
          expect(f.replaceCalls, isEmpty);
        },
        skip: !sqliteAvailable,
      );
    }

    test('removing the last song gives up after five index calls', () async {
      final f = await _open(['A'], hydrating: false, ghosts: 5);
      await expectLater(
        f.actions.removeAt(_pl, songId: 'A', occurrence: 0, copies: 1),
        throwsStateError,
      );
      expect(f.removeCalls.length, 5);
    }, skip: !sqliteAvailable);

    test('removing the last song of a clean playlist is one call', () async {
      final f = await _open(['A'], hydrating: false);
      await f.actions.removeAt(_pl, songId: 'A', occurrence: 0, copies: 1);
      expect(f.server, isEmpty);
      expect(f.removeCalls, [
        [0],
      ]);
    }, skip: !sqliteAvailable);

    test(
      'a removal from a changed list still refuses without writing',
      () async {
        final f = await _open(['A', 'B', 'A'], hydrating: false, ghosts: 1);
        f.server.remove('A');
        await expectLater(
          f.actions.removeAt(_pl, songId: 'A', occurrence: 1, copies: 2),
          throwsA(isA<PlaylistChangedException>()),
        );
        expect(f.replaceCalls, isEmpty);
        expect(f.removeCalls, isEmpty);
      },
      skip: !sqliteAvailable,
    );
  });
}
