import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/data/adaptive_library_sync_coordinator.dart';
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

@visibleForTesting
final verificationContinuationDelayProvider = Provider<Duration>((ref) {
  return const Duration(minutes: 2);
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

final librarySyncNotifierProvider = Provider<LibrarySyncNotifier>((ref) {
  return const SystemLibrarySyncNotifier();
});

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

const currentLibrarySyncModelVersion = '56';

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
  // Read live policy at call time; do not watch network providers here so
  // diagnostics overrides cannot dispose an in-flight coordinator.
  SyncNetworkPolicy readPolicy() {
    if (!ref.mounted) {
      return resolveSyncNetworkPolicy(
        networkType: NetworkType.other,
        nativeMetered: null,
        backgroundSyncUnmeteredOnly: true,
      );
    }
    return ref.read(syncNetworkPolicyProvider);
  }

  final executor = DriftLibrarySyncEngine(
    api: SubsonicLibrarySyncApi(api),
    database: database,
    serverConfigRepository: repository,
    staleAfter: staleAfter,
    networkType: ref.read(networkTypeProvider),
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
  );
  return AdaptiveLibrarySyncCoordinator(
    executor: executor,
    database: database,
    serverConfigRepository: repository,
    readSyncNetworkPolicy: readPolicy,
    staleAfter: staleAfter,
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
  );
});

final librarySyncControllerProvider =
    NotifierProvider<LibrarySyncController, LibrarySyncState>(
      LibrarySyncController.new,
    );

final starredContentSyncProvider = FutureProvider.autoDispose<void>((
  ref,
) async {
  await ref
      .read(librarySyncControllerProvider.notifier)
      .requestTargetIfStale(const LibrarySyncTarget.starred());
});

