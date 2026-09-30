import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/utils/latest_value_throttle.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/data/adaptive_library_sync_coordinator.dart';
import 'package:navis/src/features/library/data/android_background_sync.dart';
import 'package:navis/src/features/library/data/library_sync_execution_bootstrap.dart';
import 'package:navis/src/features/library/data/song_identity_cache_epoch.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:navis/src/utils/notifications/library_sync_notifier.dart';
import 'package:navis/src/utils/sync_diagnostics_overrides.dart';

/// Sync interval in minutes from user settings (0 = manual only).
/// The staleness window for the sync engine equals this interval so that
/// periodic ticks actually trigger a sync rather than being skipped.
final syncIntervalMinutesProvider = Provider<int>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.syncIntervalMinutes;
});

@visibleForTesting
final syncIntervalDurationProvider = Provider<Duration?>((ref) {
  final minutes = ref.watch(syncIntervalMinutesProvider);
  if (minutes <= 0) {
    return null;
  }
  return Duration(minutes: minutes);
});

final syncStaleAfterProvider = Provider<Duration>((ref) {
  final minutes = ref.watch(syncIntervalMinutesProvider);
  if (minutes <= 0) {
    // Manual-only: use a large staleness window so syncIfStale won't fire
    // on its own, but syncNow still works.
    return const Duration(hours: 24);
  }
  // Subtract a small tolerance so that when the periodic timer fires at
  // exactly the interval boundary the data is guaranteed to be considered
  // stale.  Without this, floating-point rounding can cause the check
  // `now.difference(lastSynced) < staleAfter` to pass, skipping the sync.
  final toleranceSeconds = (minutes * 60 * 0.05).round().clamp(10, 120);
  return Duration(seconds: minutes * 60 - toleranceSeconds);
});

/// Durable, server-scoped mutation evidence for Sync Settings.
///
/// This deliberately reads the operation ledger directly instead of keeping a
/// second in-memory history in the controller: a successful promotion must
/// remain explainable across navigation and process restarts.
final librarySyncOperationLedgerProvider =
    StreamProvider<List<LibrarySyncOperationLedgerTableData>>((ref) {
      final serverId = ref.watch(
        serverConfigStateProvider.select(
          (config) => config.asData?.value?.id,
        ),
      );
      if (serverId == null) {
        return Stream<List<LibrarySyncOperationLedgerTableData>>.value(
          const <LibrarySyncOperationLedgerTableData>[],
        );
      }
      return ref
          .watch(navisDatabaseProvider)
          .librarySyncDao
          .watchRecentOperationLedgerEntries(serverId);
    });

final librarySyncNotifierProvider = Provider<LibrarySyncNotifier>((ref) {
  return const SystemLibrarySyncNotifier();
});

final androidBackgroundSyncSchedulerProvider =
    Provider<AndroidBackgroundSyncScheduler>((ref) {
      return AndroidBackgroundSyncScheduler();
    });

final androidBackgroundSyncAvailableProvider = Provider<bool>((ref) {
  return AndroidBackgroundSyncScheduler.isSupported;
});

final androidBackgroundSyncReconcilerProvider =
    Provider<AndroidBackgroundSyncReconciler>((ref) {
      return AndroidBackgroundSyncReconciler(
        database: ref.watch(navisDatabaseProvider),
        scheduler: ref.watch(androidBackgroundSyncSchedulerProvider),
      );
    });

/// Durable redacted native scheduler state for Sync Settings and diagnostics.
final androidBackgroundSyncStatusProvider =
    StreamProvider<LibrarySyncStateTableData?>((ref) {
      final serverId = ref.watch(
        serverConfigStateProvider.select(
          (config) => config.asData?.value?.id,
        ),
      );
      if (serverId == null) {
        return Stream<LibrarySyncStateTableData?>.value(null);
      }
      return ref
          .watch(navisDatabaseProvider)
          .librarySyncDao
          .watchState(serverId);
    });

/// Enabled by default for release. A build can still set this to false for an
/// immediate rollback; reconciliation then cancels native work durably.
const bool _enableAndroidBackgroundSync = bool.fromEnvironment(
  'NAVIS_ENABLE_ANDROID_BACKGROUND_SYNC',
  defaultValue: true,
);

class LibrarySyncForegroundController extends Notifier<bool> {
  @override
  bool build() => true;

  void setForeground(bool value) {
    state = value;
  }
}

final librarySyncForegroundProvider =
    NotifierProvider<LibrarySyncForegroundController, bool>(
      LibrarySyncForegroundController.new,
    );

@visibleForTesting
final requiredLibrarySyncModelVersionProvider = Provider<String?>((ref) {
  return currentLibrarySyncModelVersion;
});

// v57 rebuilds the complete newest feed so every persisted library receives
// authoritative Recently Added ranks after the v73 repair.
/// Bumped for the stale-cache recovery release: the difference against a
/// stored value schedules exactly one post-upgrade recovery reconciliation
/// (a resumable full repair) per installation, and the new version is
/// stamped only after that repair's catalog promotion completed (plan §5).
const currentLibrarySyncModelVersion = '58';

const bool _syncDiagnosticsEnabled = bool.fromEnvironment(
  'NAVIS_SYNC_DIAGNOSTICS',
  defaultValue: false,
);

