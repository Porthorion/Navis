import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/integrations/data/deezer_catalog.dart';
import 'package:navis/src/features/integrations/data/integration_call_recorder.dart';
import 'package:navis/src/features/integrations/data/integration_json_cache.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/features/search/domain/deezer_search_boost.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../../helpers/test_database.dart';
import '../../../helpers/reachability_fakes.dart';

class _FakeSearchApiClient extends SubsonicApiClient {
  new(this._handler)
    : super(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
        ),
        enableLogging: false,
      );

  final Future<SearchResult3> Function(_Search3Call call) _handler;

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
    return _handler(
      _Search3Call(
        query: query,
        artistCount: artistCount,
        albumCount: albumCount,
        songCount: songCount,
        artistOffset: artistOffset,
        albumOffset: albumOffset,
        songOffset: songOffset,
      ),
    );
  }
}

@immutable
class _Search3Call {
  const new({
    required this.query,
    required this.artistCount,
    required this.albumCount,
    required this.songCount,
    required this.artistOffset,
    required this.albumOffset,
    required this.songOffset,
  });

  final String query;
  final int artistCount;
  final int albumCount;
  final int songCount;
  final int artistOffset;
  final int albumOffset;
  final int songOffset;
}

ProviderContainer _createContainer(
  NavisDatabase database, {
  SubsonicApiClient? api,
  bool online = true,
  IntegrationPolicy policy = const IntegrationPolicy.denyAll(),
  List<Override> overrides = const <Override>[],
}) {
  return ProviderContainer(
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
        integrationPolicyProvider.overrideWithValue(policy),
        ...overrides,
      ],
    ),
  );
}

/// A Deezer catalogue that answers from [tracks] and [artists] (or
/// from [gate] once it completes) and records every search it receives.
class _FakeDeezerCatalog extends DeezerCatalog {
  new({
    this.tracks = const <DeezerTrack>[],
    this.artists = const <DeezerArtist>[],
    this.gate,
    this.fail = false,
  }) : super(
         client: DeezerApiClient(dio: Dio()),
         cache: IntegrationJsonCache(),
       );

  final List<DeezerTrack> tracks;
  final List<DeezerArtist> artists;
  final Completer<void>? gate;
  final bool fail;
  final List<String> calls = <String>[];
  final List<CancelToken?> tokens = <CancelToken?>[];

  Future<T> _answer<T>(String call, T value, CancelToken? token) async {
    calls.add(call);
    tokens.add(token);
    await gate?.future;
    if (fail) throw const DeezerApiException(code: 4);
    return value;
  }

  @override
  Future<List<DeezerTrack>> searchTracks(
    String query, {
    int limit = DeezerCatalog.searchLimit,
    CancelToken? cancelToken,
  }) => _answer('tracks:$query', tracks, cancelToken);

  @override
  Future<List<DeezerArtist>> searchArtists(
    String query, {
    int limit = DeezerCatalog.searchLimit,
    CancelToken? cancelToken,
  }) => _answer('artists:$query', artists, cancelToken);

