import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/data/scrobble_service.dart';

import '../../../../helpers/test_database.dart';

class _FakeSubsonicApiClient extends SubsonicApiClient {
  new()
    : super(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
        ),
        enableLogging: false,
      );

  final List<({String songId, bool submission, DateTime? time})> calls =
      <({String songId, bool submission, DateTime? time})>[];
  Exception? nextError;

  @override
  Future<void> scrobble(
    String id, {
    bool submission = false,
    DateTime? time,
    CancelToken? cancelToken,
  }) async {
    calls.add((songId: id, submission: submission, time: time));
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
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(id: 'song-1', title: 'Song 1'),
        SongsTableCompanion.insert(id: 'song-2', title: 'Song 2'),
      ]);
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
      expect(apiClient.calls[0].songId, 'song-1');
      expect(apiClient.calls[0].submission, isFalse);
      expect(apiClient.calls[0].time!.isAtSameMomentAs(now), isTrue);
      expect(apiClient.calls[1].songId, 'song-1');
      expect(apiClient.calls[1].submission, isTrue);
      expect(apiClient.calls[1].time!.isAtSameMomentAs(now), isTrue);
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
        expect(queued.single.lastError, '_Exception');
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

    test(
      'flushDue keeps Subsonic events queued when API client is unavailable',
      () async {
        final service = DriftScrobbleService(
          dao: database.scrobbleDao,
          readApiClient: () => null,
          readScrobbleEnabled: () => true,
          readReachable: () => reachable,
          now: () => now,
        );

        await service.enqueueSubmission(songId: 'song-1', sessionKey: 's4');
        await service.flushDue();

        final queued = await database.select(database.scrobbleQueueTable).get();
        expect(queued.length, 1);
        expect(queued.single.provider, ScrobbleProvider.subsonic.id);
      },
      skip: !sqliteAvailable,
    );

    test('enqueueSubmission records Subsonic and ListenBrainz providers independently', () async {
      final service = DriftScrobbleService(
        dao: database.scrobbleDao,
        readApiClient: () => apiClient,
        readScrobbleEnabled: () => scrobbleEnabled,
        readListenBrainzCredentials: () async =>
            const ListenBrainzScrobbleCredentials(
              userToken: 'listenbrainz-token',
            ),
        readReachable: () => reachable,
        now: () => now,
      );

      await service.enqueueSubmission(
        songId: 'song-1',
        sessionKey: 's5',
        track: const ScrobbleTrackPayload(
          songId: 'song-1',
          title: 'Song 1',
          artist: 'Artist',
        ),
      );

      final queued = await database.select(database.scrobbleQueueTable).get();
      expect(queued.map((row) => row.provider).toSet(), {
        ScrobbleProvider.subsonic.id,
        ScrobbleProvider.listenBrainz.id,
      });
      expect(
        queued.where((row) => row.provider != ScrobbleProvider.subsonic.id),
        everyElement(
          isA<ScrobbleQueueTableData>()
              .having((row) => row.trackTitle, 'trackTitle', 'Song 1')
              .having((row) => row.artistName, 'artistName', 'Artist'),
        ),
      );
    }, skip: !sqliteAvailable);

    test(
      'flushDue drops queued Last.fm events from older app versions',
      () async {
        final service = DriftScrobbleService(
          dao: database.scrobbleDao,
          readApiClient: () => apiClient,
          readScrobbleEnabled: () => scrobbleEnabled,
          readReachable: () => reachable,
          now: () => now,
        );
        await database.scrobbleDao.enqueue(
          provider: ScrobbleProvider.lastFm.id,
          songId: 'song-1',
          sessionKey: 'legacy',
          submission: true,
          trackTitle: 'Song 1',
          artistName: 'Artist',
          createdAt: now,
          nextAttemptAt: now,
          expiresAt: now.add(const Duration(days: 2)),
        );

        await service.flushDue();

        final queued = await database.select(database.scrobbleQueueTable).get();
        expect(queued, isEmpty);
        expect(apiClient.calls, isEmpty);
      },
      skip: !sqliteAvailable,
    );
  });
}
