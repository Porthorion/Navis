import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/models/playlist.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/playlists/data/playlist_actions.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/providers/app_providers.dart';

class _MockApi extends Mock implements SubsonicApiClient;

const _playlist = PlaylistsTableData(isLocal: false, id: 'p', name: 'Mix');
const _response = Playlist(id: 'p', name: 'Mix');

void main() {
  late _MockApi api;
  late ProviderContainer container;
  late PlaylistActions actions;
  late int headerSyncs;
  late int detailSyncs;

  setUp(() {
    api = _MockApi();
    headerSyncs = 0;
    detailSyncs = 0;
    container = ProviderContainer(
      overrides: [
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

  test(
    'add refreshes headers and detail and reports no skipped server songs',
    () async {
      when(() => api.updatePlaylist(id: 'p', songIdsToAdd: ['a', 'a']))
          .thenAnswer((_) async => _response);
      await flush();
      expect(await actions.addSongs(_playlist, ['a', 'a']), 0);
      await flush();
      expect(headerSyncs, 2);
      expect(detailSyncs, 2);
      verify(() => api.updatePlaylist(id: 'p', songIdsToAdd: ['a', 'a']))
          .called(1);
    },
  );

  test('remove uses the occurrence index and refreshes detail', () async {
    when(() => api.updatePlaylist(id: 'p', songIndexesToRemove: [1]))
        .thenAnswer((_) async => _response);
    await flush();
    await actions.removeAt(_playlist, ['a', 'a', 'b'], 1);
    await flush();
    expect(headerSyncs, 1);
    expect(detailSyncs, 2);
    verify(() => api.updatePlaylist(id: 'p', songIndexesToRemove: [1]))
        .called(1);
  });

  test('reorder replaces atomically, preserves duplicates and input', () async {
    when(
      () => api.replacePlaylistSongs(playlistId: 'p', songIds: ['a', 'b', 'a']),
    ).thenAnswer((_) async {});
    await flush();
    final ids = ['a', 'a', 'b'];
    await actions.reorder(_playlist, ids, 1, 2);
    await flush();
    expect(ids, ['a', 'a', 'b']);
    expect(headerSyncs, 1);
    expect(detailSyncs, 2);
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
        ('remove', (a, p) => a.removeAt(p, ['a', 'b'], 0)),
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
      expect(headerSyncs, 1);
      expect(detailSyncs, label == 'reorder' ? 2 : 1);
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

    test('$label never sends a local ID to the server before B2', () async {
      await expectLater(
        operation(actions, _playlist.copyWith(isLocal: true)),
        throwsUnsupportedError,
      );
      verifyZeroInteractions(api);
    });
  }
}
