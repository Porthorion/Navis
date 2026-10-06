import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/api/deezer_request_limiter.dart';

/// Records the priority of every request it runs.
class _RecordingLimiter extends DeezerRequestLimiter {
  final List<bool> background = <bool>[];

  @override
  Future<T> run<T>(Future<T> Function() request, {bool background = false}) {
    this.background.add(background);
    return super.run(request, background: background);
  }
}

/// Answers every request with the next body queued for its path.
class _DeezerAdapter implements HttpClientAdapter {
  final Map<String, List<Object>> bodies = <String, List<Object>>{};
  final List<Uri> requests = <Uri>[];
  void Function(Uri uri)? onFetch;

  void queue(String path, Object body) =>
      (bodies[path] ??= <Object>[]).add(body);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    onFetch?.call(options.uri);
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

  /// What the limiter waited for; its clock moves on by each wait.
  late List<Duration> waits;
  late DeezerRequestLimiter limiter;
  late DeezerApiClient client;

  setUp(() {
    adapter = _DeezerAdapter();
    waits = <Duration>[];
    var clock = Duration.zero;
    limiter = DeezerRequestLimiter(
      elapsed: () => clock,
      delay: (duration) async {
        waits.add(duration);
        clock += duration;
      },
    );
    final dio = Dio(DeezerApiClient.baseOptions)..httpClientAdapter = adapter;
    client = DeezerApiClient(dio: dio, limiter: limiter);
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

  test('getArtist reads code 800 as not found', () async {
    adapter.queue('/artist/9', _error(800, 'DataException', 'no data'));

    expect(await client.getArtist(9), isNull);
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

  test(
    'code 4 (quota) pauses the shared limiter 5 seconds and retries once',
    () async {
      adapter
        ..queue('/search/track', _error(4, 'Exception', 'Quota limit exceeded'))
        ..queue('/search/track', <String, Object?>{
          'data': <Object?>[_track(3, 'Believer')],
        });

      final tracks = await client.searchTracks('Imagine Dragons');

      expect(tracks.single.title, 'Believer');
      expect(waits, <Duration>[const Duration(seconds: 5)]);
      expect(adapter.requests, hasLength(2));
    },
  );

  test('code 4 holds the other requests for the pause too', () {
    fakeAsync((async) {
      final shared = DeezerRequestLimiter(elapsed: () => async.elapsed);
      final limited = DeezerApiClient(
        dio: Dio(DeezerApiClient.baseOptions)..httpClientAdapter = adapter,
        limiter: shared,
      );
      final sentAt = <String, List<Duration>>{};
      adapter
        ..onFetch = ((uri) => (sentAt[uri.path] ??= []).add(async.elapsed))
        ..queue('/search/track', _error(4, 'Exception', 'Quota limit exceeded'))
        ..queue('/search/track', <String, Object?>{'data': <Object?>[]})
        ..queue('/search/artist', <String, Object?>{'data': <Object?>[]});

      unawaited(limited.searchTracks('Imagine Dragons'));
      // Dio dispatches through zero-length timers.
      async.elapse(Duration.zero);
      expect(sentAt['/search/track'], [Duration.zero]);

      // A request from another feature, after the quota error.
      var artistsDone = false;
      unawaited(limited.searchArtists('Queen').then((_) => artistsDone = true));
      async.elapse(const Duration(milliseconds: 4999));
      expect(sentAt['/search/artist'], isNull);
      expect(sentAt['/search/track'], hasLength(1));

      async.elapse(const Duration(milliseconds: 1));
      expect(sentAt['/search/artist'], [const Duration(seconds: 5)]);
      expect(sentAt['/search/track'], [
        Duration.zero,
        const Duration(seconds: 5),
      ]);
      expect(artistsDone, isTrue);
    });
  });

  test('code 4 pauses before its slot goes to a waiting request', () {
    fakeAsync((async) {
      final shared = DeezerRequestLimiter(
        elapsed: () => async.elapsed,
        maxInFlight: 1,
      );
      final limited = DeezerApiClient(
        dio: Dio(DeezerApiClient.baseOptions)..httpClientAdapter = adapter,
        limiter: shared,
      );
      final sentAt = <String, List<Duration>>{};
      adapter
        ..onFetch = ((uri) => (sentAt[uri.path] ??= []).add(async.elapsed))
        ..queue('/search/track', _error(4, 'Exception', 'Quota limit exceeded'))
        ..queue('/search/track', <String, Object?>{'data': <Object?>[]})
        ..queue('/search/artist', <String, Object?>{'data': <Object?>[]});

      // The second request waits for the only slot before the quota answer.
      unawaited(limited.searchTracks('Imagine Dragons'));
      unawaited(limited.searchArtists('Queen'));
      async.elapse(Duration.zero);
      expect(sentAt['/search/track'], [Duration.zero]);

      async.elapse(const Duration(milliseconds: 4999));
      expect(sentAt['/search/artist'], isNull);
      async.elapse(const Duration(milliseconds: 1));
      expect(sentAt.values.expand((times) => times), [
        Duration.zero,
        const Duration(seconds: 5),
        const Duration(seconds: 5),
      ]);
    });
  });

  test('a foreground request retries code 4 up to 3 times', () async {
    final quota = _error(4, 'Exception', 'Quota limit exceeded');
    adapter
      ..queue('/search/track', quota)
      ..queue('/search/track', quota)
      ..queue('/search/track', quota)
      ..queue('/search/track', <String, Object?>{
        'data': <Object?>[_track(3, 'Believer')],
      });

    final tracks = await client.searchTracks('Imagine Dragons');

    expect(tracks.single.title, 'Believer');
    expect(adapter.requests, hasLength(4));
    // Each retry waited for the shared pause.
    expect(waits, List.filled(3, const Duration(seconds: 5)));
  });

  final throwsQuota = throwsA(
    isA<DeezerApiException>().having(
      (error) => error.isQuotaExceeded,
      'isQuotaExceeded',
      isTrue,
    ),
  );

  test('a fourth code 4 throws a quota exception', () async {
    adapter.queue(
      '/search/track',
      _error(4, 'Exception', 'Quota limit exceeded'),
    );

    await expectLater(client.searchTracks('Imagine Dragons'), throwsQuota);
    expect(adapter.requests, hasLength(4));
  });

  test('a background request retries code 4 once', () async {
    adapter.queue(
      '/search/artist',
      _error(4, 'Exception', 'Quota limit exceeded'),
    );

    await expectLater(
      client.searchArtists('Queen', background: true),
      throwsQuota,
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

  test('background requests reach the limiter as background', () async {
    final recording = _RecordingLimiter();
    final limited = DeezerApiClient(
      dio: Dio(DeezerApiClient.baseOptions)..httpClientAdapter = adapter,
      limiter: recording,
    );
    const empty = <String, Object?>{'data': <Object?>[]};
    adapter
      ..queue('/search/artist', empty)
      ..queue('/artist/1/albums', empty)
      ..queue('/chart/0/tracks', empty);

    await limited.searchArtists('a', background: true);
    await limited.getArtistAlbums(1, background: true);
    await limited.getChartTracks(background: true);
    expect(recording.background, [true, true, true]);

    await limited.searchArtists('a');
    await limited.getArtistAlbums(1);
    await limited.getChartTracks();
    expect(recording.background.skip(3), [false, false, false]);
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
