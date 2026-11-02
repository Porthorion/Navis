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

class _MockApi extends Mock implements SubsonicApiClient {}

const _server = ServerConfigModel(
  url: 'https://example.com',
  username: 'alice',
  password: 'secret',
  apiVersion: '1.16.1',
);
const _pl = PlaylistsTableData(isLocal: false, id: 'p', name: 'Mix');

/// A Navidrome 0.64.2 stand-in behind the real [PlaylistActions], sync
/// controller and database. Like the real server, a multi-index removal is
/// a silent no-op, and a hydration snapshots the server when it starts and
/// writes it when its gate opens (a slow `getPlaylist`).
class _Fixture {
  _Fixture(this.db, this.server) {
    when(
      () => api.updatePlaylist(
        id: 'p',
        songIndexesToRemove: any(named: 'songIndexesToRemove'),
      ),
    ).thenAnswer((i) async {
      final idx = i.namedArguments[#songIndexesToRemove] as List<int>;
      removeCalls.add(idx);
      if (idx.length == 1) server.removeAt(idx.single);
      return const Playlist(id: 'p', name: 'Mix');
    });
    when(
      () => api.updatePlaylist(
        id: 'p',
        songIdsToAdd: any(named: 'songIdsToAdd'),
      ),
    ).thenAnswer((i) async {
      server.addAll(i.namedArguments[#songIdsToAdd] as List<String>);
      return const Playlist(id: 'p', name: 'Mix');
    });
    when(() => api.getPlaylist('p')).thenAnswer(
      (_) async => Playlist(
        id: 'p',
        name: 'Mix',
        songCount: server.length,
        entries: [for (final id in server) Song(id: id, title: id)],
      ),
    );
    engine = StubLibrarySyncEngine((request, {onProgress}) async {
      if (request.target.kind != LibrarySyncTargetKind.playlist) {
        return const LibrarySyncState(
          status: LibrarySyncStatus.skipped,
          stage: LibrarySyncStage.completed,
        );
      }
      final snapshot = List<String>.of(server);
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
  final gates = <Completer<void>>[];
  late final StubLibrarySyncEngine engine;
  late final ProviderContainer container;
  late final ProviderSubscription<AsyncValue<List<SongsTableData>>> songs;
  late final PlaylistActions actions;

  List<String> get shown =>
      songs.read().asData!.value.map((s) => s.id).toList();

  int get playlistRequests => engine.requests
      .where((r) => r.target.kind == LibrarySyncTargetKind.playlist)
      .length;

  /// Lets every hydration still waiting on its gate land, in start order.
  Future<void> landHydrations() async {
    var landed = 0;
    while (landed < gates.length) {
      gates[landed++].complete();
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

Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 50));

Future<_Fixture> _open(List<String> ids, {bool hydrating = true}) async {
  final db = createTestDatabase();
  addTearDown(db.close);
  await _Fixture.hydrate(db, ids);
  final f = _Fixture(db, List.of(ids));
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
    await f.actions.removeAt(_pl, songId: 'B', occurrence: 0);
    await pump();
    expect(f.shown, ['A', 'C', 'D'], reason: 'list updated without waiting');
    await f.actions.removeAt(_pl, songId: 'C', occurrence: 0);
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
  }, skip: !sqliteAvailable);

  test('removes the chosen occurrence of a duplicated song', () async {
    final f = await _open(['A', 'B', 'A', 'C', 'A'], hydrating: false);
    await f.actions.removeAt(_pl, songId: 'A', occurrence: 1);
    await pump();
    expect(f.removeCalls, [
      [2],
    ]);
    expect(f.server, ['A', 'B', 'C', 'A']);
    expect(f.shown, ['A', 'B', 'C', 'A']);
  }, skip: !sqliteAvailable);

  test('fewer occurrences than expected removes the last one', () async {
    final f = await _open(['A', 'B', 'A'], hydrating: false);
    await f.actions.removeAt(_pl, songId: 'A', occurrence: 5);
    expect(f.server, ['A', 'B']);
  }, skip: !sqliteAvailable);

  test('two fast removals both land on the chosen songs', () async {
    final f = await _open(['A', 'B', 'C', 'D'], hydrating: false);
    await Future.wait([
      f.actions.removeAt(_pl, songId: 'B', occurrence: 0),
      f.actions.removeAt(_pl, songId: 'C', occurrence: 0),
    ]);
    await f.landHydrations();
    expect(f.server, ['A', 'D']);
    expect(f.shown, ['A', 'D']);
  }, skip: !sqliteAvailable);

  test('a removal racing an add runs after it and keeps both', () async {
    final f = await _open(['A', 'B', 'C'], hydrating: false);
    await Future.wait([
      f.actions.addSongs(_pl, ['X']),
      f.actions.removeAt(_pl, songId: 'B', occurrence: 0),
    ]);
    await f.landHydrations();
    expect(f.server, ['A', 'C', 'X']);
    expect(f.shown, ['A', 'C', 'X']);
  }, skip: !sqliteAvailable);

  test('a song already removed elsewhere removes nothing else', () async {
    final f = await _open(['A', 'B', 'C'], hydrating: false);
    f.server.remove('B');
    await f.actions.removeAt(_pl, songId: 'B', occurrence: 0);
    expect(f.removeCalls, isEmpty);
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
      f.actions.removeAt(_pl, songId: 'A', occurrence: 0),
      throwsStateError,
    );
    expect(f.shown, ['A', 'B']);
    expect(f.playlistRequests, 0);
  }, skip: !sqliteAvailable);
}
