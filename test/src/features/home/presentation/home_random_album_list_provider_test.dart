import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_database.dart';

class _CountingApi extends SubsonicApiClient {
  new()
    : super(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
        ),
        enableLogging: false,
      );

  int randomCalls = 0;

  @override
  Future<List<Album>> getAlbumList2({
    required String type,
    int size = 20,
    int offset = 0,
    CancelToken? cancelToken,
  }) async {
    if (type == 'random') randomCalls++;
    return <Album>[Album(id: 'a$randomCalls', name: 'A$randomCalls')];
  }
}

class _SyncController extends LibrarySyncController {
  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  set value(LibrarySyncState next) => state = next;
}

void main() {
  test(
    'Random Albums row re-picks after a finished sync, not mid-sync',
    () async {
      final api = _CountingApi();
      final sync = _SyncController();
      final container = ProviderContainer(
        overrides: [
          subsonicApiProvider.overrideWithValue(api),
          librarySyncControllerProvider.overrideWith(() => sync),
        ],
      );
      addTearDown(container.dispose);
      container.listen(homeRandomAlbumListProvider, (_, _) {});

      await container.read(homeRandomAlbumListProvider.future);
      expect(api.randomCalls, 1);

      sync.value = const LibrarySyncState(
        status: LibrarySyncStatus.running,
        stage: LibrarySyncStage.finalizing,
      );
      await pumpEventQueue();
      expect(api.randomCalls, 1);

      sync.value = const LibrarySyncState(
        status: LibrarySyncStatus.succeeded,
        stage: LibrarySyncStage.finalizing,
      );
      await pumpEventQueue();
      final albums = await container.read(homeRandomAlbumListProvider.future);
      expect(api.randomCalls, 2);
      expect(albums.single.id, 'a2');
    },
  );

  test('downloaded Random Albums snapshot ignores albums-table writes and '
      're-picks after a finished sync', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    Future<void> insert(String id) => database
        .into(database.albumsTable)
        .insert(
          AlbumsTableCompanion.insert(
            id: id,
            name: id,
            artistName: const Value('A'),
          ),
        );
    await insert('one');
    final sync = _SyncController();
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: [
          librarySyncControllerProvider.overrideWith(() => sync),
          downloadedContentIdsProvider.overrideWithValue(
            const AsyncData((
              albumIds: <String>{'one', 'two'},
              artistIds: <String>{},
            )),
          ),
        ],
      ),
    );
    addTearDown(container.dispose);
    final emissions = <List<String>>[];
    container.listen(homeDownloadedRandomAlbumsProvider, (_, next) {
      final ids = next.asData?.value.map((a) => a.id).toList();
      if (ids != null) emissions.add(ids);
    });

    expect(
      (await container.read(homeDownloadedRandomAlbumsProvider.future))
          .map((a) => a.id),
      ['one'],
    );

    await insert('two');
    await pumpEventQueue();
    expect(emissions, hasLength(1));

    sync.value = const LibrarySyncState(
      status: LibrarySyncStatus.succeeded,
      stage: LibrarySyncStage.finalizing,
    );
    await pumpEventQueue();
    final after = await container.read(
      homeDownloadedRandomAlbumsProvider.future,
    );
    expect(after.map((a) => a.id).toSet(), {'one', 'two'});
  });
}
