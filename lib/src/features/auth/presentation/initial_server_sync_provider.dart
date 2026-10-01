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

/// Runs the catalog pass for first setup.
///
/// Without a committed catalog the planner already schedules its first-catalog
/// snapshot. Once a catalog exists (for example after an interrupted setup
/// followed by a keep-data sign-out and sign-in) the same request plans
/// bounded incremental discovery instead. That pass never publishes a catalog
/// and stops at its per-run budgets, so it cannot produce the completion or
/// usable-partial evidence first setup requires, and every retry would stay on
/// the full-screen route. Setup then runs the explicit full scan used by cache
/// upgrade, which publishes the catalog in its own run.
Future<LibrarySyncState> runInitialCatalogSync(
  Ref ref, {
  required bool allowMeteredBroadOverride,
}) async {
  final config = ref.read(serverConfigStateProvider).asData?.value;
  final serverId = config?.id;
  final hasCommittedCatalog =
      config?.lastSynced != null ||
      (serverId != null &&
          (await ref
                      .read(navisDatabaseProvider)
                      .librarySyncDao
                      .getOrCreateState(serverId))
                  .currentGeneration >
              0);
  final sync = ref.read(librarySyncControllerProvider.notifier);
  return hasCommittedCatalog
      ? sync.forceFullSync(allowMeteredBroadOverride: allowMeteredBroadOverride)
      : sync.syncNow(allowMeteredBroadOverride: allowMeteredBroadOverride);
}

class InitialServerSyncController extends Notifier<InitialServerSyncState> {
  Future<void>? _inFlight;
  int _inFlightEpoch = 0;
  int _epoch = 0;

  @override
  InitialServerSyncState build() {
    // Setup belongs to one signed-in session, so signing out and in again in
    // the same process starts over instead of inheriting a cancelled, failed
    // or finished setup. Riverpod keeps this notifier across rebuilds; the
    // epoch supersedes the previous session's runs.
    ref.watch(
      serverConfigStateProvider.select((config) {
        final server = config.asData?.value;
        return server == null ? null : (server.id, server.url, server.username);
      }),
    );
    _epoch += 1;
    ref.listen<SessionRoutePhase>(sessionRoutePhaseProvider, (_, next) {
      if (next == SessionRoutePhase.initialSyncRequired &&
          (state.status == InitialServerSyncStatus.idle ||
              state.status == InitialServerSyncStatus.complete)) {
        unawaited(start());
      } else if (next == SessionRoutePhase.ready &&
          state.status == InitialServerSyncStatus.idle) {
        state = const InitialServerSyncState(
          status: InitialServerSyncStatus.complete,
        );
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
    unawaited(Future<void>.microtask(start));
    return const InitialServerSyncState();
  }

  Future<void> start() => _start(allowMeteredBroadOverride: false);

  Future<void> retry() => _start(allowMeteredBroadOverride: false);

  Future<void> startUsingMobileData() =>
      _start(allowMeteredBroadOverride: true);

  Future<void> _start({required bool allowMeteredBroadOverride}) {
    if (!ref.mounted) return Future<void>.value();
    final inFlight = _inFlight;
    if (inFlight != null && _inFlightEpoch == _epoch) return inFlight;
    _inFlightEpoch = _epoch;
    late final Future<void> run;
    run = _run(allowMeteredBroadOverride: allowMeteredBroadOverride)
        .whenComplete(() {
          if (identical(_inFlight, run)) _inFlight = null;
        });
    return _inFlight = run;
  }

  /// Whether a run may still publish state: no cancellation or session change
  /// superseded it.
  bool _isCurrent(int runEpoch) => ref.mounted && runEpoch == _epoch;

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
    // The phase listener starts setup once the session is known to need it;
    // a completed profile must not run a setup pass while its phase loads.
    if (phase == SessionRoutePhase.loading) return;
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
      result = await runInitialCatalogSync(
        ref,
        allowMeteredBroadOverride: allowMeteredBroadOverride,
      );
    } on Object catch (error) {
      if (_isCurrent(runEpoch) &&
          state.status != InitialServerSyncStatus.cancelling) {
        state = InitialServerSyncState(
          status: InitialServerSyncStatus.failed,
          errorMessage: 'Setup failure: ${error.runtimeType}.',
        );
      }
      return;
    }
    if (!_isCurrent(runEpoch) ||
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
    if (!_isCurrent(runEpoch) ||
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
    if (!ref.mounted) return;
    await ref.read(signOutServiceProvider).signOut(wipeLocalData: true);
    if (!ref.mounted) return;
    await ref.read(serverConfigProvider.notifier).refresh();
    if (!ref.mounted) return;
    ref.invalidate(initialSyncRequiredProvider);
    // A completed sign-out has already reset this controller for the next
    // session. Sign-out steps fail softly, so a session can survive it; offer
    // retry rather than leaving setup in `cancelling`.
    if (state.status == InitialServerSyncStatus.cancelling) {
      state = const InitialServerSyncState(
        status: InitialServerSyncStatus.failed,
        errorMessage: 'Sign-out did not complete. Try again.',
      );
    }
  }
}
