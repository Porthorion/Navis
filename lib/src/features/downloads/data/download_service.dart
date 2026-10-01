import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:drift/drift.dart';
import 'package:navis/src/api/lrclib_client.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/daos/cache_dao.dart';
import 'package:navis/src/database/daos/download_queue_dao.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart'
    show BaseCacheManager;
import 'package:navis/src/features/downloads/data/download_path_identity.dart';
import 'package:navis/src/features/downloads/data/permanent_download_path_resolver.dart';
import 'package:navis/src/features/downloads/data/permanent_download_import_service.dart';
import 'package:navis/src/features/downloads/data/android_saf_storage.dart';
import 'package:navis/src/features/player/data/lyrics_resolver.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/file_utils.dart';
import 'package:navis/src/utils/network_usage_meter.dart';
import 'package:navis/src/utils/notifications/download_notifier.dart';
import 'package:path/path.dart' as p;

/// Maximum number of automatic retries before marking a download as failed.
const int maxRetries = 3;

typedef _RelocatedPermanentDownload = ({
  CachedTracksTableData entry,
  String storedFormat,
  String targetPath,
  bool sourceWasSaf,
});

typedef _SafRelocatedPermanentDownload = ({
  CachedTracksTableData entry,
  String locator,
  String format,
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
  new({
    required this._appSettingsDao,
    required CacheDao cacheDao,
    required this._downloadQueueDao,
    required LibraryDao libraryDao,
    required this._readApiClient,
    required this._readWifiOnly,
    required this._readIsWifi,
    required bool Function() readCustomDownloadFolderEnabled,
    required String? Function() readCustomDownloadFolderPath,
    required this._lrclibClient,
    required this._readCoverArtCacheManager,
    String? Function()? readProfileIdentity,
    this._reportNetworkUsage,
    Future<Directory> Function()? readApplicationSupportDirectory,
    Dio? dio,
  }) : _cacheDao = cacheDao,
       _libraryDao = libraryDao,
       _readCustomDownloadFolderEnabled = readCustomDownloadFolderEnabled,
       _readCustomDownloadFolderPath = readCustomDownloadFolderPath,
       _dio = dio ?? Dio(),
       _permanentPathResolver = PermanentDownloadPathResolver(
         readCustomDownloadFolderEnabled: readCustomDownloadFolderEnabled,
         readCustomDownloadFolderPath: readCustomDownloadFolderPath,
         readApplicationSupportDirectory: readApplicationSupportDirectory,
       ),
       _permanentDownloadImportService = PermanentDownloadImportService(
         cacheDao: cacheDao,
         libraryDao: libraryDao,
         readProfileIdentity: readProfileIdentity ?? (() => null),
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
  final NetworkUsageReporter? _reportNetworkUsage;
  final Dio _dio;
  final PermanentDownloadPathResolver _permanentPathResolver;
  final PermanentDownloadImportService _permanentDownloadImportService;
  final AndroidSafStorage _safStorage = const AndroidSafStorage();

  StreamSubscription<List<DownloadQueueTableData>>? _queueSubscription;
  bool _processing = false;
  bool _maintenanceInProgress = false;
  bool _stopped = false;
  CancelToken? _activeCancelToken;
  Future<void>? _startInFlight;
  final Set<Future<void>> _backgroundTasks = <Future<void>>{};
  final Set<Future<void>> _pendingProgressWrites = <Future<void>>{};

  /// Start listening to the download queue and automatically process items.
  ///
  /// Recovers any items stuck in `downloading` status from a previous crash.
  Future<void> start() {
    return _startInFlight ??= _start().whenComplete(() {
      _startInFlight = null;
    });
  }

  Future<void> _start() async {
    _stopped = false;
    await _migrateUnsafeAndroidCustomFolder();
    // Recover items left in 'downloading' from a previous app kill.
    final interrupted = await _downloadQueueDao.requeueStuckDownloads();
    if (interrupted > 0) await _removePartialDownloads();

    // A custom root belongs to the user. Files not present in Navis's local
    // database may be import candidates and must never be deleted implicitly.
    if (!_readCustomDownloadFolderEnabled()) {
      await _cleanupOrphanedFiles();
    }

    // Normalize older hashed permanent downloads into the current folder layout.
    await _normalizePermanentDownloads();

    // Best-effort lyrics backfill for already-downloaded songs.
    _trackBackgroundTask(_backfillLyricsForDownloadedSongs());

    if (!_stopped) {
      await _startQueueSubscription();
    }
  }

  /// Versions before 1.2.8 stored Android picker fallbacks as ordinary paths.
  /// Scoped storage never granted Navis reliable access to those paths. Disable
  /// the setting instead of touching user files; the settings UI will ask for a
  /// new persisted tree grant on the next selection.
  Future<void> _migrateUnsafeAndroidCustomFolder() async {
    if (!Platform.isAndroid ||
        !_readCustomDownloadFolderEnabled() ||
        _isSafRoot(_readCustomDownloadFolderPath())) {
      return;
    }
    await _appSettingsDao.updateCustomDownloadFolderEnabled(enabled: false);
    await _appSettingsDao.updateCustomDownloadFolderPath(null);
    await _appSettingsDao.updateCustomDownloadFolderStorageKind('filesystem');
    AppLogger.info(
      'Disabled legacy Android custom download folder without modifying files; '
      'a persisted SAF folder must be selected again.',
    );
  }

  /// Stop the service and cancel any active download.
  Future<void> stop() async {
    await stopAndWait();
  }

  /// Stops queue observation, cancels the active transfer, and does not return
  /// until its cancellation cleanup has finished.
  Future<void> stopAndWait() async {
    _stopped = true;
    await _queueSubscription?.cancel();
    _queueSubscription = null;
    _activeCancelToken?.cancel('Service stopped');
    await _startInFlight;
    await _waitForCurrentWorkToStop();
    await _waitForBackgroundTasks();
    await _waitForPendingProgressWrites();
    await DownloadNotifier.dismissProgress().catchError((_) {});
  }

  void _trackBackgroundTask(Future<void> task) {
    final tracked = task.catchError((Object error, StackTrace _) {
      AppLogger.warning(
        'Download background task failed: ${error.runtimeType}.',
      );
    });
    _backgroundTasks.add(tracked);
    unawaited(tracked.whenComplete(() => _backgroundTasks.remove(tracked)));
  }

  void _trackProgressWrite(Future<void> write) {
    final tracked = write.catchError((Object error, StackTrace _) {
      AppLogger.warning(
        'Download progress persistence failed: ${error.runtimeType}.',
      );
    });
    _pendingProgressWrites.add(tracked);
    unawaited(
      tracked.whenComplete(() => _pendingProgressWrites.remove(tracked)),
    );
  }

  Future<void> _waitForBackgroundTasks() async {
    while (_backgroundTasks.isNotEmpty) {
      await Future.wait<void>(_backgroundTasks.toList(growable: false));
    }
  }

  Future<void> _waitForPendingProgressWrites() async {
    while (_pendingProgressWrites.isNotEmpty) {
      await Future.wait<void>(_pendingProgressWrites.toList(growable: false));
    }
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

    if (normalizedPath case final safPath? when _isSafRoot(safPath)) {
      await _runWithQueuePaused(() async {
        final tree = await _safStorage.validateWritableTree(safPath);
        if (!tree.canRead || !tree.canWrite || !tree.canReplace) {
          throw const FileSystemException(
            'This Android folder cannot safely store Navis downloads.',
          );
        }
        await _relocatePermanentDownloadsToSaf(safPath);
        await _appSettingsDao.updateCustomDownloadFolderPath(safPath);
        await _appSettingsDao.updateCustomDownloadFolderStorageKind(
          'androidSaf',
        );
        await _appSettingsDao.updateCustomDownloadFolderEnabled(
          enabled: enabled,
        );
      });
      return;
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
      await _appSettingsDao.updateCustomDownloadFolderStorageKind('filesystem');
      await _appSettingsDao.updateCustomDownloadFolderEnabled(enabled: enabled);
    });
  }

  Future<PermanentDownloadImportPreview> previewCustomDownloadFolder(
    String path,
  ) {
    return _permanentDownloadImportService.preview(Directory(path));
  }

  Future<PermanentDownloadImportResult> importCustomDownloadFolder(
    PermanentDownloadImportPreview preview, {
    Map<String, String> manualSongIds = const <String, String>{},
    bool includeRecognized = true,
  }) {
    return _runWithQueuePaused(
      () => _permanentDownloadImportService.commit(
        preview,
        manualSongIds: manualSongIds,
        includeRecognized: includeRecognized,
      ),
    );
  }

  Future<String> resolveActivePermanentDownloadPath() async {
    final selected = _readCustomDownloadFolderPath();
    if (_isSafRoot(selected)) return selected!;
    final directory = await _permanentDirectory();
    return directory.path;
  }

  Future<void> removeDownloadedTrack(String songId) async {
    final track = await _cacheDao.getCachedTrack(songId);
    if (track == null || track.cacheType != CacheType.permanent) {
      await _cacheDao.removeCachedTrack(songId);
      return;
    }
    await _deletePermanentLocator(track.filePath);
    await _cacheDao.removeCachedTrack(songId);
  }

  Future<void> removeDownloadedTracks(Iterable<String> songIds) async {
    for (final songId in songIds) {
      final track = await _cacheDao.getCachedTrack(songId);
      if (track == null || track.cacheType != CacheType.permanent) {
        await _cacheDao.removeCachedTrack(songId);
        continue;
      }
      await _deletePermanentLocator(track.filePath);
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

  /// Trigger queue processing after external conditions change.
  ///
  /// The internal processing and Wi-Fi guards remain authoritative, so callers
  /// can invoke this optimistically when settings or connectivity change.
  Future<void> processQueuedDownloads() => _processNext();

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
      if (hadSubscription && !_stopped) {
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
      if (cached != null &&
          cached.cacheType == CacheType.permanent &&
          _isCacheQualityCompatible(cached, quality, format)) {
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
    final cachedTracks = await _cacheDao.getCachedTracksForSongIds(songIds);

    final toEnqueue = <DownloadQueueTableCompanion>[];
    var promotedCount = 0;

    for (final songId in songIds) {
      // Skip if already queued or downloading.
      if (activeSongIds.contains(songId)) continue;

      // Skip if already permanently cached.
      final cached = cachedTracks[songId];
      if (cached?.cacheType == CacheType.permanent &&
          _isCacheQualityCompatible(cached!, quality, format)) {
        continue;
      }

      // Try rolling → permanent promotion.
      if (cached?.cacheType == CacheType.rolling &&
          _isCacheQualityCompatible(cached!, quality, format)) {
        final promoted = await promoteToPermanent(songId);
        if (promoted) {
          promotedCount++;
          continue;
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

    final song = (await _libraryDao.getSongsByIds(<String>[songId]))
        .firstOrNull;
    final newPath = await _resolvePermanentPathForEntry(
      songId: songId,
      song: song,
      format: _resolveStoredFormat(track, song: song),
    );
    final destination = File(newPath);
    try {
      await Directory(p.dirname(newPath)).create(recursive: true);
      // A file already at the destination is reused only when it is a whole
      // copy; anything else is replaced through a part file.
      if (!await destination.exists() ||
          await destination.length() != await file.length()) {
        final part = File('$newPath$downloadPartSuffix');
        try {
          await file.copy(part.path);
          await _renameIntoPlace(part, destination);
        } on FileSystemException {
          await tryDeleteFile(part);
          rethrow;
        }
      }
    } on FileSystemException catch (e) {
      AppLogger.warning('DownloadService: Failed to copy to permanent: $e');
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
    final api = _readApiClient();
    if (song != null && api != null) {
      unawaited(_precacheCoverArt(song, api));
    }
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
    if (_stopped || _processing || _maintenanceInProgress) return;

    // Respect Wi-Fi-only setting.
    if (_readWifiOnly() && !_readIsWifi()) {
      AppLogger.debug('DownloadService: Wi-Fi-only mode, skipping processing');
      return;
    }

    _processing = true;

    try {
      while (true) {
        if (_stopped) break;
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
    if (await _completeFromCompatibleCache(item)) {
      return;
    }

    final api = _readApiClient();
    if (api == null) {
      AppLogger.warning('DownloadService: No API client, skipping $songId');
      await _handleFailure(item, 'No API client');
      return;
    }

    // Mark as downloading.
    await _downloadQueueDao.updateStatus(item.id, DownloadStatus.downloading);

    // Resolve destination file early so we can clean up on failure. The
    // download is written to [partFile] and renamed to [destFile] only when
    // complete, so an interrupted download never looks like a finished file.
    File? destFile;
    File? partFile;
    var renamed = false;
    var registered = false;

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
      partFile = File('${destFile.path}$downloadPartSuffix');

      _activeCancelToken = CancelToken();
      // Dio reports every received chunk. Persist progress at most twice a
      // second, in whole percent steps: each write re-emits the download
      // queue and album download badges to every watching screen.
      var lastPersistedProgress = -1.0;
      final sincePersisted = Stopwatch()..start();
      final response = await _dio.downloadUri(
        downloadUri,
        partFile.path,
        cancelToken: _activeCancelToken,
        onReceiveProgress: (received, total) {
          if (!_stopped && total > 0) {
            final progress = (received / total).clamp(0.0, 1.0);
            if (!shouldPersistDownloadProgress(
              previous: lastPersistedProgress,
              next: progress,
              sinceLastWrite: sincePersisted.elapsed,
            )) {
              return;
            }
            lastPersistedProgress = progress;
            sincePersisted.reset();
            _trackProgressWrite(
              _downloadQueueDao.updateProgress(item.id, progress),
            );
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

      if (_stopped) {
        await tryDeleteFile(partFile);
        return;
      }

      if (response.statusCode != null &&
          response.statusCode! >= 200 &&
          response.statusCode! < 300) {
        await _renameIntoPlace(partFile, destFile);
        renamed = true;
        // Tag before measuring, so the registered size is the final one.
        // Tags only help a later rescan; they never cost the download.
        try {
          await _permanentDownloadImportService.writeIdentityTags(
            destFile,
            songId,
          );
        } on Object catch (error) {
          AppLogger.warning(
            'DownloadService: Identity tags not written for $songId: $error',
          );
        }
        // Register in cached_tracks as permanent.
        final stat = await destFile.stat();
        _reportNetworkUsage?.call(
          category: NetworkUsageCategory.download,
          bytes: stat.size,
        );
        final format = _resolveFormat(song, item);
        final bitRate = _resolveBitRate(song, item);

        if (_isSafRoot(_readCustomDownloadFolderPath())) {
          final treeUri = _readCustomDownloadFolderPath()!;
          final relativePath = _safRelativePathFor(song, format);
          // The local file was tagged before its single upload; a document
          // is never copied back out to be tagged.
          final locator = await _safStorage.writeFromFile(
            treeUri: treeUri,
            relativePath: relativePath,
            source: destFile,
            mimeType: _mimeTypeFor(format),
            replace: false,
          );
          await tryDeleteFile(destFile);
          await _permanentDownloadImportService.recordDownloadedSafEntries(
            treeUri: treeUri,
            entries: [
              (
                relativePath: relativePath,
                fileSize: stat.size,
                songId: songId,
                format: format,
              ),
            ],
          );
          await _cacheDao.upsertCachedTrack(
            CachedTracksTableCompanion.insert(
              songId: songId,
              filePath: locator,
              storageKind: const Value('androidSaf'),
              fileSize: stat.size,
              format: format,
              bitRate: bitRate == null ? const Value.absent() : Value(bitRate),
              cacheType: CacheType.permanent,
              downloadStatus: DownloadStatus.complete,
              lastAccessedAt: DateTime.now(),
            ),
          );
        } else {
          await _cacheDao.upsertCachedTrack(
            CachedTracksTableCompanion.insert(
              songId: songId,
              filePath: destFile.path,
              fileSize: stat.size,
              format: format,
              bitRate: bitRate == null ? const Value.absent() : Value(bitRate),
              cacheType: CacheType.permanent,
              downloadStatus: DownloadStatus.complete,
              lastAccessedAt: DateTime.now(),
            ),
          );
          registered = true;
          // The download is registered; the sidecar record and identity tags
          // are bookkeeping and must never cost the user the finished file
          // (for example while antivirus briefly locks the sidecar).
          try {
            await _permanentDownloadImportService.recordDownloaded(
              root: await _permanentDirectory(),
              file: destFile,
              songId: songId,
              format: format,
            );
          } on Object catch (error, stackTrace) {
            AppLogger.warning(
              'DownloadService: Could not record $songId in the download '
              'folder sidecar: $error\n$stackTrace',
            );
          }
        }

        // Remove from queue.
        await _downloadQueueDao.remove(item.id);

        // Pre-cache cover art alongside the audio file (best-effort).
        _trackBackgroundTask(_precacheCoverArt(song, api));

        _trackBackgroundTask(
          DownloadNotifier.dismissProgress().catchError((_) {}),
        );
        _trackBackgroundTask(
          DownloadNotifier.showComplete(title: 'Downloaded: $songTitle')
              .catchError((_) {}),
        );

        // Best-effort: pre-fetch lyrics so they're available offline.
        _trackBackgroundTask(_prefetchLyrics(songId, song, api));

        AppLogger.info(
          'DownloadService: Completed download for $songId '
          '(${stat.size} bytes)',
        );
      } else {
        await tryDeleteFile(partFile);
        // 404 Not Found / 410 Gone — resource is permanently unavailable, no point retrying.
        if (response.statusCode == 404 || response.statusCode == 410) {
          AppLogger.warning(
            'DownloadService: Source not found (${response.statusCode}) for $songId — marking as permanently failed',
          );
          // An isolated media 404 is suspicion evidence only (plan E2):
          // validated catalog evidence must confirm absence.
          await _libraryDao.markSongsSuspectedMissing(<String>[songId]);
          await _downloadQueueDao.updateStatus(item.id, DownloadStatus.failed);
          await DownloadNotifier.showFailed().catchError((_) {});
        } else {
          await _handleFailure(item, 'HTTP ${response.statusCode}');
        }
      }
    } on DioException catch (e) {
      await DownloadNotifier.dismissProgress().catchError((_) {});
      if (e.type == DioExceptionType.cancel) {
        AppLogger.debug('DownloadService: Download cancelled for $songId');
        await tryDeleteFile(partFile);
        if (!_stopped) {
          await _downloadQueueDao.updateStatus(item.id, DownloadStatus.queued);
        }
      } else {
        final statusCode = e.response?.statusCode;
        AppLogger.warning('DownloadService: Dio error for $songId: $e');
        await tryDeleteFile(partFile);
        if (statusCode == 404 || statusCode == 410) {
          await _libraryDao.markSongsSuspectedMissing(<String>[songId]);
        }
        await _handleFailure(item, e.toString());
      }
    } on Object catch (e, st) {
      AppLogger.warning('DownloadService: Error for $songId: $e\n$st');
      await tryDeleteFile(partFile);
      // Only a file this attempt put in place and never registered.
      if (renamed && !registered) await tryDeleteFile(destFile);
      await _handleFailure(item, e.toString());
    } finally {
      _activeCancelToken = null;
    }
  }

  /// Gives a finished download its real name in one step. Windows refuses
  /// the rename while a scanner briefly holds the new file, so it retries.
  Future<void> _renameIntoPlace(File part, File destination) async {
    for (var attempt = 1; ; attempt++) {
      try {
        await part.rename(destination.path);
        return;
      } on FileSystemException {
        if (attempt == 3) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 200 * attempt));
      }
    }
  }

  /// Removes `*.navis-part` files left by downloads interrupted by a crash or
  /// kill, in the active download folder. Only files with that suffix, which
  /// Navis alone writes, are touched; links are not followed.
  Future<void> _removePartialDownloads() async {
    if (_isSafRoot(_readCustomDownloadFolderPath())) return;
    try {
      final root = await _permanentDirectory();
      if (!await root.exists()) return;
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File && entity.path.endsWith(downloadPartSuffix)) {
          await tryDeleteFile(entity);
        }
      }
    } on Object catch (error) {
      AppLogger.warning(
        'DownloadService: Partial download cleanup failed: $error',
      );
    }
  }

  Future<bool> _completeFromCompatibleCache(DownloadQueueTableData item) async {
    final songId = item.songId;
    if (songId == null) return false;

    final cached = await _cacheDao.getCachedTrack(songId);
    if (cached == null) {
      return false;
    }

    if (_isSafRoot(cached.filePath)
        ? !await _safStorage.exists(cached.filePath)
        : !await File(cached.filePath).exists()) {
      await _cacheDao.removeCachedTrack(songId);
      return false;
    }

    if (!_isCacheQualityCompatible(cached, item.quality, item.format)) {
      return false;
    }

    if (cached.cacheType == CacheType.permanent) {
      await _downloadQueueDao.remove(item.id);
      AppLogger.info(
        'DownloadService: Completed queued download for $songId from permanent cache.',
      );
      return true;
    }

    if (cached.cacheType == CacheType.rolling) {
      final promoted = await promoteToPermanent(songId);
      if (promoted) {
        await _downloadQueueDao.remove(item.id);
        AppLogger.info(
          'DownloadService: Promoted queued rolling-cached track $songId to permanent.',
        );
        return true;
      }
    }

    return false;
  }

  Future<void> _precacheCoverArt(
    SongsTableData song,
    SubsonicApiClient api,
  ) async {
    final coverArtId = song.coverArt?.trim();
    if (coverArtId == null || coverArtId.isEmpty) {
      return;
    }

    try {
      final artUrl = api
          .getCoverArtUrl(id: coverArtId, size: kCoverArtStandardSize)
          .toString();
      await _readCoverArtCacheManager().downloadFile(
        artUrl,
        key: coverArtImageCacheKey(coverArtId, kCoverArtStandardSize),
      );
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'DownloadService: Cover art pre-cache failed for '
        'song=${song.id} coverArt=$coverArtId: $error\n$stackTrace',
      );
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
        if (!_stopped) {
          unawaited(_processNext());
        }
      });
    } else {
      await _downloadQueueDao.updateStatus(item.id, DownloadStatus.failed);
      await DownloadNotifier.showFailed().catchError((_) {});
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
      // Compared by key, so a stored path spelled differently (letter case
      // on Windows, a linked folder) never gets a real download deleted.
      final identity = await DownloadRootIdentity.resolve(permDir.path);
      final knownKeys = <String>{
        for (final entry in knownEntries)
          if (identity.keyFor(entry.filePath) case final key?)
            identity.lookupKey(key),
      };

      await for (final entity in permDir.list(recursive: true)) {
        if (entity is! File) {
          continue;
        }
        final path = entity.path;
        final name = p.basename(path);
        if (name == permanentDownloadManifestFileName ||
            name == '$permanentDownloadManifestFileName-wal' ||
            name == '$permanentDownloadManifestFileName-shm') {
          continue;
        }
        final basePath = path.endsWith('.mime')
            ? path.substring(0, path.length - '.mime'.length)
            : path;
        final key = identity.keyFor(basePath);
        if (key != null && !knownKeys.contains(identity.lookupKey(key))) {
          AppLogger.info('DownloadService: Removing orphaned file $path');
          await deleteFileWithSuffixes(basePath);
        }
      }
    } on Object catch (e) {
      // Best-effort — don't crash the service on cleanup failure.
      AppLogger.warning('DownloadService: Orphaned file cleanup error: $e');
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
      if (_stopped) {
        return;
      }
      if (!_readIsWifi()) {
        AppLogger.debug(
          'DownloadService: Lyrics backfill skipped — not on wifi.',
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
        if (_stopped) {
          return;
        }
        final existing = await _libraryDao.getExternalLyricsCache(song.id);
        if (existing != null && existing.syncedLyrics != null) {
          // Already have synced lyrics — best possible quality, nothing to do.
          continue;
        }
        // Songs with only plain lyrics are still processed to try to upgrade
        // to synced lyrics.

        await _prefetchLyrics(song.id, song, api);

        if (_stopped) {
          return;
        }

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
      final settings = await _appSettingsDao.getSettings();
      final metadata = song.artistName == null || song.title.trim().isEmpty
          ? null
          : (
              artist: song.artistName!,
              title: song.title,
              album: song.albumName,
              durationSeconds: song.duration,
            );
      final resolver = LyricsResolver(
        libraryDao: _libraryDao,
        lrclibClient: _lrclibClient,
        apiClient: api,
      );
      final resolution = await resolver.resolve(
        songId: songId,
        metadata: metadata,
        useLrclib: settings?.useLrclib ?? true,
        lyricsCacheTtlSeconds: permanentLyricsCacheTtlSeconds,
        cacheServerLyrics: true,
      );
      AppLogger.info(
        'DownloadService: Lyrics prefetch resolved ${resolution.source.name} '
        'for $songId',
      );
    } on Object catch (e) {
      // Never let a lyrics error abort or surface through the download flow.
      AppLogger.warning(
        'DownloadService: Lyrics prefetch failed for $songId: $e',
      );
    }
  }

  Future<void> _normalizePermanentDownloads() async {
    if (_isSafRoot(_readCustomDownloadFolderPath())) {
      return;
    }
    try {
      final targetDirectory = await _permanentDirectory();
      final customDownloadFolderEnabled = _readCustomDownloadFolderEnabled();
      await _relocatePermanentDownloads(
        targetDirectory: targetDirectory,
        customDownloadFolderEnabled: customDownloadFolderEnabled,
        customDownloadFolderPath: _readCustomDownloadFolderPath(),
        // A custom root is user-owned: files already inside it, including
        // adopted ones, keep their names and are never rewritten.
        keepEntriesInsideTarget: customDownloadFolderEnabled,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'DownloadService: Permanent download normalization failed: '
        '$error\n$stackTrace',
      );
    }
  }

  Future<void> _relocatePermanentDownloadsToSaf(String treeUri) async {
    final entries = await _cacheDao.getPermanentEntries();
    if (entries.isEmpty) return;
    final songs = await _libraryDao.getSongsByIds(
      entries.map((entry) => entry.songId).toSet(),
    );
    final songsById = <String, SongsTableData>{
      for (final song in songs) song.id: song,
    };
    final oldLocators = <String>[];
    final newLocators = <String>[];
    final movedEntries = <_SafRelocatedPermanentDownload>[];
    final indexEntries =
        <({String relativePath, int fileSize, String songId, String format})>[];
    try {
      for (final entry in entries) {
        if (_isSafRoot(entry.filePath) &&
            await _safStorage.isDescendant(
              treeUri: treeUri,
              documentUri: entry.filePath,
            )) {
          continue;
        }
        File? temporary;
        final source = _isSafRoot(entry.filePath)
            ? (temporary = await _safStorage.materialize(entry.filePath))
            : File(entry.filePath);
        if (!await source.exists()) {
          continue;
        }
        final format = _resolveStoredFormat(
          entry,
          song: songsById[entry.songId],
        );
        final relativePath = _safRelativePathFor(
          songsById[entry.songId] ??
              SongsTableData(
                id: entry.songId,
                title: entry.songId,
                isExternal: false,
                isProvisional: false,
              ),
          format,
        );
        final target = await _safStorage.writeFromFile(
          treeUri: treeUri,
          relativePath: relativePath,
          source: source,
          mimeType: _mimeTypeFor(format),
          replace: false,
        );
        newLocators.add(target);
        oldLocators.add(entry.filePath);
        // Navis's own downloads already carry identity tags; only the folder
        // index needs entries, written once for the whole move.
        indexEntries.add((
          relativePath: relativePath,
          fileSize: entry.fileSize,
          songId: entry.songId,
          format: format,
        ));
        movedEntries.add((entry: entry, locator: target, format: format));
        if (temporary != null) {
          final temporaryFile = temporary;
          await temporaryFile.delete().catchError((_) => temporaryFile);
        }
      }
      await _permanentDownloadImportService.recordDownloadedSafEntries(
        treeUri: treeUri,
        entries: indexEntries,
      );
      await _cacheDao.upsertCachedTracks(<CachedTracksTableCompanion>[
        for (final moved in movedEntries)
          CachedTracksTableCompanion.insert(
            songId: moved.entry.songId,
            filePath: moved.locator,
            storageKind: const Value('androidSaf'),
            fileSize: moved.entry.fileSize,
            format: moved.format,
            bitRate: moved.entry.bitRate == null
                ? const Value.absent()
                : Value(moved.entry.bitRate),
            cacheType: CacheType.permanent,
            downloadStatus: moved.entry.downloadStatus,
            lastAccessedAt: DateTime.now(),
          ),
      ]);
      for (final locator in oldLocators) {
        await _deletePermanentLocator(locator);
      }
    } on Object {
      for (final locator in newLocators) {
        await _safStorage.delete(locator).catchError((_) {});
      }
      rethrow;
    }
  }

  Future<void> _relocatePermanentDownloads({
    required Directory targetDirectory,
    required bool customDownloadFolderEnabled,
    required String? customDownloadFolderPath,
    bool rollbackOnFailure = false,
    bool keepEntriesInsideTarget = false,
  }) async {
    final currentRootIsSaf = _isSafRoot(_readCustomDownloadFolderPath());
    final currentRootDirectory = currentRootIsSaf
        ? null
        : await _permanentDirectory(
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
    final safSourcesToDelete = <String>[];

    try {
      for (final entry in entries) {
        final sourceWasSaf = _isSafRoot(entry.filePath);
        File? materializedSource;
        final sourceFile = sourceWasSaf
            ? (materializedSource = await _safStorage.materialize(
                entry.filePath,
              ))
            : File(entry.filePath);
        if (!await sourceFile.exists()) {
          if (materializedSource != null) {
            try {
              await materializedSource.delete();
            } on FileSystemException {
              // The temporary copy may already have been cleaned up.
            }
          }
          AppLogger.warning(
            'DownloadService: Skipping permanent relocation for ${entry.songId} '
            'because the file is missing: ${entry.filePath}',
          );
          continue;
        }

        if (keepEntriesInsideTarget &&
            !sourceWasSaf &&
            p.isWithin(targetDirectory.path, entry.filePath)) {
          reservedTargetPaths.add(entry.filePath);
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
        if (p.equals(entry.filePath, targetPath) ||
            (!sourceWasSaf && await _isSameFile(entry.filePath, targetPath))) {
          // Already in place, possibly named through a linked folder.
          continue;
        }

        final previousParent = sourceWasSaf
            ? null
            : File(entry.filePath).parent;
        if (sourceWasSaf) {
          await Directory(p.dirname(targetPath)).create(recursive: true);
          await sourceFile.copy(targetPath);
        } else {
          await _movePermanentFileSet(entry.filePath, targetPath);
        }
        await _cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: entry.songId,
            filePath: targetPath,
            storageKind: const Value('filesystem'),
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
        await _permanentDownloadImportService.recordDownloaded(
          root: targetDirectory,
          file: File(targetPath),
          songId: entry.songId,
          format: storedFormat,
        );
        movedEntries.add((
          entry: entry,
          storedFormat: storedFormat,
          targetPath: targetPath,
          sourceWasSaf: sourceWasSaf,
        ));
        if (sourceWasSaf) {
          safSourcesToDelete.add(entry.filePath);
        } else if (previousParent != null && currentRootDirectory != null) {
          await pruneEmptyParentDirectories(
            startDirectoryPath: previousParent.path,
            stopAtDirectoryPath: currentRootDirectory.path,
          );
        }
        if (materializedSource != null) {
          try {
            await materializedSource.delete();
          } on FileSystemException {
            // The temporary copy may already have been cleaned up.
          }
        }
      }
      for (final locator in safSourcesToDelete) {
        await _deletePermanentLocator(locator);
      }
    } on Object {
      if (rollbackOnFailure) {
        await _rollbackRelocatedPermanentDownloads(
          movedEntries,
          currentRootDirectoryPath: currentRootDirectory?.path,
          targetRootDirectoryPath: targetDirectory.path,
        );
      }
      rethrow;
    }
  }

  Future<void> _rollbackRelocatedPermanentDownloads(
    List<_RelocatedPermanentDownload> movedEntries, {
    required String? currentRootDirectoryPath,
    required String targetRootDirectoryPath,
  }) async {
    for (final moved in movedEntries.reversed) {
      if (moved.sourceWasSaf) {
        await deleteFileWithSuffixes(moved.targetPath);
      } else {
        await _movePermanentFileSet(moved.targetPath, moved.entry.filePath);
      }
      await _cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: moved.entry.songId,
          filePath: moved.entry.filePath,
          storageKind: Value(moved.entry.storageKind),
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
      await pruneEmptyParentDirectories(
        startDirectoryPath: File(moved.targetPath).parent.path,
        stopAtDirectoryPath: targetRootDirectoryPath,
      );
      if (currentRootDirectoryPath != null) {
        await pruneEmptyParentDirectories(
          startDirectoryPath: File(moved.entry.filePath).parent.path,
          stopAtDirectoryPath: currentRootDirectoryPath,
        );
      }
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
    return _permanentPathResolver.resolvePathInDirectory(
      rootDirectory: rootDirectory,
      artist: null,
      title: p.basenameWithoutExtension(existingPath ?? songId),
      titleFallback: songId,
      identity: songId,
      extension: format,
      existingPath: existingPath,
      reservedPaths: reservedPaths,
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

  static Future<bool> _isSameFile(String a, String b) async {
    try {
      return await File(a).exists() &&
          await File(b).exists() &&
          await FileSystemEntity.identical(a, b);
    } on FileSystemException {
      return false;
    }
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
      throw FileSystemException('Source file does not exist.', source.path);
    }

    if (await destination.exists()) {
      // The same file reached through another spelling of its folder (a
      // link, junction or mapped drive): deleting the "destination" would
      // delete the only copy.
      if (await _isSameFile(source.path, destination.path)) return;
      await destination.delete();
    }

    try {
      await source.rename(destination.path);
    } on FileSystemException {
      await source.copy(destination.path);
      await source.delete();
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
    if (_isSafRoot(_readCustomDownloadFolderPath())) {
      final temporaryRoot = await _permanentPathResolver.resolveDefaultRoot();
      final temporary = File(
        p.join(
          temporaryRoot.path,
          '.navis-saf-transfer-${song.id}.${_resolveFormat(song, item)}',
        ),
      );
      await temporary.parent.create(recursive: true);
      return temporary;
    }
    final ext = _resolveFormat(song, item);
    final targetPath = await _permanentPathResolver.resolveSongPath(
      song: song,
      extension: ext,
    );
    return File(targetPath);
  }

  bool _isSafRoot(String? value) =>
      Platform.isAndroid && (value?.startsWith('content://') ?? false);

  Future<void> _deletePermanentLocator(String locator) async {
    if (_isSafRoot(locator)) {
      await _safStorage.delete(locator);
      return;
    }
    await deleteFileWithSuffixes(locator);
    final rootPath = await resolveActivePermanentDownloadPath();
    await pruneEmptyParentDirectories(
      startDirectoryPath: File(locator).parent.path,
      stopAtDirectoryPath: rootPath,
    );
  }

  String _safRelativePathFor(SongsTableData song, String format) {
    final artist = PermanentDownloadPathResolver.sanitizePathComponent(
      song.artistName,
      fallback: PermanentDownloadPathResolver.unknownArtistDirectory,
    );
    final title = PermanentDownloadPathResolver.sanitizePathComponent(
      song.title,
      fallback: song.id,
    );
    final identity = sha1
        .convert(utf8.encode(song.id))
        .toString()
        .substring(0, 8);
    return '$artist/$title [$identity].${format.replaceFirst('.', '')}';
  }

  String _mimeTypeFor(String format) => switch (format.toLowerCase()) {
    'flac' => 'audio/flac',
    'mp3' => 'audio/mpeg',
    'm4a' => 'audio/mp4',
    'ogg' || 'opus' => 'audio/ogg',
    _ => 'application/octet-stream',
  };

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
    return api.streamUrl(id: songId, maxBitRate: maxBitRate, format: format);
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

  int? _resolveBitRate(SongsTableData song, DownloadQueueTableData item) {
    final quality = item.quality?.trim();
    if (quality != null && quality.isNotEmpty) {
      return int.tryParse(quality);
    }
    return song.bitRate;
  }
}

/// Whether a download progress update is worth persisting: completion, or at
/// least one percentage point and half a second since the last write.
@visibleForTesting
bool shouldPersistDownloadProgress({
  required double previous,
  required double next,
  Duration sinceLastWrite = const Duration(days: 1),
}) =>
    next >= 1.0 ||
    (next - previous >= 0.01 &&
        (previous < 0 || sinceLastWrite >= const Duration(milliseconds: 500)));
