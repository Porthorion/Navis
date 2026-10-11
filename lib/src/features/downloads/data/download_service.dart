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
import 'package:navis/src/features/downloads/data/download_storage_capacity.dart';
import 'package:navis/src/features/downloads/domain/download_failure_message.dart';
import 'package:navis/src/features/downloads/data/permanent_download_path_resolver.dart';
import 'package:navis/src/features/downloads/data/permanent_download_import_service.dart';
import 'package:navis/src/features/downloads/data/android_saf_storage.dart';
import 'package:navis/src/features/downloads/data/permanent_artwork_store.dart';
import 'package:navis/src/features/downloads/domain/download_preferences.dart';
import 'package:navis/src/features/player/data/lyrics_resolver.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/notifications/notification_localizations.dart';
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

class _RecoveryCancelled implements Exception {
  const new();
}

/// Orchestrates permanent downloads of tracks from a Subsonic server.
///
/// Up to [kMaxConcurrentDownloads] transfers run at once (the user's setting,
/// one on cellular, none while paused). Each transfer streams to a part file
/// via Dio; only the network transfer runs in parallel. Finishing a download
/// (rename, tags, Android folder upload, database and folder index records)
/// runs one download at a time, so two finishes never race on the same
/// folder index or file name.
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
    bool Function()? readIsOnline,
    Future<int?> Function(String)? readFreeBytes,
    required bool Function() readCustomDownloadFolderEnabled,
    required String? Function() readCustomDownloadFolderPath,
    required this._lrclibClient,
    required this._readCoverArtCacheManager,
    bool Function()? readLyricsAllowed,
    String? Function()? readProfileIdentity,
    AppLocalizations Function()? readLocalizations,
    this._reportNetworkUsage,
    Future<Directory> Function()? readApplicationSupportDirectory,
    PermanentArtworkStore? artworkStore,
    Future<void> Function(Directory)? validateCustomRoot,
    this.folderRecheckInterval = const Duration(seconds: 5),
    Dio? dio,
    bool? isAndroid,
    this._rejectsCustomFolder = cloneRejectsDownloadFolder,
  }) : _readIsOnline = readIsOnline ?? (() => true),
       _readFreeBytes = readFreeBytes ?? downloadStorageFreeBytes,
       _cacheDao = cacheDao,
       _libraryDao = libraryDao,
       _readCustomDownloadFolderEnabled = readCustomDownloadFolderEnabled,
       _readCustomDownloadFolderPath = readCustomDownloadFolderPath,
       _readLyricsAllowed = readLyricsAllowed ?? (() => true),
       _readLocalizations =
           readLocalizations ?? (() => resolveNotificationLocalizations(null)),
       _dio = dio ?? Dio(),
       _artworkStore =
           artworkStore ??
           PermanentArtworkStore(
             readApplicationSupportDirectory: readApplicationSupportDirectory,
             dio: dio,
           ),
       _isAndroid = isAndroid ?? Platform.isAndroid,
       _permanentPathResolver = PermanentDownloadPathResolver(
         validateCustomRoot: validateCustomRoot,
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
  final bool Function() _readIsOnline;
  final Future<int?> Function(String) _readFreeBytes;
  final Map<int, int> _spaceReservations = {};
  int _spaceRequired = 0;
  static const _spaceMargin = 16 * 1024 * 1024;
  final bool Function() _readCustomDownloadFolderEnabled;
  final String? Function() _readCustomDownloadFolderPath;
  final LrclibClient _lrclibClient;

  /// Resolves notification strings when a notification is raised.
  final AppLocalizations Function() _readLocalizations;

  /// Whether lyrics prefetch may use LRCLIB, per the integration policy.
  final bool Function() _readLyricsAllowed;
  final BaseCacheManager Function() _readCoverArtCacheManager;
  final NetworkUsageReporter? _reportNetworkUsage;
  final Dio _dio;
  final bool _isAndroid;

  /// Folders this build must not use as the custom download folder (the
  /// user's own folders in a clone diagnostics build).
  final bool Function(String path) _rejectsCustomFolder;
  final PermanentDownloadPathResolver _permanentPathResolver;
  final PermanentDownloadImportService _permanentDownloadImportService;
  final AndroidSafStorage _safStorage = const AndroidSafStorage();
  final PermanentArtworkStore _artworkStore;

  @visibleForTesting
  final Duration folderRecheckInterval;
  Timer? _folderRecheckTimer;

  DownloadFolderProblem? _folderProblem;
  int _folderCheckGeneration = 0;
  bool _disposed = false;
  final _folderChanges = StreamController<DownloadFolderProblem?>.broadcast();
  final _folderNotices = StreamController<DownloadFolderProblem>.broadcast();
  bool _folderNoticeSent = false;
  bool _folderActionRequired = false;

  @visibleForTesting
  DownloadFolderProblem? get folderProblem => _folderProblem;
  Stream<DownloadFolderProblem?> get folderChanges => Stream.multi((sink) {
    final subscription = _folderChanges.stream.listen(
      sink.add,
      onDone: sink.close,
    );
    sink.add(_folderProblem);
    sink.onCancel = subscription.cancel;
  });

  Stream<DownloadFolderProblem> get folderNotices => _folderNotices.stream;

  void _setFolderProblem(
    DownloadFolderProblem? problem, {
    bool recheck = true,
    bool cancelTransfers = true,
  }) {
    if (_disposed) return;
    _folderRecheckTimer?.cancel();
    _folderActionRequired = problem != null && !recheck;
    if (_folderProblem != problem) {
      _folderProblem = problem;
      if (problem == null) _folderNoticeSent = false;
      _folderChanges.add(problem);
    }
    if (problem != DownloadFolderProblem.noSpace) _spaceRequired = 0;
    if (problem != null) {
      _trackBackgroundTask(_recordQueueHold());
      _retryTimer?.cancel();
      if (cancelTransfers) _cancelTransfers(_CancelReason.requeue);
      if (recheck && !_stopped) {
        // Probe availability only; queued items never accrue failure retries.
        _folderRecheckTimer = Timer(folderRecheckInterval, () {
          unawaited(processQueuedDownloads());
        });
      }
    }
  }

  Future<bool> _checkDownloadFolder({bool explicitRepair = false}) async {
    if (_folderActionRequired && !explicitRepair) return false;
    final generation = ++_folderCheckGeneration;
    if (!_readCustomDownloadFolderEnabled()) {
      return await _recheckSpaceHold(explicitRepair: explicitRepair);
    }
    final path = _readCustomDownloadFolderPath()?.trim();
    try {
      if (path == null || path.isEmpty) {
        throw const DownloadFolderUnavailableException(
          DownloadFolderProblem.unset,
        );
      }
      if (_isSafRoot(path)) {
        final tree = await _safStorage.validateWritableTree(path);
        if (!tree.canRead || !tree.canWrite || !tree.canReplace) {
          throw const DownloadFolderUnavailableException(
            DownloadFolderProblem.inaccessible,
          );
        }
      } else {
        await _permanentPathResolver.resolveRootFor(
          customDownloadFolderEnabled: true,
          customDownloadFolderPath: path,
        );
      }
      if (generation != _folderCheckGeneration || _disposed) {
        return _folderProblem == null;
      }
      return await _recheckSpaceHold(explicitRepair: explicitRepair);
    } on DownloadFolderUnavailableException catch (error) {
      if (generation == _folderCheckGeneration) {
        if (_isNoSpaceError(error)) {
          _spaceRequired = _spaceMargin;
          _setFolderProblem(DownloadFolderProblem.noSpace);
        } else {
          _setFolderProblem(error.problem);
        }
      }
    } on FileSystemException catch (error) {
      if (generation == _folderCheckGeneration) {
        if (_isNoSpaceError(error)) {
          _spaceRequired = _spaceMargin;
          _setFolderProblem(DownloadFolderProblem.noSpace);
        } else {
          _setFolderProblem(DownloadFolderProblem.inaccessible);
        }
      }
    }
    return false;
  }

  Future<bool> _holdForFolderFailure(FileSystemException error) async {
    if (_isNoSpaceError(error)) {
      _spaceRequired =
          _spaceMargin +
          _spaceReservations.values.fold<int>(0, (a, b) => a + b);
      _setFolderProblem(DownloadFolderProblem.noSpace);
      return true;
    }
    if (_isPermissionError(error)) {
      _setFolderProblem(DownloadFolderProblem.inaccessible, recheck: false);
      return true;
    }
    if (!_readCustomDownloadFolderEnabled()) return false;
    if (!await _checkDownloadFolder()) return true;
    return false;
  }

  bool _isNoSpaceError(FileSystemException error) =>
      (Platform.isWindows && !_isAndroid
              ? const [39, 112]
              : const [28, 69, 122])
          .contains(error.osError?.errorCode);

  bool _isPermissionError(FileSystemException error) =>
      (Platform.isWindows ? const [1, 5, 13] : const [1, 13]).contains(
        error.osError?.errorCode,
      );

  DownloadFailureReason? get _holdReason => switch (_folderProblem) {
    DownloadFolderProblem.noSpace => DownloadFailureReason.noSpace,
    DownloadFolderProblem.inaccessible => DownloadFailureReason.permission,
    DownloadFolderProblem.unset ||
    DownloadFolderProblem.missing => DownloadFailureReason.folderUnavailable,
    null => null,
  };

  Future<void> _recordQueueHold() async {
    final reason = _holdReason;
    if (reason == null) return;
    for (final item in await _downloadQueueDao.getQueuedItems()) {
      if (_holdReason != reason) return;
      await _downloadQueueDao.recordFailure(
        item.id,
        reason,
        status: DownloadStatus.queued,
      );
    }
  }

  Future<String> _capacityDirectory() async =>
      (_isSafRoot(_readCustomDownloadFolderPath())
              ? await _permanentPathResolver.resolveDefaultRoot()
              : await _permanentDirectory())
          .path;

  Future<bool> _recheckSpaceHold({required bool explicitRepair}) async {
    if (_folderProblem == DownloadFolderProblem.noSpace) {
      final free = await _readFreeBytes(await _capacityDirectory());
      if ((free == null && !explicitRepair) ||
          (free != null && free < _spaceRequired)) {
        _setFolderProblem(
          DownloadFolderProblem.noSpace,
          cancelTransfers: false,
        );
        return false;
      }
    }
    _setFolderProblem(null);
    return true;
  }

  int _expectedBytes(SongsTableData song, String? quality) {
    if (quality == null && (song.size ?? 0) > 0) return song.size!;
    return (song.duration ?? 0) *
        (int.tryParse(quality ?? '') ?? song.bitRate ?? 320) *
        125;
  }

  Future<bool> _checkSpace(int expected, {bool notice = false}) async {
    final reserved = _spaceReservations.values.fold<int>(0, (a, b) => a + b);
    final required = expected + expected ~/ 10 + reserved + _spaceMargin;
    final free = await _readFreeBytes(await _capacityDirectory());
    if (free == null || free >= required) return true;
    // A batch warning must not require room for the entire album to resume.
    // Workers recheck their own reservation when space is freed.
    _spaceRequired = _spaceMargin + (notice ? 1 : expected + expected ~/ 10);
    _setFolderProblem(DownloadFolderProblem.noSpace, cancelTransfers: false);
    if (notice && !_folderNoticeSent) {
      _folderNoticeSent = true;
      _folderNotices.add(DownloadFolderProblem.noSpace);
    }
    return false;
  }

  /// Rechecks after a folder choice, storage switch or explicit resume request.
  Future<void> refreshDownloadFolder() async {
    if (await _checkDownloadFolder(explicitRepair: true)) {
      await _recoverStartup();
    }
    await _processNext();
  }

  Future<bool> _checkRequestedFolder() async {
    final usable = await _checkDownloadFolder();
    if (!usable && !_folderNoticeSent && !_disposed && _folderProblem != null) {
      _folderNoticeSent = true;
      _folderNotices.add(_folderProblem!);
    }
    return usable;
  }

  /// Closes app-lifetime observations after workers have stopped.
  Future<void> dispose() async {
    _disposed = true;
    _folderCheckGeneration++;
    await stopAndWait();
    await _folderChanges.close();
    await _folderNotices.close();
  }

  StreamSubscription<List<DownloadQueueTableData>>? _queueSubscription;
  final List<StreamSubscription<Object>> _settingsSubscriptions =
      <StreamSubscription<Object>>[];
  bool _maintenanceInProgress = false;
  bool _stopped = false;
  bool _paused = false;
  int _maxConcurrent = kDefaultConcurrentDownloads;

  /// Re-entrancy guard for [_processNext]; a request made while it runs is
  /// remembered in [_pumpRequested] and served before it returns.
  bool _pumping = false;
  bool _pumpRequested = false;

  /// Queue ids claimed by a running worker, with the worker's future.
  final Map<int, Future<void>> _workers = <int, Future<void>>{};

  /// Cancel tokens of transfers in flight, by queue id.
  final Map<int, CancelToken> _activeTransfers = <int, CancelToken>{};

  /// Why a claimed item is being cancelled, by queue id.
  final Map<int, _CancelReason> _cancelReasons = <int, _CancelReason>{};

  /// Failed items wait here until their backoff elapses, by queue id.
  final Map<int, DateTime> _retryNotBefore = <int, DateTime>{};
  Timer? _retryTimer;

  /// Destination paths of transfers in flight, so two concurrent songs with
  /// the same artist and title never resolve to the same file.
  final Set<String> _reservedDownloadPaths = <String>{};

  /// Serializes the finishing step of concurrent downloads.
  Future<void> _finalizeTail = Future<void>.value();

  /// Bytes received per transfer in flight, for the progress notification.
  final Map<int, ({String title, int received, int total})> _transferProgress =
      <int, ({String title, int received, int total})>{};

  Future<void>? _startInFlight;
  Future<void>? _recoveryInFlight;
  int _lifecycleGeneration = 0;
  bool _startupRecoveryPending = false;
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
    _lifecycleGeneration++;
    await _migrateUnsafeAndroidCustomFolder();
    _startupRecoveryPending = true;
    if (await _checkDownloadFolder()) await _recoverStartup();
    if (_stopped) return;

    // Best-effort lyrics and cover art backfill for already-downloaded songs.
    _trackBackgroundTask(_backfillLyricsForDownloadedSongs());
    _trackBackgroundTask(_backfillArtworkForDownloadedSongs());

    // Read before the queue subscription starts, so a paused queue never
    // begins a transfer while the setting streams are still loading.
    _paused = await _appSettingsDao.getDownloadsPaused();
    _maxConcurrent = await _appSettingsDao.getMaxConcurrentDownloads();
    if (_stopped) return;
    await _startSettingsSubscriptions();

    if (!_stopped) {
      await _startQueueSubscription();
    }
  }

  void _checkRecovery(int? generation) {
    if (generation != null &&
        (_stopped || _disposed || generation != _lifecycleGeneration)) {
      throw const _RecoveryCancelled();
    }
  }

  Future<void> _recoverStartup() {
    if (!_startupRecoveryPending || _stopped || _disposed)
      return Future.value();
    final generation = _lifecycleGeneration;
    return _recoveryInFlight ??=
        (() async {
          try {
            await _removePartialDownloads(generation);
            _checkRecovery(generation);
            await _reconcileFinishedDownloads(generation);
            _checkRecovery(generation);
            if (_folderProblem != null) return;
            await _reconcileMissingDownloads(generation);
            _checkRecovery(generation);
            if (_folderProblem != null) return;
            await _downloadQueueDao.requeueStuckDownloads();
            _checkRecovery(generation);
            if (!_readCustomDownloadFolderEnabled()) {
              await _cleanupOrphanedFiles(generation);
            }
            _checkRecovery(generation);
            await _normalizePermanentDownloads(generation);
            _checkRecovery(generation);
            _startupRecoveryPending = false;
          } on _RecoveryCancelled {
            // Teardown drains this future; another start can retry recovery.
          }
        })().whenComplete(() {
          _recoveryInFlight = null;
        });
  }

  Future<void> _startSettingsSubscriptions() async {
    for (final subscription in _settingsSubscriptions) {
      await subscription.cancel();
    }
    _settingsSubscriptions
      ..clear()
      ..add(
        _appSettingsDao.watchDownloadsPaused().listen((paused) {
          if (paused != _paused) unawaited(_applyPaused(paused));
        }),
      )
      ..add(
        _appSettingsDao.watchMaxConcurrentDownloads().listen((value) {
          if (value == _maxConcurrent) return;
          _maxConcurrent = value;
          // Lowering the limit lets running transfers finish; it only stops
          // new ones from starting.
          unawaited(_processNext());
        }),
      );
  }

  /// Versions before 1.2.8 stored Android picker fallbacks as ordinary paths.
  /// Scoped storage never granted Navis reliable access to those paths. Disable
  /// the setting instead of touching user files; the settings UI will ask for a
  /// new persisted tree grant on the next selection. Like leaving any custom
  /// folder, Navis forgets the downloads in it and leaves the files there.
  Future<void> _migrateUnsafeAndroidCustomFolder() async {
    final path = _readCustomDownloadFolderPath()?.trim();
    if (!_isAndroid ||
        !_readCustomDownloadFolderEnabled() ||
        path == null ||
        path.isEmpty ||
        _isSafRoot(path)) {
      return;
    }
    // Forgotten before the setting changes: startup normalization moves every
    // row outside the active folder into Navis's own directory.
    final leftInUserFolder = await _songIdsLeftInUserFolder();
    await _cacheDao.deleteCachedTracksBySongIds(leftInUserFolder);
    await _appSettingsDao.updateCustomDownloadFolderEnabled(enabled: false);
    await _appSettingsDao.updateCustomDownloadFolderPath(null);
    await _appSettingsDao.updateCustomDownloadFolderStorageKind('filesystem');
    AppLogger.info(
      'Disabled legacy Android custom download folder without modifying files '
      '(downloads forgotten: ${leftInUserFolder.length}); '
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
    _lifecycleGeneration++;
    _folderCheckGeneration++;
    _folderRecheckTimer?.cancel();
    _folderRecheckTimer = null;
    await _queueSubscription?.cancel();
    _queueSubscription = null;
    for (final subscription in _settingsSubscriptions) {
      await subscription.cancel();
    }
    _settingsSubscriptions.clear();
    _retryTimer?.cancel();
    _retryTimer = null;
    _cancelTransfers(_CancelReason.requeue);
    await _startInFlight;
    await _recoveryInFlight;
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
    if (enabled) _checkCustomFolderAllowed(normalizedPath!);

    if (normalizedPath case final safPath? when _isSafRoot(safPath)) {
      await _runWithQueuePaused(() async {
        final tree = await _safStorage.validateWritableTree(safPath);
        if (!tree.canRead || !tree.canWrite || !tree.canReplace) {
          throw const FileSystemException(
            'This Android folder cannot safely store Navis downloads.',
          );
        }
        final leftInUserFolder = await _songIdsLeftInUserFolder(
          targetSafTree: safPath,
        );
        await _relocatePermanentDownloadsToSaf(
          safPath,
          leaveSongIds: leftInUserFolder,
        );
        await _cacheDao.deleteCachedTracksBySongIds(leftInUserFolder);
        await _appSettingsDao.transaction(() async {
          await _appSettingsDao.updateCustomDownloadFolderPath(safPath);
          await _appSettingsDao.updateCustomDownloadFolderStorageKind(
            'androidSaf',
          );
          await _appSettingsDao.updateCustomDownloadFolderEnabled(
            enabled: enabled,
          );
        });
        _setFolderProblem(null);
      });
      return;
    }
    await _runWithQueuePaused(() async {
      final targetDirectory = await _permanentDirectory(
        customDownloadFolderEnabled: enabled,
        customDownloadFolderPath: enabled ? normalizedPath : null,
      );
      final leftInUserFolder = await _songIdsLeftInUserFolder(
        targetDirectory: enabled ? targetDirectory.path : null,
      );
      await _relocatePermanentDownloads(
        targetDirectory: targetDirectory,
        customDownloadFolderEnabled: enabled,
        customDownloadFolderPath: enabled ? normalizedPath : null,
        rollbackOnFailure: true,
        keepEntriesInsideTarget: enabled,
        leaveSongIds: leftInUserFolder,
      );
      // Forgotten before the setting changes: a row left pointing into the
      // old folder would be moved out of it by the next startup.
      await _cacheDao.deleteCachedTracksBySongIds(leftInUserFolder);
      await _appSettingsDao.transaction(() async {
        await _appSettingsDao.updateCustomDownloadFolderPath(
          enabled ? normalizedPath : null,
        );
        await _appSettingsDao.updateCustomDownloadFolderStorageKind(
          'filesystem',
        );
        await _appSettingsDao.updateCustomDownloadFolderEnabled(
          enabled: enabled,
        );
      });
      _setFolderProblem(null);
    });
  }

  Future<PermanentDownloadImportPreview> previewCustomDownloadFolder(
    String path,
  ) async {
    _checkCustomFolderAllowed(path.trim());
    return await _permanentDownloadImportService.preview(Directory(path));
  }

  /// A clone diagnostics build reads a folder outside its run as unset, so
  /// choosing one would scan and adopt the user's files and then show the
  /// folder as off (issue #45). Refuse it before any work instead.
  void _checkCustomFolderAllowed(String path) {
    if (_rejectsCustomFolder(path)) {
      throw FileSystemException(
        'A diagnostics clone can only use a download folder inside its run '
        'folder.',
        path,
      );
    }
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

  Future<void> removeDownloadedTrack(String songId) =>
      removeDownloadedTracks(<String>[songId]);

  Future<void> removeDownloadedTracks(Iterable<String> songIds) async {
    var removedPermanent = false;
    for (final songId in songIds) {
      final track = await _cacheDao.getCachedTrack(songId);
      if (track == null || track.cacheType != CacheType.permanent) {
        await _cacheDao.removeCachedTrack(songId);
        continue;
      }
      await _deletePermanentLocator(track.filePath);
      await _cacheDao.removeCachedTrack(songId);
      removedPermanent = true;
    }
    if (removedPermanent) await pruneDownloadArtwork();
  }

  /// The durable cover art of permanent downloads.
  PermanentArtworkStore get artworkStore => _artworkStore;

  /// Deletes stored cover art no permanent download uses any more.
  Future<void> pruneDownloadArtwork() async {
    try {
      final referenced = await _downloadCoverArtIds();
      if (referenced != null) await _artworkStore.prune(referenced);
    } on Object catch (error) {
      AppLogger.warning('DownloadService: Artwork prune failed: $error');
    }
  }

  /// The cover art ids of permanent downloads, or null when some download's
  /// song is not in the library (during a library rebuild, for example): a
  /// partial view must never delete a cover a download may still use.
  Future<Set<String>?> _downloadCoverArtIds() async {
    final songIds = await _cacheDao.getPermanentlyCachedSongIds();
    if (songIds.isEmpty) return const <String>{};
    final songs = await _libraryDao.getSongsByIds(songIds);
    if (songs.length < songIds.length) return null;
    return <String>{
      for (final song in songs)
        if (song.coverArt?.trim() case final id? when id.isNotEmpty) id,
    };
  }

  // ---------------------------------------------------------------------------
  // Queue control
  // ---------------------------------------------------------------------------

  /// Whether the queue is paused.
  bool get isPaused => _paused;

  /// The configured number of concurrent downloads.
  int get maxConcurrentDownloads => _maxConcurrent;

  /// Queue ids with a transfer or finish in progress.
  Set<int> get activeQueueIds => Set<int>.unmodifiable(_workers.keys);

  /// The most downloads that ran at once since the last
  /// [resetPeakActiveDownloads], for diagnostics.
  int get peakActiveDownloads => _peakActiveDownloads;
  int _peakActiveDownloads = 0;

  void resetPeakActiveDownloads() => _peakActiveDownloads = _workers.length;

  /// How many downloads may run right now: none while paused or held by the
  /// Wi-Fi-only setting, one on cellular, otherwise the user's setting.
  int get effectiveConcurrency {
    if (_paused || _folderProblem != null || !_readIsOnline()) return 0;
    final onWifi = _readIsWifi();
    if (_readWifiOnly() && !onWifi) return 0;
    return onWifi ? _maxConcurrent : 1;
  }

  /// Pauses or resumes the whole queue. Pausing returns transfers in flight
  /// to the queue; their part files are discarded.
  Future<void> setPaused({required bool paused}) async {
    await _appSettingsDao.updateDownloadsPaused(paused: paused);
    await _applyPaused(paused);
  }

  Future<void> _applyPaused(bool paused) async {
    _paused = paused;
    if (paused) {
      _cancelTransfers(_CancelReason.requeue);
      await DownloadNotifier.dismissProgress().catchError((_) {});
    } else {
      await refreshDownloadFolder();
    }
  }

  /// Saves the number of concurrent downloads and starts more if allowed.
  Future<void> setMaxConcurrentDownloads(int value) async {
    _maxConcurrent = sanitizeConcurrentDownloads(value);
    await _appSettingsDao.updateMaxConcurrentDownloads(_maxConcurrent);
    await _processNext();
  }

  /// Removes one queue item, stopping its transfer if one is in flight. The
  /// partial file is deleted and nothing is registered.
  Future<void> cancelQueueItem(int id) async {
    _retryNotBefore.remove(id);
    if (_workers.containsKey(id)) {
      _cancelReasons[id] = _CancelReason.remove;
      _activeTransfers[id]?.cancel('Download cancelled');
    }
    await _downloadQueueDao.remove(id);
  }

  /// Removes every queue item, stopping transfers in flight.
  Future<void> clearQueue() async {
    _retryNotBefore.clear();
    _cancelTransfers(_CancelReason.remove);
    await _downloadQueueDao.clearQueue();
  }

  /// Cancels every claimed item. Items without a transfer yet see the reason
  /// before they start one.
  void _cancelTransfers(_CancelReason reason) {
    for (final id in _workers.keys) {
      _cancelReasons[id] = reason;
      _activeTransfers[id]?.cancel(reason.name);
    }
  }

  Future<void> _startQueueSubscription() async {
    await _queueSubscription?.cancel();
    _queueSubscription = _downloadQueueDao.watchQueue().listen((_) {
      unawaited(_processNext());
    });
    unawaited(_processNext());
  }

  /// Trigger queue processing after external conditions change, and complete
  /// once no download is running: the queue is empty, held (paused, Wi-Fi
  /// only), or waiting out a retry backoff.
  ///
  /// The internal processing and Wi-Fi guards remain authoritative, so callers
  /// can invoke this optimistically when settings or connectivity change.
  Future<void> processQueuedDownloads() async {
    if (await _checkDownloadFolder()) await _recoverStartup();
    await _processNext();
    await _waitForIdle();
  }

  Future<void> _waitForIdle() async {
    while (true) {
      if (_workers.isNotEmpty) {
        await Future.wait<void>(_workers.values.toList(growable: false));
      } else if (_pumping) {
        await Future<void>.delayed(Duration.zero);
      } else {
        return;
      }
    }
  }

  Future<T> _runWithQueuePaused<T>(Future<T> Function() action) async {
    if (_maintenanceInProgress) {
      throw StateError('Download maintenance is already in progress.');
    }
    _maintenanceInProgress = true;
    final hadSubscription = _queueSubscription != null;
    await _queueSubscription?.cancel();
    _queueSubscription = null;
    _cancelTransfers(_CancelReason.requeue);
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
    while (_workers.isNotEmpty || _pumping) {
      if (_workers.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        continue;
      }
      await Future.wait<void>(_workers.values.toList(growable: false));
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
    final folderUsable = await _checkRequestedFolder();
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
      final song = libraryRows.firstOrNull;
      if (cached != null &&
          cached.cacheType == CacheType.permanent &&
          _isCacheQualityCompatible(cached, quality, format, song: song)) {
        return;
      }

      // Smart download: if the song is in rolling cache with a compatible
      // quality, promote it to permanent storage instead of re-downloading.
      if (folderUsable &&
          cached != null &&
          cached.cacheType == CacheType.rolling) {
        if (_isCacheQualityCompatible(cached, quality, format, song: song)) {
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
    if (_folderProblem != null) await _recordQueueHold();
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
    return await _batchEnqueue(
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
    return await _batchEnqueue(
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
    final folderUsable = await _checkRequestedFolder();
    // Batch dedup: one query per data source instead of N queries per song.
    final activeSongIds = await _downloadQueueDao.getActiveSongIds();
    final cachedTracks = await _cacheDao.getCachedTracksForSongIds(songIds);
    final songsById = <String, SongsTableData>{
      for (final song in await _libraryDao.getSongsByIds(songIds))
        song.id: song,
    };

    final toEnqueue = <DownloadQueueTableCompanion>[];
    var promotedCount = 0;

    for (final songId in songIds) {
      // Skip if already queued or downloading.
      if (activeSongIds.contains(songId)) continue;

      // Skip if already permanently cached.
      final cached = cachedTracks[songId];
      final song = songsById[songId];
      if (cached?.cacheType == CacheType.permanent &&
          _isCacheQualityCompatible(cached!, quality, format, song: song)) {
        continue;
      }

      // Try rolling → permanent promotion.
      if (folderUsable &&
          cached?.cacheType == CacheType.rolling &&
          _isCacheQualityCompatible(cached!, quality, format, song: song)) {
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
      if (folderUsable) {
        final expected = toEnqueue.fold<int>(0, (sum, item) {
          final song = songsById[item.songId.value];
          return sum + (song == null ? 0 : _expectedBytes(song, quality));
        });
        if (expected > 0) await _checkSpace(expected, notice: true);
      }
      await _downloadQueueDao.enqueueBatch(toEnqueue);
      if (_folderProblem != null) await _recordQueueHold();
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
    // Keep metadata access asynchronous so storage latency cannot stall UI.
    // ignore: avoid_slow_async_io
    if (!await file.exists()) return false;

    final song = (await _libraryDao.getSongsByIds(<String>[songId]))
        .firstOrNull;
    late String newPath;
    try {
      if (!await _checkSpace(await file.length())) return false;
      newPath = await _resolvePermanentPathForEntry(
        songId: songId,
        song: song,
        format: _resolveStoredFormat(track, song: song),
      );
      final destination = File(newPath);
      await Directory(p.dirname(newPath)).create(recursive: true);
      // A file already at the destination is reused only when it is a whole
      // copy; anything else is replaced through a part file.
      // Keep storage latency off the UI isolate.
      // ignore: avoid_slow_async_io
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
      await _holdForFolderFailure(e);
      AppLogger.warning(
        'DownloadService: Failed to copy to permanent: ${e.runtimeType}',
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
    final api = _readApiClient();
    if (song != null && api != null) {
      _trackBackgroundTask(_precacheCoverArt(song, api));
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
  ///   cached entry is compatible when it is original: no bitrate, or the
  ///   song's own format at no less than its bitrate (see
  ///   [isOriginalQualityDownload]).
  bool _isCacheQualityCompatible(
    CachedTracksTableData cached,
    String? requestedQuality,
    String? requestedFormat, {
    SongsTableData? song,
  }) {
    final requestedBitRate = requestedQuality != null
        ? int.tryParse(requestedQuality)
        : null;

    // User wants "original" quality (no transcoding).
    if (requestedBitRate == null && requestedFormat == null) {
      return isOriginalQualityDownload(
        format: cached.format,
        bitRate: cached.bitRate,
        songSuffix: song?.suffix,
        songBitRate: song?.bitRate,
      );
    }

    // Check format compatibility.
    if (requestedFormat != null &&
        !sameAudioFormat(cached.format, requestedFormat)) {
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

  /// Starts queued downloads until [effectiveConcurrency] are running.
  ///
  /// Called whenever the queue, the network, or a setting changes, and when a
  /// worker finishes. Items still in their retry backoff are skipped, and a
  /// timer starts the pump again when the earliest backoff ends.
  Future<void> _processNext() async {
    if (_pumping) {
      _pumpRequested = true;
      return;
    }
    _pumping = true;
    try {
      do {
        _pumpRequested = false;
        await _fillWorkers();
      } while (_pumpRequested && !_stopped);
    } finally {
      _pumping = false;
    }
  }

  Future<void> _fillWorkers() async {
    if (_stopped ||
        _maintenanceInProgress ||
        _folderProblem != null ||
        !_readIsOnline()) {
      if (!_readIsOnline()) _retryTimer?.cancel();
      return;
    }
    final queue = await _downloadQueueDao.getQueuedItems();
    if (queue.isNotEmpty && !await _checkDownloadFolder()) return;
    if (_startupRecoveryPending) {
      await _recoverStartup();
      if (_startupRecoveryPending) return;
    }
    if (_workers.length >= effectiveConcurrency) {
      if (effectiveConcurrency == 0) {
        AppLogger.debug('DownloadService: queue held (paused or Wi-Fi only)');
      }
      return;
    }
    final now = DateTime.now();
    DateTime? nextRetry;
    for (final item in queue) {
      if (_stopped || _maintenanceInProgress) return;
      if (_workers.length >= effectiveConcurrency) break;
      if (_workers.containsKey(item.id)) continue;
      final notBefore = _retryNotBefore[item.id];
      if (notBefore != null && notBefore.isAfter(now)) {
        if (nextRetry == null || notBefore.isBefore(nextRetry)) {
          nextRetry = notBefore;
        }
        continue;
      }
      _retryNotBefore.remove(item.id);
      if (item.songId == null) {
        // Malformed entry — remove.
        await _downloadQueueDao.remove(item.id);
        continue;
      }
      _startWorker(item);
    }
    _retryTimer?.cancel();
    _retryTimer = nextRetry == null
        ? null
        : Timer(nextRetry.difference(now), () {
            if (!_stopped) unawaited(_processNext());
          });
  }

  void _startWorker(DownloadQueueTableData item) {
    final worker = _downloadItem(item)
        .catchError((Object error, StackTrace stackTrace) {
          AppLogger.warning(
            'DownloadService: Worker for ${item.songId} failed: '
            '$error\n$stackTrace',
          );
        })
        .whenComplete(() {
          _workers.removeWhere((id, _) => id == item.id);
          _cancelReasons.remove(item.id);
          if (!_stopped) unawaited(_processNext());
        });
    _workers[item.id] = worker;
    if (_workers.length > _peakActiveDownloads) {
      _peakActiveDownloads = _workers.length;
    }
  }

  /// Runs [action] after every earlier finishing step has completed.
  Future<T> _serializedFinalize<T>(Future<T> Function() action) {
    final previous = _finalizeTail;
    final done = Completer<void>();
    _finalizeTail = done.future;
    return previous.then((_) => action()).whenComplete(done.complete);
  }

  void _reportTransferProgress(int id, String title, int received, int total) {
    _transferProgress[id] = (title: title, received: received, total: total);
    final transfers = _transferProgress.values;
    final totalBytes = transfers.fold<int>(0, (sum, t) => sum + t.total);
    final receivedBytes = transfers.fold<int>(0, (sum, t) => sum + t.received);
    unawaited(
      DownloadNotifier.showProgress(
        readLocalizations: _readLocalizations,
        title: (l10n) => transfers.length == 1
            ? transfers.single.title
            : l10n.notificationDownloadProgressMultiple(transfers.length),
        received: receivedBytes,
        total: totalBytes,
      ),
    );
  }

  /// Forgets [id]'s progress; the notification goes when no transfer is left.
  Future<void> _endTransferProgress(int id) async {
    _transferProgress.remove(id);
    if (_transferProgress.isEmpty) {
      await DownloadNotifier.dismissProgress().catchError((_) {});
    }
  }

  Future<void> _downloadItem(DownloadQueueTableData item) async {
    final songId = item.songId!;
    // Resolve destination file early so we can clean up on failure. The
    // download is written to [partFile] and renamed to [destFile] only when
    // complete, so an interrupted download never looks like a finished file.
    File? destFile;
    File? partFile;
    var renamed = false;
    var registered = false;
    String? reservedPath;

    try {
      if (await _completeFromCompatibleCache(item) || _folderProblem != null) {
        return;
      }
      final api = _readApiClient();
      if (api == null) {
        AppLogger.warning('DownloadService: No API client, skipping $songId');
        await _handleFailure(
          item,
          DownloadFailureReason.network,
          detail: 'No server connection',
        );
        return;
      }

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

      // Cancelled (removed, paused, stopped) before the transfer started.
      if (_stopped || _cancelReasons.containsKey(item.id)) {
        if (_cancelReasons[item.id] == _CancelReason.remove) {
          await _downloadQueueDao.remove(item.id);
        }
        return;
      }

      final expected = _expectedBytes(song, item.quality);
      final hasSpace = await _serializedFinalize(() async {
        if (_folderProblem != null) return false;
        if (!await _checkSpace(expected)) return false;
        _spaceReservations[item.id] = expected + expected ~/ 10;
        return true;
      });
      if (!hasSpace) {
        await _downloadQueueDao.recordFailure(
          item.id,
          _holdReason ?? DownloadFailureReason.noSpace,
          status: DownloadStatus.queued,
        );
        return;
      }
      // Mark as downloading.
      await _downloadQueueDao.updateStatus(item.id, DownloadStatus.downloading);

      final downloadUri = _resolveDownloadUri(
        api: api,
        songId: songId,
        quality: item.quality,
        format: item.format,
      );
      final resolvedDest = destFile = await _resolveDownloadFile(song, item);
      reservedPath = resolvedDest.path;
      _reservedDownloadPaths.add(reservedPath);
      final part = File('${resolvedDest.path}$downloadPartSuffix');
      // An existing part name in a user folder is not proof of ownership.
      // Refuse it before Dio can truncate it or failure cleanup can remove it.
      // Keep storage latency off the UI isolate.
      // ignore: avoid_slow_async_io
      if (await FileSystemEntity.type(part.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw FileSystemException(
          'The temporary download name is occupied.',
          part.path,
        );
      }
      await _downloadQueueDao.writeFinishJournal(
        item.id,
        jsonEncode({'phase': 'transferring', 'partPath': part.path}),
      );
      partFile = part;

      final cancelToken = _activeTransfers[item.id] = CancelToken();
      if (_cancelReasons[item.id] case final reason?) {
        cancelToken.cancel(reason.name);
      }
      // Dio reports every received chunk. Persist progress at most twice a
      // second, in whole percent steps: each write re-emits the download
      // queue and album download badges to every watching screen.
      var lastPersistedProgress = -1.0;
      final sincePersisted = Stopwatch()..start();
      final response = await _dio.downloadUri(
        downloadUri,
        part.path,
        cancelToken: cancelToken,
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
            _reportTransferProgress(item.id, songTitle, received, total);
          }
        },
      );
      _activeTransfers.remove(item.id);

      if (_stopped) {
        await tryDeleteFile(partFile);
        return;
      }

      final statusCode = response.statusCode;
      final contentType = response.headers.value(Headers.contentTypeHeader);
      if (statusCode != null &&
          statusCode >= 200 &&
          statusCode < 300 &&
          isNonAudioContentType(contentType)) {
        // A Subsonic error document (XML/JSON/HTML) with a success status is
        // never registered as audio.
        await tryDeleteFile(partFile);
        await _handleFailure(
          item,
          DownloadFailureReason.notAudio,
          detail: 'Non-audio response',
        );
      } else if (statusCode != null && statusCode >= 200 && statusCode < 300) {
        final transcoded = item.quality != null || item.format != null;
        final requestedFormat = _resolveFormat(song, item);
        // The server names what it actually sent: a server without the
        // requested encoder may send the original file instead.
        final format = transcoded
            ? downloadedFormatFor(
                requested: requestedFormat,
                contentType: contentType,
              )
            : requestedFormat;
        final bitRate = format == requestedFormat
            ? _resolveBitRate(song, item)
            : song.bitRate;
        final written = await part.length();
        final contentLength = int.tryParse(
          response.headers.value(Headers.contentLengthHeader) ?? '',
        );
        if (written == 0 ||
            (!transcoded &&
                contentLength != null &&
                written != contentLength)) {
          await tryDeleteFile(part);
          await _handleFailure(
            item,
            DownloadFailureReason.truncated,
            detail: contentLength == null
                ? 'Empty file'
                : '$written / $contentLength bytes',
          );
          return;
        }
        var target = resolvedDest;
        await _serializedFinalize(() async {
          if (_stopped || _cancelReasons[item.id] == _CancelReason.remove) {
            await tryDeleteFile(part);
            if (!_stopped) await _downloadQueueDao.remove(item.id);
            return;
          }
          if (format != requestedFormat &&
              !_isSafRoot(_readCustomDownloadFolderPath())) {
            target = File(
              await _permanentPathResolver.resolveSongPath(
                song: song,
                extension: format,
                reservedPaths: _reservedDownloadPaths,
              ),
            );
          }
          await _writeFinishIntent(item, target.path, part, format, bitRate);
          await _renameIntoPlace(part, target);
          destFile = target;
          renamed = true;
          // Tag before measuring, so the registered size is the final one.
          // Tags only help a later rescan; they never cost the download.
          try {
            await _permanentDownloadImportService.writeIdentityTags(
              target,
              songId,
            );
          } on Object catch (error) {
            AppLogger.warning(
              'DownloadService: Identity tags not written for $songId: $error',
            );
          }
          // Register in cached_tracks as permanent.
          // Keep metadata access asynchronous so storage latency cannot stall UI.
          // ignore: avoid_slow_async_io
          final stat = await target.stat();
          await _writeFinishIntent(
            item,
            target.path,
            target,
            format,
            bitRate,
            phase: 'published',
            publicationLocator: target.path,
          );
          _reportNetworkUsage?.call(
            category: NetworkUsageCategory.download,
            bytes: stat.size,
          );

          var locator = target.path;
          String? treeUri;
          String? relativePath;
          if (_isSafRoot(_readCustomDownloadFolderPath())) {
            treeUri = _readCustomDownloadFolderPath()!;
            relativePath = _safRelativePathFor(song, format);
            if (await _safStorage.findDocument(
                  treeUri: treeUri,
                  relativePath: relativePath,
                ) !=
                null) {
              throw const FileSystemException(
                'A document with this name already exists.',
              );
            }
            await _writeFinishIntent(
              item,
              target.path,
              target,
              format,
              bitRate,
              treeUri: treeUri,
              relativePath: relativePath,
            );
            locator = await _safStorage.writeFromFile(
              treeUri: treeUri,
              relativePath: relativePath,
              source: target,
              mimeType: _mimeTypeFor(format),
              replace: false,
            );
          }
          if (treeUri != null) {
            await _writeFinishIntent(
              item,
              target.path,
              target,
              format,
              bitRate,
              treeUri: treeUri,
              relativePath: relativePath,
              phase: 'published',
              publicationLocator: locator,
            );
          }
          await _registerFinished(
            item,
            locator,
            stat.size,
            format,
            bitRate,
            isSaf: treeUri != null,
          );
          registered = true;
          await _recordFinishedSidecar(
            songId,
            locator,
            stat.size,
            format,
            treeUri: treeUri,
            relativePath: relativePath,
          );
          if (treeUri != null) await tryDeleteFile(target);

          // Keep cover art alongside the audio (best-effort).
          _trackBackgroundTask(_precacheCoverArt(song, api));

          _trackBackgroundTask(
            DownloadNotifier.showComplete(
              readLocalizations: _readLocalizations,
              title: (l10n) =>
                  l10n.notificationDownloadCompleteTitle(songTitle),
            ).catchError((_) {}),
          );

          // Best-effort: pre-fetch lyrics so they're available offline.
          _trackBackgroundTask(_prefetchLyrics(songId, song, api));

          AppLogger.info(
            'DownloadService: Completed download for $songId '
            '(${stat.size} bytes, $format)',
          );
        });
      } else {
        await tryDeleteFile(partFile);
        if (statusCode == 404 || statusCode == 410) {
          await _libraryDao.markSongsSuspectedMissing(<String>[songId]);
        }
        await _handleFailure(
          item,
          _httpFailure(statusCode),
          detail: 'HTTP $statusCode',
        );
      }
    } on DownloadFolderUnavailableException catch (error) {
      await tryDeleteFile(partFile);
      if (_isNoSpaceError(error)) {
        await _handleFileFailure(item, error);
      } else {
        _setFolderProblem(error.problem);
        await _downloadQueueDao.recordFailure(
          item.id,
          _holdReason!,
          status: DownloadStatus.queued,
        );
      }
    } on FileSystemException catch (error) {
      await tryDeleteFile(partFile);
      if (renamed && !registered) await tryDeleteFile(destFile);
      await _handleFileFailure(item, error);
    } on DioException catch (error) {
      await tryDeleteFile(partFile);
      if (error.type == DioExceptionType.cancel) {
        if (_cancelReasons[item.id] == _CancelReason.remove) {
          await _downloadQueueDao.remove(item.id);
        } else if (!_stopped) {
          await _downloadQueueDao.updateStatus(item.id, DownloadStatus.queued);
          if (_holdReason case final reason?) {
            await _downloadQueueDao.recordFailure(
              item.id,
              reason,
              status: DownloadStatus.queued,
            );
          }
        }
      } else if (error.error case final FileSystemException fileError) {
        await _handleFileFailure(item, fileError);
      } else {
        final code = error.response?.statusCode;
        if (code == 404 || code == 410) {
          await _libraryDao.markSongsSuspectedMissing(<String>[songId]);
        }
        final reason = code != null
            ? _httpFailure(code)
            : switch (error.type) {
                DioExceptionType.connectionTimeout ||
                DioExceptionType.sendTimeout ||
                DioExceptionType.receiveTimeout =>
                  DownloadFailureReason.timeout,
                DioExceptionType.connectionError =>
                  DownloadFailureReason.network,
                _ => DownloadFailureReason.unknown,
              };
        await _handleFailure(
          item,
          reason,
          detail: code == null ? error.type.name : 'HTTP $code',
        );
      }
    } on Object catch (error) {
      await tryDeleteFile(partFile);
      if (renamed && !registered) await tryDeleteFile(destFile);
      await _handleFailure(
        item,
        DownloadFailureReason.unknown,
        detail: error.runtimeType.toString(),
      );
    } finally {
      _spaceReservations.remove(item.id);
      _activeTransfers.remove(item.id);
      if (reservedPath != null) _reservedDownloadPaths.remove(reservedPath);
      await _endTransferProgress(item.id);
    }
  }

  Future<void> _writeFinishIntent(
    DownloadQueueTableData item,
    String path,
    File verifiedFile,
    String format,
    int? bitRate, {
    String? treeUri,
    String? relativePath,
    String phase = 'verified',
    String? publicationLocator,
    int? recoveryGeneration,
  }) async {
    final digest = await sha256.bind(verifiedFile.openRead()).first;
    final size = await verifiedFile.length();
    _checkRecovery(recoveryGeneration);
    await _downloadQueueDao.writeFinishJournal(
      item.id,
      jsonEncode({
        'phase': phase,
        'publicationLocator': publicationLocator,
        'path': path,
        'partPath': verifiedFile.path.endsWith(downloadPartSuffix)
            ? verifiedFile.path
            : '$path$downloadPartSuffix',
        'size': size,
        'sha256': digest.toString(),
        'format': format,
        'bitRate': bitRate,
        'treeUri': treeUri,
        'relativePath': relativePath,
      }),
    );
  }

  Future<void> _registerFinished(
    DownloadQueueTableData item,
    String locator,
    int size,
    String format,
    int? bitRate, {
    bool isSaf = false,
    int? recoveryGeneration,
  }) => _downloadQueueDao.transaction(() async {
    _checkRecovery(recoveryGeneration);
    await _cacheDao.upsertCachedTrack(
      CachedTracksTableCompanion.insert(
        songId: item.songId!,
        filePath: locator,
        storageKind: Value(isSaf ? 'androidSaf' : 'filesystem'),
        fileSize: size,
        format: format,
        bitRate: Value(bitRate),
        cacheType: CacheType.permanent,
        downloadStatus: DownloadStatus.complete,
        lastAccessedAt: DateTime.now(),
      ),
    );
    _checkRecovery(recoveryGeneration);
    await _downloadQueueDao.remove(item.id);
    _checkRecovery(recoveryGeneration);
  });

  Future<void> _recordFinishedSidecar(
    String songId,
    String locator,
    int size,
    String format, {
    String? treeUri,
    String? relativePath,
  }) async {
    try {
      if (treeUri != null && relativePath != null) {
        await _permanentDownloadImportService.recordDownloadedSafEntries(
          treeUri: treeUri,
          entries: [
            (
              relativePath: relativePath,
              fileSize: size,
              songId: songId,
              format: format,
            ),
          ],
        );
      } else {
        await _permanentDownloadImportService.recordDownloaded(
          root: await _permanentDirectory(),
          file: File(locator),
          songId: songId,
          format: format,
        );
      }
    } on Object catch (error) {
      AppLogger.warning(
        'Download folder index could not be updated: ${error.runtimeType}',
      );
    }
  }

  /// Replays only files whose bytes match the verified, owned finish intent.
  /// A part file is deliberately never resumed, even when it is complete.
  Future<void> _reconcileFinishedDownloads(int generation) async {
    for (final item in await _downloadQueueDao.watchQueue().first) {
      _checkRecovery(generation);
      if (item.finishJournal == null || item.songId == null) continue;
      File? staged;
      try {
        final journal = jsonDecode(item.finishJournal!) as Map<String, dynamic>;
        if (journal['phase'] == 'conflict') continue;
        if (journal['phase'] == 'transferring') {
          await _downloadQueueDao.retry(item.id);
          continue;
        }
        final path = journal['path'] as String;
        final size = journal['size'] as int;
        final format = journal['format'] as String;
        final treeUri = journal['treeUri'] as String?;
        final relativePath = journal['relativePath'] as String?;
        String? locator = path;
        if (treeUri != null && relativePath != null) {
          locator = await _safStorage.findDocument(
            treeUri: treeUri,
            relativePath: relativePath,
          );
          if (locator != null) staged = await _safStorage.materialize(locator);
        }
        final file = staged ?? File(path);
        final exists =
            locator != null && await _filesystemDownloadExists(file.path);
        final publicationMatches =
            journal['publicationLocator'] == null ||
            journal['publicationLocator'] == locator;
        final valid =
            publicationMatches &&
            exists &&
            size > 0 &&
            await file.length() == size &&
            (await sha256.bind(file.openRead()).first).toString() ==
                journal['sha256'];
        _checkRecovery(generation);
        if (valid) {
          if (treeUri == null) {
            try {
              await _permanentDownloadImportService.writeIdentityTags(
                file,
                item.songId!,
              );
            } on Object catch (error) {
              AppLogger.warning(
                'Recovered download tags could not be written: ${error.runtimeType}',
              );
            }
            await _writeFinishIntent(
              item,
              path,
              file,
              format,
              journal['bitRate'] as int?,
              phase: 'published',
              publicationLocator: path,
              recoveryGeneration: generation,
            );
          }
          final finishedSize = await file.length();
          await _registerFinished(
            item,
            locator,
            finishedSize,
            format,
            journal['bitRate'] as int?,
            isSaf: treeUri != null,
            recoveryGeneration: generation,
          );
          _checkRecovery(generation);
          await _recordFinishedSidecar(
            item.songId!,
            locator,
            finishedSize,
            format,
            treeUri: treeUri,
            relativePath: relativePath,
          );
          _checkRecovery(generation);
          if (treeUri != null) await tryDeleteFile(File(path));
        } else {
          // A pathname intent, even after publication, cannot prove ownership
          // of replacement contents. Preserve conflicts and their references
          // so the private orphan sweep also leaves them alone.
          if (exists) {
            AppLogger.warning(
              'Leaving mismatching finish destination unchanged.',
            );
            await _downloadQueueDao.writeFinishJournal(
              item.id,
              jsonEncode({...journal, 'phase': 'conflict'}),
            );
            await _downloadQueueDao.updateStatus(
              item.id,
              DownloadStatus.queued,
            );
          } else {
            await _downloadQueueDao.retry(item.id);
          }
          _checkRecovery(generation);
          if (treeUri != null) await tryDeleteFile(File(path));
        }
      } on FileSystemException catch (error) {
        _checkRecovery(generation);
        // Inaccessible storage is not missing: keep the intent for repair.
        await _holdForFolderFailure(error);
      } on FormatException {
        _checkRecovery(generation);
        await _downloadQueueDao.retry(item.id);
      } finally {
        await tryDeleteFile(staged);
      }
    }
  }

  /// Unlike stat/exists, length exposes permission and I/O errors. Only an
  /// explicit missing-path errno permits forgetting a permanent download.
  Future<bool> _filesystemDownloadExists(String path) async {
    try {
      await File(path).length();
      return true;
    } on FileSystemException catch (error) {
      final missingCodes = Platform.isWindows ? const [2, 3] : const [2];
      if (missingCodes.contains(error.osError?.errorCode)) return false;
      rethrow;
    }
  }

  Future<void> _reconcileMissingDownloads(int generation) async {
    for (final entry in await _cacheDao.getPermanentEntries()) {
      _checkRecovery(generation);
      try {
        final exists = _isSafRoot(entry.filePath)
            ? await _safStorage.exists(entry.filePath)
            : await _filesystemDownloadExists(entry.filePath);
        _checkRecovery(generation);
        if (exists) continue;
        final song = (await _libraryDao.getSongsByIds([entry.songId]))
            .firstOrNull;
        await _downloadQueueDao.transaction(() async {
          _checkRecovery(generation);
          await _cacheDao.removeCachedTrack(entry.songId);
          _checkRecovery(generation);
          if (song == null ||
              song.serverDeletedAt != null ||
              await _downloadQueueDao.findBySongId(entry.songId) != null) {
            return;
          }
          _checkRecovery(generation);
          await _downloadQueueDao.enqueue(
            DownloadQueueTableCompanion.insert(
              songId: Value(entry.songId),
              status: DownloadStatus.queued,
              addedAt: DateTime.now(),
              format: Value(entry.format),
              quality: Value(entry.bitRate?.toString()),
            ),
          );
          _checkRecovery(generation);
        });
      } on FileSystemException catch (error) {
        _checkRecovery(generation);
        await _holdForFolderFailure(error);
      }
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

  /// Removes private staging parts and exact, persisted owned parts in the
  /// active user folder. SAF transfers never create parts in the user's tree.
  Future<void> _removePartialDownloads(int generation) async {
    try {
      final saf = _isSafRoot(_readCustomDownloadFolderPath());
      final root = saf
          ? await _permanentPathResolver.resolveDefaultRoot()
          : await _permanentDirectory();
      final ownedPaths = <String>{};
      for (final item in await _downloadQueueDao.watchQueue().first) {
        if (item.finishJournal == null) continue;
        try {
          final journal =
              jsonDecode(item.finishJournal!) as Map<String, dynamic>;
          if (journal['partPath'] case final String path) ownedPaths.add(path);
        } on FormatException {
          // An unreadable journal cannot establish ownership.
        }
      }
      final identity = await DownloadRootIdentity.resolve(root.path);
      final ownedKeys = {
        for (final path in ownedPaths)
          if (identity.keyFor(path) case final key?) identity.lookupKey(key),
      };
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File || !entity.path.endsWith(downloadPartSuffix)) {
          continue;
        }
        if (_readCustomDownloadFolderEnabled() && !saf) {
          final key = identity.keyFor(entity.path);
          final resolved = await entity.resolveSymbolicLinks();
          if (key == null ||
              !ownedKeys.contains(identity.lookupKey(key)) ||
              !p.isWithin(identity.canonicalRoot, resolved)) {
            AppLogger.warning(
              'Leaving an unowned temporary file in the download folder.',
            );
            continue;
          }
        }
        _checkRecovery(generation);
        await tryDeleteFile(entity);
      }
    } on _RecoveryCancelled {
      rethrow;
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
        : !await _filesystemDownloadExists(cached.filePath)) {
      await _cacheDao.removeCachedTrack(songId);
      return false;
    }

    final song = (await _libraryDao.getSongsByIds(<String>[songId]))
        .firstOrNull;
    if (!_isCacheQualityCompatible(
      cached,
      item.quality,
      item.format,
      song: song,
    )) {
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
    // The cache entry above speeds up the first display; the durable copy
    // serves offline browsing and the system media controls for as long as
    // the download exists.
    await _artworkStore.ensure(coverArtId, api);
  }

  DownloadFailureReason _httpFailure(int? code) => switch (code) {
    404 || 410 => DownloadFailureReason.notFound,
    401 || 403 => DownloadFailureReason.permission,
    final int code when code >= 500 => DownloadFailureReason.serverError,
    _ => DownloadFailureReason.unknown,
  };

  Future<void> _handleFileFailure(
    DownloadQueueTableData item,
    FileSystemException error,
  ) async {
    final previous = _folderProblem;
    if (await _holdForFolderFailure(error)) {
      await _downloadQueueDao.recordFailure(
        item.id,
        _holdReason!,
        status: DownloadStatus.queued,
      );
      if (previous != _folderProblem) await _notifyHeldFailure(_holdReason!);
    } else {
      await _handleFailure(
        item,
        DownloadFailureReason.unknown,
        detail: 'File write failed',
      );
    }
  }

  Future<void> _notifyHeldFailure(DownloadFailureReason reason) =>
      DownloadNotifier.showFailed(
        readLocalizations: _readLocalizations,
        title: (l10n) => l10n.notificationDownloadHeldTitle,
        reason: (l10n) => downloadFailureMessage(l10n, reason),
      ).catchError((_) {});

  Future<void> _handleFailure(
    DownloadQueueTableData item,
    DownloadFailureReason reason, {
    String? detail,
  }) async {
    await _downloadQueueDao.writeFinishJournal(item.id, null);
    final retryable = switch (reason) {
      DownloadFailureReason.notFound ||
      DownloadFailureReason.notAudio ||
      DownloadFailureReason.permission ||
      DownloadFailureReason.folderUnavailable ||
      DownloadFailureReason.noSpace => false,
      _ => true,
    };
    // HTTP access denial is also an explicit-action hold, never backoff.
    if (reason == DownloadFailureReason.permission) {
      final previous = _folderProblem;
      _setFolderProblem(DownloadFolderProblem.inaccessible, recheck: false);
      await _downloadQueueDao.recordFailure(
        item.id,
        reason,
        detail: detail,
        status: DownloadStatus.queued,
      );
      if (previous != _folderProblem) await _notifyHeldFailure(reason);
      return;
    }
    if (retryable && !_readIsOnline()) {
      _retryNotBefore.remove(item.id);
      await _downloadQueueDao.recordFailure(
        item.id,
        reason,
        detail: detail,
        status: DownloadStatus.queued,
      );
      return;
    }
    if (retryable && item.retryCount < maxRetries) {
      _retryNotBefore[item.id] = DateTime.now().add(
        Duration(seconds: 5 * (1 << item.retryCount)),
      );
      await _downloadQueueDao.recordFailure(
        item.id,
        reason,
        detail: detail,
        status: DownloadStatus.queued,
      );
      await _downloadQueueDao.markForRetry(item.id);
    } else {
      await _downloadQueueDao.recordFailure(item.id, reason, detail: detail);
      await DownloadNotifier.showFailed(
        readLocalizations: _readLocalizations,
        reason: (l10n) => downloadFailureMessage(l10n, reason),
      ).catchError((_) {});
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
  Future<void> _cleanupOrphanedFiles(int generation) async {
    try {
      final permDir = await _permanentDirectory();
      // Keep metadata access asynchronous so storage latency cannot stall UI.
      // ignore: avoid_slow_async_io
      if (!await permDir.exists()) return;

      final knownEntries = await _cacheDao.getPermanentEntries();
      final pendingPaths = <String>{
        for (final item in await _downloadQueueDao.watchQueue().first)
          if (item.finishJournal case final journal?)
            (jsonDecode(journal) as Map<String, dynamic>)['path'] as String,
      };
      // Compared by key, so a stored path spelled differently (letter case
      // on Windows, a linked folder) never gets a real download deleted.
      final identity = await DownloadRootIdentity.resolve(permDir.path);
      final knownKeys = <String>{
        for (final path in [
          ...knownEntries.map((entry) => entry.filePath),
          ...pendingPaths,
        ])
          if (identity.keyFor(path) case final key?) identity.lookupKey(key),
      };

      await for (final entity in permDir.list(
        recursive: true,
        followLinks: false,
      )) {
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
          _checkRecovery(generation);
          await deleteFileWithSuffixes(basePath);
        }
      }
    } on _RecoveryCancelled {
      rethrow;
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
        if (_lrclibClient.isRateLimited) {
          AppLogger.info(
            'DownloadService: Lyrics backfill paused for LRCLIB cooldown.',
          );
          return;
        }

        if (_stopped) {
          return;
        }

        // Throttle to avoid hammering the server or LrcLib.
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      AppLogger.info('DownloadService: Lyrics backfill complete.');
    } on Object catch (e) {
      AppLogger.warning('DownloadService: Lyrics backfill error: $e');
    }
  }

  /// On app boot, stores the cover art of permanent downloads that have none
  /// yet (downloads from before the artwork store, and adopted files), then
  /// deletes stored covers no download uses. Fetches only on Wi-Fi. Never
  /// throws.
  Future<void> _backfillArtworkForDownloadedSongs() async {
    try {
      final referenced = await _downloadCoverArtIds();
      if (referenced != null) await _artworkStore.prune(referenced);
      final permanentIds = await _cacheDao.getPermanentlyCachedSongIds();
      final coverArtIds = <String>{
        for (final song in await _libraryDao.getSongsByIds(permanentIds))
          if (song.coverArt?.trim() case final id? when id.isNotEmpty) id,
      };
      final api = _readApiClient();
      if (api == null || !_readIsWifi()) return;
      var stored = 0;
      for (final id in coverArtIds) {
        if (_stopped) return;
        if (await _artworkStore.fileFor(id) != null) continue;
        if (await _artworkStore.ensure(id, api)) stored++;
        // Throttle to avoid hammering the server.
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (stored > 0) {
        AppLogger.info(
          'DownloadService: Artwork backfill stored $stored covers.',
        );
      }
    } on Object catch (e) {
      AppLogger.warning('DownloadService: Artwork backfill error: $e');
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
        useLrclib: _readLyricsAllowed(),
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

  Future<void> _normalizePermanentDownloads(int generation) async {
    if (_isSafRoot(_readCustomDownloadFolderPath())) {
      return;
    }
    try {
      final targetDirectory = await _permanentDirectory();
      final customDownloadFolderEnabled = _readCustomDownloadFolderEnabled();
      await _relocatePermanentDownloads(
        targetDirectory: targetDirectory,
        recoveryGeneration: generation,
        customDownloadFolderEnabled: customDownloadFolderEnabled,
        customDownloadFolderPath: _readCustomDownloadFolderPath(),
        // A custom root is user-owned: files already inside it, including
        // adopted ones, keep their names and are never rewritten.
        keepEntriesInsideTarget: customDownloadFolderEnabled,
      );
    } on _RecoveryCancelled {
      rethrow;
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'DownloadService: Permanent download normalization failed: '
        '$error\n$stackTrace',
      );
    }
  }

  /// Permanent downloads in the user folder Navis is about to stop using: the
  /// active custom folder, and any Android folder documents, except those
  /// inside the new target. The folder is the user's, whether Navis downloaded
  /// a file or adopted it, so those files stay where they are and Navis only
  /// forgets them. The folder's index still names them, so choosing the folder
  /// again adopts them back.
  Future<Set<String>> _songIdsLeftInUserFolder({
    String? targetDirectory,
    String? targetSafTree,
  }) async {
    final currentPath = _readCustomDownloadFolderPath()?.trim();
    final currentFolder =
        _readCustomDownloadFolderEnabled() &&
            currentPath != null &&
            currentPath.isNotEmpty &&
            !_isSafRoot(currentPath)
        ? await DownloadRootIdentity.resolve(currentPath)
        : null;
    final target = targetDirectory == null
        ? null
        : await DownloadRootIdentity.resolve(targetDirectory);
    final leaving = <String>{};
    for (final entry in await _cacheDao.getPermanentEntries()) {
      if (_isSafRoot(entry.filePath)) {
        if (targetSafTree == null ||
            !await _safStorage.isDescendant(
              treeUri: targetSafTree,
              documentUri: entry.filePath,
            )) {
          leaving.add(entry.songId);
        }
      } else if (currentFolder?.keyFor(entry.filePath) != null &&
          (target == null || !await _isInside(target, entry.filePath))) {
        leaving.add(entry.songId);
      }
    }
    return leaving;
  }

  /// Whether [path] is inside [folder], through any spelling of either: the
  /// folder chosen again through a link, junction or mapped drive is still
  /// the same folder.
  static Future<bool> _isInside(
    DownloadRootIdentity folder,
    String path,
  ) async {
    if (folder.keyFor(path) != null) return true;
    try {
      return folder.keyFor(await File(path).resolveSymbolicLinks()) != null;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> _relocatePermanentDownloadsToSaf(
    String treeUri, {
    Set<String> leaveSongIds = const <String>{},
  }) async {
    final entries = [
      for (final entry in await _cacheDao.getPermanentEntries())
        if (!leaveSongIds.contains(entry.songId)) entry,
    ];
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
        // Keep metadata access asynchronous so storage latency cannot stall UI.
        // ignore: avoid_slow_async_io
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
    Set<String> leaveSongIds = const <String>{},
    int? recoveryGeneration,
  }) async {
    final currentRootIsSaf = _isSafRoot(_readCustomDownloadFolderPath());
    final currentRootDirectory = currentRootIsSaf
        ? null
        : await _permanentDirectory(
            customDownloadFolderEnabled: _readCustomDownloadFolderEnabled(),
            customDownloadFolderPath: _readCustomDownloadFolderPath(),
          );
    final entries = [
      for (final entry in await _cacheDao.getPermanentEntries())
        if (!leaveSongIds.contains(entry.songId)) entry,
    ];
    if (entries.isEmpty) {
      return;
    }
    final targetIdentity = keepEntriesInsideTarget
        ? await DownloadRootIdentity.resolve(targetDirectory.path)
        : null;

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
        _checkRecovery(recoveryGeneration);
        final sourceWasSaf = _isSafRoot(entry.filePath);
        File? materializedSource;
        final sourceFile = sourceWasSaf
            ? (materializedSource = await _safStorage.materialize(
                entry.filePath,
              ))
            : File(entry.filePath);
        // Keep metadata access asynchronous so storage latency cannot stall UI.
        // ignore: avoid_slow_async_io
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

        if (!sourceWasSaf &&
            targetIdentity != null &&
            await _isInside(targetIdentity, entry.filePath)) {
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
        _checkRecovery(recoveryGeneration);
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
        _checkRecovery(recoveryGeneration);
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
        _checkRecovery(recoveryGeneration);
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
      return await _permanentPathResolver.resolveSongPath(
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
      // Keep storage latency off the UI isolate.
      // ignore: avoid_slow_async_io
      return await File(a).exists() &&
          // Keep storage latency off the UI isolate.
          // ignore: avoid_slow_async_io
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
    // Keep metadata access asynchronous so storage latency cannot stall UI.
    // ignore: avoid_slow_async_io
    if (!await source.exists()) {
      if (missingIsOk) {
        return;
      }
      throw FileSystemException('Source file does not exist.', source.path);
    }

    // Keep metadata access asynchronous so storage latency cannot stall UI.
    // ignore: avoid_slow_async_io
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
      final identity = sha1.convert(utf8.encode(song.id)).toString();
      final temporary = File(
        p.join(
          temporaryRoot.path,
          '.navis-saf-transfer-$identity.${safeFileExtension(_resolveFormat(song, item))}',
        ),
      );
      if (!p.isWithin(temporaryRoot.path, temporary.path)) {
        throw FileSystemException(
          'SAF transfer path escapes its root.',
          temporary.path,
        );
      }
      await temporary.parent.create(recursive: true);
      return temporary;
    }
    final ext = _resolveFormat(song, item);
    final targetPath = await _permanentPathResolver.resolveSongPath(
      song: song,
      extension: ext,
      reservedPaths: _reservedDownloadPaths,
    );
    return File(targetPath);
  }

  bool _isSafRoot(String? value) =>
      _isAndroid && (value?.startsWith('content://') ?? false);

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
    return '$artist/$title [$identity].${safeFileExtension(format)}';
  }

  String _mimeTypeFor(String format) => switch (format.toLowerCase()) {
    'flac' => 'audio/flac',
    'mp3' => 'audio/mpeg',
    'm4a' || 'mp4' => 'audio/mp4',
    'aac' => 'audio/aac',
    'ogg' || 'opus' => 'audio/ogg',
    'wav' => 'audio/wav',
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
    // Otherwise use stream.view with transcoding params. A transcoded stream
    // has no known length unless the server estimates one, and without a
    // length the download cannot report progress.
    final maxBitRate = quality != null ? int.tryParse(quality) : null;
    return api.streamUrl(
      id: songId,
      maxBitRate: maxBitRate,
      format: format,
      estimateContentLength: true,
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

  int? _resolveBitRate(SongsTableData song, DownloadQueueTableData item) {
    final quality = item.quality?.trim();
    if (quality != null && quality.isNotEmpty) {
      return int.tryParse(quality);
    }
    return song.bitRate;
  }
}

/// Why a claimed download is being cancelled.
enum _CancelReason {
  /// Return the item to the queue (pause, maintenance, stop).
  requeue,

  /// Drop the item (the user cancelled it or cleared the queue).
  remove,
}

/// Whether a response's content type is certainly not audio: a Subsonic error
/// document or web page. Unknown and missing types are allowed through.
bool isNonAudioContentType(String? contentType) {
  final type = contentType?.split(';').first.trim().toLowerCase();
  if (type == null || type.isEmpty) return false;
  return type.startsWith('text/') ||
      type == 'application/json' ||
      type == 'application/xml' ||
      type.endsWith('+xml') ||
      type.endsWith('+json');
}

/// The file format of a transcoded download, from the response's content
/// type: [requested] when the type agrees with it or is unknown, otherwise
/// the format the server actually sent (for example the original file from a
/// server without the requested encoder).
String downloadedFormatFor({
  required String requested,
  required String? contentType,
}) {
  final type = contentType?.split(';').first.trim().toLowerCase();
  final sent = switch (type) {
    'audio/mpeg' || 'audio/mp3' || 'audio/mpeg3' => 'mp3',
    'audio/ogg' ||
    'audio/opus' ||
    'audio/x-opus' ||
    'application/ogg' => requested.toLowerCase() == 'opus' ? 'opus' : 'ogg',
    'audio/mp4' || 'audio/m4a' || 'audio/x-m4a' => 'm4a',
    'audio/aac' || 'audio/aacp' || 'audio/x-aac' => 'aac',
    'audio/flac' || 'audio/x-flac' => 'flac',
    'audio/wav' || 'audio/x-wav' || 'audio/wave' => 'wav',
    _ => null,
  };
  if (sent == null) return requested;
  // An AAC request answered as MP4 is stored as .m4a.
  return sent == requested.toLowerCase() ? requested : sent;
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
