import 'dart:io';
import 'dart:async';

import 'package:navis/src/features/settings/data/external_scrobble_credentials.dart';

import 'package:path/path.dart' as p;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/downloads/presentation/auto_download_starred_dispatch_provider.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/player/presentation/same_vibes_notifier.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/file_utils.dart';
import 'package:navis/src/theme/dynamic_accent_provider.dart';
import 'package:navis/src/utils/notifications/download_notifier.dart';

abstract interface class SignOutService {
  /// Signs out, optionally wiping the server's local data.
  ///
  /// Concurrent calls: the same mode joins the running sign-out, and so does a
  /// keep-data request while a wipe runs (the wipe also signs out). A wipe
  /// requested during a keep-data sign-out runs right after it, so a wipe is
  /// never lost. The keep-data caller's future completes before that chained
  /// wipe does; only the wipe caller's future waits for it.
  Future<void> signOut({required bool wipeLocalData});

  /// Completes when the running sign-out, including a chained wipe, has
  /// finished; already complete when none runs. Never throws. Every path that
  /// saves credentials must await it first, or a late wipe clears the new
  /// session.
  Future<void> get pendingSignOut;
}

/// The sign-out phase shown to the user; teardown publishes one per group of
/// steps, never one per step.
enum SessionTransition { idle, stoppingSync, clearingData, finishing }

class SessionTransitionController extends Notifier<SessionTransition> {
  @override
  SessionTransition build() => SessionTransition.idle;

  // Keep the existing method and callback call contract for callers.
  // ignore: use_setters_to_change_properties
  void setTransition(SessionTransition value) => state = value;
}

final sessionTransitionProvider =
    NotifierProvider<SessionTransitionController, SessionTransition>(
      SessionTransitionController.new,
    );

final serverDataResetServiceProvider = Provider<ServerDataResetService>((ref) {
  return ServerDataResetService(
    database: ref.watch(navisDatabaseProvider),
    // Download artwork is Navis-owned and belongs to the server's downloads.
    clearCoverArt: () async {
      await ref.read(clearCoverArtCachesProvider)();
      await ref.read(permanentArtworkStoreProvider).clear();
    },
  );
});

final signOutServiceProvider = Provider<SignOutService>((ref) {
  return SessionLifecycleService(
    credentials: ref.watch(externalScrobbleCredentialStoreProvider),
    serverConfigRepository: ref.watch(serverConfigRepositoryProvider),
    database: ref.watch(navisDatabaseProvider),
    cancelApiRequests: () async {
      ref.read(subsonicApiProvider)?.close(force: true);
    },
    cancelSync: () =>
        ref.read(librarySyncControllerProvider.notifier).cancelAndWait(),
    dismissSyncNotifications: () =>
        ref.read(librarySyncNotifierProvider).dismissAll(),
    cancelAndroidBackgroundSync: () async {
      final config = await ref
          .read(serverConfigRepositoryProvider)
          .getActiveServer();
      if (config != null) {
        await ref
            .read(androidBackgroundSyncReconcilerProvider)
            .cancelFor(config);
      }
    },
    stopDownloads: () => ref.read(downloadServiceProvider).stopAndWait(),
    resetPlayback: () async {
      await ref
          .read(audioBootstrapControllerProvider.notifier)
          .abortForSessionTeardown();
    },
    resetTransientUi: () async {
      ref.read(instantMixProvider.notifier).deactivate();
      ref.read(sameVibesProvider.notifier).deactivate();
      ref.read(playerOverlayStackProvider.notifier).clear();
      resetPlaybackActionErrors(ref);
    },
    clearCoverArt: () => ref.read(clearCoverArtCachesProvider)(),
    wipeServerData: () async {
      await ref.read(serverDataResetServiceProvider).reset(fenceSync: true);
      await ref.read(clearIntegrationLibraryCacheProvider)();
    },
    onTransition: (transition) {
      ref.read(sessionTransitionProvider.notifier).setTransition(transition);
    },
    invalidateSessionProviders: () {
      ref.invalidate(downloadServiceProvider);
      ref.invalidate(autoDownloadStarredDispatchControllerProvider);
      ref.invalidate(scrobbleServiceProvider);
      ref.invalidate(listenBrainzFeedbackServiceProvider);
      // Cover ids are per server; a new one must not read the old colours.
      ref.invalidate(dynamicAccentColorCacheProvider);
    },
  );
});

