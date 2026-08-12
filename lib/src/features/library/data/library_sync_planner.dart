import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/utils/connectivity.dart';

enum SyncCapabilityMode { unknown, reliable, unsupported }

class LibrarySyncPlannerContext {
  const LibrarySyncPlannerContext({
    required this.request,
    required this.networkType,
    required this.restrictsBackgroundSync,
    required this.hasAuthoritativeBaseline,
    required this.isCatalogCheckDue,
    required this.pendingHydrationCount,
    required this.pendingWorkCount,
    required this.indexesMode,
    required this.indexChanged,
    required this.changeIsExplainable,
    required this.auxiliaryDue,
    required this.auditDue,
    required this.repairRequired,
    required this.isForeground,
    required this.hasActivePlayback,
  });

  final LibrarySyncRequest request;
  final NetworkType networkType;
  final bool restrictsBackgroundSync;
  final bool hasAuthoritativeBaseline;
  final bool isCatalogCheckDue;
  final int pendingHydrationCount;
  final int pendingWorkCount;
  final SyncCapabilityMode indexesMode;
  final bool? indexChanged;
  final bool changeIsExplainable;
  final bool auxiliaryDue;
  final bool auditDue;
  final bool repairRequired;
  final bool isForeground;
  final bool hasActivePlayback;
}

class LibrarySyncPlanner {
  const LibrarySyncPlanner();

