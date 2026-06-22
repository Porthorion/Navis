import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_server_clock_estimator.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_mutation_outbox.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_providers.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_state_applier.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';

typedef GroupListeningErrorMapper =
    GroupListeningErrorState Function(
      Object error, {
      required String fallbackMessage,
      required GroupListeningErrorCode fallbackCode,
    });

/// Manages websocket transport lifecycle, heartbeats, and inbound frames.
class GroupListeningSessionTransportHandler {
  GroupListeningSessionTransportHandler({
    required this.ref,
    required this.readState,
    required this.writeState,
    required this.readRuntimeSession,
    required this.writeRuntimeSession,
    required this.stateApplier,
    required this.serverClockEstimator,
    required this.asFailure,
    required this.setFailure,
    required this.ensureFreshSession,
    required this.discoverSessionServer,
    required this.resolveBestBundledServer,
    required this.finishInvalidatedSessionCleanup,
    required this.shouldCollapseToLocalCleanup,
    required this.isFatalSessionFailure,
    required this.shouldAutoReconnectAfterFailure,
    required this.reconnect,
    required this.handleMutationAck,
    required this.handleMutationNack,
    required this.abortMutationOutboxTransport,
    required this.resumeMutationOutbox,
    required this.readMutationOutbox,
    required this.resetClientSequence,
    required this.requireConfiguration,
    required this.matchesStoredSession,
    required this.cancelSnapshotRetry,
    this.reconnectInitialDelay = const Duration(seconds: 2),
    this.reconnectMaxDelay = const Duration(seconds: 60),
    this.reconnectMaxAttempts = 8,
    this.ackLagGrace = const Duration(seconds: 2),
    this.serverUpgradeCheckInterval = const Duration(minutes: 5),
    this.serverMigrationTimeout = const Duration(seconds: 15),
  });

  final Ref ref;
  final GroupListeningSessionStateReader readState;
  final GroupListeningSessionStateWriter writeState;
  final GroupListeningSessionRuntimeContext? Function() readRuntimeSession;
  final void Function(GroupListeningSessionRuntimeContext? session)
  writeRuntimeSession;
  final GroupListeningSessionStateApplier stateApplier;
  final GroupListeningServerClockEstimator serverClockEstimator;
  final GroupListeningErrorMapper asFailure;
  final GroupListeningSessionState Function(
    GroupListeningErrorState failure, {
    GroupListeningConnectionStatus? connectionStatus,
    StackTrace? stackTrace,
  })
  setFailure;
  final Future<GroupListeningSessionRuntimeContext> Function({
    bool force,
  })
  ensureFreshSession;
  final Future<GroupListeningCapabilityDiscovery> Function(
    GroupListeningSessionRuntimeContext session,
  )
  discoverSessionServer;
  final Future<GroupListeningResolvedVoyageServer?> Function({
    String? preferredUrl,
  })
  resolveBestBundledServer;
  final Future<GroupListeningSessionState> Function(
    GroupListeningErrorState failure,
  )
  finishInvalidatedSessionCleanup;
  final bool Function(GroupListeningErrorCode code)
  shouldCollapseToLocalCleanup;
  final bool Function(GroupListeningErrorCode code) isFatalSessionFailure;
  final bool Function(GroupListeningErrorState failure)
  shouldAutoReconnectAfterFailure;
  final Future<GroupListeningSessionState> Function() reconnect;
  final void Function(GroupListeningMutationAckMessage message)
  handleMutationAck;
  final void Function(GroupListeningMutationRejectedMessage message)
  handleMutationNack;
  final void Function() abortMutationOutboxTransport;
  final void Function() resumeMutationOutbox;
  final GroupListeningMutationOutbox? Function() readMutationOutbox;
  final void Function() resetClientSequence;
  final GroupListeningClientConfiguration Function() requireConfiguration;
  final bool Function(
    GroupListeningStoredSession stored,
    GroupListeningSessionRuntimeContext expected,
  )
  matchesStoredSession;
  final void Function() cancelSnapshotRetry;
  final Duration reconnectInitialDelay;
  final Duration reconnectMaxDelay;
  final int reconnectMaxAttempts;
  final Duration ackLagGrace;
  final Duration serverUpgradeCheckInterval;
  final Duration serverMigrationTimeout;

