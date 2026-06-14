import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:riverpod/src/framework.dart' show Override;

import '../../../helpers/test_database.dart';

class _StaticReachabilityController extends ServerReachabilityController {
  _StaticReachabilityController(this._state);

  final ServerReachabilityState _state;

  @override
  ServerReachabilityState build() => _state;
}

class _FakeSearchApiClient extends SubsonicApiClient {
  _FakeSearchApiClient(this._handler)
    : super(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
        ),
        enableLogging: false,
      );

  final Future<SearchResult3> Function(String query) _handler;

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
  }) {
    return _handler(query);
  }
}

ProviderContainer _createContainer(
  NavisDatabase database, {
  SubsonicApiClient? api,
  bool online = true,
  List<Override> overrides = const <Override>[],
}) {
  return ProviderContainer(
    overrides: withTestDatabase(
      database,
      overrides: <Override>[
        serverReachabilityControllerProvider.overrideWith(
          () => _StaticReachabilityController(
            ServerReachabilityState(
              status: online
                  ? ServerReachabilityStatus.online
                  : ServerReachabilityStatus.offline,
            ),
          ),
        ),
        subsonicApiProvider.overrideWithValue(api),
        ...overrides,
      ],
    ),
  );
}

Future<void> _insertArtist(
  NavisDatabase database, {
  required String id,
  required String name,
}) {
  return database
      .into(database.artistsTable)
      .insert(ArtistsTableCompanion.insert(id: id, name: name));
}

Future<void> _insertAlbum(
  NavisDatabase database, {
  required String id,
  required String name,
}) {
  return database
      .into(database.albumsTable)
      .insert(
        AlbumsTableCompanion.insert(
          id: id,
          name: name,
          artistName: const Value('Cached Artist'),
        ),
      );
}

Future<void> _insertSong(
  NavisDatabase database, {
  required String id,
  required String title,
}) {
  return database
      .into(database.songsTable)
      .insert(
        SongsTableCompanion.insert(
          id: id,
          title: title,
          artistName: const Value('Cached Artist'),
          albumName: const Value('Cached Album'),
        ),
      );
}