  LibrarySyncPlan plan(LibrarySyncPlannerContext context) {
    final request = context.request;
    final target = request.target;
    if (target.kind != LibrarySyncTargetKind.catalog) {
      final isAuxiliaryTarget =
          target.kind == LibrarySyncTargetKind.starred ||
          target.kind == LibrarySyncTargetKind.playlistHeaders ||
          target.kind == LibrarySyncTargetKind.genres;
      final isInteractiveEntity =
          target.kind == LibrarySyncTargetKind.artist ||
          target.kind == LibrarySyncTargetKind.album ||
          target.kind == LibrarySyncTargetKind.playlist;
      if (request.intent == LibrarySyncIntent.automatic &&
          isAuxiliaryTarget &&
          !context.auxiliaryDue) {
        return LibrarySyncPlan(
          kind: LibrarySyncPlanKind.targetedHydration,
          reason: '${target.kind.name}Fresh',
          shouldExecute: false,
        );
      }
      if (context.networkType == NetworkType.offline) {
        return LibrarySyncPlan(
          kind: LibrarySyncPlanKind.targetedHydration,
          reason: 'targeted${target.kind.name}Offline',
          shouldExecute: false,
          deferred: true,
        );
      }
      if (context.restrictsBackgroundSync &&
          (!isInteractiveEntity ||
              request.trigger != LibrarySyncTrigger.interaction)) {
        return LibrarySyncPlan(
          kind: LibrarySyncPlanKind.targetedHydration,
          reason: 'targeted${target.kind.name}MeteredDeferred',
          shouldExecute: false,
          deferred: true,
        );
      }
      return LibrarySyncPlan(
        kind: LibrarySyncPlanKind.targetedHydration,
        reason: 'targeted${target.kind.name}',
      );
    }

    if (request.intent == LibrarySyncIntent.repair) {
      return _broadPlan(
        context,
        kind: LibrarySyncPlanKind.fullRepair,
        reason: 'userRequestedRepair',
      );
    }

    if (!context.hasAuthoritativeBaseline) {
      return _broadPlan(
        context,
        kind: LibrarySyncPlanKind.catalogSnapshot,
        reason: 'initialCatalog',
      );
    }

    if (context.repairRequired) {
      return _broadPlan(
        context,
        kind: LibrarySyncPlanKind.fullRepair,
        reason: 'catalogInvariantRepair',
      );
    }

    // A user-requested check is a discovery operation, not an automatic
    // freshness-gated poll. `getIndexes` only invalidates the artist
    // collection, so the executor must also inspect the bounded newest-album
    // window even when that cursor is unchanged.
    if (request.intent == LibrarySyncIntent.checkForUpdates) {
      // Preserve manual discovery intent while offline. Downgrading it to a
      // probe would lose the newest-album check when the queued work resumes:
      // an unchanged getIndexes cursor cannot prove that an existing artist
      // has not received a new album.
      if (context.networkType == NetworkType.offline) {
        return const LibrarySyncPlan(
          kind: LibrarySyncPlanKind.deltaReconcile,
          reason: 'manualCatalogDiscoveryOffline',
          shouldExecute: false,
          deferred: true,
        );
      }
      if (context.restrictsBackgroundSync &&
          !request.allowMeteredBroadOverride) {
        return const LibrarySyncPlan(
          kind: LibrarySyncPlanKind.probe,
          reason: 'manualMeteredProbe',
        );
      }
      return const LibrarySyncPlan(
        kind: LibrarySyncPlanKind.deltaReconcile,
        reason: 'manualCatalogDiscovery',
      );
    }

    // Metered automatic catalog work is a hard probe only — pending hydration
    // must not expand into background artist/album verification on cellular.
    if (request.intent == LibrarySyncIntent.automatic &&
        context.restrictsBackgroundSync) {
      if (!context.isCatalogCheckDue &&
          !context.auxiliaryDue &&
          context.pendingHydrationCount == 0 &&
          context.pendingWorkCount == 0) {
        return const LibrarySyncPlan(
          kind: LibrarySyncPlanKind.probe,
          reason: 'allDomainsFresh',
          shouldExecute: false,
        );
      }
      return const LibrarySyncPlan(
        kind: LibrarySyncPlanKind.probe,
        reason: 'cellularProbeOnly',
      );
    }

    if (context.pendingHydrationCount > 0) {
      return const LibrarySyncPlan(
        kind: LibrarySyncPlanKind.targetedHydration,
        reason: 'resumePendingWork',
      );
    }

    if (context.indexChanged == true) {
      if (context.changeIsExplainable) {
        return const LibrarySyncPlan(
          kind: LibrarySyncPlanKind.deltaReconcile,
          reason: 'boundedCatalogDelta',
        );
      }
      return _broadPlan(
        context,
        kind: LibrarySyncPlanKind.catalogSnapshot,
        reason: 'unexplainedCatalogChange',
      );
    }

    if (context.indexesMode == SyncCapabilityMode.unsupported &&
        context.auditDue) {
      return _broadPlan(
        context,
        kind: LibrarySyncPlanKind.compatibilityAudit,
        reason: 'providerCompatibilityAudit',
      );
    }

    if (context.indexesMode == SyncCapabilityMode.reliable &&
        context.auditDue) {
      return _broadPlan(
        context,
        kind: LibrarySyncPlanKind.compatibilityAudit,
        reason: 'weeklyRotatingVerification',
      );
    }

    if (!context.isCatalogCheckDue &&
        !context.auxiliaryDue &&
        !context.auditDue) {
      return const LibrarySyncPlan(
        kind: LibrarySyncPlanKind.probe,
        reason: 'allDomainsFresh',
        shouldExecute: false,
      );
    }

    return LibrarySyncPlan(
      kind: LibrarySyncPlanKind.probe,
      reason: context.auxiliaryDue ? 'auxiliaryDue' : 'catalogProbeDue',
    );
  }

  LibrarySyncPlan _broadPlan(
    LibrarySyncPlannerContext context, {
    required LibrarySyncPlanKind kind,
    required String reason,
  }) {
    final unavailable =
        context.networkType == NetworkType.offline ||
        (context.restrictsBackgroundSync &&
            !context.request.allowMeteredBroadOverride);
    final unsafeToAutoRun =
        unavailable ||
        (context.request.intent == LibrarySyncIntent.automatic &&
            (!context.isForeground || context.hasActivePlayback));
    if (unsafeToAutoRun) {
      return LibrarySyncPlan(
        kind: kind,
        reason: '${reason}Deferred',
        shouldExecute: false,
        deferred: true,
      );
    }
    return LibrarySyncPlan(kind: kind, reason: reason);
  }
}