final librarySyncEngineProvider = Provider<LibrarySyncEngine?>((ref) {
  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    return null;
  }

  final database = ref.watch(navisDatabaseProvider);
  final repository = ref.watch(serverConfigRepositoryProvider);
  final staleAfter = ref.watch(syncStaleAfterProvider);
  // Read policy from the live root container at call time; do not watch network
  // providers here so a connectivity change cannot dispose an in-flight
  // coordinator. Reads through this provider's Ref are cached after the first
  // lookup, which can otherwise leave a long-lived engine on the old network
  // policy after reconnect.
  SyncNetworkPolicy readPolicy() {
    if (!ref.mounted) {
      return resolveSyncNetworkPolicy(
        networkType: NetworkType.other,
        nativeMetered: null,
        backgroundSyncUnmeteredOnly: true,
      );
    }
    return ref.container.read(syncNetworkPolicyProvider);
  }

  return LibrarySyncExecutionBootstrap.createCoordinator(
    client: api,
    database: database,
    serverConfigRepository: repository,
    staleAfter: staleAfter,
    initialNetworkType: ref.read(networkTypeProvider),
    readSyncNetworkPolicy: readPolicy,
    readMeteredResponseBudgetBytes: _syncDiagnosticsEnabled
        ? () {
            if (!ref.mounted) {
              return null;
            }
            return ref
                .read(syncDiagnosticsOverridesProvider)
                .meteredBudgetBytes;
          }
        : null,
    onBeforeSongIdentityRemap: (aliases) async {
      if (!ref.mounted) {
        return;
      }
      SongIdentityCacheEpoch.invalidate();
      await ref.read(audioHandlerProvider)?.applySongIdentityAliases(aliases);
    },
    readActiveSongId: () {
      if (!ref.mounted) {
        return null;
      }
      return ref.read(audioHandlerProvider)?.snapshot.currentSongId;
    },
    readProtectedSongIds: () {
      if (!ref.mounted) {
        return const <String>{};
      }
      final snapshot = ref.read(audioHandlerProvider)?.snapshot;
      if (snapshot == null) {
        return const <String>{};
      }
      return <String>{
        ...snapshot.queueSongIds,
        if (snapshot.currentSongId != null) snapshot.currentSongId!,
      };
    },
    readHasActivePlayback: () {
      if (!ref.mounted) {
        return false;
      }
      return ref.read(audioHandlerProvider)?.snapshot.hasActivePlayback ??
          false;
    },
    readIsForeground: () {
      if (!ref.mounted) {
        return true;
      }
      return ref.read(librarySyncForegroundProvider);
    },
    // Keep lease contention observable but bounded in the disposable runtime
    // diagnostic. Production retains its ten-minute, one-minute-heartbeat
    // cross-engine lease.
    executionLeaseTtl: _syncDiagnosticsEnabled
        ? Duration(
            seconds: const int.fromEnvironment(
              'NAVIS_SYNC_DIAGNOSTICS_LEASE_SECONDS',
              defaultValue: 6,
            ).clamp(1, 600),
          )
        : null,
    executionLeaseHeartbeatInterval: _syncDiagnosticsEnabled
        ? const Duration(seconds: 1)
        : null,
  );
});

final librarySyncControllerProvider =
    NotifierProvider<LibrarySyncController, LibrarySyncState>(
      LibrarySyncController.new,
    );

/// Minimum interval between count-only sync progress publications.
@visibleForTesting
const Duration librarySyncProgressPublishInterval = Duration(milliseconds: 250);

class LibrarySyncController extends Notifier<LibrarySyncState> {
  bool _startupSyncInFlight = false;
  bool _startupSyncSuppressed = false;
  int _startupSyncEpoch = 0;
  int _cancellationGeneration = 0;
  Future<LibrarySyncState>? _activeCatalogSync;
  int? _activeCatalogSyncPriority;
  Future<LibrarySyncState>? _activeAutomaticCheck;
  final Map<String, Future<LibrarySyncState>> _activeTargetSyncs =
      <String, Future<LibrarySyncState>>{};
  Future<void>? _startupSyncTask;
  bool _retryStartupWhenEngineReady = false;
  String? _startupSyncDoneFingerprint;
  String? _sessionFingerprint;
  ServerReachabilityStatus? _lastReachabilityStatus;
  bool _isForeground = true;
  ServerConfigModel? _androidScheduledConfig;
  final Queue<String> _priorityAlbumIds = Queue<String>();
  static const int _maxPriorityAlbums = 120;
  late final AppLifecycleListener _lifecycleListener;
  Timer? _periodicSyncTimer;
  int _automaticScheduleEpoch = 0;
  final Set<Future<void>> _automaticTimerArms = {};
  StreamSubscription<int>? _pendingWorkCountSub;
  StreamSubscription<int>? _pendingHydrationCountSub;

  @override
  LibrarySyncState build() {
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _isForeground =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    Future<void>.microtask(() {
      if (ref.mounted) {
        ref
            .read(librarySyncForegroundProvider.notifier)
            .setForeground(_isForeground);
      }
    });
    _lifecycleListener = AppLifecycleListener(
      onResume: _onAppResumed,
      onInactive: _onAppBackgrounded,
      onPause: _onAppBackgrounded,
      onHide: _onAppBackgrounded,
      onDetach: _onAppBackgrounded,
    );
    ref.onDispose(() {
      _lifecycleListener.dispose();
      _cancelPeriodicSync();
      _cancelBacklogWatchers();
    });

    final serverConfig = ref.read(serverConfigStateProvider).asData?.value;
    if (serverConfig != null) {
      _sessionFingerprint = _toSessionFingerprint(serverConfig);
      unawaited(_loadPersistedSyncState(serverConfig));
      unawaited(_reconcileAndroidBackgroundSchedule(config: serverConfig));
    }
    _lastReachabilityStatus = ref
        .read(serverReachabilityControllerProvider)
        .status;

    ref.listen<AsyncValue<ServerConfigModel?>>(
      serverConfigStateProvider,
      (_, next) => _onServerConfigChanged(next),
    );
    ref.listen<ServerReachabilityState>(
      serverReachabilityControllerProvider,
      (_, next) => _onReachabilityChanged(next),
    );
    ref.listen<int>(
      syncIntervalMinutesProvider,
      (previous, next) {
        // App settings hydrate asynchronously. That first value is not a user
        // changing their preference and must not erase a server's persisted
        // deadline simply because the controller was rebuilt.
        if (previous != null && previous != next) {
          _onSyncIntervalChanged(next);
        }
      },
    );
    // Do not create the app-settings-backed network-policy provider on other
    // platforms. Besides avoiding needless database work, this preserves the
    // controller's test and desktop lifecycle without a mobile scheduler.
    if (ref.read(androidBackgroundSyncAvailableProvider)) {
      ref.listen<bool>(backgroundSyncUnmeteredOnlyProvider, (previous, next) {
        if (previous != null && previous != next) {
          unawaited(_reconcileAndroidBackgroundSchedule(enqueueCatchup: true));
        }
      });
    }
    ref.listen<NetworkType>(networkTypeProvider, (previous, next) {
      final becameAvailable =
          previous == NetworkType.offline && next != NetworkType.offline;
      final becameWifi =
          next == NetworkType.wifi && previous != NetworkType.wifi;
      if (becameWifi) {
        _startupSyncDoneFingerprint = null;
      }
      if (becameAvailable || becameWifi) {
        _scheduleStartupSync();
      }
    });
    ref.listen<LibrarySyncEngine?>(librarySyncEngineProvider, (previous, next) {
      // A session can become visible before its credential-backed API client
      // is ready. Do not strand the shell's startup pass in that brief gap;
      // start it once the production engine is available.
      if (next != null) {
        if (_startupSyncTask != null) {
          _retryStartupWhenEngineReady = true;
          return;
        }
        _scheduleStartupSync();
      }
    });

    // Kick off the periodic timer with the current interval.
    final intervalMinutes = ref.read(syncIntervalMinutesProvider);
    _schedulePeriodicSync(intervalMinutes);

    Future<void>.microtask(_scheduleStartupSync);
    return LibrarySyncState.idle(
      lastSyncedAt: serverConfig?.lastSynced,
      freshness: _readPersistedFreshness(serverConfig?.capabilitiesJson),
    );
  }

