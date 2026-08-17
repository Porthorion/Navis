import 'dart:async';

import 'package:flutter/widgets.dart';

/// Defers Flutter activity work until Android has attached an activity.
///
/// Android Auto can start the media service's Flutter engine before
/// [AppLifecycleState.resumed]. Calling UI platform channels from that engine
/// can leave its Dart entrypoint waiting indefinitely, so audio bootstrap must
/// remain independent from this gate.
class AndroidUiBootstrapGate {
  AndroidUiBootstrapGate({
    required this.startUi,
    required this.onError,
  });

  final FutureOr<void> Function() startUi;
  final void Function(Object error, StackTrace stackTrace) onError;
  Future<void>? _uiBootstrap;

  bool get hasStartedUi => _uiBootstrap != null;

  /// Starts UI-only setup exactly once after an Android activity resumes.
  ///
  /// Calls for detached, inactive, paused, or hidden engines intentionally do
  /// nothing. Errors are reported and contained: an optional UI concern must
  /// not bring down the media browser service that owns this isolate.
  Future<void> handleLifecycleState(AppLifecycleState? state) {
    if (state != AppLifecycleState.resumed) {
      return Future<void>.value();
    }
    return _uiBootstrap ??= _startUiSafely();
  }

  Future<void> _startUiSafely() async {
    try {
      await startUi();
    } on Object catch (error, stackTrace) {
      onError(error, stackTrace);
    }
  }
}
