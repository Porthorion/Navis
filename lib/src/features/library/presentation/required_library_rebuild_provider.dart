import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/features/auth/data/sign_out_service.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/initial_server_sync_provider.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/auth/presentation/session_route_provider.dart';
import 'package:navis/src/features/cache/presentation/library_cache_reset_provider.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';

enum RequiredLibraryRebuildStatus {
  idle,
  waitingForNetwork,
  waitingForMobileConsent,
  clearingCache,
  syncing,
  failed,
  cancelling,
  complete,
}

/// Why a rebuild ended in [RequiredLibraryRebuildStatus.failed]; the screen
/// words it.
enum RequiredLibraryRebuildFailure {
  /// The sync did not complete, or failed unexpectedly.
  incomplete,
  cacheResetFailed,
  cacheRenewalPending,
  signOutFailed,
}

class RequiredLibraryRebuildState {
  const new({
    this.status = RequiredLibraryRebuildStatus.idle,
    this.failure,
    this.errorMessage,
  });

  final RequiredLibraryRebuildStatus status;
  final RequiredLibraryRebuildFailure? failure;

  /// The server's or sync engine's own explanation of a failure, when it gave
  /// one; shown under the screen's status.
  final String? errorMessage;
}

/// Scoped to one visit of a full-screen rebuild route. Every visit starts from
/// idle and runs its own rebuild, so a finished, failed or cancelled visit can
/// never be shown to a later session or rebuild request. A run or cancellation
/// in flight keeps the controller alive until its bookkeeping completes.
final requiredLibraryRebuildControllerProvider = NotifierProvider.autoDispose
    .family<
      RequiredLibraryRebuildController,
      RequiredLibraryRebuildState,
      RequiredLibraryRebuildReason
    >(RequiredLibraryRebuildController.new);

