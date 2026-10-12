import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';

class _Adapter implements HttpClientAdapter {
  Future<void> Function()? beforeResponse;
  Map<String, Object?> payload = {
    'status': 'ok',
    'artists': <String, Object?>{},
    'artist': {'id': 'artist', 'name': 'Artist'},
    'album': {'id': 'album', 'name': 'Album', 'songCount': 0},
    'playlist': {'id': 'playlist', 'name': 'Playlist', 'songCount': 0},
    'starred2': <String, Object?>{},
    'scanStatus': {'scanning': false},
    'searchResult3': <String, Object?>{},
    'albumList2': <String, Object?>{},
    'indexes': <String, Object?>{},
    'playlists': <String, Object?>{},
  };
  int requestCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    await beforeResponse?.call();
    return ResponseBody.fromString(
      jsonEncode({'subsonic-response': payload}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _Adapter adapter;
  late SubsonicLibrarySyncApi api;
  late List<CancelToken> tokens;
  late List<DioException> errors;

  setUp(() {
    adapter = _Adapter();
    tokens = [];
    errors = [];
    final dio = Dio()..httpClientAdapter = adapter;
    final client = SubsonicApiClient(
      baseUrl: 'https://example.com',
      authConfig: const SubsonicAuthConfig(
        username: 'fixture',
        password: 'fixture',
        apiVersion: '1.16.1',
      ),
      dio: dio,
      enableLogging: false,
    );
    addTearDown(client.close);
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          tokens.add(options.cancelToken!);
          handler.next(options);
        },
        onError: (error, handler) {
          errors.add(error);
          handler.next(error);
        },
      ),
    );
    api = SubsonicLibrarySyncApi(client)..beginRun();
  });

  test(
    'sync requests use distinct tokens and release completed tokens',
    () async {
      await api.getArtists();
      await api.getArtist('artist', maxResponseBytes: 10000);
      await api.getAlbum('album', maxResponseBytes: 10000);
      await api.getPlaylist('playlist', maxResponseBytes: 10000);
      await api.getStarredContent();
      await api.getScanStatusOrNull();
      for (var offset = 0; offset < 3; offset++) {
        await api.searchSongsPage(query: '', size: 1, offset: offset);
      }
      await api.getAlbumListPage(size: 1, offset: 0);
      await api.getNewestAlbumListPage(size: 1, offset: 0);
      await api.getIndexes(
        ifModifiedSince: DateTime.utc(2026),
        disableRetry: true,
      );
      await api.getPlaylists();

      expect(tokens, hasLength(13));
      expect(Set<CancelToken>.identity()..addAll(tokens), hasLength(13));

      // A later cancellation must not reach tokens from completed requests.
      api.cancelActiveRequests();
      expect(tokens.every((token) => !token.isCancelled), isTrue);
    },
  );

  test('failed requests also release their tokens', () async {
    adapter.payload = {
      'status': 'failed',
      'error': {'code': 70, 'message': 'Fixture not found'},
    };
    await expectLater(
      api.getAlbum('missing'),
      throwsA(isA<SubsonicNotFoundException>()),
    );
    expect(await api.getScanStatusOrNull(), isNull);

    api.cancelActiveRequests();
    expect(tokens, hasLength(2));
    expect(tokens.every((token) => !token.isCancelled), isTrue);
  });

  test(
    'cancellation stops every in-flight request with the existing mapping',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      adapter.beforeResponse = () {
        if (adapter.requestCount == 2) started.complete();
        return release.future;
      };
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final first = expectLater(
        api.getArtists(),
        throwsA(isA<SubsonicConnectionException>()),
      );
      final second = expectLater(
        api.getPlaylists(),
        throwsA(isA<SubsonicConnectionException>()),
      );
      await started.future;

      api.cancelActiveRequests();
      await Future.wait([first, second]);
      expect(tokens, hasLength(2));
      expect(tokens.every((token) => token.isCancelled), isTrue);
      expect(errors, hasLength(2));
      for (final error in errors) {
        expect(error.type, DioExceptionType.cancel);
        expect(error.error, 'library sync cancelled');
      }
    },
  );

  test('requests stay cancelled until beginRun resets cancellation', () async {
    api.cancelActiveRequests();
    for (var i = 0; i < 2; i++) {
      await expectLater(
        api.getArtists(),
        throwsA(
          isA<SubsonicConnectionException>().having(
            (error) => error.message,
            'message',
            'The request was manually cancelled by the user.',
          ),
        ),
      );
    }
    expect(adapter.requestCount, 0);
    // Dio rejects pre-cancelled tokens before invoking its interceptors.
    expect(tokens, isEmpty);
    expect(errors, isEmpty);

    api.beginRun();
    expect(await api.getArtists(), isEmpty);
    expect(adapter.requestCount, 1);
    expect(tokens.single.isCancelled, isFalse);
  });
}
