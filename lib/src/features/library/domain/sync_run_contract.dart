import 'package:navis/src/database/navis_database.dart';
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
  // Appended: rows persist the enum index.
  databaseBusy,
  // A promotion waited because the server scanned during collection.
  scanChanged,
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
    this.scanTriggered = false,
  });

  final LibrarySyncRequest request;
  final LibrarySyncPlanKind kind;
  final SyncExecutionBudget budget;
  final SyncSafeReason reason;

  /// The plan resumes a catalog snapshot that a new server scan queued (as
  /// opposed to the first-setup or repair snapshot). It needs unmetered data
  /// or the one-time broad grant, and a promotion that waits for a quiet
  /// server is reported as deferred.
  final bool scanTriggered;
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
  bool scanTriggeredSnapshot = false,
}) {
  if (policy.isOffline) return false;
  // A snapshot queued by a new server scan parses a full song listing: on a
  // metered network it needs the one-time broad grant, whatever the
  // unmetered-only setting says.
  if (scanTriggeredSnapshot &&
      kind == LibrarySyncPlanKind.catalogSnapshot &&
      policy.isMetered &&
      request.grant != SyncNetworkGrant.broadMeteredOnce) {
    return false;
  }
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

/// Longest automatic interval between scan-triggered catalog snapshots,
/// measured from the previous attempt. A manual check ignores it.
const librarySyncAutomaticSnapshotInterval = Duration(hours: 24);

/// Whether the snapshot work row's own state allows a new scan-triggered
/// snapshot, before any network request is spent finding out about the scan.
///
/// Queued and running work is picked up by selection. A failed snapshot keeps
/// its retry backoff unless the user asks. Otherwise an automatic pass waits
/// [librarySyncAutomaticSnapshotInterval] from the last attempt (the row's
/// last transition, so completed, cancelled and deferred attempts all count)
/// and a manual check never waits.
bool scanSnapshotWorkDue({
  required LibrarySyncWorkTableData? work,
  required DateTime now,
  required bool manual,
}) {
  switch (work?.status) {
    case null:
      return true;
    case 'running':
      return false;
    case 'queued':
      // Runnable work is picked up by selection; one still waiting out a
      // backoff is released by a manual check.
      final retryAt = work!.notBefore;
      return manual && retryAt != null && retryAt.isAfter(now);
    case 'failed':
      return manual;
    default:
      return manual || scanSnapshotAttemptStale(work!, now);
  }
}

/// Whether [work]'s last attempt is at least
/// [librarySyncAutomaticSnapshotInterval] old. A negative age means the clock
/// moved back, which counts as stale. Selection also uses this to let a failed
/// snapshot retry automatically at most once per interval.
bool scanSnapshotAttemptStale(LibrarySyncWorkTableData work, DateTime now) {
  final age = now.difference(work.updatedAt);
  return age.isNegative || age >= librarySyncAutomaticSnapshotInterval;
}

/// Whether a completed server scan has not yet been reconciled by a promoted
/// catalog snapshot and a new snapshot may start now.
///
/// A scan in progress records no token and so is never pending.
bool scanSnapshotDue({
  required LibraryScanObservationTableData? observation,
  required LibrarySyncWorkTableData? work,
  required DateTime now,
  required bool manual,
}) {
  final token = observation?.observedToken;
  return observation != null &&
      observation.scanSupported &&
      observation.pendingReconciliation &&
      token != null &&
      token != observation.reconciledToken &&
      scanSnapshotWorkDue(work: work, now: now, manual: manual);
}
