import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/api/models/listenbrainz_playlist.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/features/home/presentation/home_deezer_providers.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/integrations/data/integration_call_recorder.dart';
import 'package:navis/src/features/integrations/data/integration_json_cache.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/library/domain/artist_top_track.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:riverpod/src/framework.dart' show Override;

import '../../../../helpers/test_database.dart';

/// Serves a fixed chart and records the requests.
class _FakeDeezer extends DeezerApiClient {
  new(this.chart) : super(dio: Dio());

  final List<DeezerTrack> chart;
  int chartCalls = 0;

  @override
  Future<List<DeezerTrack>> getChartTracks({
    int limit = 100,
    CancelToken? cancelToken,
  }) async {
    chartCalls++;
    return chart;
  }
}

/// Answers `search3` for "<title> <artist>" from [results], optionally
/// holding every search at [gate], and tracks concurrency and tokens.
class _FakeSubsonic extends SubsonicApiClient {
  new({this.results = const <String, Song>{}})
    : super(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'user',
          password: 'pass',
          apiVersion: '1.16.1',
        ),
        enableLogging: false,
      );

  final Map<String, Song> results;
  Completer<void>? gate;
  final List<String> queries = <String>[];
  final List<CancelToken?> tokens = <CancelToken?>[];
  int active = 0;
  int maxActive = 0;

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
    queries.add(query);
    tokens.add(cancelToken);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      await (gate?.future ?? Future<void>.delayed(Duration.zero));
    } finally {
      active--;
    }
    final song = results[query];
    return SearchResult3(songs: <Song>[?song]);
  }
}

/// Distinct song titles, so no title contains another.
const _titles = <String>[
  'Alpha',
  'Bravo',
  'Charlie',
  'Delta',
  'Echo',
  'Foxtrot',
  'Golf',
  'Hotel',
  'India',
  'Juliet',
  'Kilo',
  'Lima',
];

String _t(int position) => _titles[position - 1];

DeezerTrack _chartTrack(int id, String title, String artist) => DeezerTrack(
  id: id,
  title: title,
  durationSeconds: 200,
  artist: DeezerArtist(id: artist.hashCode, name: artist),
);

