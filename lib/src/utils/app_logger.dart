import 'dart:async';

import 'package:logger/logger.dart';
import 'package:logging/logging.dart' as package_logging;
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

  /// Test-only sink mirroring warnings for observation.
  @visibleForTesting
  static void Function(String)? debugWarningSink;

  /// Logs a warning message.
  static void warning(String message) {
    debugWarningSink?.call(message);
    _logger.w(message);
  }

  // Lives for the process lifetime; there is nothing to cancel it from.
  // ignore: cancel_subscriptions
  static StreamSubscription<package_logging.LogRecord>? _packageLogSubscription;

  /// Forwards package:logging warnings and above to the application log.
  static void forwardPackageLogging() {
    if (_packageLogSubscription != null) return;
    package_logging.Logger.root.level = package_logging.Level.WARNING;
    _packageLogSubscription = package_logging.Logger.root.onRecord.listen((
      record,
    ) {
      if (record.level < package_logging.Level.WARNING) return;
      final error = record.error;
      warning(
        '${record.loggerName}: ${record.message}'
        '${error == null ? '' : ' $error'}',
      );
    });
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
