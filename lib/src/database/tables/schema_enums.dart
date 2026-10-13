enum CacheType { rolling, permanent }

/// Typed catalog availability for songs, albums, and artists.
///
/// Null (legacy rows) reads as [present]. [suspectedMissing] follows an
/// isolated fetch failure; only validated catalog evidence proves
/// [confirmedMissing]. Transport, authentication, rate-limit, and decoding
/// failures must never advance availability toward missing.
/// [pendingRebuild] keeps reset references outside the catalog until sync
/// reconfirms their presence or absence.
enum CatalogAvailability {
  present,
  suspectedMissing,
  confirmedMissing,
  pendingRebuild,
}

/// Stable reason codes persisted with failed permanent downloads.
enum DownloadFailureReason {
  notFound,
  serverError,
  network,
  timeout,
  notAudio,
  truncated,
  noSpace,
  folderUnavailable,
  permission,
  unknown,
}

enum DownloadStatus { queued, downloading, paused, complete, failed }

enum ShuffleMode { off, all }

enum RepeatMode { off, one, all }
