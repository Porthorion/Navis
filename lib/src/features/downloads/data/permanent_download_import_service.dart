import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:navis/src/database/daos/cache_dao.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/downloads/data/permanent_download_media_identity.dart';
import 'package:navis/src/features/downloads/data/android_saf_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// The private identity store kept at the root of a user-selected folder.
const String permanentDownloadManifestFileName = '.navis-downloads.sqlite';

enum PermanentDownloadImportDisposition {
  recognized,
  ambiguous,
  unmatched,
  profileMismatch,
  alreadyRegistered,
}

class PermanentDownloadImportItem {
  const PermanentDownloadImportItem({
    required this.relativePath,
    required this.fileSize,
    required this.format,
    required this.disposition,
    this.songId,
    this.candidates = const <SongsTableData>[],
    this.sourceUri,
  });

  final String relativePath;
  final int fileSize;
  final String format;
  final PermanentDownloadImportDisposition disposition;
  final String? songId;
  final List<SongsTableData> candidates;

  /// Set for Android SAF documents. File-system imports use [relativePath].
  final String? sourceUri;
}

class PermanentDownloadImportPreview {
  const PermanentDownloadImportPreview({
    required this.rootPath,
    required this.items,
  });

  final String rootPath;
  final List<PermanentDownloadImportItem> items;

  int get recognizedCount => items
      .where(
        (item) =>
            item.disposition == PermanentDownloadImportDisposition.recognized,
      )
      .length;

  int get uncertainCount => items
      .where(
        (item) =>
            item.disposition == PermanentDownloadImportDisposition.ambiguous,
      )
      .length;

  int get skippedCount => items
      .where(
        (item) =>
            item.disposition == PermanentDownloadImportDisposition.unmatched ||
            item.disposition ==
                PermanentDownloadImportDisposition.profileMismatch,
      )
      .length;

  int get profileMismatchCount => items
      .where(
        (item) =>
            item.disposition ==
            PermanentDownloadImportDisposition.profileMismatch,
      )
      .length;

  int get unmatchedCount => items
      .where(
        (item) =>
            item.disposition == PermanentDownloadImportDisposition.unmatched,
      )
      .length;
}

class PermanentDownloadImportResult {
  const PermanentDownloadImportResult({
    required this.importedCount,
    required this.skippedCount,
  });

  final int importedCount;
  final int skippedCount;
}

/// Adopts files in a custom permanent-download folder without moving or
/// deleting them. The SQLite sidecar is authoritative for future imports;
/// legacy folders fall back to deterministic local-catalog matching.
class PermanentDownloadImportService {
  PermanentDownloadImportService({
    required CacheDao cacheDao,
    required LibraryDao libraryDao,
    required String? Function() readProfileIdentity,
  }) : _cacheDao = cacheDao,
       _libraryDao = libraryDao,
       _readProfileIdentity = readProfileIdentity,
       _mediaIdentity = PermanentDownloadMediaIdentity();

  final CacheDao _cacheDao;
  final LibraryDao _libraryDao;
  final String? Function() _readProfileIdentity;
  final PermanentDownloadMediaIdentity _mediaIdentity;
  final AndroidSafStorage _safStorage = const AndroidSafStorage();

