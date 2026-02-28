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

/// Sync interval in minutes from user settings (0 = manual only).
/// The staleness window for the sync engine equals this interval so that
/// periodic ticks actually trigger a sync rather than being skipped.
final syncIntervalMinutesProvider = Provider<int>((ref) {
  final settings =
      ref.watch(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  return settings.syncIntervalMinutes;
});

final syncStaleAfterProvider = Provider<Duration>((ref) {
  final minutes = ref.watch(syncIntervalMinutesProvider);
  if (minutes <= 0) {
    // Manual-only: use a large staleness window so syncIfStale won't fire
    // on its own, but syncNow still works.
    return const Duration(hours: 24);
  }
  return Duration(minutes: minutes);
});

/// Whether auto-enqueue of new tracks for pinned albums runs after sync.
/// Override to `false` in unit tests that do not provide
/// [navisDatabaseProvider] / [downloadServiceProvider].
@visibleForTesting
final autoEnqueuePinnedTracksEnabledProvider = Provider<bool>((ref) => true);

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

  void _maybeRunStartupSync() {
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
    // Prefer incremental when the library has been synced before — this
    // prevents the automatic 24-hour rebaseline from blocking the UI on
    // every reconnect.  Full rebaseline is only triggered explicitly from
    // Sync Settings ("Force Full Sync").
    final hasBeenSyncedBefore = config.lastSynced != null;
    unawaited(
      (hasBeenSyncedBefore
              ? syncNow(preferIncremental: true)
              : syncIfStale())
          .then((result) {
            if (result.status == LibrarySyncStatus.succeeded ||
                result.status == LibrarySyncStatus.skipped) {
              _startupSyncDoneFingerprint = fingerprint;
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
    );
    if (!ref.mounted) {
      return result;
    }

    // After a successful sync, auto-enqueue new tracks for pinned albums.
    if (result.status == LibrarySyncStatus.succeeded &&
        ref.read(autoEnqueuePinnedTracksEnabledProvider)) {
      unawaited(
        _autoEnqueueNewPinnedTracks().catchError((_) {}),
      );
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
  }) {
    void updateProgress(LibrarySyncState progress) {
      if (ref.mounted) {
        state = progress;
      }
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

  /// After sync, check if any album that was fully pinned (all songs had a
  /// permanent cache entry) now has new tracks, and auto-enqueue them.
  Future<void> _autoEnqueueNewPinnedTracks() async {
    try {
      final db = ref.read(navisDatabaseProvider);
      final cacheDao = db.cacheDao;
      final libraryDao = db.libraryDao;

      // 1. Get all permanently cached song IDs.
      final permanentIds = await cacheDao.getPermanentlyCachedSongIds();
      if (permanentIds.isEmpty) return;

      // 2. Get the album IDs for those songs.
      final permanentSongs = await libraryDao.getSongsByIds(permanentIds);
      final albumIdToPermanentSongs = <String, Set<String>>{};
      for (final song in permanentSongs) {
        final albumId = song.albumId;
        if (albumId == null) continue;
        (albumIdToPermanentSongs[albumId] ??= <String>{}).add(song.id);
      }

      // 3. For each album with cached tracks, load the full song list.
      final albumSongMap = await libraryDao.getSongIdsByAlbumIds(
        albumIdToPermanentSongs.keys,
      );

      // 4. Find albums that were fully pinned but now have new tracks.
      final service = ref.read(downloadServiceProvider);
      var newTracksQueued = 0;
      for (final entry in albumSongMap.entries) {
        final albumId = entry.key;
        final allSongIds = entry.value;
        final pinnedSongIds = albumIdToPermanentSongs[albumId] ?? {};

        // Only auto-enqueue if the album was fully pinned (every known
        // track at the time of last sync was permanent).
        final knownCached = allSongIds.intersection(pinnedSongIds);
        final newSongIds = allSongIds.difference(pinnedSongIds);

        // The album was "fully pinned" if all previously-known songs were
        // cached. If the album had 0 cached songs, skip.
        if (knownCached.length < pinnedSongIds.length || newSongIds.isEmpty) {
          continue;
        }

        for (final songId in newSongIds) {
          await service.enqueueSong(songId);
          newTracksQueued++;
        }
      }

      if (newTracksQueued > 0) {
        AppLogger.info(
          'Auto-enqueued $newTracksQueued new tracks from pinned albums.',
        );
      }
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Auto-enqueue new pinned tracks failed',
        error,
        stackTrace,
      );
    }
  }

  void _onAppResumed() {
    final wasForeground = _isForeground;
    _isForeground = true;
    if (!wasForeground) {
      _maybeRunStartupSync();
      // Re-arm the periodic timer in case it drifted while backgrounded.
      final intervalMinutes = ref.read(syncIntervalMinutesProvider);
      _schedulePeriodicSync(intervalMinutes);
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
    if (minutes <= 0) {
      return; // Manual-only mode — no timer.
    }
    final interval = Duration(minutes: minutes);
    _periodicSyncTimer = Timer.periodic(interval, (_) {
      if (!_isForeground) {
        return; // Don't run while backgrounded.
      }
      AppLogger.debug('Periodic sync timer fired (interval: ${minutes}m).');
      unawaited(syncIfStale());
    });
  }

  void _cancelPeriodicSync() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = null;
  }
}
