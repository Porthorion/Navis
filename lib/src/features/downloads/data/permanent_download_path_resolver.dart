import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/utils/file_utils.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class PermanentDownloadPathResolver {
  new({
    required this._readCustomDownloadFolderEnabled,
    required this._readCustomDownloadFolderPath,
    Future<Directory> Function()? readApplicationSupportDirectory,
  }) : _readApplicationSupportDirectory =
           readApplicationSupportDirectory ?? getApplicationSupportDirectory;

  static const String unknownArtistDirectory = 'Unknown Artist';
  static const String unknownTrackFileName = 'Unknown Track';

  final bool Function() _readCustomDownloadFolderEnabled;
  final String? Function() _readCustomDownloadFolderPath;
  final Future<Directory> Function() _readApplicationSupportDirectory;

  Future<Directory> resolveActiveRoot() {
    return resolveRootFor(
      customDownloadFolderEnabled: _readCustomDownloadFolderEnabled(),
      customDownloadFolderPath: _readCustomDownloadFolderPath(),
    );
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
      throw FileSystemException(
        'Custom download folder is enabled but no folder path is configured.',
      );
    }
    final directory = Directory(trimmed);
    // Keep metadata access asynchronous so storage latency cannot stall UI.
    // ignore: avoid_slow_async_io
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
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
    final normalizedExtension = _normalizeExtension(extension);
    final baseDirectory = p.join(rootDirectory.path, artistDirectory);
    String candidate(String stem) =>
        p.join(baseDirectory, '$stem.$normalizedExtension');

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
    for (var attempt = 1; ; attempt++) {
      final tag = attempt == 1 ? suffix : '$suffix-$attempt';
      final path = candidate('$fileStem [$tag]');
      if (attempt >= 100 ||
          _isPathAvailable(
            candidatePath: path,
            existingPath: existingPath,
            reservedPaths: reservedPaths,
          )) {
        return path;
      }
    }
  }

  /// Longest file or folder name Navis writes; see [safeFileNameComponent].
  static const int maxComponentLength = safeFileNameMaxLength;

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

  String _normalizeExtension(String rawExtension) {
    final trimmed = rawExtension.trim().replaceFirst('.', '');
    return trimmed.isEmpty ? 'bin' : trimmed;
  }
}
