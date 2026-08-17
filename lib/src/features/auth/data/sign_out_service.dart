import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/downloads/presentation/auto_download_starred_dispatch_provider.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/player/presentation/same_vibes_notifier.dart';
import 'package:navis/src/features/player/presentation/sleep_timer_provider.dart';
import 'package:navis/src/features/player/presentation/smart_queue_notifier.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/file_utils.dart';
import 'package:navis/src/utils/notifications/download_notifier.dart';

abstract interface class SignOutService {
  Future<void> signOut({required bool wipeLocalData});
}

enum SessionTransition { idle, signingOut }

class SessionTransitionController extends Notifier<SessionTransition> {
  @override
  SessionTransition build() => SessionTransition.idle;

  void setTransition(SessionTransition value) => state = value;
}

final sessionTransitionProvider =
    NotifierProvider<SessionTransitionController, SessionTransition>(
      SessionTransitionController.new,
    );

final serverDataResetServiceProvider = Provider<ServerDataResetService>((ref) {
  return ServerDataResetService(
    database: ref.watch(navisDatabaseProvider),
    clearCoverArt: () => ref.read(coverArtCacheManagerProvider).emptyCache(),
  );
});

final signOutServiceProvider = Provider<SignOutService>((ref) {
  return SessionLifecycleService(
    serverConfigRepository: ref.watch(serverConfigRepositoryProvider),
    database: ref.watch(navisDatabaseProvider),
    cancelApiRequests: () async {
      ref.read(subsonicApiProvider)?.close(force: true);
    },
    cancelSync: () =>
        ref.read(librarySyncControllerProvider.notifier).cancelAndWait(),
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
      ref.read(sleepTimerProvider.notifier).cancel();
      ref.read(instantMixProvider.notifier).deactivate();
      ref.read(sameVibesProvider.notifier).deactivate();
      ref.read(smartQueueProvider.notifier).deactivate();
      ref.read(playerOverlayStackProvider.notifier).clear();
      resetPlaybackActionErrors(ref);
    },
    wipeServerData: () => ref.read(serverDataResetServiceProvider).reset(),
    onTransition: (transition) {
      ref.read(sessionTransitionProvider.notifier).setTransition(transition);
    },
    invalidateSessionProviders: () {
      ref.invalidate(downloadServiceProvider);
      ref.invalidate(autoDownloadStarredDispatchControllerProvider);
      ref.invalidate(scrobbleServiceProvider);
      ref.invalidate(listenBrainzFeedbackServiceProvider);
    },
  );
});

class SessionLifecycleService implements SignOutService {
  SessionLifecycleService({
    required ServerConfigRepository serverConfigRepository,
    required NavisDatabase database,
    Future<void> Function()? cancelApiRequests,
    Future<void> Function()? cancelSync,
    Future<void> Function()? cancelAndroidBackgroundSync,
    Future<void> Function()? stopDownloads,
    Future<void> Function()? resetPlayback,
    Future<void> Function()? resetTransientUi,
    Future<void> Function()? wipeServerData,
    void Function(SessionTransition transition)? onTransition,
    void Function()? invalidateSessionProviders,
  }) : _serverConfigRepository = serverConfigRepository,
       _database = database,
       _cancelApiRequests = cancelApiRequests,
       _cancelSync = cancelSync,
       _cancelAndroidBackgroundSync = cancelAndroidBackgroundSync,
       _stopDownloads = stopDownloads,
       _resetPlayback = resetPlayback,
       _resetTransientUi = resetTransientUi,
       _wipeServerData =
           wipeServerData ??
           (() => ServerDataResetService(database: database).reset()),
       _onTransition = onTransition,
       _invalidateSessionProviders = invalidateSessionProviders;

  final ServerConfigRepository _serverConfigRepository;
  final NavisDatabase _database;
  final Future<void> Function()? _cancelApiRequests;
  final Future<void> Function()? _cancelSync;
  final Future<void> Function()? _cancelAndroidBackgroundSync;
  final Future<void> Function()? _stopDownloads;
  final Future<void> Function()? _resetPlayback;
  final Future<void> Function()? _resetTransientUi;
  final Future<void> Function() _wipeServerData;
  final void Function(SessionTransition transition)? _onTransition;
  final void Function()? _invalidateSessionProviders;

  Future<void>? _inFlight;

  @override
  Future<void> signOut({required bool wipeLocalData}) {
    return _inFlight ??= _signOut(wipeLocalData: wipeLocalData).whenComplete(
      () {
        _inFlight = null;
      },
    );
  }

