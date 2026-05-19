import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:navis/src/api/lrclib_client.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/daos/cache_dao.dart';
import 'package:navis/src/database/daos/download_queue_dao.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart'
    show BaseCacheManager;
import 'package:navis/src/features/downloads/data/permanent_download_path_resolver.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/file_utils.dart';
import 'package:navis/src/utils/notifications/download_notifier.dart';
import 'package:path/path.dart' as p;

/// Maximum number of automatic retries before marking a download as failed.
const int maxRetries = 3;

typedef _RelocatedPermanentDownload = ({
  CachedTracksTableData entry,
  String storedFormat,
  String targetPath,
});

/// Orchestrates permanent downloads of tracks from a Subsonic server.
///
/// The service processes one download at a time, pulling the next pending item
/// from the download queue table and streaming it to disk via Dio.
///
/// Key design decisions:
/// * Downloads survive library sync — the `cached_tracks` table has no FK to
///   `songs`, so deleting + re-inserting songs during sync does not destroy
///   download records.
/// * Batch enqueue — `enqueueAlbum` / `enqueuePlaylist` collect all songIds,
///   dedup in-memory against a single batch DB query, then bulk-insert in one
///   transaction. This avoids the O(3n) sequential queries of the old design.
/// * Auto-retry with exponential backoff — failed downloads are retried up to
///   [maxRetries] times before being marked as permanently failed.
/// * All file I/O uses async methods (no `Sync` calls) to avoid blocking the
///   event loop.
class DownloadService {
  DownloadService({
    required AppSettingsDao appSettingsDao,
    required CacheDao cacheDao,
    required DownloadQueueDao downloadQueueDao,
    required LibraryDao libraryDao,
    required SubsonicApiClient? Function() readApiClient,
    required bool Function() readWifiOnly,
    required bool Function() readIsWifi,
    required bool Function() readCustomDownloadFolderEnabled,
    required String? Function() readCustomDownloadFolderPath,
    required LrclibClient lrclibClient,
    required BaseCacheManager Function() readCoverArtCacheManager,
    Future<Directory> Function()? readApplicationSupportDirectory,
    Dio? dio,
  }) : _appSettingsDao = appSettingsDao,
       _cacheDao = cacheDao,
       _downloadQueueDao = downloadQueueDao,
       _libraryDao = libraryDao,
       _readApiClient = readApiClient,
       _readWifiOnly = readWifiOnly,
       _readIsWifi = readIsWifi,
       _readCustomDownloadFolderEnabled = readCustomDownloadFolderEnabled,
       _readCustomDownloadFolderPath = readCustomDownloadFolderPath,
       _lrclibClient = lrclibClient,
       _readCoverArtCacheManager = readCoverArtCacheManager,
       _dio = dio ?? Dio(),
       _permanentPathResolver = PermanentDownloadPathResolver(
         readCustomDownloadFolderEnabled: readCustomDownloadFolderEnabled,
         readCustomDownloadFolderPath: readCustomDownloadFolderPath,
         readApplicationSupportDirectory: readApplicationSupportDirectory,
       );

  final AppSettingsDao _appSettingsDao;
  final CacheDao _cacheDao;
  final DownloadQueueDao _downloadQueueDao;
  final LibraryDao _libraryDao;
  final SubsonicApiClient? Function() _readApiClient;
  final bool Function() _readWifiOnly;
  final bool Function() _readIsWifi;
  final bool Function() _readCustomDownloadFolderEnabled;
  final String? Function() _readCustomDownloadFolderPath;
  final LrclibClient _lrclibClient;
  final BaseCacheManager Function() _readCoverArtCacheManager;
  final Dio _dio;
  final PermanentDownloadPathResolver _permanentPathResolver;

  StreamSubscription<List<DownloadQueueTableData>>? _queueSubscription;
  bool _processing = false;
  bool _maintenanceInProgress = false;
  CancelToken? _activeCancelToken;

  /// Start listening to the download queue and automatically process items.
  ///
  /// Recovers any items stuck in `downloading` status from a previous crash.
  Future<void> start() async {
    // Recover items left in 'downloading' from a previous app kill.
    await _downloadQueueDao.requeueStuckDownloads();

    // Best-effort cleanup of orphaned permanent files on startup.
    await _cleanupOrphanedFiles();

    // Normalize older hashed permanent downloads into the current folder layout.
    await _normalizePermanentDownloads();

    // Best-effort lyrics backfill for already-downloaded songs.
    unawaited(_backfillLyricsForDownloadedSongs());

    await _startQueueSubscription();
  }

  /// Stop the service and cancel any active download.
  Future<void> stop() async {
    await _queueSubscription?.cancel();
    _queueSubscription = null;
    _activeCancelToken?.cancel('Service stopped');
    _activeCancelToken = null;
    _processing = false;
  }

  Future<void> configureCustomDownloadFolder({
    required bool enabled,
    String? path,
  }) async {
    final normalizedPath = path?.trim();
    if (enabled && (normalizedPath == null || normalizedPath.isEmpty)) {
      throw FileSystemException(
        'A custom download folder path is required when enabling the feature.',
      );
    }

    await _runWithQueuePaused(() async {
      final targetDirectory = await _permanentDirectory(
        customDownloadFolderEnabled: enabled,
        customDownloadFolderPath: enabled ? normalizedPath : null,
      );
      await _relocatePermanentDownloads(
        targetDirectory: targetDirectory,
        customDownloadFolderEnabled: enabled,
        customDownloadFolderPath: enabled ? normalizedPath : null,
        rollbackOnFailure: true,
      );
      await _appSettingsDao.updateCustomDownloadFolderPath(
        enabled ? normalizedPath : null,
      );
      await _appSettingsDao.updateCustomDownloadFolderEnabled(enabled: enabled);
    });
  }

