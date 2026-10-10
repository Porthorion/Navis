import 'package:flutter/foundation.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';

enum LibrarySyncStatus {
  idle,
  running,
  succeeded,
  partial,
  skipped,
  deferred,
  cancelled,
  failed,
}

enum LibrarySyncMode { fullInitial, incremental, forceFull }

enum LibrarySyncFreshness { current, verificationPending, repairRecommended }

enum LibrarySyncStage {
  idle,
  preparing,
  fetchingArtists,
  fetchingAlbums,
  persistingMetadata,
  fetchingSongs,
  fetchingStarred,
  fetchingPlaylists,
  collectingCandidate,
  validatingCandidate,
  applyingCandidate,
  cleaningCandidate,
  finalizing,
  completed,
}

@immutable
class LibrarySyncState {
  const new({
    required this.status,
    required this.stage,
    this.mode,
    this.runRequestId,
    this.runAttemptId,
    this.metadataReady = false,
    this.isHydrating = false,
    this.fastPathActive = false,
    this.songIndexEntriesScanned = 0,
    this.processed,
    this.total,
    this.hydratedAlbums,
    this.pendingHydrationCount,
    this.onlyIncompleteAlbumDetails = false,
    this.catalogPublishedThisRun = false,
    this.startedAt,
    this.completedAt,
    this.errorMessage,
    this.lastSyncedAt,
    this.lastCheckedAt,
    this.nextAutomaticCheckAt,
    this.nextRetryAt,
    this.lastCatalogUpdatedAt,
    this.lastAuxiliarySyncedAt,
    this.starredSynchronized = false,
    this.playlistHeadersSynchronized = false,
    this.apiRequests = 0,
    this.endpointRequests = const <String, int>{},
    this.apiRetries = 0,
    this.apiFailures = 0,
    this.averageLatencyMs,
    this.dbWriteBatches = 0,
    this.hydrationThroughputAlbumsPerSecond,
    this.freshness = LibrarySyncFreshness.verificationPending,
    this.remainingVerificationCount = 0,
    this.canonicalizedSongCount = 0,
    this.ambiguousMatchCount = 0,
    this.planKind,
    this.planReason,
    this.pendingWorkCount = 0,
    this.lastRunBytes = 0,
    this.failureCategory,
    this.candidateGeneration,
    this.candidateStatus,
    this.deletionCandidateCount = 0,
    this.carriedForwardEntityCount = 0,
    this.lastApplyDurationMs,
    this.probeIndexChanged,
    this.probeEvidenceVersion,
    this.probeIndexesUnsupported = false,
    this.probeDiscoveryDebtStreak,
    this.updatesAvailable = false,
  });

  const new idle({
    DateTime? lastSyncedAt,
    LibrarySyncFreshness freshness = LibrarySyncFreshness.verificationPending,
  }) : this(
         status: LibrarySyncStatus.idle,
         stage: LibrarySyncStage.idle,
         lastSyncedAt: lastSyncedAt,
         freshness: freshness,
       );

  final LibrarySyncStatus status;
  final LibrarySyncStage stage;
  final LibrarySyncMode? mode;
  final int? runRequestId;
  final int? runAttemptId;
  final bool metadataReady;
  final bool isHydrating;
  final bool fastPathActive;

  /// Number of songs observed while the server's bulk song index is scanned.
  ///
  /// This is an activity reference, not a completion percentage: compatible
  /// Subsonic servers do not report a reliable total for the index.
  final int songIndexEntriesScanned;
  final int? processed;
  final int? total;
  final int? hydratedAlbums;
  final int? pendingHydrationCount;

  /// Every still-pending canonical album has a persisted incomplete detail
  /// response classification matching its current metadata. Conflicting
  /// snapshots, transport, and other failures never set it.
  final bool onlyIncompleteAlbumDetails;

  /// Pending albums block freshness unless all have valid persisted
  /// incomplete server-detail classifications. The full backlog still retries.
  bool get hasBlockingPendingAlbums =>
      (pendingHydrationCount ?? 0) > 0 && !onlyIncompleteAlbumDetails;

  /// A validated full candidate became the committed catalog during this run.
  final bool catalogPublishedThisRun;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final String? errorMessage;
  final DateTime? lastSyncedAt;
  final DateTime? lastCheckedAt;
  final DateTime? nextAutomaticCheckAt;

