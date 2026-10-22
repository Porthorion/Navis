import 'dart:convert';
import 'dart:io';

import 'package:navis/src/features/integrations/data/integration_json_cache.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/lastfm_api_client.dart';

class _MockDio extends Mock implements Dio;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('similar-track cache normalizes keys, honors limits and expires at 24 hours', () async {
    final root = await Directory.systemTemp.createTemp('lastfm-cache-');
    addTearDown(() async {
      await root.delete(recursive: true);
    });
    var now = DateTime.utc(2026, 10, 7);
    final cache = IntegrationJsonCache(
      readRootDirectory: () async => root,
      now: () => now,
    );
    var requests = 0;
    final dio = Dio();
    addTearDown(dio.close);
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests++;
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'similartracks': {
                  'track': [
                    {
                      'name': 'First',
                      'artist': {'name': 'Fixture'},
                    },
                    {
                      'name': 'Second',
                      'artist': {'name': 'Fixture'},
                    },
                  ],
                },
              },
            ),
          );
        },
      ),
    );
    final client = LastFmApiClient(apiKey: 'fixture', dio: dio, cache: cache);
    expect(
      (await client.getSimilarTracksResult(
        artist: 'Fixture  Artist',
        track: ' Track ',
        limit: 2,
      )).tracks,
      hasLength(2),
    );
    // A new client shares the disk entry; no process-local cache is required.
    final next = LastFmApiClient(apiKey: 'fixture', dio: dio, cache: cache);
    expect(
      (await next.getSimilarTracksResult(
        artist: 'fixture artist',
        track: 'track',
        limit: 1,
      )).tracks,
      hasLength(1),
    );
    expect(requests, 1);
    now = now.add(const Duration(hours: 24));
    (await next.getSimilarTracksResult(
      artist: 'fixture artist',
      track: 'track',
      limit: 2,
    )).tracks;
    expect(requests, 2);
    (await next.getSimilarTracksResult(
      artist: 'fixture artist',
      track: 'other',
      limit: 2,
    )).tracks;
    expect(requests, 3);
    (await next.getSimilarTracksResult(
      artist: 'fixture artist',
      track: 'track',
      limit: 3,
    )).tracks;
    expect(requests, 4);
  });

  test('Last.fm API errors do not poison the similar-track cache', () async {
    final root = await Directory.systemTemp.createTemp('lastfm-cache-error-');
    addTearDown(() async {
      await root.delete(recursive: true);
    });
    final cache = IntegrationJsonCache(readRootDirectory: () async => root);
    var requests = 0;
    final dio = Dio();
    addTearDown(dio.close);
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests++;
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: requests == 1
                  ? {'error': 29, 'message': 'fixture limit'}
                  : {
                      'similartracks': {'track': <dynamic>[]},
                    },
            ),
          );
        },
      ),
    );
    final client = LastFmApiClient(apiKey: 'fixture', dio: dio, cache: cache);
    expect(
      (await client.getSimilarTracksResult(
        artist: 'Fixture',
        track: 'Track',
      )).outcome,
      LastFmFetchOutcome.apiError,
    );
    expect(
      (await client.getSimilarTracksResult(
        artist: 'Fixture',
        track: 'Track',
      )).outcome,
      LastFmFetchOutcome.noResults,
    );
    await client.getSimilarTracksResult(artist: 'Fixture', track: 'Track');
    // The empty answer cost a track request and an artist-level fallback
    // request; the third call is served from the cached empty answer.
    expect(requests, 3);
  });

  setUpAll(() {
    registerFallbackValue(RequestOptions(path: '/'));
  });

  for (final (requested, resolved, accepted) in [
    ('ワンオクロック', '嵐', false),
    ('Sigur Ros', 'Sigur Rós', true),
    (' !!! ', '!!!', true),
    ('★☆', ' ★☆ ', true),
    ('!!!', '???', false),
    ('!!!', 'Queen', false),
    ('嵐', '嵐', true),
  ]) {
    test(
      'top tracks validates Unicode artist $requested against $resolved',
      () async {
        final dio = _MockDio();
        when(
          () => dio.get<Map<String, dynamic>>(
            any(),
            queryParameters: any(named: 'queryParameters'),
          ),
        ).thenAnswer(
          (_) async => Response<Map<String, dynamic>>(
            requestOptions: RequestOptions(path: '/2.0'),
            statusCode: 200,
            data: {
              'toptracks': {
                '@attr': {'artist': resolved},
                'track': [
                  {
                    'name': '残響リファレンス',
                    '@attr': {'rank': '1'},
                    if (requested.trim() != '!!!') 'artist': {'name': resolved},
                  },
                ],
              },
            },
          ),
        );
        final tracks = await LastFmApiClient(
          apiKey: 'key',
          dio: dio,
        ).getArtistTopTracks(artist: requested);
        expect(tracks, hasLength(accepted ? 1 : 0));
      },
    );
  }

  test('parses track.getSimilar payload into recommendations', () async {
    final dio = _MockDio();
    when(
      () => dio.get<Map<String, dynamic>>(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer(
      (_) async => Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(path: '/2.0'),
        data: <String, dynamic>{
          'similartracks': <String, dynamic>{
            'track': <Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'Song A',
                'artist': <String, dynamic>{'name': 'Artist A'},
                'match': '0.91',
              },
              <String, dynamic>{
                'name': 'Song B',
                'artist': <String, dynamic>{'name': 'Artist B'},
                'match': 0.83,
              },
            ],
          },
        },
      ),
    );

    final client = LastFmApiClient(apiKey: 'key', dio: dio);
    final fetched = await client.getSimilarTracksResult(
      artist: 'Seed Artist',
      track: 'Seed Song',
      limit: 10,
    );
    final recs = fetched.tracks;

    expect(recs, hasLength(2));
    expect(recs.first.artist, 'Artist A');
    expect(recs.first.title, 'Song A');
    expect(recs.first.match, closeTo(0.91, 0.0001));
    expect(recs.last.artist, 'Artist B');
    expect(recs.last.title, 'Song B');
    expect(recs.last.match, closeTo(0.83, 0.0001));
  });

  test('returns empty list for Last.fm soft-fail payload', () async {
    final dio = _MockDio();
    when(
      () => dio.get<Map<String, dynamic>>(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer(
      (_) async => Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(path: '/2.0'),
        data: <String, dynamic>{'error': 6, 'message': 'Track not found'},
      ),
    );

    final client = LastFmApiClient(apiKey: 'key', dio: dio);
    final fetched = await client.getSimilarTracksResult(
      artist: 'Unknown',
      track: 'Unknown',
    );
    final recs = fetched.tracks;

    expect(recs, isEmpty);
  });

  test('reports apiError outcome for Last.fm soft-fail payload', () async {
    final dio = _MockDio();
    when(
      () => dio.get<Map<String, dynamic>>(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer(
      (_) async => Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(path: '/2.0'),
        statusCode: 200,
        data: <String, dynamic>{'error': 6, 'message': 'Track not found'},
      ),
    );

    final client = LastFmApiClient(apiKey: 'key', dio: dio);
    final result = await client.getSimilarTracksResult(
      artist: 'Unknown',
      track: 'Unknown',
    );

    expect(result.outcome, LastFmFetchOutcome.apiError);
    expect(result.apiErrorCode, 6);
    expect(result.tracks, isEmpty);
  });

  test('reports networkError outcome for transport failures', () async {
    final dio = _MockDio();
    when(
      () => dio.get<Map<String, dynamic>>(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenThrow(
      DioException(
        requestOptions: RequestOptions(path: '/2.0'),
        type: DioExceptionType.connectionTimeout,
        message: 'timeout',
      ),
    );

    final client = LastFmApiClient(apiKey: 'key', dio: dio);
    final result = await client.getSimilarTracksResult(
      artist: 'Artist',
      track: 'Track',
    );

    expect(result.outcome, LastFmFetchOutcome.networkError);
    expect(result.tracks, isEmpty);
  });

  test('returns empty list when client is not configured', () async {
    final client = LastFmApiClient(apiKey: '');
    final fetched = await client.getSimilarTracksResult(
      artist: 'Artist',
      track: 'Track',
    );
    final recs = fetched.tracks;
    expect(recs, isEmpty);
    final result = await client.getSimilarTracksResult(
      artist: 'Artist',
      track: 'Track',
    );
    expect(result.outcome, LastFmFetchOutcome.notConfigured);
  });

  // ---------------------------------------------------------------------------
  // getArtistTopTracks
  // ---------------------------------------------------------------------------

  test('getArtistTopTracks: parses top-tracks payload correctly', () async {
    final dio = _MockDio();
    when(
      () => dio.get<Map<String, dynamic>>(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer(
      (_) async => Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(path: '/2.0'),
        statusCode: 200,
        data: <String, dynamic>{
          'toptracks': <String, dynamic>{
            '@attr': <String, dynamic>{'artist': 'Queen'},
            'track': <Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'Bohemian Rhapsody',
                'listeners': '2000000',
                '@attr': <String, dynamic>{'rank': '1'},
                'artist': <String, dynamic>{'name': 'Queen'},
              },
              <String, dynamic>{
                'name': 'We Will Rock You',
                'listeners': 1500000,
                '@attr': <String, dynamic>{'rank': '2'},
                'artist': <String, dynamic>{'name': 'Queen'},
              },
            ],
          },
        },
      ),
    );

    final client = LastFmApiClient(apiKey: 'key', dio: dio);
    final tracks = await client.getArtistTopTracks(artist: 'Queen', limit: 10);

    expect(tracks, hasLength(2));
    expect(tracks.first.rank, 1);
    expect(tracks.first.title, 'Bohemian Rhapsody');
    expect(tracks.first.artist, 'Queen');
    expect(tracks.first.listeners, 2000000);
    expect(tracks.last.rank, 2);
    expect(tracks.last.title, 'We Will Rock You');
  });

  test('getArtistTopTracks: returns empty list when @attr.artist '
      'does not match requested artist', () async {
    final dio = _MockDio();
    when(
      () => dio.get<Map<String, dynamic>>(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer(
      (_) async => Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(path: '/2.0'),
        statusCode: 200,
        // Last.fm autocorrected "Pokelawls" → "Aurora" — should be rejected.
        data: <String, dynamic>{
          'toptracks': <String, dynamic>{
            '@attr': <String, dynamic>{'artist': 'Aurora'},
            'track': <Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'Runaway',
                'listeners': '1000000',
                '@attr': <String, dynamic>{'rank': '1'},
                'artist': <String, dynamic>{'name': 'Aurora'},
              },
            ],
          },
        },
      ),
    );

    final client = LastFmApiClient(apiKey: 'key', dio: dio);
    final tracks = await client.getArtistTopTracks(
      artist: 'Pokelawls',
      limit: 10,
    );

    expect(tracks, isEmpty);
  });

  test(
    'getArtistTopTracks: returns empty list on artist-not-found API error',
    () async {
      final dio = _MockDio();
      when(
        () => dio.get<Map<String, dynamic>>(
          any(),
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenAnswer(
        (_) async => Response<Map<String, dynamic>>(
          requestOptions: RequestOptions(path: '/2.0'),
          statusCode: 200,
          data: <String, dynamic>{'error': 6, 'message': 'Artist not found'},
        ),
      );

      final client = LastFmApiClient(apiKey: 'key', dio: dio);
      final tracks = await client.getArtistTopTracks(
        artist: 'UnknownArtistXYZ',
        limit: 10,
      );

      expect(tracks, isEmpty);
    },
  );

  test('getArtistTopTracks: accepts minor name differences '
      '(case and punctuation)', () async {
    final dio = _MockDio();
    when(
      () => dio.get<Map<String, dynamic>>(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer(
      (_) async => Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(path: '/2.0'),
        statusCode: 200,
        // Last.fm returns "AC/DC" but library stores "AC DC" — still valid.
        data: <String, dynamic>{
          'toptracks': <String, dynamic>{
            '@attr': <String, dynamic>{'artist': 'AC/DC'},
            'track': <Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'Highway to Hell',
                'listeners': '3000000',
                '@attr': <String, dynamic>{'rank': '1'},
                'artist': <String, dynamic>{'name': 'AC/DC'},
              },
            ],
          },
        },
      ),
    );

    final client = LastFmApiClient(apiKey: 'key', dio: dio);
    final tracks = await client.getArtistTopTracks(artist: 'AC DC', limit: 10);

    expect(tracks, hasLength(1));
    expect(tracks.first.title, 'Highway to Hell');
  });

  test(
    'getArtistTopTracks: filters out tracks attributed to a different artist',
    () async {
      final dio = _MockDio();
      when(
        () => dio.get<Map<String, dynamic>>(
          any(),
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenAnswer(
        (_) async => Response<Map<String, dynamic>>(
          requestOptions: RequestOptions(path: '/2.0'),
          statusCode: 200,
          // @attr.artist matches, but track #2 is by a completely different
          // artist (e.g. a collaboration or Last.fm data quirk).
          data: <String, dynamic>{
            'toptracks': <String, dynamic>{
              '@attr': <String, dynamic>{'artist': 'Pokelawls'},
              'track': <Map<String, dynamic>>[
                <String, dynamic>{
                  'name': 'Good Song',
                  'listeners': '500',
                  '@attr': <String, dynamic>{'rank': '1'},
                  'artist': <String, dynamic>{'name': 'Pokelawls'},
                },
                <String, dynamic>{
                  'name': 'RUNAWAY',
                  'listeners': '1000000',
                  '@attr': <String, dynamic>{'rank': '2'},
                  'artist': <String, dynamic>{'name': 'Aurora'},
                },
                <String, dynamic>{
                  'name': 'Another Good Song',
                  'listeners': '300',
                  '@attr': <String, dynamic>{'rank': '3'},
                  'artist': <String, dynamic>{'name': 'Pokelawls'},
                },
                <String, dynamic>{
                  'name': 'Heart Attack',
                  'listeners': '2000000',
                  '@attr': <String, dynamic>{'rank': '4'},
                  'artist': <String, dynamic>{'name': 'Demi Lovato'},
                },
              ],
            },
          },
        ),
      );

      final client = LastFmApiClient(apiKey: 'key', dio: dio);
      final tracks = await client.getArtistTopTracks(
        artist: 'Pokelawls',
        limit: 10,
      );

      // Only the two tracks actually by Pokelawls should survive.
      expect(tracks, hasLength(2));
      expect(tracks[0].title, 'Good Song');
      expect(tracks[0].artist, 'Pokelawls');
      expect(tracks[1].title, 'Another Good Song');
      expect(tracks[1].artist, 'Pokelawls');

      // Ranks should be re-numbered sequentially (no gaps).
      expect(tracks[0].rank, 1);
      expect(tracks[1].rank, 2);
    },
  );

  group('similar-track fallbacks', () {
    // Answers each Last.fm method from [routes] and records every request.
    Dio routedDio(
      Map<String, Map<String, dynamic> Function(Map<String, dynamic>)> routes,
      List<Map<String, dynamic>> requests,
    ) {
      final dio = Dio();
      addTearDown(dio.close);
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            final params = Map<String, dynamic>.of(options.queryParameters);
            requests.add(params);
            final route = routes[(params['method'] as String).toLowerCase()];
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: route == null
                    ? {'error': 3, 'message': 'unrouted'}
                    : route(params),
              ),
            );
          },
        ),
      );
      return dio;
    }

    Map<String, dynamic> similarTracks(List<(String, String)> tracks) => {
      'similartracks': {
        'track': [
          for (final (artist, title) in tracks)
            {
              'name': title,
              'match': 0.9,
              'artist': {'name': artist},
            },
        ],
      },
    };

    Map<String, dynamic> similarArtists(List<(String, double)> artists) => {
      'similarartists': {
        'artist': [
          for (final (name, match) in artists) {'name': name, 'match': match},
        ],
      },
    };

    Map<String, dynamic> topTracks(String artist, int count) => {
      'toptracks': {
        '@attr': {'artist': artist},
        'track': [
          for (var rank = 1; rank <= count; rank++)
            {
              'name': '$artist hit $rank',
              'artist': {'name': artist},
              '@attr': {'rank': '$rank'},
            },
        ],
      },
    };

    final emptySimilar = <String, dynamic>{
      'similartracks': {'track': <dynamic>[]},
    };

    test(
      'an empty track list falls back to similar artists top tracks',
      () async {
        final requests = <Map<String, dynamic>>[];
        final dio = routedDio({
          'track.getsimilar': (_) => emptySimilar,
          'artist.getsimilar': (_) =>
              similarArtists([('Alpha', 1.0), ('Beta', 0.8), ('Gamma', 0.6)]),
          'artist.gettoptracks': (params) =>
              topTracks(params['artist'] as String, 3),
        }, requests);
        final result = await LastFmApiClient(
          apiKey: 'key',
          dio: dio,
        ).getSimilarTracksResult(artist: 'Seed', track: 'Seed Song', limit: 20);

        expect(result.outcome, LastFmFetchOutcome.success);
        expect(result.tracks, hasLength(9));
        // Round-robin: every artist's first track comes before any second one.
        expect(result.tracks.take(3).map((t) => t.artist), [
          'Alpha',
          'Beta',
          'Gamma',
        ]);
        expect(result.tracks.first.title, 'Alpha hit 1');
        // Sorted by match, as the Same Vibes mapper does, the order holds.
        final byMatch = [...result.tracks]
          ..sort((a, b) => (b.match ?? 0).compareTo(a.match ?? 0));
        expect(byMatch.take(3).map((t) => t.artist), [
          'Alpha',
          'Beta',
          'Gamma',
        ]);
        // One similar-track request, one similar-artist request, three charts.
        expect(requests, hasLength(5));
      },
    );

    for (final (label, firstAnswer) in <(String, Map<String, dynamic>)>[
      ('empty', emptySimilar),
      ('error 6', {'error': 6, 'message': 'Track not found'}),
    ]) {
      test(
        'a $label answer for a qualified title retries the clean title',
        () async {
          final requests = <Map<String, dynamic>>[];
          final dio = routedDio({
            'track.getsimilar': (params) => params['track'] == 'Song'
                ? similarTracks([('Other', 'Match')])
                : firstAnswer,
          }, requests);
          final result = await LastFmApiClient(apiKey: 'key', dio: dio)
              .getSimilarTracksResult(
                artist: 'Band',
                track: 'Song (Remastered 2011)',
              );

          expect(result.outcome, LastFmFetchOutcome.success);
          expect(result.tracks.single.title, 'Match');
          expect(requests.map((r) => r['track']), [
            'Song (Remastered 2011)',
            'Song',
          ]);
        },
      );
    }

    test('an empty final result is not cached for 24 hours', () async {
      final root = await Directory.systemTemp.createTemp('lastfm-empty-');
      addTearDown(() async => root.delete(recursive: true));
      var now = DateTime.utc(2026, 10, 22);
      final cache = IntegrationJsonCache(
        readRootDirectory: () async => root,
        now: () => now,
      );
      final requests = <Map<String, dynamic>>[];
      final dio = routedDio({
        'track.getsimilar': (_) => emptySimilar,
        'artist.getsimilar': (_) => <String, dynamic>{
          'similarartists': {'artist': <dynamic>[]},
        },
      }, requests);
      final client = LastFmApiClient(apiKey: 'key', dio: dio, cache: cache);
      Future<LastFmFetchOutcome> ask() async =>
          (await client.getSimilarTracksResult(
            artist: 'Band',
            track: 'Song',
          )).outcome;

      expect(await ask(), LastFmFetchOutcome.noResults);
      final firstRound = requests.length;
      now = now.add(const Duration(minutes: 31));
      expect(await ask(), LastFmFetchOutcome.noResults);
      expect(requests.length, greaterThan(firstRound));
    });

    test('a fallback result is cached with the tracks it found', () async {
      final root = await Directory.systemTemp.createTemp('lastfm-fallback-');
      addTearDown(() async => root.delete(recursive: true));
      final cache = IntegrationJsonCache(readRootDirectory: () async => root);
      final requests = <Map<String, dynamic>>[];
      final dio = routedDio({
        'track.getsimilar': (_) => emptySimilar,
        'artist.getsimilar': (_) => similarArtists([('Alpha', 1.0)]),
        'artist.gettoptracks': (params) =>
            topTracks(params['artist'] as String, 2),
      }, requests);
      final client = LastFmApiClient(apiKey: 'key', dio: dio, cache: cache);
      final first = await client.getSimilarTracksResult(
        artist: 'Band',
        track: 'Song',
      );
      expect(first.tracks, hasLength(2));
      final seen = requests.length;
      final second = await client.getSimilarTracksResult(
        artist: 'Band',
        track: 'Song',
      );
      expect(
        second.tracks.map((t) => t.title),
        first.tracks.map((t) => t.title),
      );
      expect(requests, hasLength(seen));
    });

    test(
      'a final "Track not found" is kept for ten minutes, not re-asked',
      () async {
        final root = await Directory.systemTemp.createTemp('lastfm-code6-');
        addTearDown(() async => root.delete(recursive: true));
        var now = DateTime.utc(2026, 10, 22);
        final cache = IntegrationJsonCache(
          readRootDirectory: () async => root,
          now: () => now,
        );
        final requests = <Map<String, dynamic>>[];
        final dio = routedDio({
          'track.getsimilar': (_) => {'error': 6, 'message': 'Track not found'},
          'artist.getsimilar': (_) => {
            'error': 6,
            'message': 'Artist not found',
          },
        }, requests);
        final client = LastFmApiClient(apiKey: 'key', dio: dio, cache: cache);
        Future<void> ask() =>
            client.getSimilarTracksResult(artist: 'Band', track: 'Song');

        await ask();
        final firstRound = requests.length;
        await ask();
        expect(requests, hasLength(firstRound));
        now = now.add(const Duration(minutes: 11));
        await ask();
        expect(requests.length, greaterThan(firstRound));
      },
    );

    test('an error from the similar-artist request caches an empty answer '
        'for ten minutes only', () async {
      final root = await Directory.systemTemp.createTemp('lastfm-art29-');
      addTearDown(() async => root.delete(recursive: true));
      var now = DateTime.utc(2026, 10, 22);
      final cache = IntegrationJsonCache(
        readRootDirectory: () async => root,
        now: () => now,
      );
      final requests = <Map<String, dynamic>>[];
      final dio = routedDio({
        'track.getsimilar': (_) => emptySimilar,
        'artist.getsimilar': (_) => {'error': 29, 'message': 'limit'},
      }, requests);
      final client = LastFmApiClient(apiKey: 'key', dio: dio, cache: cache);
      Future<LastFmFetchOutcome> ask() async =>
          (await client.getSimilarTracksResult(
            artist: 'Band',
            track: 'Song',
          )).outcome;

      expect(await ask(), LastFmFetchOutcome.noResults);
      final firstRound = requests.length;
      expect(await ask(), LastFmFetchOutcome.noResults);
      expect(requests, hasLength(firstRound));
      now = now.add(const Duration(minutes: 11));
      await ask();
      expect(requests.length, greaterThan(firstRound));
    });

    test('a cache entry in the old format reads as a miss', () async {
      final root = await Directory.systemTemp.createTemp('lastfm-oldcache-');
      addTearDown(() async => root.delete(recursive: true));
      final cache = IntegrationJsonCache(readRootDirectory: () async => root);
      await cache.write(
        LastFmApiClient.similarTracksNamespace,
        jsonEncode(['band', 'song']),
        <String, Object?>{
          'limit': 20,
          'data': similarTracks([('Old', 'Entry')]),
        },
        ttl: const Duration(hours: 24),
      );
      final requests = <Map<String, dynamic>>[];
      final dio = routedDio({
        'track.getsimilar': (_) => similarTracks([('New', 'Answer')]),
      }, requests);
      final result = await LastFmApiClient(
        apiKey: 'key',
        dio: dio,
        cache: cache,
      ).getSimilarTracksResult(artist: 'Band', track: 'Song');

      expect(requests, hasLength(1));
      expect(result.tracks.single.title, 'Answer');
    });

    test('at most five similar artists get a top-tracks request', () async {
      final requests = <Map<String, dynamic>>[];
      final dio = routedDio({
        'track.getsimilar': (_) => emptySimilar,
        'artist.getsimilar': (_) => similarArtists([
          for (var i = 0; i < 10; i++) ('Artist $i', 1.0 - i / 20),
        ]),
        'artist.gettoptracks': (params) =>
            topTracks(params['artist'] as String, 3),
      }, requests);
      final result = await LastFmApiClient(
        apiKey: 'key',
        dio: dio,
      ).getSimilarTracksResult(artist: 'Seed', track: 'Song', limit: 20);

      final charts = requests.where(
        (r) => (r['method'] as String).toLowerCase() == 'artist.gettoptracks',
      );
      expect(charts, hasLength(5));
      expect(result.tracks, hasLength(15));
    });

    test('the seed artist is not its own similar artist', () async {
      final requests = <Map<String, dynamic>>[];
      final dio = routedDio({
        'track.getsimilar': (_) => emptySimilar,
        'artist.getsimilar': (_) =>
            similarArtists([('SEED  Artist!', 1.0), ('Alpha', 0.8)]),
        'artist.gettoptracks': (params) =>
            topTracks(params['artist'] as String, 1),
      }, requests);
      final result = await LastFmApiClient(
        apiKey: 'key',
        dio: dio,
      ).getSimilarTracksResult(artist: 'seed artist', track: 'Song');

      expect(result.tracks.map((t) => t.artist), ['Alpha']);
    });
  });
}
