import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

/// Best-effort delete of a file (e.g., partial download on failure).
Future<void> tryDeleteFile(File? file) async {
  if (file == null) return;
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // best-effort
  }
}

/// Delete a cache file and its side-car files (.part, .mime).
///
/// Used by both the download service and the downloads screen.
Future<void> deleteFileWithSuffixes(String filePath) async {
  for (final suffix in <String>['', '.part', '.mime']) {
    try {
      final f = File('$filePath$suffix');
      if (await f.exists()) await f.delete();
    } on FileSystemException {
      // best-effort
    }
  }
}

/// Best-effort prune of empty parent directories up to, but not including,
/// [stopAtDirectoryPath].
Future<void> pruneEmptyParentDirectories({
  required String startDirectoryPath,
  required String stopAtDirectoryPath,
}) async {
  final stopAt = _normalizePath(stopAtDirectoryPath);
  var current = Directory(startDirectoryPath);
  var currentPath = _normalizePath(current.path);

  if (currentPath == stopAt || !_isWithinOrSame(stopAt, currentPath)) {
    return;
  }

  while (currentPath != stopAt) {
    final entries = await current.list().toList();
    if (entries.isNotEmpty) {
      return;
    }
    await current.delete();
    final parent = current.parent;
    final parentPath = _normalizePath(parent.path);
    if (parentPath == currentPath) {
      return;
    }
    current = parent;
    currentPath = parentPath;
    if (!_isWithinOrSame(stopAt, currentPath)) {
      return;
    }
  }
}

/// Open a directory in the platform file manager.
///
/// Returns `true` if the open request was handed off successfully.
Future<bool> openDirectoryInFileManager(String directoryPath) async {
  final normalized = directoryPath.trim();
  if (normalized.isEmpty) {
    return false;
  }

  final directory = Directory(normalized);
  if (!await directory.exists()) {
    return false;
  }

  try {
    if (Platform.isWindows) {
      await Process.start(
        'explorer.exe',
        <String>[p.normalize(normalized)],
        mode: ProcessStartMode.detached,
      );
      return true;
    }
    if (Platform.isMacOS) {
      await Process.start(
        'open',
        <String>[normalized],
        mode: ProcessStartMode.detached,
      );
      return true;
    }
    if (Platform.isLinux) {
      await Process.start(
        'xdg-open',
        <String>[normalized],
        mode: ProcessStartMode.detached,
      );
      return true;
    }

    final uri = Uri.directory(normalized);
    if (!await canLaunchUrl(uri)) {
      return false;
    }
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on Object {
    return false;
  }
}

String _normalizePath(String path) {
  final normalized = p.normalize(path);
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

bool _isWithinOrSame(String parent, String child) {
  return parent == child || p.isWithin(parent, child);
}