  @override
  Future<List<DeezerAlbum>> searchAlbums(
    String query, {
    int limit = DeezerCatalog.searchLimit,
    CancelToken? cancelToken,
  }) => _answer('albums:$query', const <DeezerAlbum>[], cancelToken);
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
  test('checking keeps search online until an outage is confirmed', () {
    final container = ProviderContainer(
      overrides: [
        serverReachabilityControllerProvider.overrideWith(
          () => StaticReachabilityController(
            const ServerReachabilityState(
              status: ServerReachabilityStatus.checking,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(searchIsOfflineProvider), isFalse);
  });

  group('debouncedSearchProvider', () {
    group('Deezer ranking', () {
      const allowed = IntegrationPolicy();
      const karaokeAndAdele = SearchResult3(
        songs: <Song>[
          Song(id: 'karaoke', title: 'Hello', artist: 'Karaoke Stars'),
          Song(id: 'adele', title: 'Hello', artist: 'Adele'),
        ],
      );
      final adeleHello = DeezerTrack(
        id: 1,
        title: 'Hello',
        artist: const DeezerArtist(id: 2, name: 'Adele'),
      );

      Future<
        ({
          ProviderContainer container,
          List<SearchResultsState> emissions,
          IntegrationCallRecorder recorder,
        })
      >
      start(
        _FakeDeezerCatalog catalog, {
        IntegrationPolicy policy = allowed,
        bool online = true,
        SearchResultType? filter,
        SearchResult3 server = karaokeAndAdele,
      }) async {
        final database = createTestDatabase();
        final recorder = IntegrationCallRecorder();
        final container = _createContainer(
          database,
          online: online,
          policy: policy,
          api: _FakeSearchApiClient((_) async => server),
          overrides: <Override>[
            deezerCatalogProvider.overrideWithValue(catalog),
            integrationCallRecorderProvider.overrideWithValue(recorder),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await database.close();
        });
        final emissions = <SearchResultsState>[];
        final subscription = _listenToSearch(container, emissions);
        addTearDown(subscription.close);
        if (filter != null) {
          container.read(searchFilterProvider.notifier).select(filter);
        }
        return (container: container, emissions: emissions, recorder: recorder);
      }

      List<String> songIds(SearchResultsState state) =>
          state.result.songs.map((song) => song.id).toList();

      test('All keeps one song, a Songs filter keeps up to three', () async {
        if (!sqliteAvailable) return;
        final tracks = [
          adeleHello,
          DeezerTrack(
            id: 3,
            title: 'Hello',
            artist: const DeezerArtist(id: 4, name: 'Karaoke Stars'),
          ),
        ];
        final all = await start(_FakeDeezerCatalog(tracks: tracks));
        all.container.read(searchQueryProvider.notifier).submit('Hello');
        await _waitForEmissions(all.emissions, 2);
        expect(all.emissions.last.topResults, hasLength(1));

        final songs = await start(
          _FakeDeezerCatalog(tracks: tracks),
          filter: SearchResultType.songs,
        );
        songs.container.read(searchQueryProvider.notifier).submit('Hello');
        await _waitForEmissions(songs.emissions, 2);
        expect(
          [
            for (final top in songs.emissions.last.topResults)
              (top as TopSongResult).song.id,
          ],
          <String>['adele', 'karaoke'],
        );
      });

      test(
        'an answer in time gives one ranked emission with Top Results',
        () async {
          if (!sqliteAvailable) return;
          final catalog = _FakeDeezerCatalog(tracks: [adeleHello]);
          final run = await start(catalog);

          run.container.read(searchQueryProvider.notifier).submit('Hello');
          await _waitForEmissions(run.emissions, 2);

          expect(run.emissions.first.isWaitingForApi, isTrue);
          expect(run.emissions.first.topResults, isEmpty);
          final ranked = run.emissions.last;
          expect(songIds(ranked), <String>['adele', 'karaoke']);
          expect(ranked.topResults, hasLength(1));
          expect((ranked.topResults.single as TopSongResult).song.id, 'adele');
          // Never reshuffles afterwards.
          await Future<void>.delayed(const Duration(milliseconds: 500));
          expect(run.emissions, hasLength(2));
          expect(catalog.calls, <String>[
            'artists:Hello',
            'albums:Hello',
            'tracks:Hello',
          ]);
          expect(
            run.recorder.recentSpans().map((span) => span.name),
            contains(kSearchDeezerSpan),
          );
        },
      );

      test(
        "an answer after the cap keeps today's order and never reshuffles",
        () async {
          if (!sqliteAvailable) return;
          final gate = Completer<void>();
          final catalog = _FakeDeezerCatalog(tracks: [adeleHello], gate: gate);
          final run = await start(catalog);

          run.container.read(searchQueryProvider.notifier).submit('Hello');
          await _waitForEmissions(run.emissions, 2);
          expect(songIds(run.emissions.last), <String>['karaoke', 'adele']);
          expect(run.emissions.last.topResults, isEmpty);
          expect(run.emissions.last.isWaitingForApi, isFalse);

          gate.complete();
          await Future<void>.delayed(const Duration(milliseconds: 200));
          expect(run.emissions, hasLength(2));
        },
      );

      test(
        "a Deezer failure keeps today's order, silently and at once",
        () async {
          if (!sqliteAvailable) return;
          final catalog = _FakeDeezerCatalog(tracks: [adeleHello], fail: true);
          final run = await start(catalog);

          run.container.read(searchQueryProvider.notifier).submit('Hello');
          await _waitForEmissions(run.emissions, 2);

          expect(songIds(run.emissions.last), <String>['karaoke', 'adele']);
          expect(run.emissions.last.topResults, isEmpty);
          expect(run.emissions.last.remoteSearchFailed, isFalse);
        },
      );

      test('a query typed further drops and cancels the old answer', () async {
        if (!sqliteAvailable) return;
        final gate = Completer<void>();
        final catalog = _FakeDeezerCatalog(tracks: [adeleHello], gate: gate);
        final run = await start(catalog);

        run.container.read(searchQueryProvider.notifier).submit('Hello');
        await _waitForEmissions(run.emissions, 1);
        while (catalog.calls.length < 3) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        run.container.read(searchQueryProvider.notifier).submit('Hello world');
        // The local-only emissions of both queries, then the final one after
        // the cap: 'Hello' never reaches it.
        await _waitForEmissions(run.emissions, 3);

        expect(
          catalog.tokens.take(3).every((t) => t?.isCancelled ?? false),
          isTrue,
        );
        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(run.emissions, hasLength(3));
        expect(run.emissions.last.topResults, isEmpty);
      });

      test(
        'the switch off, the service off or Online services off send nothing',
        () async {
          if (!sqliteAvailable) return;
          for (final policy in <IntegrationPolicy>[
            const IntegrationPolicy(disabledKeys: {'deezer.searchRanking'}),
            const IntegrationPolicy(disabledKeys: {'deezer'}),
            const IntegrationPolicy(masterEnabled: false),
            const IntegrationPolicy.denyAll(),
          ]) {
            final catalog = _FakeDeezerCatalog(tracks: [adeleHello]);
            final run = await start(catalog, policy: policy);
            run.container.read(searchQueryProvider.notifier).submit('Hello');
            await _waitForEmissions(run.emissions, 2);
            expect(catalog.calls, isEmpty, reason: '$policy');
            expect(songIds(run.emissions.last), <String>['karaoke', 'adele']);
            expect(run.emissions.last.topResults, isEmpty);
            expect(run.recorder.recentSpans(), isEmpty);
          }
        },
      );

      test('offline sends nothing to Deezer', () async {
        if (!sqliteAvailable) return;
        final catalog = _FakeDeezerCatalog(tracks: [adeleHello]);
        final run = await start(catalog, online: false);
        run.container.read(searchQueryProvider.notifier).submit('Hello');
        await _waitForEmissions(run.emissions, 1);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(catalog.calls, isEmpty);
      });

      test(
        'a type filter asks only that endpoint and shows only that type',
        () async {
          if (!sqliteAvailable) return;
          final catalog = _FakeDeezerCatalog(
            tracks: [adeleHello],
            artists: const [DeezerArtist(id: 2, name: 'Adele')],
          );
          final run = await start(
            catalog,
            filter: SearchResultType.songs,
            server: const SearchResult3(
              songs: <Song>[Song(id: 'adele', title: 'Hello', artist: 'Adele')],
              artists: <Artist>[Artist(id: 'ar', name: 'Adele')],
            ),
          );
          run.container.read(searchQueryProvider.notifier).submit('Hello');
          await _waitForEmissions(run.emissions, 2);

          expect(catalog.calls, <String>['tracks:Hello']);
          expect(run.emissions.last.topResults.single, isA<TopSongResult>());

          run.container
              .read(searchFilterProvider.notifier)
              .select(SearchResultType.playlists);
          await _waitForEmissions(run.emissions, 3);
          expect(
            catalog.calls,
            hasLength(1),
            reason: 'collections skip Deezer',
          );
        },
      );
    });

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

      expect(emissions.last.result.artists.map((artist) => artist.id), <String>[
        'local-artist',
        'remote-artist',
      ]);
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
              Artist(
                id: 'artist-1',
                name: 'Remote Artist Replacement',
                isExternal: true,
              ),
              Artist(id: 'artist-2', name: 'Remote Artist'),
            ],
            albums: <Album>[
              Album(
                id: 'album-1',
                name: 'Remote Album Replacement',
                isExternal: false,
              ),
              Album(id: 'album-2', name: 'Remote Album'),
            ],
            songs: <Song>[
              Song(
                id: 'song-1',
                title: 'Remote Song Replacement',
                isExternal: true,
              ),
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
      expect(result.artists.first.isExternal, isTrue);
      expect(result.albums.map((album) => album.id), <String>[
        'album-1',
        'album-2',
      ]);
      expect(result.albums.first.name, 'Cache Album');
      expect(result.albums.first.isExternal, isFalse);
      expect(result.songs.map((song) => song.id), <String>['song-1', 'song-2']);
      expect(result.songs.first.title, 'Cache Song');
      expect(result.songs.first.isExternal, isTrue);
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

      expect(emissions.last.result.artists.map((artist) => artist.id), <String>[
        'artist-local',
        'artist-remote',
      ]);
    });

    test(
      'ranks relevance before source and source before stable order',
      () async {
        if (!sqliteAvailable) return;

        final database = createTestDatabase();
        await _insertArtist(
          database,
          id: 'server-prefix',
          name: 'Aurora Local',
        );
        final container = _createContainer(
          database,
          api: _FakeSearchApiClient(
            (_) async => const SearchResult3(
              artists: <Artist>[
                Artist(
                  id: 'remote-prefix',
                  name: 'Aurora Remote',
                  isExternal: true,
                ),
                Artist(id: 'remote-exact', name: 'Aurora', isExternal: true),
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
        container.read(searchQueryProvider.notifier).submit('Aurora');
        await _waitForEmissions(emissions, 2);

        expect(
          emissions.last.result.artists.map((artist) => artist.id),
          <String>['remote-exact', 'server-prefix', 'remote-prefix'],
        );
      },
    );

    for (final scenario
        in <
          ({
            SearchResultType filter,
            List<String> expectedArtists,
            List<String> expectedAlbums,
            List<String> expectedSongs,
            int expectedArtistCount,
            int expectedAlbumCount,
            int expectedSongCount,
          })
        >[
          (
            filter: SearchResultType.artists,
            expectedArtists: <String>['artist-local', 'artist-remote'],
            expectedAlbums: <String>[],
            expectedSongs: <String>[],
            expectedArtistCount: 20,
            expectedAlbumCount: 0,
            expectedSongCount: 0,
          ),
          (
            filter: SearchResultType.albums,
            expectedArtists: <String>[],
            expectedAlbums: <String>['album-local', 'album-remote'],
            expectedSongs: <String>[],
            expectedArtistCount: 0,
            expectedAlbumCount: 20,
            expectedSongCount: 0,
          ),
          (
            filter: SearchResultType.songs,
            expectedArtists: <String>[],
            expectedAlbums: <String>[],
            expectedSongs: <String>['song-local', 'song-remote'],
            expectedArtistCount: 0,
            expectedAlbumCount: 0,
            expectedSongCount: 20,
          ),
        ]) {
      test(
        '${scenario.filter.name} filter removes other result categories',
        () async {
          if (!sqliteAvailable) return;

          final database = createTestDatabase();
          await _insertArtist(
            database,
            id: 'artist-local',
            name: 'Cache Artist',
          );
          await _insertAlbum(database, id: 'album-local', name: 'Cache Album');
          await _insertSong(database, id: 'song-local', title: 'Cache Song');

          _Search3Call? apiCall;
          final container = _createContainer(
            database,
            api: _FakeSearchApiClient((call) async {
              apiCall = call;
              return const SearchResult3(
                artists: <Artist>[
                  Artist(id: 'artist-remote', name: 'Cache Remote Artist'),
                ],
                albums: <Album>[
                  Album(id: 'album-remote', name: 'Cache Remote Album'),
                ],
                songs: <Song>[
                  Song(id: 'song-remote', title: 'Cache Remote Song'),
                ],
              );
            }),
          );
          addTearDown(() async {
            container.dispose();
            await database.close();
          });

          final emissions = <SearchResultsState>[];
          final subscription = _listenToSearch(container, emissions);
          addTearDown(subscription.close);

          container.read(searchFilterProvider.notifier).select(scenario.filter);
          container.read(searchQueryProvider.notifier).submit('Cache');
          await _waitForEmissions(emissions, 2);

          final result = emissions.last.result;
          expect(
            result.artists.map((artist) => artist.id),
            scenario.expectedArtists,
          );
          expect(
            result.albums.map((album) => album.id),
            scenario.expectedAlbums,
          );
          expect(result.songs.map((song) => song.id), scenario.expectedSongs);
          expect(apiCall?.artistCount, scenario.expectedArtistCount);
          expect(apiCall?.albumCount, scenario.expectedAlbumCount);
          expect(apiCall?.songCount, scenario.expectedSongCount);
        },
      );
    }

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
      expect(emissions.last.remoteSearchFailed, isTrue);
      expect(asyncValues.where((value) => value.hasError), isEmpty);
    });

    test(
      'API failure with no local match exposes recoverable empty state',
      () async {
        if (!sqliteAvailable) return;

        final database = createTestDatabase();
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
        final subscription = _listenToSearch(container, emissions);
        addTearDown(subscription.close);

        container.read(searchQueryProvider.notifier).submit('Unmatched query');
        await _waitForEmissions(emissions, 2);

        final result = emissions.last;
        expect(result.isWaitingForApi, isFalse);
        expect(result.remoteSearchFailed, isTrue);
        expect(result.result.artists, isEmpty);
        expect(result.result.albums, isEmpty);
        expect(result.result.songs, isEmpty);
      },
    );
  });
}
