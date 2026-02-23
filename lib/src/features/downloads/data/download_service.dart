import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/daos/cache_dao.dart';
import 'package:navis/src/database/daos/download_queue_dao.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Orchestrates permanent downloads of tracks from a Subsonic server.
///
/// The service processes one download at a time, pulling the next pending item
/// from the download queue table and streaming it to disk via Dio.
class DownloadService {
  DownloadService({
    required CacheDao cacheDao,
    required DownloadQueueDao downloadQueueDao,
    required LibraryDao libraryDao,
    required SubsonicApiClient? Function() readApiClient,
    Dio? dio,
  })  : _cacheDao = cacheDao,
        _downloadQueueDao = downloadQueueDao,
        _libraryDao = libraryDao,
        _readApiClient = readApiClient,
        _dio = dio ?? Dio();

  final CacheDao _cacheDao;
  final DownloadQueueDao _downloadQueueDao;
  final LibraryDao _libraryDao;
  final SubsonicApiClient? Function() _readApiClient;
  final Dio _dio;

  StreamSubscription<List<DownloadQueueTableData>>? _queueSubscription;
  bool _processing = false;
  CancelToken? _activeCancelToken;

  /// Start listening to the download queue and automatically process items.
  void start() {
    _queueSubscription?.cancel();
    _queueSubscription = _downloadQueueDao.watchQueue().listen((_) {
      _processNext();
    });
  }

  /// Stop the service and cancel any active download.
  Future<void> stop() async {
    await _queueSubscription?.cancel();
    _queueSubscription = null;
    _activeCancelToken?.cancel('Service stopped');
    _activeCancelToken = null;
    _processing = false;
  }

  // ---------------------------------------------------------------------------
  // Enqueue helpers
  // ---------------------------------------------------------------------------

  /// Enqueue a single song for permanent download.
  Future<void> enqueueSong(
    String songId, {
    String? quality,
    String? format,
    int priority = 0,
  }) async {
    await _downloadQueueDao.enqueue(
      DownloadQueueTableCompanion.insert(
        songId: Value(songId),
        quality: Value(quality),
        format: Value(format),
        status: DownloadStatus.queued,
        addedAt: DateTime.now(),
        priority: Value(priority),
      ),
    );
  }

  /// Enqueue all songs for an album.
  Future<int> enqueueAlbum(
    String albumId, {
    String? quality,
    String? format,
  }) async {
    final songs = await _libraryDao.watchSongsByAlbum(albumId).first;
    var count = 0;
    for (final song in songs) {
      // Skip already-permanently-cached songs.
      final existing = await _cacheDao.getCachedTrack(song.id);
      if (existing != null && existing.cacheType == CacheType.permanent) {
        continue;
      }
      await enqueueSong(song.id, quality: quality, format: format);
      count++;
    }
    return count;
  }

  /// Enqueue all songs for a playlist.
  Future<int> enqueuePlaylist(
    String playlistId,
    List<String> songIds, {
    String? quality,
    String? format,
  }) async {
    var count = 0;
    for (final songId in songIds) {
      final existing = await _cacheDao.getCachedTrack(songId);
      if (existing != null && existing.cacheType == CacheType.permanent) {
        continue;
      }
      await enqueueSong(songId, quality: quality, format: format);
      count++;
    }
    return count;
  }

