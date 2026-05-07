import 'dart:async';
import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/notifications/library_sync_notifier.dart';

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

final librarySyncNotifierProvider = Provider<LibrarySyncNotifier>((ref) {
  return const SystemLibrarySyncNotifier();
});

final librarySyncEngineProvider = Provider<LibrarySyncEngine?>((ref) {
  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    return null;
  }

  final database = ref.watch(navisDatabaseProvider);
  final repository = ref.watch(serverConfigRepositoryProvider);
  final staleAfter = ref.watch(syncStaleAfterProvider);
  final networkType = ref.watch(networkTypeProvider);

  return DriftLibrarySyncEngine(
    api: SubsonicLibrarySyncApi(api),
    database: database,
    serverConfigRepository: repository,
    staleAfter: staleAfter,
    networkType: networkType,
  );
});

final librarySyncControllerProvider =
    NotifierProvider<LibrarySyncController, LibrarySyncState>(
      LibrarySyncController.new,
    );

class LibrarySyncController extends Notifier<LibrarySyncState> {
  bool _startupSyncInFlight = false;
  String? _startupSyncDoneFingerprint;
  String? _sessionFingerprint;
  ServerReachabilityStatus? _lastReachabilityStatus;
  bool _isForeground = true;
  final Queue<String> _priorityAlbumIds = Queue<String>();
  static const int _maxPriorityAlbums = 120;
  late final AppLifecycleListener _lifecycleListener;
  Timer? _periodicSyncTimer;