class SessionLifecycleService implements SignOutService {
  new({
    required this._serverConfigRepository,
    required this._credentials,
    required NavisDatabase database,
    this._cancelApiRequests,
    this._cancelSync,
    this._cancelAndroidBackgroundSync,
    this._dismissSyncNotifications,
    this._stopDownloads,
    this._resetPlayback,
    this._resetTransientUi,
    this._clearCoverArt,
    Future<void> Function()? wipeServerData,
    this._onTransition,
    this._invalidateSessionProviders,
    this._timeoutScale = 1,
  }) : _database = database,
       _wipeServerData =
           wipeServerData ??
           (() =>
               ServerDataResetService(database: database)
                   .reset(fenceSync: true));

  final ExternalScrobbleCredentialStore _credentials;
  final ServerConfigRepository _serverConfigRepository;
  final NavisDatabase _database;
  final Future<void> Function()? _cancelApiRequests;
  final Future<void> Function()? _cancelSync;
  final Future<void> Function()? _cancelAndroidBackgroundSync;
  final Future<void> Function()? _dismissSyncNotifications;
  final Future<void> Function()? _stopDownloads;
  final Future<void> Function()? _resetPlayback;
  final Future<void> Function()? _resetTransientUi;
  final Future<void> Function()? _clearCoverArt;
  final Future<void> Function() _wipeServerData;
  final void Function(SessionTransition transition)? _onTransition;
  final void Function()? _invalidateSessionProviders;

  /// Multiplies every step timeout; tests shrink them instead of waiting.
  final double _timeoutScale;

  Future<void>? _inFlight;
  bool _inFlightWipes = false;

  @override
  Future<void> get pendingSignOut =>
      (_inFlight ?? Future<void>.value()).catchError((Object _) {});

  @override
  Future<void> signOut({required bool wipeLocalData}) {
    final running = _inFlight;
    // Same mode, or a keep request while a wipe runs, joins the run.
    if (running != null && (_inFlightWipes || !wipeLocalData)) return running;
    // A wipe asked during a keep-data run is chained after it (even if it
    // failed). The running `_signOut` never changes mode: after its wipe
    // check that would clear credentials but keep the data.
    late final Future<void> run;
    run = (running ?? Future<void>.value())
        .catchError((Object _) {})
        .then((_) => _signOut(wipeLocalData: wipeLocalData))
        .whenComplete(() {
          // The keep run finishing must not clear the chained wipe.
          if (identical(_inFlight, run)) {
            _inFlight = null;
            _inFlightWipes = false;
          }
        });
    _inFlight = run;
    _inFlightWipes = wipeLocalData;
    return run;
  }