void main() {
  late Directory cacheRoot;
  late NavisDatabase database;

  setUp(() {
    cacheRoot = Directory.systemTemp.createTempSync('home_trending_test_');
    database = createTestDatabase();
  });

  tearDown(() async {
    await database.close();
    if (cacheRoot.existsSync()) cacheRoot.deleteSync(recursive: true);
  });

  /// The library artist "Known" and its songs [titles].
  Future<void> library(List<String> titles) async {
    await database
        .into(database.artistsTable)
        .insert(ArtistsTableCompanion.insert(id: 'known', name: 'Known'));
    await database.libraryDao.upsertSongs(<SongsTableCompanion>[
      for (final title in titles)
        SongsTableCompanion.insert(
          id: 'lib-$title',
          title: title,
          artistId: const Value('known'),
          artistName: const Value('Known'),
          duration: const Value(200),
          coverArt: Value('cover-$title'),
        ),
    ]);
  }

  ProviderContainer container({
    required _FakeDeezer deezer,
    _FakeSubsonic? api,
    IntegrationPolicy policy = const IntegrationPolicy(),
    IntegrationCallRecorder? recorder,
  }) {
    final root = cacheRoot;
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          integrationPolicyProvider.overrideWithValue(policy),
          integrationJsonCacheProvider.overrideWithValue(
            IntegrationJsonCache(readRootDirectory: () async => root),
          ),
          deezerApiClientProvider.overrideWithValue(deezer),
          subsonicApiProvider.overrideWithValue(api),
          homeDeezerStartupDelayProvider.overrideWithValue(Duration.zero),
          homeDeezerSyncRunningProvider.overrideWithValue(false),
          if (recorder != null)
            integrationCallRecorderProvider.overrideWithValue(recorder),
        ],
      ),
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<List<ResolvedArtistTopTrack>> read(ProviderContainer container) {
    // Riverpod pauses providers nobody listens to.
    final subscription = container.listen(homeTrendingProvider, (_, _) {});
    addTearDown(subscription.close);
    return container.read(homeTrendingProvider.future);
  }

  test('asks Deezer nothing while the switch is off', () async {
    await library(<String>['A']);
    final deezer = _FakeDeezer(const <DeezerTrack>[]);
    for (final policy in <IntegrationPolicy>[
      const IntegrationPolicy(disabledKeys: <String>{'deezer.trending'}),
      const IntegrationPolicy(disabledKeys: <String>{'deezer'}),
      const IntegrationPolicy(masterEnabled: false),
      const IntegrationPolicy.denyAll(),
    ]) {
      expect(await read(container(deezer: deezer, policy: policy)), isEmpty);
    }
    expect(deezer.chartCalls, 0);
  });

  test('asks Deezer nothing for an empty library', () async {
    final deezer = _FakeDeezer(const <DeezerTrack>[]);
    expect(await read(container(deezer: deezer)), isEmpty);
    expect(deezer.chartCalls, 0);
  });

  test('keeps the playable chart songs, ranked by chart position', () async {
    await library(<String>[_t(1), for (var i = 3; i <= 9; i++) _t(i)]);
    final deezer = _FakeDeezer(<DeezerTrack>[
      _chartTrack(1, _t(1), 'Known'),
      _chartTrack(2, 'Hit', 'Stranger'),
      for (var i = 3; i <= 9; i++) _chartTrack(i, _t(i), 'Known'),
      _chartTrack(10, _t(10), 'Known'),
      _chartTrack(11, 'Gone', 'Known'),
    ]);
    final api = _FakeSubsonic(
      results: <String, Song>{
        '${_t(10)} Known': Song(
          id: 'ext-deezer-song-10',
          title: _t(10),
          artist: 'Known',
          isExternal: true,
        ),
      },
    );
    final recorder = IntegrationCallRecorder();

    final tracks = await read(
      container(deezer: deezer, api: api, recorder: recorder),
    );

    expect(tracks.map((track) => track.rank), <int>[
      1,
      3,
      4,
      5,
      6,
      7,
      8,
      9,
      10,
    ]);
    expect(tracks.first.resolvedSong?.id, 'lib-Alpha');
    expect(tracks.last.resolvedSong?.id, 'ext-deezer-song-10');
    // Only songs by library artists that the library lacks are searched.
    expect(api.queries.toSet(), <String>{'Juliet Known', 'Gone Known'});
    final span = recorder.recentSpans().lastWhere(
      (span) => span.name == kHomeTrendingSpan,
    );
    expect(span.counts, <String, int>{
      'chart': 11,
      'byLibraryArtists': 10,
      'playable': 9,
    });
    expect(
      recorder.recentSpans().map((span) => span.name),
      containsAll(<String>['trending.localMatch', 'trending.serverMatch']),
    );
  });

  test('fewer than eight playable songs leave Trending out', () async {
    await library(<String>[for (var i = 1; i <= 7; i++) _t(i)]);
    final deezer = _FakeDeezer(<DeezerTrack>[
      for (var i = 1; i <= 7; i++) _chartTrack(i, _t(i), 'Known'),
      _chartTrack(8, 'Missing', 'Known'),
    ]);
    expect(
      await read(container(deezer: deezer, api: _FakeSubsonic())),
      isEmpty,
    );
  });

  test('searches two at a time and stops when Home leaves', () async {
    await library(<String>[_t(1)]);
    final deezer = _FakeDeezer(<DeezerTrack>[
      _chartTrack(1, _t(1), 'Known'),
      for (var i = 2; i <= 9; i++) _chartTrack(i, _t(i), 'Known'),
    ]);
    final api = _FakeSubsonic()..gate = Completer<void>();
    final c = container(deezer: deezer, api: api);
    final subscription = c.listen(homeTrendingProvider, (_, _) {});
    unawaited(
      c.read(homeTrendingProvider.future).then<void>((_) {}, onError: (_) {}),
    );
    for (var i = 0; i < 50 && api.queries.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(api.queries, hasLength(2));
    expect(api.maxActive, 2);

    subscription.close();
    c.invalidate(homeTrendingProvider);
    await Future<void>.delayed(Duration.zero);
    expect(api.tokens.every((token) => token?.isCancelled ?? false), isTrue);
    api.gate!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(api.queries, hasLength(2));
  });

  test('joins the hero after the weekly playlists, never filtered', () async {
    final tracks = <ResolvedArtistTopTrack>[
      for (var i = 1; i <= 8; i++)
        ResolvedArtistTopTrack(
          rank: i,
          title: 'T$i',
          artist: 'Known',
          resolvedSong: Song(id: 's$i', title: 'T$i', coverArt: 'c$i'),
        ),
    ];
    var trendingReads = 0;
    final c = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          listenBrainzDiscoverStreamProvider.overrideWith(
            (ref) => Stream.value(const <ListenBrainzDiscoverPlaylist>[
              ListenBrainzDiscoverPlaylist(
                playlist: ListenBrainzPlaylist(
                  identifier: 'jams',
                  title: 'Weekly Jams',
                  sourcePatch: 'weekly-jams',
                  tracks: <ListenBrainzPlaylistTrack>[],
                ),
                recommendations: <ListenBrainzResolvedRecommendation>[],
                matchingComplete: true,
              ),
            ]),
          ),
          homeRandomAlbumShowcaseProvider.overrideWith(
            (ref, filters) async => const <HomeRandomShowcaseAlbum>[
              HomeRandomShowcaseAlbum(
                id: 'a',
                name: 'Album',
                source: HomeRandomShowcaseSource.serverRandom,
              ),
            ],
          ),
          homeTrendingProvider.overrideWith((ref) async {
            trendingReads++;
            return tracks;
          }),
        ],
      ),
    );
    addTearDown(c.dispose);
    const all = (downloadedOnly: false, likedOnly: false);
    final subscription = c.listen(homeRandomShowcaseProvider(all), (_, _) {});
    addTearDown(subscription.close);
    await c.read(homeTrendingProvider.future);
    await c.read(listenBrainzDiscoverStreamProvider.future);
    await c.read(homeRandomAlbumShowcaseProvider(all).future);
    final items = c.read(homeRandomShowcaseProvider(all)).requireValue;
    expect(items.map((item) => item.stableId), <String>[
      'listenbrainz:weekly-jams',
      'trending:deezer',
      'album:a',
    ]);
    final trending = items[1] as HomeRandomShowcaseTrending;
    expect(trending.coverArtIds.take(2), <String>['c1', 'c2']);

    for (final filters in <({bool downloadedOnly, bool likedOnly})>[
      (downloadedOnly: true, likedOnly: false),
      (downloadedOnly: false, likedOnly: true),
    ]) {
      final filtered = c.listen(homeRandomShowcaseProvider(filters), (_, _) {});
      addTearDown(filtered.close);
      await c.read(homeRandomAlbumShowcaseProvider(filters).future);
      expect(
        c
            .read(homeRandomShowcaseProvider(filters))
            .requireValue
            .whereType<HomeRandomShowcaseTrending>(),
        isEmpty,
      );
    }
    expect(trendingReads, 1);
  });
}
