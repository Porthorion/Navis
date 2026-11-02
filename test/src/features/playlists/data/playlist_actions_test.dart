import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/models/playlist.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/playlists/data/playlist_actions.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_database.dart';

class _MockApi extends Mock implements SubsonicApiClient;

const _playlist = PlaylistsTableData(isLocal: false, id: 'p', name: 'Mix');
const _response = Playlist(id: 'p', name: 'Mix');

/// Records the refresh requests an edit makes instead of syncing.
class _Sync extends LibrarySyncController {
  new(this.requests);

  final List<(LibrarySyncTarget, bool)> requests;

  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> requestTarget(
    LibrarySyncTarget target, {
    bool requireFresh = false,
  }) async {
    requests.add((target, requireFresh));
    return const LibrarySyncState.idle();
  }
}

void main() {
  late _MockApi api;
  late ProviderContainer container;
  late PlaylistActions actions;
  late int headerSyncs;
  late int detailSyncs;
  late List<(LibrarySyncTarget, bool)> requests;
  late NavisDatabase db;

  setUp(() {
    api = _MockApi();
    headerSyncs = 0;
    detailSyncs = 0;
    requests = [];
    db = createTestDatabase();
    addTearDown(db.close);
    container = ProviderContainer(
      overrides: [
        ...withTestDatabase(db),
        librarySyncControllerProvider.overrideWith(() => _Sync(requests)),
        subsonicApiProvider.overrideWithValue(api),
        playlistSyncProvider.overrideWith((ref) async {
          headerSyncs++;
        }),
        playlistDetailSyncProvider.overrideWith((ref, id) async {
          detailSyncs++;
        }),
      ],
    );
    container.listen(playlistSyncProvider, (_, _) {});
    container.listen(playlistDetailSyncProvider('p'), (_, _) {});
    actions = container.read(playlistActionsProvider);
    addTearDown(container.dispose);
  });

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('create trims names, refreshes headers and returns server ID', () async {
    when(() => api.createPlaylist('New', songIds: ['a']))
        .thenAnswer((_) async => _response);
    await flush();
    expect(await actions.create('  New  ', ['a'], onServer: true), 'p');
    await flush();
    expect(headerSyncs, 2);
    verify(() => api.createPlaylist('New', songIds: ['a'])).called(1);
  });

  test('server creation fails visibly when offline', () async {
    final offline = ProviderContainer(
      overrides: [subsonicApiProvider.overrideWithValue(null)],
    );
    addTearDown(offline.dispose);
    await expectLater(
      offline.read(playlistActionsProvider).create('New', [], onServer: true),
      throwsStateError,
    );
  });

  test('create propagates server failure', () async {
    when(() => api.createPlaylist('New', songIds: []))
        .thenThrow(StateError('failed'));
    await expectLater(
      actions.create('New', [], onServer: true),
      throwsStateError,
    );
  });

  test('blank create and rename names fail before contacting server', () async {
    for (final onServer in [true, false]) {
      await expectLater(
        actions.create('  ', [], onServer: onServer),
        throwsArgumentError,
      );
    }
    await expectLater(actions.rename(_playlist, '  '), throwsArgumentError);
    verifyZeroInteractions(api);
  });

  test('rename trims the name', () async {
    when(() => api.updatePlaylist(id: 'p', name: 'New'))
        .thenAnswer((_) async => _response);
    await actions.rename(_playlist, ' New ');
    verify(() => api.updatePlaylist(id: 'p', name: 'New')).called(1);
  });

  test(
    'all device actions work offline and leave sync and API untouched',
    () async {
      final local = ProviderContainer(
        overrides: withTestDatabase(
          db,
          overrides: [
            subsonicApiProvider.overrideWithValue(api),
            playlistSyncProvider.overrideWith(
              (ref) => throw StateError('unexpected sync'),
            ),
            playlistDetailSyncProvider.overrideWith(
              (ref, id) => throw StateError('unexpected detail'),
            ),
          ],
        ),
      );
      addTearDown(local.dispose);
      await db.libraryDao.upsertSongs([
        SongsTableCompanion.insert(
          id: 'a',
          title: 'A',
          duration: const Value(5),
        ),
        SongsTableCompanion.insert(
          id: 'b',
          title: 'B',
          duration: const Value(10),
        ),
      ]);
      final a = local.read(playlistActionsProvider);
      final id = await a.create(' Mix ', ['a', 'a'], onServer: false);
      final p = (await db.playlistDao.watchPlaylistById(id).first)!;
      expect(p.name, 'Mix');
      expect(await a.addSongs(p, ['b', 'missing']), (
        added: 1,
        alreadyThere: 0,
        failed: 1,
      ));
      expect(
        (await db.playlistDao.watchPlaylistSongs(id).first).map((s) => s.id),
        ['a', 'a', 'b'],
      );
      final ids = ['a', 'a', 'b'];
      await a.reorder(p, ids, 1, 2);
      expect(ids, ['a', 'a', 'b']);
      await a.removeAt(p, songId: 'a', occurrence: 1, copies: 2);
      await a.rename(p, ' Renamed ');
      final updated = (await db.playlistDao.watchPlaylistById(id).first)!;
      expect(
        (updated.name, updated.songCount, updated.duration),
        ('Renamed', 2, 15),
      );
      expect(
        (await db.playlistDao.watchPlaylistSongs(id).first).map((s) => s.id),
        ['a', 'b'],
      );
      final offline = ProviderContainer(
        overrides: withTestDatabase(
          db,
          overrides: [subsonicApiProvider.overrideWithValue(null)],
        ),
      );
      addTearDown(offline.dispose);
      await offline.read(playlistActionsProvider).rename(p, 'Offline');
      await offline.read(playlistActionsProvider).delete(p);
      expect(await db.playlistDao.watchPlaylistById(id).first, isNull);
      expect(await db.playlistDao.watchPlaylistSongs(id).first, isEmpty);
      verifyZeroInteractions(api);
    },
    skip: !sqliteAvailable,
  );

  test('device playlists skip present ids and edit by occurrence', () async {
    final local = ProviderContainer(overrides: withTestDatabase(db));
    addTearDown(local.dispose);
    await db.libraryDao.upsertSongs([
      for (final id in ['a', 'b', 'c', 'x'])
        SongsTableCompanion.insert(id: id, title: id),
    ]);
    final a = local.read(playlistActionsProvider);
    final id = await a.create('Mix', [
      'a',
      'b',
      'a',
      'c',
      'a',
    ], onServer: false);
    final p = (await db.playlistDao.watchPlaylistById(id).first)!;
    Future<List<String>> stored() async => [
      for (final s in await db.playlistDao.watchPlaylistSongs(id).first) s.id,
    ];

    // 'b' is there, 'x' is picked twice: only one 'x' is added.
    expect(await a.addSongs(p, ['x', 'b', 'x']), (
      added: 1,
      alreadyThere: 2,
      failed: 0,
    ));
    expect(await stored(), ['a', 'b', 'a', 'c', 'a', 'x']);

    await a.removeAt(p, songId: 'a', occurrence: 1, copies: 3);
    expect(await stored(), ['a', 'b', 'c', 'a', 'x']);

    // A list that missed the removal above must not be written back.
    await expectLater(
      a.reorder(p, ['a', 'b', 'a', 'c', 'a', 'x'], 0, 5),
      throwsA(isA<PlaylistChangedException>()),
    );
    expect(await stored(), ['a', 'b', 'c', 'a', 'x']);

    // A list that held another number of 'a' than the stored one is refused.
    await expectLater(
      a.removeAt(p, songId: 'a', occurrence: 1, copies: 3),
      throwsA(isA<PlaylistChangedException>()),
    );
    expect(await stored(), ['a', 'b', 'c', 'a', 'x']);

    // A repeated tap on the first of two copies keeps the second.
    await a.removeAt(p, songId: 'a', occurrence: 0, copies: 2);
    await expectLater(
      a.removeAt(p, songId: 'a', occurrence: 0, copies: 2),
      throwsA(isA<PlaylistChangedException>()),
    );
    expect(await stored(), ['b', 'c', 'a', 'x']);
  }, skip: !sqliteAvailable);

  test('rename and delete call the server and refresh headers', () async {
    when(() => api.updatePlaylist(id: 'p', name: 'New'))
        .thenAnswer((_) async => _response);
    when(() => api.deletePlaylist('p')).thenAnswer((_) async {});
    await flush();
    await actions.rename(_playlist, 'New');
    await flush();
    expect(headerSyncs, 2);
    expect(detailSyncs, 1);
    await actions.delete(_playlist);
    await flush();
    expect(headerSyncs, 3);
    verify(() => api.updatePlaylist(id: 'p', name: 'New')).called(1);
    verify(() => api.deletePlaylist('p')).called(1);
  });

  var inFlight = 0;
  var maxInFlight = 0;

  /// Stateful server: [maxAdd] caps how many `songIdsToAdd` one call honours
  /// (Navidrome 0.64 ignores 2+ ids). [multiKeep] picks what a refused multi
  /// call stores anyway, [rejected] ids are never stored, [failing] ids throw
  /// and [onUpdate] runs on every update (another client writing).
  List<String> stubServer(
    List<String> songs, {
    required int maxAdd,
    Iterable<String> Function(List<String>)? multiKeep,
    Set<String> rejected = const {},
    Set<String> failing = const {},
    void Function()? onUpdate,
  }) {
    inFlight = maxInFlight = 0;
    when(
      () => api.updatePlaylist(
        id: 'p',
        songIdsToAdd: any(named: 'songIdsToAdd'),
      ),
    ).thenAnswer((i) async {
      final ids = i.namedArguments[#songIdsToAdd] as List<String>;
      maxInFlight = ++inFlight > maxInFlight ? inFlight : maxInFlight;
      await Future<void>.delayed(Duration.zero);
      inFlight--;
      onUpdate?.call();
      if (ids.any(failing.contains)) throw StateError('add failed');
      final kept = ids.length <= maxAdd ? ids : multiKeep?.call(ids) ?? [];
      songs.addAll(kept.where((id) => !rejected.contains(id)));
      return _response;
    });
    when(() => api.getPlaylist('p')).thenAnswer(
      (_) async => Playlist(
        id: 'p',
        name: 'Mix',
        songCount: songs.length,
        entries: [for (final id in songs) Song(id: id, title: id)],
      ),
    );
    return songs;
  }

  test('another client writing mid-add does not hide missing songs', () async {
    final server = ['x'];
    var wrote = false;
    stubServer(
      server,
      maxAdd: 1,
      onUpdate: () {
        if (!wrote) server.add('z');
        wrote = true;
      },
    );
    await flush();
    expect(await actions.addSongs(_playlist, ['a', 'b', 'c']), (
      added: 3,
      alreadyThere: 0,
      failed: 0,
    ));
    expect(server.toSet(), {'x', 'z', 'a', 'b', 'c'});
    expect(server.length, 5);
  });

  test('a server keeping a non-prefix subset is not resent that id', () async {
    final server = stubServer(['x'], maxAdd: 1, multiKeep: (ids) => [ids.last]);
    await flush();
    expect(await actions.addSongs(_playlist, ['a', 'b', 'c']), (
      added: 3,
      alreadyThere: 0,
      failed: 0,
    ));
    expect(server, ['x', 'c', 'a', 'b']);
  });

  test('an id the server rejects is reported as missing', () async {
    final server = stubServer(['x'], maxAdd: 1, rejected: {'bad'});
    await flush();
    expect(await actions.addSongs(_playlist, ['bad', 'b', 'c']), (
      added: 2,
      alreadyThere: 0,
      failed: 1,
    ));
    expect(server, ['x', 'b', 'c']);
  });

  test('one failing id does not abort the rest', () async {
    final server = stubServer(['x'], maxAdd: 1, failing: {'b'});
    await flush();
    expect(await actions.addSongs(_playlist, ['a', 'b', 'c']), (
      added: 2,
      alreadyThere: 0,
      failed: 1,
    ));
    expect(server, ['x', 'a', 'c']);
  });

  test('a truncated read-back is inconclusive and mutates nothing', () async {
    when(() => api.getPlaylist('p')).thenAnswer(
      (_) async => const Playlist(id: 'p', name: 'Mix', songCount: 5),
    );
    when(
      () => api.updatePlaylist(
        id: 'p',
        songIdsToAdd: any(named: 'songIdsToAdd'),
      ),
    ).thenAnswer((_) async => _response);
    await flush();
    await expectLater(
      actions.addSongs(_playlist, ['a', 'b']),
      throwsStateError,
    );
    verifyNever(() => api.updatePlaylist(id: 'p', songIdsToAdd: ['a']));
  });

  test('adds to one playlist never overlap', () async {
    final server = stubServer(['x'], maxAdd: 1);
    await flush();
    await Future.wait([
      actions.addSongs(_playlist, ['a', 'b']),
      actions.addSongs(_playlist, ['c', 'd']),
    ]);
    expect(maxInFlight, 1);
    expect(server.length, 5);
  });

  test('album add falls back to one id per request', () async {
    final server = stubServer(['x'], maxAdd: 1);
    await flush();
    // The repeated 'a' inside the picked list counts as already there.
    expect(await actions.addSongs(_playlist, ['a', 'b', 'a']), (
      added: 2,
      alreadyThere: 1,
      failed: 0,
    ));
    await flush();
    expect(server, ['x', 'a', 'b']);
    expect(headerSyncs, 2);
    // The refresh asks for a fresh hydration instead of re-running the
    // detail sync, which would join one that started before the edit.
    expect(detailSyncs, 1);
    expect(requests.map((r) => r.$2), [true]);
  });

  test('songs already in the playlist are skipped, not re-added', () async {
    final server = stubServer(['s1', 's2'], maxAdd: 99);
    await flush();
    expect(await actions.addSongs(_playlist, ['s1', 's2', 's3']), (
      added: 1,
      alreadyThere: 2,
      failed: 0,
    ));
    expect(server, ['s1', 's2', 's3']);
    verify(() => api.updatePlaylist(id: 'p', songIdsToAdd: ['s3'])).called(1);
  });

  test('adding only songs already there makes no update call', () async {
    stubServer(['s1', 's2'], maxAdd: 99);
    await flush();
    expect(await actions.addSongs(_playlist, ['s2', 's1']), (
      added: 0,
      alreadyThere: 2,
      failed: 0,
    ));
    verifyNever(
      () => api.updatePlaylist(
        id: any(named: 'id'),
        songIdsToAdd: any(named: 'songIdsToAdd'),
      ),
    );
  });

  test('add stays one update when the server honours multi-id', () async {
    final server = stubServer(['x'], maxAdd: 99);
    await flush();
    expect(await actions.addSongs(_playlist, ['a', 'b']), (
      added: 2,
      alreadyThere: 0,
      failed: 0,
    ));
    expect(server, ['x', 'a', 'b']);
    verify(() => api.updatePlaylist(id: 'p', songIdsToAdd: ['a', 'b']))
        .called(1);
    verifyNever(() => api.updatePlaylist(id: 'p', songIdsToAdd: ['a']));
    // One read before (baseline) and one after.
    verify(() => api.getPlaylist('p')).called(2);
  });

  test('add never reports success when the server drops every add', () async {
    final server = stubServer(['x'], maxAdd: 0);
    await flush();
    expect(await actions.addSongs(_playlist, ['a', 'b']), (
      added: 0,
      alreadyThere: 0,
      failed: 2,
    ));
    expect(server, ['x']);
  });

  test('add reports the songs the server still lacks', () async {
    var calls = 0;
    final server = ['x'];
    when(
      () => api.updatePlaylist(
        id: 'p',
        songIdsToAdd: any(named: 'songIdsToAdd'),
      ),
    ).thenAnswer((i) async {
      final ids = i.namedArguments[#songIdsToAdd] as List<String>;
      if (ids.length == 1 && ++calls == 1) server.addAll(ids);
      return _response;
    });
    when(() => api.getPlaylist('p')).thenAnswer(
      (_) async => Playlist(
        id: 'p',
        name: 'Mix',
        entries: [for (final id in server) Song(id: id, title: id)],
      ),
    );
    await flush();
    expect(await actions.addSongs(_playlist, ['a', 'b', 'c']), (
      added: 1,
      alreadyThere: 0,
      failed: 2,
    ));
    expect(server, ['x', 'a']);
  });

  test('reorder replaces atomically, preserves duplicates and input', () async {
    when(
      () => api.replacePlaylistSongs(playlistId: 'p', songIds: ['a', 'b', 'a']),
    ).thenAnswer((_) async {});
    when(() => api.getPlaylist('p')).thenAnswer(
      (_) async => const Playlist(
        id: 'p',
        name: 'Mix',
        songCount: 3,
        entries: [
          Song(id: 'a', title: 'a'),
          Song(id: 'a', title: 'a'),
          Song(id: 'b', title: 'b'),
        ],
      ),
    );
    await flush();
    final ids = ['a', 'a', 'b'];
    await actions.reorder(_playlist, ids, 1, 2);
    await flush();
    expect(ids, ['a', 'a', 'b']);
    expect(headerSyncs, 2);
    expect(detailSyncs, 1);
    expect(requests.map((r) => r.$2), [true]);
    verify(
      () => api.replacePlaylistSongs(playlistId: 'p', songIds: ['a', 'b', 'a']),
    ).called(1);
  });

  test('unchanged reorder does not call the server', () async {
    await actions.reorder(_playlist, ['a'], 0, 0);
    verifyZeroInteractions(api);
  });

  for (final (label, operation)
      in <(String, Future<void> Function(PlaylistActions, PlaylistsTableData))>[
        ('rename', (a, p) => a.rename(p, 'New')),
        ('delete', (a, p) => a.delete(p)),
        (
          'add',
          (a, p) async {
            await a.addSongs(p, ['a']);
          },
        ),
        (
          'remove',
          (a, p) => a.removeAt(p, songId: 'a', occurrence: 0, copies: 1),
        ),
        ('reorder', (a, p) => a.reorder(p, ['a', 'b'], 0, 1)),
      ]) {
    test('$label throws server failures to its caller', () async {
      final error = StateError('server failed');
      when(
        () => api.updatePlaylist(
          id: any(named: 'id'),
          name: any(named: 'name'),
          songIdsToAdd: any(named: 'songIdsToAdd'),
          songIndexesToRemove: any(named: 'songIndexesToRemove'),
        ),
      ).thenThrow(error);
      when(() => api.getPlaylist(any())).thenThrow(error);
      when(() => api.deletePlaylist(any())).thenThrow(error);
      when(
        () => api.replacePlaylistSongs(
          playlistId: any(named: 'playlistId'),
          songIds: any(named: 'songIds'),
        ),
      ).thenThrow(error);
      await flush();
      await expectLater(operation(actions, _playlist), throwsA(same(error)));
      await flush();
      // A failed edit may have changed the server, so it refreshes too.
      final edits = {'add', 'remove', 'reorder'}.contains(label);
      expect(headerSyncs, edits ? 2 : 1);
      expect(detailSyncs, 1);
      expect(requests.length, edits ? 1 : 0);
    });

    test('$label fails visibly when offline', () async {
      final offline = ProviderContainer(
        overrides: [subsonicApiProvider.overrideWithValue(null)],
      );
      addTearDown(offline.dispose);
      await expectLater(
        operation(offline.read(playlistActionsProvider), _playlist),
        throwsStateError,
      );
    });
  }
}
