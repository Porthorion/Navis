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
import 'package:navis/src/providers/app_providers.dart';

final syncStaleAfterProvider = Provider<Duration>((ref) {
  return const Duration(hours: 1);
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
  Completer<void>? _foregroundCompleter;
  final Queue<String> _priorityAlbumIds = Queue<String>();
  static const int _maxPriorityAlbums = 120;
  late final AppLifecycleListener _lifecycleListener;

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
      _foregroundCompleter?.complete();
      _foregroundCompleter = null;
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

    Future<void>.microtask(_maybeRunStartupSync);
    return LibrarySyncState.idle(lastSyncedAt: serverConfig?.lastSynced);
  }

  Future<LibrarySyncState> syncIfStale() => _runSync(force: false);

  Future<LibrarySyncState> syncNow({bool forceFull = false}) {
    return _runSync(force: true, forceFull: forceFull);
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
    unawaited(
      syncIfStale()
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
    );
    if (!ref.mounted) {
      return result;
    }

    if (result.status == LibrarySyncStatus.failed && !_isForeground) {
      await _waitUntilForeground();
      if (!ref.mounted) {
        return result;
      }
      if (_isForeground) {
        final resumed = await _executeSync(
          engine: engine,
          force: force,
          forceFull: forceFull,
        );
        if (!ref.mounted) {
          return resumed;
        }
        state = resumed;
        return resumed;
      }
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
  }) {
    void updateProgress(LibrarySyncState progress) {
      if (ref.mounted) {
        state = progress;
      }
    }

    return force
        ? engine.syncNow(
            forceFull: forceFull,
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
    _foregroundCompleter ??= Completer<void>();
  }

  void _onAppResumed() {
    final wasForeground = _isForeground;
    _isForeground = true;
    _foregroundCompleter?.complete();
    _foregroundCompleter = null;
    if (!wasForeground) {
      _maybeRunStartupSync();
    }
  }

  Future<void> _waitUntilForeground() async {
    if (_isForeground) {
      return;
    }
    final completer = _foregroundCompleter ??= Completer<void>();
    await completer.future;
  }
}
