import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/common_widgets/song_playback_indicator.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/sync_diagnostics_server.dart';
import 'package:path/path.dart' as p;

import '../../helpers/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('diagnostics API requires its random bearer token', () async {
    final fixture = await _startFixture(SyncDiagnosticsMode.clone);
    addTearDown(fixture.close);

    final unauthorized = await _request(
      fixture.port,
      '/v1/health',
    );
    expect(unauthorized.statusCode, HttpStatus.unauthorized);

    final authorized = await _request(
      fixture.port,
      '/v1/health',
      token: fixture.token,
    );
    expect(authorized.statusCode, HttpStatus.ok);
    expect(authorized.body['mode'], 'clone');
    expect(authorized.body['schemaVersion'], 60);
  });

  test('primary certification rejects mutation and cancellation', () async {
    final fixture = await _startFixture(
      SyncDiagnosticsMode.primaryCertification,
    );
    addTearDown(fixture.close);

    final cancel = await _request(
      fixture.port,
      '/v1/sync/cancel',
      method: 'POST',
      token: fixture.token,
    );
    expect(cancel.statusCode, HttpStatus.forbidden);

    final mutation = await _request(
      fixture.port,
      '/v1/diagnostics/local-mutation',
      method: 'POST',
      token: fixture.token,
      body: <String, Object?>{
        'type': 'song',
        'id': 'song-1',
        'field': 'starred',
        'value': true,
      },
    );
    expect(mutation.statusCode, HttpStatus.forbidden);

    final restore = await _request(
      fixture.port,
      '/v1/diagnostics/restore-server-star',
      method: 'POST',
      token: fixture.token,
      body: <String, Object?>{'songId': 'song-1', 'liked': false},
    );
    expect(restore.statusCode, HttpStatus.forbidden);
  });

  test('clone local mutation remains pending for sync precedence', () async {
    final fixture = await _startFixture(SyncDiagnosticsMode.clone);
    addTearDown(fixture.close);

    final mutation = await _request(
      fixture.port,
      '/v1/diagnostics/local-mutation',
      method: 'POST',
      token: fixture.token,
      body: <String, Object?>{
        'type': 'song',
        'id': 'song-1',
        'field': 'starred',
        'value': true,
      },
    );

    expect(mutation.statusCode, HttpStatus.ok);
    final pending = await fixture.database.starSyncDao.getPendingActions();
    expect(pending, hasLength(1));
    expect(pending.single.itemId, 'song-1');
    expect(pending.single.action, 'star');
  });

  test('clone mode accepts diagnostics override mutations', () async {
    final fixture = await _startFixture(SyncDiagnosticsMode.clone);
    addTearDown(fixture.close);

    final response = await _request(
      fixture.port,
      '/v1/diagnostics/overrides',
      method: 'POST',
      token: fixture.token,
      body: <String, Object?>{
        'networkType': 'cellular',
        'nativeMetered': true,
        'requestReporting': true,
      },
    );

    expect(response.statusCode, HttpStatus.ok);
    expect(response.body['networkType'], 'cellular');
    expect(response.body['requestReporting'], isTrue);

    final cleared = await _request(
      fixture.port,
      '/v1/diagnostics/overrides',
      method: 'POST',
      token: fixture.token,
      body: const <String, Object?>{},
    );
    expect(cleared.statusCode, HttpStatus.ok);
    expect(cleared.body['networkType'], isNull);
    expect(cleared.body['nativeMetered'], isNull);
  });

  test(
    'primary certification rejects diagnostics override mutations',
    () async {
      final fixture = await _startFixture(
        SyncDiagnosticsMode.primaryCertification,
      );
      addTearDown(fixture.close);

      final response = await _request(
        fixture.port,
        '/v1/diagnostics/overrides',
        method: 'POST',
        token: fixture.token,
        body: <String, Object?>{'networkType': 'cellular'},
      );

      expect(response.statusCode, HttpStatus.forbidden);
    },
  );

  test('handshake is removed when the diagnostics server closes', () async {
    final fixture = await _startFixture(SyncDiagnosticsMode.clone);
    expect(await fixture.handshake.exists(), isTrue);

    await fixture.close();

    expect(await fixture.handshake.exists(), isFalse);
  });

  test(
    'song indicator endpoint is authenticated, validated, and sanitized',
    () async {
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        playbackSnapshot: const PlaybackSnapshot(
          queueSongIds: <String>['song-1'],
          currentSongId: 'song-1',
          currentIndex: 0,
          playing: false,
          processingState: AudioProcessingState.ready,
          position: Duration.zero,
          duration: Duration(minutes: 3),
          bufferedPosition: Duration.zero,
          shuffleMode: AudioServiceShuffleMode.none,
          repeatMode: AudioServiceRepeatMode.none,
        ),
      );
      addTearDown(fixture.close);

      final unauthorized = await _request(
        fixture.port,
        '/v1/presentation/song-indicator?songId=song-1',
      );
      expect(unauthorized.statusCode, HttpStatus.unauthorized);

      final invalid = await _request(
        fixture.port,
        '/v1/presentation/song-indicator',
        token: fixture.token,
      );
      expect(invalid.statusCode, HttpStatus.badRequest);

      expect(
        fixture.container.read(
          songPlaybackIndicatorStateProvider('song-1'),
        ),
        SongPlaybackIndicatorState.current,
      );
      final current = await _request(
        fixture.port,
        '/v1/presentation/song-indicator?songId=song-1',
        token: fixture.token,
      );
      expect(current.statusCode, HttpStatus.ok);
      expect(current.body, <String, Object?>{
        'state': 'current',
        'selected': true,
        'markerRole': 'equalizer',
        'semanticRole': 'nowPlaying',
        'backgroundColorRole': 'primaryTint08',
        'foregroundColorRole': 'primary',
      });

      final inactive = await _request(
        fixture.port,
        '/v1/presentation/song-indicator?songId=song-2',
        token: fixture.token,
      );
      expect(inactive.body['state'], 'inactive');
      expect(inactive.body['selected'], isFalse);
      expect(inactive.body.containsKey('songId'), isFalse);
    },
  );

  test(
    'song indicator endpoint exposes the loading presentation state',
    () async {
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        playbackSnapshot: const PlaybackSnapshot(
          queueSongIds: <String>['song-1', 'song-2'],
          currentSongId: 'song-1',
          currentIndex: 1,
          playing: true,
          processingState: AudioProcessingState.loading,
          position: Duration.zero,
          duration: Duration(minutes: 3),
          bufferedPosition: Duration.zero,
          shuffleMode: AudioServiceShuffleMode.none,
          repeatMode: AudioServiceRepeatMode.none,
          isLoading: true,
          loadingSongId: 'song-2',
        ),
      );
      addTearDown(fixture.close);

      final response = await _request(
        fixture.port,
        '/v1/presentation/song-indicator?songId=song-2',
        token: fixture.token,
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(response.body['state'], 'loading');
      expect(response.body['markerRole'], 'progress');
      expect(response.body['semanticRole'], 'nowPlaying');
    },
  );

  test(
    'volume API uses production controller and persists mute state',
    () async {
      final handler = _MockPlaybackHandler();
      var handlerVolume = 1.0;
      when(() => handler.loadFailureStream).thenAnswer(
        (_) => const Stream<PlaybackLoadFailure>.empty(),
      );
      when(handler.waitUntilReady).thenAnswer((_) async {});
      when(() => handler.setVolume(any())).thenAnswer((invocation) async {
        handlerVolume = invocation.positionalArguments.single as double;
      });
      when(handler.collectPlaybackDiagnostics).thenAnswer(
        (_) => <String, Object?>{
          'userVolume': handlerVolume,
          'effectivePlayerVolume': handlerVolume,
        },
      );
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        handler: handler,
      );
      addTearDown(fixture.close);
      fixture.container
          .read(playbackVolumeProvider.notifier)
          .hydrate(
            volume: 1,
            lastAudibleVolume: 1,
          );

      final invalid = await _request(
        fixture.port,
        '/v1/playback/volume',
        method: 'POST',
        token: fixture.token,
        body: <String, Object?>{'value': 2},
      );
      expect(invalid.statusCode, HttpStatus.badRequest);

      final set = await _request(
        fixture.port,
        '/v1/playback/volume',
        method: 'POST',
        token: fixture.token,
        body: <String, Object?>{'value': 0.37},
      );
      expect(set.statusCode, HttpStatus.ok);
      expect(set.body['volume'], 0.37);
      expect(set.body['persistedVolume'], 0.37);
      expect(set.body['handlerUserVolume'], 0.37);

      final muted = await _request(
        fixture.port,
        '/v1/playback/volume/toggle-mute',
        method: 'POST',
        token: fixture.token,
      );
      expect(muted.statusCode, HttpStatus.ok);
      expect(muted.body['volume'], 0);
      expect(muted.body['lastAudibleVolume'], 0.37);
      expect(muted.body['persistedLastAudibleVolume'], 0.37);

      final observed = await _request(
        fixture.port,
        '/v1/playback/volume',
        token: fixture.token,
      );
      expect(observed.statusCode, HttpStatus.ok);
      expect(observed.body['persistedVolume'], 0);
    },
  );

  test('primary certification observes volume but rejects mutation', () async {
    final handler = _MockPlaybackHandler();
    when(() => handler.loadFailureStream).thenAnswer(
      (_) => const Stream<PlaybackLoadFailure>.empty(),
    );
    when(handler.waitUntilReady).thenAnswer((_) async {});
    when(handler.collectPlaybackDiagnostics).thenReturn(<String, Object?>{
      'userVolume': 1.0,
      'effectivePlayerVolume': 1.0,
    });
    final fixture = await _startFixture(
      SyncDiagnosticsMode.primaryCertification,
      handler: handler,
    );
    addTearDown(fixture.close);
    fixture.container
        .read(playbackVolumeProvider.notifier)
        .hydrate(volume: 1, lastAudibleVolume: 1);

    final observed = await _request(
      fixture.port,
      '/v1/playback/volume',
      token: fixture.token,
    );
    expect(observed.statusCode, HttpStatus.ok);
    expect(observed.body['desktopPersistenceEnabled'], isTrue);

    final response = await _request(
      fixture.port,
      '/v1/playback/volume',
      method: 'POST',
      token: fixture.token,
      body: <String, Object?>{'value': 0.37},
    );
    expect(response.statusCode, HttpStatus.forbidden);
  });

  test(
    'source audit is authenticated, sanitized, and classifies mixed rows',
    () async {
      final fixture = await _startFixture(
        SyncDiagnosticsMode.clone,
        api: _SourceAuditApiClient(),
      );
      addTearDown(fixture.close);
      await fixture.database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(id: 'server-artist', name: 'Local Artist'),
      ]);

      final unauthorized = await _request(
        fixture.port,
        '/v1/search/source-audit',
        method: 'POST',
        body: const <String, Object?>{'query': 'mixed'},
      );
      expect(unauthorized.statusCode, HttpStatus.unauthorized);

      final response = await _request(
        fixture.port,
        '/v1/search/source-audit',
        method: 'POST',
        token: fixture.token,
        body: const <String, Object?>{'query': 'mixed'},
      );
      expect(response.statusCode, HttpStatus.ok);
      final records = response.body['records'] as List<dynamic>;
      expect(records, hasLength(3));
      expect(
        records,
        contains(
          containsPair('source', 'remote'),
        ),
      );
      final local = records.cast<Map<String, dynamic>>().singleWhere(
        (record) => record['id'] == 'server-artist',
      );
      expect(local['locallyIndexed'], isTrue);
      expect(local['source'], 'onServer');
      for (final record in records.cast<Map<String, dynamic>>()) {
        expect(
          record.keys,
          unorderedEquals(<String>[
            'kind',
            'id',
            'displayLabel',
            'source',
            'apiIsExternal',
            'locallyIndexed',
            'isProvisional',
          ]),
        );
      }
    },
  );

  test('current diagnostics playback source is resumed, not replaced', () {
    const active = PlaybackSnapshot(
      queueSongIds: <String>['song-1'],
      currentSongId: 'song-1',
      currentIndex: 0,
      playing: false,
      processingState: AudioProcessingState.ready,
      position: Duration(seconds: 12),
      duration: Duration(minutes: 4),
      bufferedPosition: Duration(seconds: 30),
      shuffleMode: AudioServiceShuffleMode.none,
      repeatMode: AudioServiceRepeatMode.none,
    );

    expect(
      canResumeDiagnosticsPlayback(snapshot: active, songId: 'song-1'),
      isTrue,
    );
    expect(
      canResumeDiagnosticsPlayback(snapshot: active, songId: 'song-2'),
      isFalse,
    );
    expect(
      canResumeDiagnosticsPlayback(
        snapshot: const PlaybackSnapshot.idle(),
        songId: 'song-1',
      ),
      isFalse,
    );
  });
}

