import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

/// Minimal application logger used during bootstrap and early infrastructure.
class AppLogger {
  AppLogger._();

  static final Logger _logger = Logger(
    level: kReleaseMode ? Level.warning : Level.trace,
  );

  /// Logs a standard informational message.
  static void info(String message) {
    _logger.i(message);
  }

  /// Logs a warning message.
  static void warning(String message) {
    _logger.w(message);
  }

  /// Logs an error message.
  static void error(String message, [Object? error, StackTrace? stackTrace]) {
    _logger.e(message, error: error, stackTrace: stackTrace);
  }
}
