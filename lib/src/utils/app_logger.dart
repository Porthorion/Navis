import 'dart:async';

import 'package:logger/logger.dart';
import 'package:navis/src/utils/startup_timeline.dart';

import 'package:flutter/foundation.dart';

export 'package:navis/src/utils/startup_timeline.dart'
    show StartupEvent, StartupOutcome, StartupFailure;

/// Minimal application logger used during bootstrap and early infrastructure.
class AppLogger {
  new _();

  static const bool _isReleaseMode = bool.fromEnvironment('dart.vm.product');

  static final StartupTimeline _startupTimeline = StartupTimeline();

  static void startup(
    StartupEvent event, {
    int? attempt,
    int? elapsedMs,
    StartupOutcome? outcome,
    StartupFailure? failureType,
  }) {
    unawaited(
      _startupTimeline
          .record(
            event,
            attempt: attempt,
            elapsedMs: elapsedMs,
            outcome: outcome,
            failureType: failureType,
          )
          .catchError((Object error) {
            warning('Startup details write failed: ${error.runtimeType}');
          }),
    );
  }

  static Future<String> startupDetails() => _startupTimeline.copyDetails();

  static final Logger _logger = Logger(
    level: _isReleaseMode ? Level.warning : Level.trace,
  );

  /// Logs a standard informational message.
  static void info(String message) {
    if (kProfileMode &&
        const bool.fromEnvironment('NAVIS_SYNC_DIAGNOSTICS') &&
        message.startsWith('Audio bootstrap')) {
      debugPrint(message);
    }
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