  Future<String> resolveActivePermanentDownloadPath() async {
    final directory = await _permanentDirectory();
    return directory.path;
  }

  Future<void> removeDownloadedTrack(String songId) async {
    final track = await _cacheDao.getCachedTrack(songId);
    if (track == null || track.cacheType != CacheType.permanent) {
      await _cacheDao.removeCachedTrack(songId);
      return;
    }
    final rootPath = await resolveActivePermanentDownloadPath();
    await deleteFileWithSuffixes(track.filePath);
    await pruneEmptyParentDirectories(
      startDirectoryPath: File(track.filePath).parent.path,
      stopAtDirectoryPath: rootPath,
    );
    await _cacheDao.removeCachedTrack(songId);
  }

  Future<void> removeDownloadedTracks(Iterable<String> songIds) async {
    final rootPath = await resolveActivePermanentDownloadPath();
    for (final songId in songIds) {
      final track = await _cacheDao.getCachedTrack(songId);
      if (track == null || track.cacheType != CacheType.permanent) {
        await _cacheDao.removeCachedTrack(songId);
        continue;
      }
      await deleteFileWithSuffixes(track.filePath);
      await pruneEmptyParentDirectories(
        startDirectoryPath: File(track.filePath).parent.path,
        stopAtDirectoryPath: rootPath,
      );
      await _cacheDao.removeCachedTrack(songId);
    }
  }

  Future<void> _startQueueSubscription() async {
    await _queueSubscription?.cancel();
    _queueSubscription = _downloadQueueDao.watchQueue().listen((_) {
      unawaited(_processNext());
    });
    unawaited(_processNext());
  }

  Future<T> _runWithQueuePaused<T>(Future<T> Function() action) async {
    if (_maintenanceInProgress) {
      throw StateError('Download maintenance is already in progress.');
    }
    _maintenanceInProgress = true;
    final hadSubscription = _queueSubscription != null;
    await _queueSubscription?.cancel();
    _queueSubscription = null;
    _activeCancelToken?.cancel('Download maintenance');
    await _waitForCurrentWorkToStop();
    try {
      return await action();
    } finally {
      _maintenanceInProgress = false;
      if (hadSubscription) {
        await _startQueueSubscription();
      }
    }
  }

