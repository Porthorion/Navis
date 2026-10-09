import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/sync_run_contract.dart';
import 'package:navis/src/utils/connectivity.dart';

enum SyncCapabilityMode { unknown, reliable, unsupported }

class LibrarySyncPlannerContext {
  const new({
    required this.request,
    required this.networkPolicy,
    required this.hasAuthoritativeBaseline,
    required this.isCatalogCheckDue,
    required this.pendingHydrationCount,
    required this.pendingWorkCount,
    required this.indexesMode,
    required this.auxiliaryDue,
    required this.auditDue,
    required this.isForeground,
    required this.hasActivePlayback,
    this.isBackgroundExecutor = false,
  });

  final LibrarySyncRequest request;
  final SyncNetworkPolicy networkPolicy;
  final bool hasAuthoritativeBaseline;
  final bool isCatalogCheckDue;
  final int pendingHydrationCount;
  final int pendingWorkCount;
  final SyncCapabilityMode indexesMode;
  final bool auxiliaryDue;
  final bool auditDue;
  final bool isForeground;
  final bool hasActivePlayback;

  /// True only for the constrained Android WorkManager entrypoint. This is a
  /// scheduler capability, not a general permission to run in a hidden app.
  final bool isBackgroundExecutor;
}

class LibrarySyncPlanner {
  const new();

  LibrarySyncPlan plan(LibrarySyncPlannerContext context) {
    final plan = _plan(context);
    final request = context.request;
    if (!plan.shouldExecute ||
        librarySyncWorkAllowed(
          kind: plan.kind,
          workClass: 'background',
          request: request,
          policy: context.networkPolicy,
          isForeground: context.isForeground,
          hasActivePlayback: context.hasActivePlayback,
          isBackgroundExecutor: context.isBackgroundExecutor,
        )) {
      return plan;
    }
    final suffix = request.target.kind != LibrarySyncTargetKind.catalog
        ? context.networkPolicy.isOffline
              ? 'Offline'
              : context.networkPolicy.isMetered
              ? 'MeteredDeferred'
              : 'Deferred'
        : 'Deferred';
    return LibrarySyncPlan(
      kind: plan.kind,
      reason: '${plan.reason}$suffix',
      shouldExecute: false,
      deferred: true,
    );
  }

  LibrarySyncPlan _plan(LibrarySyncPlannerContext context) {
    final request = context.request;
    final target = request.target;
    if (target.kind != LibrarySyncTargetKind.catalog) {
      final isAuxiliaryTarget =
          target.kind == LibrarySyncTargetKind.starred ||
          target.kind == LibrarySyncTargetKind.playlistHeaders;
      if (request.intent == SyncRunIntent.automaticCatalogCheck &&
          isAuxiliaryTarget &&
          !context.auxiliaryDue) {
        return LibrarySyncPlan(
          kind: LibrarySyncPlanKind.targetedHydration,
          reason: '${target.kind.name}Fresh',
          shouldExecute: false,
        );
      }
      return LibrarySyncPlan(
        kind: LibrarySyncPlanKind.targetedHydration,
        reason: 'targeted${target.kind.name}',
      );
    }

    if (request.intent == SyncRunIntent.repairLibrary) {
      return LibrarySyncPlan(
        kind: LibrarySyncPlanKind.fullRepair,
        reason: 'userRequestedRepair',
      );
    }

    if (!context.hasAuthoritativeBaseline) {
      return LibrarySyncPlan(
        kind: LibrarySyncPlanKind.catalogSnapshot,
        reason: 'initialCatalog',
      );
    }

    // A user-requested check is a discovery operation, not an automatic
    // freshness-gated poll. `getIndexes` only invalidates the artist
    // collection, so the executor must also inspect the bounded newest-album
    // window even when that cursor is unchanged.
    if (request.intent == SyncRunIntent.manualCatalogCheck) {
      // Preserve manual discovery intent while offline. Downgrading it to a
      // probe would lose the newest-album check when the queued work resumes:
      // an unchanged getIndexes cursor cannot prove that an existing artist
      // has not received a new album.
      if (context.networkPolicy.isOffline) {
        return const LibrarySyncPlan(
          kind: LibrarySyncPlanKind.deltaReconcile,
          reason: 'manualCatalogDiscoveryOffline',
          shouldExecute: false,
          deferred: true,
        );
      }
      if (context.networkPolicy.isMetered &&
          request.grant != SyncNetworkGrant.broadMeteredOnce &&
          request.grant != SyncNetworkGrant.boundedMeteredDiscovery) {
        return const LibrarySyncPlan(
          kind: LibrarySyncPlanKind.probe,
          reason: 'manualMeteredProbe',
        );
      }
      return LibrarySyncPlan(
        kind: LibrarySyncPlanKind.deltaReconcile,
        reason:
            context.networkPolicy.isMetered &&
                request.grant != SyncNetworkGrant.broadMeteredOnce
            ? 'manualMeteredLimitedDiscovery'
            : 'manualCatalogDiscovery',
      );
    }

    // Without background-network permission or a broad grant, automatic catalog
    // checks stay probes; a bounded grant alone does not expand fresh planning.
    if (request.intent == SyncRunIntent.automaticCatalogCheck &&
        context.networkPolicy.isMetered &&
        !context.networkPolicy.allowsBackgroundSync &&
        request.grant != SyncNetworkGrant.broadMeteredOnce) {
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

    // A due discovery interval must not wait for an older hydration backlog.
    // The bounded delta pass also hydrates pending albums, with new arrivals
    // prioritized by the executor.
    if (context.isCatalogCheckDue && context.pendingHydrationCount > 0) {
      return LibrarySyncPlan(
        kind: LibrarySyncPlanKind.deltaReconcile,
        reason: 'automaticDiscoveryBeforeBacklog',
      );
    }

    if (context.pendingHydrationCount > 0) {
      return LibrarySyncPlan(
        kind: LibrarySyncPlanKind.targetedHydration,
        reason: 'resumePendingWork',
      );
    }

    if (context.indexesMode == SyncCapabilityMode.unsupported &&
        context.auditDue) {
      return LibrarySyncPlan(
        kind: LibrarySyncPlanKind.compatibilityAudit,
        reason: 'providerCompatibilityAudit',
      );
    }

    if (context.indexesMode == SyncCapabilityMode.reliable &&
        context.auditDue) {
      return LibrarySyncPlan(
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

    if (context.isCatalogCheckDue) {
      return LibrarySyncPlan(
        kind: LibrarySyncPlanKind.deltaReconcile,
        reason: 'automaticCatalogDiscovery',
      );
    }
    return const LibrarySyncPlan(
      kind: LibrarySyncPlanKind.probe,
      reason: 'auxiliaryDue',
    );
  }
}