  @override
  LibrarySyncState build() {
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _isForeground =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
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
    });

    final serverConfig = ref.read(serverConfigStateProvider).asData?.value;
    if (serverConfig != null) {
      _sessionFingerprint = _toSessionFingerprint(serverConfig);
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

    // Kick off the periodic timer with the current interval.
    final intervalMinutes = ref.read(syncIntervalMinutesProvider);
    _schedulePeriodicSync(intervalMinutes);

    Future<void>.microtask(_maybeRunStartupSync);
    return LibrarySyncState.idle(lastSyncedAt: serverConfig?.lastSynced);
  }

  Future<LibrarySyncState> syncIfStale() => _runSync(force: false);

  Future<LibrarySyncState> syncNow({
    bool forceFull = false,
    bool preferIncremental = false,
  }) {
    return _runSync(
      force: true,
      forceFull: forceFull,
      preferIncremental: preferIncremental,
    );
  }

  /// Cancel a running sync.  The sync will complete with [LibrarySyncStatus.failed]
  /// and an error message of \"Sync cancelled.\".
  void cancelSync() {
    final engine = ref.read(librarySyncEngineProvider);
    if (engine is DriftLibrarySyncEngine) {
      engine.cancelSync();
    }
  }

  void setVisibleAlbumIds(Iterable<String> albumIds) {
    for (final albumId in albumIds) {
      _addPriorityAlbum(albumId);
    }
  }

  void registerAlbumInteraction(String albumId) {
    _addPriorityAlbum(albumId);
  }

  void _onServerConfigChanged(AsyncValue<ServerConfigModel?> next) {
    if (next.isLoading && !next.hasValue) {
      return;
    }

    final serverConfig = next.asData?.value;
    if (serverConfig == null) {
      _startupSyncInFlight = false;
      _startupSyncDoneFingerprint = null;
      _sessionFingerprint = null;
      state = const LibrarySyncState.idle();
      _priorityAlbumIds.clear();
      return;
    }

    final fingerprint = _toSessionFingerprint(serverConfig);
    if (_sessionFingerprint != fingerprint) {
      _startupSyncInFlight = false;
      _startupSyncDoneFingerprint = null;
      _sessionFingerprint = fingerprint;
      _priorityAlbumIds.clear();
      state = LibrarySyncState.idle(lastSyncedAt: serverConfig.lastSynced);
    }
    _maybeRunStartupSync();
  }

  void _onReachabilityChanged(ServerReachabilityState next) {
    final previous = _lastReachabilityStatus;
    _lastReachabilityStatus = next.status;

    if (previous == ServerReachabilityStatus.offline &&
        next.status == ServerReachabilityStatus.online) {
      _startupSyncDoneFingerprint = null;
    }

    _maybeRunStartupSync();
  }

  Future<void> _maybeRunStartupSync() async {
    if (_startupSyncInFlight) {
      return;
    }

    final config = ref.read(serverConfigStateProvider).asData?.value;
    if (config == null) {
      return;
    }

    final reachability = ref.read(serverReachabilityControllerProvider);
    if (reachability.status == ServerReachabilityStatus.offline) {
      return;
    }

    final fingerprint = _toSessionFingerprint(config);
    if (_startupSyncDoneFingerprint == fingerprint) {
      return;
    }

    _startupSyncInFlight = true;

    // Detect app updates: force a full resync whenever the version changes.
    final database = ref.read(navisDatabaseProvider);
    final packageInfo = await ref.read(packageInfoProvider.future);
    final currentBuild = '${packageInfo.version}+${packageInfo.buildNumber}';
    final lastSyncBuild = await database.appSettingsDao
        .getLastFullSyncAppBuild();
    final isNewVersion = lastSyncBuild != currentBuild;

    final hasBeenSyncedBefore = config.lastSynced != null;
    unawaited(
      (isNewVersion
              ? syncNow(forceFull: true)
              : hasBeenSyncedBefore
              ? syncNow(preferIncremental: true)
              : syncIfStale())
          .then((result) {
            if (result.status == LibrarySyncStatus.succeeded ||
                result.status == LibrarySyncStatus.skipped) {
              _startupSyncDoneFingerprint = fingerprint;
            }
            // Record the version so subsequent startups skip the forced resync.
            if (isNewVersion && result.status == LibrarySyncStatus.succeeded) {
              database.appSettingsDao.setLastFullSyncAppBuild(currentBuild);
            }
          })
          .whenComplete(() {
            _startupSyncInFlight = false;
          }),
    );
  }

  Future<LibrarySyncState> _runSync({
    required bool force,
    bool forceFull = false,
    bool preferIncremental = false,
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
      preferIncremental: preferIncremental,
      onProgressExternal: (progress) {
        if (progress.status == LibrarySyncStatus.running) {
          unawaited(notifier.showProgress(progress));
        }
      },
    );
    if (!ref.mounted) {
      return result;
    }

    switch (result.status) {
      case LibrarySyncStatus.succeeded:
        unawaited(notifier.showComplete(result));
      case LibrarySyncStatus.failed:
        unawaited(notifier.showFailed(result));
      case LibrarySyncStatus.skipped:
      case LibrarySyncStatus.idle:
        unawaited(notifier.dismissProgress());
      case LibrarySyncStatus.running:
        break;
    }

    state = result;
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
    bool preferIncremental = false,
    required void Function(LibrarySyncState progress) onProgressExternal,
  }) {
    void updateProgress(LibrarySyncState progress) {
      if (ref.mounted) {
        state = progress;
      }
      onProgressExternal(progress);
    }

    return force
        ? engine.syncNow(
            forceFull: forceFull,
            preferIncremental: preferIncremental,
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
  }

  void _onAppResumed() {
    final wasForeground = _isForeground;
    _isForeground = true;
    if (!wasForeground) {
      // Re-arm the periodic timer in case it drifted while backgrounded.
      final intervalMinutes = ref.read(syncIntervalMinutesProvider);
      _schedulePeriodicSync(intervalMinutes);

      // On resume, run a startup sync for first-time / reconnect scenarios
      // and also run syncIfStale for periodic interval scenarios.  The
      // startup-done fingerprint gates _maybeRunStartupSync so it won't
      // duplicate if it already ran, while syncIfStale checks staleness
      // independently so the periodic interval actually fires on resume.
      _maybeRunStartupSync();
      if (intervalMinutes > 0 && !state.isRunning) {
        unawaited(syncIfStale());
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
      unawaited(syncIfStale());
    });
  }

  void _cancelPeriodicSync() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = null;
  }
}