  Future<LibrarySyncState> syncIfStale() {
    final active = _activeAutomaticCheck;
    if (active != null) {
      return active;
    }
    final task = _runAutomaticCheckIfDue();
    _activeAutomaticCheck = task;
    return task.whenComplete(() {
      if (identical(_activeAutomaticCheck, task)) {
        _activeAutomaticCheck = null;
      }
    });
  }

  Future<LibrarySyncState> syncNow({bool allowMeteredBroadOverride = false}) {
    return _runSync(
      force: true,
      tolerateUnavailableEngine: false,
      allowMeteredBroadOverride: allowMeteredBroadOverride,
    );
  }

  Future<LibrarySyncState> forceFullSync({
    bool allowMeteredBroadOverride = false,
  }) {
    return _runSync(
      force: true,
      tolerateUnavailableEngine: false,
      forceFull: true,
      allowMeteredBroadOverride: allowMeteredBroadOverride,
    );
  }

  /// Starts the explicit, non-destructive server-catalog repair flow.
  ///
  /// Keep this separate from [resetCachesAndRebuildLibrary]: both collect a
  /// catalog, but only the latter has already erased local device caches.
  ///
  /// The mobile-data consent lives in a controller-owned session for the whole
  /// run, so automatic retries and reconnects keep the grant, and the grant is
  /// always cleared on completion, failure, or cancellation.
  Future<LibrarySyncState> repairLibrary({
    bool allowMeteredBroadOverride = false,
  }) async {
    final engine = ref.read(librarySyncEngineProvider);
    final serverId = ref.read(serverConfigStateProvider).asData?.value?.id;
    final coordinator = engine is AdaptiveLibrarySyncCoordinator
        ? engine
        : null;
    if (coordinator != null && serverId != null) {
      coordinator.beginRepairSession(
        serverId: serverId,
        allowMetered: allowMeteredBroadOverride,
      );
    }
    try {
      return await _runSync(
        force: true,
        tolerateUnavailableEngine: false,
        forceFull: true,
        allowMeteredBroadOverride: allowMeteredBroadOverride,
        caller: LibrarySyncRequestCaller.repairLibrary,
      );
    } finally {
      coordinator?.endRepairSession(serverId: serverId);
    }
  }

  /// Starts a fresh catalog build after the device-storage reset flow.
  Future<LibrarySyncState> resetCachesAndRebuildLibrary({
    bool allowMeteredBroadOverride = false,
  }) {
    return _runSync(
      force: true,
      tolerateUnavailableEngine: false,
      forceFull: true,
      allowMeteredBroadOverride: allowMeteredBroadOverride,
      caller: LibrarySyncRequestCaller.cacheReset,
    );
  }

  /// Abandons an uncommitted deletion-confirmation candidate while retaining
  /// the currently committed offline catalog.
  Future<bool> discardAwaitingRepairCandidate() async {
    final config = ref.read(serverConfigStateProvider).asData?.value;
    final serverId = config?.id;
    final generation = state.candidateGeneration;
    if (serverId == null ||
        generation == null ||
        state.candidateStatus != 'awaitingDeletionConfirmation') {
      return false;
    }
    final discarded = await ref
        .read(navisDatabaseProvider)
        .librarySyncDao
        .discardAwaitingRepairCandidate(
          serverId: serverId,
          generation: generation,
        );
    if (discarded && ref.mounted) {
      state = state.copyWith(
        clearCandidateGeneration: true,
        clearCandidateStatus: true,
        deletionCandidateCount: 0,
        carriedForwardEntityCount: 0,
      );
    }
    return discarded;
  }

  Future<LibrarySyncState> syncUsingMobileData() {
    return syncNow(allowMeteredBroadOverride: true);
  }

  /// Cancel a running sync while retaining its durable work for resume.
  void cancelSync() {
    _cancellationGeneration++;
    final engine = ref.read(librarySyncEngineProvider);
    if (engine is AdaptiveLibrarySyncCoordinator) {
      engine.cancelSync();
      // Cancellation always clears the in-session mobile-data grant.
      engine.endRepairSession();
    } else if (engine is DriftLibrarySyncEngine) {
      engine.cancelSync();
    }
  }

  Future<void> cancelAndWait() async {
    _cancelPeriodicSync();
    _startupSyncSuppressed = true;
    _startupSyncEpoch++;
    final engine = ref.read(librarySyncEngineProvider);
    cancelSync();
    final startupTask = _startupSyncTask;
    if (startupTask != null) {
      await startupTask;
    }
    if (engine is AdaptiveLibrarySyncCoordinator) {
      await engine.cancelAndWait();
    } else if (engine is DriftLibrarySyncEngine) {
      await engine.cancelAndWait();
    }
    // The automatic check owns a final schedule write after its engine returns.
    // Drain that owner as well as the engine before a caller closes Drift.
    final automaticCheck = _activeAutomaticCheck;
    if (automaticCheck != null) {
      await automaticCheck;
    }
    await Future.wait(_automaticTimerArms.toList());
    _cancelPeriodicSync();
    if (ref.mounted) {
      state = state.copyWith(
        status: LibrarySyncStatus.cancelled,
        stage: LibrarySyncStage.completed,
        completedAt: DateTime.now(),
      );
      await ref.read(librarySyncNotifierProvider).dismissProgress();
    }
  }

  Future<LibrarySyncState> requestTarget(LibrarySyncTarget target) async {
    final engine = ref.read(librarySyncEngineProvider);
    if (engine == null) {
      return state;
    }
    return _joinOrStartTargetSync(
      target,
      () => _runRequest(
        engine,
        LibrarySyncRequest(
          trigger: LibrarySyncTrigger.interaction,
          intent: LibrarySyncIntent.checkForUpdates,
          target: target,
        ),
      ),
    );
  }