  Future<void> _signOut({required bool wipeLocalData}) async {
    final failures = <String>[];

    // The callback reaches into providers and can throw (a disposed ref). A
    // phase is cosmetic: it must never skip a teardown step or the credentials.
    void publish(SessionTransition phase) {
      try {
        _onTransition?.call(phase);
      } on Object catch (error) {
        AppLogger.warning(
          'Session transition ${phase.name} failed: ${error.runtimeType}.',
        );
      }
    }

    publish(SessionTransition.stoppingSync);

    // Every step is bounded: one that never completes is abandoned (its late
    // result is ignored) and teardown moves on, so credentials are always
    // cleared. Durations are logged so a slow step names itself.
    Future<void> attempt(
      String label,
      FutureOr<void> Function() action, {
      required Duration timeout,
    }) async {
      final watch = Stopwatch()..start();
      var timedOut = false;
      try {
        // The async wrapper gives the future the static type the timeout
        // callback returns: a DAO's Future<int> would reject it.
        await (() async => await action())().timeout(
          timeout * _timeoutScale,
          onTimeout: () => timedOut = true,
        );
      } on Object catch (error) {
        failures.add(label);
        AppLogger.warning(
          'Session teardown step failed ($label): ${error.runtimeType}.',
        );
        return;
      }
      if (timedOut) {
        failures.add(label);
        AppLogger.warning(
          'Session teardown step timed out ($label) after '
          '${watch.elapsedMilliseconds} ms.',
        );
        return;
      }
      AppLogger.info(
        'Session teardown step ($label) took ${watch.elapsedMilliseconds} ms.',
      );
    }

    try {
      await attempt('cancel API requests', () async {
        await _cancelApiRequests?.call();
      }, timeout: const Duration(seconds: 5));
      await attempt('cancel library sync', () async {
        await _cancelSync?.call();
      }, timeout: const Duration(seconds: 30));
      await attempt('cancel Android background sync', () async {
        await _cancelAndroidBackgroundSync?.call();
      }, timeout: const Duration(seconds: 10));
      // Runs whether or not the cancels finished: a run that ignored its
      // cancel can no longer write once its lease is the sign-out sentinel.
      // A busy writer lock is retried until the step's own bound, because
      // this is the step that keeps a stale run out of the wipe.
      final fenceBound = _fenceTimeout * _timeoutScale;
      var fenceGaveUp = false;
      await attempt('fence library sync', () async {
        final waited = Stopwatch()..start();
        var pause = const Duration(milliseconds: 50);
        // No try may start once the step has given up: a late sentinel from
        // an abandoned loop would land after the lock frees, defeating the
        // in-transaction fence of the wipe.
        while (!fenceGaveUp) {
          try {
            return await _database.librarySyncDao
                .fenceAllExecutionLeasesForSignOut(now: DateTime.now());
          } on Object catch (error) {
            final left = fenceBound - waited.elapsed;
            if (!isDatabaseLockTimeout(error) || left <= Duration.zero) {
              rethrow;
            }
            // Back off so an instantly failing lock cannot spin, never past
            // the bound.
            await Future<void>.delayed(pause < left ? pause : left);
            pause = pause * 2 > _fenceMaxPause ? _fenceMaxPause : pause * 2;
          }
        }
      }, timeout: _fenceTimeout);
      fenceGaveUp = true;
      await attempt('stop downloads', () async {
        await _stopDownloads?.call();
      }, timeout: const Duration(seconds: 20));
      await attempt('reset playback', () async {
        await _resetPlayback?.call();
      }, timeout: const Duration(seconds: 10));
      await attempt('reset transient UI', () async {
        await _resetTransientUi?.call();
      }, timeout: const Duration(seconds: 5));

      publish(SessionTransition.clearingData);
      await attempt('clear persisted playback queue', () {
        return _database.playQueueDao.clearQueue();
      }, timeout: _databaseStepTimeout);
      await attempt('clear pending download queue', () {
        return _database.downloadQueueDao.clearQueue();
      }, timeout: _databaseStepTimeout);
      await attempt('clear pending star actions', () async {
        await _database.starSyncDao.clearAll();
      }, timeout: _databaseStepTimeout);
      await attempt(
        'delete ListenBrainz token',
        _credentials.clearListenBrainzToken,
        timeout: const Duration(seconds: 10),
      );
      await attempt(
        'reset ListenBrainz connection',
        () => _database.appSettingsDao.updateListenBrainzScrobblingState(
          tokenValid: false,
          enabled: false,
          clearUserName: true,
        ),
        timeout: _databaseStepTimeout,
      );
      await attempt('clear pending scrobbles', () {
        return _database.scrobbleDao.clearAll();
      }, timeout: _databaseStepTimeout);
      await attempt('clear pending ListenBrainz feedback', () async {
        await _database.listenBrainzFeedbackDao.clearAll();
      }, timeout: _databaseStepTimeout);
      await attempt('clear sync candidates', () {
        return _database.librarySyncCandidateDao.clearAll();
      }, timeout: _databaseStepTimeout);
      await attempt('clear sync mutations', () {
        return _database.librarySyncDao.clearLocalMutations();
      }, timeout: _databaseStepTimeout);
      await attempt('clear durable sync work', () {
        return _database.librarySyncDao.discardAllPendingSessionWork();
      }, timeout: _databaseStepTimeout);
      await attempt(
        'dismiss download notification',
        DownloadNotifier.dismissProgress,
        timeout: const Duration(seconds: 5),
      );
      // A run abandoned by its timeout can leave the sync progress
      // notification up; its own tail no longer dismisses it.
      await attempt('dismiss sync notification', () async {
        await _dismissSyncNotifications?.call();
      }, timeout: const Duration(seconds: 5));

      await attempt('clear cover artwork cache', () async {
        await _clearCoverArt?.call();
      }, timeout: const Duration(seconds: 30));

      if (wipeLocalData) {
        // Deletes the downloaded files too, so it gets the longest bound.
        await attempt(
          'clear server-scoped data',
          _wipeServerData,
          timeout: const Duration(seconds: 180),
        );
      }
    } finally {
      publish(SessionTransition.finishing);
      // Credentials are never skipped, whatever the steps above did.
      await attempt('clear authentication', () {
        return wipeLocalData
            ? _serverConfigRepository.clear()
            : _serverConfigRepository.signOutKeepData();
      }, timeout: const Duration(seconds: 60));
      // Again: by now the sync controller has left the old session, so a
      // run that reposted after the earlier dismiss cannot do it again.
      await attempt('dismiss sync notification after sign-out', () async {
        await _dismissSyncNotifications?.call();
      }, timeout: const Duration(seconds: 5));
      await attempt('invalidate session providers', () async {
        _invalidateSessionProviders?.call();
      }, timeout: const Duration(seconds: 5));
      await attempt('finish session transition', () async {
        _onTransition?.call(SessionTransition.idle);
      }, timeout: const Duration(seconds: 5));
    }

    if (failures.isNotEmpty) {
      AppLogger.warning(
        'Session signed out with ${failures.length} cleanup warning(s): '
        '${failures.join(', ')}.',
      );
    }
  }

