import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/auth/data/sign_out_service.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
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

class RequiredLibraryRebuildState {
  const RequiredLibraryRebuildState({
    this.status = RequiredLibraryRebuildStatus.idle,
    this.errorMessage,
  });

  final RequiredLibraryRebuildStatus status;
  final String? errorMessage;
}

final requiredLibraryRebuildControllerProvider =
    NotifierProvider.family<
      RequiredLibraryRebuildController,
      RequiredLibraryRebuildState,
      RequiredLibraryRebuildReason
    >(RequiredLibraryRebuildController.new);

class RequiredLibraryRebuildController
    extends Notifier<RequiredLibraryRebuildState> {
  RequiredLibraryRebuildController(this._reason);

  final RequiredLibraryRebuildReason _reason;
  Future<void>? _inFlight;
  int _epoch = 0;
  bool _resetPrepared = false;

  @override
  RequiredLibraryRebuildState build() {
    ref.listen<ServerReachabilityState>(
      serverReachabilityControllerProvider,
      (_, next) {
        if (state.status == RequiredLibraryRebuildStatus.waitingForNetwork &&
            next.status == ServerReachabilityStatus.online) {
          unawaited(start());
        }
      },
    );
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
    unawaited(Future<void>.microtask(start));
    return const RequiredLibraryRebuildState();
  }

  Future<void> start() => _start(allowMeteredBroadOverride: false);

  Future<void> retry() => _start(allowMeteredBroadOverride: false);

  Future<void> startUsingMobileData() =>
      _start(allowMeteredBroadOverride: true);

  Future<void> _start({required bool allowMeteredBroadOverride}) {
    return _inFlight ??= _run(
      allowMeteredBroadOverride: allowMeteredBroadOverride,
    ).whenComplete(() => _inFlight = null);
  }

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
        if (runEpoch == _epoch) {
          state = RequiredLibraryRebuildState(
            status: RequiredLibraryRebuildStatus.failed,
            errorMessage: 'Library cache reset failed: ${error.runtimeType}.',
          );
        }
        return;
      }
      if (runEpoch != _epoch) return;
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
      if (runEpoch != _epoch ||
          state.status == RequiredLibraryRebuildStatus.cancelling) {
        return;
      }
      if (result.status == LibrarySyncStatus.succeeded &&
          await _hasCommittedCatalog()) {
        if (_reason == RequiredLibraryRebuildReason.cacheUpgrade) {
          await ref
              .read(cacheSystemUpgradeServiceProvider)
              .markCurrentVersionAfterSuccessfulScan();
        }
        if (_reason == RequiredLibraryRebuildReason.initialLogin) {
          ref.invalidate(initialSyncRequiredProvider);
        }
        state = const RequiredLibraryRebuildState(
          status: RequiredLibraryRebuildStatus.complete,
        );
        return;
      }
      state = RequiredLibraryRebuildState(
        status: RequiredLibraryRebuildStatus.failed,
        errorMessage:
            result.errorMessage ?? 'Library rebuild did not complete.',
      );
    } on Object catch (error) {
      if (runEpoch == _epoch &&
          state.status != RequiredLibraryRebuildStatus.cancelling) {
        state = RequiredLibraryRebuildState(
          status: RequiredLibraryRebuildStatus.failed,
          errorMessage: 'Library rebuild failed: ${error.runtimeType}.',
        );
      }
    }
  }

  Future<LibrarySyncState> _runInitialSync(bool allowMetered) {
    state = const RequiredLibraryRebuildState(
      status: RequiredLibraryRebuildStatus.syncing,
    );
    return ref
        .read(librarySyncControllerProvider.notifier)
        .syncNow(allowMeteredBroadOverride: allowMetered);
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
    return ref
        .read(librarySyncControllerProvider.notifier)
        .forceFullSync(allowMeteredBroadOverride: allowMetered);
  }

  Future<LibrarySyncState> _runRepair(bool allowMetered) {
    state = const RequiredLibraryRebuildState(
      status: RequiredLibraryRebuildStatus.syncing,
    );
    return ref
        .read(librarySyncControllerProvider.notifier)
        .forceFullSync(allowMeteredBroadOverride: allowMetered);
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

  Future<bool> _hasCommittedCatalog() async {
    final serverId = ref.read(serverConfigStateProvider).asData?.value?.id;
    if (serverId == null) return false;
    final persisted = await ref
        .read(navisDatabaseProvider)
        .librarySyncDao
        .getOrCreateState(serverId);
    return persisted.currentGeneration > 0 &&
        persisted.candidateStatus != 'applying';
  }

  Future<void> cancelAndSignOut() async {
    if (state.status == RequiredLibraryRebuildStatus.cancelling) return;
    state = const RequiredLibraryRebuildState(
      status: RequiredLibraryRebuildStatus.cancelling,
    );
    _epoch += 1;
    await ref.read(signOutServiceProvider).signOut(wipeLocalData: false);
    await ref.read(serverConfigProvider.notifier).refresh();
    ref.invalidate(initialSyncRequiredProvider);
  }
}
