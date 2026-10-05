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
  }) async {
    calls.add('artist/$artistId/albums?limit=$limit');
    return const [DeezerAlbum(id: 9, title: 'Ambitions', recordType: 'album')];
  }

  @override
  Future<DeezerAlbum?> getAlbum(int albumId, {CancelToken? cancelToken}) async {
    calls.add('album/$albumId');
    return DeezerAlbum(id: albumId, title: 'Ambitions', trackCount: 14);
  }
}

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

  test('an album is kept for 7 days with its track count', () async {
    expect((await catalog.album(9))?.trackCount, 14);
    now = now.add(const Duration(days: 6));
    expect((await catalog.album(9))?.trackCount, 14);
    expect(deezer.calls, ['album/9']);
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
