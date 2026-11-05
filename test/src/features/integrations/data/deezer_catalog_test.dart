import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/features/integrations/data/deezer_catalog.dart';
import 'package:navis/src/features/integrations/data/integration_json_cache.dart';

class _FakeDeezer extends DeezerApiClient {
  new() : super(dio: Dio());

  final List<String> calls = <String>[];
  Exception? error;

  @override
  Future<DeezerArtist?> getArtist(
    int artistId, {
    CancelToken? cancelToken,
  }) async {
    calls.add('artist/$artistId');
    if (error case final error?) throw error;
    return artistId == 404
        ? null
        : DeezerArtist(id: artistId, name: 'Artist', fanCount: 4100000);
  }

  @override
  Future<List<DeezerArtist>> getRelatedArtists(
    int artistId, {
    int limit = 20,
    CancelToken? cancelToken,
  }) async {
    calls.add('artist/$artistId/related?limit=$limit');
    return const [DeezerArtist(id: 2, name: 'Related')];
  }

  @override
  Future<List<DeezerAlbum>> getArtistAlbums(
    int artistId, {
    int limit = 100,
    CancelToken? cancelToken,
    bool background = false,
  }) async {
    calls.add('artist/$artistId/albums?limit=$limit${_mark(background)}');
    return const [DeezerAlbum(id: 9, title: 'Ambitions', recordType: 'album')];
  }

  @override
  Future<List<DeezerTrack>> searchTracks(
    String query, {
    int limit = 100,
    CancelToken? cancelToken,
  }) async {
    calls.add('search/track?q=$query&limit=$limit');
    if (error case final error?) throw error;
    return const [
      DeezerTrack(
        id: 3135556,
        title: 'Hello',
        artist: DeezerArtist(id: 75798, name: 'Adele'),
        rank: 900000,
      ),
    ];
  }

  @override
  Future<List<DeezerArtist>> searchArtists(
    String name, {
    int limit = 25,
    CancelToken? cancelToken,
    bool background = false,
  }) async {
    calls.add('search/artist?q=$name&limit=$limit');
    return const [DeezerArtist(id: 75798, name: 'Adele')];
  }

  @override
  Future<List<DeezerAlbum>> searchAlbums(
    String query, {
    int limit = 25,
    CancelToken? cancelToken,
  }) async {
    calls.add('search/album?q=$query&limit=$limit');
    return const [
      DeezerAlbum(
        id: 302127,
        title: '25',
        artist: DeezerArtist(id: 75798, name: 'Adele'),
      ),
    ];
  }

  @override
  Future<List<DeezerTrack>> getChartTracks({
    int limit = 100,
    CancelToken? cancelToken,
    bool background = false,
  }) async {
    calls.add('chart/0/tracks?limit=$limit${_mark(background)}');
    return const [
      DeezerTrack(
        id: 1,
        title: 'Dracula',
        artist: DeezerArtist(id: 7, name: 'Tame Impala'),
      ),
    ];
  }
}

String _mark(bool background) => background ? ' (background)' : '';

