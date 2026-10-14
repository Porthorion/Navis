import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/listenbrainz_api_client.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/daos/scrobble_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/player/data/scrobble_service.dart';
import 'package:navis/src/features/settings/data/external_scrobble_credentials.dart';

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
  Completer<void>? gate;
  Completer<void>? entered;

  @override
  Future<void> scrobble(
    String id, {
    bool submission = false,
    DateTime? time,
    CancelToken? cancelToken,
  }) async {
    calls.add((songId: id, submission: submission, time: time));
    entered?.complete();
    await gate?.future;
    final error = nextError;
    if (error != null) {
      throw error;
    }
  }
}

class _MockScrobbleDao extends Mock implements ScrobbleDao;
class _MockSecureStorage extends Mock implements FlutterSecureStorage;

/// A ListenBrainz client that accepts every listen without touching the
/// network, counting submissions in [requests].
ListenBrainzApiClient _acceptingListenBrainzClient(List<int> requests) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        requests.add(1);
        handler.resolve(
          Response<void>(requestOptions: options, statusCode: 200),
        );
      },
    ),
  );
  return ListenBrainzApiClient(dio: dio);
}

void main() {
  group('DriftScrobbleService', () {
    late NavisDatabase database;
    late _FakeSubsonicApiClient apiClient;
    late DateTime now;
    late bool scrobbleEnabled;
    late bool reachable;

    setUp(() async {
      database = createTestDatabase();
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

    test('disposing during a flush cannot restart dispatch timers', () async {
      final timers = <Timer>[];
      final service = DriftScrobbleService(
        dao: database.scrobbleDao,
        readApiClient: () => apiClient,
        readScrobbleEnabled: () => true,
        readReachable: () => true,
        now: () => now,
      );
      addTearDown(() async {
        await service.dispose();
        for (final timer in timers) {
          timer.cancel();
        }
      });
      final gate = Completer<void>();
      final entered = Completer<void>();
      apiClient
        ..gate = gate
        ..entered = entered
        ..nextError = Exception('fixture failure');
      await runZoned(
        () async {
          await service.enqueueSubmission(
            songId: 'song-1',
            sessionKey: 'in-flight',
          );
          service.start();
          final flush = service.flushDue();
          await entered.future;
          await service.dispose();
          gate.complete();
          await flush;
          expect(timers.where((timer) => timer.isActive), isEmpty);
        },
        zoneSpecification: ZoneSpecification(
          createPeriodicTimer: (self, parent, zone, duration, callback) {
            final timer = parent.createPeriodicTimer(zone, duration, callback);
            timers.add(timer);
            return timer;
          },
        ),
      );
    }, skip: !sqliteAvailable);

    for (final locked in [false, true]) {
      test(
        'disposing during timer sync cannot schedule timers (locked=$locked)',
        () async {
          final dao = _MockScrobbleDao();
          final count = Completer<int>();
          final entered = Completer<void>();
          when(dao.countEntries).thenAnswer((_) {
            entered.complete();
            return count.future;
          });
          final timers = <Timer>[];
          final service = DriftScrobbleService(
            dao: dao,
            readApiClient: () => null,
            readScrobbleEnabled: () => true,
            readReachable: () => false,
          );
          addTearDown(() async {
            await service.dispose();
            for (final timer in timers) {
              timer.cancel();
            }
          });
          await runZoned(
            () async {
              service.start();
              await entered.future;
              await service.dispose();
              if (locked) {
                count.completeError(StateError('database is locked'));
              } else {
                count.complete(1);
              }
              await pumpEventQueue();
              expect(timers.where((timer) => timer.isActive), isEmpty);
            },
            zoneSpecification: ZoneSpecification(
              createTimer: (self, parent, zone, duration, callback) {
                final timer = parent.createTimer(zone, duration, callback);
                timers.add(timer);
                return timer;
              },
              createPeriodicTimer: (self, parent, zone, duration, callback) {
                final timer = parent.createPeriodicTimer(
                  zone,
                  duration,
                  callback,
                );
                timers.add(timer);
                return timer;
              },
            ),
          );
        },
      );
    }
    test(
      'ListenBrainz cooldown defers later events while Subsonic continues',
      () async {
        var requests = 0;
        final dio = Dio();
        addTearDown(dio.close);
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests++;
              handler.resolve(
                Response<void>(
                  requestOptions: options,
                  statusCode: 200,
                  headers: Headers.fromMap(
                    requests == 1
                        ? {
                            'X-RateLimit-Remaining': ['0'],
                            'X-RateLimit-Reset-In': ['60'],
                          }
                        : {},
                  ),
                ),
              );
            },
          ),
        );
        final client = ListenBrainzApiClient(dio: dio, now: () => now);
        final service = DriftScrobbleService(
          dao: database.scrobbleDao,
          readApiClient: () => apiClient,
          readScrobbleEnabled: () => true,
          readReachable: () => true,
          now: () => now,
          readListenBrainzCredentials: () async =>
              const ListenBrainzScrobbleCredentials(userToken: 'fixture'),
          createListenBrainzClient: () => client,
        );
        addTearDown(service.dispose);
        for (final id in ['song-1', 'song-2']) {
          await service.enqueueSubmission(
            songId: id,
            sessionKey: id,
            track: ScrobbleTrackPayload(
              songId: id,
              title: 'Fixture Track',
              artist: 'Fixture Artist',
            ),
          );
        }
        await service.flushDue();
        expect(requests, 1);
        expect(apiClient.calls, hasLength(2));
        final queued = await database.select(database.scrobbleQueueTable).get();
        expect(queued, hasLength(1));
        expect(queued.single.provider, 'listenbrainz');
        expect(queued.single.attempts, 0);
        now = now.add(const Duration(seconds: 59));
        await service.flushDue();
        expect(requests, 1);
        now = now.add(const Duration(seconds: 1));
        await service.flushDue();
        expect(requests, 2);
        expect(await database.scrobbleDao.countEntries(), 0);
      },
      skip: !sqliteAvailable,
    );

    test(
      'unavailable ListenBrainz retains queued listens and token validity',
      () async {
        final dio = Dio();
        addTearDown(dio.close);
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.reject(
              DioException(
                requestOptions: options,
                response: Response<Object?>(
                  requestOptions: options,
                  statusCode: 404,
                ),
              ),
            ),
          ),
        );
        var invalidated = false;
        final service = DriftScrobbleService(
          dao: database.scrobbleDao,
          readApiClient: () => apiClient,
          readScrobbleEnabled: () => false,
          readReachable: () => true,
          now: () => now,
          readListenBrainzCredentials: () async =>
              const ListenBrainzScrobbleCredentials(userToken: 'fixture'),
          createListenBrainzClient: () => ListenBrainzApiClient(dio: dio),
          onListenBrainzInvalidToken: () => invalidated = true,
        );
        addTearDown(service.dispose);
        await service.enqueueSubmission(
          songId: 'song-1',
          sessionKey: 'fixture',
          track: const ScrobbleTrackPayload(
            songId: 'song-1',
            title: 'Track',
            artist: 'Artist',
          ),
        );
        await service.flushDue();
        final queued = await database.select(database.scrobbleQueueTable).get();
        expect(queued, hasLength(1));
        expect(queued.single.attempts, 1);
        expect(invalidated, isFalse);
      },
      skip: !sqliteAvailable,
    );

    test(
      'storage failure does not drop a ListenBrainz entry beside Subsonic',
      () async {
        final storage = _MockSecureStorage();
        when(
          () => storage.read(key: 'navis.external_scrobble.listenbrainz.token'),
        ).thenThrow(PlatformException(code: 'keystore_busy'));
        final service = DriftScrobbleService(
          dao: database.scrobbleDao,
          readApiClient: () => apiClient,
          readScrobbleEnabled: () => true,
          readReachable: () => true,
          now: () => now,
          readListenBrainzCredentials: () =>
              readListenBrainzScrobbleCredentials(
                policy: const IntegrationPolicy(listenBrainzVerified: true),
                readToken: () =>
                    FlutterExternalScrobbleCredentialStore(storage: storage)
                        .readListenBrainzToken(),
              ),
        );
        addTearDown(service.dispose);
        await service.enqueueSubmission(
          songId: 'song-1',
          sessionKey: 'fixture',
          track: const ScrobbleTrackPayload(
            songId: 'song-1',
            title: 'Track',
            artist: 'Artist',
          ),
        );

        await service.flushDue();

        expect(apiClient.calls, hasLength(1));
        final queued = await database.select(database.scrobbleQueueTable).get();
        expect(queued, hasLength(1));
        expect(queued.single.provider, ScrobbleProvider.listenBrainz.id);
        expect(queued.single.attempts, 1);
      },
      skip: !sqliteAvailable,
    );

    test('Subsonic delivery continues while ListenBrainz credentials are unreadable', () async {
      var credentialsReadable = true;
      final listenBrainzRequests = <int>[];
      final service = DriftScrobbleService(
        dao: database.scrobbleDao,
        readApiClient: () => apiClient,
        readScrobbleEnabled: () => true,
        readReachable: () => true,
        now: () => now,
        readListenBrainzCredentials: () async {
          if (!credentialsReadable) throw const CredentialReadException();
          return const ListenBrainzScrobbleCredentials(userToken: 'fixture');
        },
        createListenBrainzClient: () =>
            _acceptingListenBrainzClient(listenBrainzRequests),
      );
      addTearDown(service.dispose);
      await service.enqueueSubmission(
        songId: 'song-1',
        sessionKey: 'fixture',
        track: const ScrobbleTrackPayload(
          songId: 'song-1',
          title: 'Track',
          artist: 'Artist',
        ),
      );

      credentialsReadable = false;
      await service.flushDue();

      expect(apiClient.calls, hasLength(1));
      final queued = await database.select(database.scrobbleQueueTable).get();
      expect(queued, hasLength(1));
      expect(queued.single.provider, ScrobbleProvider.listenBrainz.id);
      expect(queued.single.attempts, 1);

      credentialsReadable = true;
      now = now.add(const Duration(seconds: 15));
      await service.flushDue();
      expect(await database.scrobbleDao.countEntries(), 0);
      expect(listenBrainzRequests, hasLength(1));
    }, skip: !sqliteAvailable);

    test(
      'ListenBrainz entries stay queued when the token cannot be read',
      () async {
        var credentialsReadable = true;
        final listenBrainzRequests = <int>[];
        final service = DriftScrobbleService(
          dao: database.scrobbleDao,
          readApiClient: () => apiClient,
          readScrobbleEnabled: () => false,
          readReachable: () => true,
          now: () => now,
          readListenBrainzCredentials: () async {
            if (!credentialsReadable) throw const CredentialReadException();
            return const ListenBrainzScrobbleCredentials(userToken: 'fixture');
          },
          createListenBrainzClient: () =>
              _acceptingListenBrainzClient(listenBrainzRequests),
        );
        addTearDown(service.dispose);
        await service.enqueueSubmission(
          songId: 'song-1',
          sessionKey: 'fixture',
          track: const ScrobbleTrackPayload(
            songId: 'song-1',
            title: 'Track',
            artist: 'Artist',
          ),
        );

        credentialsReadable = false;
        await service.flushDue();

        final queued = await database.select(database.scrobbleQueueTable).get();
        expect(queued, hasLength(1));
        expect(queued.single.attempts, 1);

        credentialsReadable = true;
        now = now.add(const Duration(seconds: 15));
        await service.flushDue();
        expect(await database.scrobbleDao.countEntries(), 0);
        expect(apiClient.calls, isEmpty);
        expect(listenBrainzRequests, hasLength(1));
      },
      skip: !sqliteAvailable,
    );

    test(
      'enqueue still queues ListenBrainz while credentials are unreadable',
      () async {
        final service = DriftScrobbleService(
          dao: database.scrobbleDao,
          readApiClient: () => apiClient,
          readScrobbleEnabled: () => true,
          readReachable: () => true,
          now: () => now,
          readListenBrainzCredentials: () async =>
              throw const CredentialReadException(),
        );
        addTearDown(service.dispose);
        await service.enqueueSubmission(
          songId: 'song-1',
          sessionKey: 'fixture',
          track: const ScrobbleTrackPayload(
            songId: 'song-1',
            title: 'Track',
            artist: 'Artist',
          ),
        );

        final queued = await database.select(database.scrobbleQueueTable).get();
        expect(queued.map((row) => row.provider).toSet(), {
          ScrobbleProvider.subsonic.id,
          ScrobbleProvider.listenBrainz.id,
        });
      },
      skip: !sqliteAvailable,
    );

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

  group('readListenBrainzScrobbleCredentials policy gate', () {
    const verified = IntegrationPolicy(listenBrainzVerified: true);

    test('returns the trimmed token while allowed', () async {
      final credentials = await readListenBrainzScrobbleCredentials(
        policy: verified,
        readToken: () async => '  secret-token  ',
      );
      expect(credentials?.userToken, 'secret-token');
    });

    for (final entry in <String, IntegrationPolicy>{
      'the feature switch is off': const IntegrationPolicy(
        listenBrainzVerified: true,
        disabledKeys: {'listenbrainz.scrobbling'},
      ),
      'the ListenBrainz service is off': const IntegrationPolicy(
        listenBrainzVerified: true,
        disabledKeys: {'listenbrainz'},
      ),
      'the master switch is off': const IntegrationPolicy(
        listenBrainzVerified: true,
        masterEnabled: false,
      ),
      'the token is not validated': const IntegrationPolicy(),
    }.entries) {
      test('never reads the token when ${entry.key}', () async {
        var tokenReads = 0;
        final credentials = await readListenBrainzScrobbleCredentials(
          policy: entry.value,
          readToken: () async {
            tokenReads++;
            return 'secret-token';
          },
        );
        expect(credentials, isNull);
        expect(tokenReads, 0);
      });
    }

    test('returns null without a stored token', () async {
      expect(
        await readListenBrainzScrobbleCredentials(
          policy: verified,
          readToken: () async => '  ',
        ),
        isNull,
      );
      expect(
        await readListenBrainzScrobbleCredentials(
          policy: verified,
          readToken: () async => null,
        ),
        isNull,
      );
    });

    test('read failures propagate as unavailable', () async {
      await expectLater(
        readListenBrainzScrobbleCredentials(
          policy: verified,
          readToken: () async => throw const CredentialReadException(),
        ),
        throwsA(isA<CredentialReadException>()),
      );
    });
  });
}