Future<_DiagnosticsFixture> _startFixture(
  SyncDiagnosticsMode mode, {
  SubsonicApiClient? api,
  NavisPlaybackHandler? handler,
  PlaybackSnapshot? playbackSnapshot,
}) async {
  final temp = await Directory.systemTemp.createTemp('navis_diagnostics_test_');
  final database = createTestDatabase();
  final container = ProviderContainer(
    overrides: [
      navisDatabaseProvider.overrideWith((ref) => database),
      audioHandlerProvider.overrideWith((ref) => handler),
      if (playbackSnapshot != null)
        playerStateProvider.overrideWithValue(playbackSnapshot),
      if (api != null) subsonicApiProvider.overrideWithValue(api),
    ],
  );
  final handshake = File(p.join(temp.path, 'handshake.json'));
  final server = SyncDiagnosticsServer(
    container: container,
    mode: mode,
    handshakePath: handshake.path,
    onShutdown: () async {},
  );
  await server.start();
  final value =
      jsonDecode(await handshake.readAsString()) as Map<String, dynamic>;
  return _DiagnosticsFixture(
    server: server,
    container: container,
    database: database,
    temp: temp,
    handshake: handshake,
    port: value['port'] as int,
    token: value['token'] as String,
  );
}

class _MockPlaybackHandler extends Mock implements NavisPlaybackHandler {}

