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
    try {
      final entries = await current.list().toList();
      if (entries.isNotEmpty) {
        return;
      }
      await current.delete();
    } on FileSystemException {
      // Already gone, not empty after all, or locked (Windows): stop here.
      return;
    }
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
      await Process.start('explorer.exe', <String>[
        p.normalize(normalized),
      ], mode: ProcessStartMode.detached);
      return true;
    }
    if (Platform.isMacOS) {
      await Process.start('open', <String>[
        normalized,
      ], mode: ProcessStartMode.detached);
      return true;
    }
    if (Platform.isLinux) {
      await Process.start('xdg-open', <String>[
        normalized,
      ], mode: ProcessStartMode.detached);
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

/// Longest file or folder name Navis writes, in UTF-16 code units. Keeps
/// `<root>/<artist>/<title> [hash].<ext>` well inside Windows' 260 character
/// path limit for typical roots, and every platform's 255-byte component
/// limit for most scripts.
const int safeFileNameMaxLength = 120;

/// [raw] as a single file or folder name that every platform accepts, or the
/// equally cleaned [fallback] when nothing usable remains (which may itself
/// be empty).
///
/// Path separators, `<>:"|?*` and control characters become `_`, whitespace
/// collapses, the name is capped at [maxLength] without splitting a
/// surrogate pair, trailing dots and spaces are dropped (Windows would drop
/// them), and Windows device names such as `CON.flac` are prefixed with `_`.
String safeFileNameComponent(
  String? raw, {
  required String fallback,
  int maxLength = safeFileNameMaxLength,
}) {
  var cleaned = _cleanFileName(raw, maxLength);
  if (cleaned.isEmpty) cleaned = _cleanFileName(fallback, maxLength);
  if (cleaned.isNotEmpty && _isReservedWindowsName(cleaned)) {
    cleaned = '_$cleaned';
  }
  return cleaned;
}

String _cleanFileName(String? raw, int maxLength) {
  var value = (raw ?? '')
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F\x7F]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (value.length > maxLength) {
    var end = maxLength;
    final unit = value.codeUnitAt(end - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF) end--;
    value = value.substring(0, end);
  }
  return value.replaceAll(RegExp(r'[. ]+$'), '');
}

/// Windows reserves these device names with any extension and in any case.
bool _isReservedWindowsName(String name) {
  final stem = name.split('.').first.trimRight().toUpperCase();
  return const <String>{
        'CON',
        'PRN',
        'AUX',
        'NUL',
        r'CONIN$',
        r'CONOUT$',
        r'CLOCK$',
      }.contains(stem) ||
      RegExp(r'^(COM|LPT)[0-9\u00B9\u00B2\u00B3]$').hasMatch(stem);
}
