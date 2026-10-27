import 'dart:io';

import 'package:drift/drift.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/database/daos/cache_dao.dart';
import 'package:navis/src/database/daos/song_identity_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum RollingCacheActivityStatus { idle, caching }

class RollingCacheActivity {
  const new({required this.status, this.songId, this.progress});

  const new idle()
    : status = RollingCacheActivityStatus.idle,
      songId = null,
      progress = null;

  final RollingCacheActivityStatus status;
  final String? songId;
  final double? progress;

  bool get isCaching => status == RollingCacheActivityStatus.caching;
}

class RollingCacheManager {
  new({
    required this._cacheDao,
    this._songIdentityDao,
    Future<bool> Function(CachedTracksTableData entry)? entryExists,
    DateTime Function()? now,
  }) : _entryExists = entryExists ?? _defaultEntryExists,
       _now = now ?? DateTime.now;

  final CacheDao _cacheDao;
  final SongIdentityDao? _songIdentityDao;
  final Future<bool> Function(CachedTracksTableData entry) _entryExists;
  final DateTime Function() _now;

  static Future<bool> _defaultEntryExists(CachedTracksTableData entry) async =>
      File(entry.filePath).existsSync();

  /// Cached files at most this large are checked for a server error document;
  /// real audio is far larger, so bigger files are never read.
  static const int _errorDocumentMaxBytes = 64 * 1024;

  static Future<bool> _holdsErrorDocument(File file, int size) async {
    if (size > _errorDocumentMaxBytes) {
      return false;
    }
    try {
      final head = <int>[];
      await file
          .openRead(0, subsonicErrorDocumentProbeBytes)
          .forEach(head.addAll);
      return looksLikeSubsonicErrorDocument(head);
    } on FileSystemException {
      return false;
    }
  }

  Future<void> registerTrack({
    required String songId,
    required String filePath,
    int? fileSize,
    String? format,
    int? bitRate,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      return;
    }

    final stat = file.statSync();
    // A stream request the server refused can still arrive with HTTP 200 and
    // an error document. Never keep that as audio: playback prefers the
    // rolling cache over streaming, so the song would fail until evicted.
    if (await _holdsErrorDocument(file, stat.size)) {
      await _deleteCacheFileSet(filePath);
      AppLogger.warning(
        'Discarded a server error response cached as audio for song=$songId.',
      );
      return;
    }
    final normalizedFormat = _normalizeFormat(format, filePath);
    final canonicalSongId =
        await _songIdentityDao?.resolveCanonicalId(songId) ?? songId;

    await _cacheDao.upsertRollingCachedTrack(
      CachedTracksTableCompanion.insert(
        songId: canonicalSongId,
        filePath: filePath,
        fileSize: fileSize ?? stat.size,
        format: normalizedFormat,
        bitRate: bitRate == null ? const Value.absent() : Value(bitRate),
        cacheType: CacheType.rolling,
        downloadStatus: DownloadStatus.complete,
        lastAccessedAt: _now(),
      ),
    );
  }

  Future<void> touchTrack(String songId) async {
    final canonicalSongId =
        await _songIdentityDao?.resolveCanonicalId(songId) ?? songId;
    await _cacheDao.touchTrack(canonicalSongId);
  }

  Future<Set<String>> getPermanentlyCachedSongIds() {
    return _cacheDao.getPermanentlyCachedSongIds();
  }

  /// Evicts the least recently used rolling entries until the total fits
  /// [maxBytes], never those of [keepSongIds] (the playing and next songs).
  Future<void> enforceBudget({
    required int maxBytes,
    Set<String> keepSongIds = const <String>{},
  }) async {
    if (maxBytes <= 0) {
      return;
    }

    var totalBytes = await _cacheDao.getRollingTotalBytes();
    if (totalBytes <= maxBytes) {
      return;
    }

    final candidates = await _cacheDao.getRollingEntriesOrderedByLastAccessed();
    final evictedIds = <String>[];
    var actualBytesFreed = 0;

    for (final entry in candidates) {
      if (totalBytes <= maxBytes) {
        break;
      }
      if (keepSongIds.contains(entry.songId)) continue;

      actualBytesFreed += await _deleteCacheFileSet(entry.filePath);
      evictedIds.add(entry.songId);
      totalBytes -= entry.fileSize;
    }

    if (evictedIds.isNotEmpty) {
      await _cacheDao.deleteCachedTracksBySongIds(evictedIds);
      await _garbageCollectProvisionalMetadata();
      AppLogger.debug(
        'Rolling cache eviction: removed ${evictedIds.length} track(s), '
        'freed $actualBytesFreed bytes',
      );
    }
  }

