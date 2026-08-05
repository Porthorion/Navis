import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/api/subsonic_error.dart';

void main() {
  SubsonicApiClient createClient({
    required Dio dio,
  }) {
    return SubsonicApiClient(
      baseUrl: 'https://example.com',
      authConfig: const SubsonicAuthConfig(
        username: 'alice',
        password: 'secret',
        apiVersion: '1.16.1',
      ),
      dio: dio,
      enableLogging: false,
    );
  }

  Map<String, dynamic> ok(Map<String, dynamic> payload) {
    return <String, dynamic>{
      'subsonic-response': <String, dynamic>{
        'status': 'ok',
        'version': '1.16.1',
        ...payload,
      },
    };
  }

  group('SubsonicApiClient', () {
    test('ping succeeds and returns server api version', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
      late RequestOptions captured;
      createClient(dio: dio);

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured = options;
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: ok(const <String, dynamic>{}),
              ),
            );
          },
        ),
      );

      final version = await createClient(dio: dio).ping();

      expect(captured.path, '/rest/ping.view');
      expect(captured.queryParameters['f'], 'json');
      expect(version, '1.16.1');
    });

    test('ping falls back to configured api version when missing', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
      final client = createClient(dio: dio);

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{
                  'subsonic-response': const <String, dynamic>{'status': 'ok'},
                },
              ),
            );
          },
        ),
      );

      final version = await client.ping();
      expect(version, '1.16.1');
    });

    test('parses OpenSubsonic extensions', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
      final client = createClient(dio: dio);

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: ok(<String, dynamic>{
                  'openSubsonicExtensions': <String, dynamic>{
                    'openSubsonicExtension': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'name': 'transcodeOffset',
                        'versions': <String>['1'],
                      },
                    ],
                  },
                }),
              ),
            );
          },
        ),
      );

      final capabilities = await client.getOpenSubsonicExtensions();
      expect(capabilities.extensions, hasLength(1));
      expect(capabilities.extensions.first.name, 'transcodeOffset');
    });

    test('getIndexes parses changed artist payload with timestamp', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
      final client = createClient(dio: dio);
      late RequestOptions captured;

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured = options;
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: ok(<String, dynamic>{
                  'indexes': <String, dynamic>{
                    'lastModified': '1739980000000',
                    'index': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'name': 'A',
                        'artist': <Map<String, dynamic>>[
                          <String, dynamic>{'id': 'a1', 'name': 'Artist 1'},
                        ],
                      },
                    ],
                    'shortcut': <Map<String, dynamic>>[
                      <String, dynamic>{'id': 'a2', 'name': 'Artist 2'},
                    ],
                  },
                }),
              ),
            );
          },
        ),
      );

      final since = DateTime.utc(2025, 1, 1);
      final indexes = await client.getIndexes(ifModifiedSince: since);

      expect(captured.path, '/rest/getIndexes.view');
      expect(
        captured.queryParameters['ifModifiedSince'],
        since.millisecondsSinceEpoch,
      );
      expect(indexes.indexes, hasLength(1));
      expect(indexes.indexes.first.artists.single.id, 'a1');
      expect(indexes.shortcut.single.id, 'a2');
      expect(indexes.lastModified, isNotNull);
    });

    test('getIndexes handles missing lists safely', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
      final client = createClient(dio: dio);

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: ok(<String, dynamic>{
                  'indexes': const <String, dynamic>{},
                }),
              ),
            );
          },
        ),
      );

      final indexes = await client.getIndexes();
      expect(indexes.indexes, isEmpty);
      expect(indexes.shortcut, isEmpty);
      expect(indexes.child, isEmpty);
      expect(indexes.lastModified, isNull);
    });

    test(
      'getArtistInfo2 deduplicates similar artists by id preserving order',
      () async {
        final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
        final client = createClient(dio: dio);
        late RequestOptions captured;

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              captured = options;
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: ok(<String, dynamic>{
                    'artistInfo2': <String, dynamic>{
                      'similarArtist': <Map<String, dynamic>>[
                        <String, dynamic>{'id': 'a1', 'name': 'Alpha'},
                        <String, dynamic>{
                          'id': 'a1',
                          'name': 'Alpha Duplicate',
                        },
                        <String, dynamic>{'id': 'a2', 'name': 'Beta'},
                        <String, dynamic>{'id': 'A2', 'name': 'Beta Again'},
                      ],
                    },
                  }),
                ),
              );
            },
          ),
        );

        final info = await client.getArtistInfo2('artist-1');

        expect(captured.path, '/rest/getArtistInfo2.view');
        expect(captured.queryParameters['id'], 'artist-1');
        expect(info.similarArtists.map((artist) => artist.id), <String>[
          'a1',
          'a2',
        ]);
        expect(info.similarArtists.map((artist) => artist.name), <String>[
          'Alpha',
          'Beta',
        ]);
      },
    );

    test(
      'getGenres skips malformed genres and parses numeric fields',
      () async {
        final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
        final client = createClient(dio: dio);

        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: ok(<String, dynamic>{
                    'genres': <String, dynamic>{
                      'genre': <Map<String, dynamic>>[
                        <String, dynamic>{'name': null, 'songCount': 7},
                        <String, dynamic>{
                          'name': ' Rock ',
                          'songCount': '10',
                          'albumCount': '2',
                        },
                        <String, dynamic>{'name': ''},
                        <String, dynamic>{'songCount': 3},
                        <String, dynamic>{
                          'name': 'Jazz',
                          'songCount': 4.0,
                          'albumCount': 1,
                        },
                      ],
                    },
                  }),
                ),
              );
            },
          ),
        );

        final genres = await client.getGenres();
        expect(genres, hasLength(2));
        expect(genres.first.name, 'Rock');
        expect(genres.first.songCount, 10);
        expect(genres.first.albumCount, 2);
        expect(genres.last.name, 'Jazz');
        expect(genres.last.songCount, 4);
        expect(genres.last.albumCount, 1);
      },
    );

    test('parses one endpoint per category', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
      final client = createClient(dio: dio);

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            switch (options.path) {
              case '/rest/getArtists.view':
                handler.resolve(
                  Response<dynamic>(
                    requestOptions: options,
                    statusCode: 200,
                    data: ok(<String, dynamic>{
                      'artists': <String, dynamic>{
                        'index': <Map<String, dynamic>>[
                          <String, dynamic>{
                            'artist': <Map<String, dynamic>>[
                              <String, dynamic>{'id': 'a1', 'name': 'A'},
                            ],
                          },
                        ],
                      },
                    }),
                  ),
                );
              case '/rest/getAlbumList2.view':
                handler.resolve(
                  Response<dynamic>(
                    requestOptions: options,
                    statusCode: 200,
                    data: ok(<String, dynamic>{
                      'albumList2': <String, dynamic>{
                        'album': <Map<String, dynamic>>[
                          <String, dynamic>{'id': 'al1', 'name': 'Album 1'},
                        ],
                      },
                    }),
                  ),
                );
              case '/rest/search3.view':
                handler.resolve(
                  Response<dynamic>(
                    requestOptions: options,
                    statusCode: 200,
                    data: ok(<String, dynamic>{
                      'searchResult3': <String, dynamic>{
                        'artist': <Map<String, dynamic>>[
                          <String, dynamic>{'id': 'a1', 'name': 'A'},
                        ],
                        'album': <Map<String, dynamic>>[
                          <String, dynamic>{'id': 'al1', 'name': 'Album 1'},
                        ],
                        'song': <Map<String, dynamic>>[
                          <String, dynamic>{'id': 's1', 'title': 'Song 1'},
                        ],
                      },
                    }),
                  ),
                );
              case '/rest/getPlaylists.view':
                handler.resolve(
                  Response<dynamic>(
                    requestOptions: options,
                    statusCode: 200,
                    data: ok(<String, dynamic>{
                      'playlists': <String, dynamic>{
                        'playlist': <Map<String, dynamic>>[
                          <String, dynamic>{'id': 'p1', 'name': 'Playlist'},
                        ],
                      },
                    }),
                  ),
                );
              case '/rest/getLyricsBySongId.view':
                handler.resolve(
                  Response<dynamic>(
                    requestOptions: options,
                    statusCode: 200,
                    data: ok(<String, dynamic>{
                      'lyricsList': <String, dynamic>{
                        'structuredLyrics': <Map<String, dynamic>>[
                          <String, dynamic>{
                            'lang': 'en',
                            'line': <Map<String, dynamic>>[
                              <String, dynamic>{'start': 0, 'value': 'line'},
                            ],
                          },
                        ],
                      },
                    }),
                  ),
                );
              case '/rest/getInternetRadioStations.view':
                handler.resolve(
                  Response<dynamic>(
                    requestOptions: options,
                    statusCode: 200,
                    data: ok(<String, dynamic>{
                      'internetRadioStations': <String, dynamic>{
                        'internetRadioStation': <Map<String, dynamic>>[
                          <String, dynamic>{
                            'id': 'r1',
                            'name': 'Station 1',
                            'streamUrl': 'https://radio.example.com/stream',
                          },
                        ],
                      },
                    }),
                  ),
                );
              case '/rest/star.view':
                handler.resolve(
                  Response<dynamic>(
                    requestOptions: options,
                    statusCode: 200,
                    data: ok(const <String, dynamic>{}),
                  ),
                );
              default:
                handler.reject(
                  DioException(
                    requestOptions: options,
                    type: DioExceptionType.badResponse,
                  ),
                );
            }
          },
        ),
      );

      final artists = await client.getArtists();
      final albums = await client.getAlbumList2(type: 'newest');
      final search = await client.search3(query: 'q');
      final playlists = await client.getPlaylists();
      final lyrics = await client.getLyricsBySongId('s1');
      final stations = await client.getInternetRadioStations();
      await client.star('s1');

      expect(artists.first.id, 'a1');
      expect(albums.first.id, 'al1');
      expect(search.songs.first.id, 's1');
      expect(playlists.first.id, 'p1');
      expect(lyrics.structuredLyrics.first.line.first.value, 'line');
      expect(stations.single.id, 'r1');
    });

    test('getAlbum maps Subsonic song payload into album songs', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
      final client = createClient(dio: dio);

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/rest/getAlbum.view') {
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: ok(<String, dynamic>{
                    'album': <String, dynamic>{
                      'id': 'al1',
                      'name': 'Album 1',
                      'song': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'id': 's1',
                          'title': 'Song 1',
                          'albumId': 'al1',
                        },
                      ],
                    },
                  }),
                ),
              );
              return;
            }
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
              ),
            );
          },
        ),
      );

      final album = await client.getAlbum('al1');
      expect(album.id, 'al1');
      expect(album.songs, hasLength(1));
      expect(album.songs.single.id, 's1');
    });

    test('forwards cancel token', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
      final client = createClient(dio: dio);
      final token = CancelToken();

      late RequestOptions captured;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured = options;
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: ok(<String, dynamic>{
                  'searchResult3': const <String, dynamic>{},
                }),
              ),
            );
          },
        ),
      );

      await client.search3(query: 'hello', cancelToken: token);
      expect(captured.cancelToken, same(token));
    });

    test('maps API error codes to typed exceptions', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
      final client = createClient(dio: dio);

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{
                  'subsonic-response': <String, dynamic>{
                    'status': 'failed',
                    'error': <String, dynamic>{
                      'code': 40,
                      'message': 'bad credentials',
                    },
                  },
                },
              ),
            );
          },
        ),
      );

      await expectLater(
        client.ping(),
        throwsA(isA<SubsonicAuthException>()),
      );
    });

    test(
      'maps HTTP 530 into SubsonicGenericException with status code',
      () async {
        final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
        final client = createClient(dio: dio);

        // Disable default client interceptors to avoid retry backoff in this unit test.
        dio.interceptors.clear();
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.badResponse,
                  response: Response<dynamic>(
                    requestOptions: options,
                    statusCode: 530,
                    statusMessage: 'Origin DNS error',
                  ),
                ),
                true,
              );
            },
          ),
        );

        await expectLater(
          client.ping(),
          throwsA(
            predicate<Object>(
              (error) => error is SubsonicGenericException && error.code == 530,
            ),
          ),
        );
      },
    );

    test('builds media urls without fetching', () {
      final client = createClient(
        dio: Dio(BaseOptions(baseUrl: 'https://example.com')),
      );

      final stream = client.streamUrl(
        id: 'song-1',
        maxBitRate: 320,
        format: 'mp3',
      );
      final download = client.downloadUrl(id: 'song-1');
      final cover = client.getCoverArtUrl(id: 'cover-1', size: 500);

      expect(stream.path, '/rest/stream.view');
      expect(stream.queryParameters['id'], 'song-1');
      expect(download.path, '/rest/download.view');
      expect(download.queryParameters['id'], 'song-1');
      expect(cover.path, '/rest/getCoverArt.view');
      expect(cover.queryParameters['id'], 'cover-1');
      expect(cover.queryParameters['size'], '500');
    });

    test('rejects responses that exceed the byte budget', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
      final client = createClient(dio: dio);
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                headers: Headers.fromMap(<String, List<String>>{
                  Headers.contentLengthHeader: <String>['2048'],
                }),
                data: ok(<String, dynamic>{
                  'album': <String, dynamic>{
                    'id': 'a1',
                    'name': 'Album',
                    'song': const <Map<String, dynamic>>[],
                  },
                }),
              ),
            );
          },
        ),
      );

      await expectLater(
        client.getAlbum('a1', maxResponseBytes: 1024),
        throwsA(isA<SubsonicResponseBudgetExceededException>()),
      );
    });

    test('disables transport retries when requested', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
      final client = createClient(dio: dio);
      var calls = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            calls++;
            expect(options.extra['navisDisableRetry'], isTrue);
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionTimeout,
              ),
            );
          },
        ),
      );

      await expectLater(
        client.getIndexes(disableRetry: true),
        throwsA(isA<SubsonicConnectionException>()),
      );
      expect(calls, 1);
    });
  });
}
