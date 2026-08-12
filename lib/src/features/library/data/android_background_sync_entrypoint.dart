import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/library/data/adaptive_library_sync_coordinator.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:navis/src/utils/network_cost_bridge.dart';
import 'package:navis/src/utils/network_usage_meter.dart';

const _backgroundSyncChannel = MethodChannel('com.navis.app/background_sync');

/// Android WorkManager's retained Dart entrypoint. It intentionally creates no
/// app shell, player, audio handler, notification bootstrap, or diagnostics
/// HTTP server.
@pragma('vm:entry-point')
Future<void> navisBackgroundSyncEntrypoint() async {
  WidgetsFlutterBinding.ensureInitialized();
  final runner = _HeadlessBackgroundSyncRunner();
  final lifetime = Completer<void>();
  _backgroundSyncChannel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'runAutomaticBackgroundSync':
        return runner.run();
      case 'cancel':
        await runner.cancel();
        return true;
      case 'shutdown':
        await runner.cancel();
        if (!lifetime.isCompleted) {
          lifetime.complete();
        }
        return true;
      default:
        throw MissingPluginException('Unknown background sync command.');
    }
  });
  await _backgroundSyncChannel.invokeMethod<void>('ready');
  await lifetime.future;
}

class _HeadlessBackgroundSyncRunner {
  Future<Map<String, Object?>>? _running;
  AdaptiveLibrarySyncCoordinator? _coordinator;

  Future<Map<String, Object?>> run() {
    return _running ??= _run().whenComplete(() {
      _running = null;
    });
  }

  Future<void> cancel() async {
    final coordinator = _coordinator;
    if (coordinator != null) {
      await coordinator.cancelAndWait();
    }
  }

  Future<Map<String, Object?>> _run() async {
    final database = NavisDatabase();
    SubsonicApiClient? client;
    int? activeServerId;
    try {
      final repository = ServerConfigRepository(
        database,
        credentials: const FlutterSecureCredentialStore(),
      );
      final retained = await repository.getRetainedServer();
      final config = await repository.getActiveServer();
      final serverId = retained?.id;
      activeServerId = serverId;
      if (config == null || config.id == null) {
        if (serverId != null) {
          await database.librarySyncDao.writeAndroidBackgroundStatus(
            serverId: serverId,
            workerCompletedAt: DateTime.now(),
            workerResult: 'credentialUnavailable',
          );
        }
        return _result('credentialUnavailable');
      }
      activeServerId = config.id;

      final persisted = await database.librarySyncDao.getOrCreateState(
        config.id!,
      );
      if (!persisted.androidBackgroundSyncEnabled ||
          persisted.currentGeneration == 0) {
        await database.librarySyncDao.writeAndroidBackgroundStatus(
          serverId: config.id!,
          workerCompletedAt: DateTime.now(),
          workerResult: 'noWorkDue',
        );
        return _result('noWorkDue');
      }

      final settings = await database.appSettingsDao.getSettings();
      final connectivity = await Connectivity().checkConnectivity();
      final networkType = resolveNetworkType(connectivity);
      final metered = await NetworkCostBridge().isActiveNetworkMetered();
      final policy = resolveSyncNetworkPolicy(
        networkType: networkType,
        nativeMetered: metered,
        backgroundSyncUnmeteredOnly:
            settings?.backgroundSyncUnmeteredOnly ?? true,
      );
      if (!policy.allowsBackgroundSync) {
        await database.librarySyncDao.writeAndroidBackgroundStatus(
          serverId: config.id!,
          workerCompletedAt: DateTime.now(),
          workerResult: 'deferredPolicy',
        );
        return _result('deferredPolicy');
      }

      final meter = NetworkUsageMeter(
        dao: database.networkUsageDao,
        readNetworkType: () => policy.networkType,
      );
      client = SubsonicApiClient(
        baseUrl: config.url,
        authConfig: SubsonicAuthConfig(
          username: config.username,
          password: config.password,
          apiVersion: config.apiVersion,
          authType: config.useLegacyAuth
              ? SubsonicAuthType.legacyPassword
              : SubsonicAuthType.token,
        ),
        enableLogging: false,
        maxConnectionsPerHost: 4,
        reportNetworkUsage: ({required category, required bytes, operation}) {
          meter.record(
            category: category,
            bytes: bytes,
            operation: operation,
          );
        },
      );
      final executor = DriftLibrarySyncEngine(
        api: SubsonicLibrarySyncApi(client),
        database: database,
        serverConfigRepository: repository,
        networkType: policy.networkType,
        readSyncNetworkPolicy: () => policy,
        staleAfter: Duration(
          minutes: settings?.syncIntervalMinutes ?? 60,
        ),
      );
      final coordinator = AdaptiveLibrarySyncCoordinator(
        executor: executor,
        database: database,
        serverConfigRepository: repository,
        readSyncNetworkPolicy: () => policy,
        staleAfter: Duration(
          minutes: settings?.syncIntervalMinutes ?? 60,
        ),
        readHasActivePlayback: () => false,
        readIsForeground: () => false,
        executionOwnerKind: 'androidWorker',
        isBackgroundExecution: true,
      );
      _coordinator = coordinator;
      final startedAt = DateTime.now();
      await database.librarySyncDao.writeAndroidBackgroundStatus(
        serverId: config.id!,
        workerStartedAt: startedAt,
        workerStopReason: 'none',
      );
      final state = await coordinator.requestSync(
        const LibrarySyncRequest.automatic(),
      );
      final category = _categoryFor(state);
      final completedAt = DateTime.now();
      await database.librarySyncDao.writeAndroidBackgroundStatus(
        serverId: config.id!,
        workerCompletedAt: completedAt,
        workerDurationMs: completedAt.difference(startedAt).inMilliseconds,
        workerResult: category,
      );
      return _result(category, state: state);
    } on SyncCancelledException {
      if (activeServerId != null) {
        await database.librarySyncDao.writeAndroidBackgroundStatus(
          serverId: activeServerId,
          workerCompletedAt: DateTime.now(),
          workerResult: 'stoppedBySystem',
        );
      }
      return _result('stoppedBySystem');
    } on Object {
      // The coordinator persists sync-domain failures itself. Reaching here
      // means bootstrap or engine setup failed before it owned the pass.
      if (activeServerId != null) {
        await database.librarySyncDao.writeAndroidBackgroundStatus(
          serverId: activeServerId,
          workerCompletedAt: DateTime.now(),
          workerResult: 'transientFailure',
        );
      }
      return _result('transientFailure', retry: true);
    } finally {
      _coordinator = null;
      client?.close(force: true);
      await database.close();
    }
  }

  String _categoryFor(LibrarySyncState state) {
    if (state.planReason == 'leaseHeld') {
      return 'leaseHeld';
    }
    return switch (state.status) {
      LibrarySyncStatus.succeeded ||
      LibrarySyncStatus.partial ||
      LibrarySyncStatus.skipped => 'succeeded',
      LibrarySyncStatus.deferred => 'deferredPolicy',
      LibrarySyncStatus.failed => 'permanentFailure',
      LibrarySyncStatus.cancelled => 'stoppedBySystem',
      LibrarySyncStatus.idle || LibrarySyncStatus.running => 'noWorkDue',
    };
  }

  Map<String, Object?> _result(
    String category, {
    bool retry = false,
    LibrarySyncState? state,
  }) {
    return <String, Object?>{
      'category': category,
      'retry': retry,
      'requests': state?.apiRequests ?? 0,
      'bytes': state?.lastRunBytes ?? 0,
    };
  }
}