  static const _fenceTimeout = Duration(seconds: 30);
  static const _fenceMaxPause = Duration(seconds: 1);
  static const _databaseStepTimeout = Duration(seconds: 30);
}

class ServerDataResetService {
  new({required this._database, this._clearCoverArt});

  final NavisDatabase _database;
  final Future<void> Function()? _clearCoverArt;

  /// [fenceSync] also fences every sync run as the first statement of the
  /// wipe transaction, so a run that outlived the sign-out fence cannot write
  /// between this reset and the server delete. Only sign-out passes it:
  /// a diagnostics reset must not block sync.
  Future<void> reset({bool fenceSync = false}) async {
    final cachedTracks = await _database.cacheDao.getCachedTracks();
    final userFolder = await _userOwnedDownloadFolder();
    await _database.transaction(() async {
      if (fenceSync) {
        await _database.librarySyncDao.fenceAllExecutionLeasesForSignOut(
          now: DateTime.now(),
        );
      }
      await _database.delete(_database.librarySyncWorkTable).go();
      await _database.delete(_database.librarySyncLocalMutationsTable).go();
      await _database.delete(_database.librarySyncCandidateSongsTable).go();
      await _database.delete(_database.librarySyncCandidateAlbumsTable).go();
      await _database.delete(_database.librarySyncCandidateArtistsTable).go();
      await _database.delete(_database.listenBrainzFeedbackQueueTable).go();
      await _database.delete(_database.scrobbleQueueTable).go();
      await _database.delete(_database.starSyncQueueTable).go();
      await _database.delete(_database.downloadQueueTable).go();
      await _database.delete(_database.playQueueItemsTable).go();
      await _database.delete(_database.playQueueTable).go();
      await _database.delete(_database.matchFlowSongsTable).go();
      await _database.delete(_database.matchFlowsTable).go();
      await _database.delete(_database.playlistSongsTable).go();
      await _database.delete(_database.playlistsTable).go();
      await _database.delete(_database.localRadioStationsTable).go();
      await _database.delete(_database.playHistoryTable).go();
      await _database.delete(_database.recentSearchesTable).go();
      await _database.delete(_database.albumInfoCacheTable).go();
      await _database.delete(_database.externalLyricsCacheTable).go();
      await _database.delete(_database.listenBrainzWeeklyCacheTable).go();
      await _database.delete(_database.networkUsageTable).go();
      await _database.delete(_database.entityIdentityAliasTable).go();
      await _database.delete(_database.cachedTracksTable).go();
      await _database.delete(_database.songGenreIndexTable).go();
      await _database.delete(_database.songsTable).go();
      await _database.delete(_database.albumsTable).go();
      await _database.delete(_database.artistsTable).go();
      await _database.delete(_database.librarySyncStateTable).go();
      await _database.serverDao.clearSyncTimestamps();
    });
    var kept = 0;
    for (final track in cachedTracks) {
      // A custom download folder and a chosen Android folder are the
      // user's: their files stay, as they would without Navis.
      if (track.storageKind == 'androidSaf' ||
          track.filePath.startsWith('content://') ||
          (userFolder != null && userFolder.contains(track.filePath))) {
        kept++;
        continue;
      }
      try {
        await deleteFileWithSuffixes(track.filePath);
      } on Object catch (error) {
        AppLogger.warning(
          'Server audio-file reset failed: ${error.runtimeType}.',
        );
      }
    }
    if (kept > 0) {
      AppLogger.info('Server reset kept $kept file(s) in the user folder.');
    }
    try {
      await _clearCoverArt?.call();
    } on Object catch (error) {
      AppLogger.warning('Server cover-art reset failed: ${error.runtimeType}.');
    }
  }

  Future<_UserFolder?> _userOwnedDownloadFolder() async {
    final settings = await _database.appSettingsDao.getSettings();
    final path = settings?.customDownloadFolderPath?.trim();
    if (settings?.customDownloadFolderEnabled != true ||
        path == null ||
        path.isEmpty ||
        path.startsWith('content://')) {
      return null;
    }
    String? resolved;
    try {
      resolved = await Directory(path).resolveSymbolicLinks();
    } on FileSystemException {
      resolved = null;
    }
    return _UserFolder(<String>{p.normalize(path), ?resolved});
  }
}

/// A user-chosen download folder, as configured and link-resolved.
class _UserFolder {
  const new(this._roots);

  final Set<String> _roots;

  bool contains(String filePath) {
    final normalized = p.normalize(filePath);
    return _roots.any((root) => p.isWithin(root, normalized));
  }
}