  /// Durable cooldown after a failed catalog operation.
  ///
  /// This is separate from [nextAutomaticCheckAt]: the latter is normal
  /// scheduling, while this value explains why automatic catalog work is
  /// deliberately waiting after an endpoint or transport failure.
  final DateTime? nextRetryAt;
  final DateTime? lastCatalogUpdatedAt;
  final DateTime? lastAuxiliarySyncedAt;
  final bool starredSynchronized;
  final bool playlistHeadersSynchronized;
  final int apiRequests;
  final Map<String, int> endpointRequests;
  final int apiRetries;
  final int apiFailures;
  final int? averageLatencyMs;
  final int dbWriteBatches;
  final double? hydrationThroughputAlbumsPerSecond;
  final LibrarySyncFreshness freshness;
  final int remainingVerificationCount;
  final int canonicalizedSongCount;
  final int ambiguousMatchCount;
  final LibrarySyncPlanKind? planKind;
  final String? planReason;
  final int pendingWorkCount;
  final int lastRunBytes;
  final String? failureCategory;
  final int? candidateGeneration;
  final String? candidateStatus;

  /// Number of server-missing entities awaiting an explicit repair retry.
  final int deletionCandidateCount;
  final int carriedForwardEntityCount;
  final int? lastApplyDurationMs;
  final bool? probeIndexChanged;
  final String? probeEvidenceVersion;
  final bool probeIndexesUnsupported;

  /// Consecutive newest-feed checks that hit their page cap without reaching
  /// known content. Non-zero widens the next check and, past the escalation
  /// threshold, tells the coordinator to enqueue broad reconciliation.
  final int? probeDiscoveryDebtStreak;
  final bool updatesAvailable;

  bool get isRunning => status == LibrarySyncStatus.running;

