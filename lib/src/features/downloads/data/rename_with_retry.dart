import 'dart:io';

/// Renames [file] to [path] with up to three attempts for brief filesystem holds.
///
/// Windows refuses the replace while another process (typically an
/// antivirus scan of the new file) holds it open; that clears quickly.
Future<void> renameWithRetry(File file, String path) async {
  for (var attempt = 1; ; attempt++) {
    try {
      await file.rename(path);
      return;
    } on FileSystemException {
      if (attempt == 3) rethrow;
      await Future<void>.delayed(Duration(milliseconds: 200 * attempt));
    }
  }
}
