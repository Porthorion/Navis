import 'package:navis/src/database/navis_database.dart';
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
  bool scanTriggered = false,
  HeldDeletionConfirmation? confirms,
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
    confirmsHeldDeletion: confirms,
  );
  return SyncExecutionPlan(
    request: request,
    kind: kind,
    reason: SyncSafeReason.none,
    scanTriggered: scanTriggered,
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

/// A Repair Library press after the Apply Library Repair dialog: a full repair
/// that confirms the large deletion the stored state holds (its generation and
/// item count), or a plain one when nothing is held.
Future<SyncExecutionPlan> repairPlanAfterDialog(NavisDatabase database) async {
  final held = (await database.select(database.librarySyncStateTable).get())
      .where((row) => row.candidateStatus == 'awaitingDeletionConfirmation')
      .firstOrNull;
  return syncPlanForTest(
    LibrarySyncPlanKind.fullRepair,
    confirms: held == null || held.candidateGeneration == null
        ? null
        : HeldDeletionConfirmation(
            generation: held.candidateGeneration!,
            count: held.deletionCandidateCount,
          ),
  );
}
