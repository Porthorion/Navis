import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/library/domain/sync_run_contract.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/data/android_background_sync.dart';
import 'package:navis/src/features/library/data/android_background_sync_entrypoint.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';

import '../../../../helpers/test_database.dart';

class _WorkerCredentialStore implements SecureCredentialStore {
  new({required this.failRead, this.password});

  final bool failRead;
  final String? password;
  int clearCalls = 0;

  @override
  Future<String?> readPassword() async {
    if (failRead) throw const CredentialReadException();
    return password;
  }

  @override
  Future<void> savePassword(String password) async {}

  @override
  Future<void> clearPassword() async => clearCalls++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.navis.app/background_sync');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    messenger.setMockMethodCallHandler(channel, (_) async => false);
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final failRead in [false, true]) {
    test('worker handles credential read failure: $failRead', () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await database.serverDao.saveServer(
        ServerConfigTableCompanion.insert(
          url: 'https://example.test',
          username: 'fixture',
          apiVersion: '1.16.1',
        ),
      );
      final server = (await database.serverDao.getActiveServer())!;
      final credentials = _WorkerCredentialStore(failRead: failRead);
      final result = await runAndroidBackgroundSyncForTesting(
        database: database,
        credentials: credentials,
        profileKey: '00000000000000000000000000000000',
      );

      final expectedCategory = failRead
          ? 'transientFailure'
          : 'credentialUnavailable';
      expect(result['category'], expectedCategory);
      expect(result['retry'], failRead);
      expect(credentials.clearCalls, 0);
      expect(
        (await database.serverDao.getRetainedServer())?.isAuthenticated,
        failRead,
      );
      expect(
        (await database.librarySyncDao.getOrCreateState(server.id))
            .androidWorkerResult,
        expectedCategory,
      );
    }, skip: !sqliteAvailable);
  }

  test('a worker fenced out mid-pass reports leaseHeld or stoppedBySystem '
      'without a retry', () async {
    const connectivityChannel = MethodChannel(
      'dev.fluttercommunity.plus/connectivity',
    );
    messenger
      ..setMockMethodCallHandler(connectivityChannel, (_) async => ['wifi'])
      ..setMockStreamHandler(
        const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (_, _) {}),
      )
      ..setMockMethodCallHandler(
        const MethodChannel('com.navis.app/network_cost'),
        (_) async => false,
      );
    addTearDown(() {
      messenger
        ..setMockMethodCallHandler(connectivityChannel, null)
        ..setMockStreamHandler(
          const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
          null,
        )
        ..setMockMethodCallHandler(
          const MethodChannel('com.navis.app/network_cost'),
          null,
        );
    });

    // The test binding answers every HttpClient request with a 400.
    final httpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = httpOverrides);

    final requests = <String>[];
    final heldRequestArrived = Completer<void>();
    final answerHeldRequest = Completer<void>();
    final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => httpServer.close(force: true));
    httpServer.listen((request) async {
      requests.add(request.uri.path);
      if (requests.length == 1) {
        heldRequestArrived.complete();
        await answerHeldRequest.future;
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'subsonic-response': {
            'status': 'ok',
            'version': '1.16.1',
            'indexes': {'lastModified': 1767225600000},
            'albumList2': <String, Object?>{},
            'starred2': <String, Object?>{},
            'playlists': <String, Object?>{},
            'scanStatus': {'scanning': false, 'count': 0},
          },
        }),
      );
      await request.response.close();
    });

    final database = createTestDatabase();
    addTearDown(database.close);
    Future<Map<String, Object?>>? workerRun;
    addTearDown(() async {
      if (!answerHeldRequest.isCompleted) answerHeldRequest.complete();
      await workerRun;
    });
    await database.serverDao.saveServer(
      ServerConfigTableCompanion.insert(
        url: 'http://127.0.0.1:${httpServer.port}',
        username: 'fixture',
        apiVersion: '1.16.1',
        isAuthenticated: const Value(true),
        lastSynced: Value(DateTime.now().subtract(const Duration(days: 1))),
      ),
    );
    final server = (await database.serverDao.getActiveServer())!;
    await database.librarySyncDao.writeState(
      LibrarySyncStateTableCompanion(
        serverId: Value(server.id),
        currentGeneration: const Value(1),
        initialCatalogUsableAt: Value(DateTime.now()),
        androidBackgroundSyncEnabled: const Value(true),
      ),
    );

    workerRun = runAndroidBackgroundSyncForTesting(
      database: database,
      credentials: _WorkerCredentialStore(failRead: false, password: 'pw'),
      profileKey: AndroidBackgroundSyncScheduler.profileKeyFor(
        ServerConfigModel(
          url: server.url,
          username: server.username,
          password: 'pw',
          apiVersion: server.apiVersion,
        ),
      ),
    );
    await heldRequestArrived.future.timeout(const Duration(seconds: 20));
    final workerLease = await database.librarySyncDao.getExecutionLease(
      server.id,
    );
    expect(workerLease?.ownerKind, 'androidWorker');

    expect(
      await database.librarySyncDao.acquireExecutionLease(
        serverId: server.id,
        ownerToken: 'foreground-owner',
        ownerKind: 'foreground',
        now: DateTime.now(),
        ttl: const Duration(minutes: 10),
      ),
      isTrue,
    );
    answerHeldRequest.complete();
    final result = await workerRun.timeout(const Duration(seconds: 30));

    expect(result['category'], anyOf('leaseHeld', 'stoppedBySystem'));
    expect(result['retry'], isFalse);
    expect(
      (await database.librarySyncDao.getOrCreateState(server.id))
          .androidWorkerResult,
      result['category'],
    );
    expect(
      (await database.librarySyncDao.getExecutionLease(server.id))?.ownerToken,
      'foreground-owner',
    );
    expect(
      await (database.select(
        database.librarySyncWorkTable,
      )..where((work) => work.status.equals('running'))).get(),
      isEmpty,
    );
  }, skip: !sqliteAvailable);

  test('entrypoint supplies the cached native playback reader to sync', () {
    final source = File(
      'lib/src/features/library/data/android_background_sync_entrypoint.dart',
    ).readAsStringSync();
    expect(
      source,
      contains('readHasActivePlayback: () => tracker.hasActivePlayback'),
    );
    expect(source, isNot(contains('readHasActivePlayback: () => false')));
  });

  for (final initiallyActive in [false, true]) {
    test('worker playback cache refreshes from $initiallyActive', () {
      fakeAsync((clock) {
        var active = initiallyActive;
        var reads = 0;
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'isPlaybackActive');
          reads++;
          return active;
        });
        BackgroundSyncPolicyTracker? created;
        unawaited(
          BackgroundSyncPolicyTracker.create(
            readConnectivity: () async => [ConnectivityResult.wifi],
            connectivityChanges: const Stream.empty(),
            readNativeMetered: () async => false,
            backgroundSyncUnmeteredOnly: true,
          ).then((value) => created = value),
        );
        clock.flushMicrotasks();
        final tracker = created!;
        bool admitted() => librarySyncWorkAllowed(
          kind: LibrarySyncPlanKind.deltaReconcile,
          workClass: 'catalog',
          request: const LibrarySyncRequest.automatic(),
          policy: tracker.current,
          isForeground: false,
          hasActivePlayback: tracker.hasActivePlayback,
          isBackgroundExecutor: true,
        );

        expect(tracker.hasActivePlayback, initiallyActive);
        expect(admitted(), !initiallyActive);
        active = !initiallyActive;
        expect(tracker.hasActivePlayback, initiallyActive);
        clock.elapse(const Duration(seconds: 2));
        clock.flushMicrotasks();
        expect(tracker.hasActivePlayback, active);
        expect(admitted(), !active);

        unawaited(tracker.dispose());
        clock.flushMicrotasks();
        final readsAtDisposal = reads;
        clock.elapse(const Duration(seconds: 2));
        clock.flushMicrotasks();
        expect(reads, readsAtDisposal);
        expect(clock.periodicTimerCount, 0);
      });
    });
  }

  test(
    'unavailable native playback probe conservatively defers work',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'unavailable');
      });
      final tracker = await BackgroundSyncPolicyTracker.create(
        readConnectivity: () async => [ConnectivityResult.wifi],
        connectivityChanges: const Stream.empty(),
        readNativeMetered: () async => false,
        backgroundSyncUnmeteredOnly: true,
        refreshInterval: const Duration(days: 1),
      );
      addTearDown(tracker.dispose);
      expect(tracker.hasActivePlayback, isTrue);
      messenger.setMockMethodCallHandler(channel, (_) async => false);
      await tracker.refresh();
      expect(tracker.hasActivePlayback, isFalse);
      messenger.setMockMethodCallHandler(channel, null);
      await tracker.refresh();
      expect(tracker.hasActivePlayback, isTrue);
    },
  );
  for (final entry in <int, Duration>{
    -1: const Duration(hours: 24),
    0: const Duration(hours: 24),
    1: const Duration(seconds: 50),
    10: const Duration(seconds: 570),
    40: const Duration(seconds: 2280),
    60: const Duration(seconds: 3480),
  }.entries) {
    test('shared staleness for ${entry.key} minutes', () {
      expect(syncStaleAfterForInterval(entry.key), entry.value);
    });
  }

  test(
    'worker defers setup even after an unready catalog was published',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await database.serverDao.saveServer(
        ServerConfigTableCompanion.insert(
          url: 'https://example.test',
          username: 'fixture',
          apiVersion: '1.16.1',
        ),
      );
      final server = (await database.serverDao.getActiveServer())!;
      final config = ServerConfigModel(
        id: server.id,
        url: server.url,
        username: server.username,
        password: 'fixture',
        apiVersion: server.apiVersion,
      );
      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(server.id),
          currentGeneration: const Value(1),
        ),
      );
      expect(
        await deferAndroidBackgroundSyncForSetup(
          database: database,
          config: config,
          startedAt: DateTime.now(),
        ),
        isTrue,
      );
      final deferred = await database.librarySyncDao.getOrCreateState(
        server.id,
      );
      expect(deferred.androidWorkerResult, 'deferredSetup');
      expect(deferred.androidWorkerCompletedAt, isNotNull);
      expect(deferred.nextAutomaticCheckAt, isNull);
      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(server.id),
          initialCatalogUsableAt: Value(DateTime.now()),
        ),
      );
      expect(
        await deferAndroidBackgroundSyncForSetup(
          database: database,
          config: config,
          startedAt: DateTime.now(),
        ),
        isFalse,
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'background policy tracker refreshes metering during a worker pass',
    () async {
      final changes = StreamController<List<ConnectivityResult>>();
      addTearDown(changes.close);
      var connectivity = <ConnectivityResult>[ConnectivityResult.wifi];
      var metered = false;
      final tracker = await BackgroundSyncPolicyTracker.create(
        readConnectivity: () async => connectivity,
        connectivityChanges: changes.stream,
        readNativeMetered: () async => metered,
        backgroundSyncUnmeteredOnly: true,
        refreshInterval: const Duration(days: 1),
      );
      addTearDown(tracker.dispose);

      expect(tracker.current.allowsBackgroundSync, isTrue);

      connectivity = <ConnectivityResult>[ConnectivityResult.mobile];
      metered = true;
      await tracker.refresh();

      expect(tracker.current.networkType.name, 'cellular');
      expect(tracker.current.allowsBackgroundSync, isFalse);
    },
  );

  test('background policy tracker reacts to connectivity changes', () async {
    final changes = StreamController<List<ConnectivityResult>>();
    addTearDown(changes.close);
    var connectivity = <ConnectivityResult>[ConnectivityResult.wifi];
    final tracker = await BackgroundSyncPolicyTracker.create(
      readConnectivity: () async => connectivity,
      connectivityChanges: changes.stream,
      readNativeMetered: () async => false,
      backgroundSyncUnmeteredOnly: true,
      refreshInterval: const Duration(days: 1),
    );
    addTearDown(tracker.dispose);

    connectivity = <ConnectivityResult>[ConnectivityResult.none];
    changes.add(connectivity);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(tracker.current.networkType.name, 'offline');
    expect(tracker.current.allowsBackgroundSync, isFalse);
  });
}