  GroupListeningRealtimeConnection? connection;
  StreamSubscription<GroupListeningTransportMessage>? transportSubscription;
  Timer? heartbeatTimer;
  Timer? serverUpgradeTimer;
  Timer? reconnectTimer;
  Timer? ackLagTimer;
  int reconnectAttempts = 0;
  int? ackLagRoomVersion;
  GroupListeningCapabilityDiscovery? connectingDiscovery;
  bool serverUpgradeInProgress = false;
  bool transportTeardownInProgress = false;
  bool transportTeardownFailureObserved = false;
  String? loadingStatusKey;
  DateTime? loadingStartedAt;

  GroupListeningSessionState get state => readState();

  set state(GroupListeningSessionState value) => writeState(value);

  Future<GroupListeningSessionState> connect() async {
    final session = readRuntimeSession();
    if (session == null) {
      return setFailure(
        const GroupListeningErrorState(
          code: GroupListeningErrorCode.sessionUnavailable,
          message: 'No active Voyage session is available to connect.',
        ),
      );
    }

    state = state.copyWith(
      status:
          state.connection.status == GroupListeningConnectionStatus.connected
          ? GroupListeningSessionStatus.connected
          : GroupListeningSessionStatus.connecting,
      connection: state.connection.copyWith(
        status:
            state.connection.status == GroupListeningConnectionStatus.connected
            ? GroupListeningConnectionStatus.connected
            : GroupListeningConnectionStatus.connecting,
        clearDisconnectReason: true,
      ),
      clearFailure: true,
    );

    try {
      await disposeTransport();
      resetClientSequence();
      final freshSession = await ensureFreshSession();
      connectingDiscovery = await discoverSessionServer(freshSession);
      final nextConnection = await ref
          .read(groupListeningRepositoryProvider)
          .connect(
            GroupListeningTransportConnectRequest(
              session: freshSession,
              lastAppliedRoomVersion: state.lastAppliedRoomVersion,
              lastAppliedEventId: state.lastAppliedEventId,
              lastAppliedQueueVersion: state.room?.queue.queueVersion ?? 0,
              lastAppliedPlaybackVersion: state.room?.playbackVersion ?? 0,
              lastAppliedPresenceVersion: state.room?.presenceVersion ?? 0,
            ),
          );
      connection = nextConnection;
      transportSubscription = nextConnection.messages.listen(
        handleTransportMessage,
        onError: (Object error, StackTrace stackTrace) {
          handleTransportFailure(
            asFailure(
              error,
              fallbackMessage: 'Voyage transport stream failed.',
              fallbackCode: GroupListeningErrorCode.transportDisconnected,
            ),
            stackTrace: stackTrace,
          );
        },
      );
      return state;
    } on Object catch (error, stackTrace) {
      final failure = asFailure(
        error,
        fallbackMessage: 'Unable to connect to Voyage room realtime transport.',
        fallbackCode: GroupListeningErrorCode.transportUnavailable,
      );
      if (shouldCollapseToLocalCleanup(failure.code)) {
        return finishInvalidatedSessionCleanup(failure);
      }
      if (shouldAutoReconnectAfterFailure(failure)) {
        scheduleAutoReconnect();
      }
      return setFailure(
        failure,
        connectionStatus: GroupListeningConnectionStatus.disconnected,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> disposeTransport() async {
    serverClockEstimator.clear();
    heartbeatTimer?.cancel();
    heartbeatTimer = null;
    serverUpgradeTimer?.cancel();
    serverUpgradeTimer = null;
    reconnectTimer?.cancel();
    reconnectTimer = null;
    clearAckLagRecovery();
    reconnectAttempts = 0;
    connectingDiscovery = null;
    await transportSubscription?.cancel();
    transportSubscription = null;
    final activeConnection = connection;
    connection = null;
    abortMutationOutboxTransport();
    if (activeConnection != null) {
      await activeConnection.disconnect();
    }
  }

  void beginTransportTeardown() {
    transportTeardownInProgress = true;
    transportTeardownFailureObserved = false;
  }

  void endTransportTeardown() {
    transportTeardownInProgress = false;
    transportTeardownFailureObserved = false;
  }

  Future<GroupListeningSessionRuntimeContext> refreshAccessTokenOverTransport(
    GroupListeningSessionRuntimeContext session,
    Future<GroupListeningSessionRuntimeContext> Function(
      GroupListeningSessionRuntimeContext session,
    )
    rejoinCurrentSession,
  ) async {
    final activeConnection = connection;
    final clientConnectionId = state.connection.clientConnectionId;
    if (activeConnection == null ||
        clientConnectionId == null ||
        !state.connection.isConnected) {
      return rejoinCurrentSession(session);
    }
    await activeConnection.send(
      GroupListeningSessionRefreshMessage(
        clientConnectionId: clientConnectionId,
      ),
    );
    return readRuntimeSession() ?? session;
  }

  void handleTransportMessage(GroupListeningTransportMessage message) {
    if (message is GroupListeningConnectionWelcomeMessage) {
      markTransportReady(
        clientConnectionId: message.clientConnectionId,
        heartbeatInterval: message.heartbeatInterval,
        memberStaleTimeout: message.memberStaleTimeout,
        serverTime: message.serverTime,
      );
      return;
    }
    if (message is GroupListeningConnectionReadyMessage) {
      markTransportReady(
        clientConnectionId: message.clientConnectionId,
        heartbeatInterval: message.heartbeatInterval,
        memberStaleTimeout: message.memberStaleTimeout,
        serverTime: message.serverTime,
      );
      if (message.playbackEpoch > 0) {
        state = stateApplier.withSyncHealth(
          state.copyWith(
            localPlaybackEpoch: message.playbackEpoch,
            catchUpAligned: true,
            room: state.room?.copyWith(playbackEpoch: message.playbackEpoch),
          ),
        );
      }
      if (message.requiresSnapshot) {
        stateApplier.requestSnapshotRecovery(
          'replay-snapshot-required',
          GroupListeningErrorState(
            code: GroupListeningErrorCode.snapshotRequired,
            message: 'Voyage replay resume requires a fresh snapshot.',
            retryable: true,
            roomVersion: message.roomVersion,
            details: <String, Object?>{
              'latest_event_id': message.latestEventId,
              'last_applied_event_id': state.lastAppliedEventId,
            },
          ),
        );
      }
      return;
    }
    if (message is GroupListeningRoomSnapshotMessage) {
      stateApplier.applySnapshot(message.snapshot);
      return;
    }
    if (message is GroupListeningRoomEventMessage) {
      stateApplier.applyRealtimeEvent(message.event);
      return;
    }
    if (message is GroupListeningPresenceUpdatedMessage) {
      final room = state.room;
      if (room == null || room.roomId != message.roomId) {
        return;
      }
      if (message.roomVersion < state.lastAppliedRoomVersion) {
        return;
      }
      if (message.roomVersion > state.lastAppliedRoomVersion + 1) {
        stateApplier.requestSnapshotRecovery(
          'presence-gap',
          GroupListeningErrorState(
            code: GroupListeningErrorCode.snapshotRequired,
            message: 'Voyage presence update arrived ahead of room state.',
            retryable: true,
            roomVersion: message.roomVersion,
          ),
        );
        return;
      }
      state = state.copyWith(
        room: room.copyWith(
          presenceVersion: message.presenceVersion,
          members: stateApplier.mergeMembers(
            existing: room.members,
            updates: message.members,
            removedMemberIds: const <String>[],
          ),
        ),
      );
      return;
    }
    if (message is GroupListeningHeartbeatAckMessage) {
      recordServerClockSample(message);
      final receivedAt = DateTime.now();
      state = state.copyWith(
        connection: state.connection.copyWith(
          lastHeartbeatAckAt: receivedAt,
          lastServerTime: message.serverTime,
        ),
      );
      if (!state.snapshotRequired &&
          message.roomVersion > state.lastAppliedRoomVersion) {
        scheduleAckLagRecovery(message.roomVersion);
      } else {
        clearAckLagRecovery(upToRoomVersion: state.lastAppliedRoomVersion);
      }
      return;
    }
    if (message is GroupListeningMutationAckMessage) {
      handleMutationAck(message);
      return;
    }
    if (message is GroupListeningRoomClosedMessage) {
      writeRuntimeSession(null);
      unawaited(ref.read(groupListeningSessionCredentialStoreProvider).clear());
      state = state.copyWith(
        status: GroupListeningSessionStatus.idle,
        connection: const GroupListeningConnectionState.disconnected(),
        clearActiveInviteCode: true,
        room: state.room?.copyWith(
          roomStatus: GroupListeningRoomStatus.closed,
          roomVersion: message.roomVersion,
          serverTime: message.closedAt,
        ),
      );
      return;
    }
    if (message is GroupListeningTransportDisconnectedMessage) {
      handleTransportFailure(
        message.error ??
            const GroupListeningErrorState(
              code: GroupListeningErrorCode.transportDisconnected,
              message: 'Voyage realtime transport disconnected.',
              retryable: true,
            ),
      );
      return;
    }
    if (message is GroupListeningMutationRejectedMessage) {
      handleMutationNack(message);
      return;
    }
    if (message is GroupListeningSessionRefreshedMessage) {
      applySessionRefreshed(message);
      return;
    }
    if (message is GroupListeningTransportErrorMessage) {
      handleTransportFailure(message.error);
    }
  }

  void applySessionRefreshed(GroupListeningSessionRefreshedMessage message) {
    final runtime = readRuntimeSession();
    if (runtime == null) {
      return;
    }
    writeRuntimeSession(
      GroupListeningSessionRuntimeContext(
        roomId: runtime.roomId,
        memberId: runtime.memberId,
        role: runtime.role,
        authVersion: runtime.authVersion,
        voyageBaseUrl: runtime.voyageBaseUrl,
        sourceServerFingerprint: runtime.sourceServerFingerprint,
        accessToken: message.accessToken,
        accessTokenExpiresAt: message.accessTokenExpiresAt,
        rejoinToken: runtime.rejoinToken,
        protocolVersion: runtime.protocolVersion,
      ),
    );
    unawaited(persistRuntimeSession());
  }

  Future<void> persistRuntimeSession() async {
    final runtime = readRuntimeSession();
    if (runtime == null) {
      return;
    }
    final stored = await ref
        .read(groupListeningSessionCredentialStoreProvider)
        .read();
    if (stored == null) {
      return;
    }
    await ref
        .read(groupListeningSessionCredentialStoreProvider)
        .save(
          GroupListeningStoredSession(
            roomId: runtime.roomId,
            memberId: runtime.memberId,
            role: runtime.role,
            authVersion: runtime.authVersion,
            voyageBaseUrl: runtime.voyageBaseUrl,
            sourceServerFingerprint: runtime.sourceServerFingerprint,
            rejoinToken: runtime.rejoinToken,
            client: stored.client,
            lastAppliedRoomVersion: state.lastAppliedRoomVersion,
            lastAppliedEventId: state.lastAppliedEventId,
            protocolVersion: runtime.protocolVersion,
          ),
        );
  }

  void markTransportReady({
    required String clientConnectionId,
    required Duration heartbeatInterval,
    required Duration memberStaleTimeout,
    required DateTime serverTime,
  }) {
    scheduleHeartbeat(after: heartbeatInterval);
    reconnectTimer?.cancel();
    reconnectTimer = null;
    reconnectAttempts = 0;
    clearAckLagRecovery();
    final connectedDiscovery = connectingDiscovery;
    connectingDiscovery = null;
    final connectedSession = readRuntimeSession();
    serverClockEstimator.recordInstantSample(
      serverTime: serverTime,
      clientReceiveTime: DateTime.now().toUtc(),
    );
    final shouldCatchUp =
        state.status == GroupListeningSessionStatus.reconnecting ||
        state.connection.reconnectAttempt > 0;
    state = stateApplier.withSyncHealth(
      state.copyWith(
        status: GroupListeningSessionStatus.connected,
        connection: state.connection.copyWith(
          status: GroupListeningConnectionStatus.connected,
          clientConnectionId: clientConnectionId,
          heartbeatInterval: heartbeatInterval,
          memberStaleTimeout: memberStaleTimeout,
          connectedAt: DateTime.now(),
          lastServerTime: serverTime,
          connectedServerUrl: connectedSession?.voyageBaseUrl,
          connectedServerVersion: connectedDiscovery?.serverVersion,
          serverClockOffset: serverClockEstimator.clockOffset,
          clearDisconnectReason: true,
        ),
        clearFailure: true,
      ),
    );
    if (shouldCatchUp) {
      stateApplier.enterCatchUpFromServer(
        serverEpoch: state.room?.playbackEpoch ?? 0,
      );
    }
    resumeMutationOutbox();
    scheduleServerUpgradeCheck();
  }

  void recordServerClockSample(GroupListeningHeartbeatAckMessage message) {
    final clientTime = message.clientTime;
    final serverReceiveTime = message.serverReceiveTime;
    final serverSendTime = message.serverSendTime;
    if (clientTime == null ||
        serverReceiveTime == null ||
        serverSendTime == null) {
      return;
    }
    final accepted = serverClockEstimator.recordSample(
      clientSendTime: clientTime,
      serverReceiveTime: serverReceiveTime,
      serverSendTime: serverSendTime,
      clientReceiveTime: DateTime.now().toUtc(),
    );
    if (!accepted) {
      return;
    }
    final medianOffset = serverClockEstimator.clockOffset;
    AppLogger.debug(
      'Group listening heartbeat clock sample: '
      'rtt_ms=${serverClockEstimator.lastRoundTripTime?.inMilliseconds}, '
      'offset_ms=${serverClockEstimator.lastSampleOffset?.inMilliseconds}, '
      'median_offset_ms=${medianOffset.inMilliseconds}',
    );
    state = state.copyWith(
      connection: state.connection.copyWith(
        serverClockOffset: medianOffset,
        lastRoundTripTime: serverClockEstimator.lastRoundTripTime,
      ),
    );
  }

  void recordPlaybackLoadingState(PlaybackSnapshot snapshot) {
    final loading =
        snapshot.isLoading ||
        snapshot.processingState.name == 'loading' ||
        snapshot.processingState.name == 'buffering';
    if (!loading) {
      loadingStatusKey = null;
      loadingStartedAt = null;
      return;
    }

    final key =
        '${snapshot.loadingSongId ?? snapshot.currentSongId ?? ''}'
        '|${snapshot.processingState.name}';
    if (loadingStatusKey == key && loadingStartedAt != null) {
      return;
    }
    loadingStatusKey = key;
    loadingStartedAt = DateTime.now().toUtc();
  }

  Duration? playbackLoadingAge(PlaybackSnapshot snapshot) {
    final loading =
        snapshot.isLoading ||
        snapshot.processingState.name == 'loading' ||
        snapshot.processingState.name == 'buffering';
    if (!loading) {
      return null;
    }
    final startedAt = loadingStartedAt;
    if (startedAt == null) {
      recordPlaybackLoadingState(snapshot);
      return Duration.zero;
    }
    final age = DateTime.now().toUtc().difference(startedAt);
    return age.isNegative ? Duration.zero : age;
  }

  void handleTransportFailure(
    GroupListeningErrorState failure, {
    StackTrace? stackTrace,
  }) {
    final isRecoverable =
        failure.code == GroupListeningErrorCode.snapshotRequired ||
        failure.code == GroupListeningErrorCode.staleVersion;
    if (!isRecoverable) {
      heartbeatTimer?.cancel();
      heartbeatTimer = null;
    }
    if (transportTeardownInProgress) {
      transportTeardownFailureObserved = true;
      return;
    }
    if (stackTrace != null) {
      AppLogger.warning(
        'Group listening transport failure: ${failure.code.name}',
      );
    }
    if (failure.code == GroupListeningErrorCode.snapshotRequired ||
        failure.code == GroupListeningErrorCode.staleVersion) {
      stateApplier.requestSnapshotRecovery(
        'transport-${failure.code.name}',
        failure,
      );
      return;
    }
    if (shouldCollapseToLocalCleanup(failure.code)) {
      unawaited(finishInvalidatedSessionCleanup(failure));
      return;
    }
    if (failure.code == GroupListeningErrorCode.unsupportedProtocolVersion ||
        failure.code == GroupListeningErrorCode.transportUnavailable ||
        failure.code == GroupListeningErrorCode.transportDisconnected) {
      unawaited(checkForBundledServerUpgrade(triggeredByFailure: true));
    }
    if (isFatalSessionFailure(failure.code)) {
      cancelSnapshotRetry();
      reconnectTimer?.cancel();
      reconnectTimer = null;
      reconnectAttempts = 0;
      writeRuntimeSession(null);
      unawaited(ref.read(groupListeningSessionCredentialStoreProvider).clear());
    }
    state = state.copyWith(
      status: GroupListeningSessionStatus.error,
      connection: state.connection.copyWith(
        status: GroupListeningConnectionStatus.disconnected,
        lastDisconnectReason: failure,
      ),
      clearActiveInviteCode: isFatalSessionFailure(failure.code),
      failure: failure,
    );
    if (shouldAutoReconnectAfterFailure(failure)) {
      scheduleAutoReconnect();
    }
  }

  void scheduleAutoReconnect() {
    reconnectTimer?.cancel();
    if (reconnectAttempts >= reconnectMaxAttempts) {
      AppLogger.warning(
        'Group listening: auto-reconnect exhausted after '
        '$reconnectAttempts attempts',
      );
      return;
    }
    final attempt = reconnectAttempts + 1;
    final backoff = Duration(
      milliseconds:
          (reconnectInitialDelay.inMilliseconds *
                  (1 << (reconnectAttempts).clamp(0, 5)))
              .clamp(
                reconnectInitialDelay.inMilliseconds,
                reconnectMaxDelay.inMilliseconds,
              ),
    );
    AppLogger.info(
      'Group listening: scheduling auto-reconnect attempt $attempt in '
      '${backoff.inSeconds}s',
    );
    reconnectTimer = Timer(backoff, () {
      if (readRuntimeSession() == null || state.connection.isConnected) {
        return;
      }
      reconnectAttempts = attempt;
      AppLogger.info(
        'Group listening: auto-reconnect attempt $reconnectAttempts',
      );
      unawaited(reconnect());
    });
  }

  void scheduleHeartbeat({Duration? after}) {
    heartbeatTimer?.cancel();
    final delay = after ?? state.connection.heartbeatInterval;
    if (delay == null || delay <= Duration.zero) {
      return;
    }
    heartbeatTimer = Timer(delay, () {
      unawaited(sendHeartbeat());
    });
  }

  void scheduleAckLagRecovery(int roomVersion) {
    if (roomVersion <= state.lastAppliedRoomVersion) {
      clearAckLagRecovery();
      return;
    }
    if (ackLagRoomVersion == roomVersion && (ackLagTimer?.isActive ?? false)) {
      return;
    }
    ackLagTimer?.cancel();
    ackLagRoomVersion = roomVersion;
    ackLagTimer = Timer(ackLagGrace, () {
      final stillLagging =
          state.connection.isConnected &&
          !state.snapshotRequired &&
          state.lastAppliedRoomVersion < roomVersion;
      if (!stillLagging) {
        clearAckLagRecovery(upToRoomVersion: state.lastAppliedRoomVersion);
        return;
      }
      AppLogger.info(
        'Group listening: heartbeat ack stayed ahead of room state; '
        'requesting snapshot recovery',
      );
      stateApplier.requestSnapshotRecovery(
        'heartbeat-ack-lag',
        GroupListeningErrorState(
          code: GroupListeningErrorCode.snapshotRequired,
          message: 'Heartbeat ack indicates the room state is lagging behind.',
          retryable: true,
          roomVersion: roomVersion,
          details: <String, Object?>{
            'last_applied_room_version': state.lastAppliedRoomVersion,
            'ack_room_version': roomVersion,
          },
        ),
      );
      clearAckLagRecovery();
    });
  }

  void clearAckLagRecovery({int? upToRoomVersion}) {
    final trackedRoomVersion = ackLagRoomVersion;
    if (upToRoomVersion != null &&
        trackedRoomVersion != null &&
        trackedRoomVersion > upToRoomVersion) {
      return;
    }
    ackLagTimer?.cancel();
    ackLagTimer = null;
    ackLagRoomVersion = null;
  }

  Future<void> sendHeartbeat() async {
    final activeConnection = connection;
    final clientConnectionId = state.connection.clientConnectionId;
    if (activeConnection == null ||
        clientConnectionId == null ||
        !state.connection.isConnected) {
      return;
    }

    final interval = state.connection.heartbeatInterval;
    if (interval == null || interval <= Duration.zero) {
      return;
    }

    final playbackSnapshot = ref.read(playerStateProvider);
    final observedPosition = playbackSnapshot.position;
    try {
      await activeConnection.send(
        GroupListeningHeartbeatMessage(
          clientConnectionId: clientConnectionId,
          clientTime: DateTime.now().toUtc(),
          lastAppliedRoomVersion: state.lastAppliedRoomVersion,
          lastAppliedEventId: state.lastAppliedEventId,
          lastAppliedQueueVersion: state.room?.queue.queueVersion ?? 0,
          lastAppliedPlaybackVersion: state.room?.playbackVersion ?? 0,
          lastAppliedPresenceVersion: state.room?.presenceVersion ?? 0,
          observedPosition: observedPosition,
          transportRtt: state.connection.lastRoundTripTime,
        ),
      );
      final loadingAge = playbackLoadingAge(playbackSnapshot);
      final observedCurrentIndex = playbackSnapshot.currentIndex;
      final observedQueueEntryId =
          observedCurrentIndex != null &&
              observedCurrentIndex >= 0 &&
              (state.room?.queue.entries.length ?? 0) > observedCurrentIndex
          ? state.room!.queue.entries[observedCurrentIndex].queueEntryId
          : null;
      await activeConnection.send(
        GroupListeningClientStatusMessage(
          clientConnectionId: clientConnectionId,
          lastAppliedPlaybackApplyId: state.room?.playbackApplyId ?? 0,
          observedQueueEntryId: observedQueueEntryId,
          observedCurrentIndex: observedCurrentIndex,
          localProcessingState: playbackSnapshot.processingState.name,
          loadingAge: loadingAge,
          clientTime: DateTime.now().toUtc(),
        ),
      );
      scheduleHeartbeat(after: interval);
    } on Object catch (error, stackTrace) {
      handleTransportFailure(
        asFailure(
          error,
          fallbackMessage: 'Unable to send Voyage heartbeat.',
          fallbackCode: GroupListeningErrorCode.transportDisconnected,
        ),
        stackTrace: stackTrace,
      );
    }
  }

  void scheduleServerUpgradeCheck() {
    serverUpgradeTimer?.cancel();
    if (!state.connection.isConnected) {
      return;
    }
    serverUpgradeTimer = Timer(serverUpgradeCheckInterval, () {
      unawaited(checkForBundledServerUpgrade());
    });
  }

  Future<void> checkForBundledServerUpgrade({
    bool triggeredByFailure = false,
  }) async {
    if (serverUpgradeInProgress ||
        readRuntimeSession() == null ||
        !state.connection.isConnected) {
      return;
    }
    final currentVersion = state.connection.connectedServerVersion;
    final currentUrl = readRuntimeSession()?.voyageBaseUrl.toString();
    if (currentVersion == null || currentUrl == null) {
      scheduleServerUpgradeCheck();
      return;
    }

    final candidate = await resolveBestBundledServer(preferredUrl: currentUrl);
    if (candidate == null ||
        candidate.option.url == currentUrl ||
        compareSemanticVersions(
              candidate.discovery.serverVersion,
              currentVersion,
            ) <=
            0) {
      if (!triggeredByFailure) {
        scheduleServerUpgradeCheck();
      }
      return;
    }
    await migrateToBundledServer(candidate);
    if (!triggeredByFailure) {
      scheduleServerUpgradeCheck();
    }
  }

  Future<void> migrateToBundledServer(
    GroupListeningResolvedVoyageServer candidate,
  ) async {
    serverUpgradeInProgress = true;
    GroupListeningRealtimeConnection? candidateConnection;
    StreamSubscription<GroupListeningTransportMessage>? candidateSubscription;
    try {
      final currentSession = readRuntimeSession();
      final baseConfiguration = requireConfiguration();
      if (currentSession == null) {
        return;
      }
      final store = ref.read(groupListeningSessionCredentialStoreProvider);
      final storedSession = await store.read();
      if (storedSession == null ||
          !matchesStoredSession(storedSession, currentSession)) {
        return;
      }
      final nextUri = Uri.parse(candidate.option.url);
      final nextConfiguration = configurationWithVoyageBaseUrl(
        baseConfiguration,
        nextUri,
      );
      final result = await ref
          .read(groupListeningRepositoryProvider)
          .rejoinRoom(
            GroupListeningRejoinRoomRequest(
              configuration: nextConfiguration,
              session: storedSession.copyWith(
                voyageBaseUrl: nextUri,
                lastAppliedRoomVersion: state.lastAppliedRoomVersion,
              ),
            ),
          );
      candidateConnection = await ref
          .read(groupListeningRepositoryProvider)
          .connect(
            GroupListeningTransportConnectRequest(
              session: result.runtimeContext,
              lastAppliedRoomVersion: state.lastAppliedRoomVersion,
              lastAppliedEventId: state.lastAppliedEventId,
              lastAppliedQueueVersion: state.room?.queue.queueVersion ?? 0,
              lastAppliedPlaybackVersion: state.room?.playbackVersion ?? 0,
              lastAppliedPresenceVersion: state.room?.presenceVersion ?? 0,
            ),
          );

      final messages = <GroupListeningTransportMessage>[];
      final ready = Completer<void>();
      GroupListeningConnectionWelcomeMessage? welcome;
      GroupListeningRoomSnapshotMessage? snapshot;
      candidateSubscription = candidateConnection.messages.listen(
        (message) {
          messages.add(message);
          if (message is GroupListeningConnectionWelcomeMessage) {
            welcome = message;
          }
          if (message is GroupListeningRoomSnapshotMessage) {
            snapshot = message;
          }
          if (welcome != null && snapshot != null && !ready.isCompleted) {
            ready.complete();
          }
          if (message is GroupListeningTransportErrorMessage &&
              !ready.isCompleted) {
            ready.completeError(
              GroupListeningRepositoryException(message.error),
            );
          }
          if (message is GroupListeningTransportDisconnectedMessage &&
              !ready.isCompleted) {
            ready.completeError(
              GroupListeningRepositoryException(
                message.error ??
                    const GroupListeningErrorState(
                      code: GroupListeningErrorCode.transportDisconnected,
                      message: 'Voyage realtime transport disconnected.',
                      retryable: true,
                    ),
              ),
            );
          }
        },
        onError: ready.completeError,
      );
      await ready.future.timeout(serverMigrationTimeout);

      final oldConnection = connection;
      final oldSubscription = transportSubscription;
      heartbeatTimer?.cancel();
      heartbeatTimer = null;
      await oldSubscription?.cancel();
      connection = candidateConnection;
      transportSubscription = candidateConnection.messages.listen(
        handleTransportMessage,
        onError: (Object error, StackTrace stackTrace) {
          handleTransportFailure(
            asFailure(
              error,
              fallbackMessage: 'Voyage transport stream failed.',
              fallbackCode: GroupListeningErrorCode.transportDisconnected,
            ),
            stackTrace: stackTrace,
          );
        },
      );
      await candidateSubscription.cancel();
      candidateSubscription = null;
      candidateConnection = null;
      await oldConnection?.disconnect();

      writeRuntimeSession(result.runtimeContext);
      connectingDiscovery = candidate.discovery;
      for (final message in messages) {
        if (message is GroupListeningConnectionWelcomeMessage ||
            message is GroupListeningRoomSnapshotMessage) {
          handleTransportMessage(message);
        }
      }
      state = state.copyWith(
        activeInviteCode: result.inviteCode,
        clearActiveInviteCode: result.inviteCode == null,
      );
      await store.save(
        GroupListeningStoredSession(
          roomId: result.runtimeContext.roomId,
          memberId: result.runtimeContext.memberId,
          role: result.runtimeContext.role,
          authVersion: result.runtimeContext.authVersion,
          voyageBaseUrl: result.runtimeContext.voyageBaseUrl,
          sourceServerFingerprint:
              result.runtimeContext.sourceServerFingerprint,
          rejoinToken: result.runtimeContext.rejoinToken,
          client: storedSession.client,
          lastAppliedRoomVersion: state.lastAppliedRoomVersion,
        ),
      );
      await persistSelectedVoyageServer(result.runtimeContext.voyageBaseUrl);
    } on Object catch (error) {
      AppLogger.warning('Voyage bundled server migration failed: $error');
      await candidateSubscription?.cancel();
      await candidateConnection?.disconnect();
    } finally {
      serverUpgradeInProgress = false;
    }
  }

  Future<void> persistSelectedVoyageServer(Uri voyageBaseUrl) async {
    final settings =
        ref.read(appSettingsProvider).asData?.value ??
        const AppSettingsModel.defaults();
    await ref
        .read(settingsRepositoryProvider)
        .saveSettings(
          settings.copyWith(voyageServerUrl: voyageBaseUrl.toString()),
        );
  }
}
