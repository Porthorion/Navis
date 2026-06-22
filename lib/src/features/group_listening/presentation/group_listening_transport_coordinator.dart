import 'dart:async';
import 'dart:math' as math;

import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/utils/app_logger.dart';

typedef GroupListeningTransportConnector =
    Future<GroupListeningRealtimeConnection> Function(
      GroupListeningTransportConnectRequest request,
    );

typedef GroupListeningSessionRefreshSender =
    Future<void> Function(GroupListeningSessionRefreshMessage message);

typedef GroupListeningSessionRejoiner =
    Future<GroupListeningJoinResponse> Function();

typedef GroupListeningSnapshotFetcher =
    Future<GroupListeningRoomState> Function();

/// Manages websocket lifecycle, reconnect backoff, and token refresh frames.
class GroupListeningTransportCoordinator {
  GroupListeningTransportCoordinator({
    Duration reconnectInitialDelay = const Duration(seconds: 2),
    Duration reconnectMaxDelay = const Duration(seconds: 60),
    int reconnectMaxAttempts = 8,
    Duration tokenRefreshWindow = const Duration(minutes: 1),
  }) : _reconnectInitialDelay = reconnectInitialDelay,
       _reconnectMaxDelay = reconnectMaxDelay,
       _reconnectMaxAttempts = reconnectMaxAttempts,
       _tokenRefreshWindow = tokenRefreshWindow;

  final Duration _reconnectInitialDelay;
  final Duration _reconnectMaxDelay;
  final int _reconnectMaxAttempts;
  final Duration _tokenRefreshWindow;

  GroupListeningRealtimeConnection? connection;
  StreamSubscription<GroupListeningTransportMessage>? subscription;
  Timer? heartbeatTimer;
  Timer? reconnectTimer;
  int reconnectAttempts = 0;

  void dispose() {
    heartbeatTimer?.cancel();
    reconnectTimer?.cancel();
    unawaited(subscription?.cancel());
    unawaited(connection?.disconnect());
    connection = null;
    subscription = null;
  }

  void scheduleReconnect({
    required void Function() onReconnect,
    required void Function() onGiveUp,
  }) {
    if (reconnectAttempts >= _reconnectMaxAttempts) {
      onGiveUp();
      return;
    }
    reconnectTimer?.cancel();
    final delay = _backoffDelay(reconnectAttempts);
    reconnectTimer = Timer(delay, onReconnect);
    reconnectAttempts++;
  }

  void resetReconnect() {
    reconnectTimer?.cancel();
    reconnectTimer = null;
    reconnectAttempts = 0;
  }

  void scheduleHeartbeat({
    required Duration interval,
    required void Function() onHeartbeat,
  }) {
    heartbeatTimer?.cancel();
    heartbeatTimer = Timer(interval, onHeartbeat);
  }

  bool shouldRefreshAccessToken(
    DateTime accessTokenExpiresAt, {
    bool force = false,
  }) {
    if (force) {
      return true;
    }
    return accessTokenExpiresAt
            .difference(DateTime.now().toUtc())
            .compareTo(_tokenRefreshWindow) <=
        0;
  }

  Future<void> refreshAccessTokenOverTransport({
    required GroupListeningSessionRefreshSender send,
    required String clientConnectionId,
  }) {
    return send(
      GroupListeningSessionRefreshMessage(
        clientConnectionId: clientConnectionId,
      ),
    );
  }

  Duration _backoffDelay(int attempt) {
    final exponent = math.min(attempt, 5);
    final multiplier = 1 << exponent;
    final delayMs = _reconnectInitialDelay.inMilliseconds * multiplier;
    return Duration(
      milliseconds: math.min(delayMs, _reconnectMaxDelay.inMilliseconds),
    );
  }

  /// Atomic reconnect: HTTP rejoin → WS connect → connection.ready → snapshot.
  Future<GroupListeningRoomState?> resumeSession({
    required GroupListeningSessionRejoiner rejoin,
    required GroupListeningTransportConnector connect,
    required GroupListeningSnapshotFetcher fetchSnapshot,
    required Future<void> Function(GroupListeningConnectionReadyMessage ready)
    onConnectionReady,
    required void Function(GroupListeningRoomState snapshot) applySnapshot,
    required void Function() clearSnapshotRequired,
  }) async {
    AppLogger.debug('Group listening: resume_session start');
    final joinResponse = await rejoin();
    final runtime = joinResponse.runtimeContext;
    final connection = await connect(
      GroupListeningTransportConnectRequest(
        session: runtime,
        lastAppliedRoomVersion: joinResponse.roomSnapshot.roomVersion,
        lastAppliedEventId: joinResponse.roomSnapshot.latestEventId,
        lastAppliedQueueVersion: joinResponse.roomSnapshot.queue.queueVersion,
        lastAppliedPlaybackVersion: joinResponse.roomSnapshot.playbackVersion,
        lastAppliedPresenceVersion: joinResponse.roomSnapshot.presenceVersion,
      ),
    );
    this.connection = connection;
    final completer = Completer<GroupListeningRoomState?>();
    late final StreamSubscription<GroupListeningTransportMessage> sub;
    sub = connection.messages.listen((message) async {
      if (message is GroupListeningConnectionReadyMessage) {
        await onConnectionReady(message);
        if (message.requiresSnapshot) {
          final snapshot = await fetchSnapshot();
          applySnapshot(snapshot);
        } else {
          applySnapshot(joinResponse.roomSnapshot);
        }
        clearSnapshotRequired();
        AppLogger.debug('Group listening: resume_session complete');
        if (!completer.isCompleted) {
          completer.complete(joinResponse.roomSnapshot);
        }
        await sub.cancel();
      }
    });
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        AppLogger.warning('Group listening: resume_session timed out');
        return null;
      },
    );
  }
}
