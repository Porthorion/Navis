import 'dart:io';

import 'package:drift/drift.dart';
import 'package:navis/src/database/daos/cache_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

abstract class RollingCacheManager {
  Future<void> registerTrack({
    required String songId,
    required String filePath,
    int? fileSize,
    String? format,
    int? bitRate,
  });

  Future<void> touchTrack(String songId);

  Future<void> enforceBudget({required int maxBytes});

  Future<void> pruneMissingFiles();

  /// Remove permanent cache DB entries whose backing files no longer exist on
  /// disk (e.g. deleted by the OS, manual cleanup, or filesystem corruption).
  Future<void> pruneMissingPermanentFiles();

  /// Remove rolling-cache files that are not referenced in the DB.
  Future<void> cleanupOrphanedRollingFiles();
}

class DriftRollingCacheManager implements RollingCacheManager {
  DriftRollingCacheManager({
    required CacheDao cacheDao,
    DateTime Function()? now,
  }) : _cacheDao = cacheDao,
       _now = now ?? DateTime.now;

  final CacheDao _cacheDao;
  final DateTime Function() _now;

  @override
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
    final normalizedFormat = _normalizeFormat(format, filePath);

    await _cacheDao.upsertRollingCachedTrack(
      CachedTracksTableCompanion.insert(
        songId: songId,
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

  @override
  Future<void> touchTrack(String songId) {
    return _cacheDao.touchTrack(songId);
  }

  @override
  Future<void> enforceBudget({required int maxBytes}) async {
    if (maxBytes <= 0) {
      return;
    }

    var totalBytes = await _cacheDao.getRollingTotalBytes();
    if (totalBytes <= maxBytes) {
      return;
    }

    final candidates = await _cacheDao.getRollingEntriesOrderedByLastAccessed();
    final evictedIds = <String>[];

    for (final entry in candidates) {
      if (totalBytes <= maxBytes) {
        break;
      }

      await _deleteCacheFileSet(entry.filePath);
      evictedIds.add(entry.songId);
      totalBytes -= entry.fileSize;
    }

    if (evictedIds.isNotEmpty) {
      await _cacheDao.deleteCachedTracksBySongIds(evictedIds);
      AppLogger.debug(
        'Rolling cache eviction: removed ${evictedIds.length} track(s), '
        'freed ${(totalBytes - maxBytes).abs()} bytes',
      );
    }
  }

  @override
  Future<void> pruneMissingFiles() async {
    final entries = await _cacheDao.getRollingEntriesOrderedByLastAccessed();
    final staleIds = <String>[];

    for (final entry in entries) {
      final file = File(entry.filePath);
      if (!file.existsSync()) {
        staleIds.add(entry.songId);
      }
    }

    if (staleIds.isNotEmpty) {
      await _cacheDao.deleteCachedTracksBySongIds(staleIds);
    }
  }

  @override
  Future<void> pruneMissingPermanentFiles() async {
    final entries = await _cacheDao.getPermanentEntries();
    final staleIds = <String>[];

    for (final entry in entries) {
      final file = File(entry.filePath);
      if (!file.existsSync()) {
        staleIds.add(entry.songId);
        AppLogger.info(
          'Pruning stale permanent cache entry for ${entry.songId} — '
          'file missing: ${entry.filePath}',
        );
      }
    }

    if (staleIds.isNotEmpty) {
      await _cacheDao.deleteCachedTracksBySongIds(staleIds);
      AppLogger.info(
        'Pruned ${staleIds.length} permanent cache entries with missing files.',
      );
    }
  }

  @override
  Future<void> cleanupOrphanedRollingFiles() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final rollingDir = Directory(p.join(tempDir.path, 'audio', 'rolling'));
      if (!rollingDir.existsSync()) {
        return;
      }

      final knownEntries = await _cacheDao.getRollingEntriesOrderedByLastAccessed();
      final knownPaths = knownEntries.map((entry) => entry.filePath).toSet();
      var removed = 0;

      await for (final entity in rollingDir.list()) {
        if (entity is! File) {
          continue;
        }
        final path = entity.path;
        if (path.endsWith('.part') || path.endsWith('.mime')) {
          continue;
        }
        if (knownPaths.contains(path)) {
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

  Future<void> _deleteCacheFileSet(String filePath) async {
    final paths = <String>[
      filePath,
      '$filePath.part',
      '$filePath.mime',
    ];

    for (final path in paths) {
      final file = File(path);
      if (!file.existsSync()) {
        continue;
      }
      try {
        file.deleteSync();
      } on FileSystemException catch (error, stackTrace) {
        AppLogger.warning(
          'Failed to delete rolling cache file "$path": $error\n$stackTrace',
        );
      }
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
