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
import 'package:navis/src/utils/search_text.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// The private identity store kept at the root of a user-selected folder.
const String permanentDownloadManifestFileName = '.navis-downloads.sqlite';

enum PermanentDownloadImportDisposition {
  recognized,
  ambiguous,
  unmatched,
  profileMismatch,
  inaccessible,
  alreadyRegistered,
}

enum PermanentDownloadMatchOrigin {
  manifest,
  embeddedIdentity,
  filenameArtist,
  filenameOnly,
  ambiguous,
  unmatched,
  profileMismatch,
  inaccessible,
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
    this.matchOrigin,
    this.sourceTitle,
    this.sourceArtist,
  });

  final String relativePath;
  final int fileSize;
  final String format;
  final PermanentDownloadImportDisposition disposition;
  final String? songId;
  final List<SongsTableData> candidates;

  /// Set for Android SAF documents. File-system imports use [relativePath].
  final String? sourceUri;
  final PermanentDownloadMatchOrigin? matchOrigin;
  final String? sourceTitle;
  final String? sourceArtist;
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
                PermanentDownloadImportDisposition.profileMismatch ||
            item.disposition == PermanentDownloadImportDisposition.inaccessible,
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

  int get inaccessibleCount => items
      .where(
        (item) =>
            item.disposition == PermanentDownloadImportDisposition.inaccessible,
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
      final songIndex = await _openMatchIndex();
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
              matchOrigin: PermanentDownloadMatchOrigin.alreadyRegistered,
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
              await songIndex.containsId(manifestRecord.songId)) {
            items.add(
              PermanentDownloadImportItem(
                relativePath: relativePath,
                fileSize: stat.size,
                format: format,
                disposition: registeredSongIds.contains(manifestRecord.songId)
                    ? PermanentDownloadImportDisposition.alreadyRegistered
                    : PermanentDownloadImportDisposition.recognized,
                songId: manifestRecord.songId,
                matchOrigin: PermanentDownloadMatchOrigin.manifest,
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
          if (await songIndex.containsId(taggedSongId)) {
            items.add(
              PermanentDownloadImportItem(
                relativePath: relativePath,
                fileSize: stat.size,
                format: format,
                disposition: registeredSongIds.contains(taggedSongId)
                    ? PermanentDownloadImportDisposition.alreadyRegistered
                    : PermanentDownloadImportDisposition.recognized,
                songId: taggedSongId,
                matchOrigin: PermanentDownloadMatchOrigin.embeddedIdentity,
              ),
            );
            continue;
          }
        }
        final match = await songIndex.match(
          rootPath: canonicalRoot,
          filePath: normalizedPath,
          format: format,
          tags: tags,
        );
        items.add(
          PermanentDownloadImportItem(
            relativePath: relativePath,
            fileSize: stat.size,
            format: format,
            disposition: match.candidates.length == 1
                ? registeredSongIds.contains(match.candidates.single.id)
                      ? PermanentDownloadImportDisposition.alreadyRegistered
                      : PermanentDownloadImportDisposition.recognized
                : match.candidates.isEmpty
                ? PermanentDownloadImportDisposition.unmatched
                : PermanentDownloadImportDisposition.ambiguous,
            songId: match.candidates.length == 1
                ? match.candidates.single.id
                : null,
            matchOrigin: match.candidates.length == 1
                ? match.usedArtist
                      ? PermanentDownloadMatchOrigin.filenameArtist
                      : PermanentDownloadMatchOrigin.filenameOnly
                : match.candidates.isEmpty
                ? PermanentDownloadMatchOrigin.unmatched
                : PermanentDownloadMatchOrigin.ambiguous,
            sourceTitle: match.title,
            sourceArtist: match.artist,
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
    final tree = await _safStorage.validateWritableTree(treeUri);
    if (!tree.canRead || !tree.canWrite || !tree.canReplace) {
      throw const FileSystemException(
        'This Android folder does not allow Navis to read and replace its download index.',
      );
    }
    final profileFingerprint = _profileFingerprint();
    final songIndex = await _openMatchIndex();
    final registered = await _cacheDao.getPermanentEntries();
    final registeredPaths = registered.map((track) => track.filePath).toSet();
    final registeredSongsByPath = <String, String>{
      for (final track in registered) track.filePath: track.songId,
    };
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
              songId: registeredSongsByPath[document.uri],
              sourceUri: document.uri,
              matchOrigin: PermanentDownloadMatchOrigin.alreadyRegistered,
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
            await songIndex.containsId(manifestRecord.songId)) {
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
              matchOrigin: PermanentDownloadMatchOrigin.manifest,
            ),
          );
          continue;
        }
        try {
          final tags = format == 'flac'
              ? await _safStorage.readFlacIdentity(document.uri)
              : const <String, String>{};
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
          final match = await songIndex.match(
            rootPath: '',
            filePath: document.relativePath,
            format: format,
            tags: tags,
          );
          final recognizedTag =
              taggedSongId != null &&
              taggedSongId.isNotEmpty &&
              await songIndex.containsId(taggedSongId);
          items.add(
            PermanentDownloadImportItem(
              relativePath: document.relativePath,
              fileSize: document.size,
              format: format,
              disposition: recognizedTag || match.candidates.length == 1
                  ? (registeredSongIds.contains(
                          taggedSongId ?? match.candidates.single.id,
                        )
                        ? PermanentDownloadImportDisposition.alreadyRegistered
                        : PermanentDownloadImportDisposition.recognized)
                  : match.candidates.isEmpty
                  ? PermanentDownloadImportDisposition.unmatched
                  : PermanentDownloadImportDisposition.ambiguous,
              songId: recognizedTag
                  ? taggedSongId
                  : match.candidates.length == 1
                  ? match.candidates.single.id
                  : null,
              sourceUri: document.uri,
              matchOrigin: recognizedTag
                  ? PermanentDownloadMatchOrigin.embeddedIdentity
                  : match.candidates.length == 1
                  ? match.usedArtist
                        ? PermanentDownloadMatchOrigin.filenameArtist
                        : PermanentDownloadMatchOrigin.filenameOnly
                  : match.candidates.isEmpty
                  ? PermanentDownloadMatchOrigin.unmatched
                  : PermanentDownloadMatchOrigin.ambiguous,
              sourceTitle: match.title,
              sourceArtist: match.artist,
            ),
          );
        } on Object {
          // Providers may revoke a single document while a tree remains
          // usable. Preserve it and explain the exclusion instead of failing
          // the complete review.
          items.add(
            PermanentDownloadImportItem(
              relativePath: document.relativePath,
              fileSize: document.size,
              format: format,
              disposition: PermanentDownloadImportDisposition.inaccessible,
              sourceUri: document.uri,
            ),
          );
        }
      }
      items.sort((a, b) => a.relativePath.compareTo(b.relativePath));
      return PermanentDownloadImportPreview(rootPath: treeUri, items: items);
    } finally {
      manifest?.close();
      if (manifestFile != null) {
        final file = manifestFile;
        await file.delete().catchError((_) => file);
      }
    }
  }

  /// Adopts the reviewed files. Adopted files are never modified: the folder
  /// index records their identity. Index records are written in one
  /// transaction and cache rows in chunks, so the library's cache-derived
  /// views update a few times rather than once per file.
  Future<PermanentDownloadImportResult> commit(
    PermanentDownloadImportPreview preview, {
    Map<String, String> manualSongIds = const <String, String>{},
    bool includeRecognized = true,
  }) async {
    if (_isSafTreeUri(preview.rootPath)) {
      return _commitSaf(
        preview,
        manualSongIds: manualSongIds,
        includeRecognized: includeRecognized,
      );
    }
    final root = Directory(preview.rootPath);
    final manifest = _openManifest(root);
    var imported = 0;
    var skipped = 0;
    final rows = <CachedTracksTableCompanion>[];
    try {
      manifest.execute('BEGIN');
      for (final item in preview.items) {
        if (!includeRecognized &&
            item.disposition == PermanentDownloadImportDisposition.recognized) {
          continue;
        }
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
        rows.add(
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
        imported++;
      }
      manifest.execute('COMMIT');
      await _cacheDao.upsertCachedTracks(rows);
      return PermanentDownloadImportResult(
        importedCount: imported,
        skippedCount: skipped,
      );
    } on Object {
      if (manifest.autocommit == false) manifest.execute('ROLLBACK');
      rethrow;
    } finally {
      manifest.close();
    }
  }

  Future<PermanentDownloadImportResult> _commitSaf(
    PermanentDownloadImportPreview preview, {
    required Map<String, String> manualSongIds,
    required bool includeRecognized,
  }) async {
    final (manifestFile, manifest) = await _openSafManifest(preview.rootPath);
    var imported = 0;
    var skipped = 0;
    final rows = <CachedTracksTableCompanion>[];
    try {
      manifest.execute('BEGIN');
      for (final item in preview.items) {
        if (!includeRecognized &&
            item.disposition == PermanentDownloadImportDisposition.recognized) {
          continue;
        }
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
        // The document is adopted in place: no copy out, no tag rewrite, no
        // copy back. The folder index records its identity.
        rows.add(
          CachedTracksTableCompanion.insert(
            songId: songId,
            filePath: item.sourceUri!,
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
      manifest
        ..execute('COMMIT')
        ..close();
      await _safStorage.writeFromFile(
        treeUri: preview.rootPath,
        relativePath: permanentDownloadManifestFileName,
        source: manifestFile,
        mimeType: 'application/vnd.sqlite3',
      );
      await _cacheDao.upsertCachedTracks(rows);
      return PermanentDownloadImportResult(
        importedCount: imported,
        skippedCount: skipped,
      );
    } finally {
      // sqlite accepts repeated close poorly, so only close when still open.
      try {
        manifest.close();
      } catch (_) {}
      await manifestFile.delete().catchError((_) => manifestFile);
    }
  }

  /// A local copy of a SAF folder's index (or a new, empty one), found
  /// directly rather than by listing the whole folder.
  Future<(File, Database)> _openSafManifest(String treeUri) async {
    final existing = await _safStorage.findDocument(
      treeUri: treeUri,
      relativePath: permanentDownloadManifestFileName,
    );
    final manifestFile = existing == null
        ? File(
            p.join(
              (await Directory.systemTemp.createTemp('navis-downloads-')).path,
              'manifest.sqlite',
            ),
          )
        : await _safStorage.materialize(existing);
    return (manifestFile, _openManifestFile(manifestFile));
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

  /// Adds folder index entries for Navis-created SAF documents, with one
  /// index read and write for the whole batch. The media is not touched:
  /// Navis writes identity tags before uploading its own downloads.
  Future<void> recordDownloadedSafEntries({
    required String treeUri,
    required List<
      ({String relativePath, int fileSize, String songId, String format})
    >
    entries,
  }) async {
    if (entries.isEmpty) return;
    final (manifestFile, manifest) = await _openSafManifest(treeUri);
    try {
      manifest.execute('BEGIN');
      for (final entry in entries) {
        _writeManifestRecord(
          manifest,
          _ManifestRecord(
            relativePath: entry.relativePath,
            songId: entry.songId,
            profileFingerprint: _profileFingerprint(),
            fileSize: entry.fileSize,
            format: entry.format,
            updatedAt: DateTime.now(),
          ),
        );
      }
      manifest
        ..execute('COMMIT')
        ..close();
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
      await manifestFile.delete().catchError((_) => manifestFile);
    }
  }

  /// Writes Navis identity tags into a local file Navis downloaded, before it
  /// is published to a SAF folder.
  Future<void> writeIdentityTags(File file, String songId) =>
      _writeIdentityTags(file, songId);

  /// A matcher that looks catalogue songs up by name as files are reviewed,
  /// instead of normalizing the whole library up front.
  Future<_DownloadMatchIndex> _openMatchIndex() async {
    // Name keys come from the derived search index; make it current.
    await _libraryDao.refreshSongSearchIndex();
    return _DownloadMatchIndex(_libraryDao);
  }

  bool _isNavisSidecar(String path) {
    final name = p.basename(path);
    return name == permanentDownloadManifestFileName ||
        name == '$permanentDownloadManifestFileName-wal' ||
        name == '$permanentDownloadManifestFileName-shm' ||
        name.endsWith(identityRewriteSuffix);
  }

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

class _DownloadMatchResult {
  const _DownloadMatchResult({
    required this.candidates,
    required this.title,
    required this.artist,
    required this.usedArtist,
  });

  final List<DownloadReconciliationSong> candidates;
  final String title;
  final String artist;
  final bool usedArtist;
}

/// Name matching for legacy folders. It deliberately retains all duplicate
/// candidates: uniqueness is a safety requirement, not a ranking decision.
///
/// Titles and artists use the `normalizeSearchText` form stored in
/// `song_search_text`, so each distinct title is one indexed lookup, and
/// titles in any script match (the former ASCII-only form dropped Arabic,
/// CJK, and accented letters).
class _DownloadMatchIndex {
  _DownloadMatchIndex(this._dao);

  final LibraryDao _dao;
  final Map<
    String,
    Future<List<({DownloadReconciliationSong song, String artistKey})>>
  >
  _byTitle =
      <
        String,
        Future<List<({DownloadReconciliationSong song, String artistKey})>>
      >{};
  final Map<String, Future<bool>> _known = <String, Future<bool>>{};

  Future<bool> containsId(String id) =>
      _known[id] ??= _dao.isDownloadReconciliationSong(id);

  Future<_DownloadMatchResult> match({
    required String rootPath,
    required String filePath,
    required String format,
    required Map<String, String> tags,
  }) async {
    final relative = p.relative(filePath, from: rootPath);
    final segments = p.split(relative);
    final title = normalizeSearchText(
      tags['TITLE'] ?? p.basenameWithoutExtension(filePath),
    );
    final artist = normalizeSearchText(
      tags['ARTIST'] ??
          (segments.length > 1 ? segments[segments.length - 2] : ''),
    );
    return _DownloadMatchResult(
      candidates: await _candidates(
        title: title,
        artist: artist,
        format: format,
      ),
      title: title,
      artist: artist,
      usedArtist: artist.isNotEmpty,
    );
  }

  Future<List<DownloadReconciliationSong>> _candidates({
    required String title,
    required String artist,
    required String format,
  }) async {
    if (title.isEmpty) return const <DownloadReconciliationSong>[];
    final songs = await (_byTitle[title] ??= _dao
        .getDownloadReconciliationSongsByTitleKey(title));
    return <DownloadReconciliationSong>[
      for (final entry in songs)
        // A song with no declared suffix is compatible with every format.
        if ((artist.isEmpty || entry.artistKey == artist) &&
            _formatCompatible(entry.song.suffix, format))
          entry.song,
    ];
  }

  static bool _formatCompatible(String? suffix, String format) {
    final normalized = suffix?.trim().toLowerCase() ?? '';
    return normalized.isEmpty || normalized == format;
  }
}
