import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/auth/presentation/session_route_provider.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../../../helpers/fake_playback_handler.dart';
import '../../../../helpers/stub_library_sync_engine.dart';
import '../../../../helpers/test_database.dart';

class _Handler extends InertPlaybackHandler {
  final aliases = <Map<String, String>>[];
  bool failAliasesOnce = false;
  int aliasAttempts = 0;
  @override
  Future<void> applySongIdentityAliases(Map<String, String> value) async {
    aliasAttempts++;
    if (failAliasesOnce) {
      failAliasesOnce = false;
      throw StateError('temporary alias failure');
    }
    aliases.add(value);
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test('long resume coalesces connectivity refresh and server probe', () async {
    final database = createTestDatabase();
    await database.serverDao.saveServer(
      ServerConfigTableCompanion.insert(
        url: 'https://fixture.invalid',
        username: 'fixture',
        apiVersion: '1.16.1',
      ),
    );
    var now = DateTime(2026, 1, 1);
    var checks = 0;
    var pings = 0;
    var metering = 0;
    final ping = Completer<String>();
    const config = ServerConfigModel(
      id: 1,
      url: 'https://fixture.invalid',
      username: 'fixture',
      password: 'synthetic',
      apiVersion: '1.16.1',
    );
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: [
          nowProvider.overrideWithValue(() => now),
          serverConfigStateProvider.overrideWithValue(const AsyncData(config)),
          networkTypeProvider.overrideWithValue(NetworkType.wifi),
          audioHandlerProvider.overrideWithValue(null),
          librarySyncEngineProvider.overrideWithValue(null),
          syncIntervalMinutesProvider.overrideWithValue(0),
          initialSyncRequiredProvider.overrideWith((_) async => false),
          connectivityProvider.overrideWith((_) {
            checks++;
            return Stream.value([ConnectivityResult.wifi]);
          }),
          nativeNetworkMeteredProvider.overrideWith((_) async {
            metering++;
            return false;
          }),
          pingServerProvider.overrideWithValue(() {
            pings++;
            return ping.future;
          }),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    container.listen(librarySyncControllerProvider, (_, _) {});
    await container
        .read(connectivityProvider.future)
        .timeout(const Duration(seconds: 2));
    await container.read(nativeNetworkMeteredProvider.future);
    await pumpEventQueue();
    final initialChecks = checks;
    expect(pings, 1);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await pumpEventQueue();
    now = now.add(const Duration(seconds: 31));
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpEventQueue(times: 80);
    expect(checks, initialChecks + 1);
    expect(
      pings,
      1,
      reason: 'resume must join the already-running server probe',
    );
    expect(metering, 2);
    ping.complete('fixture');
    await pumpEventQueue();
  });

  test(
    'fast reachability completion does not produce a second resume ping',
    () async {
      final database = createTestDatabase();
      await database.serverDao.saveServer(
        ServerConfigTableCompanion.insert(
          url: 'https://fixture.invalid',
          username: 'fixture',
          apiVersion: '1.16.1',
        ),
      );
      var now = DateTime(2026, 1, 1);
      var checks = 0;
      var pings = 0;
      var metering = 0;
      final ping = Completer<String>();
      const config = ServerConfigModel(
        id: 1,
        url: 'https://fixture.invalid',
        username: 'fixture',
        password: 'synthetic',
        apiVersion: '1.16.1',
      );
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [
            nowProvider.overrideWithValue(() => now),
            serverConfigStateProvider.overrideWithValue(
              const AsyncData(config),
            ),
            networkTypeProvider.overrideWithValue(NetworkType.wifi),
            audioHandlerProvider.overrideWithValue(null),
            librarySyncEngineProvider.overrideWithValue(null),
            syncIntervalMinutesProvider.overrideWithValue(0),
            initialSyncRequiredProvider.overrideWith((_) async => false),
            connectivityProvider.overrideWith((_) {
              checks++;
              return Stream.value([ConnectivityResult.wifi]);
            }),
            nativeNetworkMeteredProvider.overrideWith((_) async {
              metering++;
              return false;
            }),
            pingServerProvider.overrideWithValue(() {
              pings++;
              return Future.value('fixture');
            }),
          ],
        ),
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });
      binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      container.listen(librarySyncControllerProvider, (_, _) {});
      await container
          .read(connectivityProvider.future)
          .timeout(const Duration(seconds: 2));
      await container.read(nativeNetworkMeteredProvider.future);
      await pumpEventQueue();
      final initialChecks = checks;
      final initialPings = pings;
      expect(initialPings, greaterThan(0));
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await pumpEventQueue();
      now = now.add(const Duration(seconds: 31));
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpEventQueue(times: 80);
      expect(checks, initialChecks + 1);
      expect(
        pings,
        initialPings + 1,
        reason: 'resume must not repeat a fast completed probe',
      );
      expect(metering, 2);
      ping.complete('fixture');
      await pumpEventQueue();
    },
  );

  test('external worker commit refreshes a subscribed catalog, sync state and aliases on resume', () async {
    final directory = await Directory.systemTemp.createTemp(
      'navis-worker-resume-',
    );
    final file = File(p.join(directory.path, 'navis.sqlite'));
    final database = createTestDatabase(file: file);
    await database.serverDao.saveServer(
      ServerConfigTableCompanion.insert(
        url: 'https://fixture.invalid',
        username: 'fixture',
        apiVersion: '1.16.1',
        lastSynced: Value(DateTime.now()),
        isAuthenticated: const Value(true),
      ),
    );
    await database.libraryDao.upsertSongs([
      SongsTableCompanion.insert(id: 'before', title: 'Before'),
    ]);
    await database.librarySyncDao.getOrCreateState(1);
    final handler = _Handler();
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: [
          serverConfigStateProvider.overrideWithValue(
            AsyncData(
              ServerConfigModel(
                id: 1,
                url: 'https://fixture.invalid',
                username: 'fixture',
                password: 'synthetic',
                apiVersion: '1.16.1',
                lastSynced: DateTime.now(),
              ),
            ),
          ),
          networkTypeProvider.overrideWithValue(NetworkType.offline),
          pingServerProvider.overrideWithValue(null),
          audioHandlerProvider.overrideWithValue(handler),
          librarySyncEngineProvider.overrideWithValue(
            StubLibrarySyncEngine.returning(const LibrarySyncState.idle()),
          ),
          syncIntervalMinutesProvider.overrideWithValue(0),
          initialSyncRequiredProvider.overrideWith((_) async => false),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
      await directory.delete(recursive: true);
    });
    binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    container.listen(librarySyncControllerProvider, (_, _) {});
    final counts = <int>[];
    final subscription = database
        .customSelect(
          'SELECT count(*) AS n FROM songs',
          readsFrom: {database.songsTable},
        )
        .watch()
        .listen((rows) => counts.add(rows.single.read<int>('n')));
    addTearDown(subscription.cancel);
    await pumpEventQueue();
    expect(counts.last, 1);
    final before = await database.readDataVersion();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await pumpEventQueue();
    final worker = sqlite3.open(file.path);
    try {
      worker.execute("INSERT INTO songs(id, title) VALUES ('after', 'After')");
      worker.execute(
        "UPDATE library_sync_state SET last_run_bytes = 1234 WHERE server_id = 1",
      );
      worker.execute(
        "INSERT INTO entity_identity_aliases(entity_type, old_id, new_id, match_reason, matched_at) VALUES ('song', 'before', 'after', 'fixture', 1)",
      );
    } finally {
      worker.dispose();
    }
    expect(await database.readDataVersion(), isNot(before));
    await pumpEventQueue();
    expect(
      counts.last,
      1,
      reason: 'external SQLite commits have no Drift notifications',
    );
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpEventQueue(times: 100);
    expect(counts.last, 2);
    expect(container.read(librarySyncControllerProvider).lastRunBytes, 1234);
    expect(handler.aliases.last, {'before': 'after'});
  });
  for (final (leased, retry, rapid, stop) in [
    (false, false, false, 'complete'),
    (true, false, false, 'complete'),
    (true, true, false, 'complete'),
    (false, false, true, 'complete'),
    (true, false, true, 'complete'),
    (true, false, false, 'pause'),
    (true, false, false, 'dispose'),
    (true, false, false, 'budget'),
  ]) {
    test(
      'worker commit after resume refreshes catalog and aliases (lease: $leased, retry: $retry, rapid: $rapid, stop: $stop)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-worker-resume-',
        );
        final file = File(p.join(directory.path, 'navis.sqlite'));
        final database = createTestDatabase(file: file);
        await database.serverDao.saveServer(
          ServerConfigTableCompanion.insert(
            url: 'https://fixture.invalid',
            username: 'fixture',
            apiVersion: '1.16.1',
            lastSynced: Value(DateTime.now()),
            isAuthenticated: const Value(true),
          ),
        );
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(id: 'before', title: 'Before'),
        ]);
        await database.librarySyncDao.getOrCreateState(1);
        await database.librarySyncDao.writeAndroidBackgroundStatus(
          serverId: 1,
          workerStartedAt: DateTime.now(),
          workState: 'running',
        );
        if (leased) {
          await database.librarySyncDao.acquireExecutionLease(
            serverId: 1,
            ownerToken: 'fixture-worker',
            ownerKind: 'androidWorker',
            now: DateTime.now(),
            ttl: Duration(minutes: stop == 'budget' ? 20 : 1),
          );
        }
        var now = DateTime.now();
        final metering = Completer<bool>();
        final meteringEntered = Completer<void>();
        final handler = _Handler()..failAliasesOnce = retry;
        final container = ProviderContainer(
          overrides: withTestDatabase(
            database,
            overrides: [
              nowProvider.overrideWithValue(() => now),
              if (rapid) ...[
                connectivityProvider.overrideWith(
                  (_) => Stream.value([ConnectivityResult.wifi]),
                ),
                nativeNetworkMeteredProvider.overrideWith((_) {
                  if (!meteringEntered.isCompleted) meteringEntered.complete();
                  return metering.future;
                }),
              ],
              serverConfigStateProvider.overrideWithValue(
                AsyncData(
                  ServerConfigModel(
                    id: 1,
                    url: 'https://fixture.invalid',
                    username: 'fixture',
                    password: 'synthetic',
                    apiVersion: '1.16.1',
                    lastSynced: DateTime.now(),
                  ),
                ),
              ),
              networkTypeProvider.overrideWithValue(NetworkType.offline),
              pingServerProvider.overrideWithValue(null),
              audioHandlerProvider.overrideWithValue(handler),
              librarySyncEngineProvider.overrideWithValue(
                StubLibrarySyncEngine.returning(const LibrarySyncState.idle()),
              ),
              syncIntervalMinutesProvider.overrideWithValue(0),
              initialSyncRequiredProvider.overrideWith((_) async => false),
            ],
          ),
        );
        addTearDown(() async {
          if (!metering.isCompleted) metering.complete(false);
          container.dispose();
          await database.close();
          await directory.delete(recursive: true);
        });
        binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        container.listen(librarySyncControllerProvider, (_, _) {});
        final counts = <int>[];
        final subscription = database
            .customSelect(
              'SELECT count(*) AS n FROM songs',
              readsFrom: {database.songsTable},
            )
            .watch()
            .listen((rows) => counts.add(rows.single.read<int>('n')));
        addTearDown(subscription.cancel);
        await pumpEventQueue();
        expect(counts.last, 1);
        final before = await database.readDataVersion();
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await pumpEventQueue();
        if (rapid) now = now.add(const Duration(seconds: 31));
        binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await pumpEventQueue(times: 100);
        expect(counts.last, 1);
        if (rapid) {
          await meteringEntered.future.timeout(const Duration(seconds: 1));
          // Cancel the watcher while the connectivity/metering reconciliation
          // is still pending, then resume into that same in-flight future.
          binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
          binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
          binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
          await pumpEventQueue();
          binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
          binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
          binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await pumpEventQueue(times: 100);
          expect(metering.isCompleted, isFalse);
        }
        switch (stop) {
          case 'pause':
            binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
            binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
            binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
            await pumpEventQueue();
          case 'dispose':
            container.dispose();
          case 'budget':
            now = now.add(const Duration(minutes: 10));
        }
        final worker = sqlite3.open(file.path);
        try {
          worker.execute(
            "INSERT INTO songs(id, title) VALUES ('after', 'After')",
          );
          worker.execute(
            'UPDATE library_sync_state SET last_run_bytes = 1234 WHERE server_id = 1',
          );
          worker.execute(
            "INSERT INTO entity_identity_aliases(entity_type, old_id, new_id, match_reason, matched_at) VALUES ('song', 'before', 'after', 'fixture', 1)",
          );
          if (stop == 'complete') {
            worker.execute(
              'DELETE FROM library_sync_execution_lease WHERE server_id = 1',
            );
            worker.execute(
              "UPDATE library_sync_state SET android_worker_completed_at = strftime('%s', 'now'), android_worker_result = 'succeeded' WHERE server_id = 1",
            );
          }
        } finally {
          worker.close();
        }
        expect(await database.readDataVersion(), isNot(before));
        await pumpEventQueue();
        expect(
          counts.last,
          1,
          reason: 'external SQLite commits have no Drift notifications',
        );
        if (stop == 'pause' || stop == 'dispose') {
          await Future<void>.delayed(const Duration(milliseconds: 1200));
          await pumpEventQueue();
          expect(counts.last, 1);
          expect(handler.aliases, isEmpty);
          return;
        }
        for (var i = 0; i < 40 && handler.aliases.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await pumpEventQueue();
        }
        expect(counts.last, 2);
        expect(
          container.read(librarySyncControllerProvider).lastRunBytes,
          1234,
        );
        expect(handler.aliases.last, {'before': 'after'});
        expect(handler.aliasAttempts, retry ? 2 : 1);
        // Completion or the observation budget must stop polling, even
        // if a worker lease outlives the foreground observation window.
        final later = sqlite3.open(file.path);
        try {
          later.execute(
            "INSERT INTO songs(id, title) VALUES ('later', 'Later')",
          );
        } finally {
          later.close();
        }
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        await pumpEventQueue();
        expect(counts.last, 2);
      },
    );
  }
}