  Future<LibrarySyncState> requestTargetIfStale(
    LibrarySyncTarget target,
  ) async {
    final engine = ref.read(librarySyncEngineProvider);
    if (engine == null) {
      return state;
    }
    return _joinOrStartTargetSync(
      target,
      () => _runRequest(
        engine,
        LibrarySyncRequest(
          trigger: LibrarySyncTrigger.interaction,
          intent: LibrarySyncIntent.automatic,
          target: target,
        ),
      ),
    );
  }

  void setVisibleAlbumIds(Iterable<String> albumIds) {
    for (final albumId in albumIds) {
      _addPriorityAlbum(albumId);
    }
  }

  void registerAlbumInteraction(String albumId) {
    _addPriorityAlbum(albumId);
    unawaited(_requestAlbumHydrationIfNeeded(albumId));
  }

  void registerArtistInteraction(String artistId) {
    unawaited(_requestArtistHydrationIfNeeded(artistId));
  }

  Future<LibrarySyncState> refreshArtist(String artistId) {
    final normalizedId = artistId.trim();
    if (normalizedId.isEmpty) {
      return Future<LibrarySyncState>.value(state);
    }
    return requestTarget(LibrarySyncTarget.artist(normalizedId));
  }

  Future<void> _requestAlbumHydrationIfNeeded(String albumId) async {
    final normalizedId = albumId.trim();
    if (normalizedId.isEmpty) {
      return;
    }
    final album = await ref
        .read(navisDatabaseProvider)
        .libraryDao
        .getAlbumById(normalizedId);
    if (!ref.mounted || album?.songsHydrated == true) {
      return;
    }
    await requestTarget(LibrarySyncTarget.album(normalizedId));
  }

  Future<void> _requestArtistHydrationIfNeeded(String artistId) async {
    final normalizedId = artistId.trim();
    if (normalizedId.isEmpty) {
      return;
    }
    final dao = ref.read(navisDatabaseProvider).libraryDao;
    final artist = await dao.getArtistById(normalizedId);
    final albums = await dao.watchAlbumsByArtist(normalizedId).first;
    final needsHydration =
        artist == null ||
        artist.albumCount == null ||
        albums.length < artist.albumCount!;
    if (!ref.mounted || !needsHydration) {
      return;
    }
    await requestTarget(LibrarySyncTarget.artist(normalizedId));
  }

  void _onServerConfigChanged(AsyncValue<ServerConfigModel?> next) {
    if (next.isLoading && !next.hasValue) {
      return;
    }

    final serverConfig = next.asData?.value;
    if (serverConfig == null) {
      final scheduled = _androidScheduledConfig;
      if (scheduled != null) {
        unawaited(
          ref
              .read(androidBackgroundSyncReconcilerProvider)
              .cancelFor(scheduled),
        );
      }
      _androidScheduledConfig = null;
      _startupSyncSuppressed = true;
      _startupSyncEpoch++;
      _startupSyncInFlight = false;
      _retryStartupWhenEngineReady = false;
      _startupSyncDoneFingerprint = null;
      _sessionFingerprint = null;
      state = const LibrarySyncState.idle();
      _priorityAlbumIds.clear();
      return;
    }

    final fingerprint = _toSessionFingerprint(serverConfig);
    if (_sessionFingerprint != fingerprint) {
      _startupSyncSuppressed = false;
      _startupSyncEpoch++;
      _startupSyncInFlight = false;
      _retryStartupWhenEngineReady = false;
      _startupSyncDoneFingerprint = null;
      _sessionFingerprint = fingerprint;
      _priorityAlbumIds.clear();
      state = LibrarySyncState.idle(
        lastSyncedAt: serverConfig.lastSynced,
        freshness: _readPersistedFreshness(serverConfig.capabilitiesJson),
      );
      unawaited(_loadPersistedSyncState(serverConfig));
    }
    unawaited(_reconcileAndroidBackgroundSchedule(config: serverConfig));
    _scheduleStartupSync();
  }

  Future<void> _reconcileAndroidBackgroundSchedule({
    ServerConfigModel? config,
    bool enqueueCatchup = false,
  }) async {
    if (!ref.read(androidBackgroundSyncAvailableProvider)) {
      return;
    }
    final active = config ?? ref.read(serverConfigStateProvider).asData?.value;
    if (active == null || !ref.mounted) {
      return;
    }
    final previous = _androidScheduledConfig;
    if (previous != null &&
        AndroidBackgroundSyncScheduler.profileKeyFor(previous) !=
            AndroidBackgroundSyncScheduler.profileKeyFor(active)) {
      await ref
          .read(androidBackgroundSyncReconcilerProvider)
          .cancelFor(previous);
    }
    final serverId = active.id;
    if (serverId == null) {
      return;
    }
    final dao = ref.read(navisDatabaseProvider).librarySyncDao;
    final persisted = await dao.getOrCreateState(serverId);
    final becameEnabled =
        _enableAndroidBackgroundSync && !persisted.androidBackgroundSyncEnabled;
    if (persisted.androidBackgroundSyncEnabled !=
        _enableAndroidBackgroundSync) {
      await dao.setAndroidBackgroundSyncEnabled(
        serverId: serverId,
        enabled: _enableAndroidBackgroundSync,
      );
    }
    if (!ref.mounted || _sessionFingerprint != _toSessionFingerprint(active)) {
      return;
    }
    await ref
        .read(androidBackgroundSyncReconcilerProvider)
        .reconcile(
          config: active,
          intervalMinutes: ref.read(syncIntervalMinutesProvider),
          unmeteredOnly: ref.read(backgroundSyncUnmeteredOnlyProvider),
          enqueueCatchup: enqueueCatchup || becameEnabled,
        );
    _androidScheduledConfig = active;
  }

  LibrarySyncFreshness _readPersistedFreshness(String? capabilitiesJson) {
    if (capabilitiesJson == null || capabilitiesJson.trim().isEmpty) {
      return LibrarySyncFreshness.verificationPending;
    }
    try {
      final root = jsonDecode(capabilitiesJson);
      if (root is! Map<String, dynamic>) {
        return LibrarySyncFreshness.verificationPending;
      }
      final navis = root['navis'];
      if (navis is! Map<String, dynamic>) {
        return LibrarySyncFreshness.verificationPending;
      }
      final value = navis['libraryFreshness'];
      return LibrarySyncFreshness.values.firstWhere(
        (freshness) => freshness.name == value,
        orElse: () => LibrarySyncFreshness.verificationPending,
      );
    } on FormatException {
      return LibrarySyncFreshness.verificationPending;
    }
  }

