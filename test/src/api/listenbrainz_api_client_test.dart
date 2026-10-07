import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/listenbrainz_api_client.dart';

class _MockDio extends Mock implements Dio;

void main() {
  setUpAll(() {
    registerFallbackValue(Options());
    registerFallbackValue(<String, Object?>{});
  });

  test('validateTokenDetails parses validity and username', () async {
    final dio = _MockDio();
    when(
      () => dio.get<Map<String, dynamic>>(
        '/validate-token',
        options: any(named: 'options'),
      ),
    ).thenAnswer(
      (_) async => Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(path: '/validate-token'),
        data: <String, dynamic>{'valid': true, 'user_name': 'alice'},
      ),
    );

    final details = await ListenBrainzApiClient(dio: dio)
        .validateTokenDetails('token');

    expect(details.valid, isTrue);
    expect(details.userName, 'alice');
  });

  test('getRecommendationPlaylists parses JSPF playlist metadata', () async {
    final dio = _MockDio();
    when(
      () => dio.get<Map<String, dynamic>>(
        '/user/alice/playlists/recommendations',
        options: any(named: 'options'),
      ),
    ).thenAnswer(
      (_) async => Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(
          path: '/user/alice/playlists/recommendations',
        ),
        data: <String, dynamic>{
          'playlists': <String, dynamic>{
            'playlist': <Map<String, dynamic>>[
              <String, dynamic>{
                'identifier': <String>[
                  'https://musicbrainz.org/playlist/11111111-1111-1111-1111-111111111111',
                ],
                'title': 'Weekly Exploration',
                'creator': 'ListenBrainz',
                'annotation': 'Fresh recommendations',
                'extension': <String, dynamic>{
                  'https://musicbrainz.org/doc/jspf#playlist':
                      <String, dynamic>{
                        'additional_metadata': <String, dynamic>{
                          'algorithm_metadata': <String, dynamic>{
                            'source_patch': 'weekly-exploration',
                          },
                        },
                      },
                },
              },
            ],
          },
        },
      ),
    );

    final playlists = await ListenBrainzApiClient(dio: dio)
        .getRecommendationPlaylists(userName: 'alice', userToken: 'token');

    expect(playlists, hasLength(1));
    expect(playlists.single.identifier, '11111111-1111-1111-1111-111111111111');
    expect(playlists.single.title, 'Weekly Exploration');
    expect(playlists.single.description, 'Fresh recommendations');
    expect(playlists.single.sourcePatch, 'weekly-exploration');
    expect(playlists.single.recommendationDisplayTitle, 'Weekly Exploration');
  });

  test('getPlaylist preserves JSPF track metadata', () async {
    final dio = _MockDio();
    when(
      () => dio.get<Map<String, dynamic>>(
        '/playlist/11111111-1111-1111-1111-111111111111',
        queryParameters: any(named: 'queryParameters'),
        options: any(named: 'options'),
      ),
    ).thenAnswer((invocation) async {
      final params =
          invocation.namedArguments[#queryParameters] as Map<String, Object?>;
      expect(params['fetch_metadata'], isTrue);
      return Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(
          path: '/playlist/11111111-1111-1111-1111-111111111111',
        ),
        data: <String, dynamic>{
          'playlist': <String, dynamic>{
            'identifier': 'https://musicbrainz.org/playlist/11111111-1111-1111-1111-111111111111',
            'title': 'Weekly Exploration',
            'track': <String, dynamic>{
              'track': <Map<String, dynamic>>[
                <String, dynamic>{
                  'title': 'Song A',
                  'creator': 'Artist A',
                  'album': 'Album A',
                  'duration': 181000,
                  'identifier': <String>[
                    'https://musicbrainz.org/recording/22222222-2222-2222-2222-222222222222',
                  ],
                  'extension': <String, dynamic>{
                    'https://musicbrainz.org/doc/jspf#track': <String, dynamic>{
                      'additional_metadata': <String, dynamic>{
                        'recording_msid': 'msid-1',
                      },
                    },
                  },
                },
              ],
            },
          },
        },
      );
    });

    final playlist = await ListenBrainzApiClient(
      dio: dio,
    ).getPlaylist('11111111-1111-1111-1111-111111111111', userToken: 'token');

    expect(playlist.tracks, hasLength(1));
    expect(playlist.tracks.single.title, 'Song A');
    expect(playlist.tracks.single.creator, 'Artist A');
    expect(playlist.tracks.single.album, 'Album A');
    expect(playlist.tracks.single.durationSeconds, 181);
    expect(playlist.tracks.single.recordingMsid, 'msid-1');
    expect(playlist.tracks.single.raw, contains('identifier'));
  });

  test(
    'getPlaylist parses detail payload with tracks directly on playlist',
    () async {
      final dio = _MockDio();
      when(
        () => dio.get<Map<String, dynamic>>(
          '/playlist/55555555-5555-5555-5555-555555555555',
          queryParameters: any(named: 'queryParameters'),
          options: any(named: 'options'),
        ),
      ).thenAnswer(
        (_) async => Response<Map<String, dynamic>>(
          requestOptions: RequestOptions(
            path: '/playlist/55555555-5555-5555-5555-555555555555',
          ),
          data: <String, dynamic>{
            'playlist': <String, dynamic>{
              'identifier': 'https://musicbrainz.org/playlist/55555555-5555-5555-5555-555555555555',
              'title': 'Weekly Jams',
              'track': <Map<String, dynamic>>[
                <String, dynamic>{
                  'title': 'Direct Song',
                  'creator': 'Direct Artist',
                  'extension': <String, dynamic>{
                    'https://musicbrainz.org/doc/jspf#track': <String, dynamic>{
                      'additional_metadata': <String, dynamic>{
                        'recording_mbid':
                            '66666666-6666-6666-6666-666666666666',
                      },
                    },
                  },
                },
              ],
            },
          },
        ),
      );

      final playlist = await ListenBrainzApiClient(
        dio: dio,
      ).getPlaylist('55555555-5555-5555-5555-555555555555', userToken: 'token');

      expect(playlist.tracks, hasLength(1));
      expect(playlist.tracks.single.title, 'Direct Song');
      expect(playlist.tracks.single.creator, 'Direct Artist');
      expect(
        playlist.tracks.single.recordingMbid,
        '66666666-6666-6666-6666-666666666666',
      );
    },
  );

  test('submitRecordingFeedback posts MBID score with auth', () async {
    final dio = _MockDio();
    when(
      () => dio.post<void>(
        '/feedback/recording-feedback',
        data: any(named: 'data'),
        options: any(named: 'options'),
      ),
    ).thenAnswer(
      (_) async => Response<void>(
        requestOptions: RequestOptions(path: '/feedback/recording-feedback'),
      ),
    );

    await ListenBrainzApiClient(dio: dio).submitRecordingFeedback(
      userToken: 'token',
      recordingMbid: '22222222-2222-2222-2222-222222222222',
      score: 1,
    );

    final captured = verify(
      () => dio.post<void>(
        '/feedback/recording-feedback',
        data: captureAny(named: 'data'),
        options: captureAny(named: 'options'),
      ),
    ).captured;
    expect(captured[0], <String, Object>{
      'recording_mbid': '22222222-2222-2222-2222-222222222222',
      'score': 1,
    });
    final options = captured[1] as Options;
    expect(options.headers?['Authorization'], 'Token token');
  });

  test('submitRecordingFeedback maps invalid token response', () async {
    final dio = _MockDio();
    when(
      () => dio.post<void>(
        '/feedback/recording-feedback',
        data: any(named: 'data'),
        options: any(named: 'options'),
      ),
    ).thenThrow(
      DioException(
        requestOptions: RequestOptions(path: '/feedback/recording-feedback'),
        response: Response<void>(
          requestOptions: RequestOptions(path: '/feedback/recording-feedback'),
          statusCode: 401,
        ),
      ),
    );

    expect(
      () => ListenBrainzApiClient(dio: dio).submitRecordingFeedback(
        userToken: 'bad-token',
        recordingMbid: '22222222-2222-2222-2222-222222222222',
        score: 0,
      ),
      throwsA(isA<ListenBrainzInvalidTokenException>()),
    );
  });

  test('lookupRecordingMbid parses MBID and sends auth', () async {
    final dio = _MockDio();
    when(
      () => dio.get<Map<String, dynamic>>(
        '/metadata/lookup',
        queryParameters: any(named: 'queryParameters'),
        options: any(named: 'options'),
      ),
    ).thenAnswer(
      (_) async => Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(path: '/metadata/lookup'),
        data: <String, dynamic>{
          'recording_mbid': '33333333-3333-3333-3333-333333333333',
        },
      ),
    );

    final mbid = await ListenBrainzApiClient(dio: dio).lookupRecordingMbid(
      userToken: 'token',
      title: 'Song A',
      artist: 'Artist A',
      album: 'Album A',
    );

    expect(mbid, '33333333-3333-3333-3333-333333333333');
    final captured = verify(
      () => dio.get<Map<String, dynamic>>(
        '/metadata/lookup',
        queryParameters: captureAny(named: 'queryParameters'),
        options: captureAny(named: 'options'),
      ),
    ).captured;
    expect(captured[0], <String, Object>{
      'recording_name': 'Song A',
      'artist_name': 'Artist A',
      'release_name': 'Album A',
    });
    final options = captured[1] as Options;
    expect(options.headers?['Authorization'], 'Token token');
  });

  test('lookupRecordingMbid handles empty match', () async {
    final dio = _MockDio();
    when(
      () => dio.get<Map<String, dynamic>>(
        '/metadata/lookup',
        queryParameters: any(named: 'queryParameters'),
        options: any(named: 'options'),
      ),
    ).thenAnswer(
      (_) async => Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(path: '/metadata/lookup'),
        data: const <String, dynamic>{},
      ),
    );

    final mbid = await ListenBrainzApiClient(dio: dio).lookupRecordingMbid(
      userToken: 'token',
      title: 'Song A',
      artist: 'Artist A',
    );

    expect(mbid, isNull);
  });
}