class _SourceAuditApiClient extends SubsonicApiClient {
  _SourceAuditApiClient()
    : super(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'test',
          password: 'test',
          apiVersion: '1.16.1',
        ),
      );

  @override
  Future<SearchResult3> search3({
    required String query,
    int artistCount = 20,
    int artistOffset = 0,
    int albumCount = 20,
    int albumOffset = 0,
    int songCount = 20,
    int songOffset = 0,
    CancelToken? cancelToken,
  }) async {
    return const SearchResult3(
      artists: <Artist>[
        Artist(
          id: 'server-artist',
          name: 'Local Artist',
          isExternal: false,
        ),
      ],
      albums: <Album>[
        Album(id: 'ext-deezer-album-1', name: 'Remote Album'),
      ],
      songs: <Song>[
        Song(
          id: 'provider-song-1',
          title: 'Remote Song',
          isExternal: true,
        ),
      ],
    );
  }
}

Future<_Response> _request(
  int port,
  String path, {
  String method = 'GET',
  String? token,
  Map<String, Object?>? body,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    return _Response(
      statusCode: response.statusCode,
      body: jsonDecode(text) as Map<String, dynamic>,
    );
  } finally {
    client.close(force: true);
  }
}

class _DiagnosticsFixture {
  _DiagnosticsFixture({
    required this.server,
    required this.container,
    required this.database,
    required this.temp,
    required this.handshake,
    required this.port,
    required this.token,
  });

  final SyncDiagnosticsServer server;
  final ProviderContainer container;
  final dynamic database;
  final Directory temp;
  final File handshake;
  final int port;
  final String token;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await server.close();
    container.dispose();
    await database.close();
    await temp.delete(recursive: true);
  }
}

class _Response {
  const _Response({required this.statusCode, required this.body});

  final int statusCode;
  final Map<String, dynamic> body;
}
