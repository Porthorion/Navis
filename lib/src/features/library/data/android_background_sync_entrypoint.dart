import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/library/data/adaptive_library_sync_coordinator.dart';
import 'package:navis/src/features/library/data/android_background_sync.dart';
import 'package:navis/src/features/library/data/library_sync_execution_bootstrap.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/providers/app_providers.dart';
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
        final command = _BackgroundWorkerCommand.tryParse(call.arguments);
        if (command == null) {
          return const <String, Object?>{'category': 'permanentFailure'};
        }
        return runner.run(command);
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

  Future<Map<String, Object?>> run(_BackgroundWorkerCommand command) {
    return _running ??= _run(command).whenComplete(() {
      _running = null;
    });
  }

  Future<void> cancel() async {
    final coordinator = _coordinator;
    if (coordinator != null) {
      await coordinator.cancelAndWait();
    }
  }

  Future<Map<String, Object?>> _run(_BackgroundWorkerCommand command) async {
    final container = ProviderContainer();
    final database = container.read(navisDatabaseProvider);
    SubsonicApiClient? client;
    BackgroundNetworkPolicyTracker? policyTracker;
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
          final startedAt = DateTime.now();
          await database.librarySyncDao.writeAndroidBackgroundStatus(
            serverId: serverId,
            workerStartedAt: startedAt,
            workerCompletedAt: startedAt,
            workerDurationMs: 0,
            workerResult: 'credentialUnavailable',
          );
        }
        return _result('credentialUnavailable');
      }
      activeServerId = config.id;

      // A cancelled/replaced profile can leave a WorkManager dispatch racing
      // with reconciliation. The worker input contains only this opaque key,
      // which is enough to reject that stale request without touching the new
      // active account or making a network request.
      if (AndroidBackgroundSyncScheduler.profileKeyFor(config) !=
          command.profileKey) {
        return _result('noWorkDue');
      }

      final startedAt = DateTime.now();
      await database.librarySyncDao.writeAndroidBackgroundStatus(
        serverId: config.id!,
        workId: command.workId,
        workState: 'running',
        attemptCount: command.attemptCount,
        workerStartedAt: startedAt,
        workerStopReason: 'none',
      );

      final persisted = await database.librarySyncDao.getOrCreateState(
        config.id!,
      );
      if (!persisted.androidBackgroundSyncEnabled ||
          persisted.currentGeneration == 0) {
        final completedAt = DateTime.now();
        await database.librarySyncDao.writeAndroidBackgroundStatus(
          serverId: config.id!,
          workerCompletedAt: completedAt,
          workerDurationMs: completedAt.difference(startedAt).inMilliseconds,
          workerResult: 'noWorkDue',
        );
        return _result('noWorkDue');
      }

      final settings = await database.appSettingsDao.getSettings();
      final unmeteredOnly = settings?.backgroundSyncUnmeteredOnly ?? true;
      final tracker = await BackgroundNetworkPolicyTracker.create(
        readConnectivity: Connectivity().checkConnectivity,
        connectivityChanges: Connectivity().onConnectivityChanged,
        readNativeMetered: () async =>
            await NetworkCostBridge().isActiveNetworkMetered() ?? true,
        backgroundSyncUnmeteredOnly: unmeteredOnly,
      );
      policyTracker = tracker;
      if (!tracker.current.allowsBackgroundSync) {
        final completedAt = DateTime.now();
        await database.librarySyncDao.writeAndroidBackgroundStatus(
          serverId: config.id!,
          workerCompletedAt: completedAt,
          workerDurationMs: completedAt.difference(startedAt).inMilliseconds,
          workerResult: 'deferredPolicy',
        );
        return _result('deferredPolicy');
      }

      final meter = NetworkUsageMeter(
        dao: database.networkUsageDao,
        readNetworkType: () => tracker.current.networkType,
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
        reportNetworkUsage: meter.record,
      );
      final coordinator = LibrarySyncExecutionBootstrap.createCoordinator(
        client: client,
        database: database,
        serverConfigRepository: repository,
        initialNetworkType: tracker.current.networkType,
        readSyncNetworkPolicy: () => tracker.current,
        staleAfter: Duration(minutes: settings?.syncIntervalMinutes ?? 60),
        readHasActivePlayback: () => false,
        readIsForeground: () => false,
        executionOwnerKind: 'androidWorker',
        isBackgroundExecution: true,
      );
      _coordinator = coordinator;
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
        final completedAt = DateTime.now();
        await database.librarySyncDao.writeAndroidBackgroundStatus(
          serverId: activeServerId,
          workerCompletedAt: completedAt,
          workerResult: 'stoppedBySystem',
        );
      }
      return _result('stoppedBySystem');
    } on Object {
      // The coordinator persists sync-domain failures itself. Reaching here
      // means bootstrap or engine setup failed before it owned the pass.
      if (activeServerId != null) {
        final completedAt = DateTime.now();
        await database.librarySyncDao.writeAndroidBackgroundStatus(
          serverId: activeServerId,
          workerCompletedAt: completedAt,
          workerResult: 'transientFailure',
        );
      }
      return _result('transientFailure', retry: true);
    } finally {
      _coordinator = null;
      await policyTracker?.dispose();
      client?.close(force: true);
      container.dispose();
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

/// Keeps a headless worker's policy current without retaining a UI provider.
///
/// The coordinator and engine invoke their supplied policy reader at their
/// existing execution gates. This tracker makes those reads reflect both a
/// connectivity transition and a native metering change that occurs after the
/// worker has started.
class BackgroundNetworkPolicyTracker {
  new _({
    required SyncNetworkPolicy initialPolicy,
    required this._readConnectivity,
    required this._connectivityChanges,
    required this._readNativeMetered,
    required this._backgroundSyncUnmeteredOnly,
    required this._refreshInterval,
  }) : _current = initialPolicy;

  static Future<BackgroundNetworkPolicyTracker> create({
    required Future<List<ConnectivityResult>> Function() readConnectivity,
    required Stream<List<ConnectivityResult>> connectivityChanges,
    required Future<bool> Function() readNativeMetered,
    required bool backgroundSyncUnmeteredOnly,
    Duration refreshInterval = const Duration(seconds: 2),
  }) async {
    final tracker = BackgroundNetworkPolicyTracker._(
      initialPolicy: await _resolve(
        readConnectivity: readConnectivity,
        readNativeMetered: readNativeMetered,
        backgroundSyncUnmeteredOnly: backgroundSyncUnmeteredOnly,
      ),
      readConnectivity: readConnectivity,
      connectivityChanges: connectivityChanges,
      readNativeMetered: readNativeMetered,
      backgroundSyncUnmeteredOnly: backgroundSyncUnmeteredOnly,
      refreshInterval: refreshInterval,
    );
    tracker._start();
    return tracker;
  }

  final Future<List<ConnectivityResult>> Function() _readConnectivity;
  final Stream<List<ConnectivityResult>> _connectivityChanges;
  final Future<bool> Function() _readNativeMetered;
  final bool _backgroundSyncUnmeteredOnly;
  final Duration _refreshInterval;
  SyncNetworkPolicy _current;
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Timer? _refreshTimer;
  Future<void> _pendingRefresh = Future<void>.value();

  SyncNetworkPolicy get current => _current;

  void _start() {
    _subscription = _connectivityChanges.listen((_) => _queueRefresh());
    _refreshTimer = Timer.periodic(_refreshInterval, (_) => _queueRefresh());
  }

  Future<void> refresh() async {
    _current = await _resolve(
      readConnectivity: _readConnectivity,
      readNativeMetered: _readNativeMetered,
      backgroundSyncUnmeteredOnly: _backgroundSyncUnmeteredOnly,
    );
  }

  void _queueRefresh() {
    _pendingRefresh = _pendingRefresh.then((_) => refresh());
  }

  Future<void> dispose() async {
    _refreshTimer?.cancel();
    await _subscription?.cancel();
    await _pendingRefresh;
  }

  static Future<SyncNetworkPolicy> _resolve({
    required Future<List<ConnectivityResult>> Function() readConnectivity,
    required Future<bool> Function() readNativeMetered,
    required bool backgroundSyncUnmeteredOnly,
  }) async {
    final connectivity = await readConnectivity();
    return resolveSyncNetworkPolicy(
      networkType: resolveNetworkType(connectivity),
      nativeMetered: await readNativeMetered(),
      backgroundSyncUnmeteredOnly: backgroundSyncUnmeteredOnly,
    );
  }
}

/// Strictly validates the small Kotlin-to-Dart work protocol. No profile
/// identity or credential can cross this boundary.
class _BackgroundWorkerCommand {
  const new({
    required this.profileKey,
    required this.workId,
    required this.attemptCount,
  });

  final String profileKey;
  final String workId;
  final int attemptCount;

  static _BackgroundWorkerCommand? tryParse(Object? value) {
    if (value is! Map) {
      return null;
    }
    final profileKey = value['profileKey'];
    final workId = value['workId'];
    final attempts = value['attemptCount'];
    if (profileKey is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(profileKey) ||
        workId is! String ||
        !RegExp(r'^[0-9a-fA-F-]{1,64}$').hasMatch(workId) ||
        attempts is! int) {
      return null;
    }
    return _BackgroundWorkerCommand(
      profileKey: profileKey,
      workId: workId,
      attemptCount: attempts.clamp(0, 100),
    );
  }
}
