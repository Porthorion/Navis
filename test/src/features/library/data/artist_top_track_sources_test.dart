import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/features/integrations/data/deezer_artist_resolver.dart';
import 'package:navis/src/features/integrations/data/deezer_cache.dart';
import 'package:navis/src/features/integrations/data/integration_json_cache.dart';
import 'package:navis/src/features/library/data/artist_top_track_sources.dart';
import 'package:navis/src/features/library/domain/artist_top_track.dart';

class _FakeDeezer extends DeezerApiClient {
  new() : super(dio: Dio());

  List<DeezerArtist> artists = const [DeezerArtist(id: 9, name: 'Artist')];
  List<DeezerTrack> top = const [];
  List<DeezerTrack> search = const [];
  Exception? error;
  int topCalls = 0;
  int searchCalls = 0;
  String? searchQuery;
  int? searchLimit;

  @override
  Future<List<DeezerArtist>> searchArtists(
    String name, {
    int limit = 25,
    CancelToken? cancelToken,
  }) async {
    if (error case final error?) throw error;
    return artists;
  }

  @override
  Future<List<DeezerTrack>> getArtistTopTracks(
    int artistId, {
    int limit = 50,
    CancelToken? cancelToken,
  }) async {
    topCalls++;
    return top;
  }

  @override
  Future<List<DeezerTrack>> searchTracks(
    String query, {
    int limit = 100,
    CancelToken? cancelToken,
  }) async {
    searchCalls++;
    searchQuery = query;
    searchLimit = limit;
    return search;
  }
}

class _FakeLastFm extends LastFmApiClient {
  new() : super(apiKey: 'fake');

  int calls = 0;
  List<LastFmArtistTopTrack> tracks = const [
    LastFmArtistTopTrack(
      rank: 1,
      title: 'From Last.fm',
      artist: 'Artist',
      listeners: 1200,
    ),
  ];

  @override
  Future<List<LastFmArtistTopTrack>> getArtistTopTracks({
    required String artist,
    int limit = 10,
  }) async {
    calls++;
    return tracks;
  }
}

DeezerTrack _track(
  int id,
  String title, {
  int artistId = 9,
  int rank = 0,
  String artist = 'Artist',
}) => DeezerTrack(
  id: id,
  title: title,
  rank: rank,
  durationSeconds: 200,
  artist: DeezerArtist(id: artistId, name: artist),
  album: const DeezerAlbum(id: 1, title: 'Album'),
);

