import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/utils/connectivity.dart';

/// Consecutive newest-feed checks that hit their page cap without reaching
/// known content (discovery debt) after which the coordinator escalates deep
/// discovery to delta reconciliation. Shared between the engine, which
/// records the streak, and the coordinator, which enqueues the follow-up.
const int discoveryDebtEscalationStreak = 2;

/// Freshness interval for independent starred and playlist-header work.
const librarySyncAuxiliaryInterval = Duration(hours: 12);

enum SyncEndpoint {
  indexes({'getIndexes'}),
  newestAlbums({'getNewestAlbumList2'}),
  catalogAlbums({'getAlbumList2', 'getAlbumListPage'}),
  artists({'getArtists'}),
  artist({'getArtist'}),
  album({'getAlbum'}),
  playlists({'getPlaylists', 'getPlaylist'}),
  starred({'getStarredContent'}),
  bulkSongs({'searchSongsPage'});

  new(this.requestNames);
  final Set<String> requestNames;
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
  // Retained because historical outcome rows persist this enum index.
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

class SyncExecutionPlan {
  const new({
    required this.request,
    required this.kind,
    required this.budget,
    required this.reason,
  });

  final LibrarySyncRequest request;
  final LibrarySyncPlanKind kind;
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

/// Admission shared by planning, durable work selection and live execution.
/// Explicit catalog and auxiliary work can continue while the app is hidden.
/// A metered grant changes network permission, never automatic playback or
/// visibility limits. Restored manual discovery retains its explicit intent, but
/// grants come only from the current caller. Full repairs require a fresh
/// explicit repair action.
bool librarySyncWorkAllowed({
  required LibrarySyncPlanKind kind,
  required String workClass,
  required LibrarySyncRequest request,
  required SyncNetworkPolicy policy,
  required bool isForeground,
  required bool hasActivePlayback,
  required bool isBackgroundExecutor,
}) {
  if (policy.isOffline) return false;
  if (kind == LibrarySyncPlanKind.fullRepair &&
      request.intent != SyncRunIntent.repairLibrary) {
    return false;
  }
  if (kind == LibrarySyncPlanKind.probe) return policy.allowsHardProbe;
  if (!isForeground &&
      !isBackgroundExecutor &&
      (request.isAutomatic ||
          request.target.kind.requiresEntityId ||
          workClass == 'interactive')) {
    return false;
  }
  if (!isForeground && isBackgroundExecutor && hasActivePlayback) return false;
  final interactive =
      kind == LibrarySyncPlanKind.targetedHydration &&
      (workClass == 'interactive' ||
          (request.target.kind.requiresEntityId && request.isInteraction));
  if (interactive) return policy.allowsInteractiveHydration;
  if (request.isAutomatic && hasActivePlayback) return false;
  if (request.grant == SyncNetworkGrant.broadMeteredOnce) return true;
  if (policy.isMetered && !policy.allowsBackgroundSync) {
    return kind == LibrarySyncPlanKind.deltaReconcile &&
        request.grant == SyncNetworkGrant.boundedMeteredDiscovery;
  }
  return policy.allowsBackgroundSync;
}
