import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/lastfm_api_client.dart';

class _MockDio extends Mock implements Dio {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(
      RequestOptions(path: '/'),
    );
  });

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
}
