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
      await client.getSimilarTracks(
        artist: 'Fixture  Artist',
        track: ' Track ',
        limit: 2,
      ),
      hasLength(2),
    );
    // A new client shares the disk entry; no process-local cache is required.
    final next = LastFmApiClient(apiKey: 'fixture', dio: dio, cache: cache);
    expect(
      await next.getSimilarTracks(
        artist: 'fixture artist',
        track: 'track',
        limit: 1,
      ),
      hasLength(1),
    );
    expect(requests, 1);
    now = now.add(const Duration(hours: 24));
    await next.getSimilarTracks(
      artist: 'fixture artist',
      track: 'track',
      limit: 2,
    );
    expect(requests, 2);
    await next.getSimilarTracks(
      artist: 'fixture artist',
      track: 'other',
      limit: 2,
    );
    expect(requests, 3);
    await next.getSimilarTracks(
      artist: 'fixture artist',
      track: 'track',
      limit: 3,
    );
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
    expect(requests, 2);
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
    final recs = await client.getSimilarTracks(
      artist: 'Seed Artist',
      track: 'Seed Song',
      limit: 10,
    );

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
    final recs = await client.getSimilarTracks(
      artist: 'Unknown',
      track: 'Unknown',
    );

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
    final recs = await client.getSimilarTracks(
      artist: 'Artist',
      track: 'Track',
    );
    expect(client.isConfigured, isFalse);
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
}
