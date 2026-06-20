import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/listenbrainz_api_client.dart';
import 'package:navis/src/api/models/listenbrainz_playlist.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/playlists/presentation/playlist_providers.dart';
import 'package:navis/src/features/settings/data/external_scrobble_credentials.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:riverpod/src/framework.dart' show Override;

import '../../../../helpers/test_database.dart';

Future<void> _insertAlbum(
  NavisDatabase db, {
  required String id,
  required String name,
  DateTime? starred,
}) {
  return db
      .into(db.albumsTable)
      .insert(
        AlbumsTableCompanion.insert(
          id: id,
          name: name,
          artistName: const Value('Artist'),
          coverArt: Value('cover-$id'),
          starred: Value(starred),
        ),
      );
}

class _FakeDiscoveryApiClient extends SubsonicApiClient {
  _FakeDiscoveryApiClient(
    this._similarBySeed, {
    this.searchSongs = const <Song>[],
    this.searchGate,
    this.similarGate,
  }) : super(
         baseUrl: 'https://example.com',
         authConfig: const SubsonicAuthConfig(
           username: 'alice',
           password: 'secret',
           apiVersion: '1.16.1',
         ),
         enableLogging: false,
       );

  final Map<String, List<Song>> _similarBySeed;
  final List<Song> searchSongs;
  final Completer<void>? searchGate;
  final Completer<void>? similarGate;
  int activeSearchCalls = 0;
  int maxActiveSearchCalls = 0;
  int totalSearchCalls = 0;
  int totalSimilarSongCalls = 0;

  @override
  Future<List<Song>> getSimilarSongs(
    String seedSongId, {
    int count = 50,
    CancelToken? cancelToken,
  }) async {
    totalSimilarSongCalls++;
    final gate = similarGate;
    if (gate != null) {
      await gate.future;
    }
    return _similarBySeed[seedSongId] ?? const <Song>[];
  }

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
    totalSearchCalls++;
    activeSearchCalls++;
    if (activeSearchCalls > maxActiveSearchCalls) {
      maxActiveSearchCalls = activeSearchCalls;
    }
    try {
      final gate = searchGate;
      if (gate != null) {
        await gate.future;
      }
      return SearchResult3(songs: searchSongs.take(songCount).toList());
    } finally {
      activeSearchCalls--;
    }
  }
}

class _FakeListenBrainzApiClient extends ListenBrainzApiClient {
  _FakeListenBrainzApiClient({
    required this.playlists,
    List<ListenBrainzPlaylist>? createdForPlaylists,
    List<ListenBrainzPlaylist>? userPlaylists,
    List<ListenBrainzPlaylist>? recommendationPlaylists,
    Map<String, ListenBrainzPlaylist>? detailsById,
    Map<String, Completer<ListenBrainzPlaylist>>? detailCompleters,
    this.recommendationCompleter,
  }) : createdForPlaylists = createdForPlaylists ?? playlists,
       userPlaylists = userPlaylists ?? const <ListenBrainzPlaylist>[],
       recommendationPlaylists =
           recommendationPlaylists ?? const <ListenBrainzPlaylist>[],
       detailsById = detailsById ?? <String, ListenBrainzPlaylist>{},
       detailCompleters =
           detailCompleters ?? <String, Completer<ListenBrainzPlaylist>>{};

  final List<ListenBrainzPlaylist> playlists;
  final List<ListenBrainzPlaylist> createdForPlaylists;
  final List<ListenBrainzPlaylist> userPlaylists;
  final List<ListenBrainzPlaylist> recommendationPlaylists;
  final Map<String, ListenBrainzPlaylist> detailsById;
  final Map<String, Completer<ListenBrainzPlaylist>> detailCompleters;
  final Completer<List<ListenBrainzPlaylist>>? recommendationCompleter;
  final List<String> detailStarts = <String>[];
  int createdForCalls = 0;
  int userPlaylistCalls = 0;
  int recommendationPlaylistCalls = 0;

  @override
  Future<List<ListenBrainzPlaylist>> getCreatedForPlaylists({
    required String userName,
    int count = 100,
    int offset = 0,
  }) async {
    createdForCalls++;
    return createdForPlaylists;
  }

  @override
  Future<List<ListenBrainzPlaylist>> getUserPlaylists({
    required String userName,
    String? userToken,
    int count = 100,
    int offset = 0,
  }) async {
    userPlaylistCalls++;
    return userPlaylists;
  }

  @override
  Future<List<ListenBrainzPlaylist>> getRecommendationPlaylists({
    required String userName,
    String? userToken,
  }) async {
    recommendationPlaylistCalls++;
    if (recommendationCompleter != null) {
      return recommendationCompleter!.future;
    }
    return recommendationPlaylists;
  }

  @override
  Future<ListenBrainzPlaylist> getPlaylist(
    String playlistMbid, {
    bool fetchMetadata = true,
    String? userToken,
  }) async {
    detailStarts.add(playlistMbid);
    final detailCompleter = detailCompleters[playlistMbid];
    if (detailCompleter != null) {
      return detailCompleter.future;
    }
    final allPlaylists = <ListenBrainzPlaylist>[
      ...playlists,
      ...createdForPlaylists,
      ...userPlaylists,
      ...recommendationPlaylists,
    ];
    return detailsById[playlistMbid] ??
        allPlaylists.firstWhere(
          (playlist) => playlist.identifier == playlistMbid,
        );
  }
}

class _FakeExternalScrobbleCredentialStore
    implements ExternalScrobbleCredentialStore {
  const _FakeExternalScrobbleCredentialStore(this.token);

  final String? token;

  @override
  Future<void> clearListenBrainzToken() async {}

  @override
  Future<String?> readListenBrainzToken() async => token;

  @override
  Future<void> saveListenBrainzToken(String value) async {}
}

extension _HomeRandomShowcaseItemTestX on HomeRandomShowcaseItem {
  HomeRandomShowcaseAlbum get album => this as HomeRandomShowcaseAlbum;

  HomeRandomShowcaseListenBrainz get listenBrainz =>
      this as HomeRandomShowcaseListenBrainz;
}

