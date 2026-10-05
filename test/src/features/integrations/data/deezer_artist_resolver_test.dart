import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/features/integrations/data/deezer_artist_resolver.dart';
import 'package:navis/src/features/integrations/data/deezer_cache.dart';
import 'package:navis/src/features/integrations/data/integration_json_cache.dart';

class _FakeDeezer extends DeezerApiClient {
  new() : super(dio: Dio());

  List<DeezerArtist> artists = const [];
  Map<int, List<DeezerAlbum>> albumsByArtist = const {};
  Exception? searchError;
  int searchCalls = 0;
  final List<int> albumCalls = <int>[];

  @override
  Future<List<DeezerArtist>> searchArtists(
    String name, {
    int limit = 25,
    CancelToken? cancelToken,
  }) async {
    searchCalls++;
    if (searchError case final error?) throw error;
    return artists;
  }

  @override
  Future<List<DeezerAlbum>> getArtistAlbums(
    int artistId, {
    int limit = 100,
    CancelToken? cancelToken,
  }) async {
    albumCalls.add(artistId);
    return albumsByArtist[artistId] ?? const [];
  }
}

List<DeezerAlbum> _albums(List<String> titles) => [
  for (var i = 0; i < titles.length; i++)
    DeezerAlbum(id: i + 1, title: titles[i]),
];

void main() {
  late Directory root;
  late DateTime now;
  late _FakeDeezer deezer;
  late DeezerArtistResolver resolver;

  setUp(() {
    root = Directory.systemTemp.createTempSync('deezer_artist_resolver_');
    now = DateTime.utc(2026, 10, 5);
    deezer = _FakeDeezer();
    resolver = DeezerArtistResolver(
      client: deezer,
      cache: IntegrationJsonCache(
        readRootDirectory: () async => root,
        now: () => now,
      ),
    );
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('an ext-deezer-artist id is used without a request', () async {
    final id = await resolver.resolve(
      artistId: 'ext-deezer-artist-416239',
      name: 'Anything',
    );

    expect(id, 416239);
    expect(deezer.searchCalls, 0);
    expect(DeezerArtistResolver.idFromLibraryArtistId('artist-1'), isNull);
  });

  test('only an exact normalized name matches', () async {
    deezer.artists = const [
      DeezerArtist(id: 1, name: 'Imagine Dragons & K.Flay', fanCount: 300),
      DeezerArtist(id: 2, name: 'IMAGINE DRAGONS', fanCount: 9000000),
    ];

    expect(await resolver.resolve(artistId: 'a1', name: 'Imagine Dragons'), 2);
  });

  test('Unicode names match after normalization', () async {
    deezer.artists = const [
      DeezerArtist(id: 7, name: 'ＯＮＥ　ＯＫ　ＲＯＣＫ', fanCount: 10),
      DeezerArtist(id: 8, name: 'Beyoncé', fanCount: 10),
    ];

    expect(await resolver.resolve(artistId: 'a', name: 'ONE OK ROCK'), 7);
    expect(await resolver.resolve(artistId: 'b', name: 'Beyonce'), 8);
  });

  test('namesakes go to the most fans without library albums', () async {
    deezer.artists = const [
      DeezerArtist(id: 10, name: 'Nirvana', fanCount: 5000),
      DeezerArtist(id: 11, name: 'Nirvana', fanCount: 9000000),
    ];

    expect(await resolver.resolve(artistId: 'n', name: 'Nirvana'), 11);
    expect(deezer.albumCalls, isEmpty);
  });

  test('namesakes go to the one sharing library album titles', () async {
    deezer
      ..artists = const [
        DeezerArtist(id: 11, name: 'Nirvana', fanCount: 9000000),
        DeezerArtist(id: 10, name: 'Nirvana', fanCount: 5000),
      ]
      ..albumsByArtist = {
        11: _albums(['Nevermind', 'In Utero']),
        10: _albums(['The Story of Simon Simopath', 'All of Us']),
      };

    final id = await resolver.resolve(
      artistId: 'n',
      name: 'Nirvana',
      readLibraryAlbumTitles: () async => ['All Of Us (Remastered)'],
    );

    expect(id, 10);
    expect(deezer.albumCalls, [11, 10]);
  });

  test('equal album overlap keeps the artist with more fans', () async {
    deezer
      ..artists = const [
        DeezerArtist(id: 10, name: 'Nirvana', fanCount: 5000),
        DeezerArtist(id: 11, name: 'Nirvana', fanCount: 9000000),
      ]
      ..albumsByArtist = {
        11: _albums(['Nevermind']),
        10: _albums(['Nevermind']),
      };

    final id = await resolver.resolve(
      artistId: 'n',
      name: 'Nirvana',
      readLibraryAlbumTitles: () async => ['Unrelated'],
    );

    expect(id, 11);
  });

  test('album overlap compares at most three namesakes', () async {
    deezer.artists = [
      for (var i = 1; i <= 5; i++)
        DeezerArtist(id: i, name: 'Common', fanCount: 100 - i),
    ];

    await resolver.resolve(
      artistId: 'c',
      name: 'Common',
      readLibraryAlbumTitles: () async => ['Be'],
    );

    expect(deezer.albumCalls, [1, 2, 3]);
  });

  test('the mapping is cached for 30 days', () async {
    deezer.artists = const [DeezerArtist(id: 412, name: 'Queen')];

    expect(await resolver.resolve(artistId: 'q', name: 'Queen'), 412);
    now = now.add(const Duration(days: 29));
    expect(await resolver.resolve(artistId: 'q', name: 'queen'), 412);
    expect(deezer.searchCalls, 1);

    now = now.add(DeezerCache.artistFoundTtl);
    await resolver.resolve(artistId: 'q', name: 'Queen');
    expect(deezer.searchCalls, 2);
  });

  test('"not on Deezer" is cached for 7 days', () async {
    deezer.artists = const [DeezerArtist(id: 1, name: 'Someone Else')];

    expect(await resolver.resolve(artistId: 'x', name: 'Unknown'), isNull);
    now = now.add(const Duration(days: 6));
    expect(await resolver.resolve(artistId: 'x', name: 'Unknown'), isNull);
    expect(deezer.searchCalls, 1);

    now = now.add(const Duration(days: 1));
    await resolver.resolve(artistId: 'x', name: 'Unknown');
    expect(deezer.searchCalls, 2);
  });

  test('a failed search is not cached', () async {
    deezer.searchError = const DeezerApiException(code: 4);

    await expectLater(
      resolver.resolve(artistId: 'q', name: 'Queen'),
      throwsA(isA<DeezerApiException>()),
    );

    deezer
      ..searchError = null
      ..artists = const [DeezerArtist(id: 412, name: 'Queen')];
    expect(await resolver.resolve(artistId: 'q', name: 'Queen'), 412);
  });
}