  /// Remove rolling entries whose files are missing or hold a server error
  /// document instead of audio.
  Future<void> pruneMissingFiles() async {
    final entries = await _cacheDao.getRollingEntriesOrderedByLastAccessed();
    final staleIds = <String>[];
    var errorDocuments = 0;

    for (final entry in entries) {
      if (!await _entryExists(entry)) {
        staleIds.add(entry.songId);
      } else if (await _holdsErrorDocument(
        File(entry.filePath),
        entry.fileSize,
      )) {
        await _deleteCacheFileSet(entry.filePath);
        staleIds.add(entry.songId);
        errorDocuments += 1;
      }
    }

    if (staleIds.isNotEmpty) {
      await _cacheDao.deleteCachedTracksBySongIds(staleIds);
      await _garbageCollectProvisionalMetadata();
    }
    if (errorDocuments > 0) {
      AppLogger.info(
        'Removed $errorDocuments rolling cache entries holding a server error '
        'response instead of audio.',
      );
    }
  }

  /// Remove permanent cache DB entries whose backing files no longer exist on
  /// disk (e.g. deleted by the OS, manual cleanup, or filesystem corruption).
  Future<void> pruneMissingPermanentFiles() async {
    final entries = await _cacheDao.getPermanentEntries();
    final staleIds = <String>[];

    for (final entry in entries) {
      if (!await _entryExists(entry)) {
        staleIds.add(entry.songId);
        AppLogger.info(
          'Pruning stale permanent cache entry for ${entry.songId} — '
          'file missing: ${entry.filePath}',
        );
      }
    }

    if (staleIds.isNotEmpty) {
      await _cacheDao.deleteCachedTracksBySongIds(staleIds);
      await _garbageCollectProvisionalMetadata();
      AppLogger.info(
        'Pruned ${staleIds.length} permanent cache entries with missing files.',
      );
    }
  }

  /// Remove rolling-cache files that are not referenced in the DB.
  Future<void> cleanupOrphanedRollingFiles() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final rollingDir = Directory(p.join(tempDir.path, 'audio', 'rolling'));
      if (!rollingDir.existsSync()) {
        return;
      }

      final knownEntries = await _cacheDao
          .getRollingEntriesOrderedByLastAccessed();
      final knownPaths = knownEntries.map((entry) => entry.filePath).toSet();
      var removed = 0;

      await for (final entity in rollingDir.list()) {
        if (entity is! File) {
          continue;
        }
        final path = entity.path;

        // Stale .part files (interrupted downloads from previous sessions).
        // Skip anything touched recently — active downloads update mtime
        // continuously, so a 2-hour threshold safely excludes them.
        if (path.endsWith('.part') ||
            RegExp(r'\.part\.[0-9]+\.[0-9]+$').hasMatch(path)) {
          final age = _now().difference(entity.statSync().modified);
          if (age < const Duration(hours: 2)) {
            continue;
          }
          try {
            entity.deleteSync();
            removed += 1;
          } on FileSystemException catch (error, stackTrace) {
            AppLogger.warning(
              'Failed to delete stale .part file "$path": $error\n$stackTrace',
            );
          }
          continue;
        }

        if (path.endsWith('.mime')) {
          final audioPath = path.substring(0, path.length - '.mime'.length);
          if (knownPaths.contains(audioPath) || File(audioPath).existsSync()) {
            continue;
          }
          try {
            entity.deleteSync();
            removed += 1;
          } on FileSystemException catch (error, stackTrace) {
            AppLogger.warning(
              'Failed to delete orphaned MIME sidecar "$path": '
              '$error\n$stackTrace',
            );
          }
          continue;
        }
        if (knownPaths.contains(path)) {
          continue;
        }
        final age = _now().difference(entity.statSync().modified);
        if (age < const Duration(hours: 2)) {
          continue;
        }
        await _deleteCacheFileSet(path);
        removed += 1;
      }

      if (removed > 0) {
        AppLogger.info('Pruned $removed orphaned rolling cache file(s).');
      }
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Orphaned rolling cache cleanup failed: $error\n$stackTrace',
      );
    }
  }

  Future<int> _deleteCacheFileSet(String filePath) async {
    // Never delete '.part' files: they belong to just_audio's
    // LockCachingAudioSource while a download is in flight. Deleting one
    // causes a PathNotFoundException when just_audio tries to rename it to the
    // final path after the download completes. Stale '.part' files are handled
    // separately by cleanupOrphanedRollingFiles with an age gate.
    final paths = <String>[filePath, '$filePath.mime'];
    var bytesFreed = 0;

    for (final path in paths) {
      final file = File(path);
      if (!file.existsSync()) {
        continue;
      }
      try {
        bytesFreed += file.lengthSync();
        file.deleteSync();
      } on FileSystemException catch (error, stackTrace) {
        AppLogger.warning(
          'Failed to delete rolling cache file "$path": $error\n$stackTrace',
        );
      }
    }
    return bytesFreed;
  }

  Future<void> _garbageCollectProvisionalMetadata() async {
    final result = await _songIdentityDao
        ?.garbageCollectUnreferencedProvisionalMetadata();
    if (result != null &&
        (result.songs > 0 || result.albums > 0 || result.artists > 0)) {
      AppLogger.info(
        'Provisional cache cleanup: songs=${result.songs} '
        'albums=${result.albums} artists=${result.artists}.',
      );
    }
  }

  String _normalizeFormat(String? format, String filePath) {
    final trimmed = format?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }
    final extension = p.extension(filePath).replaceFirst('.', '').trim();
    return extension.isEmpty ? 'bin' : extension;
  }
}