void main() {
  setUp(debugResetListenBrainzDiscoverSessionCacheForTests);

  test('ListenBrainz weekly detail requests start concurrently', () async {
    final database = createTestDatabase();
    final explorationCompleter = Completer<ListenBrainzPlaylist>();
    final jamsCompleter = Completer<ListenBrainzPlaylist>();
    final fakeListenBrainz = _FakeListenBrainzApiClient(
      playlists: const <ListenBrainzPlaylist>[],
      recommendationPlaylists: const <ListenBrainzPlaylist>[
        ListenBrainzPlaylist(
          identifier: 'exploration',
          title: 'Weekly Exploration',
          sourcePatch: 'weekly-exploration',
          tracks: <ListenBrainzPlaylistTrack>[],
        ),
        ListenBrainzPlaylist(
          identifier: 'jams',
          title: 'Weekly Jams',
          sourcePatch: 'weekly-jams',
          tracks: <ListenBrainzPlaylistTrack>[],
        ),
      ],
      detailCompleters: <String, Completer<ListenBrainzPlaylist>>{
        'exploration': explorationCompleter,
        'jams': jamsCompleter,
      },
    );
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                listenBrainzScrobblingEnabled: true,
                listenBrainzTokenValid: true,
                listenBrainzUserName: 'alice',
              ),
            ),
          ),
          externalScrobbleCredentialStoreProvider.overrideWithValue(
            const _FakeExternalScrobbleCredentialStore('token'),
          ),
          listenBrainzApiClientProvider.overrideWithValue(fakeListenBrainz),
          subsonicApiProvider.overrideWithValue(_FakeDiscoveryApiClient({})),
        ],
      ),
    );
    addTearDown(() async {
      if (!explorationCompleter.isCompleted) {
        explorationCompleter.complete(
          const ListenBrainzPlaylist(
            identifier: 'exploration',
            title: 'Weekly Exploration',
            sourcePatch: 'weekly-exploration',
            tracks: <ListenBrainzPlaylistTrack>[],
          ),
        );
      }
      if (!jamsCompleter.isCompleted) {
        jamsCompleter.complete(
          const ListenBrainzPlaylist(
            identifier: 'jams',
            title: 'Weekly Jams',
            sourcePatch: 'weekly-jams',
            tracks: <ListenBrainzPlaylistTrack>[],
          ),
        );
      }
      container.dispose();
      await database.close();
    });

    final future = container.read(listenBrainzDiscoverProvider.future);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(
      fakeListenBrainz.detailStarts,
      containsAll(<String>[
        'exploration',
        'jams',
      ]),
    );

    explorationCompleter.complete(
      const ListenBrainzPlaylist(
        identifier: 'exploration',
        title: 'Weekly Exploration',
        sourcePatch: 'weekly-exploration',
        tracks: <ListenBrainzPlaylistTrack>[],
      ),
    );
    jamsCompleter.complete(
      const ListenBrainzPlaylist(
        identifier: 'jams',
        title: 'Weekly Jams',
        sourcePatch: 'weekly-jams',
        tracks: <ListenBrainzPlaylistTrack>[],
      ),
    );
    await future;
  });

  test('ListenBrainz remote matching is globally bounded', () async {
    final database = createTestDatabase();
    final searchGate = Completer<void>();
    final fakeApi = _FakeDiscoveryApiClient(
      {},
      searchGate: searchGate,
      searchSongs: const <Song>[],
    );
    final tracks = List<ListenBrainzPlaylistTrack>.generate(
      5,
      (index) => ListenBrainzPlaylistTrack(
        title: 'Remote Song $index',
        creator: 'Remote Artist',
      ),
    );
    final fakeListenBrainz = _FakeListenBrainzApiClient(
      playlists: const <ListenBrainzPlaylist>[],
      recommendationPlaylists: const <ListenBrainzPlaylist>[
        ListenBrainzPlaylist(
          identifier: 'exploration',
          title: 'Weekly Exploration',
          sourcePatch: 'weekly-exploration',
          tracks: <ListenBrainzPlaylistTrack>[],
        ),
        ListenBrainzPlaylist(
          identifier: 'jams',
          title: 'Weekly Jams',
          sourcePatch: 'weekly-jams',
          tracks: <ListenBrainzPlaylistTrack>[],
        ),
      ],
      detailsById: <String, ListenBrainzPlaylist>{
        'exploration': ListenBrainzPlaylist(
          identifier: 'exploration',
          title: 'Weekly Exploration',
          sourcePatch: 'weekly-exploration',
          tracks: tracks,
        ),
        'jams': ListenBrainzPlaylist(
          identifier: 'jams',
          title: 'Weekly Jams',
          sourcePatch: 'weekly-jams',
          tracks: tracks,
        ),
      },
    );
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                listenBrainzScrobblingEnabled: true,
                listenBrainzTokenValid: true,
                listenBrainzUserName: 'alice',
              ),
            ),
          ),
          externalScrobbleCredentialStoreProvider.overrideWithValue(
            const _FakeExternalScrobbleCredentialStore('token'),
          ),
          listenBrainzApiClientProvider.overrideWithValue(fakeListenBrainz),
          subsonicApiProvider.overrideWithValue(fakeApi),
        ],
      ),
    );
    addTearDown(() async {
      if (!searchGate.isCompleted) {
        searchGate.complete();
      }
      container.dispose();
      await database.close();
    });

    final future = container.read(listenBrainzDiscoverProvider.future);
    for (
      var attempt = 0;
      attempt < 50 && fakeApi.activeSearchCalls < 6;
      attempt++
    ) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(fakeApi.maxActiveSearchCalls, 6);
    searchGate.complete();
    await future;

    expect(fakeApi.totalSearchCalls, 10);
    expect(fakeApi.maxActiveSearchCalls, lessThanOrEqualTo(6));
  });

  test(
    'ListenBrainz duplicate exact title and artist candidates are not ambiguous',
    () async {
      final database = createTestDatabase();
      final fakeApi = _FakeDiscoveryApiClient(
        {},
        searchSongs: const <Song>[
          Song(
            id: 'toxicity-album',
            title: 'Toxicity',
            artist: 'System Of A Down',
            album: 'Toxicity',
            duration: 219,
          ),
          Song(
            id: 'toxicity-compilation',
            title: 'Toxicity',
            artist: 'System Of A Down',
            album: 'Greatest Hits',
            duration: 219,
          ),
        ],
      );
      final fakeListenBrainz = _FakeListenBrainzApiClient(
        playlists: const <ListenBrainzPlaylist>[],
        recommendationPlaylists: const <ListenBrainzPlaylist>[
          ListenBrainzPlaylist(
            identifier: 'jams',
            title: 'Weekly Jams',
            sourcePatch: 'weekly-jams',
            tracks: <ListenBrainzPlaylistTrack>[],
          ),
        ],
        detailsById: const <String, ListenBrainzPlaylist>{
          'jams': ListenBrainzPlaylist(
            identifier: 'jams',
            title: 'Weekly Jams',
            sourcePatch: 'weekly-jams',
            tracks: <ListenBrainzPlaylistTrack>[
              ListenBrainzPlaylistTrack(
                title: 'Toxicity',
                creator: 'System Of A Down',
              ),
            ],
          ),
        },
      );
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            appSettingsProvider.overrideWithValue(
              AsyncData(
                const AppSettingsModel.defaults().copyWith(
                  listenBrainzScrobblingEnabled: true,
                  listenBrainzTokenValid: true,
                  listenBrainzUserName: 'alice',
                ),
              ),
            ),
            externalScrobbleCredentialStoreProvider.overrideWithValue(
              const _FakeExternalScrobbleCredentialStore('token'),
            ),
            listenBrainzApiClientProvider.overrideWithValue(fakeListenBrainz),
            subsonicApiProvider.overrideWithValue(fakeApi),
          ],
        ),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final result = await container.read(listenBrainzDiscoverProvider.future);

      expect(result, hasLength(1));
      expect(
        result.single.recommendations.single.status,
        ListenBrainzRecommendationMatchStatus.matched,
      );
      expect(result.single.recommendations.single.song!.id, 'toxicity-album');
    },
  );

  test('ListenBrainz local matches do not call search3', () async {
    final database = createTestDatabase();
    await database.libraryDao.upsertSongs(<SongsTableCompanion>[
      SongsTableCompanion.insert(
        id: 'talking-to-the-moon',
        title: 'Talking to the Moon',
        artistName: const Value('Bruno Mars'),
        albumName: const Value('Doo-Wops & Hooligans'),
        duration: const Value(217),
      ),
    ]);
    final fakeApi = _FakeDiscoveryApiClient({}, searchSongs: const <Song>[]);
    final fakeListenBrainz = _FakeListenBrainzApiClient(
      playlists: const <ListenBrainzPlaylist>[],
      recommendationPlaylists: const <ListenBrainzPlaylist>[
        ListenBrainzPlaylist(
          identifier: 'jams',
          title: 'Weekly Jams',
          sourcePatch: 'weekly-jams',
          tracks: <ListenBrainzPlaylistTrack>[],
        ),
      ],
      detailsById: const <String, ListenBrainzPlaylist>{
        'jams': ListenBrainzPlaylist(
          identifier: 'jams',
          title: 'Weekly Jams',
          sourcePatch: 'weekly-jams',
          tracks: <ListenBrainzPlaylistTrack>[
            ListenBrainzPlaylistTrack(
              title: 'Talking to the Moon',
              creator: 'Bruno Mars',
              album: 'Doo-Wops & Hooligans',
              durationMs: 217000,
            ),
          ],
        ),
      },
    );
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                listenBrainzScrobblingEnabled: true,
                listenBrainzTokenValid: true,
                listenBrainzUserName: 'alice',
              ),
            ),
          ),
          externalScrobbleCredentialStoreProvider.overrideWithValue(
            const _FakeExternalScrobbleCredentialStore('token'),
          ),
          listenBrainzApiClientProvider.overrideWithValue(fakeListenBrainz),
          subsonicApiProvider.overrideWithValue(fakeApi),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    final result = await container.read(listenBrainzDiscoverProvider.future);

    expect(result, hasLength(1));
    expect(
      result.single.recommendations.single.status,
      ListenBrainzRecommendationMatchStatus.matched,
    );
    expect(
      result.single.recommendations.single.tableSong!.id,
      'talking-to-the-moon',
    );
    expect(fakeApi.totalSearchCalls, 0);
  });

  test('online unfiltered uses server random source', () async {
    final database = createTestDatabase();
    final fakeApi = _FakeDiscoveryApiClient({});
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          subsonicApiProvider.overrideWithValue(fakeApi),
          homeRandomAlbumsProvider.overrideWith(
            (ref) async => const <Album>[
              Album(
                id: 'srv-1',
                name: 'Server Album',
                artist: 'Server Artist',
                coverArt: 'server-cover',
                year: 2025,
                songCount: 10,
              ),
            ],
          ),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    final result = await container.read(
      homeRandomShowcaseProvider((
        downloadedOnly: false,
        likedOnly: false,
      )).future,
    );

    expect(result, hasLength(1));
    expect(result.first.album.id, 'srv-1');
    expect(result.first.album.source, HomeRandomShowcaseSource.serverRandom);
  });

  test(
    'online unfiltered prepends weekly ListenBrainz playlists in fixed order',
    () async {
      final database = createTestDatabase();
      final fakeApi = _FakeDiscoveryApiClient(
        {},
        searchSongs: const <Song>[
          Song(id: 'song-exploration', title: 'Explore Song', artist: 'Artist'),
          Song(id: 'song-jams', title: 'Jam Song', artist: 'Artist'),
        ],
      );
      final fakeListenBrainz = _FakeListenBrainzApiClient(
        playlists: const <ListenBrainzPlaylist>[],
        createdForPlaylists: const <ListenBrainzPlaylist>[
          ListenBrainzPlaylist(
            identifier: 'created-jams',
            title: 'Weekly Jams',
            tracks: <ListenBrainzPlaylistTrack>[],
          ),
        ],
        userPlaylists: const <ListenBrainzPlaylist>[
          ListenBrainzPlaylist(
            identifier: 'owned-exploration',
            title: 'Weekly Exploration',
            tracks: <ListenBrainzPlaylistTrack>[],
          ),
        ],
        recommendationPlaylists: const <ListenBrainzPlaylist>[
          ListenBrainzPlaylist(
            identifier: 'daily-1',
            title: 'Daily Mix 1',
            sourcePatch: 'daily-jams',
            tracks: <ListenBrainzPlaylistTrack>[],
          ),
          ListenBrainzPlaylist(
            identifier: 'jams',
            title: 'Weekly Jams for alice, week of 2026-06-15',
            sourcePatch: 'weekly-jams',
            tracks: <ListenBrainzPlaylistTrack>[],
          ),
          ListenBrainzPlaylist(
            identifier: 'monthly',
            title: 'Monthly Jams',
            sourcePatch: 'monthly-jams',
            tracks: <ListenBrainzPlaylistTrack>[],
          ),
          ListenBrainzPlaylist(
            identifier: 'exploration',
            title: 'Weekly Exploration for alice, week of 2026-06-15',
            sourcePatch: 'weekly-exploration',
            tracks: <ListenBrainzPlaylistTrack>[],
          ),
        ],
        detailsById: const <String, ListenBrainzPlaylist>{
          'jams': ListenBrainzPlaylist(
            identifier: 'jams',
            title: 'Weekly Jams for alice, week of 2026-06-15',
            tracks: <ListenBrainzPlaylistTrack>[
              ListenBrainzPlaylistTrack(title: 'Jam Song', creator: 'Artist'),
            ],
          ),
          'exploration': ListenBrainzPlaylist(
            identifier: 'exploration',
            title: 'Weekly Exploration for alice, week of 2026-06-15',
            tracks: <ListenBrainzPlaylistTrack>[
              ListenBrainzPlaylistTrack(
                title: 'Explore Song',
                creator: 'Artist',
              ),
            ],
          ),
        },
      );
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            appSettingsProvider.overrideWithValue(
              AsyncData(
                const AppSettingsModel.defaults().copyWith(
                  listenBrainzScrobblingEnabled: true,
                  listenBrainzTokenValid: true,
                  listenBrainzUserName: 'alice',
                ),
              ),
            ),
            externalScrobbleCredentialStoreProvider.overrideWithValue(
              const _FakeExternalScrobbleCredentialStore('token'),
            ),
            listenBrainzApiClientProvider.overrideWithValue(fakeListenBrainz),
            subsonicApiProvider.overrideWithValue(fakeApi),
            homeRandomAlbumsProvider.overrideWith(
              (ref) async => const <Album>[
                Album(id: 'srv-1', name: 'Server Album'),
              ],
            ),
          ],
        ),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      await container.read(listenBrainzDiscoverProvider.future);
      final result = await container.read(
        homeRandomShowcaseProvider((
          downloadedOnly: false,
          likedOnly: false,
        )).future,
      );

      expect(result, hasLength(3));
      expect(fakeListenBrainz.createdForCalls, 0);
      expect(fakeListenBrainz.userPlaylistCalls, 0);
      expect(fakeListenBrainz.recommendationPlaylistCalls, 1);
      expect(
        result[0].listenBrainz.playlist!.displayTitle,
        'Weekly Exploration',
      );
      expect(
        result[0].listenBrainz.playlist!.playlist.identifier,
        'exploration',
      );
      expect(
        result[1].listenBrainz.playlist!.displayTitle,
        'Weekly Jams',
      );
      expect(
        result[1].listenBrainz.playlist!.playlist.identifier,
        'jams',
      );
      expect(result[2].album.id, 'srv-1');
    },
  );

  test(
    'playlist library provider includes ListenBrainz virtual playlists',
    () async {
      final virtualPlaylists = <ListenBrainzDiscoverPlaylist>[
        ListenBrainzDiscoverPlaylist(
          playlist: const ListenBrainzPlaylist(
            identifier: 'exploration',
            title: 'Weekly Exploration',
            sourcePatch: 'weekly-exploration',
            tracks: <ListenBrainzPlaylistTrack>[
              ListenBrainzPlaylistTrack(title: 'Explore Song'),
            ],
          ),
          recommendations: const <ListenBrainzResolvedRecommendation>[
            ListenBrainzResolvedRecommendation(
              track: ListenBrainzPlaylistTrack(title: 'Explore Song'),
              status: ListenBrainzRecommendationMatchStatus.pending,
            ),
          ],
        ),
        ListenBrainzDiscoverPlaylist(
          playlist: const ListenBrainzPlaylist(
            identifier: 'jams',
            title: 'Weekly Jams',
            sourcePatch: 'weekly-jams',
            tracks: <ListenBrainzPlaylistTrack>[
              ListenBrainzPlaylistTrack(title: 'Jam Song'),
            ],
          ),
          recommendations: const <ListenBrainzResolvedRecommendation>[
            ListenBrainzResolvedRecommendation(
              track: ListenBrainzPlaylistTrack(title: 'Jam Song'),
              status: ListenBrainzRecommendationMatchStatus.pending,
            ),
          ],
        ),
      ];
      final container = ProviderContainer(
        overrides: <Override>[
          playlistListProvider.overrideWithValue(
            const AsyncData<List<PlaylistsTableData>>(<PlaylistsTableData>[
              PlaylistsTableData(id: 'server-playlist', name: 'Server Mix'),
            ]),
          ),
          listenBrainzDiscoverStreamProvider.overrideWithValue(
            AsyncData<List<ListenBrainzDiscoverPlaylist>>(virtualPlaylists),
          ),
        ],
      );
      addTearDown(container.dispose);

      final libraryItems = container.read(playlistLibraryItemsProvider);

      expect(libraryItems.hasValue, isTrue);
      expect(
        libraryItems.requireValue.map((item) => item.id),
        <String>[
          listenBrainzWeeklyExplorationVirtualPlaylistId,
          listenBrainzWeeklyJamsVirtualPlaylistId,
          'server-playlist',
        ],
      );
    },
  );

  test(
    'online unfiltered prepends loading ListenBrainz weekly cards',
    () async {
      final database = createTestDatabase();
      final recommendationCompleter = Completer<List<ListenBrainzPlaylist>>();
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            appSettingsProvider.overrideWithValue(
              AsyncData(
                const AppSettingsModel.defaults().copyWith(
                  listenBrainzScrobblingEnabled: true,
                  listenBrainzTokenValid: true,
                  listenBrainzUserName: 'alice',
                ),
              ),
            ),
            externalScrobbleCredentialStoreProvider.overrideWithValue(
              const _FakeExternalScrobbleCredentialStore('token'),
            ),
            listenBrainzApiClientProvider.overrideWithValue(
              _FakeListenBrainzApiClient(
                playlists: const <ListenBrainzPlaylist>[],
                recommendationCompleter: recommendationCompleter,
              ),
            ),
            subsonicApiProvider.overrideWithValue(_FakeDiscoveryApiClient({})),
            homeRandomAlbumsProvider.overrideWith(
              (ref) async => const <Album>[
                Album(id: 'srv-1', name: 'Server Album'),
              ],
            ),
          ],
        ),
      );
      addTearDown(() async {
        if (!recommendationCompleter.isCompleted) {
          recommendationCompleter.complete(const <ListenBrainzPlaylist>[]);
        }
        container.dispose();
        await database.close();
      });

      final result = await container.read(
        homeRandomShowcaseProvider((
          downloadedOnly: false,
          likedOnly: false,
        )).future,
      );

      expect(result, hasLength(3));
      expect(result[0].stableId, 'listenbrainz:weekly-exploration');
      expect(result[0].listenBrainz.isLoading, isTrue);
      expect(result[1].stableId, 'listenbrainz:weekly-jams');
      expect(result[1].listenBrainz.isLoading, isTrue);
      expect(result[2].album.id, 'srv-1');
    },
  );

  test(
    'online unfiltered compacts Weekly Jams to front when exploration is absent',
    () async {
      final database = createTestDatabase();
      final fakeApi = _FakeDiscoveryApiClient(
        {},
        searchSongs: const <Song>[
          Song(id: 'song-jams', title: 'Jam Song', artist: 'Artist'),
        ],
      );
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            appSettingsProvider.overrideWithValue(
              AsyncData(
                const AppSettingsModel.defaults().copyWith(
                  listenBrainzScrobblingEnabled: true,
                  listenBrainzTokenValid: true,
                  listenBrainzUserName: 'alice',
                ),
              ),
            ),
            externalScrobbleCredentialStoreProvider.overrideWithValue(
              const _FakeExternalScrobbleCredentialStore('token'),
            ),
            listenBrainzApiClientProvider.overrideWithValue(
              _FakeListenBrainzApiClient(
                playlists: const <ListenBrainzPlaylist>[],
                recommendationPlaylists: const <ListenBrainzPlaylist>[
                  ListenBrainzPlaylist(
                    identifier: 'jams',
                    title: 'Weekly Jams for alice, week of 2026-06-15',
                    sourcePatch: 'weekly-jams',
                    tracks: <ListenBrainzPlaylistTrack>[],
                  ),
                ],
                detailsById: const <String, ListenBrainzPlaylist>{
                  'jams': ListenBrainzPlaylist(
                    identifier: 'jams',
                    title: 'Weekly Jams for alice, week of 2026-06-15',
                    tracks: <ListenBrainzPlaylistTrack>[
                      ListenBrainzPlaylistTrack(
                        title: 'Jam Song',
                        creator: 'Artist',
                      ),
                    ],
                  ),
                },
              ),
            ),
            subsonicApiProvider.overrideWithValue(fakeApi),
            homeRandomAlbumsProvider.overrideWith(
              (ref) async => const <Album>[
                Album(id: 'srv-1', name: 'Server Album'),
              ],
            ),
          ],
        ),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      await container.read(listenBrainzDiscoverProvider.future);
      final result = await container.read(
        homeRandomShowcaseProvider((
          downloadedOnly: false,
          likedOnly: false,
        )).future,
      );

      expect(result, hasLength(2));
      expect(result.first.listenBrainz.playlist!.playlist.identifier, 'jams');
      expect(result[1].album.id, 'srv-1');
    },
  );

  test(
    'online unfiltered ignores ordinary ListenBrainz playlists with weekly titles',
    () async {
      final database = createTestDatabase();
      final fakeApi = _FakeDiscoveryApiClient({});
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            appSettingsProvider.overrideWithValue(
              AsyncData(
                const AppSettingsModel.defaults().copyWith(
                  listenBrainzScrobblingEnabled: true,
                  listenBrainzTokenValid: true,
                  listenBrainzUserName: 'alice',
                ),
              ),
            ),
            externalScrobbleCredentialStoreProvider.overrideWithValue(
              const _FakeExternalScrobbleCredentialStore('token'),
            ),
            listenBrainzApiClientProvider.overrideWithValue(
              _FakeListenBrainzApiClient(
                playlists: const <ListenBrainzPlaylist>[],
                createdForPlaylists: const <ListenBrainzPlaylist>[],
                userPlaylists: const <ListenBrainzPlaylist>[
                  ListenBrainzPlaylist(
                    identifier: 'jams',
                    title: 'Weekly Jams',
                    tracks: <ListenBrainzPlaylistTrack>[],
                  ),
                ],
              ),
            ),
            subsonicApiProvider.overrideWithValue(fakeApi),
            homeRandomAlbumsProvider.overrideWith(
              (ref) async => const <Album>[
                Album(id: 'srv-1', name: 'Server Album'),
              ],
            ),
          ],
        ),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      await container.read(listenBrainzDiscoverProvider.future);
      final result = await container.read(
        homeRandomShowcaseProvider((
          downloadedOnly: false,
          likedOnly: false,
        )).future,
      );

      expect(result, hasLength(1));
      expect(result.first.album.id, 'srv-1');
    },
  );

  test('online unfiltered ignores non-target ListenBrainz playlists', () async {
    final database = createTestDatabase();
    final fakeApi = _FakeDiscoveryApiClient({});
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                listenBrainzScrobblingEnabled: true,
                listenBrainzTokenValid: true,
                listenBrainzUserName: 'alice',
              ),
            ),
          ),
          externalScrobbleCredentialStoreProvider.overrideWithValue(
            const _FakeExternalScrobbleCredentialStore('token'),
          ),
          listenBrainzApiClientProvider.overrideWithValue(
            _FakeListenBrainzApiClient(
              playlists: const <ListenBrainzPlaylist>[],
              recommendationPlaylists: const <ListenBrainzPlaylist>[
                ListenBrainzPlaylist(
                  identifier: 'monthly',
                  title: 'Monthly Weekly Mix',
                  sourcePatch: 'daily-jams',
                  tracks: <ListenBrainzPlaylistTrack>[],
                ),
              ],
            ),
          ),
          subsonicApiProvider.overrideWithValue(fakeApi),
          homeRandomAlbumsProvider.overrideWith(
            (ref) async => const <Album>[
              Album(id: 'srv-1', name: 'Server Album'),
            ],
          ),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    await container.read(listenBrainzDiscoverProvider.future);
    final result = await container.read(
      homeRandomShowcaseProvider((
        downloadedOnly: false,
        likedOnly: false,
      )).future,
    );

    expect(result, hasLength(1));
    expect(result.first.album.id, 'srv-1');
  });

  test(
    'ListenBrainz card is hidden when Subsonic API cannot match tracks',
    () async {
      final database = createTestDatabase();
      await _insertAlbum(database, id: 'loc-1', name: 'Local Album');
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            appSettingsProvider.overrideWithValue(
              AsyncData(
                const AppSettingsModel.defaults().copyWith(
                  listenBrainzScrobblingEnabled: true,
                  listenBrainzTokenValid: true,
                  listenBrainzUserName: 'alice',
                ),
              ),
            ),
            externalScrobbleCredentialStoreProvider.overrideWithValue(
              const _FakeExternalScrobbleCredentialStore('token'),
            ),
            listenBrainzApiClientProvider.overrideWithValue(
              _FakeListenBrainzApiClient(
                playlists: const <ListenBrainzPlaylist>[],
                recommendationPlaylists: const <ListenBrainzPlaylist>[
                  ListenBrainzPlaylist(
                    identifier: 'exploration',
                    title: 'Weekly Exploration for alice, week of 2026-06-15',
                    sourcePatch: 'weekly-exploration',
                    tracks: <ListenBrainzPlaylistTrack>[],
                  ),
                ],
                detailsById: const <String, ListenBrainzPlaylist>{
                  'exploration': ListenBrainzPlaylist(
                    identifier: 'exploration',
                    title: 'Weekly Exploration for alice, week of 2026-06-15',
                    tracks: <ListenBrainzPlaylistTrack>[
                      ListenBrainzPlaylistTrack(
                        title: 'Remote Song',
                        creator: 'Remote Artist',
                      ),
                    ],
                  ),
                },
              ),
            ),
            subsonicApiProvider.overrideWithValue(null),
            homeRandomAlbumsProvider.overrideWith(
              (ref) async => const <Album>[
                Album(id: 'srv-1', name: 'Server Album'),
              ],
            ),
          ],
        ),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      await container.read(listenBrainzDiscoverProvider.future);
      final result = await container.read(
        homeRandomShowcaseProvider((
          downloadedOnly: false,
          likedOnly: false,
        )).future,
      );

      expect(result, hasLength(1));
      expect(result.first.album.source, HomeRandomShowcaseSource.localFallback);
    },
  );

  test(
    'online unfiltered removes weekly playlist with zero detail tracks',
    () async {
      final database = createTestDatabase();
      final fakeApi = _FakeDiscoveryApiClient({});
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            appSettingsProvider.overrideWithValue(
              AsyncData(
                const AppSettingsModel.defaults().copyWith(
                  listenBrainzScrobblingEnabled: true,
                  listenBrainzTokenValid: true,
                  listenBrainzUserName: 'alice',
                ),
              ),
            ),
            externalScrobbleCredentialStoreProvider.overrideWithValue(
              const _FakeExternalScrobbleCredentialStore('token'),
            ),
            listenBrainzApiClientProvider.overrideWithValue(
              _FakeListenBrainzApiClient(
                playlists: const <ListenBrainzPlaylist>[],
                recommendationPlaylists: const <ListenBrainzPlaylist>[
                  ListenBrainzPlaylist(
                    identifier: 'exploration',
                    title: 'Weekly Exploration',
                    sourcePatch: 'weekly-exploration',
                    tracks: <ListenBrainzPlaylistTrack>[],
                  ),
                ],
                detailsById: const <String, ListenBrainzPlaylist>{
                  'exploration': ListenBrainzPlaylist(
                    identifier: 'exploration',
                    title: 'Weekly Exploration',
                    tracks: <ListenBrainzPlaylistTrack>[],
                  ),
                },
              ),
            ),
            subsonicApiProvider.overrideWithValue(fakeApi),
            homeRandomAlbumsProvider.overrideWith(
              (ref) async => const <Album>[
                Album(id: 'srv-1', name: 'Server Album'),
              ],
            ),
          ],
        ),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      await container.read(listenBrainzDiscoverProvider.future);
      final result = await container.read(
        homeRandomShowcaseProvider((
          downloadedOnly: false,
          likedOnly: false,
        )).future,
      );

      expect(result, hasLength(1));
      expect(result.first.album.id, 'srv-1');
    },
  );

  test('online unfiltered removes weekly playlist with zero matches', () async {
    final database = createTestDatabase();
    final fakeApi = _FakeDiscoveryApiClient({});
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                listenBrainzScrobblingEnabled: true,
                listenBrainzTokenValid: true,
                listenBrainzUserName: 'alice',
              ),
            ),
          ),
          externalScrobbleCredentialStoreProvider.overrideWithValue(
            const _FakeExternalScrobbleCredentialStore('token'),
          ),
          listenBrainzApiClientProvider.overrideWithValue(
            _FakeListenBrainzApiClient(
              playlists: const <ListenBrainzPlaylist>[],
              recommendationPlaylists: const <ListenBrainzPlaylist>[
                ListenBrainzPlaylist(
                  identifier: 'exploration',
                  title: 'Weekly Exploration',
                  sourcePatch: 'weekly-exploration',
                  tracks: <ListenBrainzPlaylistTrack>[],
                ),
              ],
              detailsById: const <String, ListenBrainzPlaylist>{
                'exploration': ListenBrainzPlaylist(
                  identifier: 'exploration',
                  title: 'Weekly Exploration',
                  tracks: <ListenBrainzPlaylistTrack>[
                    ListenBrainzPlaylistTrack(
                      title: 'Remote Song',
                      creator: 'Remote Artist',
                    ),
                  ],
                ),
              },
            ),
          ),
          subsonicApiProvider.overrideWithValue(fakeApi),
          homeRandomAlbumsProvider.overrideWith(
            (ref) async => const <Album>[
              Album(id: 'srv-1', name: 'Server Album'),
            ],
          ),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    await container.read(listenBrainzDiscoverProvider.future);
    final result = await container.read(
      homeRandomShowcaseProvider((
        downloadedOnly: false,
        likedOnly: false,
      )).future,
    );

    expect(result, hasLength(1));
    expect(result.first.album.id, 'srv-1');
  });

  test('missing token falls back to random albums', () async {
    final database = createTestDatabase();
    final fakeApi = _FakeDiscoveryApiClient({});
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(
                listenBrainzScrobblingEnabled: true,
                listenBrainzTokenValid: true,
                listenBrainzUserName: 'alice',
              ),
            ),
          ),
          externalScrobbleCredentialStoreProvider.overrideWithValue(
            const _FakeExternalScrobbleCredentialStore(null),
          ),
          listenBrainzApiClientProvider.overrideWithValue(
            _FakeListenBrainzApiClient(
              playlists: const <ListenBrainzPlaylist>[
                ListenBrainzPlaylist(
                  identifier: 'exploration',
                  title: 'Weekly Exploration',
                  tracks: <ListenBrainzPlaylistTrack>[],
                ),
              ],
            ),
          ),
          subsonicApiProvider.overrideWithValue(fakeApi),
          homeRandomAlbumsProvider.overrideWith(
            (ref) async => const <Album>[
              Album(id: 'srv-1', name: 'Server Album'),
            ],
          ),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    await container.read(listenBrainzDiscoverProvider.future);
    final result = await container.read(
      homeRandomShowcaseProvider((
        downloadedOnly: false,
        likedOnly: false,
      )).future,
    );

    expect(result, hasLength(1));
    expect(result.first.album.id, 'srv-1');
  });

  test(
    'online unfiltered uses liked-song discovery before random fallback',
    () async {
      final database = createTestDatabase();
      for (var i = 0; i < 12; i++) {
        await _insertAlbum(database, id: 'disc-$i', name: 'Discovery $i');
      }

      final fakeApi = _FakeDiscoveryApiClient({
        'seed-1': const <Song>[
          Song(id: 'sim-1', title: 'Sim 1', albumId: 'disc-1', album: 'Disc 1'),
          Song(id: 'sim-2', title: 'Sim 2', albumId: 'disc-2', album: 'Disc 2'),
          Song(id: 'sim-3', title: 'Sim 3', albumId: 'disc-3', album: 'Disc 3'),
        ],
        'seed-2': const <Song>[
          Song(id: 'sim-4', title: 'Sim 4', albumId: 'disc-4', album: 'Disc 4'),
          Song(id: 'sim-5', title: 'Sim 5', albumId: 'disc-5', album: 'Disc 5'),
          Song(id: 'sim-6', title: 'Sim 6', albumId: 'disc-6', album: 'Disc 6'),
        ],
        'seed-3': const <Song>[
          Song(id: 'sim-7', title: 'Sim 7', albumId: 'disc-7', album: 'Disc 7'),
          Song(
            id: 'sim-14',
            title: 'Sim 14',
            albumId: 'disc-0',
            album: 'Disc 0',
          ),
        ],
        'seed-4': const <Song>[
          Song(id: 'sim-8', title: 'Sim 8', albumId: 'disc-8', album: 'Disc 8'),
          Song(id: 'sim-9', title: 'Sim 9', albumId: 'disc-9', album: 'Disc 9'),
          Song(
            id: 'sim-10',
            title: 'Sim 10',
            albumId: 'disc-10',
            album: 'Disc 10',
          ),
        ],
        'seed-5': const <Song>[
          Song(
            id: 'sim-11',
            title: 'Sim 11',
            albumId: 'disc-11',
            album: 'Disc 11',
          ),
          Song(
            id: 'sim-12',
            title: 'Sim 12',
            albumId: 'disc-6',
            album: 'Disc 6',
          ),
          Song(
            id: 'sim-13',
            title: 'Sim 13',
            albumId: 'disc-7',
            album: 'Disc 7',
          ),
        ],
      });

      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            subsonicApiProvider.overrideWithValue(fakeApi),
            homeRandomAlbumsProvider.overrideWith(
              (ref) async => throw StateError('discovery should be used first'),
            ),
            likedSongsProvider.overrideWithValue(
              const AsyncData(
                <SongsTableData>[
                  SongsTableData(
                    id: 'seed-1',
                    title: 'Seed 1',
                    albumId: 'liked-a',
                  ),
                  SongsTableData(
                    id: 'seed-2',
                    title: 'Seed 2',
                    albumId: 'liked-b',
                  ),
                  SongsTableData(
                    id: 'seed-3',
                    title: 'Seed 3',
                    albumId: 'liked-c',
                  ),
                  SongsTableData(
                    id: 'seed-4',
                    title: 'Seed 4',
                    albumId: 'liked-d',
                  ),
                  SongsTableData(
                    id: 'seed-5',
                    title: 'Seed 5',
                    albumId: 'liked-e',
                  ),
                ],
              ),
            ),
          ],
        ),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final result = await container.read(
        homeRandomShowcaseProvider((
          downloadedOnly: false,
          likedOnly: false,
        )).future,
      );

      expect(result.length, greaterThanOrEqualTo(6));
      expect(
        result.every(
          (album) =>
              album.album.source == HomeRandomShowcaseSource.likedDiscovery,
        ),
        isTrue,
      );
    },
  );

  test(
    'ListenBrainz updates do not rerun liked-song discovery',
    () async {
      final database = createTestDatabase();
      for (var i = 0; i < 12; i++) {
        await _insertAlbum(database, id: 'disc-$i', name: 'Discovery $i');
      }

      final fakeApi = _FakeDiscoveryApiClient({
        'seed-1': const <Song>[
          Song(id: 'sim-1', title: 'Sim 1', albumId: 'disc-1', album: 'Disc 1'),
          Song(id: 'sim-2', title: 'Sim 2', albumId: 'disc-2', album: 'Disc 2'),
        ],
        'seed-2': const <Song>[
          Song(id: 'sim-3', title: 'Sim 3', albumId: 'disc-3', album: 'Disc 3'),
          Song(id: 'sim-4', title: 'Sim 4', albumId: 'disc-4', album: 'Disc 4'),
        ],
        'seed-3': const <Song>[
          Song(id: 'sim-5', title: 'Sim 5', albumId: 'disc-5', album: 'Disc 5'),
          Song(id: 'sim-6', title: 'Sim 6', albumId: 'disc-6', album: 'Disc 6'),
        ],
        'seed-4': const <Song>[
          Song(id: 'sim-7', title: 'Sim 7', albumId: 'disc-7', album: 'Disc 7'),
          Song(id: 'sim-8', title: 'Sim 8', albumId: 'disc-8', album: 'Disc 8'),
        ],
        'seed-5': const <Song>[
          Song(id: 'sim-9', title: 'Sim 9', albumId: 'disc-9', album: 'Disc 9'),
          Song(
            id: 'sim-10',
            title: 'Sim 10',
            albumId: 'disc-10',
            album: 'Disc 10',
          ),
        ],
      });
      final recommendationCompleter = Completer<List<ListenBrainzPlaylist>>();
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            appSettingsProvider.overrideWithValue(
              AsyncData(
                const AppSettingsModel.defaults().copyWith(
                  listenBrainzScrobblingEnabled: true,
                  listenBrainzTokenValid: true,
                  listenBrainzUserName: 'alice',
                ),
              ),
            ),
            externalScrobbleCredentialStoreProvider.overrideWithValue(
              const _FakeExternalScrobbleCredentialStore('token'),
            ),
            listenBrainzApiClientProvider.overrideWithValue(
              _FakeListenBrainzApiClient(
                playlists: const <ListenBrainzPlaylist>[],
                recommendationCompleter: recommendationCompleter,
              ),
            ),
            subsonicApiProvider.overrideWithValue(fakeApi),
            homeRandomAlbumsProvider.overrideWith(
              (ref) async => throw StateError('discovery should be reused'),
            ),
            likedSongsProvider.overrideWithValue(
              const AsyncData(
                <SongsTableData>[
                  SongsTableData(
                    id: 'seed-1',
                    title: 'Seed 1',
                    albumId: 'liked-a',
                  ),
                  SongsTableData(
                    id: 'seed-2',
                    title: 'Seed 2',
                    albumId: 'liked-b',
                  ),
                  SongsTableData(
                    id: 'seed-3',
                    title: 'Seed 3',
                    albumId: 'liked-c',
                  ),
                  SongsTableData(
                    id: 'seed-4',
                    title: 'Seed 4',
                    albumId: 'liked-d',
                  ),
                  SongsTableData(
                    id: 'seed-5',
                    title: 'Seed 5',
                    albumId: 'liked-e',
                  ),
                ],
              ),
            ),
          ],
        ),
      );
      addTearDown(() async {
        if (!recommendationCompleter.isCompleted) {
          recommendationCompleter.complete(const <ListenBrainzPlaylist>[]);
        }
        container.dispose();
        await database.close();
      });

      const filters = (downloadedOnly: false, likedOnly: false);
      final firstResult = await container.read(
        homeRandomShowcaseProvider(filters).future,
      );
      final similarCallsAfterDiscovery = fakeApi.totalSimilarSongCalls;

      expect(firstResult.length, greaterThanOrEqualTo(6));
      expect(similarCallsAfterDiscovery, greaterThan(0));

      recommendationCompleter.complete(const <ListenBrainzPlaylist>[]);
      await container.read(listenBrainzDiscoverProvider.future);
      final secondResult = await container.read(
        homeRandomShowcaseProvider(filters).future,
      );

      expect(secondResult.length, greaterThanOrEqualTo(6));
      expect(fakeApi.totalSimilarSongCalls, similarCallsAfterDiscovery);
    },
  );

  test(
    'slow liked-song discovery falls back without waiting for completion',
    () async {
      final database = createTestDatabase();
      final similarGate = Completer<void>();
      final fakeApi = _FakeDiscoveryApiClient(
        {
          'seed-1': const <Song>[
            Song(
              id: 'sim-1',
              title: 'Sim 1',
              albumId: 'disc-1',
              album: 'Disc 1',
            ),
          ],
        },
        similarGate: similarGate,
      );
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            subsonicApiProvider.overrideWithValue(fakeApi),
            homeRandomAlbumsProvider.overrideWith(
              (ref) async => const <Album>[
                Album(id: 'srv-1', name: 'Server Album'),
              ],
            ),
            likedSongsProvider.overrideWithValue(
              const AsyncData(
                <SongsTableData>[
                  SongsTableData(
                    id: 'seed-1',
                    title: 'Seed 1',
                    albumId: 'liked-a',
                  ),
                  SongsTableData(
                    id: 'seed-2',
                    title: 'Seed 2',
                    albumId: 'liked-b',
                  ),
                  SongsTableData(
                    id: 'seed-3',
                    title: 'Seed 3',
                    albumId: 'liked-c',
                  ),
                  SongsTableData(
                    id: 'seed-4',
                    title: 'Seed 4',
                    albumId: 'liked-d',
                  ),
                  SongsTableData(
                    id: 'seed-5',
                    title: 'Seed 5',
                    albumId: 'liked-e',
                  ),
                ],
              ),
            ),
          ],
        ),
      );
      addTearDown(() async {
        if (!similarGate.isCompleted) {
          similarGate.complete();
        }
        container.dispose();
        await database.close();
      });

      final result = await container.read(
        homeRandomShowcaseProvider((
          downloadedOnly: false,
          likedOnly: false,
        )).future,
      );

      expect(fakeApi.totalSimilarSongCalls, 3);
      expect(result, hasLength(1));
      expect(result.first.album.id, 'srv-1');
      expect(result.first.album.source, HomeRandomShowcaseSource.serverRandom);
    },
  );

  test('offline falls back to local random pool', () async {
    final database = createTestDatabase();
    await _insertAlbum(database, id: 'loc-1', name: 'Local Album');

    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.offline),
          homeRandomAlbumsProvider.overrideWith(
            (ref) async => const <Album>[
              Album(id: 'srv-ignored', name: 'Ignored Server Album'),
            ],
          ),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    final result = await container.read(
      homeRandomShowcaseProvider((
        downloadedOnly: false,
        likedOnly: false,
      )).future,
    );

    expect(result, hasLength(1));
    expect(result.first.album.id, 'loc-1');
    expect(result.first.album.source, HomeRandomShowcaseSource.localFallback);
  });

  test('liked-only tops up albums from liked songs when needed', () async {
    final database = createTestDatabase();
    await _insertAlbum(
      database,
      id: 'liked-explicit',
      name: 'Explicitly Liked Album',
      starred: DateTime(2026, 1, 1),
    );
    await _insertAlbum(
      database,
      id: 'liked-song-album',
      name: 'Song-Liked Album',
    );

    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          likedSongsProvider.overrideWithValue(
            AsyncData(
              <SongsTableData>[
                SongsTableData(
                  id: 'liked-song-1',
                  title: 'Liked Song',
                  albumId: 'liked-song-album',
                  starred: DateTime(2026, 1, 2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    final result = await container.read(
      homeRandomShowcaseProvider((
        downloadedOnly: false,
        likedOnly: true,
      )).future,
    );

    final ids = result.map((album) => album.album.id).toSet();
    expect(ids, contains('liked-explicit'));
    expect(ids, contains('liked-song-album'));
    expect(
      result.every(
        (album) => album.album.source == HomeRandomShowcaseSource.localFallback,
      ),
      isTrue,
    );
  });

  test(
    'downloaded-only filters local random pool to downloaded albums',
    () async {
      final database = createTestDatabase();
      await _insertAlbum(database, id: 'album-a', name: 'Album A');
      await _insertAlbum(database, id: 'album-b', name: 'Album B');

      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.offline),
            downloadedContentIdsProvider.overrideWithValue(
              const AsyncData((
                albumIds: <String>{'album-b'},
                artistIds: <String>{},
              )),
            ),
          ],
        ),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final result = await container.read(
        homeRandomShowcaseProvider((
          downloadedOnly: true,
          likedOnly: false,
        )).future,
      );

      expect(result, hasLength(1));
      expect(result.first.album.id, 'album-b');
    },
  );

  test(
    'downloaded + liked only keeps downloaded liked-song album candidates',
    () async {
      final database = createTestDatabase();
      await _insertAlbum(database, id: 'album-a', name: 'Album A');
      await _insertAlbum(database, id: 'album-b', name: 'Album B');

      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: <Override>[
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            downloadedContentIdsProvider.overrideWithValue(
              const AsyncData((
                albumIds: <String>{'album-a'},
                artistIds: <String>{},
              )),
            ),
            downloadedSongIdsProvider.overrideWithValue(
              const AsyncData(<String>{'song-a'}),
            ),
            likedSongsProvider.overrideWithValue(
              AsyncData(
                <SongsTableData>[
                  SongsTableData(
                    id: 'song-a',
                    title: 'Downloaded liked song',
                    albumId: 'album-a',
                    starred: DateTime(2026, 1, 2),
                  ),
                  SongsTableData(
                    id: 'song-b',
                    title: 'Non-downloaded liked song',
                    albumId: 'album-b',
                    starred: DateTime(2026, 1, 3),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final result = await container.read(
        homeRandomShowcaseProvider((
          downloadedOnly: true,
          likedOnly: true,
        )).future,
      );

      expect(result, hasLength(1));
      expect(result.first.album.id, 'album-a');
      expect(result.first.album.source, HomeRandomShowcaseSource.localFallback);
    },
  );
}
