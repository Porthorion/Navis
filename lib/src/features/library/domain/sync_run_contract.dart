import 'package:navis/src/features/library/domain/library_sync_request.dart';

/// Consecutive newest-feed checks that hit their page cap without reaching
/// known content (discovery debt) after which the coordinator escalates deep
/// discovery to delta reconciliation. Shared between the engine, which
/// records the streak, and the coordinator, which enqueues the follow-up.
const int discoveryDebtEscalationStreak = 2;

/// The source of a durable sync request. These values intentionally describe
/// a user or scheduler action rather than an implementation detail.
enum SyncRunOrigin {
  libraryPullToRefresh,
  settingsRepair,
  cacheReset,
  homeRefresh,
  desktopCommand,
  startup,
  timer,
  resume,
  reconnect,
  interaction,
  androidWorker,
  migration,
  invariant,
  legacyRecovery,
}

/// The user-visible contract that a request carries through scheduling.
enum SyncRunIntent {
  automaticCatalogCheck,
  manualCatalogCheck,
  repairLibrary,
  targetHydration,
  auxiliaryRefresh,
}

/// A user grant for metered network work. Unmetered access is a network
/// condition, not a grant, so it is deliberately not represented here.
enum SyncNetworkGrant { none, boundedMeteredDiscovery, broadMeteredOnce }

/// A single executor path. The executor receives this plan directly and must
/// never infer intent from legacy boolean flags.
enum SyncExecutionPlanKind {
  automaticProbe,
  manualCatalogDiscovery,
  repairLibrary,
  targetHydration,
  auxiliaryRefresh,
  catalogSnapshot,
  compatibilityAudit,
}

enum SyncEndpoint {
  indexes,
  newestAlbums,
  catalogAlbums,
  artists,
  artist,
  album,
  playlists,
  starred,
  bulkSongs,
}

/// Safe, durable outcome categories. These are deliberately not derived from
/// display strings or exception messages.
enum SyncRunOutcomeKind {
  completed,
  noChanges,
  deferred,
  cancelled,
  partial,
  failed,
  awaitingConfirmation,
  skipped,
}

/// Redacted, stable explanations suitable for settings and diagnostics.
enum SyncSafeReason {
  none,
  offline,
  meteredPolicy,
  activePlayback,
  backgrounded,
  cooldown,
  leaseHeld,
  cancellation,
  confirmationRequired,
  networkFailure,
  authenticationFailure,
  responseBudgetExceeded,
  providerUnsupported,
  legacyAmbiguous,
  unknownFailure,
}

/// Immutable network and endpoint limits resolved once by the scheduler.
class SyncExecutionBudget {
  const new({
    required this.allowedEndpoints,
    required this.maxNewestPages,
    required this.maxAlbumHydrations,
    required this.maxResponseBytes,
    required this.maxTotalBytes,
    required this.maxConcurrency,
    this.maxRequests = 10000,
    this.maxDuration = const Duration(minutes: 10),
  });

  final Set<SyncEndpoint> allowedEndpoints;
  final int maxNewestPages;
  final int maxAlbumHydrations;
  final int? maxResponseBytes;
  final int? maxTotalBytes;
  final int maxConcurrency;
  final int maxRequests;
  final Duration maxDuration;
}

/// A request is immutable from its caller through durable scheduling and
/// execution. The compatibility adapter below is the only bridge from the
/// previous [LibrarySyncRequest] shape.
class SyncRunRequest {
  const new({
    required this.contractVersion,
    required this.origin,
    required this.intent,
    required this.target,
    required this.networkGrant,
    required this.priority,
    this.resumedFromRequestId,
  });

  static const int currentContractVersion = 1;

  final int contractVersion;
  final SyncRunOrigin origin;
  final SyncRunIntent intent;
  final LibrarySyncTarget target;
  final SyncNetworkGrant networkGrant;
  final int priority;
  final int? resumedFromRequestId;

  /// An intent-specific durable key. In particular, an automatic probe and a
  /// manual discovery request never coalesce merely because both address the
  /// catalog. A device-cache reset also never joins Repair Library: they share
  /// catalog collection but have different destructive local preparation and
  /// user-facing recovery contracts.
  String get coalescingKey {
    final recoveryOrigin = switch (origin) {
      SyncRunOrigin.settingsRepair || SyncRunOrigin.cacheReset => origin.name,
      _ => '',
    };
    return [
      intent.name,
      target.kind.name,
      target.entityId ?? '',
      networkGrant.name,
      recoveryOrigin,
    ].join(':');
  }
}