  /// Keeps run-independent backlog counters live between sync runs so the
  /// UI can show queued work honestly. While a run is in flight the engine
  /// owns these state fields and the stream defers to it.
  void _watchBacklogCounts(NavisDatabase database, int serverId) {
    _cancelBacklogWatchers();
    _pendingWorkCountSub = database.librarySyncDao
        .watchPendingWork(serverId)
        .listen((count) {
          if (!ref.mounted ||
              state.isRunning ||
              state.pendingWorkCount == count) {
            return;
          }
          state = state.copyWith(pendingWorkCount: count);
        });
    _pendingHydrationCountSub = database.libraryDao
        .watchPendingHydrationAlbums()
        .listen((count) {
          if (!ref.mounted ||
              state.isRunning ||
              state.pendingHydrationCount == count) {
            return;
          }
          state = state.copyWith(pendingHydrationCount: count);
        });
  }

  void _cancelBacklogWatchers() {
    unawaited(_pendingWorkCountSub?.cancel());
    unawaited(_pendingHydrationCountSub?.cancel());
    _pendingWorkCountSub = null;
    _pendingHydrationCountSub = null;
  }

  Future<void> _loadPersistedSyncState(ServerConfigModel config) async {
    final serverId = config.id;
    if (serverId == null) {
      return;
    }
    final database = ref.read(navisDatabaseProvider);
    _watchBacklogCounts(database, serverId);
    final persisted = await database.librarySyncDao.getOrCreateState(serverId);
    final pending = await database.librarySyncDao.countPendingWork(serverId);
    if (!ref.mounted ||
        _sessionFingerprint != _toSessionFingerprint(config) ||
        state.isRunning) {
      return;
    }
    final storedPlan = LibrarySyncPlanKind.values.where(
      (kind) => kind.name == persisted.lastPlanKind,
    );
    state = state.copyWith(
      lastCheckedAt: persisted.lastCheckedAt,
      nextAutomaticCheckAt: persisted.nextAutomaticCheckAt,
      nextRetryAt: persisted.nextEligibleAt,
      lastCatalogUpdatedAt: persisted.lastCatalogSyncedAt,
      lastAuxiliarySyncedAt: persisted.lastAuxiliarySyncedAt,
      lastGenresSyncedAt: persisted.lastGenresSyncedAt,
      planKind: storedPlan.isEmpty ? state.planKind : storedPlan.first,
      planReason: persisted.lastPlanReason,
      pendingWorkCount: pending,
      lastRunBytes: persisted.lastRunBytes,
      apiRequests: persisted.lastRunRequests,
      candidateGeneration: persisted.candidateGeneration,
      candidateStatus: persisted.candidateStatus,
      deletionCandidateCount: persisted.deletionCandidateCount,
    );
    _schedulePeriodicSync(ref.read(syncIntervalMinutesProvider));
  }

  void _onReachabilityChanged(ServerReachabilityState next) {
    final previous = _lastReachabilityStatus;
    _lastReachabilityStatus = next.status;

    if (previous == ServerReachabilityStatus.offline &&
        next.status == ServerReachabilityStatus.online) {
      _startupSyncDoneFingerprint = null;
    }

    _scheduleStartupSync();
  }

  void _scheduleStartupSync() {
    if (_startupSyncSuppressed || _startupSyncTask != null) {
      return;
    }
    final epoch = _startupSyncEpoch;
    final task = _maybeRunStartupSync(epoch);
    _startupSyncTask = task;
    unawaited(
      task.whenComplete(() {
        if (identical(_startupSyncTask, task)) {
          _startupSyncTask = null;
          if (_retryStartupWhenEngineReady) {
            _retryStartupWhenEngineReady = false;
            _scheduleStartupSync();
          }
        }
      }),
    );
  }

  Future<void> _maybeRunStartupSync(int epoch) async {
    if (!ref.mounted ||
        _startupSyncSuppressed ||
        epoch != _startupSyncEpoch ||
        _startupSyncInFlight) {
      return;
    }

    final config = ref.read(serverConfigStateProvider).asData?.value;
    if (config == null) {
      return;
    }

    final serverId = config.id;
    if (serverId != null && config.lastSynced == null) {
      await ref
          .read(navisDatabaseProvider)
          .librarySyncDao
          .getOrCreateState(serverId);
      if (!ref.mounted ||
          _startupSyncSuppressed ||
          epoch != _startupSyncEpoch) {
        return;
      }
      // First-time catalog collection runs from the normal application shell.
      // The planner still selects the full candidate snapshot when no
      // generation is committed; routing must not be the sync owner.
    }

    final reachability = ref.read(serverReachabilityControllerProvider);
    if (reachability.status == ServerReachabilityStatus.offline) {
      return;
    }

    final fingerprint = _toSessionFingerprint(config);
    if (_startupSyncDoneFingerprint == fingerprint) {
      return;
    }

    if (_startupSyncSuppressed || epoch != _startupSyncEpoch) {
      return;
    }
    _startupSyncInFlight = true;
    final database = ref.read(navisDatabaseProvider);
    final requiredSyncModelVersion = ref.read(
      requiredLibrarySyncModelVersionProvider,
    );
    final lastSyncModelVersion = await database.appSettingsDao
        .getLastFullSyncAppBuild();
    if (!ref.mounted || _startupSyncSuppressed || epoch != _startupSyncEpoch) {
      _startupSyncInFlight = false;
      return;
    }
    final requiresSyncModelRepair =
        requiredSyncModelVersion != null &&
        lastSyncModelVersion != requiredSyncModelVersion;

    final networkType = ref.read(networkTypeProvider);
    final deferFullResyncOnMobile =
        requiresSyncModelRepair && networkType == NetworkType.cellular;
    if (deferFullResyncOnMobile) {
      AppLogger.debug(
        'Startup library sync model repair deferred on cellular for model '
        '$requiredSyncModelVersion.',
      );
    }
    try {
      final result = await (requiresSyncModelRepair && !deferFullResyncOnMobile
          ? _runSync(
              force: true,
              forceFull: true,
              tolerateUnavailableEngine: true,
            )
          : syncIfStale());
      if (!ref.mounted || epoch != _startupSyncEpoch) {
        return;
      }
      final completedSyncModelRepair =
          requiresSyncModelRepair &&
          !deferFullResyncOnMobile &&
          (result.status == LibrarySyncStatus.succeeded ||
              (result.status == LibrarySyncStatus.partial &&
                  result.metadataReady &&
                  result.candidateGeneration == null &&
                  result.candidateStatus == null));
      final completedStartupPass =
          result.status == LibrarySyncStatus.succeeded ||
          result.status == LibrarySyncStatus.partial ||
          completedSyncModelRepair ||
          result.status == LibrarySyncStatus.failed ||
          (!deferFullResyncOnMobile &&
              result.status == LibrarySyncStatus.skipped);
      if (completedStartupPass) {
        _startupSyncDoneFingerprint = fingerprint;
      }
      if (completedSyncModelRepair) {
        unawaited(
          database.appSettingsDao.setLastFullSyncAppBuild(
            requiredSyncModelVersion,
          ),
        );
      }
    } finally {
      _startupSyncInFlight = false;
    }
  }

