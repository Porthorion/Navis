import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../helpers/reachability_fakes.dart';
import '../../../helpers/test_database.dart';

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

  int search3Calls = 0;

  @override
  Future<SearchResult3> search3({
    required String query,
    int artistCount = 20,
    int albumCount = 20,
    int songCount = 20,
    int artistOffset = 0,
    int albumOffset = 0,
    int songOffset = 0,
    CancelToken? cancelToken,
  }) async {
    search3Calls++;
    return const SearchResult3();
  }
}

const _jazzDevice = InternetRadioStation(
  id: 'dev-jazz',
  name: 'Jazz FM',
  streamUrl: 'https://example.com/jazz',
);
const _jazzServer = InternetRadioStation(
  id: 'srv-jazz',
  name: 'Smooth Jazz',
  streamUrl: 'https://example.com/smooth',
);
const _rock = InternetRadioStation(
  id: 'srv-rock',
  name: 'Rock Radio',
  streamUrl: 'https://example.com/rock',
);

Future<void> _insertPlaylist(NavisDatabase db, String id, String name) async {
  await db
      .into(db.playlistsTable)
      .insert(PlaylistsTableCompanion.insert(id: id, name: name));
}

ProviderContainer _container(
  NavisDatabase database, {
  SubsonicApiClient? api,
  bool online = true,
  Exception? serverStationsError,
  List<InternetRadioStation> device = const [],
  List<InternetRadioStation> server = const [],
  List<Override> overrides = const [],
}) {
  return ProviderContainer(
    // Riverpod 3 retries failed providers; surface the failure at once.
    retry: (_, _) => null,
    overrides: withTestDatabase(
      database,
      overrides: <Override>[
        serverReachabilityControllerProvider.overrideWith(
          () => StaticReachabilityController(
            ServerReachabilityState(
              status: online
                  ? ServerReachabilityStatus.online
                  : ServerReachabilityStatus.offline,
            ),
          ),
        ),
        subsonicApiProvider.overrideWithValue(api),
        localRadioStationsProvider.overrideWith((ref) => Stream.value(device)),
        radioStationsProvider.overrideWith((ref) async {
          if (serverStationsError != null) throw serverStationsError;
          return server;
        }),
        ...overrides,
      ],
    ),
  );
}

/// Subscribes (the provider is auto-dispose) and lets the sources load.
Future<SearchCollectionMatches> _matches(
  ProviderContainer container,
  String query, {
  SearchResultType? filter,
}) async {
  container.read(searchQueryProvider.notifier).submit(query);
  container.read(searchFilterProvider.notifier).select(filter);
  final sub = container.listen(searchCollectionMatchesProvider, (_, _) {});
  addTearDown(sub.close);
  // Riverpod 3 pauses unlistened providers: listen before awaiting.
  addTearDown(container.listen(playlistListProvider, (_, _) {}).close);
  addTearDown(container.listen(localRadioStationsProvider, (_, _) {}).close);
  addTearDown(container.listen(radioStationsProvider, (_, _) {}).close);
  await container.read(playlistListProvider.future);
  await container.read(localRadioStationsProvider.future);
  await container.read(radioStationsProvider.future).onError((_, _) => []);
  return container.read(searchCollectionMatchesProvider);
}

void main() {
  group('searchCollectionMatchesProvider', () {
    test(
      'ranks playlists exact > prefix > substring and drops misses',
      () async {
        if (!sqliteAvailable) return;
        final database = createTestDatabase();
        await _insertPlaylist(database, 'p1', 'Late Night Chill');
        await _insertPlaylist(database, 'p2', 'Chill');
        await _insertPlaylist(database, 'p3', 'Chill Out');
        await _insertPlaylist(database, 'p4', 'Workout');
        final container = _container(database);
        addTearDown(() async {
          container.dispose();
          await database.close();
        });

        final m = await _matches(container, 'chill');
        expect(m.playlists.map((p) => p.id), <String>['p2', 'p3', 'p1']);
      },
    );

    test('empty and whitespace queries match nothing', () async {
      if (!sqliteAvailable) return;
      final database = createTestDatabase();
      await _insertPlaylist(database, 'p1', 'Chill');
      final container = _container(database, device: const [_jazzDevice]);
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final m = await _matches(container, '   ');
      expect(m.playlists, isEmpty);
      expect(m.stations, isEmpty);
    });

    test('stations list device stations first, then server', () async {
      if (!sqliteAvailable) return;
      final database = createTestDatabase();
      final container = _container(
        database,
        device: const [_jazzDevice],
        server: const [_rock, _jazzServer],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final m = await _matches(container, 'jazz');
      expect(m.stations.map((s) => s.id), <String>['dev-jazz', 'srv-jazz']);
    });

    test('matches are independent of the selected filter', () async {
      if (!sqliteAvailable) return;
      final database = createTestDatabase();
      await _insertPlaylist(database, 'p1', 'Jazz Mix');
      final container = _container(database, device: const [_jazzDevice]);
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      for (final filter in <SearchResultType?>[
        null,
        SearchResultType.songs,
        SearchResultType.playlists,
        SearchResultType.radio,
      ]) {
        final m = await _matches(container, 'jazz', filter: filter);
        expect(m.playlists.map((p) => p.id), <String>['p1'], reason: '$filter');
        expect(m.stations.map((s) => s.id), <String>[
          'dev-jazz',
        ], reason: '$filter');
      }
    });

    test('offline keeps device playlists and stations', () async {
      if (!sqliteAvailable) return;
      final database = createTestDatabase();
      await _insertPlaylist(database, 'p1', 'Jazz Mix');
      final container = _container(
        database,
        online: false,
        serverStationsError: Exception('offline'),
        device: const [_jazzDevice],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final m = await _matches(container, 'jazz');
      expect(m.playlists.map((p) => p.id), <String>['p1']);
      expect(m.stations.map((s) => s.id), <String>['dev-jazz']);
    });

    test(
      'a failing server station list falls back to device stations',
      () async {
        if (!sqliteAvailable) return;
        final database = createTestDatabase();
        final container = _container(
          database,
          serverStationsError: Exception('boom'),
          device: const [_jazzDevice],
        );
        addTearDown(() async {
          container.dispose();
          await database.close();
        });

        final m = await _matches(container, 'jazz');
        expect(m.stations.map((s) => s.id), <String>['dev-jazz']);
      },
    );
  });

  group('debouncedSearchProvider with collection filters', () {
    for (final filter in <SearchResultType>[
      SearchResultType.playlists,
      SearchResultType.radio,
    ]) {
      test('filter ${filter.name} makes no search3 call', () async {
        if (!sqliteAvailable) return;
        final database = createTestDatabase();
        final api = _CountingApi();
        final container = _container(database, api: api);
        addTearDown(() async {
          container.dispose();
          await database.close();
        });

        container.read(searchQueryProvider.notifier).submit('jazz');
        container.read(searchFilterProvider.notifier).select(filter);
        final done = container.listen(
          debouncedSearchProvider,
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(done.close);
        final state = await container.read(debouncedSearchProvider.future);
        expect(state, isNotNull);
        expect(state!.result.songs, isEmpty);
        expect(state.isWaitingForApi, isFalse);
        expect(api.search3Calls, 0);
      });
    }
  });
}
