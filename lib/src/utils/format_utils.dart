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

/// Formats a duration as `m:ss`.
///
/// When [showHours] is true, durations of at least one hour are formatted as
/// `h:mm:ss`.
String formatDuration(Duration duration, {bool showHours = false}) {
  final totalSeconds = duration.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = showHours ? (totalSeconds % 3600) ~/ 60 : totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  if (showHours && hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// Formats a nullable song duration in seconds.
String formatSeconds(
  int? seconds, {
  String fallback = '--:--',
  bool showHours = false,
}) {
  if (seconds == null || seconds <= 0) {
    return fallback;
  }
  return formatDuration(Duration(seconds: seconds), showHours: showHours);
}