class SyncExecutionPlan {
  const new({
    required this.request,
    required this.kind,
    required this.budget,
    required this.reason,
  });

  final SyncRunRequest request;
  final SyncExecutionPlanKind kind;
  final SyncExecutionBudget budget;
  final SyncSafeReason reason;
}

class SyncRunOutcome {
  const new({
    required this.kind,
    required this.reason,
    this.requestCount = 0,
    this.byteCount = 0,
  });

  final SyncRunOutcomeKind kind;
  final SyncSafeReason reason;
  final int requestCount;
  final int byteCount;
}

/// Transitional conversion from the legacy request model. It is intentionally
/// centralized so callers do not spread origin/permission guesses through
/// coordinators and executors.
SyncRunRequest syncRunRequestFromLegacy(
  LibrarySyncRequest request, {
  int? resumedFromRequestId,
}) {
  final intent = switch (request.target.kind) {
    LibrarySyncTargetKind.catalog => switch (request.intent) {
      LibrarySyncIntent.automatic => SyncRunIntent.automaticCatalogCheck,
      LibrarySyncIntent.checkForUpdates => SyncRunIntent.manualCatalogCheck,
      LibrarySyncIntent.repair => SyncRunIntent.repairLibrary,
    },
    LibrarySyncTargetKind.starred ||
    LibrarySyncTargetKind.playlistHeaders => SyncRunIntent.auxiliaryRefresh,
    _ => SyncRunIntent.targetHydration,
  };
  final origin = switch (request.caller) {
    LibrarySyncRequestCaller.repairLibrary => SyncRunOrigin.settingsRepair,
    LibrarySyncRequestCaller.cacheReset => SyncRunOrigin.cacheReset,
    _ => switch (request.trigger) {
      LibrarySyncTrigger.startup => SyncRunOrigin.startup,
      LibrarySyncTrigger.interval => SyncRunOrigin.timer,
      LibrarySyncTrigger.resume => SyncRunOrigin.resume,
      LibrarySyncTrigger.reconnect => SyncRunOrigin.reconnect,
      LibrarySyncTrigger.interaction => SyncRunOrigin.interaction,
      LibrarySyncTrigger.migration => SyncRunOrigin.migration,
      LibrarySyncTrigger.invariant => SyncRunOrigin.invariant,
      LibrarySyncTrigger.user => SyncRunOrigin.libraryPullToRefresh,
    },
  };
  final grant = request.allowMeteredBroadOverride
      ? SyncNetworkGrant.broadMeteredOnce
      : request.allowMeteredLimitedDiscovery
      ? SyncNetworkGrant.boundedMeteredDiscovery
      : SyncNetworkGrant.none;
  final priority = switch (intent) {
    SyncRunIntent.repairLibrary => 80,
    SyncRunIntent.manualCatalogCheck => 60,
    SyncRunIntent.targetHydration => 100,
    SyncRunIntent.auxiliaryRefresh => 40,
    SyncRunIntent.automaticCatalogCheck => 20,
  };
  return SyncRunRequest(
    contractVersion: SyncRunRequest.currentContractVersion,
    origin: origin,
    intent: intent,
    target: request.target,
    networkGrant: grant,
    priority: priority,
    resumedFromRequestId: resumedFromRequestId,
  );
}

SyncExecutionPlanKind syncExecutionPlanKindFromLegacy(
  LibrarySyncPlanKind kind,
  SyncRunRequest request,
) {
  return switch (kind) {
    LibrarySyncPlanKind.probe => SyncExecutionPlanKind.automaticProbe,
    LibrarySyncPlanKind.deltaReconcile =>
      SyncExecutionPlanKind.manualCatalogDiscovery,
    LibrarySyncPlanKind.fullRepair => SyncExecutionPlanKind.repairLibrary,
    LibrarySyncPlanKind.targetedHydration =>
      request.intent == SyncRunIntent.auxiliaryRefresh
          ? SyncExecutionPlanKind.auxiliaryRefresh
          : SyncExecutionPlanKind.targetHydration,
    LibrarySyncPlanKind.catalogSnapshot =>
      SyncExecutionPlanKind.catalogSnapshot,
    LibrarySyncPlanKind.compatibilityAudit =>
      SyncExecutionPlanKind.compatibilityAudit,
  };
}