  Future<LibrarySyncState> _runAutomaticCheckIfDue() async {
    final config = ref.read(serverConfigStateProvider).asData?.value;
    final serverId = config?.id;
    // The controller can be constructed while a session is still being saved
    // (and in narrow controller tests without a persisted server). There is
    // no durable schedule to consult in that state, so retain the engine's
    // existing bootstrap semantics rather than suppressing initial sync.
    if (serverId == null) {
      return _runSync(force: false, tolerateUnavailableEngine: true);
    }
    final interval = ref.read(syncIntervalDurationProvider);
    if (interval == null || !ref.mounted) {
      return state;
    }

    final nextCheckAt = await _ensureAutomaticCheckSchedule(interval);
    if (!ref.mounted || nextCheckAt == null) {
      return state;
    }
    final now = DateTime.now().toUtc();
    final automaticCheckIsDue = !nextCheckAt.isAfter(now);
    final hasEligibleManualCatalogWork = await _hasEligibleManualCatalogWork(
      serverId,
      now,
    );
    if (!automaticCheckIsDue && !hasEligibleManualCatalogWork) {
      _schedulePeriodicSync(ref.read(syncIntervalMinutesProvider));
      return state;
    }

    final result = await _runSync(
      force: false,
      tolerateUnavailableEngine: true,
    );
    if (automaticCheckIsDue && result.completedAt != null) {
      await _recordAutomaticCheckCompletion(interval);
    }
    if (ref.mounted) {
      _schedulePeriodicSync(ref.read(syncIntervalMinutesProvider));
    }
    return result;
  }

  /// A deferred user action must not be held behind a future automatic
  /// deadline. In particular, an offline Check for updates preserves bounded
  /// delta discovery for the next eligible connection. Full repair remains
  /// deliberately excluded because it always requires another explicit Repair
  /// Library action.
  Future<bool> _hasEligibleManualCatalogWork(
    int serverId,
    DateTime now,
  ) async {
    final work = await ref
        .read(navisDatabaseProvider)
        .librarySyncDao
        .getRunnableWork(serverId: serverId, now: now, limit: 8);
    return work.any(
      (item) =>
          item.entityId.isEmpty &&
          item.kind != LibrarySyncPlanKind.fullRepair.name &&
          item.priority >= 60,
    );
  }

  Future<DateTime?> _ensureAutomaticCheckSchedule(Duration interval) async {
    final config = ref.read(serverConfigStateProvider).asData?.value;
    final serverId = config?.id;
    if (serverId == null) {
      return null;
    }
    final dao = ref.read(navisDatabaseProvider).librarySyncDao;
    final persisted = await dao.getOrCreateState(serverId);
    final existing = persisted.nextAutomaticCheckAt;
    if (existing != null) {
      return existing;
    }
    final now = DateTime.now().toUtc();
    final anchor = persisted.lastCheckedAt ?? config?.lastSynced;
    final next = anchor == null ? now : anchor.add(interval);
    await dao.setNextAutomaticCheckAt(
      serverId: serverId,
      nextAutomaticCheckAt: next,
    );
    if (ref.mounted && _sessionFingerprint == _toSessionFingerprint(config!)) {
      state = state.copyWith(nextAutomaticCheckAt: next);
    }
    return next;
  }

  Future<void> _recordAutomaticCheckCompletion(Duration interval) async {
    final config = ref.read(serverConfigStateProvider).asData?.value;
    final serverId = config?.id;
    if (serverId == null) {
      return;
    }
    final next = DateTime.now().toUtc().add(interval);
    await ref
        .read(navisDatabaseProvider)
        .librarySyncDao
        .setNextAutomaticCheckAt(
          serverId: serverId,
          nextAutomaticCheckAt: next,
        );
    if (ref.mounted && _sessionFingerprint == _toSessionFingerprint(config!)) {
      state = state.copyWith(nextAutomaticCheckAt: next);
    }
  }

  Future<LibrarySyncState> _runSync({
    required bool force,
    required bool tolerateUnavailableEngine,
    bool forceFull = false,
    bool allowMeteredBroadOverride = false,
    LibrarySyncRequestCaller caller = LibrarySyncRequestCaller.unspecified,
  }) async {
    return _joinOrQueueCatalogSync(
      priority: forceFull
          ? 2
          : force
          ? 1
          : 0,
      start: () => _runSyncOnce(
        force: force,
        tolerateUnavailableEngine: tolerateUnavailableEngine,
        forceFull: forceFull,
        allowMeteredBroadOverride: allowMeteredBroadOverride,
        caller: caller,
      ),
    );
  }

  /// Coalesces equivalent catalog work while preserving stronger user intent.
  ///
  /// In particular, a manual refresh or repair requested while an automatic
  /// interval check is active must run after that check; returning the weaker
  /// request's result makes an explicit command appear to have succeeded
  /// without ever performing its requested work.
  Future<LibrarySyncState> _joinOrQueueCatalogSync({
    required int priority,
    required Future<LibrarySyncState> Function() start,
  }) {
    final active = _activeCatalogSync;
    final activePriority = _activeCatalogSyncPriority;
    if (active != null &&
        activePriority != null &&
        activePriority >= priority) {
      return active;
    }

    final generation = _cancellationGeneration;
    Future<LibrarySyncState> startUnlessCancelled() async {
      if (!ref.mounted || generation != _cancellationGeneration) {
        return LibrarySyncState(
          status: LibrarySyncStatus.cancelled,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
        );
      }
      return start();
    }

    final task = active == null
        ? startUnlessCancelled()
        : active.then<LibrarySyncState>(
            (_) => startUnlessCancelled(),
            onError: (error, _) => startUnlessCancelled(),
          );
    _activeCatalogSync = task;
    _activeCatalogSyncPriority = priority;
    return task.whenComplete(() {
      if (identical(_activeCatalogSync, task)) {
        _activeCatalogSync = null;
        _activeCatalogSyncPriority = null;
      }
    });
  }

