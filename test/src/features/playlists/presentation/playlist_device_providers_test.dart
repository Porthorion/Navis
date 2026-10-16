import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';

import '../../../../helpers/test_database.dart';

class _Reachability extends ServerReachabilityController {
  @override
  ServerReachabilityState build() =>
      const ServerReachabilityState(status: ServerReachabilityStatus.online);

  void setStatus(ServerReachabilityStatus status) =>
      state = state.copyWith(status: status);
}

class _MockApi extends Mock implements SubsonicApiClient;

class _QueueHandler extends Mock implements NavisPlaybackHandler {
  List<SongsTableData>? songs;

  @override
  Future<void> replaceQueueWithData(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    List<String>? originalOrder,
  }) async {
    this.songs = songs;
  }
}

class _SyncController extends LibrarySyncController {
  final targets = <LibrarySyncTarget>[];

  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  Future<LibrarySyncState> requestTarget(LibrarySyncTarget target) async {
    targets.add(target);
    return const LibrarySyncState.idle();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'local detail and queue use ordered DB rows without server hydration',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final api = _MockApi();
      final handler = _QueueHandler();
      final sync = _SyncController();
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [
            subsonicApiProvider.overrideWithValue(api),
            librarySyncControllerProvider.overrideWith(() => sync),
            audioHandlerProvider.overrideWithValue(handler),
            playbackSnapshotProvider.overrideWithValue(
              const AsyncData(PlaybackSnapshot.idle()),
            ),
            lyricsPrewarmProvider.overrideWithValue((_) async {}),
          ],
        ),
      );
      addTearDown(container.dispose);
      await database.libraryDao.upsertSongs([
        SongsTableCompanion.insert(id: 'a', title: 'A'),
        SongsTableCompanion.insert(id: 'b', title: 'B'),
      ]);
      final id = await database.playlistDao.createLocalPlaylist('Device', [
        'b',
        'a',
        'b',
      ]);
      container.listen(playlistDetailSyncProvider(id), (_, _) {});
      await container.read(playlistDetailSyncProvider(id).future);
      container.listen(playlistSongsProvider(id), (_, _) {});
      final songs = await container.read(playlistSongsProvider(id).future);
      await container.read(queueProvider.notifier).replaceWithTableData(songs);
      expect(handler.songs!.map((s) => s.id), ['b', 'a', 'b']);
      expect(sync.targets, isEmpty);
      verifyZeroInteractions(api);
      container.invalidate(playlistDetailSyncProvider(id));
      await container.read(playlistDetailSyncProvider(id).future);
      expect(sync.targets, isEmpty);
      await database.playlistDao.deletePlaylist(id);
      container.invalidate(playlistDetailSyncProvider(id));
      await container.read(playlistDetailSyncProvider(id).future);
      expect(sync.targets, isEmpty);

      await database.playlistDao.upsertPlaylists([
        PlaylistsTableCompanion.insert(id: 'server', name: 'Server'),
      ]);
      container.listen(playlistDetailSyncProvider('server'), (_, _) {});
      await container.read(playlistDetailSyncProvider('server').future);
      expect(sync.targets, hasLength(1));
      expect(sync.targets.single.kind, LibrarySyncTargetKind.playlist);
      expect(sync.targets.single.entityId, 'server');
    },
    skip: !sqliteAvailable,
  );

  test('server creation stays available while reachability is checking', () {
    final container = ProviderContainer(
      overrides: [
        subsonicApiProvider.overrideWithValue(_MockApi()),
        networkTypeProvider.overrideWithValue(NetworkType.wifi),
        serverReachabilityControllerProvider.overrideWith(_Reachability.new),
      ],
    );
    addTearDown(container.dispose);
    container.listen(playlistServerCreationAvailableProvider, (_, _) {});
    (container.read(
      serverReachabilityControllerProvider.notifier,
    ) as _Reachability).setStatus(ServerReachabilityStatus.checking);
    expect(container.read(playlistServerCreationAvailableProvider), isTrue);
  });

  test(
    'destination is sticky; offline forced off is never persisted',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final api = _MockApi();
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [
            subsonicApiProvider.overrideWithValue(api),
            networkTypeProvider.overrideWithValue(NetworkType.wifi),
            serverReachabilityControllerProvider.overrideWith(
              _Reachability.new,
            ),
          ],
        ),
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        playlistCreateOnServerProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      container.listen(appSettingsProvider, (_, _) {});
      await container.read(appSettingsProvider.future);
      expect(container.read(playlistCreateOnServerProvider), isTrue);

      Future<void> choose({required bool onServer}) async {
        final changed = Completer<void>();
        final listener = container.listen(playlistCreateOnServerProvider, (
          _,
          next,
        ) {
          if (next == onServer && !changed.isCompleted) changed.complete();
        });
        try {
          await container
              .read(playlistCreateOnServerProvider.notifier)
              .setOnServer(enabled: onServer);
          await changed.future;
        } finally {
          listener.close();
        }
      }

      await choose(onServer: false);
      expect(
        (await database.appSettingsDao.getSettings())!.playlistCreateOnServer,
        isFalse,
      );
      final nextDialog = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [
            subsonicApiProvider.overrideWithValue(api),
            networkTypeProvider.overrideWithValue(NetworkType.wifi),
            serverReachabilityControllerProvider.overrideWith(
              _Reachability.new,
            ),
          ],
        ),
      );
      addTearDown(nextDialog.dispose);
      nextDialog.listen(appSettingsProvider, (_, _) {});
      await nextDialog.read(appSettingsProvider.future);
      expect(nextDialog.read(playlistCreateOnServerProvider), isFalse);
      await choose(onServer: true);
      expect(container.read(playlistCreateOnServerProvider), isTrue);

      final reachability = container.read(
        serverReachabilityControllerProvider.notifier,
      ) as _Reachability;
      reachability.setStatus(ServerReachabilityStatus.offline);
      expect(container.read(playlistServerCreationAvailableProvider), isFalse);
      expect(container.read(playlistCreateOnServerProvider), isFalse);
      await container
          .read(playlistCreateOnServerProvider.notifier)
          .setOnServer(enabled: false);
      expect(
        (await database.appSettingsDao.getSettings())!.playlistCreateOnServer,
        isTrue,
      );
      reachability.setStatus(ServerReachabilityStatus.online);
      expect(container.read(playlistCreateOnServerProvider), isTrue);

      container.updateOverrides([
        navisDatabaseProvider.overrideWithValue(database),
        subsonicApiProvider.overrideWithValue(api),
        networkTypeProvider.overrideWithValue(NetworkType.offline),
        serverReachabilityControllerProvider.overrideWith(_Reachability.new),
      ]);
      expect(container.read(playlistServerCreationAvailableProvider), isFalse);
      expect(container.read(playlistCreateOnServerProvider), isFalse);
      await container
          .read(playlistCreateOnServerProvider.notifier)
          .setOnServer(enabled: false);
      expect(
        (await database.appSettingsDao.getSettings())!.playlistCreateOnServer,
        isTrue,
      );
      container.updateOverrides([
        navisDatabaseProvider.overrideWithValue(database),
        subsonicApiProvider.overrideWithValue(api),
        networkTypeProvider.overrideWithValue(NetworkType.wifi),
        serverReachabilityControllerProvider.overrideWith(_Reachability.new),
      ]);
      expect(container.read(playlistCreateOnServerProvider), isTrue);
      verifyZeroInteractions(api);

      final reopened = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [
            subsonicApiProvider.overrideWithValue(null),
            networkTypeProvider.overrideWithValue(NetworkType.wifi),
            serverReachabilityControllerProvider.overrideWith(
              _Reachability.new,
            ),
          ],
        ),
      );
      addTearDown(reopened.dispose);
      reopened.listen(appSettingsProvider, (_, _) {});
      await reopened.read(appSettingsProvider.future);
      expect(reopened.read(playlistServerCreationAvailableProvider), isFalse);
      expect(reopened.read(playlistCreateOnServerProvider), isFalse);
      expect(
        (await database.appSettingsDao.getSettings())!.playlistCreateOnServer,
        isTrue,
      );
    },
    skip: !sqliteAvailable,
  );
}
