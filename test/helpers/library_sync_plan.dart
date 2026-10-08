import 'package:navis/src/features/library/data/adaptive_library_sync_coordinator.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/sync_run_contract.dart';
import 'package:navis/src/utils/connectivity.dart';

/// Builds an executor plan with the same budget as production admission.
SyncExecutionPlan syncPlanForTest(
  LibrarySyncPlanKind kind, {
  SyncRunIntent? intent,
  LibrarySyncTarget target = const LibrarySyncTarget.catalog(),
  SyncNetworkGrant grant = SyncNetworkGrant.none,
  NetworkType networkType = NetworkType.other,
}) {
  final request = LibrarySyncRequest(
    origin: switch (kind) {
      LibrarySyncPlanKind.fullRepair => SyncRunOrigin.settingsRepair,
      LibrarySyncPlanKind.deltaReconcile =>
        intent == SyncRunIntent.automaticCatalogCheck
            ? SyncRunOrigin.timer
            : SyncRunOrigin.libraryPullToRefresh,
      LibrarySyncPlanKind.targetedHydration => SyncRunOrigin.interaction,
      _ => SyncRunOrigin.startup,
    },
    intent:
        intent ??
        switch (kind) {
          LibrarySyncPlanKind.fullRepair => SyncRunIntent.repairLibrary,
          LibrarySyncPlanKind.deltaReconcile =>
            SyncRunIntent.manualCatalogCheck,
          LibrarySyncPlanKind.targetedHydration =>
            target.kind == LibrarySyncTargetKind.starred ||
                    target.kind == LibrarySyncTargetKind.playlistHeaders
                ? SyncRunIntent.auxiliaryRefresh
                : SyncRunIntent.targetHydration,
          _ => SyncRunIntent.automaticCatalogCheck,
        },
    target: target,
    grant: grant,
  );
  return SyncExecutionPlan(
    request: request,
    kind: kind,
    reason: SyncSafeReason.none,
    budget: AdaptiveLibrarySyncCoordinator.executionBudgetFor(
      request: request,
      kind: kind,
      policy: resolveSyncNetworkPolicy(
        networkType: networkType,
        nativeMetered: networkType == NetworkType.cellular,
        backgroundSyncUnmeteredOnly: true,
      ),
    ),
  );
}
