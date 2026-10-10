import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/library/domain/sync_run_contract.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/data/android_background_sync_entrypoint.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';

import '../../../../helpers/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.navis.app/background_sync');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    messenger.setMockMethodCallHandler(channel, (_) async => false);
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

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
