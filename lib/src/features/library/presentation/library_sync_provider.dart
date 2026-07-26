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
import 'package:navis/src/features/library/data/song_identity_cache_epoch.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/connectivity.dart';
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

@visibleForTesting
final requiredLibrarySyncModelVersionProvider = Provider<String?>((ref) {
  return '54';
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
    onBeforeSongIdentityRemap: (aliases) async {
      SongIdentityCacheEpoch.invalidate();
      await ref.read(audioHandlerProvider)?.applySongIdentityAliases(aliases);
    },
    readActiveSongId: () =>
        ref.read(audioHandlerProvider)?.snapshot.currentSongId,
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
  @visibleForTesting
  static const Duration retryAfterFailureWindow = Duration(minutes: 15);
  static const int _maxAutoRetries = 3;
  static const List<Duration> _autoRetryDelays = <Duration>[
    Duration(seconds: 30),
    Duration(minutes: 2),
    Duration(minutes: 5),
  ];
  late final AppLifecycleListener _lifecycleListener;
  Timer? _periodicSyncTimer;
  Timer? _autoRetryTimer;
  Timer? _verificationContinuationTimer;
  DateTime? _lastFailedSyncAt;
  int _autoRetryCount = 0;
  bool _retryVerificationContinuation = false;

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
      _cancelAutoRetryTimer();
      _cancelVerificationContinuation();
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
    ref.listen<NetworkType>(networkTypeProvider, (previous, next) {
      final becameAvailable =
          previous == NetworkType.offline && next != NetworkType.offline;
      final becameWifi =
          next == NetworkType.wifi && previous != NetworkType.wifi;
      if (becameWifi) {
        _startupSyncDoneFingerprint = null;
      }
      if (becameAvailable || becameWifi) {
        _maybeRunStartupSync();
        if (state.remainingVerificationCount > 0) {
          _scheduleVerificationContinuation();
        }
      }
    });

    // Kick off the periodic timer with the current interval.
    final intervalMinutes = ref.read(syncIntervalMinutesProvider);
    _schedulePeriodicSync(intervalMinutes);

    Future<void>.microtask(_maybeRunStartupSync);
    return LibrarySyncState.idle(
      lastSyncedAt: serverConfig?.lastSynced,
      freshness: _readPersistedFreshness(serverConfig?.capabilitiesJson),
    );
  }

  Future<LibrarySyncState> syncIfStale() {
    if (_shouldForceRetryAfterFailure()) {
      return syncNow();
    }
    return _runSync(force: false);
  }

  Future<LibrarySyncState> syncNow() {
    return _runSync(force: true);
  }

  Future<LibrarySyncState> forceFullSync() {
    return _runSync(force: true, forceFull: true);
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
      _lastFailedSyncAt = null;
      _autoRetryCount = 0;
      _retryVerificationContinuation = false;
      _cancelAutoRetryTimer();
      _cancelVerificationContinuation();
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
      state = LibrarySyncState.idle(
        lastSyncedAt: serverConfig.lastSynced,
        freshness: _readPersistedFreshness(serverConfig.capabilitiesJson),
      );
    }
    _maybeRunStartupSync();
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
    if (!ref.mounted || _startupSyncInFlight) {
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
    final database = ref.read(navisDatabaseProvider);
    final requiredSyncModelVersion = ref.read(
      requiredLibrarySyncModelVersionProvider,
    );
    final lastSyncModelVersion = await database.appSettingsDao
        .getLastFullSyncAppBuild();
    if (!ref.mounted) {
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
    unawaited(
      (requiresSyncModelRepair && !deferFullResyncOnMobile
              ? forceFullSync()
              : syncIfStale())
          .then((result) {
            if (!ref.mounted) {
              return;
            }
            final completedStartupPass =
                result.status == LibrarySyncStatus.succeeded ||
                (!deferFullResyncOnMobile &&
                    result.status == LibrarySyncStatus.skipped);
            if (completedStartupPass) {
              _startupSyncDoneFingerprint = fingerprint;
            }
            if (requiresSyncModelRepair &&
                !deferFullResyncOnMobile &&
                result.status == LibrarySyncStatus.succeeded) {
              unawaited(
                database.appSettingsDao.setLastFullSyncAppBuild(
                  requiredSyncModelVersion,
                ),
              );
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
    bool verificationContinuation = false,
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
        _lastFailedSyncAt = null;
        _autoRetryCount = 0;
        _retryVerificationContinuation = false;
        _cancelAutoRetryTimer();
        if (!verificationContinuation) {
          unawaited(notifier.showComplete(result));
        }
        if (result.remainingVerificationCount > 0) {
          _scheduleVerificationContinuation();
        } else {
          _cancelVerificationContinuation();
        }
      case LibrarySyncStatus.failed:
        _lastFailedSyncAt = DateTime.now();
        _retryVerificationContinuation = verificationContinuation;
        _scheduleAutoRetry();
        if (!verificationContinuation) {
          unawaited(notifier.showFailed(result));
        }
      case LibrarySyncStatus.skipped:
      case LibrarySyncStatus.idle:
        unawaited(notifier.dismissProgress());
      case LibrarySyncStatus.running:
        break;
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
    _cancelVerificationContinuation();
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
        if (ref.read(networkTypeProvider) == NetworkType.cellular) {
          AppLogger.debug('Resume stale sync skipped on cellular.');
        } else {
          unawaited(syncIfStale());
        }
      }
      if (state.remainingVerificationCount > 0) {
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
      if (ref.read(networkTypeProvider) == NetworkType.cellular) {
        AppLogger.debug('Periodic sync skipped on cellular.');
        return;
      }
      unawaited(syncIfStale());
    });
  }

  void _cancelPeriodicSync() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = null;
  }

  bool _shouldForceRetryAfterFailure() {
    final lastFailed = _lastFailedSyncAt;
    if (lastFailed == null) {
      return false;
    }
    return DateTime.now().difference(lastFailed) < retryAfterFailureWindow;
  }

  void _scheduleAutoRetry() {
    _cancelAutoRetryTimer();
    if (_autoRetryCount >= _maxAutoRetries) {
      return;
    }
    if (ref.read(networkTypeProvider) == NetworkType.offline) {
      return;
    }
    final delayIndex = _autoRetryCount.clamp(0, _autoRetryDelays.length - 1);
    final delay = _autoRetryDelays[delayIndex];
    final retryVerificationContinuation = _retryVerificationContinuation;
    _autoRetryCount++;
    AppLogger.debug(
      'Scheduling library sync auto-retry #$_autoRetryCount in '
      '${delay.inSeconds}s.',
    );
    _autoRetryTimer = Timer(delay, () {
      if (!ref.mounted || state.isRunning) {
        return;
      }
      unawaited(
        retryVerificationContinuation
            ? _runSync(force: true, verificationContinuation: true)
            : syncNow(),
      );
    });
  }

  void _cancelAutoRetryTimer() {
    _autoRetryTimer?.cancel();
    _autoRetryTimer = null;
  }

  void _scheduleVerificationContinuation() {
    _cancelVerificationContinuation();
    if (!_isForeground ||
        ref.read(serverConfigStateProvider).asData?.value == null ||
        ref.read(networkTypeProvider) == NetworkType.cellular ||
        ref.read(networkTypeProvider) == NetworkType.offline) {
      return;
    }
    final delay = ref.read(verificationContinuationDelayProvider);
    AppLogger.debug(
      'Scheduling artist verification continuation in '
      '${delay.inSeconds}s (${state.remainingVerificationCount} remaining).',
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

  void _cancelVerificationContinuation() {
    _verificationContinuationTimer?.cancel();
    _verificationContinuationTimer = null;
  }
}
