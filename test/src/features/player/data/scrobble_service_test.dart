import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/data/scrobble_service.dart';
import '../../../../helpers/test_database.dart';

class _FakeSubsonicApiClient extends SubsonicApiClient {
  _FakeSubsonicApiClient()
    : super(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
        ),
        enableLogging: false,
      );

  final List<({String songId, bool submission})> calls =
      <({String songId, bool submission})>[];
  Exception? nextError;

  @override
  Future<void> scrobble(
    String id, {
    bool submission = false,
    CancelToken? cancelToken,
  }) async {
    calls.add((songId: id, submission: submission));
    final error = nextError;
    if (error != null) {
      throw error;
    }
  }
}

void main() {
  group('DriftScrobbleService', () {
    late NavisDatabase database;
    late _FakeSubsonicApiClient apiClient;
    late DateTime now;
    late bool scrobbleEnabled;
    late bool reachable;

    setUp(() async {
      database = NavisDatabase(NativeDatabase.memory());
      apiClient = _FakeSubsonicApiClient();
      now = DateTime.utc(2026, 1, 1, 0, 0, 0);
      scrobbleEnabled = true;
      reachable = true;
      await database.libraryDao.upsertSongs(
        <SongsTableCompanion>[
          SongsTableCompanion.insert(id: 'song-1', title: 'Song 1'),
          SongsTableCompanion.insert(id: 'song-2', title: 'Song 2'),
        ],
      );
    });

    tearDown(() async {
      await database.close();
    });

    test('flushDue delivers due events and removes them', () async {
      final service = DriftScrobbleService(
        dao: database.scrobbleDao,
        readApiClient: () => apiClient,
        readScrobbleEnabled: () => scrobbleEnabled,
        readReachable: () => reachable,
        now: () => now,
      );

      await service.enqueueNowPlaying(songId: 'song-1', sessionKey: 's1');
      await service.enqueueSubmission(songId: 'song-1', sessionKey: 's1');

      await service.flushDue();

      final queued = await database.select(database.scrobbleQueueTable).get();
      expect(queued, isEmpty);
      expect(apiClient.calls.length, 2);
      expect(apiClient.calls[0], (songId: 'song-1', submission: false));
      expect(apiClient.calls[1], (songId: 'song-1', submission: true));
    }, skip: !sqliteAvailable);

    test(
      'flushDue reschedules failed delivery with exponential backoff',
      () async {
        final service = DriftScrobbleService(
          dao: database.scrobbleDao,
          readApiClient: () => apiClient,
          readScrobbleEnabled: () => scrobbleEnabled,
          readReachable: () => reachable,
          now: () => now,
        );
        apiClient.nextError = Exception('network timeout');

        await service.enqueueSubmission(songId: 'song-2', sessionKey: 's2');
        await service.flushDue();

        final queued = await database.select(database.scrobbleQueueTable).get();
        expect(queued.length, 1);
        expect(queued.single.attempts, 1);
        expect(queued.single.lastError, contains('network timeout'));
        expect(
          queued.single.nextAttemptAt.isAtSameMomentAs(
            now.add(const Duration(seconds: 15)),
          ),
          isTrue,
        );
      },
      skip: !sqliteAvailable,
    );

    test('flushDue clears queue when scrobbling is disabled', () async {
      final service = DriftScrobbleService(
        dao: database.scrobbleDao,
        readApiClient: () => apiClient,
        readScrobbleEnabled: () => scrobbleEnabled,
        readReachable: () => reachable,
        now: () => now,
      );

      await service.enqueueNowPlaying(songId: 'song-1', sessionKey: 's3');
      scrobbleEnabled = false;
      await service.flushDue();

      final queued = await database.select(database.scrobbleQueueTable).get();
      expect(queued, isEmpty);
      expect(apiClient.calls, isEmpty);
    }, skip: !sqliteAvailable);
  });
}