  Future<PermanentDownloadImportPreview> preview(Directory root) async {
    if (_isSafTreeUri(root.path)) {
      return _previewSaf(root.path);
    }
    final canonicalRoot = await root.resolveSymbolicLinks();
    final profileFingerprint = _profileFingerprint();
    final manifestFile = File(
      p.join(canonicalRoot, permanentDownloadManifestFileName),
    );
    final manifest = manifestFile.existsSync()
        ? sqlite3.open(manifestFile.path)
        : null;
    try {
      final songs = await _libraryDao.watchAllSongs().first;
      final registered = await _cacheDao.getPermanentEntries();
      final registeredPaths = registered
          .map((track) => p.normalize(track.filePath))
          .toSet();
      final registeredSongsByPath = <String, String>{
        for (final track in registered)
          p.normalize(track.filePath): track.songId,
      };
      final registeredSongIds = registered.map((track) => track.songId).toSet();
      final manifestRecords = manifest == null
          ? const <String, _ManifestRecord>{}
          : _readManifestRecords(manifest);
      final items = <PermanentDownloadImportItem>[];

      await for (final entity in Directory(
        canonicalRoot,
      ).list(recursive: true)) {
        if (entity is! File || _isNavisSidecar(entity.path)) continue;
        final stat = await entity.stat();
        final normalizedPath = p.normalize(entity.path);
        final relativePath = p.relative(normalizedPath, from: canonicalRoot);
        final format = p
            .extension(normalizedPath)
            .replaceFirst('.', '')
            .toLowerCase();
        if (format.isEmpty) continue;
        if (registeredPaths.contains(normalizedPath)) {
          items.add(
            PermanentDownloadImportItem(
              relativePath: relativePath,
              fileSize: stat.size,
              format: format,
              disposition: PermanentDownloadImportDisposition.alreadyRegistered,
              songId: registeredSongsByPath[normalizedPath],
            ),
          );
          continue;
        }

        final manifestRecord = manifestRecords[relativePath];
        if (manifestRecord != null) {
          if (manifestRecord.profileFingerprint != profileFingerprint) {
            items.add(
              PermanentDownloadImportItem(
                relativePath: relativePath,
                fileSize: stat.size,
                format: format,
                disposition: PermanentDownloadImportDisposition.profileMismatch,
              ),
            );
            continue;
          }
          if (manifestRecord.fileSize == stat.size &&
              songs.any((song) => song.id == manifestRecord.songId)) {
            items.add(
              PermanentDownloadImportItem(
                relativePath: relativePath,
                fileSize: stat.size,
                format: format,
                disposition: registeredSongIds.contains(manifestRecord.songId)
                    ? PermanentDownloadImportDisposition.alreadyRegistered
                    : PermanentDownloadImportDisposition.recognized,
                songId: manifestRecord.songId,
              ),
            );
            continue;
          }
        }

        final tags = await _mediaIdentity.read(entity);
        final taggedSongId = tags[PermanentDownloadMediaIdentity.songIdKey];
        final taggedProfile =
            tags[PermanentDownloadMediaIdentity.profileFingerprintKey];
        if (taggedSongId != null && taggedSongId.isNotEmpty) {
          if (taggedProfile != null && taggedProfile != profileFingerprint) {
            items.add(
              PermanentDownloadImportItem(
                relativePath: relativePath,
                fileSize: stat.size,
                format: format,
                disposition: PermanentDownloadImportDisposition.profileMismatch,
              ),
            );
            continue;
          }
          if (songs.any((song) => song.id == taggedSongId)) {
            items.add(
              PermanentDownloadImportItem(
                relativePath: relativePath,
                fileSize: stat.size,
                format: format,
                disposition: registeredSongIds.contains(taggedSongId)
                    ? PermanentDownloadImportDisposition.alreadyRegistered
                    : PermanentDownloadImportDisposition.recognized,
                songId: taggedSongId,
              ),
            );
            continue;
          }
        }
        final candidates = _legacyCandidates(
          rootPath: canonicalRoot,
          filePath: normalizedPath,
          format: format,
          songs: songs,
          tags: tags,
        );
        items.add(
          PermanentDownloadImportItem(
            relativePath: relativePath,
            fileSize: stat.size,
            format: format,
            disposition: candidates.length == 1
                ? registeredSongIds.contains(candidates.single.id)
                      ? PermanentDownloadImportDisposition.alreadyRegistered
                      : PermanentDownloadImportDisposition.recognized
                : candidates.isEmpty
                ? PermanentDownloadImportDisposition.unmatched
                : PermanentDownloadImportDisposition.ambiguous,
            songId: candidates.length == 1 ? candidates.single.id : null,
            candidates: candidates,
          ),
        );
      }
      items.sort((a, b) => a.relativePath.compareTo(b.relativePath));
      return PermanentDownloadImportPreview(
        rootPath: canonicalRoot,
        items: items,
      );
    } finally {
      manifest?.close();
    }
  }