  /// Target hydration is page-scoped. It may share a durable executor with
  /// catalog sync, but it must not share catalog UI state or satisfy a catalog
  /// request. Dedupe only the same durable target key.
  Future<LibrarySyncState> _joinOrStartTargetSync(
    LibrarySyncTarget target,
    Future<LibrarySyncState> Function() start,
  ) {
    final key = librarySyncTargetWorkKey(target);
    final active = _activeTargetSyncs[key];
    if (active != null) {
      return active;
    }
    final task = start();
    _activeTargetSyncs[key] = task;
    return task.whenComplete(() {
      if (identical(_activeTargetSyncs[key], task)) {
        unawaited(_activeTargetSyncs.remove(key));
      }
    });
  }

  Future<LibrarySyncState> _runSyncOnce({
    required bool force,
    required bool tolerateUnavailableEngine,
    required bool forceFull,
    required bool allowMeteredBroadOverride,
    required LibrarySyncRequestCaller caller,
  }) async {
    final engine = ref.read(librarySyncEngineProvider);
    final notifier = ref.read(librarySyncNotifierProvider);
    if (engine == null) {
      if (tolerateUnavailableEngine) {
        // Startup/periodic work is not a user-visible failed sync merely
        // because the credential-backed API provider is still initializing.
        return state;
      }
      state = state.copyWith(
        status: LibrarySyncStatus.failed,
        stage: LibrarySyncStage.completed,
        completedAt: DateTime.now(),
        errorMessage: 'Metadata sync unavailable for current session.',
        clearRunIdentity: true,
        apiRequests: 0,
        endpointRequests: const {},
        apiRetries: 0,
        apiFailures: 0,
        lastRunBytes: 0,
        dbWriteBatches: 0,
        clearAverageLatencyMs: true,
      );
      return state;
    }

    final stateBeforeRequest = state;
    // Planning performs durable work before its first detailed frame. Make an
    // explicit rescan visibly running immediately instead of leaving the UI
    // idle between the shortcut and catalog collection.
    state = state.copyWith(
      status: LibrarySyncStatus.running,
      stage: LibrarySyncStage.preparing,
      clearRunIdentity: true,
      apiRequests: 0,
      endpointRequests: const {},
      apiRetries: 0,
      apiFailures: 0,
      lastRunBytes: 0,
      dbWriteBatches: 0,
      clearAverageLatencyMs: true,
      mode: forceFull
          ? LibrarySyncMode.forceFull
          : force
          ? LibrarySyncMode.incremental
          : state.mode,
      metadataReady: false,
      isHydrating: false,
      fastPathActive: false,
      clearProcessed: true,
      clearTotal: true,
      clearHydratedAlbums: true,
      clearPendingHydrationCount: true,
      onlyIncompleteAlbumDetails: false,
      catalogPublishedThisRun: false,
      startedAt: DateTime.now(),
      clearCompletedAt: true,
      clearErrorMessage: true,
      clearHydrationThroughput: true,
      planKind: forceFull
          ? LibrarySyncPlanKind.fullRepair
          : force
          ? LibrarySyncPlanKind.deltaReconcile
          : state.planKind,
      clearPlanReason: true,
      clearCandidateGeneration: true,
      clearCandidateStatus: true,
    );
    unawaited(notifier.showProgress(state));

    final result = await _executeSync(
      engine: engine,
      force: force,
      forceFull: forceFull,
      allowMeteredBroadOverride: allowMeteredBroadOverride,
      caller: caller,
      onProgressExternal: (progress) {
        if (progress.status == LibrarySyncStatus.running) {
          unawaited(notifier.showProgress(progress));
        }
      },
    );
    if (!ref.mounted) {
      return result;
    }
    if (result.status == LibrarySyncStatus.succeeded &&
        result.startedAt != null) {
      final aliases = await ref
          .read(navisDatabaseProvider)
          .songIdentityDao
          .getAliasesMatchedSince(result.startedAt!);
      if (aliases.isNotEmpty) {
        SongIdentityCacheEpoch.invalidate();
        await ref.read(audioHandlerProvider)?.applySongIdentityAliases(
          <String, String>{
            for (final alias in aliases) alias.oldSongId: alias.canonicalSongId,
          },
        );
      }
    }

    // A no-op automatic pass must never erase a failure the user still needs
    // to see and retry.  This commonly happened when startup/periodic work
    // joined after a transient failure and returned `skipped`.
    final preserveFailure =
        !force &&
        stateBeforeRequest.status == LibrarySyncStatus.failed &&
        (result.status == LibrarySyncStatus.skipped ||
            result.status == LibrarySyncStatus.deferred ||
            result.status == LibrarySyncStatus.cancelled);
    if (preserveFailure) {
      state = stateBeforeRequest;
      return stateBeforeRequest;
    }
    // The engine owns catalog result fields, but automatic scheduling is a
    // controller-owned durable contract. A manual result must not blank the
    // in-memory deadline while the persisted value remains valid.
    state = result.copyWith(nextAutomaticCheckAt: state.nextAutomaticCheckAt);
    switch (result.status) {
      case LibrarySyncStatus.succeeded:
      case LibrarySyncStatus.partial:
        unawaited(notifier.showComplete(result));
      case LibrarySyncStatus.failed:
        unawaited(notifier.showFailed(result));
      case LibrarySyncStatus.skipped:
      case LibrarySyncStatus.deferred:
      case LibrarySyncStatus.cancelled:
      case LibrarySyncStatus.idle:
        unawaited(notifier.dismissProgress());
      case LibrarySyncStatus.running:
        break;
    }

    return result;
  }

  Future<LibrarySyncState> _runRequest(
    LibrarySyncEngine engine,
    LibrarySyncRequest request,
  ) async {
    final result = await engine.requestSync(
      request,
      priorityAlbumIds: _priorityAlbumIds,
      // Target hydration has its own page-level loading/error surfaces. Do
      // not overwrite the persistent catalog status while a detail page or
      // playlist asks for one entity.
      onProgress: null,
    );
    return result;
  }

  String _toSessionFingerprint(ServerConfigModel config) {
    return '${config.url}|${config.username}|${config.apiVersion}|${config.useLegacyAuth}';
  }

