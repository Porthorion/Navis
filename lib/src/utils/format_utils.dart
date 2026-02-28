/// Shared formatting utilities used across the app.
library;

/// Format a byte count as a human-readable string (e.g. "12.3 MB").
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  final gb = mb / 1024;
  return '${gb.toStringAsFixed(2)} GB';
}

/// Format a playback speed multiplier without unnecessary trailing zeroes.
String formatPlaybackSpeed(double speed) {
  final normalized = speed.toStringAsFixed(2);
  final trimmed = normalized
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
  return '$trimmed×';
}