class LibrarySyncController extends Notifier<LibrarySyncState> {
  bool _startupSyncInFlight = false;
  bool _startupSyncSuppressed = false;
  int _startupSyncEpoch = 0;
  Future<void>? _startupSyncTask;
  String? _startupSyncDoneFingerprint;
  String? _sessionFingerprint;
  ServerReachabilityStatus? _lastReachabilityStatus;
  bool _isForeground = true;
  final Queue<String> _priorityAlbumIds = Queue<String>();
  static const int _maxPriorityAlbums = 120;
  late final AppLifecycleListener _lifecycleListener;
  Timer? _periodicSyncTimer;
  Timer? _verificationContinuationTimer;

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
      _cancelVerificationContinuation();
    });

    final serverConfig = ref.read(serverConfigStateProvider).asData?.value;
    if (serverConfig != null) {
      _sessionFingerprint = _toSessionFingerprint(serverConfig);
      unawaited(_loadPersistedSyncState(serverConfig));
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
      (previous, next) => _onSyncIntervalChanged(next),
    );
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
        if (_hasPendingVerificationWork) {
          _scheduleVerificationContinuation();
        }
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
    return _runSync(force: false);
  }

  Future<LibrarySyncState> syncNow({bool allowMeteredBroadOverride = false}) {
    return _runSync(
      force: true,
      allowMeteredBroadOverride: allowMeteredBroadOverride,
    );
  }

  Future<LibrarySyncState> forceFullSync({
    bool allowMeteredBroadOverride = false,
  }) {
    return _runSync(
      force: true,
      forceFull: true,
      allowMeteredBroadOverride: allowMeteredBroadOverride,
    );
  }

  Future<LibrarySyncState> syncUsingMobileData() {
    return syncNow(allowMeteredBroadOverride: true);
  }

  /// Cancel a running sync while retaining its durable work for resume.
  void cancelSync() {
    final engine = ref.read(librarySyncEngineProvider);
    if (engine is AdaptiveLibrarySyncCoordinator) {
      engine.cancelSync();
    } else if (engine is DriftLibrarySyncEngine) {
      engine.cancelSync();
    }
  }

  Future<void> cancelAndWait() async {
    _cancelVerificationContinuation();
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
    return _runRequest(
      engine,
      LibrarySyncRequest(
        trigger: LibrarySyncTrigger.interaction,
        intent: LibrarySyncIntent.checkForUpdates,
        target: target,
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
    return _runRequest(
      engine,
      LibrarySyncRequest(
        trigger: LibrarySyncTrigger.interaction,
        intent: LibrarySyncIntent.automatic,
        target: target,
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
    final albums = await dao.getAlbumsByArtist(normalizedId);
    if (!ref.mounted || (artist != null && albums.isNotEmpty)) {
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
      _startupSyncSuppressed = true;
      _startupSyncEpoch++;
      _startupSyncInFlight = false;
      _startupSyncDoneFingerprint = null;
      _sessionFingerprint = null;
      _cancelVerificationContinuation();
      state = const LibrarySyncState.idle();
      _priorityAlbumIds.clear();
      return;
    }

    final fingerprint = _toSessionFingerprint(serverConfig);
    if (_sessionFingerprint != fingerprint) {
      _startupSyncSuppressed = false;
      _startupSyncEpoch++;
      _startupSyncInFlight = false;
      _startupSyncDoneFingerprint = null;
      _sessionFingerprint = fingerprint;
      _priorityAlbumIds.clear();
      state = LibrarySyncState.idle(
        lastSyncedAt: serverConfig.lastSynced,
        freshness: _readPersistedFreshness(serverConfig.capabilitiesJson),
      );
      unawaited(_loadPersistedSyncState(serverConfig));
    }
    _scheduleStartupSync();
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

  Future<void> _loadPersistedSyncState(ServerConfigModel config) async {
    final serverId = config.id;
    if (serverId == null) {
      return;
    }
    final database = ref.read(navisDatabaseProvider);
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
      lastCatalogUpdatedAt: persisted.lastCatalogSyncedAt,
      lastAuxiliarySyncedAt: persisted.lastAuxiliarySyncedAt,
      lastGenresSyncedAt: persisted.lastGenresSyncedAt,
      planKind: storedPlan.isEmpty ? state.planKind : storedPlan.first,
      planReason: persisted.lastPlanReason,
      pendingWorkCount: pending,
      lastRunBytes: persisted.lastRunBytes,
      apiRequests: persisted.lastRunRequests,
    );
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
      final persisted = await ref
          .read(navisDatabaseProvider)
          .librarySyncDao
          .getOrCreateState(serverId);
      if (!ref.mounted ||
          _startupSyncSuppressed ||
          epoch != _startupSyncEpoch) {
        return;
      }
      if (persisted.currentGeneration <= 0) {
        // Initial setup owns the first catalog snapshot so routing can keep
        // the user on its recoverable, cancellable gate.
        return;
      }
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
          ? forceFullSync()
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

  Future<LibrarySyncState> _runSync({
    required bool force,
    bool forceFull = false,
    bool verificationContinuation = false,
    bool allowMeteredBroadOverride = false,
  }) async {
    if (state.isRunning) {
      return state;
    }

    final engine = ref.read(librarySyncEngineProvider);
    final notifier = ref.read(librarySyncNotifierProvider);
    if (engine == null) {
      state = state.copyWith(
        status: LibrarySyncStatus.failed,
        stage: LibrarySyncStage.completed,
        completedAt: DateTime.now(),
        errorMessage: 'Metadata sync unavailable for current session.',
      );
      return state;
    }

    final result = await _executeSync(
      engine: engine,
      force: force,
      forceFull: forceFull,
      verificationContinuation: verificationContinuation,
      allowMeteredBroadOverride: allowMeteredBroadOverride,
      onProgressExternal: (progress) {
        if (!verificationContinuation &&
            progress.status == LibrarySyncStatus.running) {
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

    state = result;
    switch (result.status) {
      case LibrarySyncStatus.succeeded:
      case LibrarySyncStatus.partial:
        if (!verificationContinuation) {
          unawaited(notifier.showComplete(result));
        }
        if (_hasPendingVerificationWork) {
          _scheduleVerificationContinuation();
        } else {
          _cancelVerificationContinuation();
        }
      case LibrarySyncStatus.failed:
        if (!verificationContinuation) {
          unawaited(notifier.showFailed(result));
        }
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
      onProgress: (progress) {
        if (ref.mounted) {
          state = progress;
        }
      },
    );
    if (ref.mounted) {
      state = result;
    }
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
    required bool verificationContinuation,
    required bool allowMeteredBroadOverride,
    required void Function(LibrarySyncState progress) onProgressExternal,
  }) {
    void updateProgress(LibrarySyncState progress) {
      if (ref.mounted) {
        state = progress;
      }
      onProgressExternal(progress);
    }

    if (verificationContinuation) {
      return engine.continueVerification(
        priorityAlbumIds: _priorityAlbumIds,
        onProgress: updateProgress,
      );
    }
    if (engine is AdaptiveLibrarySyncCoordinator) {
      return force
          ? forceFull
                ? engine.forceFullSync(
                    priorityAlbumIds: _priorityAlbumIds,
                    onProgress: updateProgress,
                    allowMeteredBroadOverride: allowMeteredBroadOverride,
                  )
                : engine.syncNow(
                    priorityAlbumIds: _priorityAlbumIds,
                    onProgress: updateProgress,
                    allowMeteredBroadOverride: allowMeteredBroadOverride,
                  )
          : engine.syncIfStale(
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
    _cancelVerificationContinuation();
  }

  void _onAppResumed() {
    final wasForeground = _isForeground;
    _isForeground = true;
    ref.read(librarySyncForegroundProvider.notifier).setForeground(true);
    if (!wasForeground) {
      // Re-arm the periodic timer in case it drifted while backgrounded.
      final intervalMinutes = ref.read(syncIntervalMinutesProvider);
      _schedulePeriodicSync(intervalMinutes);

      // On resume, run a startup sync for first-time / reconnect scenarios
      // and also run syncIfStale for periodic interval scenarios.  The
      // startup-done fingerprint gates _maybeRunStartupSync so it won't
      // duplicate if it already ran, while syncIfStale checks staleness
      // independently so the periodic interval actually fires on resume.
      _scheduleStartupSync();
      if (intervalMinutes > 0 && !state.isRunning) {
        unawaited(syncIfStale());
      }
      if (_hasPendingVerificationWork) {
        _scheduleVerificationContinuation();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Periodic background sync
  // ---------------------------------------------------------------------------

  void _onSyncIntervalChanged(int minutes) {
    _schedulePeriodicSync(minutes);
  }

  void _schedulePeriodicSync(int minutes) {
    _cancelPeriodicSync();
    final interval = ref.read(syncIntervalDurationProvider);
    if (interval == null) {
      return; // Manual-only mode — no timer.
    }
    _periodicSyncTimer = Timer.periodic(interval, (_) {
      AppLogger.debug(
        'Periodic sync timer fired (interval: ${minutes}m, '
        'foreground=$_isForeground).',
      );
      if (!_isForeground) {
        return;
      }
      unawaited(syncIfStale());
    });
  }

  void _cancelPeriodicSync() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = null;
  }

  void _scheduleVerificationContinuation() {
    _cancelVerificationContinuation();
    if (!_hasPendingVerificationWork ||
        !_isForeground ||
        ref.read(serverConfigStateProvider).asData?.value == null ||
        ref.read(networkTypeProvider) == NetworkType.cellular ||
        ref.read(networkTypeProvider) == NetworkType.offline) {
      return;
    }
    final delay = ref.read(verificationContinuationDelayProvider);
    final pendingAlbums = state.pendingHydrationCount ?? 0;
    AppLogger.debug(
      'Scheduling metadata verification continuation in '
      '${delay.inSeconds}s (artists=${state.remainingVerificationCount}, '
      'albums=$pendingAlbums).',
    );
    _verificationContinuationTimer = Timer(delay, () {
      if (!ref.mounted || !_isForeground) {
        return;
      }
      final networkType = ref.read(networkTypeProvider);
      if (state.isRunning ||
          networkType == NetworkType.cellular ||
          networkType == NetworkType.offline) {
        _scheduleVerificationContinuation();
        return;
      }
      unawaited(
        _runSync(
          force: true,
          verificationContinuation: true,
        ),
      );
    });
  }

  bool get _hasPendingVerificationWork =>
      state.remainingVerificationCount > 0 ||
      (state.pendingHydrationCount ?? 0) > 0;

  void _cancelVerificationContinuation() {
    _verificationContinuationTimer?.cancel();
    _verificationContinuationTimer = null;
  }
}
