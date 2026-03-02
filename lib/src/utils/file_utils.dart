import 'dart:io';

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