void main() {
  late Directory root;
  late DateTime now;
  late _FakeDeezer deezer;
  late DeezerCatalog catalog;

  setUp(() {
    root = Directory.systemTemp.createTempSync('deezer_catalog_');
    now = DateTime.utc(2026, 10, 5);
    deezer = _FakeDeezer();
    catalog = DeezerCatalog(
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

  test('artist details and related artists are kept for 7 days', () async {
    expect((await catalog.artist(1))?.fanCount, 4100000);
    expect((await catalog.relatedArtists(1)).single.name, 'Related');
    now = now.add(const Duration(days: 6, hours: 23));
    expect((await catalog.artist(1))?.fanCount, 4100000);
    expect((await catalog.relatedArtists(1)).single.name, 'Related');
    expect(deezer.calls, ['artist/1', 'artist/1/related?limit=20']);

    now = now.add(const Duration(hours: 1));
    await catalog.artist(1);
    await catalog.relatedArtists(1);
    expect(deezer.calls, hasLength(4));
  });

  test("an artist's albums are kept for 24 hours", () async {
    expect((await catalog.artistAlbums(1)).single.title, 'Ambitions');
    now = now.add(const Duration(hours: 23));
    await catalog.artistAlbums(1);
    expect(deezer.calls, ['artist/1/albums?limit=100']);

    now = now.add(const Duration(hours: 1));
    await catalog.artistAlbums(1);
    expect(deezer.calls, hasLength(2));
  });

  test("an artist's first releases are kept for 24 hours apart", () async {
    await catalog.artistAlbums(1);
    expect((await catalog.recentArtistAlbums(1)).single.title, 'Ambitions');
    now = now.add(const Duration(hours: 23));
    await catalog.recentArtistAlbums(1);
    expect(deezer.calls, [
      'artist/1/albums?limit=100',
      'artist/1/albums?limit=5',
    ]);

    now = now.add(const Duration(hours: 1));
    await catalog.recentArtistAlbums(1);
    expect(deezer.calls, hasLength(3));
  });

  test('first releases and the chart can be read in the background', () async {
    await catalog.recentArtistAlbums(1, background: true);
    await catalog.chartTracks(background: true);
    await catalog.artistAlbums(2);
    expect(deezer.calls, [
      'artist/1/albums?limit=5 (background)',
      'chart/0/tracks?limit=100 (background)',
      'artist/2/albums?limit=100',
    ]);
  });

  test('the chart is kept for 6 hours', () async {
    expect((await catalog.chartTracks()).single.artist.name, 'Tame Impala');
    now = now.add(const Duration(hours: 5, minutes: 59));
    await catalog.chartTracks();
    expect(deezer.calls, ['chart/0/tracks?limit=100']);

    now = now.add(const Duration(minutes: 1));
    await catalog.chartTracks();
    expect(deezer.calls, hasLength(2));
  });

  test('search results are kept 10 minutes per query, ignoring case', () async {
    final tracks = await catalog.searchTracks('Hello');
    expect(tracks.single.artist.name, 'Adele');
    expect((await catalog.searchArtists('Hello')).single.name, 'Adele');
    final albums = await catalog.searchAlbums('Hello');
    expect(albums.single.artist?.name, 'Adele');
    now = now.add(const Duration(minutes: 9, seconds: 59));
    await catalog.searchTracks('  hello ');
    await catalog.searchArtists('HELLO');
    await catalog.searchAlbums('hello');
    expect(deezer.calls, [
      'search/track?q=Hello&limit=25',
      'search/artist?q=Hello&limit=25',
      'search/album?q=Hello&limit=25',
    ]);

    now = now.add(const Duration(seconds: 1));
    await catalog.searchTracks('hello');
    expect(deezer.calls, hasLength(4));
    await catalog.searchTracks('hello again');
    expect(deezer.calls, hasLength(5));
  });

  test("a new session removes the earlier session's searches", () async {
    await catalog.searchTracks('hello');
    await catalog.searchTracks('hello');
    expect(deezer.calls, hasLength(1));

    final nextSession = DeezerCatalog(
      client: deezer,
      cache: IntegrationJsonCache(
        readRootDirectory: () async => root,
        now: () => now,
      ),
    );
    await nextSession.searchTracks('hello');
    expect(deezer.calls, hasLength(2));
    await nextSession.searchTracks('hello');
    expect(deezer.calls, hasLength(2));
  });

  test('a failed search is not cached', () async {
    deezer.error = const DeezerApiException(code: 4);
    await expectLater(
      catalog.searchTracks('hello'),
      throwsA(isA<DeezerApiException>()),
    );
    deezer.error = null;
    expect(await catalog.searchTracks('hello'), hasLength(1));
  });

  test('"not on Deezer" is cached too', () async {
    expect(await catalog.artist(404), isNull);
    expect(await catalog.artist(404), isNull);
    expect(deezer.calls, ['artist/404']);
  });

  test('a failed request is not cached', () async {
    deezer.error = const DeezerApiException(code: 4);
    await expectLater(catalog.artist(1), throwsA(isA<DeezerApiException>()));

    deezer.error = null;
    expect((await catalog.artist(1))?.fanCount, 4100000);
    expect(deezer.calls, ['artist/1', 'artist/1']);
  });
}