  Future<PermanentDownloadImportPreview> _previewSaf(String treeUri) async {
    final tree = await _safStorage.inspectTree(treeUri);
    if (!tree.canRead || !tree.canWrite || !tree.canReplace) {
      throw const FileSystemException(
        'This Android folder does not allow Navis to read and replace its download index.',
      );
    }
    final profileFingerprint = _profileFingerprint();
    final songs = await _libraryDao.watchAllSongs().first;
    final registered = await _cacheDao.getPermanentEntries();
    final registeredPaths = registered.map((track) => track.filePath).toSet();
    final registeredSongIds = registered.map((track) => track.songId).toSet();
    final documents = await _safStorage.listRecursively(treeUri);
    final sidecar = documents.where(
      (document) => document.relativePath == permanentDownloadManifestFileName,
    );
    Database? manifest;
    File? manifestFile;
    try {
      if (sidecar.isNotEmpty) {
        manifestFile = await _safStorage.materialize(sidecar.first.uri);
        manifest = sqlite3.open(manifestFile.path);
      }
      final manifestRecords = manifest == null
          ? const <String, _ManifestRecord>{}
          : _readManifestRecords(manifest);
      final items = <PermanentDownloadImportItem>[];
      for (final document in documents) {
        if (_isNavisSidecar(document.relativePath)) continue;
        final format = p
            .extension(document.relativePath)
            .replaceFirst('.', '')
            .toLowerCase();
        if (format.isEmpty) continue;
        if (registeredPaths.contains(document.uri)) {
          items.add(
            PermanentDownloadImportItem(
              relativePath: document.relativePath,
              fileSize: document.size,
              format: format,
              disposition: PermanentDownloadImportDisposition.alreadyRegistered,
              songId: registered
                  .firstWhere((track) => track.filePath == document.uri)
                  .songId,
              sourceUri: document.uri,
            ),
          );
          continue;
        }
        final manifestRecord = manifestRecords[document.relativePath];
        if (manifestRecord != null &&
            manifestRecord.profileFingerprint != profileFingerprint) {
          items.add(
            PermanentDownloadImportItem(
              relativePath: document.relativePath,
              fileSize: document.size,
              format: format,
              disposition: PermanentDownloadImportDisposition.profileMismatch,
              sourceUri: document.uri,
            ),
          );
          continue;
        }
        if (manifestRecord != null &&
            manifestRecord.fileSize == document.size &&
            songs.any((song) => song.id == manifestRecord.songId)) {
          items.add(
            PermanentDownloadImportItem(
              relativePath: document.relativePath,
              fileSize: document.size,
              format: format,
              disposition: registeredSongIds.contains(manifestRecord.songId)
                  ? PermanentDownloadImportDisposition.alreadyRegistered
                  : PermanentDownloadImportDisposition.recognized,
              songId: manifestRecord.songId,
              sourceUri: document.uri,
            ),
          );
          continue;
        }
        File? materialized;
        try {
          materialized = await _safStorage.materialize(document.uri);
          final tags = await _mediaIdentity.read(materialized);
          final taggedSongId = tags[PermanentDownloadMediaIdentity.songIdKey];
          final taggedProfile =
              tags[PermanentDownloadMediaIdentity.profileFingerprintKey];
          if (taggedSongId != null &&
              taggedSongId.isNotEmpty &&
              taggedProfile != null &&
              taggedProfile != profileFingerprint) {
            items.add(
              PermanentDownloadImportItem(
                relativePath: document.relativePath,
                fileSize: document.size,
                format: format,
                disposition: PermanentDownloadImportDisposition.profileMismatch,
                sourceUri: document.uri,
              ),
            );
            continue;
          }
          final candidates =
              taggedSongId != null &&
                  songs.any((song) => song.id == taggedSongId)
              ? songs
                    .where((song) => song.id == taggedSongId)
                    .toList(growable: false)
              : _legacyCandidates(
                  rootPath: '',
                  filePath: document.relativePath,
                  format: format,
                  songs: songs,
                  tags: tags,
                );
          items.add(
            PermanentDownloadImportItem(
              relativePath: document.relativePath,
              fileSize: document.size,
              format: format,
              disposition: candidates.length == 1
                  ? (registeredSongIds.contains(candidates.single.id)
                        ? PermanentDownloadImportDisposition.alreadyRegistered
                        : PermanentDownloadImportDisposition.recognized)
                  : candidates.isEmpty
                  ? PermanentDownloadImportDisposition.unmatched
                  : PermanentDownloadImportDisposition.ambiguous,
              songId: candidates.length == 1 ? candidates.single.id : null,
              candidates: candidates,
              sourceUri: document.uri,
            ),
          );
        } finally {
          if (materialized != null)
            await materialized.delete().catchError((_) {});
        }
      }
      items.sort((a, b) => a.relativePath.compareTo(b.relativePath));
      return PermanentDownloadImportPreview(rootPath: treeUri, items: items);
    } finally {
      manifest?.close();
      if (manifestFile != null) await manifestFile.delete().catchError((_) {});
    }
  }

