import 'dart:io';
import 'dart:async';

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
      await ref.read(coverArtCacheManagerProvider).emptyCache();
      await ref.read(permanentArtworkStoreProvider).clear();
    },
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
      ref.read(instantMixProvider.notifier).deactivate();
      ref.read(sameVibesProvider.notifier).deactivate();
      ref.read(smartQueueProvider.notifier).deactivate();
      ref.read(playerOverlayStackProvider.notifier).clear();
      resetPlaybackActionErrors(ref);
    },
    wipeServerData: () async {
      await ref.read(serverDataResetServiceProvider).reset();
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
    },
  );
});

class SessionLifecycleService implements SignOutService {
  new({
    required this._serverConfigRepository,
    required NavisDatabase database,
    this._cancelApiRequests,
    this._cancelSync,
    this._cancelAndroidBackgroundSync,
    this._stopDownloads,
    this._resetPlayback,
    this._resetTransientUi,
    Future<void> Function()? wipeServerData,
    this._onTransition,
    this._invalidateSessionProviders,
  }) : _database = database,
       _wipeServerData =
           wipeServerData ??
           (() => ServerDataResetService(database: database).reset());

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
    return _inFlight ??= _signOut(wipeLocalData: wipeLocalData)
        .whenComplete(() {
          _inFlight = null;
        });
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
      await attempt('clear pending star actions', () async {
        await _database.starSyncDao.clearAll();
      });
      await attempt('clear pending scrobbles', () {
        return _database.scrobbleDao.clearAll();
      });
      await attempt('clear pending ListenBrainz feedback', () async {
        await _database.listenBrainzFeedbackDao.clearAll();
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
      await attempt(
        'dismiss download notification',
        DownloadNotifier.dismissProgress,
      );

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
  new({required this._database, this._clearCoverArt});

  final NavisDatabase _database;
  final Future<void> Function()? _clearCoverArt;

  Future<void> reset() async {
    final cachedTracks = await _database.cacheDao.getCachedTracks();
    final userFolder = await _userOwnedDownloadFolder();
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
