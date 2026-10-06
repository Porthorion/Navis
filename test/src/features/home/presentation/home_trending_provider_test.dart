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
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
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
  new({this.results = const <String, List<Song>>{}})
    : super(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'user',
          password: 'pass',
          apiVersion: '1.16.1',
        ),
        enableLogging: false,
      );

  final Map<String, List<Song>> results;
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
    return SearchResult3(songs: results[query] ?? const <Song>[]);
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

class _MutableLibrarySyncController extends LibrarySyncController {
  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  set value(LibrarySyncState next) => state = next;
}

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
    _MutableLibrarySyncController? sync,
  }) {
    final root = cacheRoot;
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          integrationPolicyProvider.overrideWithValue(policy),
          integrationAccountScopeProvider.overrideWithValue('fixture-account'),
          integrationJsonCacheProvider.overrideWithValue(
            IntegrationJsonCache(readRootDirectory: () async => root),
          ),
          deezerApiClientProvider.overrideWithValue(deezer),
          subsonicApiProvider.overrideWithValue(api),
          homeDeezerStartupDelayProvider.overrideWithValue(Duration.zero),
          homeDeezerSyncRunningProvider.overrideWithValue(false),
          librarySyncControllerProvider.overrideWith(
            () => sync ?? _MutableLibrarySyncController(),
          ),
          if (recorder != null)
            integrationCallRecorderProvider.overrideWithValue(recorder),
        ],
      ),
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Every emission of Trending until one has no song still matching.
  Future<List<List<ResolvedArtistTopTrack>>> emissions(
    ProviderContainer container,
  ) async {
    final all = <List<ResolvedArtistTopTrack>>[];
    final done = Completer<void>();
    // Riverpod pauses providers nobody listens to.
    final subscription = container.listen(homeTrendingProvider, (_, next) {
      if (next case AsyncData(:final value)) {
        all.add(value);
        if (!value.any((track) => track.isMatching) && !done.isCompleted) {
          done.complete();
        }
      }
    }, fireImmediately: true);
    addTearDown(subscription.close);
    await done.future.timeout(const Duration(seconds: 5));
    await container.read(trendingMatchStoreProvider).whenSaved();
    return all;
  }

  Future<List<ResolvedArtistTopTrack>> read(
    ProviderContainer container,
  ) async => (await emissions(container)).last;

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

  test('keeps every chart song in chart order, matched or not', () async {
    await library(<String>[_t(1), _t(3)]);
    final deezer = _FakeDeezer(<DeezerTrack>[
      _chartTrack(1, _t(1), 'Known'),
      _chartTrack(2, 'Hit', 'Stranger'),
      _chartTrack(3, _t(3), 'Known'),
      _chartTrack(4, 'Gone', 'Known'),
      _chartTrack(5, 'Copy', 'Stranger'),
    ]);
    final api = _FakeSubsonic(
      results: <String, List<Song>>{
        // A song by an artist the library does not have: searched too.
        'Hit Stranger': <Song>[
          const Song(
            id: 'ext-deezer-song-2',
            title: 'Hit',
            artist: 'Stranger',
            isExternal: true,
          ),
        ],
        // A copy on the server wins over the remote one.
        'Copy Stranger': <Song>[
          const Song(
            id: 'ext-deezer-song-5',
            title: 'Copy',
            artist: 'Stranger',
            isExternal: true,
          ),
          const Song(id: 'server-copy', title: 'Copy', artist: 'Stranger'),
        ],
      },
    );
    final recorder = IntegrationCallRecorder();

    final all = await emissions(
      container(deezer: deezer, api: api, recorder: recorder),
    );

    // The rows show at once, the searched ones still matching.
    expect(all.first.map((track) => track.isMatching), <bool>[
      false,
      true,
      false,
      true,
      true,
    ]);
    final tracks = all.last;
    expect(tracks.map((track) => track.rank), <int>[1, 2, 3, 4, 5]);
    expect(tracks.map((track) => track.resolvedSong?.id), <String?>[
      'lib-Alpha',
      'ext-deezer-song-2',
      'lib-Charlie',
      null,
      'server-copy',
    ]);
    expect(tracks[3].title, 'Gone');
    expect(api.queries.toSet(), <String>{
      'Hit Stranger',
      'Gone Known',
      'Copy Stranger',
    });
    // The server copy is stored for the next library pass.
    expect(await database.libraryDao.getSongById('server-copy'), isNotNull);
    final span = recorder.recentSpans().lastWhere(
      (span) => span.name == kHomeTrendingSpan,
    );
    expect(span.counts, <String, int>{
      'chart': 5,
      'playable': 4,
      'remote': 1,
      'manual': 0,
    });
    expect(
      recorder.recentSpans().map((span) => span.name),
      containsAll(<String>['trending.localMatch', 'trending.serverMatch']),
    );
  });

  test('shows the chart while nothing is matched yet', () async {
    await library(<String>[_t(12)]);
    final deezer = _FakeDeezer(<DeezerTrack>[
      _chartTrack(1, _t(1), 'Known'),
      _chartTrack(2, _t(2), 'Known'),
    ]);
    final all = await emissions(
      container(deezer: deezer, api: _FakeSubsonic()),
    );
    expect(all, hasLength(2));
    expect(all.first.every((track) => track.isMatching), isTrue);
    expect(all.last.every((track) => track.resolvedSong == null), isTrue);
  });

  test('searches two at a time and stops when invalidated', () async {
    await library(<String>[_t(1)]);
    final deezer = _FakeDeezer(<DeezerTrack>[
      _chartTrack(1, _t(1), 'Known'),
      for (var i = 2; i <= 9; i++) _chartTrack(i, _t(i), 'Known'),
    ]);
    final api = _FakeSubsonic()..gate = Completer<void>();
    final c = container(deezer: deezer, api: api);
    final subscription = c.listen(homeTrendingProvider, (_, _) {});
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

  test(
    'a pull to refresh searches six at a time and unmatched songs again',
    () async {
      await library(<String>[_t(1)]);
      final deezer = _FakeDeezer(<DeezerTrack>[
        for (var i = 1; i <= 12; i++) _chartTrack(i, _t(i), 'Known'),
      ]);
      final api = _FakeSubsonic();
      final c = container(deezer: deezer, api: api);
      final first = await emissions(c);
      expect(first.last.where((t) => t.resolvedSong == null), hasLength(11));
      expect(api.queries, hasLength(11));
      expect(api.maxActive, lessThanOrEqualTo(2));

      api
        ..maxActive = 0
        ..gate = Completer<void>();
      final updates = <List<ResolvedArtistTopTrack>>[];
      c.listen(homeTrendingProvider, (_, next) {
        if (next case AsyncData(:final value)) updates.add(value);
      });
      c.read(homeTrendingRefreshProvider.notifier).refresh(manual: true);
      for (var i = 0; i < 50 && api.queries.length < 17; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(api.maxActive, 6);
      api.gate!.complete();
      for (var i = 0; i < 100 && api.queries.length < 22; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // All eleven unmatched songs were searched again, and the rows moved
      // on in batches before the end.
      expect(api.queries, hasLength(22));
      expect(updates.length, greaterThanOrEqualTo(3));
      expect(updates.last.any((track) => track.isMatching), isFalse);

      // The manual mode was for that refresh only: a rebuild for another
      // reason (here an invalidation) is automatic again, so the unmatched
      // songs, checked minutes ago, are not searched.
      c.invalidate(homeTrendingProvider);
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(api.queries, hasLength(22));
    },
  );

  test(
    'a library sync matches again locally without searching again',
    () async {
      await library(<String>[_t(1)]);
      final deezer = _FakeDeezer(<DeezerTrack>[
        _chartTrack(1, _t(1), 'Known'),
        _chartTrack(2, _t(2), 'Known'),
        _chartTrack(3, 'Hit', 'Stranger'),
      ]);
      final api = _FakeSubsonic(
        results: <String, List<Song>>{
          'Hit Stranger': <Song>[
            const Song(
              id: 'ext-deezer-song-3',
              title: 'Hit',
              artist: 'Stranger',
              isExternal: true,
            ),
          ],
        },
      );
      final sync = _MutableLibrarySyncController();
      final c = container(deezer: deezer, api: api, sync: sync);
      final first = await emissions(c);
      expect(first.last[1].resolvedSong, isNull);
      expect(api.queries, hasLength(2));

      // The sync brings the second song.
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(
          id: 'lib-${_t(2)}',
          title: _t(2),
          artistId: const Value('known'),
          artistName: const Value('Known'),
          duration: const Value(200),
        ),
      ]);
      final updates = <List<ResolvedArtistTopTrack>>[];
      c.listen(homeTrendingProvider, (_, next) {
        if (next case AsyncData(:final value)) updates.add(value);
      });
      sync.value = const LibrarySyncState(
        status: LibrarySyncStatus.running,
        stage: LibrarySyncStage.idle,
      );
      sync.value = const LibrarySyncState(
        status: LibrarySyncStatus.succeeded,
        stage: LibrarySyncStage.idle,
      );
      for (var i = 0; i < 100 && updates.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(updates.last.map((track) => track.resolvedSong?.id), <String?>[
        'lib-Alpha',
        'lib-Bravo',
        'ext-deezer-song-3',
      ]);
      expect(api.queries, hasLength(2));
    },
  );

  test('joins the hero after the weekly playlists, never filtered', () async {
    final tracks = <ResolvedArtistTopTrack>[
      for (var i = 1; i <= 8; i++)
        ResolvedArtistTopTrack(
          rank: i,
          title: 'T$i',
          artist: 'Known',
          resolvedSong: Song(id: 's$i', title: 'T$i', coverArt: 'c$i'),
        ),
      const ResolvedArtistTopTrack(rank: 9, title: 'T9', artist: 'Other'),
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
          homeTrendingProvider.overrideWith((ref) {
            trendingReads++;
            return Stream.value(tracks);
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
    expect(trending.tracks, hasLength(9));
    expect(trending.songs, hasLength(8));

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

  test('the hero needs eight playable chart songs, matched rows count', () {
    List<ResolvedArtistTopTrack> chart(
      int playable,
    ) => <ResolvedArtistTopTrack>[
      for (var i = 1; i <= 20; i++)
        ResolvedArtistTopTrack(
          rank: i,
          title: 'T$i',
          artist: 'A',
          resolvedSong: i <= playable ? Song(id: 's$i', title: 'T$i') : null,
        ),
    ];
    expect(HomeRandomShowcaseTrending.forHero(chart(7)), isNull);
    final item = HomeRandomShowcaseTrending.forHero(chart(8));
    expect(item?.tracks, hasLength(20));
    expect(item?.entries.map((entry) => entry.rank), <int>[
      for (var i = 1; i <= 8; i++) i,
    ]);
  });
}
