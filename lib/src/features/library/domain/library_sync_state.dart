import 'package:flutter/foundation.dart';

enum LibrarySyncStatus { idle, running, succeeded, skipped, failed }

enum LibrarySyncMode { fullInitial, incremental, forceFull }

enum LibrarySyncFreshness {
  current,
  verificationPending,
  repairRecommended,
}

enum LibrarySyncStage {
  idle,
  preparing,
  fetchingArtists,
  fetchingAlbums,
  persistingMetadata,
  fetchingSongs,
  fetchingGenres,
  fetchingPlaylists,
  finalizing,
  completed,
}

@immutable
class LibrarySyncState {
  const LibrarySyncState({
    required this.status,
    required this.stage,
    this.mode,
    this.metadataReady = false,
    this.isHydrating = false,
    this.fastPathActive = false,
    this.processed,
    this.total,
    this.hydratedAlbums,
    this.pendingHydrationCount,
    this.startedAt,
    this.completedAt,
    this.errorMessage,
    this.lastSyncedAt,
    this.apiRequests = 0,
    this.apiRetries = 0,
    this.apiFailures = 0,
    this.averageLatencyMs,
    this.dbWriteBatches = 0,
    this.hydrationThroughputAlbumsPerSecond,
    this.freshness = LibrarySyncFreshness.verificationPending,
    this.remainingVerificationCount = 0,
    this.canonicalizedSongCount = 0,
    this.ambiguousMatchCount = 0,
  });

  const LibrarySyncState.idle({
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
  final bool metadataReady;
  final bool isHydrating;
  final bool fastPathActive;
  final int? processed;
  final int? total;
  final int? hydratedAlbums;
  final int? pendingHydrationCount;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final String? errorMessage;
  final DateTime? lastSyncedAt;
  final int apiRequests;
  final int apiRetries;
  final int apiFailures;
  final int? averageLatencyMs;
  final int dbWriteBatches;
  final double? hydrationThroughputAlbumsPerSecond;
  final LibrarySyncFreshness freshness;
  final int remainingVerificationCount;
  final int canonicalizedSongCount;
  final int ambiguousMatchCount;

  bool get isRunning => status == LibrarySyncStatus.running;

  LibrarySyncState copyWith({
    LibrarySyncStatus? status,
    LibrarySyncStage? stage,
    LibrarySyncMode? mode,
    bool clearMode = false,
    bool? metadataReady,
    bool? isHydrating,
    bool? fastPathActive,
    int? processed,
    bool clearProcessed = false,
    int? total,
    bool clearTotal = false,
    int? hydratedAlbums,
    bool clearHydratedAlbums = false,
    int? pendingHydrationCount,
    bool clearPendingHydrationCount = false,
    DateTime? startedAt,
    bool clearStartedAt = false,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    String? errorMessage,
    bool clearErrorMessage = false,
    DateTime? lastSyncedAt,
    bool clearLastSyncedAt = false,
    int? apiRequests,
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
  }) {
    return LibrarySyncState(
      status: status ?? this.status,
      stage: stage ?? this.stage,
      mode: clearMode ? null : mode ?? this.mode,
      metadataReady: metadataReady ?? this.metadataReady,
      isHydrating: isHydrating ?? this.isHydrating,
      fastPathActive: fastPathActive ?? this.fastPathActive,
      processed: clearProcessed ? null : processed ?? this.processed,
      total: clearTotal ? null : total ?? this.total,
      hydratedAlbums: clearHydratedAlbums
          ? null
          : hydratedAlbums ?? this.hydratedAlbums,
      pendingHydrationCount: clearPendingHydrationCount
          ? null
          : pendingHydrationCount ?? this.pendingHydrationCount,
      startedAt: clearStartedAt ? null : startedAt ?? this.startedAt,
      completedAt: clearCompletedAt ? null : completedAt ?? this.completedAt,
      errorMessage: clearErrorMessage
          ? null
          : errorMessage ?? this.errorMessage,
      lastSyncedAt: clearLastSyncedAt
          ? null
          : lastSyncedAt ?? this.lastSyncedAt,
      apiRequests: apiRequests ?? this.apiRequests,
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
    );
  }
}
