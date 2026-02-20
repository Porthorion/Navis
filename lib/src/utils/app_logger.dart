import 'package:logger/logger.dart';

/// Minimal application logger used during bootstrap and early infrastructure.
class AppLogger {
  AppLogger._();

  static const bool _isReleaseMode = bool.fromEnvironment('dart.vm.product');

  static final Logger _logger = Logger(
    level: _isReleaseMode ? Level.warning : Level.trace,
  );

  /// Logs a standard informational message.
  static void info(String message) {
    _logger.i(message);
  }

  /// Logs a warning message.
  static void warning(String message) {
    _logger.w(message);
  }

  /// Logs a low-priority debug message.
  static void debug(String message) {
    _logger.t(message);
  }

  /// Logs an error message.
  static void error(String message, [Object? error, StackTrace? stackTrace]) {
    _logger.e(message, error: error, stackTrace: stackTrace);
  }
}