  /// Promote a rolling-cache track to permanent (no re-download needed).
  Future<bool> promoteToPermament(String songId) async {
    final track = await _cacheDao.getCachedTrack(songId);
    if (track == null) return false;
    if (track.cacheType == CacheType.permanent) return true;

    final file = File(track.filePath);
    if (!file.existsSync()) return false;

    // Move file to permanent directory.
    final permDir = await _permanentDirectory();
    final newPath = p.join(permDir.path, p.basename(track.filePath));
    final destination = File(newPath);
    if (!destination.existsSync()) {
      await file.copy(newPath);
    }
    // Clean up rolling cache files.
    for (final suffix in <String>['', '.part', '.mime']) {
      final f = File('${track.filePath}$suffix');
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } on FileSystemException {
          // best-effort
        }
      }
    }

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

  // ---------------------------------------------------------------------------
  // Processing
  // ---------------------------------------------------------------------------

  Future<void> _processNext() async {
    if (_processing) return;
    _processing = true;

    try {
      while (true) {
        final queue = await _downloadQueueDao.watchQueue().first;
        final next = queue
            .where((item) => item.status == DownloadStatus.queued)
            .toList();
        if (next.isEmpty) break;

        final item = next.first;
        if (item.songId == null) {
          // Malformed entry — remove.
          await _downloadQueueDao.remove(item.id);
          continue;
        }
        await _downloadItem(item);
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
      await _downloadQueueDao.updateStatus(item.id, DownloadStatus.failed);
      return;
    }

    // Mark as downloading.
    await _downloadQueueDao.updateStatus(item.id, DownloadStatus.downloading);

    // Resolve download URL.
    final downloadUri = _resolveDownloadUri(
      api: api,
      songId: songId,
      quality: item.quality,
      format: item.format,
    );

    // Resolve destination file.
    final songs = await _libraryDao.getSongsByIds(<String>[songId]);
    if (songs.isEmpty) {
      AppLogger.warning('DownloadService: Song $songId not found in library');
      await _downloadQueueDao.updateStatus(item.id, DownloadStatus.failed);
      return;
    }
    final song = songs.first;
    final destFile = await _resolveDownloadFile(song, item);

    _activeCancelToken = CancelToken();
    try {
      final response = await _dio.downloadUri(
        downloadUri,
        destFile.path,
        cancelToken: _activeCancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            final progress = (received / total).clamp(0.0, 1.0);
            _downloadQueueDao.updateProgress(item.id, progress);
          }
        },
      );

      if (response.statusCode != null &&
          response.statusCode! >= 200 &&
          response.statusCode! < 300) {
        // Register in cached_tracks as permanent.
        final stat = destFile.statSync();
        final format = _inferFormat(song, item);

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
        AppLogger.info(
          'DownloadService: Completed download for $songId '
          '(${stat.size} bytes)',
        );
      } else {
        await _downloadQueueDao.updateStatus(item.id, DownloadStatus.failed);
        AppLogger.warning(
          'DownloadService: HTTP ${response.statusCode} for $songId',
        );
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        AppLogger.debug('DownloadService: Download cancelled for $songId');
        await _downloadQueueDao.updateStatus(item.id, DownloadStatus.queued);
      } else {
        AppLogger.warning('DownloadService: Dio error for $songId: $e');
        await _downloadQueueDao.updateStatus(item.id, DownloadStatus.failed);
      }
    } on Object catch (e, st) {
      AppLogger.warning('DownloadService: Error for $songId: $e\n$st');
      await _downloadQueueDao.updateStatus(item.id, DownloadStatus.failed);
    } finally {
      _activeCancelToken = null;
    }
  }

  // ---------------------------------------------------------------------------
  // File resolution
  // ---------------------------------------------------------------------------

  Future<Directory> _permanentDirectory() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory(p.join(root.path, 'audio', 'permanent'));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  Future<File> _resolveDownloadFile(
    SongsTableData song,
    DownloadQueueTableData item,
  ) async {
    final dir = await _permanentDirectory();
    final qualitySig = '${item.quality ?? 'original'}-${item.format ?? 'raw'}';
    final digest =
        sha1.convert(utf8.encode('${song.id}::$qualitySig')).toString();
    final ext = _songFileExtension(song, item);
    return File(p.join(dir.path, '${song.id}_$digest.$ext'));
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

  String _songFileExtension(SongsTableData song, DownloadQueueTableData item) {
    if (item.format != null && item.format!.trim().isNotEmpty) {
      return item.format!.trim();
    }
    final suffix = song.suffix?.trim();
    if (suffix != null && suffix.isNotEmpty) return suffix;
    return 'bin';
  }

  String _inferFormat(SongsTableData song, DownloadQueueTableData item) {
    if (item.format != null && item.format!.trim().isNotEmpty) {
      return item.format!.trim();
    }
    final suffix = song.suffix?.trim();
    if (suffix != null && suffix.isNotEmpty) return suffix;
    return 'bin';
  }
}
