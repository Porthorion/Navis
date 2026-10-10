import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/data/external_scrobble_credentials.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/data/sign_out_service.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/library/data/android_background_sync.dart';

import '../../../../helpers/test_database.dart';
import '../../../../helpers/library_sync_fakes.dart'
    show FakeSyncCredentialStore;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.navis.app/background_sync');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'late Android cancellation status is a no-op after a sign-out wipe',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await database.serverDao.saveServer(
        ServerConfigTableCompanion.insert(
          url: 'https://music.example.test',
          username: 'listener',
          apiVersion: '1.16.1',
        ),
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'cancel');
            entered.complete();
            await release.future;
            return <String, Object>{'available': true, 'state': 'cancelled'};
          });
      final reconciler = AndroidBackgroundSyncReconciler(
        database: database,
        scheduler: AndroidBackgroundSyncScheduler(
          channel: channel,
          supported: true,
        ),
      );
      final cancellation = reconciler.cancelFor(
        const ServerConfigModel(
          id: 1,
          url: 'https://music.example.test',
          username: 'listener',
          password: 'unused',
          apiVersion: '1.16.1',
        ),
      );
      final completed = expectLater(cancellation, completes);
      await entered.future;
      await SessionLifecycleService(
        credentials: CloneDiagnosticsExternalScrobbleCredentialStore(),
        serverConfigRepository: ServerConfigRepository(
          database,
          credentials: FakeSyncCredentialStore(),
        ),
        database: database,
      ).signOut(wipeLocalData: true);
      release.complete();
      await completed;
      expect(
        await database.select(database.librarySyncStateTable).get(),
        isEmpty,
      );
    },
    skip: !sqliteAvailable,
  );

  test('profile key is stable across harmless server URL normalization', () {
    final left = ServerConfigModel(
      url: 'HTTPS://Music.Example.test:443/rest/',
      username: ' listener ',
      password: 'unused',
      apiVersion: '1.16.1',
    );
    final right = ServerConfigModel(
      url: 'https://music.example.test/rest',
      username: 'listener',
      password: 'unused',
      apiVersion: '1.16.1',
    );

    final key = AndroidBackgroundSyncScheduler.profileKeyFor(left);
    expect(key, AndroidBackgroundSyncScheduler.profileKeyFor(right));
    expect(key, matches(RegExp(r'^[0-9a-f]{32}$')));
  });

  test('scheduler sends only opaque scheduling data to native code', () async {
    final profileKey = 'a'.padRight(32, 'a');
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          captured = call;
          return <String, Object>{
            'available': true,
            'state': 'scheduled',
            'workId': '76bceb9a-6e54-4f78-a07c-f5c33c2b591c',
            'attemptCount': 0,
          };
        });
    final scheduler = AndroidBackgroundSyncScheduler(
      channel: channel,
      supported: true,
    );

    final observation = await scheduler.configurePeriodic(
      profileKey: profileKey,
      intervalMinutes: 60,
      unmeteredOnly: true,
    );

    expect(captured?.method, 'configurePeriodic');
    expect(captured?.arguments, <String, Object>{
      'profileKey': profileKey,
      'intervalMinutes': 60,
      'unmeteredOnly': true,
    });
    expect(observation.state, 'scheduled');
    expect(observation.workId, isNotNull);
  });

  test('native status unavailability remains a bounded observation', () {
    final observation = AndroidBackgroundScheduleObservation.fromPlatform(
      <String, Object>{
        'available': true,
        'state': 'statusUnavailable',
        'workerResult': 'engineTimeout',
        'workerStopReason': 'engineTimeout',
      },
    );

    expect(observation.state, 'statusUnavailable');
    expect(observation.workerResult, 'engineTimeout');
    expect(observation.workerStopReason, 'engineTimeout');
  });

  test('reconciler persists bounded Android schedule observation', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    await database.serverDao.saveServer(
      ServerConfigTableCompanion.insert(
        url: 'https://music.example.test',
        username: 'listener',
        apiVersion: '1.16.1',
      ),
    );
    await database.librarySyncDao.setAndroidBackgroundSyncEnabled(
      serverId: 1,
      enabled: true,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'configurePeriodic');
          return <String, Object>{
            'available': true,
            'state': 'scheduled',
            'workId': '76bceb9a-6e54-4f78-a07c-f5c33c2b591c',
            'attemptCount': 2,
          };
        });
    final reconciler = AndroidBackgroundSyncReconciler(
      database: database,
      scheduler: AndroidBackgroundSyncScheduler(
        channel: channel,
        supported: true,
      ),
    );
    final config = ServerConfigModel(
      id: 1,
      url: 'https://music.example.test',
      username: 'listener',
      password: 'unused',
      apiVersion: '1.16.1',
    );

    await reconciler.reconcile(
      config: config,
      intervalMinutes: 60,
      unmeteredOnly: true,
    );

    final state = await database.librarySyncDao.getOrCreateState(1);
    expect(state.androidBackgroundSyncEnabled, isTrue);
    expect(state.androidRequestedIntervalMinutes, 60);
    expect(state.androidWorkState, 'scheduled');
    expect(state.androidWorkAttemptCount, 2);
    expect(state.androidScheduleReconciledAt, isNotNull);
  }, skip: !sqliteAvailable);

  test(
    'manual-only reconciliation clears the stale requested cadence',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await database.serverDao.saveServer(
        ServerConfigTableCompanion.insert(
          url: 'https://music.example.test',
          username: 'listener',
          apiVersion: '1.16.1',
        ),
      );
      await database.librarySyncDao.setAndroidBackgroundSyncEnabled(
        serverId: 1,
        enabled: true,
      );
      await database.librarySyncDao.writeAndroidBackgroundStatus(
        serverId: 1,
        requestedIntervalMinutes: 60,
        workId: '76bceb9a-6e54-4f78-a07c-f5c33c2b591c',
        workState: 'scheduled',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'cancel');
            return <String, Object>{'available': true, 'state': 'cancelled'};
          });
      final reconciler = AndroidBackgroundSyncReconciler(
        database: database,
        scheduler: AndroidBackgroundSyncScheduler(
          channel: channel,
          supported: true,
        ),
      );
      final config = ServerConfigModel(
        id: 1,
        url: 'https://music.example.test',
        username: 'listener',
        password: 'unused',
        apiVersion: '1.16.1',
      );

      await reconciler.reconcile(
        config: config,
        intervalMinutes: 0,
        unmeteredOnly: true,
      );

      final state = await database.librarySyncDao.getOrCreateState(1);
      expect(state.androidRequestedIntervalMinutes, isNull);
      expect(state.androidWorkId, isNull);
      expect(state.androidWorkState, 'cancelled');
    },
    skip: !sqliteAvailable,
  );

  test(
    'native schedule acknowledgement failure preserves a known-good cadence',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await database.serverDao.saveServer(
        ServerConfigTableCompanion.insert(
          url: 'https://music.example.test',
          username: 'listener',
          apiVersion: '1.16.1',
        ),
      );
      await database.librarySyncDao.setAndroidBackgroundSyncEnabled(
        serverId: 1,
        enabled: true,
      );
      await database.librarySyncDao.writeAndroidBackgroundStatus(
        serverId: 1,
        requestedIntervalMinutes: 60,
        workId: '76bceb9a-6e54-4f78-a07c-f5c33c2b591c',
        workState: 'scheduled',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'configurePeriodic');
            return <String, Object>{
              'available': true,
              'state': 'platformFailure',
            };
          });
      final reconciler = AndroidBackgroundSyncReconciler(
        database: database,
        scheduler: AndroidBackgroundSyncScheduler(
          channel: channel,
          supported: true,
        ),
      );
      final config = ServerConfigModel(
        id: 1,
        url: 'https://music.example.test',
        username: 'listener',
        password: 'unused',
        apiVersion: '1.16.1',
      );

      await reconciler.reconcile(
        config: config,
        intervalMinutes: 120,
        unmeteredOnly: true,
      );

      final state = await database.librarySyncDao.getOrCreateState(1);
      expect(state.androidRequestedIntervalMinutes, 60);
      expect(state.androidWorkId, '76bceb9a-6e54-4f78-a07c-f5c33c2b591c');
      expect(state.androidWorkState, 'platformFailure');
    },
    skip: !sqliteAvailable,
  );

  test('native cancellation acknowledgement failure preserves a known-good cadence', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    await database.serverDao.saveServer(
      ServerConfigTableCompanion.insert(
        url: 'https://music.example.test',
        username: 'listener',
        apiVersion: '1.16.1',
      ),
    );
    await database.librarySyncDao.setAndroidBackgroundSyncEnabled(
      serverId: 1,
      enabled: true,
    );
    await database.librarySyncDao.writeAndroidBackgroundStatus(
      serverId: 1,
      requestedIntervalMinutes: 60,
      workId: '76bceb9a-6e54-4f78-a07c-f5c33c2b591c',
      workState: 'scheduled',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'cancel');
          return <String, Object>{
            'available': true,
            'state': 'platformFailure',
          };
        });
    final reconciler = AndroidBackgroundSyncReconciler(
      database: database,
      scheduler: AndroidBackgroundSyncScheduler(
        channel: channel,
        supported: true,
      ),
    );
    final config = ServerConfigModel(
      id: 1,
      url: 'https://music.example.test',
      username: 'listener',
      password: 'unused',
      apiVersion: '1.16.1',
    );

    await reconciler.reconcile(
      config: config,
      intervalMinutes: 0,
      unmeteredOnly: true,
    );

    final state = await database.librarySyncDao.getOrCreateState(1);
    expect(state.androidRequestedIntervalMinutes, 60);
    expect(state.androidWorkId, '76bceb9a-6e54-4f78-a07c-f5c33c2b591c');
    expect(state.androidWorkState, 'platformFailure');
  }, skip: !sqliteAvailable);

  for (final category in ['engineTimeout', 'deferredPlayback']) {
    test('reconciler imports a redacted native $category outcome', () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await database.serverDao.saveServer(
        ServerConfigTableCompanion.insert(
          url: 'https://music.example.test',
          username: 'listener',
          apiVersion: '1.16.1',
        ),
      );
      await database.librarySyncDao.setAndroidBackgroundSyncEnabled(
        serverId: 1,
        enabled: true,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'status') {
              return <String, Object>{
                'available': true,
                'state': 'none',
                'workerResult': category,
                'workerStopReason': category,
              };
            }
            expect(call.method, 'configurePeriodic');
            return <String, Object>{'available': true, 'state': 'scheduled'};
          });
      final reconciler = AndroidBackgroundSyncReconciler(
        database: database,
        scheduler: AndroidBackgroundSyncScheduler(
          channel: channel,
          supported: true,
        ),
      );
      final config = ServerConfigModel(
        id: 1,
        url: 'https://music.example.test',
        username: 'listener',
        password: 'unused',
        apiVersion: '1.16.1',
      );

      await reconciler.reconcile(
        config: config,
        intervalMinutes: 60,
        unmeteredOnly: true,
      );

      final state = await database.librarySyncDao.getOrCreateState(1);
      expect(state.androidWorkerResult, category);
      expect(state.androidWorkerStopReason, category);
    }, skip: !sqliteAvailable);
  }
}