  Future<void> _waitForCurrentWorkToStop() async {
    while (_processing || _activeCancelToken != null) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  // ---------------------------------------------------------------------------
  // Enqueue helpers
  // ---------------------------------------------------------------------------

  /// Enqueue a single song for permanent download.
  ///
  /// If the song is already in the rolling cache with a compatible quality,
  /// it is promoted to permanent storage instantly (no re-download needed).
  /// Skips if the song is already queued or downloading.
  /// When [forceRedownload] is true, re-downloads even if a permanent cache
  /// entry already exists (e.g., to upgrade to original quality).
  Future<void> enqueueSong(
    String songId, {
    String? albumId,
    String? playlistId,
    String? quality,
    String? format,
    int priority = 0,
    bool forceRedownload = false,
  }) async {
    final libraryRows = await _libraryDao.getSongsByIds(<String>[songId]);
    if (libraryRows.firstOrNull?.serverDeletedAt != null) {
      AppLogger.info(
        'DownloadService: Skipping local-only deleted song $songId.',
      );
      return;
    }
    // Dedup: skip if already queued or downloading.
    final existing = await _downloadQueueDao.findBySongId(songId);
    if (existing != null &&
        (existing.status == DownloadStatus.queued ||
            existing.status == DownloadStatus.downloading)) {
      return;
    }
    // Also skip if already permanently cached (unless force re-download).
    if (!forceRedownload) {
      final cached = await _cacheDao.getCachedTrack(songId);
      if (cached != null && cached.cacheType == CacheType.permanent) {
        return;
      }

      // Smart download: if the song is in rolling cache with a compatible
      // quality, promote it to permanent storage instead of re-downloading.
      if (cached != null && cached.cacheType == CacheType.rolling) {
        if (_isCacheQualityCompatible(cached, quality, format)) {
          final promoted = await promoteToPermanent(songId);
          if (promoted) {
            AppLogger.info(
              'DownloadService: Promoted rolling-cached track $songId '
              'to permanent (saved bandwidth).',
            );
            return;
          }
        }
      }
    }
    // Remove any stale failed entry before re-enqueueing.
    if (existing != null) {
      await _downloadQueueDao.remove(existing.id);
    }
    AppLogger.info(
      'DownloadService: Enqueuing song $songId '
      '(albumId=$albumId, quality=$quality, format=$format).',
    );
    await _downloadQueueDao.enqueue(
      DownloadQueueTableCompanion.insert(
        songId: Value(songId),
        albumId: Value(albumId),
        playlistId: Value(playlistId),
        quality: Value(quality),
        format: Value(format),
        status: DownloadStatus.queued,
        addedAt: DateTime.now(),
        priority: Value(priority),
      ),
    );
  }

  /// Enqueue all songs for an album using batch operations.
  ///
  /// Returns the number of songs newly queued. This method uses batch DB
  /// queries + a single bulk insert to avoid the O(3n) round-trip overhead
  /// of the old per-song approach.
  Future<int> enqueueAlbum(
    String albumId, {
    String? quality,
    String? format,
  }) async {
    final songs = await _libraryDao.watchSongsByAlbum(albumId).first;
    if (songs.isEmpty) return 0;

    AppLogger.info(
      'DownloadService: Enqueuing album $albumId '
      '(${songs.length} songs, quality=$quality, format=$format).',
    );
    final songIds = songs.map((s) => s.id).toList();
    return _batchEnqueue(
      songIds: songIds,
      albumId: albumId,
      quality: quality,
      format: format,
    );
  }

  /// Enqueue all songs for a playlist using batch operations.
  ///
  /// Returns the number of songs newly queued.
  Future<int> enqueuePlaylist(
    String playlistId,
    List<String> songIds, {
    String? quality,
    String? format,
  }) async {
    if (songIds.isEmpty) return 0;
    return _batchEnqueue(
      songIds: songIds,
      playlistId: playlistId,
      quality: quality,
      format: format,
    );
  }

  /// Core batch enqueue logic shared by [enqueueAlbum] and [enqueuePlaylist].
  ///
  /// 1. Batch-fetch existing queue entries + cache entries (2 queries).
  /// 2. Filter out songs already queued/downloading or permanently cached.
  /// 3. Attempt rolling→permanent promotion for compatible cached songs.
  /// 4. Bulk-insert remaining songs in a single transaction.
  Future<int> _batchEnqueue({
    required List<String> songIds,
    String? albumId,
    String? playlistId,
    String? quality,
    String? format,
  }) async {
    // Batch dedup: one query per data source instead of N queries per song.
    final activeSongIds = await _downloadQueueDao.getActiveSongIds();
    final cacheTypes = await _cacheDao.getCacheTypesForSongIds(songIds);

    final toEnqueue = <DownloadQueueTableCompanion>[];
    var promotedCount = 0;

    for (final songId in songIds) {
      // Skip if already queued or downloading.
      if (activeSongIds.contains(songId)) continue;

      // Skip if already permanently cached.
      final cacheType = cacheTypes[songId];
      if (cacheType == CacheType.permanent) continue;

      // Try rolling → permanent promotion.
      if (cacheType == CacheType.rolling) {
        final cached = await _cacheDao.getCachedTrack(songId);
        if (cached != null &&
            _isCacheQualityCompatible(cached, quality, format)) {
          final promoted = await promoteToPermanent(songId);
          if (promoted) {
            promotedCount++;
            continue;
          }
        }
      }

      toEnqueue.add(
        DownloadQueueTableCompanion.insert(
          songId: Value(songId),
          albumId: Value(albumId),
          playlistId: Value(playlistId),
          quality: Value(quality),
          format: Value(format),
          status: DownloadStatus.queued,
          addedAt: DateTime.now(),
        ),
      );
    }

    if (toEnqueue.isNotEmpty) {
      await _downloadQueueDao.enqueueBatch(toEnqueue);
    }

    if (promotedCount > 0) {
      AppLogger.info(
        'DownloadService: Promoted $promotedCount rolling-cached tracks '
        'to permanent (saved bandwidth).',
      );
    }
    return toEnqueue.length;
  }

  /// Promote a rolling-cache track to permanent (no re-download needed).
  Future<bool> promoteToPermanent(String songId) async {
    final track = await _cacheDao.getCachedTrack(songId);
    if (track == null) return false;
    if (track.cacheType == CacheType.permanent) return true;

    final file = File(track.filePath);
    if (!await file.exists()) return false;

    final song = (await _libraryDao.getSongsByIds(<String>[
      songId,
    ])).firstOrNull;
    final newPath = await _resolvePermanentPathForEntry(
      songId: songId,
      song: song,
      format: _resolveStoredFormat(track, song: song),
    );
    final destination = File(newPath);
    try {
      await Directory(p.dirname(newPath)).create(recursive: true);
      if (!await destination.exists()) {
        await file.copy(newPath);
      }
    } on FileSystemException catch (e) {
      AppLogger.warning(
        'DownloadService: Failed to copy to permanent: $e',
      );
      return false;
    }
    // Clean up rolling cache files.
    await deleteFileWithSuffixes(track.filePath);

    await _cacheDao.upsertCachedTrack(
      CachedTracksTableCompanion.insert(
        songId: songId,
        filePath: newPath,
        fileSize: track.fileSize,
        format: track.format,
        bitRate: track.bitRate == null
            ? const Value.absent()
            : Value(track.bitRate),
        cacheType: CacheType.permanent,
        downloadStatus: DownloadStatus.complete,
        lastAccessedAt: DateTime.now(),
      ),
    );
    return true;
  }

  /// Returns `true` if the rolling-cached track's quality is compatible with
  /// the requested download quality, meaning we can promote instead of
  /// re-downloading.
  ///
  /// Rules:
  /// * If both quality and format are null (original), a cached track with no
  ///   bitrate/format restriction (also original) is compatible.
  /// * If a specific format is requested and matches the cached format, we
  ///   further check bitrate: if the cached bitrate is null (original) or ≥
  ///   the requested bitrate, the cache is at least as good.
  /// * If no specific quality/format is requested (original download) the
  ///   cached entry is compatible when it was also cached at original quality
  ///   (null bitrate).
  bool _isCacheQualityCompatible(
    CachedTracksTableData cached,
    String? requestedQuality,
    String? requestedFormat,
  ) {
    final requestedBitRate = requestedQuality != null
        ? int.tryParse(requestedQuality)
        : null;

    // User wants "original" quality (no transcoding).
    if (requestedBitRate == null && requestedFormat == null) {
      // Only compatible if the cache is also original (no forced bitrate).
      return cached.bitRate == null;
    }

    // Check format compatibility.
    if (requestedFormat != null &&
        cached.format.toLowerCase() != requestedFormat.toLowerCase()) {
      return false;
    }

    // Check bitrate: cached must be ≥ requested (or original).
    if (requestedBitRate != null) {
      if (cached.bitRate == null) {
        // Cached at original quality — always ≥ any transcoded bitrate.
        return true;
      }
      return cached.bitRate! >= requestedBitRate;
    }

    return true;
  }

  // ---------------------------------------------------------------------------
  // Processing
  // ---------------------------------------------------------------------------

  Future<void> _processNext() async {
    if (_processing || _maintenanceInProgress) return;

    // Respect Wi-Fi-only setting.
    if (_readWifiOnly() && !_readIsWifi()) {
      AppLogger.debug('DownloadService: Wi-Fi-only mode, skipping processing');
      return;
    }

    _processing = true;

    try {
      while (true) {
        final queue = await _downloadQueueDao.getQueuedItems();
        if (queue.isEmpty) break;

        final item = queue.first;
        if (item.songId == null) {
          // Malformed entry — remove.
          await _downloadQueueDao.remove(item.id);
          continue;
        }
        await _downloadItem(item);

        // Yield to the event loop between downloads so the UI stays
        // responsive and other microtasks can run.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      _processing = false;
    }
  }

  Future<void> _downloadItem(DownloadQueueTableData item) async {
    final songId = item.songId!;
    final api = _readApiClient();
    if (api == null) {
      AppLogger.warning('DownloadService: No API client, skipping $songId');
      await _handleFailure(item, 'No API client');
      return;
    }

    // Mark as downloading.
    await _downloadQueueDao.updateStatus(item.id, DownloadStatus.downloading);

    // Resolve destination file early so we can clean up on failure.
    File? destFile;

    try {
      // Resolve download URL.
      final downloadUri = _resolveDownloadUri(
        api: api,
        songId: songId,
        quality: item.quality,
        format: item.format,
      );

      // Resolve destination file.
      final songs = await _libraryDao.getSongsByIds(<String>[songId]);
      if (songs.isEmpty || songs.first.serverDeletedAt != null) {
        AppLogger.warning(
          'DownloadService: Removing stale queue item for unavailable song $songId',
        );
        await _downloadQueueDao.remove(item.id);
        return;
      }
      final song = songs.first;
      final songTitle = song.title;
      destFile = await _resolveDownloadFile(song, item);

      _activeCancelToken = CancelToken();
      final response = await _dio.downloadUri(
        downloadUri,
        destFile.path,
        cancelToken: _activeCancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            final progress = (received / total).clamp(0.0, 1.0);
            _downloadQueueDao.updateProgress(item.id, progress);
            unawaited(
              DownloadNotifier.showProgress(
                title: songTitle,
                received: received,
                total: total,
              ),
            );
          }
        },
      );

      if (response.statusCode != null &&
          response.statusCode! >= 200 &&
          response.statusCode! < 300) {
        // Register in cached_tracks as permanent.
        final stat = await destFile.stat();
        final format = _resolveFormat(song, item);

        await _cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: songId,
            filePath: destFile.path,
            fileSize: stat.size,
            format: format,
            bitRate: song.bitRate == null
                ? const Value.absent()
                : Value(song.bitRate),
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );

        // Remove from queue.
        await _downloadQueueDao.remove(item.id);

        // Pre-cache cover art alongside the audio file (best-effort).
        final coverArtId = song.coverArt;
        if (coverArtId != null && coverArtId.isNotEmpty) {
          final artUrl = api
              .getCoverArtUrl(id: coverArtId, size: 300)
              .toString();
          unawaited(
            _readCoverArtCacheManager()
                .downloadFile(
                  artUrl,
                  key: coverArtImageCacheKey(coverArtId, 300),
                )
                .then((_) {})
                .catchError((_) {}),
          );
        }

        unawaited(DownloadNotifier.dismissProgress().catchError((_) {}));
        unawaited(
          DownloadNotifier.showComplete(
            title: 'Downloaded: $songTitle',
          ).catchError((_) {}),
        );

        // Best-effort: pre-fetch lyrics so they're available offline.
        unawaited(_prefetchLyrics(songId, song, api));

        AppLogger.info(
          'DownloadService: Completed download for $songId '
          '(${stat.size} bytes)',
        );
      } else {
        await tryDeleteFile(destFile);
        // 404 Not Found / 410 Gone — resource is permanently unavailable, no point retrying.
        if (response.statusCode == 404 || response.statusCode == 410) {
          AppLogger.warning(
            'DownloadService: Source not found (${response.statusCode}) for $songId — marking as permanently failed',
          );
          await _downloadQueueDao.updateStatus(item.id, DownloadStatus.failed);
          await DownloadNotifier.showFailed(
            title: 'Download failed: $songId',
          ).catchError((_) {});
        } else {
          await _handleFailure(
            item,
            'HTTP ${response.statusCode}',
          );
        }
      }
    } on DioException catch (e) {
      await DownloadNotifier.dismissProgress().catchError((_) {});
      if (e.type == DioExceptionType.cancel) {
        AppLogger.debug('DownloadService: Download cancelled for $songId');
        await tryDeleteFile(destFile);
        await _downloadQueueDao.updateStatus(item.id, DownloadStatus.queued);
      } else {
        AppLogger.warning('DownloadService: Dio error for $songId: $e');
        await tryDeleteFile(destFile);
        await _handleFailure(item, e.toString());
      }
    } on Object catch (e, st) {
      AppLogger.warning('DownloadService: Error for $songId: $e\n$st');
      await tryDeleteFile(destFile);
      await _handleFailure(item, e.toString());
    } finally {
      _activeCancelToken = null;
    }
  }

  /// Handle a download failure with automatic retry logic.
  ///
  /// If the item has been retried fewer than [maxRetries] times, it is
  /// re-queued with an incremented retry count and a backoff delay.
  /// Otherwise it is marked as permanently [DownloadStatus.failed].
  Future<void> _handleFailure(
    DownloadQueueTableData item,
    String reason,
  ) async {
    await DownloadNotifier.dismissProgress().catchError((_) {});

    if (item.retryCount < maxRetries) {
      // Exponential backoff: 5s, 10s, 20s, ...
      final backoff = Duration(seconds: 5 * (1 << item.retryCount));
      AppLogger.info(
        'DownloadService: Retrying ${item.songId} '
        '(attempt ${item.retryCount + 1}/$maxRetries) '
        'after ${backoff.inSeconds}s',
      );
      await _downloadQueueDao.markForRetry(item.id);

      // Schedule a delayed re-trigger. The queue subscription would
      // eventually pick it up, but the backoff delay adds some spacing.
      Future<void>.delayed(backoff, () {
        unawaited(_processNext());
      });
    } else {
      await _downloadQueueDao.updateStatus(item.id, DownloadStatus.failed);
      await DownloadNotifier.showFailed(
        title: 'Download failed: ${item.songId}',
      ).catchError((_) {});
      AppLogger.warning(
        'DownloadService: Permanently failed ${item.songId}: $reason',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Orphaned file cleanup
  // ---------------------------------------------------------------------------

  /// Scan the permanent download directory for files not referenced in the
  /// `cached_tracks` table and delete them.
  ///
  /// This recovers disk space from files orphaned by the old CASCADE FK
  /// behavior (where sync would delete the DB record but leave the file).
  Future<void> _cleanupOrphanedFiles() async {
    try {
      final permDir = await _permanentDirectory();
      if (!await permDir.exists()) return;

      final knownEntries = await _cacheDao.getPermanentEntries();
      final knownPaths = knownEntries.map((e) => e.filePath).toSet();

      await for (final entity in permDir.list(recursive: true)) {
        if (entity is! File) {
          continue;
        }
        final path = entity.path;
        final basePath = path.endsWith('.mime')
            ? path.substring(0, path.length - '.mime'.length)
            : path;
        if (!knownPaths.contains(basePath)) {
          AppLogger.info(
            'DownloadService: Removing orphaned file $path',
          );
          await deleteFileWithSuffixes(basePath);
        }
      }
    } on Object catch (e) {
      // Best-effort — don't crash the service on cleanup failure.
      AppLogger.warning(
        'DownloadService: Orphaned file cleanup error: $e',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Lyrics backfill
  // ---------------------------------------------------------------------------

  /// On app boot, scan all permanently-downloaded tracks and fetch lyrics for
  /// any that do not yet have a cached entry.
  ///
  /// Runs fire-and-forget from [start]. Respects the wifi-only setting, skips
  /// songs that already have lyrics, and throttles requests to avoid hammering
  /// the server or LrcLib. Never throws.
  Future<void> _backfillLyricsForDownloadedSongs() async {
    try {
      if (_readWifiOnly() && !_readIsWifi()) {
        AppLogger.debug(
          'DownloadService: Lyrics backfill skipped — wifi-only and not on wifi.',
        );
        return;
      }

      final api = _readApiClient();
      if (api == null) {
        AppLogger.debug(
          'DownloadService: Lyrics backfill skipped — no active API client.',
        );
        return;
      }

      final permanentIds = await _cacheDao.getPermanentlyCachedSongIds();
      if (permanentIds.isEmpty) return;

      final songs = await _libraryDao.getSongsByIds(permanentIds);
      if (songs.isEmpty) return;

      AppLogger.info(
        'DownloadService: Lyrics backfill — checking ${songs.length} downloaded songs.',
      );

      for (final song in songs) {
        final existing = await _libraryDao.getExternalLyricsCache(song.id);
        if (existing != null && existing.syncedLyrics != null) {
          // Already have synced lyrics — best possible quality, nothing to do.
          continue;
        }
        // Songs with only plain lyrics are still processed to try to upgrade
        // to synced lyrics.

        await _prefetchLyrics(song.id, song, api);

        // Throttle to avoid hammering the server or LrcLib.
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      AppLogger.info('DownloadService: Lyrics backfill complete.');
    } catch (e) {
      AppLogger.warning('DownloadService: Lyrics backfill error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Lyrics prefetch
  // ---------------------------------------------------------------------------

  /// Best-effort: fetch and persist lyrics for a downloaded song so they are
  /// available offline. Never throws — a failure here must not fail the
  /// download itself.
  Future<void> _prefetchLyrics(
    String songId,
    SongsTableData song,
    SubsonicApiClient api,
  ) async {
    try {
      // Skip only if synced lyrics are already cached — best possible quality.
      final existing = await _libraryDao.getExternalLyricsCache(songId);
      if (existing != null && existing.syncedLyrics != null) {
        AppLogger.debug(
          'DownloadService: Synced lyrics already cached for $songId, skipping.',
        );
        return;
      }
      // If only plain lyrics exist, continue and try to upgrade to synced.
      final hasOnlyPlain = existing != null && existing.plainLyrics != null;

      // 1. Try server synced lyrics (OpenSubsonic getLyricsBySongId).
      try {
        final serverLyrics = await api.getLyricsBySongId(songId);
        final synced = serverLyrics.structuredLyrics
            .where((s) => s.synced == true && s.line.isNotEmpty)
            .firstOrNull;
        final unsynced = synced == null
            ? serverLyrics.structuredLyrics
                  .where((s) => s.synced == false && s.line.isNotEmpty)
                  .firstOrNull
            : null;

        if (synced != null) {
          await _libraryDao.upsertExternalLyricsCache(
            songId: songId,
            source: 'serverSynced',
            syncedLyrics: _structuredLyricsToLrc(synced.line),
            ttlSeconds: 30 * 24 * 3600, // 30 days for downloaded tracks
          );
          AppLogger.info(
            'DownloadService: Cached server synced lyrics for $songId',
          );
          return;
        }

        // Only store plain lyrics if we don't already have them.
        if (unsynced != null && !hasOnlyPlain) {
          final plainText = unsynced.line.map((l) => l.value ?? '').join('\n');
          if (plainText.trim().isNotEmpty) {
            await _libraryDao.upsertExternalLyricsCache(
              songId: songId,
              source: 'serverPlain',
              plainLyrics: plainText,
              ttlSeconds: 30 * 24 * 3600,
            );
            AppLogger.info(
              'DownloadService: Cached server plain lyrics for $songId',
            );
            return;
          }
        }

        // getLyricsBySongId succeeded but returned no usable lyrics — fall
        // through to legacy getLyrics.
      } on SubsonicNotFoundException {
        // Server doesn't have lyrics for this song — continue.
      } on SubsonicApiException {
        // Server error — continue to lrclib fallback.
      } on SubsonicConnectionException {
        // Offline — skip server entirely, try lrclib.
      }

      // 2. Try legacy getLyrics endpoint (plain text only — skip if we already
      // have plain lyrics and are only looking for an upgrade to synced).
      if (!hasOnlyPlain && song.artistName != null && song.title.isNotEmpty) {
        try {
          final legacy = await api.getLyrics(
            artist: song.artistName,
            title: song.title,
          );
          final plain = legacy.value;
          if (plain != null && plain.trim().isNotEmpty) {
            await _libraryDao.upsertExternalLyricsCache(
              songId: songId,
              source: 'serverPlain',
              plainLyrics: plain,
              ttlSeconds: 30 * 24 * 3600,
            );
            AppLogger.info(
              'DownloadService: Cached legacy server lyrics for $songId',
            );
            return;
          }
        } on SubsonicException {
          // Continue to lrclib.
        }
      }

      // 3. Fall back to LRCLIB.
      if (song.artistName == null ||
          song.artistName!.isEmpty ||
          song.title.isEmpty) {
        return;
      }
      final lrclibResult = await _lrclibClient.getLyrics(
        artist: song.artistName!,
        title: song.title,
        album: song.albumName,
        duration: song.duration,
      );
      if (lrclibResult == null) return;

      // Only store a plain LrcLib result if we don't already have plain lyrics;
      // always store if LrcLib found synced lyrics.
      if (!lrclibResult.hasSynced && hasOnlyPlain) {
        AppLogger.debug(
          'DownloadService: LrcLib plain lyrics for $songId already covered, skipping.',
        );
        return;
      }

      await _libraryDao.upsertExternalLyricsCache(
        songId: songId,
        source: lrclibResult.hasSynced ? 'lrclibSynced' : 'lrclibPlain',
        syncedLyrics: lrclibResult.syncedLyrics,
        plainLyrics: lrclibResult.plainLyrics,
        ttlSeconds: 30 * 24 * 3600,
      );
      AppLogger.info(
        'DownloadService: Cached LRCLIB lyrics for $songId '
        '(synced=${lrclibResult.hasSynced})',
      );
    } on Object catch (e) {
      // Never let a lyrics error abort or surface through the download flow.
      AppLogger.warning(
        'DownloadService: Lyrics prefetch failed for $songId: $e',
      );
    }
  }

  /// Serialises a list of [LyricLine]s into LRC format.
  ///
  /// Example output line: `[02:15.30] Some lyrics text`
  static String _structuredLyricsToLrc(List<LyricLine> lines) {
    final buf = StringBuffer();
    for (final line in lines) {
      final ms = line.start ?? 0;
      final mins = ms ~/ 60000;
      final secs = (ms % 60000) ~/ 1000;
      final cents = (ms % 1000) ~/ 10;
      final timestamp =
          '${mins.toString().padLeft(2, '0')}'
          ':${secs.toString().padLeft(2, '0')}'
          '.${cents.toString().padLeft(2, '0')}';
      buf.writeln('[$timestamp]${line.value ?? ''}');
    }
    return buf.toString().trimRight();
  }

  Future<void> _normalizePermanentDownloads() async {
    try {
      final targetDirectory = await _permanentDirectory();
      await _relocatePermanentDownloads(
        targetDirectory: targetDirectory,
        customDownloadFolderEnabled: _readCustomDownloadFolderEnabled(),
        customDownloadFolderPath: _readCustomDownloadFolderPath(),
      );
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'DownloadService: Permanent download normalization failed: '
        '$error\n$stackTrace',
      );
    }
  }

  Future<void> _relocatePermanentDownloads({
    required Directory targetDirectory,
    required bool customDownloadFolderEnabled,
    required String? customDownloadFolderPath,
    bool rollbackOnFailure = false,
  }) async {
    final currentRootDirectory = await _permanentDirectory(
      customDownloadFolderEnabled: _readCustomDownloadFolderEnabled(),
      customDownloadFolderPath: _readCustomDownloadFolderPath(),
    );
    final entries = await _cacheDao.getPermanentEntries();
    if (entries.isEmpty) {
      return;
    }

    final songs = await _libraryDao.getSongsByIds(
      entries.map((entry) => entry.songId).toSet(),
    );
    final songsById = <String, SongsTableData>{
      for (final song in songs) song.id: song,
    };
    final reservedTargetPaths = <String>{};
    final movedEntries = <_RelocatedPermanentDownload>[];

    try {
      for (final entry in entries) {
        final sourceFile = File(entry.filePath);
        if (!await sourceFile.exists()) {
          AppLogger.warning(
            'DownloadService: Skipping permanent relocation for ${entry.songId} '
            'because the file is missing: ${entry.filePath}',
          );
          continue;
        }

        final song = songsById[entry.songId];
        final storedFormat = _resolveStoredFormat(entry, song: song);
        final targetPath = await _resolvePermanentPathForEntry(
          songId: entry.songId,
          song: song,
          format: storedFormat,
          existingPath: entry.filePath,
          reservedPaths: reservedTargetPaths,
          customDownloadFolderEnabled: customDownloadFolderEnabled,
          customDownloadFolderPath: customDownloadFolderPath,
        );
        reservedTargetPaths.add(targetPath);
        if (p.equals(entry.filePath, targetPath)) {
          continue;
        }

        final previousParent = File(entry.filePath).parent;
        await _movePermanentFileSet(entry.filePath, targetPath);
        await _cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: entry.songId,
            filePath: targetPath,
            fileSize: entry.fileSize,
            format: storedFormat,
            bitRate: entry.bitRate == null
                ? const Value.absent()
                : Value(entry.bitRate),
            cacheType: CacheType.permanent,
            downloadStatus: entry.downloadStatus,
            lastAccessedAt: DateTime.now(),
          ),
        );
        movedEntries.add((
          entry: entry,
          storedFormat: storedFormat,
          targetPath: targetPath,
        ));
        await _deleteEmptyDirectoriesUpwards(
          startDirectory: previousParent,
          stopAtDirectory: currentRootDirectory.path,
        );
      }
    } on Object {
      if (rollbackOnFailure) {
        await _rollbackRelocatedPermanentDownloads(
          movedEntries,
          currentRootDirectoryPath: currentRootDirectory.path,
          targetRootDirectoryPath: targetDirectory.path,
        );
      }
      rethrow;
    }
  }

  Future<void> _rollbackRelocatedPermanentDownloads(
    List<_RelocatedPermanentDownload> movedEntries, {
    required String currentRootDirectoryPath,
    required String targetRootDirectoryPath,
  }) async {
    for (final moved in movedEntries.reversed) {
      await _movePermanentFileSet(moved.targetPath, moved.entry.filePath);
      await _cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: moved.entry.songId,
          filePath: moved.entry.filePath,
          fileSize: moved.entry.fileSize,
          format: moved.storedFormat,
          bitRate: moved.entry.bitRate == null
              ? const Value.absent()
              : Value(moved.entry.bitRate),
          cacheType: CacheType.permanent,
          downloadStatus: moved.entry.downloadStatus,
          lastAccessedAt: moved.entry.lastAccessedAt,
        ),
      );
      await _deleteEmptyDirectoriesUpwards(
        startDirectory: File(moved.targetPath).parent,
        stopAtDirectory: targetRootDirectoryPath,
      );
      await _deleteEmptyDirectoriesUpwards(
        startDirectory: File(moved.entry.filePath).parent,
        stopAtDirectory: currentRootDirectoryPath,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // File utilities
  // ---------------------------------------------------------------------------

  Future<String> _resolvePermanentPathForEntry({
    required String songId,
    required String format,
    SongsTableData? song,
    String? existingPath,
    Set<String> reservedPaths = const <String>{},
    bool? customDownloadFolderEnabled,
    String? customDownloadFolderPath,
  }) async {
    if (song != null) {
      return _permanentPathResolver.resolveSongPath(
        song: song,
        extension: format,
        existingPath: existingPath,
        reservedPaths: reservedPaths,
        customDownloadFolderEnabled: customDownloadFolderEnabled,
        customDownloadFolderPath: customDownloadFolderPath,
      );
    }

    final rootDirectory = await _permanentDirectory(
      customDownloadFolderEnabled: customDownloadFolderEnabled,
      customDownloadFolderPath: customDownloadFolderPath,
    );
    final artistDirectory = PermanentDownloadPathResolver.sanitizePathComponent(
      null,
      fallback: PermanentDownloadPathResolver.unknownArtistDirectory,
    );
    final fileStem = PermanentDownloadPathResolver.sanitizePathComponent(
      p.basenameWithoutExtension(existingPath ?? songId),
      fallback: songId,
    );
    final extension = format.trim().replaceFirst('.', '');
    final basePath = p.join(
      rootDirectory.path,
      artistDirectory,
      '$fileStem.${extension.isEmpty ? 'bin' : extension}',
    );
    if (existingPath != null && p.equals(basePath, existingPath)) {
      return basePath;
    }
    if (!reservedPaths.contains(basePath) && !File(basePath).existsSync()) {
      return basePath;
    }
    final suffix = sha1.convert(utf8.encode(songId)).toString().substring(0, 8);
    return p.join(
      rootDirectory.path,
      artistDirectory,
      '$fileStem [$suffix].${extension.isEmpty ? 'bin' : extension}',
    );
  }

  String _resolveStoredFormat(
    CachedTracksTableData track, {
    SongsTableData? song,
  }) {
    final stored = track.format.trim();
    if (stored.isNotEmpty) {
      return stored;
    }
    final suffix = song?.suffix?.trim();
    if (suffix != null && suffix.isNotEmpty) {
      return suffix;
    }
    final ext = p.extension(track.filePath).replaceFirst('.', '').trim();
    return ext.isEmpty ? 'bin' : ext;
  }

  Future<void> _movePermanentFileSet(
    String sourcePath,
    String targetPath,
  ) async {
    await Directory(p.dirname(targetPath)).create(recursive: true);
    await _moveFile(File(sourcePath), File(targetPath));
    await _moveFile(
      File('$sourcePath.mime'),
      File('$targetPath.mime'),
      missingIsOk: true,
    );
  }

  Future<void> _moveFile(
    File source,
    File destination, {
    bool missingIsOk = false,
  }) async {
    if (!await source.exists()) {
      if (missingIsOk) {
        return;
      }
      throw FileSystemException(
        'Source file does not exist.',
        source.path,
      );
    }

    if (await destination.exists()) {
      await destination.delete();
    }

    try {
      await source.rename(destination.path);
    } on FileSystemException {
      await source.copy(destination.path);
      await source.delete();
    }
  }

  Future<void> _deleteEmptyDirectoriesUpwards({
    required Directory startDirectory,
    required String stopAtDirectory,
  }) async {
    final stopAt = p.normalize(stopAtDirectory);
    var current = startDirectory;
    while (true) {
      final currentPath = p.normalize(current.path);
      if (currentPath == stopAt) {
        return;
      }
      final entries = await current.list().toList();
      if (entries.isNotEmpty) {
        return;
      }
      await current.delete();
      final parent = current.parent;
      if (p.normalize(parent.path) == currentPath) {
        return;
      }
      current = parent;
    }
  }

  Future<Directory> _permanentDirectory({
    bool? customDownloadFolderEnabled,
    String? customDownloadFolderPath,
  }) {
    return _permanentPathResolver.resolveRootFor(
      customDownloadFolderEnabled:
          customDownloadFolderEnabled ?? _readCustomDownloadFolderEnabled(),
      customDownloadFolderPath:
          customDownloadFolderPath ?? _readCustomDownloadFolderPath(),
    );
  }

  Future<File> _resolveDownloadFile(
    SongsTableData song,
    DownloadQueueTableData item,
  ) async {
    final ext = _resolveFormat(song, item);
    final targetPath = await _permanentPathResolver.resolveSongPath(
      song: song,
      extension: ext,
    );
    return File(targetPath);
  }

  Uri _resolveDownloadUri({
    required SubsonicApiClient api,
    required String songId,
    String? quality,
    String? format,
  }) {
    // If no quality/format specified, use download.view (original quality).
    if (quality == null && format == null) {
      return api.downloadUrl(id: songId);
    }
    // Otherwise use stream.view with transcoding params.
    final maxBitRate = quality != null ? int.tryParse(quality) : null;
    return api.streamUrl(
      id: songId,
      maxBitRate: maxBitRate,
      format: format,
    );
  }

  /// Resolve the file format/extension for a download item.
  String _resolveFormat(SongsTableData song, DownloadQueueTableData item) {
    if (item.format != null && item.format!.trim().isNotEmpty) {
      return item.format!.trim();
    }
    final suffix = song.suffix?.trim();
    if (suffix != null && suffix.isNotEmpty) return suffix;
    return 'bin';
  }
}
