import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/api/deezer_request_limiter.dart';

/// Answers every request with the next body queued for its path.
class _DeezerAdapter implements HttpClientAdapter {
  final Map<String, List<Object>> bodies = <String, List<Object>>{};
  final List<Uri> requests = <Uri>[];

  void queue(String path, Object body) =>
      (bodies[path] ??= <Object>[]).add(body);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    final queued = bodies[options.uri.path];
    if (queued == null || queued.isEmpty) {
      throw StateError('No response queued for ${options.uri.path}');
    }
    final body = queued.length == 1 ? queued.first : queued.removeAt(0);
    return ResponseBody.fromString(
      body is String ? body : jsonEncode(body),
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, Object?> _error(
  int code,
  String type,
  String message,
) => <String, Object?>{
  'error': <String, Object?>{'type': type, 'message': message, 'code': code},
};

Map<String, Object?> _track(
  int id,
  String title, {
  int artistId = 416239,
  int rank = 100,
}) => <String, Object?>{
  'id': id,
  'readable': true,
  'title': title,
  'title_short': title,
  'title_version': '',
  'isrc': 'USUM7120$id',
  'duration': 175,
  'rank': rank,
  'artist': <String, Object?>{'id': artistId, 'name': 'Imagine Dragons'},
  'album': <String, Object?>{
    'id': 6240279,
    'title': 'Night Visions',
    'cover_small': 'https://cdn-images.dzcdn.net/images/cover/x/56x56.jpg',
    'cover_medium': 'https://cdn-images.dzcdn.net/images/cover/x/250x250.jpg',
  },
  'type': 'track',
};

void main() {
  late _DeezerAdapter adapter;
  late List<Duration> waits;
  late DeezerApiClient client;

  setUp(() {
    adapter = _DeezerAdapter();
    waits = <Duration>[];
    final dio = Dio(DeezerApiClient.baseOptions)..httpClientAdapter = adapter;
    client = DeezerApiClient(
      dio: dio,
      wait: (duration) async => waits.add(duration),
    );
  });

  test('base options use 8 second timeouts against api.deezer.com', () {
    expect(DeezerApiClient.baseOptions.baseUrl, 'https://api.deezer.com/');
    expect(
      DeezerApiClient.baseOptions.connectTimeout,
      const Duration(seconds: 8),
    );
    expect(
      DeezerApiClient.baseOptions.receiveTimeout,
      const Duration(seconds: 8),
    );
  });

  test('searchArtists parses artists with fan and album counts', () async {
    adapter.queue('/search/artist', <String, Object?>{
      'data': <Object?>[
        <String, Object?>{
          'id': 416239,
          'name': 'Imagine Dragons',
          'picture_medium': 'https://cdn-images.dzcdn.net/a/250x250.jpg',
          'nb_album': 62,
          'nb_fan': 9538593,
          'type': 'artist',
        },
        <String, Object?>{'id': 0, 'name': 'No id'},
      ],
      'total': 2,
    });

    final artists = await client.searchArtists(' Imagine Dragons ');

    expect(artists, hasLength(1));
    expect(artists.single.id, 416239);
    expect(artists.single.fanCount, 9538593);
    expect(artists.single.albumCount, 62);
    expect(
      artists.single.pictureMedium,
      'https://cdn-images.dzcdn.net/a/250x250.jpg',
    );
    final uri = adapter.requests.single;
    expect(uri.host, 'api.deezer.com');
    expect(uri.path, '/search/artist');
    expect(uri.queryParameters['q'], 'Imagine Dragons');
    expect(uri.queryParameters['limit'], '25');
  });

  test('getArtistTopTracks and searchTracks parse tracks', () async {
    adapter
      ..queue('/artist/416239/top', <String, Object?>{
        'data': <Object?>[_track(1, 'Demons', rank: 958755)],
      })
      ..queue('/search/track', <String, Object?>{
        'data': <Object?>[_track(2, 'Radioactive')],
      });

    final top = await client.getArtistTopTracks(416239);
    final search = await client.searchTracks('Imagine Dragons');

    expect(top.single.title, 'Demons');
    expect(top.single.rank, 958755);
    expect(top.single.durationSeconds, 175);
    expect(top.single.isrc, 'USUM71201');
    expect(top.single.artist.id, 416239);
    expect(top.single.album?.title, 'Night Visions');
    expect(search.single.title, 'Radioactive');
    expect(adapter.requests.first.queryParameters['limit'], '50');
    expect(adapter.requests.last.queryParameters['limit'], '100');
  });

  test('model JSON round-trips through toJson', () {
    final track = DeezerTrack.fromJson(_track(7, 'Wonder (Japanese Version)'));
    final copy = DeezerTrack.fromJson(track.toJson());

    expect(copy.id, 7);
    expect(copy.title, 'Wonder (Japanese Version)');
    expect(copy.artist.name, 'Imagine Dragons');
    expect(copy.album?.coverMedium, track.album?.coverMedium);
  });

  test('getArtistAlbums parses release details', () async {
    adapter.queue('/artist/416239/albums', <String, Object?>{
      'data': <Object?>[
        <String, Object?>{
          'id': 712820501,
          'title': 'Reflections',
          'release_date': '2025-02-21',
          'record_type': 'album',
          'cover_big': 'https://cdn-images.dzcdn.net/c/500x500.jpg',
        },
      ],
    });

    final albums = await client.getArtistAlbums(416239);

    expect(albums.single.title, 'Reflections');
    expect(albums.single.releaseDate, '2025-02-21');
    expect(albums.single.recordType, 'album');
  });

  test('getArtist parses the photo and fan count', () async {
    adapter.queue('/artist/1105', <String, Object?>{
      'id': 1105,
      'name': 'ONE OK ROCK',
      'picture_xl':
          'https://cdn-images.dzcdn.net/images/artist/h/1000x1000.jpg',
      'nb_album': 31,
      'nb_fan': 1234567,
      'type': 'artist',
    });

    final artist = await client.getArtist(1105);

    expect(artist?.name, 'ONE OK ROCK');
    expect(artist?.fanCount, 1234567);
    expect(
      artist?.pictureXl,
      'https://cdn-images.dzcdn.net/images/artist/h/1000x1000.jpg',
    );
  });

  test('getArtist and getAlbum read code 800 as not found', () async {
    adapter
      ..queue('/artist/9', _error(800, 'DataException', 'no data'))
      ..queue('/album/9', _error(800, 'DataException', 'no data'));

    expect(await client.getArtist(9), isNull);
    expect(await client.getAlbum(9), isNull);
  });

  test('getRelatedArtists parses artists and sends the limit', () async {
    adapter.queue('/artist/1105/related', <String, Object?>{
      'data': <Object?>[
        <String, Object?>{'id': 4, 'name': 'Coldrain', 'nb_fan': 10},
        <String, Object?>{'id': 0, 'name': 'No id'},
      ],
    });

    final related = await client.getRelatedArtists(1105, limit: 12);

    expect(related.map((artist) => artist.name), ['Coldrain']);
    expect(adapter.requests.single.queryParameters['limit'], '12');
  });

  test('getAlbum parses the track count', () async {
    adapter.queue('/album/302127', <String, Object?>{
      'id': 302127,
      'title': 'Ambitions (Japanese Version)',
      'record_type': 'album',
      'release_date': '2017-01-11',
      'nb_tracks': 14,
    });

    final album = await client.getAlbum(302127);

    expect(album?.title, 'Ambitions (Japanese Version)');
    expect(album?.trackCount, 14);
    expect(album?.releaseDate, '2017-01-11');
  });

  test('getAlbum parses the tracklist, which round-trips', () async {
    adapter.queue('/album/910510411', <String, Object?>{
      'id': 910510411,
      'title': 'Dracula (with JENNIE)',
      'record_type': 'single',
      'release_date': '2026-02-06',
      'nb_tracks': 2,
      'tracks': <String, Object?>{
        'data': <Object?>[
          _track(3818963601, 'Dracula (with JENNIE)'),
          _track(3818963602, 'Dracula (with JENNIE) [Instrumental]'),
        ],
      },
    });

    final album = await client.getAlbum(910510411);

    expect(album?.tracks?.map((track) => track.title), <String>[
      'Dracula (with JENNIE)',
      'Dracula (with JENNIE) [Instrumental]',
    ]);
    expect(album?.tracks?.first.durationSeconds, 175);
    final cached = DeezerAlbum.fromJson(
      jsonDecode(jsonEncode(album!.toJson())) as Map<String, dynamic>,
    );
    expect(cached.tracks?.map((track) => track.id), <int>[
      3818963601,
      3818963602,
    ]);
    // A listed album has no tracklist, and none is written for it.
    expect(
      const DeezerAlbum(id: 1, title: 'A').toJson(),
      isNot(contains('tracks')),
    );
  });

  test('getChartTracks parses the chart and sends the limit', () async {
    adapter.queue('/chart/0/tracks', <String, Object?>{
      'data': <Object?>[
        _track(1, 'First', rank: 990000),
        _track(2, 'Second', rank: 980000),
      ],
      'total': 2,
    });

    final chart = await client.getChartTracks(limit: 100);

    expect(chart.map((track) => track.title), <String>['First', 'Second']);
    expect(chart.first.artist.name, 'Imagine Dragons');
    expect(adapter.requests.single.queryParameters['limit'], '100');
  });

  test('code 800 (no data) reads as an empty result', () async {
    adapter.queue('/artist/0/top', _error(800, 'DataException', 'no data'));

    expect(await client.getArtistTopTracks(0), isEmpty);
    expect(waits, isEmpty);
  });

  test('code 4 (quota) waits 5 seconds and retries once', () async {
    adapter
      ..queue('/search/track', _error(4, 'Exception', 'Quota limit exceeded'))
      ..queue('/search/track', <String, Object?>{
        'data': <Object?>[_track(3, 'Believer')],
      });

    final tracks = await client.searchTracks('Imagine Dragons');

    expect(tracks.single.title, 'Believer');
    expect(waits, <Duration>[const Duration(seconds: 5)]);
    expect(adapter.requests, hasLength(2));
  });

  test('a second code 4 throws a quota exception', () async {
    adapter.queue(
      '/search/track',
      _error(4, 'Exception', 'Quota limit exceeded'),
    );

    await expectLater(
      client.searchTracks('Imagine Dragons'),
      throwsA(
        isA<DeezerApiException>().having(
          (error) => error.isQuotaExceeded,
          'isQuotaExceeded',
          isTrue,
        ),
      ),
    );
    expect(adapter.requests, hasLength(2));
  });

  test('other body errors throw a typed exception without retrying', () async {
    adapter.queue(
      '/search/artist',
      _error(100, 'ParameterException', 'Wrong parameter'),
    );

    await expectLater(
      client.searchArtists('x'),
      throwsA(
        isA<DeezerApiException>()
            .having((error) => error.code, 'code', 100)
            .having((error) => error.type, 'type', 'ParameterException'),
      ),
    );
    expect(adapter.requests, hasLength(1));
    expect(waits, isEmpty);
  });

  test('a body that is not a JSON object throws', () async {
    adapter.queue('/search/artist', '"unexpected"');

    await expectLater(
      client.searchArtists('x'),
      throwsA(isA<DeezerApiException>()),
    );
  });

  test('an empty query sends no request', () async {
    expect(await client.searchArtists('  '), isEmpty);
    expect(await client.searchTracks(''), isEmpty);
    expect(adapter.requests, isEmpty);
  });

  test('every request goes through the shared limiter', () async {
    final limiter = DeezerRequestLimiter(maxInFlight: 1);
    final limited = DeezerApiClient(
      dio: Dio(DeezerApiClient.baseOptions)..httpClientAdapter = adapter,
      limiter: limiter,
    );
    adapter.queue('/search/artist', <String, Object?>{'data': <Object?>[]});

    final pending = limited.searchArtists('a');
    await Future<void>.delayed(Duration.zero);
    expect(limiter.inFlight, 1);
    await pending;
    expect(limiter.inFlight, 0);
  });
}
