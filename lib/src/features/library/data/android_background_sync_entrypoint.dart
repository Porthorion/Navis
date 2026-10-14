import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/session_route_provider.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/library/data/adaptive_library_sync_coordinator.dart';
import 'package:navis/src/features/library/data/android_background_sync.dart';
import 'package:navis/src/features/library/data/library_sync_execution_bootstrap.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/providers/provider_retry.dart';
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
        return await runner.run(command);
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

@visibleForTesting
Future<Map<String, Object?>> runAndroidBackgroundSyncForTesting({
  required NavisDatabase database,
  required SecureCredentialStore credentials,
  required String profileKey,
}) => _HeadlessBackgroundSyncRunner()._run(
  _BackgroundWorkerCommand(
    profileKey: profileKey,
    workId: 'fixture',
    attemptCount: 0,
  ),
  databaseOverride: database,
  credentialsOverride: credentials,
);

/// Records a worker deferral before network bootstrap while setup owns sync.
Future<bool> deferAndroidBackgroundSyncForSetup({
  required NavisDatabase database,
  required ServerConfigModel config,
  required DateTime startedAt,
}) async {
  if (!await isInitialCatalogSetupPending(database, config)) return false;
  final completedAt = DateTime.now();
  await database.librarySyncDao.writeAndroidBackgroundStatus(
    serverId: config.id!,
    workerCompletedAt: completedAt,
    workerDurationMs: completedAt.difference(startedAt).inMilliseconds,
    workerResult: 'deferredSetup',
  );
  return true;
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

  Future<Map<String, Object?>> _run(
    _BackgroundWorkerCommand command, {
    NavisDatabase? databaseOverride,
    SecureCredentialStore? credentialsOverride,
  }) async {
    final container = ProviderContainer(
      retry: navisProviderRetry,
      overrides: [
        if (databaseOverride != null)
          navisDatabaseProvider.overrideWithValue(databaseOverride),
      ],
    );
    final database = container.read(navisDatabaseProvider);
    SubsonicApiClient? client;
    BackgroundSyncPolicyTracker? policyTracker;
    int? activeServerId;
    var startedAt = DateTime.now();
    Future<Map<String, Object?>> finish(
      String category, {
      bool retry = false,
      bool recordStartedAt = false,
      LibrarySyncState? state,
    }) async {
      final serverId = activeServerId;
      if (serverId != null) {
        final completedAt = DateTime.now();
        await database.librarySyncDao.writeAndroidBackgroundStatus(
          serverId: serverId,
          workerStartedAt: recordStartedAt ? startedAt : null,
          workerCompletedAt: completedAt,
          workerDurationMs: completedAt.difference(startedAt).inMilliseconds,
          workerResult: category,
        );
      }
      return _result(category, retry: retry, state: state);
    }

    try {
      final repository = ServerConfigRepository(
        database,
        credentials: credentialsOverride ?? FlutterSecureCredentialStore(),
      );
      final retained = await repository.getRetainedServer();
      activeServerId = retained?.id;
      final config = await repository.getActiveServer();
      if (config == null || config.id == null) {
        return await finish('credentialUnavailable', recordStartedAt: true);
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

      startedAt = DateTime.now();
      await database.librarySyncDao.writeAndroidBackgroundStatus(
        serverId: config.id!,
        workId: command.workId,
        workState: 'running',
        attemptCount: command.attemptCount,
        workerStartedAt: startedAt,
        workerStopReason: 'none',
      );

      if (await deferAndroidBackgroundSyncForSetup(
        database: database,
        config: config,
        startedAt: startedAt,
      )) {
        return _result('deferredSetup');
      }

      final persisted = await database.librarySyncDao.getOrCreateState(
        config.id!,
      );
      if (!persisted.androidBackgroundSyncEnabled ||
          persisted.currentGeneration == 0) {
        return await finish('noWorkDue');
      }

      final settings = await database.appSettingsDao.getSettings();
      final unmeteredOnly = settings?.backgroundSyncUnmeteredOnly ?? true;
      final tracker = await BackgroundSyncPolicyTracker.create(
        readConnectivity: Connectivity().checkConnectivity,
        connectivityChanges: Connectivity().onConnectivityChanged,
        readNativeMetered: () async =>
            await NetworkCostBridge().isActiveNetworkMetered() ?? true,
        backgroundSyncUnmeteredOnly: unmeteredOnly,
      );
      policyTracker = tracker;
      if (tracker.hasActivePlayback) {
        return await finish('deferredPlayback');
      }
      if (!tracker.current.allowsBackgroundSync) {
        return await finish('deferredPolicy');
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
        staleAfter: syncStaleAfterForInterval(
          settings?.syncIntervalMinutes ?? 60,
        ),
        readHasActivePlayback: () => tracker.hasActivePlayback,
        readIsForeground: () => false,
        executionOwnerKind: 'androidWorker',
        isBackgroundExecution: true,
      );
      _coordinator = coordinator;
      final state = await coordinator.requestSync(
        const LibrarySyncRequest.automatic(),
      );
      return await finish(
        _categoryFor(state, hasActivePlayback: tracker.hasActivePlayback),
        state: state,
      );
    } on SyncCancelledException {
      return await finish('stoppedBySystem');
    } on Object {
      // Bootstrap failed before the coordinator owned the pass.
      return await finish('transientFailure', retry: true);
    } finally {
      _coordinator = null;
      await policyTracker?.dispose();
      client?.close(force: true);
      container.dispose();
    }
  }

  String _categoryFor(
    LibrarySyncState state, {
    required bool hasActivePlayback,
  }) {
    if (state.planReason == 'leaseHeld') {
      return 'leaseHeld';
    }
    return switch (state.status) {
      LibrarySyncStatus.succeeded ||
      LibrarySyncStatus.partial ||
      LibrarySyncStatus.skipped => 'succeeded',
      LibrarySyncStatus.deferred =>
        hasActivePlayback ? 'deferredPlayback' : 'deferredPolicy',
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

/// Keeps a headless worker's network and playback policy current.
///
/// The coordinator and engine invoke their supplied policy reader at their
/// existing execution gates. This tracker makes those reads reflect both a
/// connectivity transition and a native metering change that occurs after the
/// worker has started. Native playback is polled on the same two-second timer;
/// live sessions, including paused playback, reach the existing admission gates.
class BackgroundSyncPolicyTracker {
  new _({
    required SyncNetworkPolicy initialPolicy,
    required this._hasActivePlayback,
    required this._readConnectivity,
    required this._connectivityChanges,
    required this._readNativeMetered,
    required this._backgroundSyncUnmeteredOnly,
    required this._refreshInterval,
  }) : _current = initialPolicy;

  static Future<BackgroundSyncPolicyTracker> create({
    required Future<List<ConnectivityResult>> Function() readConnectivity,
    required Stream<List<ConnectivityResult>> connectivityChanges,
    required Future<bool> Function() readNativeMetered,
    required bool backgroundSyncUnmeteredOnly,
    Duration refreshInterval = const Duration(seconds: 2),
  }) async {
    final tracker = BackgroundSyncPolicyTracker._(
      hasActivePlayback: await _readPlaybackActive(),
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
  bool _hasActivePlayback;
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Timer? _refreshTimer;
  Future<void> _pendingRefresh = Future<void>.value();

  SyncNetworkPolicy get current => _current;

  bool get hasActivePlayback => _hasActivePlayback;

  void _start() {
    _subscription = _connectivityChanges.listen((_) => _queueRefresh());
    _refreshTimer = Timer.periodic(_refreshInterval, (_) => _queueRefresh());
  }

  Future<void> refresh() async {
    _hasActivePlayback = await _readPlaybackActive();
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

  static Future<bool> _readPlaybackActive() async {
    try {
      return await _backgroundSyncChannel.invokeMethod<bool>(
            'isPlaybackActive',
          ) ??
          true;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      return true;
    }
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