class RequiredLibraryRebuildController
    extends Notifier<RequiredLibraryRebuildState> {
  new(this._reason);

  final RequiredLibraryRebuildReason _reason;
  Future<void>? _inFlight;
  int _inFlightEpoch = 0;
  int _epoch = 0;
  bool _resetPrepared = false;

  @override
  RequiredLibraryRebuildState build() {
    // A visit also belongs to one signed-in session. A quick sign-out and
    // sign-in can reuse the still-mounted route during its exit transition,
    // and Riverpod keeps this notifier instance across rebuilds, so a session
    // change starts a new visit here and supersedes the previous one's runs.
    final session = ref.watch(
      serverConfigStateProvider.select((config) {
        final server = config.asData?.value;
        return server == null ? null : (server.id, server.url, server.username);
      }),
    );
    _epoch += 1;
    _resetPrepared = false;
    ref.listen<ServerReachabilityState>(serverReachabilityControllerProvider, (
      _,
      next,
    ) {
      if (state.status == RequiredLibraryRebuildStatus.waitingForNetwork &&
          next.status == ServerReachabilityStatus.online) {
        unawaited(start());
      }
    });
    ref.listen<SyncNetworkPolicy>(syncNetworkPolicyProvider, (_, next) {
      if (state.status == RequiredLibraryRebuildStatus.waitingForNetwork &&
          !next.isOffline) {
        unawaited(start());
      }
      if (state.status ==
              RequiredLibraryRebuildStatus.waitingForMobileConsent &&
          !next.isMetered) {
        unawaited(start());
      }
    });
    if (session != null) unawaited(Future<void>.microtask(start));
    return const RequiredLibraryRebuildState();
  }

  Future<void> start() => _start(allowMeteredBroadOverride: false);

  Future<void> retry() => _start(allowMeteredBroadOverride: false);

  Future<void> startUsingMobileData() =>
      _start(allowMeteredBroadOverride: true);

  Future<void> _start({required bool allowMeteredBroadOverride}) {
    // The build microtask and network listeners can fire after the route
    // closed and the controller was disposed, or while signed out.
    if (!ref.mounted ||
        ref.read(serverConfigStateProvider).asData?.value == null) {
      return Future<void>.value();
    }
    final inFlight = _inFlight;
    if (inFlight != null && _inFlightEpoch == _epoch) return inFlight;
    final link = ref.keepAlive();
    _inFlightEpoch = _epoch;
    late final Future<void> run;
    run = _run(allowMeteredBroadOverride: allowMeteredBroadOverride)
        .whenComplete(() {
          if (identical(_inFlight, run)) _inFlight = null;
          link.close();
        });
    return _inFlight = run;
  }

  /// Whether a run may still publish state: the controller is mounted and no
  /// cancellation or session change superseded the run.
  bool _isCurrent(int runEpoch) => ref.mounted && runEpoch == _epoch;

  Future<void> _run({required bool allowMeteredBroadOverride}) async {
    final runEpoch = _epoch;
    if (_reason != RequiredLibraryRebuildReason.initialLogin &&
        _reason != RequiredLibraryRebuildReason.repairLibrary &&
        !_resetPrepared) {
      state = const RequiredLibraryRebuildState(
        status: RequiredLibraryRebuildStatus.clearingCache,
      );
      try {
        await _clearRecoverableCache();
      } on Object catch (error) {
        AppLogger.warning('Library cache reset failed: ${error.runtimeType}.');
        if (_isCurrent(runEpoch)) {
          state = const RequiredLibraryRebuildState(
            status: RequiredLibraryRebuildStatus.failed,
            failure: RequiredLibraryRebuildFailure.cacheResetFailed,
          );
        }
        return;
      }
      if (!_isCurrent(runEpoch)) return;
      _resetPrepared = true;
    }
    final reachability = ref.read(serverReachabilityControllerProvider);
    final policy = ref.read(syncNetworkPolicyProvider);
    if (reachability.status != ServerReachabilityStatus.online ||
        policy.isOffline) {
      state = const RequiredLibraryRebuildState(
        status: RequiredLibraryRebuildStatus.waitingForNetwork,
      );
      return;
    }
    if (policy.isMetered && !allowMeteredBroadOverride) {
      state = const RequiredLibraryRebuildState(
        status: RequiredLibraryRebuildStatus.waitingForMobileConsent,
      );
      return;
    }

    try {
      final result = switch (_reason) {
        RequiredLibraryRebuildReason.initialLogin => await _runInitialSync(
          allowMeteredBroadOverride,
        ),
        RequiredLibraryRebuildReason.cacheUpgrade => await _runCacheUpgrade(
          allowMeteredBroadOverride,
        ),
        RequiredLibraryRebuildReason.manualCacheReset ||
        RequiredLibraryRebuildReason.playbackRecovery => await _runManualReset(
          allowMeteredBroadOverride,
        ),
        RequiredLibraryRebuildReason.repairLibrary => await _runRepair(
          allowMeteredBroadOverride,
        ),
      };
      if (!_isCurrent(runEpoch) ||
          state.status == RequiredLibraryRebuildStatus.cancelling) {
        return;
      }
      final usableIncompleteAlbums = isUsableIncompleteAlbumSyncRun(result);
      if ((_reason == RequiredLibraryRebuildReason.initialLogin
              ? isCompletedInitialSyncRun(result) || usableIncompleteAlbums
              : result.status == LibrarySyncStatus.succeeded ||
                    usableIncompleteAlbums) &&
          await _hasCommittedCatalog(result)) {
        if (!_isCurrent(runEpoch) ||
            state.status == RequiredLibraryRebuildStatus.cancelling) {
          return;
        }
        if (_reason == RequiredLibraryRebuildReason.cacheUpgrade) {
          await ref
              .read(cacheSystemUpgradeServiceProvider)
              .markCurrentVersionAfterSuccessfulScan();
          if (!_isCurrent(runEpoch)) return;
          final cacheRenewalStillRequired = await ref.refresh(
            cacheSystemUpgradeNeededProvider.future,
          );
          if (!_isCurrent(runEpoch)) return;
          if (cacheRenewalStillRequired) {
            state = const RequiredLibraryRebuildState(
              status: RequiredLibraryRebuildStatus.failed,
              failure: RequiredLibraryRebuildFailure.cacheRenewalPending,
            );
            return;
          }
        }
        if (!_isCurrent(runEpoch) ||
            state.status == RequiredLibraryRebuildStatus.cancelling) {
          return;
        }
        if (_reason == RequiredLibraryRebuildReason.initialLogin) {
          ref.invalidate(initialSyncRequiredProvider);
        }
        if (usableIncompleteAlbums) {
          ref.read(initialSyncCompletionWarningProvider.notifier).show();
        }
        state = const RequiredLibraryRebuildState(
          status: RequiredLibraryRebuildStatus.complete,
        );
        return;
      }
      if (!_isCurrent(runEpoch)) return;
      state = RequiredLibraryRebuildState(
        status: RequiredLibraryRebuildStatus.failed,
        failure: RequiredLibraryRebuildFailure.incomplete,
        errorMessage: result.errorMessage,
      );
    } on Object catch (error) {
      AppLogger.warning('Library rebuild failed: ${error.runtimeType}.');
      if (_isCurrent(runEpoch) &&
          state.status != RequiredLibraryRebuildStatus.cancelling) {
        state = const RequiredLibraryRebuildState(
          status: RequiredLibraryRebuildStatus.failed,
          failure: RequiredLibraryRebuildFailure.incomplete,
        );
      }
    }
  }

  Future<LibrarySyncState> _runInitialSync(bool allowMetered) {
    state = const RequiredLibraryRebuildState(
      status: RequiredLibraryRebuildStatus.syncing,
    );
    return runInitialCatalogSync(ref, allowMeteredBroadOverride: allowMetered);
  }

  Future<LibrarySyncState> _runCacheUpgrade(bool allowMetered) async {
    state = const RequiredLibraryRebuildState(
      status: RequiredLibraryRebuildStatus.syncing,
    );
    final result = await ref
        .read(librarySyncControllerProvider.notifier)
        .forceFullSync(allowMeteredBroadOverride: allowMetered);
    return result;
  }

  Future<LibrarySyncState> _runManualReset(bool allowMetered) async {
    state = const RequiredLibraryRebuildState(
      status: RequiredLibraryRebuildStatus.syncing,
    );
    return await ref
        .read(librarySyncControllerProvider.notifier)
        .resetCachesAndRebuildLibrary(allowMeteredBroadOverride: allowMetered);
  }

  Future<LibrarySyncState> _runRepair(bool allowMetered) {
    state = const RequiredLibraryRebuildState(
      status: RequiredLibraryRebuildStatus.syncing,
    );
    return ref
        .read(librarySyncControllerProvider.notifier)
        .repairLibrary(allowMeteredBroadOverride: allowMetered);
  }

  Future<void> _clearRecoverableCache() {
    return switch (_reason) {
      RequiredLibraryRebuildReason.cacheUpgrade =>
        ref.read(cacheSystemUpgradeServiceProvider).resetRecoverableCache(),
      RequiredLibraryRebuildReason.manualCacheReset ||
      RequiredLibraryRebuildReason.playbackRecovery =>
        ref.read(libraryCacheResetServiceProvider).reset(),
      RequiredLibraryRebuildReason.repairLibrary => Future<void>.value(),
      RequiredLibraryRebuildReason.initialLogin => Future<void>.value(),
    };
  }

  Future<bool> _hasCommittedCatalog(LibrarySyncState result) async {
    final serverId = ref.read(serverConfigStateProvider).asData?.value?.id;
    if (serverId == null) return false;
    final database = ref.read(navisDatabaseProvider);
    final persisted = await database.librarySyncDao.getOrCreateState(serverId);
    if (_reason == RequiredLibraryRebuildReason.initialLogin) {
      return await recordInitialCatalogReadiness(
        database: database,
        serverId: serverId,
        result: result,
        syncModelVersion: ref.read(requiredLibrarySyncModelVersionProvider),
      );
    }
    if (persisted.currentGeneration <= 0 ||
        persisted.candidateGeneration != null ||
        persisted.candidateStatus != null) {
      return false;
    }
    return !isUsableIncompleteAlbumSyncRun(result) ||
        await database.libraryDao.countPendingHydrationAlbums() ==
            result.pendingHydrationCount;
  }

  Future<void> cancelAndSignOut() async {
    if (state.status == RequiredLibraryRebuildStatus.cancelling) return;
    // Signing out replaces this route while the teardown is still running.
    final link = ref.keepAlive();
    try {
      state = const RequiredLibraryRebuildState(
        status: RequiredLibraryRebuildStatus.cancelling,
      );
      _epoch += 1;
      await ref.read(signOutServiceProvider).signOut(wipeLocalData: false);
      if (!ref.mounted) return;
      await ref.read(serverConfigProvider.notifier).refresh();
      if (!ref.mounted) return;
      ref.invalidate(initialSyncRequiredProvider);
      // A completed sign-out has already reset this controller for the next
      // session. Sign-out steps fail softly, so a session can survive it;
      // offer retry rather than leaving the screen in `cancelling`.
      if (state.status == RequiredLibraryRebuildStatus.cancelling) {
        state = const RequiredLibraryRebuildState(
          status: RequiredLibraryRebuildStatus.failed,
          failure: RequiredLibraryRebuildFailure.signOutFailed,
        );
      }
    } finally {
      link.close();
    }
  }
}