Future<void> _waitForEmissions(
  List<SearchResultsState> emissions,
  int count,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (emissions.length < count) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Expected $count search emissions, got ${emissions.length}.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

ProviderSubscription<AsyncValue<SearchResultsState?>> _listenToSearch(
  ProviderContainer container,
  List<SearchResultsState> emissions,
) {
  return container.listen<AsyncValue<SearchResultsState?>>(
    debouncedSearchProvider,
    (_, next) {
      final value = next.asData?.value;
      if (value != null) {
        emissions.add(value);
      }
    },
    fireImmediately: true,
  );
}

void main() {
  group('debouncedSearchProvider', () {
    test('emits local results before delayed API results', () async {
      if (!sqliteAvailable) return;

      final database = createTestDatabase();
      await _insertArtist(database, id: 'local-artist', name: 'Cache Artist');
      final apiCompleter = Completer<SearchResult3>();
      final container = _createContainer(
        database,
        api: _FakeSearchApiClient((_) => apiCompleter.future),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final emissions = <SearchResultsState>[];
      final subscription = _listenToSearch(container, emissions);
      addTearDown(subscription.close);

      container.read(searchQueryProvider.notifier).submit('Cache');
      await _waitForEmissions(emissions, 1);

      expect(emissions.single.result.artists.single.id, 'local-artist');
      expect(emissions.single.isWaitingForApi, isTrue);

      apiCompleter.complete(
        const SearchResult3(
          artists: <Artist>[Artist(id: 'remote-artist', name: 'Cache Remote')],
        ),
      );
      await _waitForEmissions(emissions, 2);

      expect(
        emissions.last.result.artists.map((artist) => artist.id),
        <String>['local-artist', 'remote-artist'],
      );
      expect(emissions.last.isWaitingForApi, isFalse);
    });

    test('removes API duplicates by ID and keeps local items first', () async {
      if (!sqliteAvailable) return;

      final database = createTestDatabase();
      await _insertArtist(database, id: 'artist-1', name: 'Cache Artist');
      await _insertAlbum(database, id: 'album-1', name: 'Cache Album');
      await _insertSong(database, id: 'song-1', title: 'Cache Song');
      final container = _createContainer(
        database,
        api: _FakeSearchApiClient(
          (_) async => const SearchResult3(
            artists: <Artist>[
              Artist(id: 'artist-1', name: 'Remote Artist Replacement'),
              Artist(id: 'artist-2', name: 'Remote Artist'),
            ],
            albums: <Album>[
              Album(id: 'album-1', name: 'Remote Album Replacement'),
              Album(id: 'album-2', name: 'Remote Album'),
            ],
            songs: <Song>[
              Song(id: 'song-1', title: 'Remote Song Replacement'),
              Song(id: 'song-2', title: 'Remote Song'),
            ],
          ),
        ),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final emissions = <SearchResultsState>[];
      final subscription = _listenToSearch(container, emissions);
      addTearDown(subscription.close);

      container.read(searchQueryProvider.notifier).submit('Cache');
      await _waitForEmissions(emissions, 2);

      final result = emissions.last.result;
      expect(result.artists.map((artist) => artist.id), <String>[
        'artist-1',
        'artist-2',
      ]);
      expect(result.artists.first.name, 'Cache Artist');
      expect(result.albums.map((album) => album.id), <String>[
        'album-1',
        'album-2',
      ]);
      expect(result.albums.first.name, 'Cache Album');
      expect(result.songs.map((song) => song.id), <String>['song-1', 'song-2']);
      expect(result.songs.first.title, 'Cache Song');
    });

    test('appends API-only results after local results', () async {
      if (!sqliteAvailable) return;

      final database = createTestDatabase();
      await _insertArtist(database, id: 'artist-local', name: 'Cache Artist');
      final container = _createContainer(
        database,
        api: _FakeSearchApiClient(
          (_) async => const SearchResult3(
            artists: <Artist>[
              Artist(id: 'artist-remote', name: 'Cache Remote'),
            ],
          ),
        ),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final emissions = <SearchResultsState>[];
      final subscription = _listenToSearch(container, emissions);
      addTearDown(subscription.close);

      container.read(searchQueryProvider.notifier).submit('Cache');
      await _waitForEmissions(emissions, 2);

      expect(
        emissions.last.result.artists.map((artist) => artist.id),
        <String>['artist-local', 'artist-remote'],
      );
    });

    test('offline mode emits only local results', () async {
      if (!sqliteAvailable) return;

      final database = createTestDatabase();
      await _insertArtist(database, id: 'local-only', name: 'Cache Artist');
      final container = _createContainer(
        database,
        api: _FakeSearchApiClient((_) async {
          fail('API should not be called while offline.');
        }),
        online: false,
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final emissions = <SearchResultsState>[];
      final subscription = _listenToSearch(container, emissions);
      addTearDown(subscription.close);

      container.read(searchQueryProvider.notifier).submit('Cache');
      await _waitForEmissions(emissions, 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(emissions, hasLength(1));
      expect(emissions.single.result.artists.single.id, 'local-only');
      expect(emissions.single.isLocalOnly, isTrue);
      expect(emissions.single.isWaitingForApi, isFalse);
    });

    test('API failure falls back to local results without an error', () async {
      if (!sqliteAvailable) return;

      final database = createTestDatabase();
      await _insertArtist(database, id: 'local-fallback', name: 'Cache Artist');
      final container = _createContainer(
        database,
        api: _FakeSearchApiClient((_) async {
          throw DioException(requestOptions: RequestOptions());
        }),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final emissions = <SearchResultsState>[];
      final asyncValues = <AsyncValue<SearchResultsState?>>[];
      final subscription = container.listen<AsyncValue<SearchResultsState?>>(
        debouncedSearchProvider,
        (_, next) {
          asyncValues.add(next);
          final value = next.asData?.value;
          if (value != null) {
            emissions.add(value);
          }
        },
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      container.read(searchQueryProvider.notifier).submit('Cache');
      await _waitForEmissions(emissions, 2);

      expect(emissions.last.result.artists.single.id, 'local-fallback');
      expect(emissions.last.isWaitingForApi, isFalse);
      expect(asyncValues.where((value) => value.hasError), isEmpty);
    });
  });
}