  Future<void> _signOut({required bool wipeLocalData}) async {
    _onTransition?.call(SessionTransition.signingOut);
    final failures = <String>[];

    Future<void> attempt(String label, FutureOr<void> Function() action) async {
      try {
        await action();
      } on Object catch (error) {
        failures.add(label);
        AppLogger.warning(
          'Session teardown step failed ($label): ${error.runtimeType}.',
        );
      }
    }

    try {
      await attempt('cancel API requests', () async {
        await _cancelApiRequests?.call();
      });
      await attempt('cancel library sync', () async {
        await _cancelSync?.call();
      });
      await attempt('cancel Android background sync', () async {
        await _cancelAndroidBackgroundSync?.call();
      });
      await attempt('stop downloads', () async {
        await _stopDownloads?.call();
      });
      await attempt('reset playback', () async {
        await _resetPlayback?.call();
      });
      await attempt('reset transient UI', () async {
        await _resetTransientUi?.call();
      });
      await attempt('clear persisted playback queue', () {
        return _database.playQueueDao.clearQueue();
      });
      await attempt('clear pending download queue', () {
        return _database.downloadQueueDao.clearQueue();
      });
      await attempt('clear pending star actions', () {
        return _database.starSyncDao.clearAll();
      });
      await attempt('clear pending scrobbles', () {
        return _database.scrobbleDao.clearAll();
      });
      await attempt('clear pending ListenBrainz feedback', () {
        return _database.listenBrainzFeedbackDao.clearAll();
      });
      await attempt('clear sync candidates', () {
        return _database.librarySyncCandidateDao.clearAll();
      });
      await attempt('clear sync mutations', () {
        return _database.librarySyncDao.clearLocalMutations();
      });
      await attempt('clear durable sync work', () {
        return _database.librarySyncDao.discardAllPendingSessionWork();
      });
      await attempt('dismiss download notification', () {
        return DownloadNotifier.dismissProgress();
      });

      if (wipeLocalData) {
        await attempt('clear server-scoped data', _wipeServerData);
      }
    } finally {
      await attempt('clear authentication', () {
        return wipeLocalData
            ? _serverConfigRepository.clear()
            : _serverConfigRepository.signOutKeepData();
      });
      await attempt('invalidate session providers', () async {
        _invalidateSessionProviders?.call();
      });
      await attempt('finish session transition', () async {
        _onTransition?.call(SessionTransition.idle);
      });
    }

    if (failures.isNotEmpty) {
      AppLogger.warning(
        'Session signed out with ${failures.length} cleanup warning(s): '
        '${failures.join(', ')}.',
      );
    }
  }
}

class ServerDataResetService {
  ServerDataResetService({
    required NavisDatabase database,
    Future<void> Function()? clearCoverArt,
  }) : _database = database,
       _clearCoverArt = clearCoverArt;

  final NavisDatabase _database;
  final Future<void> Function()? _clearCoverArt;

  Future<void> reset() async {
    final cachedTracks = await _database.cacheDao.getCachedTracks();
    await _database.transaction(() async {
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
      await _database.delete(_database.playHistoryTable).go();
      await _database.delete(_database.recentSearchesTable).go();
      await _database.delete(_database.albumInfoCacheTable).go();
      await _database.delete(_database.externalLyricsCacheTable).go();
      await _database.delete(_database.listenBrainzWeeklyCacheTable).go();
      await _database.delete(_database.networkUsageTable).go();
      await _database.delete(_database.songIdentityAliasesTable).go();
      await _database.delete(_database.cachedTracksTable).go();
      await _database.delete(_database.songsTable).go();
      await _database.delete(_database.albumsTable).go();
      await _database.delete(_database.artistsTable).go();
      await _database.delete(_database.genresTable).go();
      await _database.delete(_database.librarySyncStateTable).go();
      await _database.serverDao.clearSyncTimestamps();
    });
    for (final track in cachedTracks) {
      try {
        await deleteFileWithSuffixes(track.filePath);
      } on Object catch (error) {
        AppLogger.warning(
          'Server audio-file reset failed: ${error.runtimeType}.',
        );
      }
    }
    try {
      await _clearCoverArt?.call();
    } on Object catch (error) {
      AppLogger.warning(
        'Server cover-art reset failed: ${error.runtimeType}.',
      );
    }
  }
}
