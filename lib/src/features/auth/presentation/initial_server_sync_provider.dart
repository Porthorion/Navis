import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/auth/data/sign_out_service.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/auth/presentation/session_route_provider.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';

enum InitialServerSyncStatus {
  idle,
  waitingForNetwork,
  waitingForMobileConsent,
  running,
  failed,
  cancelling,
  complete,
}

class InitialServerSyncState {
  const new({
    this.status = InitialServerSyncStatus.idle,
    this.errorMessage,
    this.completedWithWarnings = false,
  });

  final InitialServerSyncStatus status;
  final String? errorMessage;
  final bool completedWithWarnings;
}

final initialServerSyncControllerProvider =
    NotifierProvider<InitialServerSyncController, InitialServerSyncState>(
      InitialServerSyncController.new,
    );

class InitialSyncCompletionWarningController extends Notifier<bool> {
  @override
  bool build() => false;

  void show() => state = true;

  void consume() => state = false;
}

final initialSyncCompletionWarningProvider =
    NotifierProvider<InitialSyncCompletionWarningController, bool>(
      InitialSyncCompletionWarningController.new,
    );

class InitialServerSyncController extends Notifier<InitialServerSyncState> {
  Future<void>? _inFlight;
  int _epoch = 0;

  @override
  InitialServerSyncState build() {
    ref.listen<SessionRoutePhase>(sessionRoutePhaseProvider, (_, next) {
      if (next == SessionRoutePhase.initialSyncRequired &&
          (state.status == InitialServerSyncStatus.idle ||
              state.status == InitialServerSyncStatus.complete)) {
        unawaited(start());
      }
    });
    ref.listen<ServerReachabilityState>(serverReachabilityControllerProvider, (
      _,
      next,
    ) {
      if (state.status == InitialServerSyncStatus.waitingForNetwork &&
          next.status == ServerReachabilityStatus.online) {
        unawaited(start());
      }
    });
    ref.listen<SyncNetworkPolicy>(syncNetworkPolicyProvider, (_, next) {
      if (state.status == InitialServerSyncStatus.waitingForNetwork &&
          !next.isOffline) {
        unawaited(start());
      }
      if (state.status == InitialServerSyncStatus.waitingForMobileConsent &&
          !next.isMetered) {
        unawaited(start());
      }
    });
    Future<void>.microtask(start);
    return const InitialServerSyncState();
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
    final phase = ref.read(sessionRoutePhaseProvider);
    if (phase == SessionRoutePhase.ready ||
        phase == SessionRoutePhase.unauthenticated) {
      state = const InitialServerSyncState(
        status: InitialServerSyncStatus.complete,
      );
      return;
    }
    final reachability = ref.read(serverReachabilityControllerProvider);
    final policy = ref.read(syncNetworkPolicyProvider);
    if (reachability.status != ServerReachabilityStatus.online ||
        policy.isOffline) {
      state = const InitialServerSyncState(
        status: InitialServerSyncStatus.waitingForNetwork,
      );
      return;
    }
    if (policy.isMetered && !allowMeteredBroadOverride) {
      state = const InitialServerSyncState(
        status: InitialServerSyncStatus.waitingForMobileConsent,
      );
      return;
    }

    state = const InitialServerSyncState(
      status: InitialServerSyncStatus.running,
    );
    late final LibrarySyncState result;
    try {
      result = await ref
          .read(librarySyncControllerProvider.notifier)
          .syncNow(allowMeteredBroadOverride: allowMeteredBroadOverride);
    } on Object catch (error) {
      if (runEpoch == _epoch &&
          state.status != InitialServerSyncStatus.cancelling) {
        state = InitialServerSyncState(
          status: InitialServerSyncStatus.failed,
          errorMessage: 'Setup failure: ${error.runtimeType}.',
        );
      }
      return;
    }
    if (runEpoch != _epoch ||
        state.status == InitialServerSyncStatus.cancelling) {
      return;
    }
    final serverId = ref.read(serverConfigStateProvider).asData?.value?.id;
    final ready =
        serverId != null &&
        await recordInitialCatalogReadiness(
          database: ref.read(navisDatabaseProvider),
          serverId: serverId,
          result: result,
        );
    if (runEpoch != _epoch ||
        state.status == InitialServerSyncStatus.cancelling) {
      return;
    }
    if (ready) {
      final withWarnings = isUsableIncompleteAlbumSyncRun(result);
      state = InitialServerSyncState(
        status: InitialServerSyncStatus.complete,
        completedWithWarnings: withWarnings,
      );
      if (withWarnings) {
        ref.read(initialSyncCompletionWarningProvider.notifier).show();
      }
      ref.invalidate(initialSyncRequiredProvider);
      return;
    }
    state = InitialServerSyncState(
      status: InitialServerSyncStatus.failed,
      errorMessage:
          result.errorMessage ?? 'Initial server sync did not complete.',
    );
  }

  Future<void> cancelAndLogOut() async {
    if (state.status == InitialServerSyncStatus.cancelling) {
      return;
    }
    state = const InitialServerSyncState(
      status: InitialServerSyncStatus.cancelling,
    );
    _epoch += 1;
    // Keep the acknowledgement on screen long enough to render before a fast
    // local teardown changes the route to Login. Real sync cancellation often
    // takes longer, but an empty first-sync profile can otherwise skip this
    // feedback entirely.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await ref.read(signOutServiceProvider).signOut(wipeLocalData: true);
    await ref.read(serverConfigProvider.notifier).refresh();
    ref.invalidate(initialSyncRequiredProvider);
  }
}