  void _addPriorityAlbum(String albumId) {
    final normalized = albumId.trim();
    if (normalized.isEmpty) {
      return;
    }
    _priorityAlbumIds.remove(normalized);
    _priorityAlbumIds.addFirst(normalized);
    while (_priorityAlbumIds.length > _maxPriorityAlbums) {
      _priorityAlbumIds.removeLast();
    }
  }

  Future<LibrarySyncState> _executeSync({
    required LibrarySyncEngine engine,
    required bool force,
    required bool forceFull,
    required bool allowMeteredBroadOverride,
    required LibrarySyncRequestCaller caller,
    required void Function(LibrarySyncState progress) onProgressExternal,
  }) {
    // Engines report progress per artist or album batch, and every published
    // state rebuilds each listener (shell, Home, Library). Status and stage
    // changes publish immediately; count-only updates at most every 250 ms.
    // A held update is dropped once the run returns, because the caller
    // publishes the final result itself.
    final throttle = LatestValueThrottle<LibrarySyncState>(
      interval: librarySyncProgressPublishInterval,
      onPublish: (progress) {
        if (ref.mounted) {
          state = progress;
        }
      },
    );

    void updateProgress(LibrarySyncState progress) {
      onProgressExternal(progress);
      final current = ref.mounted ? state : null;
      throttle.add(
        progress,
        urgent:
            current == null ||
            current.status != progress.status ||
            current.stage != progress.stage,
      );
    }

    return _runSyncEngine(
      engine: engine,
      force: force,
      forceFull: forceFull,
      allowMeteredBroadOverride: allowMeteredBroadOverride,
      caller: caller,
      updateProgress: updateProgress,
    ).whenComplete(throttle.close);
  }

  Future<LibrarySyncState> _runSyncEngine({
    required LibrarySyncEngine engine,
    required bool force,
    required bool forceFull,
    required bool allowMeteredBroadOverride,
    required LibrarySyncRequestCaller caller,
    required void Function(LibrarySyncState progress) updateProgress,
  }) {
    if (engine is AdaptiveLibrarySyncCoordinator) {
      final request = forceFull
          ? caller == LibrarySyncRequestCaller.cacheReset
                ? LibrarySyncRequest.cacheReset(
                    allowMeteredBroadOverride: allowMeteredBroadOverride,
                  )
                : LibrarySyncRequest.repair(
                    allowMeteredBroadOverride: allowMeteredBroadOverride,
                  )
          : force
          ? LibrarySyncRequest.checkForUpdates(
              allowMeteredBroadOverride: allowMeteredBroadOverride,
            )
          : const LibrarySyncRequest.automatic();
      return engine.requestSync(
        request,
        priorityAlbumIds: _priorityAlbumIds,
        onProgress: updateProgress,
      );
    }
    return force
        ? forceFull
              ? engine.forceFullSync(
                  priorityAlbumIds: _priorityAlbumIds,
                  onProgress: updateProgress,
                )
              : engine.syncNow(
                  priorityAlbumIds: _priorityAlbumIds,
                  onProgress: updateProgress,
                )
        : engine.syncIfStale(
            priorityAlbumIds: _priorityAlbumIds,
            onProgress: updateProgress,
          );
  }

  void _onAppBackgrounded() {
    _isForeground = false;
    ref.read(librarySyncForegroundProvider.notifier).setForeground(false);
    _cancelPeriodicSync();
  }

  void _onAppResumed() {
    final wasForeground = _isForeground;
    _isForeground = true;
    ref.read(librarySyncForegroundProvider.notifier).setForeground(true);
    if (!wasForeground) {
      // Re-arm the one-shot deadline timer in case it elapsed while the app
      // was backgrounded. The schedule gate decides whether it may run.
      final intervalMinutes = ref.read(syncIntervalMinutesProvider);
      _schedulePeriodicSync(intervalMinutes);
    }
  }

  // ---------------------------------------------------------------------------
  // Periodic background sync
  // ---------------------------------------------------------------------------

  void _onSyncIntervalChanged(int minutes) {
    unawaited(_resetAutomaticCheckSchedule(minutes));
    unawaited(_reconcileAndroidBackgroundSchedule(enqueueCatchup: true));
  }

  void _schedulePeriodicSync(int minutes) {
    _cancelPeriodicSync();
    if (_startupSyncSuppressed) return;
    final epoch = _automaticScheduleEpoch;
    late final Future<void> task;
    task = _armAutomaticCheckTimer(minutes, epoch).whenComplete(() {
      _automaticTimerArms.remove(task);
    });
    _automaticTimerArms.add(task);
    unawaited(task);
  }

  Future<void> _armAutomaticCheckTimer(int minutes, int epoch) async {
    final interval = ref.read(syncIntervalDurationProvider);
    if (interval == null || !_isForeground) {
      return; // Manual-only mode or a backgrounded app — no timer.
    }
    final nextCheckAt = await _ensureAutomaticCheckSchedule(interval);
    if (!ref.mounted || !_isForeground || epoch != _automaticScheduleEpoch) {
      return;
    }
    if (nextCheckAt == null) {
      return;
    }
    final delay = nextCheckAt.difference(DateTime.now().toUtc());
    _periodicSyncTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () {
        if (epoch != _automaticScheduleEpoch) {
          return;
        }
        AppLogger.debug(
          'Automatic sync deadline reached (interval: ${minutes}m, '
          'foreground=$_isForeground).',
        );
        if (!_isForeground) {
          return;
        }
        unawaited(syncIfStale());
      },
    );
  }

  Future<void> _resetAutomaticCheckSchedule(int minutes) async {
    _cancelPeriodicSync();
    final config = ref.read(serverConfigStateProvider).asData?.value;
    final serverId = config?.id;
    final interval = ref.read(syncIntervalDurationProvider);
    if (serverId == null) {
      _schedulePeriodicSync(minutes);
      return;
    }
    final next = interval == null ? null : DateTime.now().toUtc().add(interval);
    await ref
        .read(navisDatabaseProvider)
        .librarySyncDao
        .setNextAutomaticCheckAt(
          serverId: serverId,
          nextAutomaticCheckAt: next,
        );
    if (ref.mounted && _sessionFingerprint == _toSessionFingerprint(config!)) {
      state = state.copyWith(
        nextAutomaticCheckAt: next,
        clearNextAutomaticCheckAt: next == null,
      );
    }
    if (ref.mounted) {
      _schedulePeriodicSync(minutes);
    }
  }

  void _cancelPeriodicSync() {
    _automaticScheduleEpoch++;
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = null;
  }
}