  LibrarySyncState copyWith({
    LibrarySyncStatus? status,
    LibrarySyncStage? stage,
    LibrarySyncMode? mode,
    int? runRequestId,
    int? runAttemptId,
    bool clearRunIdentity = false,
    bool? metadataReady,
    bool? isHydrating,
    bool? fastPathActive,
    int? songIndexEntriesScanned,
    int? processed,
    bool clearProcessed = false,
    int? total,
    bool clearTotal = false,
    int? hydratedAlbums,
    bool clearHydratedAlbums = false,
    int? pendingHydrationCount,
    bool? onlyIncompleteAlbumDetails,
    bool? catalogPublishedThisRun,
    bool clearPendingHydrationCount = false,
    DateTime? startedAt,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    String? errorMessage,
    bool clearErrorMessage = false,
    DateTime? lastSyncedAt,
    DateTime? lastCheckedAt,
    DateTime? nextAutomaticCheckAt,
    bool clearNextAutomaticCheckAt = false,
    DateTime? nextRetryAt,
    bool clearNextRetryAt = false,
    DateTime? lastCatalogUpdatedAt,
    DateTime? lastAuxiliarySyncedAt,
    bool? starredSynchronized,
    bool? playlistHeadersSynchronized,
    int? apiRequests,
    Map<String, int>? endpointRequests,
    int? apiRetries,
    int? apiFailures,
    int? averageLatencyMs,
    bool clearAverageLatencyMs = false,
    int? dbWriteBatches,
    double? hydrationThroughputAlbumsPerSecond,
    bool clearHydrationThroughput = false,
    LibrarySyncFreshness? freshness,
    int? remainingVerificationCount,
    int? canonicalizedSongCount,
    int? ambiguousMatchCount,
    LibrarySyncPlanKind? planKind,
    String? planReason,
    bool clearPlanReason = false,
    int? pendingWorkCount,
    int? lastRunBytes,
    String? failureCategory,
    bool clearFailureCategory = false,
    int? candidateGeneration,
    bool clearCandidateGeneration = false,
    String? candidateStatus,
    bool clearCandidateStatus = false,
    int? deletionCandidateCount,
    int? carriedForwardEntityCount,
    int? lastApplyDurationMs,
    bool? probeIndexChanged,
    String? probeEvidenceVersion,
    bool? probeIndexesUnsupported,
    int? probeDiscoveryDebtStreak,
    bool? updatesAvailable,
  }) {
    return LibrarySyncState(
      status: status ?? this.status,
      runRequestId: clearRunIdentity ? null : runRequestId ?? this.runRequestId,
      runAttemptId: clearRunIdentity ? null : runAttemptId ?? this.runAttemptId,
      stage: stage ?? this.stage,
      mode: mode ?? this.mode,
      metadataReady: metadataReady ?? this.metadataReady,
      isHydrating: isHydrating ?? this.isHydrating,
      fastPathActive: fastPathActive ?? this.fastPathActive,
      songIndexEntriesScanned:
          songIndexEntriesScanned ?? this.songIndexEntriesScanned,
      processed: clearProcessed ? null : processed ?? this.processed,
      total: clearTotal ? null : total ?? this.total,
      hydratedAlbums: clearHydratedAlbums
          ? null
          : hydratedAlbums ?? this.hydratedAlbums,
      pendingHydrationCount: clearPendingHydrationCount
          ? null
          : pendingHydrationCount ?? this.pendingHydrationCount,
      onlyIncompleteAlbumDetails:
          onlyIncompleteAlbumDetails ?? this.onlyIncompleteAlbumDetails,
      catalogPublishedThisRun:
          catalogPublishedThisRun ?? this.catalogPublishedThisRun,
      startedAt: startedAt ?? this.startedAt,
      completedAt: clearCompletedAt ? null : completedAt ?? this.completedAt,
      errorMessage: clearErrorMessage
          ? null
          : errorMessage ?? this.errorMessage,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      nextAutomaticCheckAt: clearNextAutomaticCheckAt
          ? null
          : nextAutomaticCheckAt ?? this.nextAutomaticCheckAt,
      nextRetryAt: clearNextRetryAt ? null : nextRetryAt ?? this.nextRetryAt,
      lastCatalogUpdatedAt: lastCatalogUpdatedAt ?? this.lastCatalogUpdatedAt,
      lastAuxiliarySyncedAt:
          lastAuxiliarySyncedAt ?? this.lastAuxiliarySyncedAt,
      starredSynchronized: starredSynchronized ?? this.starredSynchronized,
      playlistHeadersSynchronized:
          playlistHeadersSynchronized ?? this.playlistHeadersSynchronized,
      apiRequests: apiRequests ?? this.apiRequests,
      endpointRequests: endpointRequests ?? this.endpointRequests,
      apiRetries: apiRetries ?? this.apiRetries,
      apiFailures: apiFailures ?? this.apiFailures,
      averageLatencyMs: clearAverageLatencyMs
          ? null
          : averageLatencyMs ?? this.averageLatencyMs,
      dbWriteBatches: dbWriteBatches ?? this.dbWriteBatches,
      hydrationThroughputAlbumsPerSecond: clearHydrationThroughput
          ? null
          : hydrationThroughputAlbumsPerSecond ??
                this.hydrationThroughputAlbumsPerSecond,
      freshness: freshness ?? this.freshness,
      remainingVerificationCount:
          remainingVerificationCount ?? this.remainingVerificationCount,
      canonicalizedSongCount:
          canonicalizedSongCount ?? this.canonicalizedSongCount,
      ambiguousMatchCount: ambiguousMatchCount ?? this.ambiguousMatchCount,
      planKind: planKind ?? this.planKind,
      planReason: clearPlanReason ? null : planReason ?? this.planReason,
      pendingWorkCount: pendingWorkCount ?? this.pendingWorkCount,
      lastRunBytes: lastRunBytes ?? this.lastRunBytes,
      failureCategory: clearFailureCategory
          ? null
          : failureCategory ?? this.failureCategory,
      candidateGeneration: clearCandidateGeneration
          ? null
          : candidateGeneration ?? this.candidateGeneration,
      candidateStatus: clearCandidateStatus
          ? null
          : candidateStatus ?? this.candidateStatus,
      deletionCandidateCount:
          deletionCandidateCount ?? this.deletionCandidateCount,
      carriedForwardEntityCount:
          carriedForwardEntityCount ?? this.carriedForwardEntityCount,
      lastApplyDurationMs: lastApplyDurationMs ?? this.lastApplyDurationMs,
      probeIndexChanged: probeIndexChanged ?? this.probeIndexChanged,
      probeEvidenceVersion: probeEvidenceVersion ?? this.probeEvidenceVersion,
      probeIndexesUnsupported:
          probeIndexesUnsupported ?? this.probeIndexesUnsupported,
      probeDiscoveryDebtStreak:
          probeDiscoveryDebtStreak ?? this.probeDiscoveryDebtStreak,
      updatesAvailable: updatesAvailable ?? this.updatesAvailable,
    );
  }
}
