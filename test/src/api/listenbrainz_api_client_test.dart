import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/listenbrainz_api_client.dart';

class _MockDio extends Mock implements Dio {}

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
        data: <String, dynamic>{
          'valid': true,
          'user_name': 'alice',
        },
      ),
    );

    final details = await ListenBrainzApiClient(
      dio: dio,
    ).validateTokenDetails('token');

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
              },
            ],
          },
        },
      ),
    );

    final playlists = await ListenBrainzApiClient(
      dio: dio,
    ).getRecommendationPlaylists(userName: 'alice', userToken: 'token');

    expect(playlists, hasLength(1));
    expect(playlists.single.identifier, '11111111-1111-1111-1111-111111111111');
    expect(playlists.single.title, 'Weekly Exploration');
    expect(playlists.single.description, 'Fresh recommendations');
  });

  test('getPlaylist preserves JSPF track metadata', () async {
    final dio = _MockDio();
    when(
      () => dio.get<Map<String, dynamic>>(
        '/playlist/11111111-1111-1111-1111-111111111111',
        queryParameters: any(named: 'queryParameters'),
        options: any(named: 'options'),
      ),
    ).thenAnswer(
      (_) async => Response<Map<String, dynamic>>(
        requestOptions: RequestOptions(
          path: '/playlist/11111111-1111-1111-1111-111111111111',
        ),
        data: <String, dynamic>{
          'playlist': <String, dynamic>{
            'identifier':
                'https://musicbrainz.org/playlist/11111111-1111-1111-1111-111111111111',
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
      ),
    );

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
}
