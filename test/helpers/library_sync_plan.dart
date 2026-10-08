import 'package:navis/src/features/library/data/adaptive_library_sync_coordinator.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/sync_run_contract.dart';
import 'package:navis/src/utils/connectivity.dart';

/// Builds an executor plan with the same budget as production admission.
SyncExecutionPlan syncPlanForTest(
  SyncExecutionPlanKind kind, {
  SyncRunIntent? intent,
  LibrarySyncTarget target = const LibrarySyncTarget.catalog(),
  SyncNetworkGrant grant = SyncNetworkGrant.none,
  NetworkType networkType = NetworkType.other,
}) {
  final request = SyncRunRequest(
    origin: switch (kind) {
      SyncExecutionPlanKind.repairLibrary => SyncRunOrigin.settingsRepair,
      SyncExecutionPlanKind.manualCatalogDiscovery =>
        intent == SyncRunIntent.automaticCatalogCheck
            ? SyncRunOrigin.timer
            : SyncRunOrigin.libraryPullToRefresh,
      SyncExecutionPlanKind.targetHydration => SyncRunOrigin.interaction,
      _ => SyncRunOrigin.startup,
    },
    intent:
        intent ??
        switch (kind) {
          SyncExecutionPlanKind.repairLibrary => SyncRunIntent.repairLibrary,
          SyncExecutionPlanKind.manualCatalogDiscovery =>
            SyncRunIntent.manualCatalogCheck,
          SyncExecutionPlanKind.targetHydration =>
            SyncRunIntent.targetHydration,
          SyncExecutionPlanKind.auxiliaryRefresh =>
            SyncRunIntent.auxiliaryRefresh,
          _ => SyncRunIntent.automaticCatalogCheck,
        },
    target: target,
    networkGrant: grant,
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