void main() {
  late Directory root;
  late IntegrationJsonCache cache;
  late _FakeDeezer deezer;
  late _FakeLastFm lastFm;
  late ArtistTopTrackSources sources;

  setUp(() {
    root = Directory.systemTemp.createTempSync('artist_top_track_sources_');
    cache = IntegrationJsonCache(readRootDirectory: () async => root);
    deezer = _FakeDeezer();
    lastFm = _FakeLastFm();
    sources = ArtistTopTrackSources(
      cache: cache,
      deezer: deezer,
      deezerArtists: DeezerArtistResolver(client: deezer, cache: cache),
      lastFm: lastFm,
    );
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<ArtistTopTrackSeedsLoad> load({
    bool deezerAllowed = true,
    bool lastFmAllowed = true,
  }) => sources.load(
    artistId: 'artist-1',
    artistName: 'Artist',
    deezerAllowed: deezerAllowed,
    lastFmAllowed: lastFmAllowed,
  );

  test('Deezer top tracks come first, without listener counts', () async {
    deezer.top = [_track(1, 'Hit', rank: 900), _track(2, 'Second', rank: 800)];

    final result = await load(lastFmAllowed: false);

    expect(result.seeds.map((seed) => seed.title), ['Hit', 'Second']);
    expect(result.seeds.map((seed) => seed.rank), [1, 2]);
    final first = result.seeds.first;
    expect(first.source, ArtistTopTrackSource.deezer);
    expect(first.listeners, isNull);
    expect(first.popularity, 900);
    expect(first.deezerTrackId, 1);
    expect(first.album, 'Album');
    expect(first.durationSeconds, 200);
    // Fewer than 50: the search was asked to fill, and had nothing.
    expect(deezer.searchCalls, 1);
    expect(lastFm.calls, 0);
  });

  test(
    'an empty top list falls back to track search, filtered and ranked',
    () async {
      deezer.search = [
        _track(1, 'Wonder', rank: 500),
        _track(2, 'Cover of Wonder', artistId: 77, rank: 999),
        _track(3, 'Wonder (Japanese Version)', rank: 300),
        _track(4, 'Wonder (Remastered 2011)', rank: 200),
        _track(5, 'Big Hit', rank: 800),
      ];

      final result = await load(lastFmAllowed: false);

      expect(deezer.topCalls, 1);
      expect(deezer.searchQuery, 'Artist');
      expect(deezer.searchLimit, 100);
      expect(result.seeds.map((seed) => seed.title), [
        'Big Hit',
        'Wonder',
        'Wonder (Japanese Version)',
      ]);
    },
  );

  test('rankDeezerArtistTracks keeps at most one track per edition', () {
    final ranked = rankDeezerArtistTracks([
      _track(1, 'Song', rank: 10),
      _track(2, 'Song', rank: 20),
      _track(3, 'Song (Live)', rank: 5),
    ], deezerArtistId: 9);

    expect(ranked.map((track) => track.id), [2, 3]);
  });

  test('Deezer results are cached for the next load', () async {
    deezer
      ..top = [_track(1, 'Hit', rank: 900)]
      ..search = [_track(2, 'Filler', rank: 10)];

    expect((await load(lastFmAllowed: false)).cacheHit, isFalse);
    final second = await load(lastFmAllowed: false);

    expect(second.cacheHit, isTrue);
    expect(second.seeds.map((seed) => seed.title), ['Hit', 'Filler']);
    expect((second.fromTop, second.fromSearch), (1, 1));
    expect(deezer.topCalls, 1);
    expect(deezer.searchCalls, 1);
  });

  List<DeezerTrack> numbered(int from, int to, {int rankBase = 1000}) => [
    for (var i = from; i <= to; i++) _track(i, 'Song $i', rank: rankBase - i),
  ];

  test('a one-song top list is filled from the track search', () async {
    deezer
      ..top = [_track(1, 'eScape', rank: 5000)]
      ..search = [
        _track(1, 'eScape', rank: 5000),
        _track(99, 'Cover', artistId: 77, rank: 9999),
        ...numbered(2, 15),
      ];

    final result = await load();

    expect(result.seeds.first.title, 'eScape');
    expect(result.seeds, hasLength(15));
    expect(result.seeds.map((seed) => seed.rank), [
      for (var i = 1; i <= 15; i++) i,
    ]);
    expect(result.seeds.where((seed) => seed.title == 'eScape'), hasLength(1));
    expect(result.seeds.any((seed) => seed.title == 'Cover'), isFalse);
    expect((result.fromTop, result.fromSearch, result.fromLastFm), (1, 14, 0));
    // Ten or more from Deezer: Last.fm is not asked.
    expect(lastFm.calls, 0);
  });

  test('a nine-song top list is filled without repeating its songs', () async {
    deezer
      ..top = numbered(1, 9)
      ..search = [...numbered(5, 20), _track(50, 'Song 3 (Remastered)')];

    final result = await load();

    expect(result.seeds.map((seed) => seed.title), [
      for (var i = 1; i <= 20; i++) 'Song $i',
    ]);
    expect((result.fromTop, result.fromSearch), (9, 11));
    expect(lastFm.calls, 0);
  });

  test('top and search together stop at 50 songs', () async {
    deezer
      ..top = numbered(1, 45)
      ..search = numbered(46, 80);

    final result = await load();

    expect(result.seeds, hasLength(kArtistTopTrackSeedMax));
    expect((result.fromTop, result.fromSearch), (45, 5));
  });

  test('a full top list skips the search', () async {
    deezer.top = numbered(1, 50);

    await load();

    expect(deezer.searchCalls, 0);
  });

  test(
    'fewer than ten Deezer songs get Last.fm songs appended, once each',
    () async {
      deezer.top = [
        _track(1, 'Hit', rank: 900),
        _track(2, 'Second', rank: 800),
      ];
      lastFm.tracks = const [
        LastFmArtistTopTrack(rank: 1, title: 'HIT', artist: 'Artist'),
        LastFmArtistTopTrack(
          rank: 2,
          title: 'Other',
          artist: 'Artist',
          listeners: 500,
        ),
        LastFmArtistTopTrack(rank: 3, title: 'Second (Live)', artist: 'Artist'),
      ];

      final result = await load();

      expect(result.seeds.map((seed) => seed.title), [
        'Hit',
        'Second',
        'Other',
        'Second (Live)',
      ]);
      expect(result.seeds.map((seed) => seed.rank), [1, 2, 3, 4]);
      expect(result.seeds.map((seed) => seed.source), [
        ArtistTopTrackSource.deezer,
        ArtistTopTrackSource.deezer,
        ArtistTopTrackSource.lastFm,
        ArtistTopTrackSource.lastFm,
      ]);
      // A mixed list shows no listener counts.
      expect(result.seeds.every((seed) => seed.listeners == null), isTrue);
      expect((result.fromTop, result.fromSearch, result.fromLastFm), (2, 0, 2));
    },
  );

  test('Last.fm switched off is not asked to fill a short list', () async {
    deezer.top = [_track(1, 'Hit', rank: 900)];

    final result = await load(lastFmAllowed: false);

    expect(result.seeds.single.title, 'Hit');
    expect(lastFm.calls, 0);
  });

  test('a cache entry from before the search fill is fetched again', () async {
    deezer.top = [_track(1, 'Hit', rank: 900)];
    await cache.write(DeezerCache.artistTopTracksNamespace, '9', [
      _track(1, 'Hit', rank: 900).toJson(),
    ], ttl: const Duration(hours: 24));

    final result = await load(lastFmAllowed: false);

    expect(result.cacheHit, isFalse);
    expect(deezer.topCalls, 1);
  });

  test('Deezer with nothing for the artist hands over to Last.fm', () async {
    final result = await load();

    expect(deezer.searchCalls, 1);
    expect(result.seeds.single.title, 'From Last.fm');
    expect(result.seeds.single.source, ArtistTopTrackSource.lastFm);
    expect(result.seeds.single.listeners, 1200);
  });

  test('an artist not on Deezer hands over to Last.fm', () async {
    deezer.artists = const [DeezerArtist(id: 3, name: 'Somebody Else')];

    final result = await load();

    expect(deezer.topCalls, 0);
    expect(result.seeds.single.source, ArtistTopTrackSource.lastFm);
  });

  test('a Deezer failure hands over to Last.fm', () async {
    deezer.error = const DeezerApiException(code: 4);

    final result = await load();

    expect(result.seeds.single.source, ArtistTopTrackSource.lastFm);
  });

  test('Deezer switched off goes straight to Last.fm', () async {
    deezer.top = [_track(1, 'Hit', rank: 900)];

    final result = await load(deezerAllowed: false);

    expect(deezer.topCalls, 0);
    expect(result.seeds.single.source, ArtistTopTrackSource.lastFm);
  });

  test('Last.fm results are cached for the next load', () async {
    await load(deezerAllowed: false);
    final second = await load(deezerAllowed: false);

    expect(second.cacheHit, isTrue);
    expect(second.seeds.single.listeners, 1200);
    expect(lastFm.calls, 1);
  });

  test('no allowed source gives no songs and sends nothing', () async {
    deezer.top = [_track(1, 'Hit', rank: 900)];

    final result = await load(deezerAllowed: false, lastFmAllowed: false);

    expect(result.seeds, isEmpty);
    expect(deezer.topCalls, 0);
    expect(lastFm.calls, 0);
  });

  test('Last.fm switched off leaves an empty Deezer result empty', () async {
    final result = await load(lastFmAllowed: false);

    expect(result.seeds, isEmpty);
    expect(lastFm.calls, 0);
  });
}
