import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class PermanentDownloadPathResolver {
  PermanentDownloadPathResolver({
    required bool Function() readCustomDownloadFolderEnabled,
    required String? Function() readCustomDownloadFolderPath,
    Future<Directory> Function()? readApplicationSupportDirectory,
  }) : _readCustomDownloadFolderEnabled = readCustomDownloadFolderEnabled,
       _readCustomDownloadFolderPath = readCustomDownloadFolderPath,
       _readApplicationSupportDirectory =
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
      return resolveDefaultRoot();
    }
    final trimmed = customDownloadFolderPath?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      throw FileSystemException(
        'Custom download folder is enabled but no folder path is configured.',
      );
    }
    final directory = Directory(trimmed);
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
    final artistDirectory = sanitizePathComponent(
      song.artistName,
      fallback: unknownArtistDirectory,
    );
    final fileStem = sanitizePathComponent(
      song.title,
      fallback: song.id.trim().isEmpty ? unknownTrackFileName : song.id,
    );
    final normalizedExtension = _normalizeExtension(extension);

    final baseDirectory = Directory(
      p.join(rootDirectory.path, artistDirectory),
    );
    final preferredPath = p.join(
      baseDirectory.path,
      '$fileStem.$normalizedExtension',
    );
    if (_isPathAvailable(
      candidatePath: preferredPath,
      existingPath: existingPath,
      reservedPaths: reservedPaths,
    )) {
      return preferredPath;
    }

    final suffix = sha1
        .convert(utf8.encode(song.id))
        .toString()
        .substring(0, 8);
    final collisionPath = p.join(
      baseDirectory.path,
      '$fileStem [$suffix].$normalizedExtension',
    );
    return collisionPath;
  }

  static String sanitizePathComponent(String? raw, {required String fallback}) {
    final source = raw?.trim() ?? '';
    var sanitized = source
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    sanitized = sanitized.replaceAll(RegExp(r'[. ]+$'), '');
    if (sanitized.isEmpty) {
      sanitized = fallback;
    }
    if (_reservedWindowsNames.contains(sanitized.toUpperCase())) {
      sanitized = '_$sanitized';
    }
    return sanitized;
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
    return !File(candidatePath).existsSync();
  }

  String _normalizeExtension(String rawExtension) {
    final trimmed = rawExtension.trim().replaceFirst('.', '');
    return trimmed.isEmpty ? 'bin' : trimmed;
  }
}

const Set<String> _reservedWindowsNames = <String>{
  'CON',
  'PRN',
  'AUX',
  'NUL',
  'COM1',
  'COM2',
  'COM3',
  'COM4',
  'COM5',
  'COM6',
  'COM7',
  'COM8',
  'COM9',
  'LPT1',
  'LPT2',
  'LPT3',
  'LPT4',
  'LPT5',
  'LPT6',
  'LPT7',
  'LPT8',
  'LPT9',
};