  Future<PermanentDownloadImportResult> commit(
    PermanentDownloadImportPreview preview, {
    Map<String, String> manualSongIds = const <String, String>{},
  }) async {
    if (_isSafTreeUri(preview.rootPath)) {
      return _commitSaf(preview, manualSongIds: manualSongIds);
    }
    final root = Directory(preview.rootPath);
    final manifest = _openManifest(root);
    var imported = 0;
    var skipped = 0;
    try {
      for (final item in preview.items) {
        final songId = item.songId ?? manualSongIds[item.relativePath];
        if (item.disposition ==
            PermanentDownloadImportDisposition.alreadyRegistered) {
          if (songId != null) {
            final file = File(p.join(root.path, item.relativePath));
            if (await file.exists()) {
              final stat = await file.stat();
              _writeManifestRecord(
                manifest,
                _ManifestRecord(
                  relativePath: item.relativePath,
                  songId: songId,
                  profileFingerprint: _profileFingerprint(),
                  fileSize: stat.size,
                  format: item.format,
                  updatedAt: DateTime.now(),
                ),
              );
              await _writeIdentityTags(file, songId);
            }
          }
          continue;
        }
        if (songId == null ||
            (item.disposition !=
                    PermanentDownloadImportDisposition.recognized &&
                item.disposition !=
                    PermanentDownloadImportDisposition.ambiguous &&
                item.disposition !=
                    PermanentDownloadImportDisposition.unmatched)) {
          skipped++;
          continue;
        }
        final file = File(p.join(root.path, item.relativePath));
        if (!await file.exists()) {
          skipped++;
          continue;
        }
        final stat = await file.stat();
        await _cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: songId,
            filePath: file.path,
            fileSize: stat.size,
            format: item.format,
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );
        _writeManifestRecord(
          manifest,
          _ManifestRecord(
            relativePath: item.relativePath,
            songId: songId,
            profileFingerprint: _profileFingerprint(),
            fileSize: stat.size,
            format: item.format,
            updatedAt: DateTime.now(),
          ),
        );
        await _writeIdentityTags(file, songId);
        imported++;
      }
      return PermanentDownloadImportResult(
        importedCount: imported,
        skippedCount: skipped,
      );
    } finally {
      manifest.close();
    }
  }

  Future<PermanentDownloadImportResult> _commitSaf(
    PermanentDownloadImportPreview preview, {
    required Map<String, String> manualSongIds,
  }) async {
    final documents = await _safStorage.listRecursively(preview.rootPath);
    final existingSidecar = documents.where(
      (document) => document.relativePath == permanentDownloadManifestFileName,
    );
    File manifestFile;
    if (existingSidecar.isEmpty) {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'navis-downloads-',
      );
      manifestFile = File(p.join(temporaryDirectory.path, 'manifest.sqlite'));
    } else {
      manifestFile = await _safStorage.materialize(existingSidecar.first.uri);
    }
    final manifest = _openManifestFile(manifestFile);
    var imported = 0;
    var skipped = 0;
    try {
      for (final item in preview.items) {
        final songId = item.songId ?? manualSongIds[item.relativePath];
        if (item.disposition ==
            PermanentDownloadImportDisposition.alreadyRegistered) {
          if (songId != null) {
            _writeManifestRecord(
              manifest,
              _ManifestRecord(
                relativePath: item.relativePath,
                songId: songId,
                profileFingerprint: _profileFingerprint(),
                fileSize: item.fileSize,
                format: item.format,
                updatedAt: DateTime.now(),
              ),
            );
          }
          continue;
        }
        if (songId == null ||
            item.sourceUri == null ||
            (item.disposition !=
                    PermanentDownloadImportDisposition.recognized &&
                item.disposition !=
                    PermanentDownloadImportDisposition.ambiguous &&
                item.disposition !=
                    PermanentDownloadImportDisposition.unmatched)) {
          skipped++;
          continue;
        }
        var locator = item.sourceUri!;
        File? local;
        try {
          local = await _safStorage.materialize(locator);
          await _writeIdentityTags(local, songId);
          // Replacing the document is intentional: SAF does not expose a
          // filesystem handle for an atomic in-place tag edit. The cache row is
          // updated to the returned document URI before becoming visible.
          locator = await _safStorage.writeFromFile(
            treeUri: preview.rootPath,
            relativePath: item.relativePath,
            source: local,
            mimeType: _mimeTypeFor(item.format),
          );
        } finally {
          if (local != null) await local.delete().catchError((_) {});
        }
        await _cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: songId,
            filePath: locator,
            storageKind: const Value('androidSaf'),
            fileSize: item.fileSize,
            format: item.format,
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );
        _writeManifestRecord(
          manifest,
          _ManifestRecord(
            relativePath: item.relativePath,
            songId: songId,
            profileFingerprint: _profileFingerprint(),
            fileSize: item.fileSize,
            format: item.format,
            updatedAt: DateTime.now(),
          ),
        );
        imported++;
      }
      manifest.close();
      await _safStorage.writeFromFile(
        treeUri: preview.rootPath,
        relativePath: permanentDownloadManifestFileName,
        source: manifestFile,
        mimeType: 'application/vnd.sqlite3',
      );
      return PermanentDownloadImportResult(
        importedCount: imported,
        skippedCount: skipped,
      );
    } finally {
      // sqlite accepts repeated close poorly, so only close when still open.
      try {
        manifest.close();
      } catch (_) {}
      await manifestFile.delete().catchError((_) {});
    }
  }

  /// Records a Navis-created permanent download. This intentionally does not
  /// touch the media bytes: format-specific tag writers are best-effort and
  /// must never make a completed download fail.
  Future<void> recordDownloaded({
    required Directory root,
    required File file,
    required String songId,
    required String format,
  }) async {
    final canonicalRoot = await root.resolveSymbolicLinks();
    final stat = await file.stat();
    final manifest = _openManifest(Directory(canonicalRoot));
    try {
      _writeManifestRecord(
        manifest,
        _ManifestRecord(
          relativePath: p.relative(file.path, from: canonicalRoot),
          songId: songId,
          profileFingerprint: _profileFingerprint(),
          fileSize: stat.size,
          format: format,
          updatedAt: DateTime.now(),
        ),
      );
      await _writeIdentityTags(file, songId);
    } finally {
      manifest.close();
    }
  }

  /// Adds a sidecar entry for a single Navis-created SAF document without
  /// scanning or adopting any other file in the selected folder.
  Future<void> recordDownloadedSaf({
    required String treeUri,
    required String relativePath,
    required int fileSize,
    required String songId,
    required String format,
  }) async {
    final documents = await _safStorage.listRecursively(treeUri);
    final existing = documents.where(
      (document) => document.relativePath == permanentDownloadManifestFileName,
    );
    final manifestFile = existing.isEmpty
        ? File(
            p.join(
              (await Directory.systemTemp.createTemp('navis-downloads-')).path,
              'manifest.sqlite',
            ),
          )
        : await _safStorage.materialize(existing.first.uri);
    final manifest = _openManifestFile(manifestFile);
    try {
      _writeManifestRecord(
        manifest,
        _ManifestRecord(
          relativePath: relativePath,
          songId: songId,
          profileFingerprint: _profileFingerprint(),
          fileSize: fileSize,
          format: format,
          updatedAt: DateTime.now(),
        ),
      );
      manifest.close();
      await _safStorage.writeFromFile(
        treeUri: treeUri,
        relativePath: permanentDownloadManifestFileName,
        source: manifestFile,
        mimeType: 'application/vnd.sqlite3',
      );
    } finally {
      try {
        manifest.close();
      } catch (_) {}
      await manifestFile.delete().catchError((_) {});
    }
  }

  bool _isNavisSidecar(String path) {
    final name = p.basename(path);
    return name == permanentDownloadManifestFileName ||
        name == '$permanentDownloadManifestFileName-wal' ||
        name == '$permanentDownloadManifestFileName-shm';
  }

  List<SongsTableData> _legacyCandidates({
    required String rootPath,
    required String filePath,
    required String format,
    required List<SongsTableData> songs,
    required Map<String, String> tags,
  }) {
    final relative = p.relative(filePath, from: rootPath);
    final segments = p.split(relative);
    final title = _normalize(
      tags['TITLE'] ?? p.basenameWithoutExtension(filePath),
    );
    final artist = _normalize(
      tags['ARTIST'] ??
          (segments.length > 1 ? segments[segments.length - 2] : ''),
    );
    return songs
        .where((song) {
          if (_normalize(song.title) != title) return false;
          if (artist.isNotEmpty && _normalize(song.artistName ?? '') != artist)
            return false;
          final suffix = song.suffix?.trim().toLowerCase();
          return suffix == null || suffix.isEmpty || suffix == format;
        })
        .toList(growable: false);
  }

  String _normalize(String input) =>
      input.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  String _profileFingerprint() {
    final identity = _readProfileIdentity()?.trim();
    if (identity == null || identity.isEmpty) return '';
    return sha256.convert(utf8.encode(identity.toLowerCase())).toString();
  }

  Future<void> _writeIdentityTags(File file, String songId) async {
    try {
      await _mediaIdentity.write(
        file: file,
        songId: songId,
        profileFingerprint: _profileFingerprint(),
      );
    } on FileSystemException {
      // The manifest was committed first and remains authoritative.
    }
  }

  Database _openManifest(Directory root) {
    if (!root.existsSync()) root.createSync(recursive: true);
    final db = sqlite3.open(
      p.join(root.path, permanentDownloadManifestFileName),
    );
    db.execute('PRAGMA journal_mode=DELETE;');
    db.execute(
      'CREATE TABLE IF NOT EXISTS download_records ('
      'relative_path TEXT PRIMARY KEY, song_id TEXT NOT NULL, '
      'profile_fingerprint TEXT NOT NULL, file_size INTEGER NOT NULL, '
      'format TEXT NOT NULL, updated_at INTEGER NOT NULL)',
    );
    return db;
  }

  Database _openManifestFile(File file) {
    final db = sqlite3.open(file.path);
    db.execute('PRAGMA journal_mode=DELETE;');
    db.execute(
      'CREATE TABLE IF NOT EXISTS download_records ('
      'relative_path TEXT PRIMARY KEY, song_id TEXT NOT NULL, '
      'profile_fingerprint TEXT NOT NULL, file_size INTEGER NOT NULL, '
      'format TEXT NOT NULL, updated_at INTEGER NOT NULL)',
    );
    return db;
  }

  bool _isSafTreeUri(String value) => value.startsWith('content://');

  String _mimeTypeFor(String format) => switch (format.toLowerCase()) {
    'flac' => 'audio/flac',
    'mp3' => 'audio/mpeg',
    'm4a' => 'audio/mp4',
    'ogg' => 'audio/ogg',
    'opus' => 'audio/ogg',
    _ => 'application/octet-stream',
  };

  Map<String, _ManifestRecord> _readManifestRecords(Database db) {
    final rows = db.select(
      'SELECT relative_path, song_id, profile_fingerprint, file_size, format, updated_at FROM download_records',
    );
    return <String, _ManifestRecord>{
      for (final row in rows)
        row['relative_path'] as String: _ManifestRecord(
          relativePath: row['relative_path'] as String,
          songId: row['song_id'] as String,
          profileFingerprint: row['profile_fingerprint'] as String,
          fileSize: row['file_size'] as int,
          format: row['format'] as String,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(
            row['updated_at'] as int,
          ),
        ),
    };
  }

  void _writeManifestRecord(Database db, _ManifestRecord record) {
    db.execute(
      'INSERT INTO download_records(relative_path, song_id, profile_fingerprint, file_size, format, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(relative_path) DO UPDATE SET '
      'song_id=excluded.song_id, profile_fingerprint=excluded.profile_fingerprint, '
      'file_size=excluded.file_size, format=excluded.format, updated_at=excluded.updated_at',
      <Object?>[
        record.relativePath,
        record.songId,
        record.profileFingerprint,
        record.fileSize,
        record.format,
        record.updatedAt.millisecondsSinceEpoch,
      ],
    );
  }
}

class _ManifestRecord {
  const _ManifestRecord({
    required this.relativePath,
    required this.songId,
    required this.profileFingerprint,
    required this.fileSize,
    required this.format,
    required this.updatedAt,
  });

  final String relativePath;
  final String songId;
  final String profileFingerprint;
  final int fileSize;
  final String format;
  final DateTime updatedAt;
}
