import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/utils/file_utils.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum DownloadFolderProblem { unset, missing, inaccessible, noSpace }

/// A user-owned download destination needs attention, rather than a retry.
class DownloadFolderUnavailableException extends FileSystemException {
  const new(this.problem, {OSError? osError})
    : super('Custom download folder needs attention.', '', osError);
  final DownloadFolderProblem problem;
}

class PermanentDownloadPathResolver {
  new({
    required this._readCustomDownloadFolderEnabled,
    required this._readCustomDownloadFolderPath,
    Future<Directory> Function()? readApplicationSupportDirectory,
    Future<void> Function(Directory)? validateCustomRoot,
  }) : _readApplicationSupportDirectory =
           readApplicationSupportDirectory ?? getApplicationSupportDirectory,
       _validateCustomRoot = validateCustomRoot ?? _probeWritableRoot;

  static const String unknownArtistDirectory = 'Unknown Artist';
  static const String unknownTrackFileName = 'Unknown Track';

  final bool Function() _readCustomDownloadFolderEnabled;
  final String? Function() _readCustomDownloadFolderPath;
  final Future<Directory> Function() _readApplicationSupportDirectory;

  final Future<void> Function(Directory) _validateCustomRoot;

  static Future<void> _probeWritableRoot(Directory directory) async {
    final probe = await directory.createTemp('.navis-write-');
    try {
      await File(p.join(probe.path, 'probe'))
          .writeAsBytes(const [0], flush: true);
    } finally {
      await probe.delete(recursive: true);
    }
  }

  Future<Directory> resolveDefaultRoot() async {
    final root = await _readApplicationSupportDirectory();
    final directory = Directory(p.join(root.path, 'audio', 'permanent'));
    // Keep metadata access asynchronous so storage latency cannot stall UI.
    // ignore: avoid_slow_async_io
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<Directory> resolveRootFor({
    required bool customDownloadFolderEnabled,
    String? customDownloadFolderPath,
  }) async {
    if (!customDownloadFolderEnabled) {
      return await resolveDefaultRoot();
    }
    final trimmed = customDownloadFolderPath?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      throw const DownloadFolderUnavailableException(
        DownloadFolderProblem.unset,
      );
    }
    final directory = Directory(trimmed);
    try {
      // A missing mount must never be replaced by a folder on another volume.
      // ignore: avoid_slow_async_io
      if (!await directory.exists()) {
        throw const DownloadFolderUnavailableException(
          DownloadFolderProblem.missing,
        );
      }
      await _validateCustomRoot(directory);
      return directory;
    } on DownloadFolderUnavailableException {
      rethrow;
    } on FileSystemException catch (error) {
      throw DownloadFolderUnavailableException(
        DownloadFolderProblem.inaccessible,
        osError: error.osError,
      );
    }
  }

  Future<String> resolveSongPath({
    required SongsTableData song,
    required String extension,
    String? existingPath,
    Set<String> reservedPaths = const <String>{},
    bool? customDownloadFolderEnabled,
    String? customDownloadFolderPath,
  }) async {
    final root = await resolveRootFor(
      customDownloadFolderEnabled:
          customDownloadFolderEnabled ?? _readCustomDownloadFolderEnabled(),
      customDownloadFolderPath:
          customDownloadFolderPath ?? _readCustomDownloadFolderPath(),
    );
    return resolveSongPathInDirectory(
      rootDirectory: root,
      song: song,
      extension: extension,
      existingPath: existingPath,
      reservedPaths: reservedPaths,
    );
  }

  String resolveSongPathInDirectory({
    required Directory rootDirectory,
    required SongsTableData song,
    required String extension,
    String? existingPath,
    Set<String> reservedPaths = const <String>{},
  }) {
    return resolvePathInDirectory(
      rootDirectory: rootDirectory,
      artist: song.artistName,
      title: song.title,
      titleFallback: song.id.trim().isEmpty ? unknownTrackFileName : song.id,
      identity: song.id,
      extension: extension,
      existingPath: existingPath,
      reservedPaths: reservedPaths,
    );
  }

  /// `<root>/<artist>/<title>.<ext>`, or `<title> [<hash>].<ext>` (then
  /// `[<hash>-2]`, `-3`, ...) when that name is taken by another file or
  /// reserved in the current batch.
  String resolvePathInDirectory({
    required Directory rootDirectory,
    required String? artist,
    required String? title,
    required String titleFallback,
    required String identity,
    required String extension,
    String? existingPath,
    Set<String> reservedPaths = const <String>{},
  }) {
    final artistDirectory = sanitizePathComponent(
      artist,
      fallback: unknownArtistDirectory,
    );
    final fileStem = sanitizePathComponent(title, fallback: titleFallback);
    final normalizedExtension = safeFileExtension(extension);
    final baseDirectory = p.join(rootDirectory.path, artistDirectory);
    String candidate(String stem) {
      final path = p.join(baseDirectory, '$stem.$normalizedExtension');
      if (!p.isWithin(rootDirectory.path, path)) {
        throw FileSystemException('Download path escapes its root.', path);
      }
      return path;
    }

    final preferredPath = candidate(fileStem);
    if (_isPathAvailable(
      candidatePath: preferredPath,
      existingPath: existingPath,
      reservedPaths: reservedPaths,
    )) {
      return preferredPath;
    }
    final suffix = sha1
        .convert(utf8.encode(identity))
        .toString()
        .substring(0, 8);
    for (var attempt = 1; attempt <= 100; attempt++) {
      final tag = attempt == 1 ? suffix : '$suffix-$attempt';
      final path = candidate('$fileStem [$tag]');
      if (_isPathAvailable(
        candidatePath: path,
        existingPath: existingPath,
        reservedPaths: reservedPaths,
      )) {
        return path;
      }
    }
    throw FileSystemException('No free download path after 100 attempts.');
  }

  static String sanitizePathComponent(String? raw, {required String fallback}) {
    final cleaned = safeFileNameComponent(raw, fallback: fallback);
    return cleaned.isEmpty ? unknownTrackFileName : cleaned;
  }

  bool _isPathAvailable({
    required String candidatePath,
    required Set<String> reservedPaths,
    String? existingPath,
  }) {
    if (existingPath != null && p.equals(candidatePath, existingPath)) {
      return true;
    }
    if (reservedPaths.contains(candidatePath)) {
      return false;
    }
    if (!File(candidatePath).existsSync()) return true;
    // Taken only by the file itself, named through another spelling of its
    // folder (a link, junction or mapped drive).
    try {
      return existingPath != null &&
          File(existingPath).existsSync() &&
          FileSystemEntity.identicalSync(candidatePath, existingPath);
    } on FileSystemException {
      return false;
    }
  }
}
