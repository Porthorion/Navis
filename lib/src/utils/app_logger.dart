import 'package:flutter/foundation.dart';

/// Minimal application logger used during bootstrap and early infrastructure.
class AppLogger {
  AppLogger._();

  /// Logs a standard informational message.
  static void info(String message) {
    debugPrint('[Navis][INFO] $message');
  }

  /// Logs a warning message.
  static void warning(String message) {
    debugPrint('[Navis][WARN] $message');
  }

  /// Logs an error message.
  static void error(String message, [Object? error, StackTrace? stackTrace]) {
    debugPrint('[Navis][ERROR] $message');
    if (error != null) {
      debugPrint('[Navis][ERROR] $error');
    }
    if (stackTrace != null) {
      debugPrint('[Navis][ERROR] $stackTrace');
    }
  }
}
