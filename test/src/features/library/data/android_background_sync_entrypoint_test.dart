import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/data/android_background_sync_entrypoint.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';

import '../../../../helpers/test_database.dart';

void main() {
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
      final tracker = await BackgroundNetworkPolicyTracker.create(
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
    final tracker = await BackgroundNetworkPolicyTracker.create(
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
