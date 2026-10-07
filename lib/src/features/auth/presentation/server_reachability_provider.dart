import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

typedef PingServer = Future<String> Function();

final reachabilityRetryIntervalProvider = Provider<Duration>((ref) {
  return const Duration(seconds: 30);
});

final reachabilityVisibleRetryLimitProvider = Provider<int>((ref) {
  return 3;
});

final pingServerProvider = Provider<PingServer?>((ref) {
  final api = ref.watch(subsonicApiProvider);
  if (api == null) {
    return null;
  }
  return api.ping;
});

final serverReachabilityControllerProvider =
    NotifierProvider<ServerReachabilityController, ServerReachabilityState>(
      ServerReachabilityController.new,
    );

class ServerReachabilityController extends Notifier<ServerReachabilityState> {
  Timer? _retryTimer;
  bool _isChecking = false;
  bool _pendingCheck = false;
  Future<void>? _inFlightCheck;
  String? _sessionFingerprint;
  bool _hasAuthenticatedSession = false;

  @override
  ServerReachabilityState build() {
    ref.onDispose(_cancelRetryTimer);

    final configState = ref.read(serverConfigStateProvider).asData?.value;
    _hasAuthenticatedSession = configState != null;
    _sessionFingerprint = configState == null
        ? null
        : _toSessionFingerprint(configState);

    if (_hasAuthenticatedSession) {
      unawaited(Future<void>.microtask(_checkReachability));
    }

    ref.listen<AsyncValue<ServerConfigModel?>>(
      serverConfigStateProvider,
      (_, next) => _onServerConfigChanged(next),
    );

    // The API client appears shortly after the session (its credentials are
    // read asynchronously): check as soon as it exists rather than at the
    // next retry, which kept "Server unreachable" up for up to 30 seconds
    // after signing in.
    ref.listen<PingServer?>(pingServerProvider, (previous, next) {
      if (previous == null &&
          next != null &&
          _hasAuthenticatedSession &&
          state.status != ServerReachabilityStatus.online) {
        unawaited(_checkReachability());
      }
    });

    ref.listen<AsyncValue<List<ConnectivityResult>>>(connectivityProvider, (
      _,
      next,
    ) {
      if (!_hasAuthenticatedSession || next.isLoading) {
        return;
      }
      if (state.status == ServerReachabilityStatus.offline) {
        state = state.copyWith(
          status: ServerReachabilityStatus.checking,
          consecutiveFailureCount: 0,
          showRetryBanner: true,
          clearErrorMessage: true,
        );
      }
      unawaited(_checkReachability());
    });

    return const ServerReachabilityState(
      status: ServerReachabilityStatus.checking,
    );
  }

  void _onServerConfigChanged(AsyncValue<ServerConfigModel?> next) {
    if (next.isLoading && !next.hasValue) {
      return;
    }

    final config = next.asData?.value;
    if (config == null) {
      _hasAuthenticatedSession = false;
      _sessionFingerprint = null;
      _cancelRetryTimer();
      state = const ServerReachabilityState(
        status: ServerReachabilityStatus.checking,
      );
      return;
    }

    final fingerprint = _toSessionFingerprint(config);
    if (_sessionFingerprint == fingerprint) {
      return;
    }

    _hasAuthenticatedSession = true;
    _sessionFingerprint = fingerprint;
    _cancelRetryTimer();
    state = state.copyWith(
      status: ServerReachabilityStatus.checking,
      consecutiveFailureCount: 0,
      showRetryBanner: true,
      clearErrorMessage: true,
    );
    unawaited(_checkReachability());
  }

  /// Checks the server now, for example from the offline banner's Retry.
  ///
  /// Joins a check that is already running instead of starting another
  /// ping. The status stays as it is until the check finishes, so the
  /// offline banner stays up while it runs.
  Future<void> retryNow() {
    return _inFlightCheck ?? _checkReachability();
  }

  Future<void> _checkReachability() async {
    if (!_hasAuthenticatedSession) {
      return;
    }
    if (_isChecking) {
      _pendingCheck = true;
      return;
    }

    final ping = ref.read(pingServerProvider);
    if (!_hasAuthenticatedSession) {
      return;
    }
    if (ping == null) {
      // No client for the session yet: nothing has been tried, so this is
      // not "unreachable". The pingServerProvider listener checks once the
      // client exists.
      state = state.copyWith(
        status: ServerReachabilityStatus.checking,
        clearErrorMessage: true,
      );
      return;
    }

    _isChecking = true;
    final check = Completer<void>();
    _inFlightCheck = check.future;
    try {
      await ping();
      if (!_hasAuthenticatedSession) {
        return;
      }
      final now = DateTime.now();
      state = state.copyWith(
        status: ServerReachabilityStatus.online,
        lastCheckedAt: now,
        lastOnlineAt: now,
        consecutiveFailureCount: 0,
        showRetryBanner: true,
        clearErrorMessage: true,
      );
      _cancelRetryTimer();
    } on Object catch (error) {
      if (!_hasAuthenticatedSession) {
        return;
      }
      final now = DateTime.now();
      state = state.copyWith(
        status: ServerReachabilityStatus.offline,
        lastCheckedAt: now,
        lastErrorMessage: _toUserSafeError(error),
        consecutiveFailureCount: state.consecutiveFailureCount + 1,
        showRetryBanner: _shouldShowRetryBanner(
          state.consecutiveFailureCount + 1,
        ),
      );
      _scheduleRetryTimer();
    } finally {
      _isChecking = false;
      _inFlightCheck = null;
      check.complete();
      if (_pendingCheck) {
        _pendingCheck = false;
        unawaited(_checkReachability());
      }
    }
  }

  String _toSessionFingerprint(ServerConfigModel config) {
    return '${config.url}|${config.username}|${config.apiVersion}|${config.useLegacyAuth}';
  }

  void _scheduleRetryTimer() {
    if (_retryTimer != null) {
      return;
    }

    final interval = ref.read(reachabilityRetryIntervalProvider);
    _retryTimer = Timer.periodic(interval, (_) {
      unawaited(_checkReachability());
    });
  }

  void _cancelRetryTimer() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  bool _shouldShowRetryBanner(int consecutiveFailureCount) {
    final visibleLimit = ref.read(reachabilityVisibleRetryLimitProvider);
    return consecutiveFailureCount <= visibleLimit;
  }

  String _toUserSafeError(Object error) {
    return switch (error) {
      SubsonicConnectionException() => 'Could not reach the server.',
      SubsonicAuthException() => 'Authentication failed.',
      SubsonicApiException() => 'Server request failed.',
      _ => 'Could not reach the server.',
    };
  }
}
