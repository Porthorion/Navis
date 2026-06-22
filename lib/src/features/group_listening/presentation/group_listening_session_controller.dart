import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_server_clock_estimator.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_mutation_outbox.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_providers.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_room_ops.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_state_applier.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_transport_handler.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_snapshot_recovery.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_transport_coordinator.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:uuid/uuid.dart';

export 'group_listening_providers.dart';

final groupListeningSessionControllerProvider =
    NotifierProvider<
      GroupListeningSessionController,
      GroupListeningSessionState
    >(GroupListeningSessionController.new);

class GroupListeningSessionController
    extends Notifier<GroupListeningSessionState> {
  static const Uuid _uuid = Uuid();
  static const Duration _tokenRefreshWindow = Duration(minutes: 1);
  static const Duration _snapshotRetryDelay = Duration(seconds: 5);

  GroupListeningClientConfiguration? _configuration;
  GroupListeningSessionRuntimeContext? _runtimeSession;
  Timer? _snapshotRetryTimer;
  Future<GroupListeningSessionState>? _snapshotRefreshOperation;
  bool _snapshotRefreshInFlight = false;
  bool _queuedSnapshotRefresh = false;
  String? _queuedSnapshotRefreshReason;
  int _clientSequence = 0;
  final GroupListeningServerClockEstimator _serverClockEstimator =
      GroupListeningServerClockEstimator();
  final GroupListeningTransportCoordinator _transportCoordinator =
      GroupListeningTransportCoordinator();
  GroupListeningMutationOutbox? _mutationOutbox;
  GroupListeningSnapshotRecovery? _snapshotRecovery;
  bool _coldStartAutoRejoinAttempted = false;
  bool _modulesInitialized = false;

  late GroupListeningSessionStateApplier _stateApplier;
  late GroupListeningSessionTransportHandler _transport;
  late GroupListeningSessionRoomOps _roomOps;

  @override
  GroupListeningSessionState build() {
    _configuration = ref.read(groupListeningClientConfigurationProvider);
    final availability = ref.read(groupListeningAvailabilityProvider);
    _initModules();

    ref.listen<GroupListeningAvailability>(
      groupListeningAvailabilityProvider,
      (_, next) => _handleAvailabilityChanged(next),
    );
    ref.listen<GroupListeningClientConfiguration?>(
      groupListeningClientConfigurationProvider,
      (_, next) => _handleConfigurationChanged(next),
    );
    ref.listen<PlaybackSnapshot>(
      playerStateProvider,
      (_, next) => _transport.recordPlaybackLoadingState(next),
    );
    ref.onDispose(() {
      _snapshotRetryTimer?.cancel();
      if (_modulesInitialized) {
        unawaited(_transport.disposeTransport());
      }
      _snapshotRecovery?.dispose();
      _transportCoordinator.dispose();
    });

    _snapshotRecovery = GroupListeningSnapshotRecovery(
      refreshSnapshot: ({required String reason}) async {
        await refreshSnapshot(reason: reason);
      },
    );
    _mutationOutbox = GroupListeningMutationOutbox(
      send: (mutation, message) async {
        final activeConnection = _transport.connection;
        if (activeConnection == null) {
          throw const GroupListeningRepositoryException(
            GroupListeningErrorState(
              code: GroupListeningErrorCode.transportDisconnected,
              message: 'Voyage realtime transport is disconnected.',
              retryable: true,
            ),
          );
        }
        await activeConnection.send(message);
      },
      canSendType: _canSendMutationType,
      expectedQueueVersion: (type, {playbackAnchor}) =>
          _expectedQueueVersionForMutation(
            type,
            playbackAnchor: playbackAnchor,
          ),
      expectedPlaybackVersion: (type, {playbackAnchor}) =>
          _expectedPlaybackVersionForMutation(
            type,
            playbackAnchor: playbackAnchor,
          ),
      expectedPlaybackEpoch: () => state.localPlaybackEpoch,
      nextClientSequence: () => ++_clientSequence,
      readClientConnectionId: () => state.connection.clientConnectionId,
      isConnected: () => state.connection.isConnected,
      readLastAppliedRoomVersion: () => state.lastAppliedRoomVersion,
      onSendError: (mutation, error, stackTrace) {
        _transport.handleTransportFailure(
          _asFailure(
            error,
            fallbackMessage: 'Unable to send Voyage room mutation.',
            fallbackCode: GroupListeningErrorCode.transportDisconnected,
          ),
          stackTrace: stackTrace,
        );
      },
    );

    unawaited(_roomOps.probeStoredSession());

    return GroupListeningSessionState(
      availability: availability,
      status: GroupListeningSessionStatus.idle,
      connection: const GroupListeningConnectionState.disconnected(),
      configuration: _configuration,
    );
  }

  void _initModules() {
    if (_modulesInitialized) {
      return;
    }
    _modulesInitialized = true;

    _stateApplier = GroupListeningSessionStateApplier(
      ref: ref,
      readState: () => state,
      writeState: (next) => state = next,
      readConfiguration: () => _configuration,
      readRuntimeSession: () => _runtimeSession,
      writeRuntimeSession: (session) => _runtimeSession = session,
      serverClockEstimator: _serverClockEstimator,
      readMutationOutbox: () => _mutationOutbox,
      clearAckLagRecovery: ({int? upToRoomVersion}) =>
          _transport.clearAckLagRecovery(upToRoomVersion: upToRoomVersion),
      pauseMutationOutbox: _pauseMutationOutbox,
      resumeMutationOutbox: _resumeMutationOutbox,
      persistLastAppliedCursor: _persistLastAppliedCursor,
      setFailure: (failure, {bool clearRoom = false}) =>
          _setFailure(failure, clearRoom: clearRoom),
      refreshSnapshot: ({String reason = 'manual'}) =>
          refreshSnapshot(reason: reason),
      readConnectionConnected: () => state.connection.isConnected,
      snapshotRetryDelay: _snapshotRetryDelay,
      readSnapshotRetryTimer: () => _snapshotRetryTimer,
      writeSnapshotRetryTimer: (timer) => _snapshotRetryTimer = timer,
    );

    _transport = GroupListeningSessionTransportHandler(
      ref: ref,
      readState: () => state,
      writeState: (next) => state = next,
      readRuntimeSession: () => _runtimeSession,
      writeRuntimeSession: (session) => _runtimeSession = session,
      stateApplier: _stateApplier,
      serverClockEstimator: _serverClockEstimator,
      asFailure: _asFailure,
      setFailure: _setFailure,
      ensureFreshSession: ({bool force = false}) =>
          _roomOps.ensureFreshSession(force: force),
      discoverSessionServer: (session) =>
          _roomOps.discoverSessionServer(session),
      resolveBestBundledServer: ({String? preferredUrl}) =>
          _roomOps.resolveBestBundledServer(preferredUrl: preferredUrl),
      finishInvalidatedSessionCleanup: (failure) async {
        final result = await _roomOps.finishInvalidatedSessionCleanup(failure);
        return result;
      },
      shouldCollapseToLocalCleanup: _shouldCollapseToLocalCleanup,
      isFatalSessionFailure: _isFatalSessionFailure,
      shouldAutoReconnectAfterFailure: _shouldAutoReconnectAfterFailure,
      reconnect: () => _roomOps.reconnect(),
      handleMutationAck: _handleMutationAck,
      handleMutationNack: _handleMutationNack,
      abortMutationOutboxTransport: () =>
          _mutationOutbox?.abortInFlightTransport(),
      resumeMutationOutbox: _resumeMutationOutbox,
      readMutationOutbox: () => _mutationOutbox,
      resetClientSequence: () => _clientSequence = 0,
      requireConfiguration: () => _roomOps.requireConfiguration(),
      matchesStoredSession: _matchesStoredSession,
      cancelSnapshotRetry: () {
        _snapshotRetryTimer?.cancel();
        _snapshotRetryTimer = null;
      },
    );

    _roomOps = GroupListeningSessionRoomOps(
      ref: ref,
      readState: () => state,
      writeState: (next) => state = next,
      readConfiguration: () => _configuration,
      writeConfiguration: (configuration) => _configuration = configuration,
      readRuntimeSession: () => _runtimeSession,
      writeRuntimeSession: (session) => _runtimeSession = session,
      stateApplier: _stateApplier,
      serverClockEstimator: _serverClockEstimator,
      asFailure: _asFailure,
      setFailure: _setFailure,
      connect: () => _transport.connect(),
      disposeTransport: () => _transport.disposeTransport(),
      beginTransportTeardown: () => _transport.beginTransportTeardown(),
      endTransportTeardown: () => _transport.endTransportTeardown(),
      readTransportTeardownFailureObserved: () =>
          _transport.transportTeardownFailureObserved,
      shouldCollapseToLocalCleanup: _shouldCollapseToLocalCleanup,
      canLeaveLocallyAfterFailure: _canLeaveLocallyAfterFailure,
      shouldAutoReconnectAfterFailure: _shouldAutoReconnectAfterFailure,
      scheduleAutoReconnect: () => _transport.scheduleAutoReconnect(),
      isFatalSessionFailure: _isFatalSessionFailure,
      clearMutationOutbox: _clearMutationOutbox,
      sendMutation: sendMutation,
      logRoomAction: _logRoomAction,
      readColdStartAutoRejoinAttempted: () => _coldStartAutoRejoinAttempted,
      writeColdStartAutoRejoinAttempted: (attempted) =>
          _coldStartAutoRejoinAttempted = attempted,
      refreshAccessTokenOverTransport: (session) =>
          _transport.refreshAccessTokenOverTransport(
            session,
            _roomOps.rejoinCurrentSession,
          ),
      tokenRefreshWindow: _tokenRefreshWindow,
    );
  }

  Future<GroupListeningCapabilityDiscovery> discoverCapabilities() =>
      _roomOps.discoverCapabilities();

  Future<GroupListeningSessionState> createRoom({
    required GroupListeningClientDescriptor client,
    GroupListeningRoomOptions roomOptions = const GroupListeningRoomOptions(),
    GroupListeningRoomSeed? roomSeed,
    bool connectAfterCreate = true,
  }) => _roomOps.createRoom(
    client: client,
    roomOptions: roomOptions,
    roomSeed: roomSeed,
    connectAfterCreate: connectAfterCreate,
  );

  Future<GroupListeningSessionState> joinRoom({
    required String inviteCode,
    required GroupListeningClientDescriptor client,
    String? pinCode,
    bool connectAfterJoin = true,
  }) => _roomOps.joinRoom(
    inviteCode: inviteCode,
    client: client,
    pinCode: pinCode,
    connectAfterJoin: connectAfterJoin,
  );

  Future<GroupListeningSessionState> joinAvailableRoom({
    required String roomId,
    required GroupListeningClientDescriptor client,
    String? pinCode,
    bool connectAfterJoin = true,
  }) => _roomOps.joinAvailableRoom(
    roomId: roomId,
    client: client,
    pinCode: pinCode,
    connectAfterJoin: connectAfterJoin,
  );

  Future<GroupListeningSessionState> connect() => _transport.connect();

  Future<String?> sendMutation({
    required GroupListeningMutationType type,
    GroupListeningPlaybackAnchor? playbackAnchor,
    GroupListeningQueueState? queue,
    String? targetQueueEntryId,
    int? insertIndex,
    String? targetMemberId,
  }) async {
    if (!_canSendMutationType(type)) {
      return null;
    }

    final mutationId = _uuid.v4();
    _mutationOutbox?.enqueue(
      PendingGroupListeningMutation(
        type: type,
        clientMutationId: mutationId,
        playbackAnchor: playbackAnchor,
        queue: queue,
        targetQueueEntryId: targetQueueEntryId,
        insertIndex: insertIndex,
        targetMemberId: targetMemberId,
      ),
    );
    return mutationId;
  }

  Future<void> sendTrackReadiness({
    required String queueEntryId,
    required String status,
    String? resolvedSongId,
  }) async {
    final activeConnection = _transport.connection;
    final clientConnectionId = state.connection.clientConnectionId;
    if (activeConnection == null ||
        clientConnectionId == null ||
        !state.connection.isConnected) {
      return;
    }
    await activeConnection.send(
      GroupListeningTrackReadinessMessage(
        clientConnectionId: clientConnectionId,
        queueEntryId: queueEntryId,
        status: status,
        resolvedSongId: resolvedSongId,
      ),
    );
  }

  void markPlaybackCatchUpAligned({required int serverEpoch}) {
    _stateApplier.markPlaybackCatchUpAligned(serverEpoch: serverEpoch);
  }

  Future<GroupListeningSessionState> disconnect({
    bool preserveSession = true,
  }) => _roomOps.disconnect(preserveSession: preserveSession);

  Future<GroupListeningSessionState> leaveRoom({
    String source = 'unknown',
  }) => _roomOps.leaveRoom(source: source);

  Future<GroupListeningSessionState> closeRoom({
    String source = 'unknown',
  }) => _roomOps.closeRoom(source: source);

  Future<GroupListeningSessionState> rotateInvite({
    String source = 'unknown',
  }) => _roomOps.rotateInvite(source: source);

  Future<String?> transferHost({
    required String targetMemberId,
    String source = 'unknown',
  }) => _roomOps.transferHost(
    targetMemberId: targetMemberId,
    source: source,
  );

  Future<GroupListeningSessionState> reconnect() => _roomOps.reconnect();

  Future<GroupListeningSessionState> refreshSnapshot({
    String reason = 'manual',
  }) async {
    final session = _runtimeSession;
    if (session == null) {
      return _setFailure(
        const GroupListeningErrorState(
          code: GroupListeningErrorCode.sessionUnavailable,
          message:
              'No active Voyage session is available for snapshot refresh.',
        ),
      );
    }
    if (_snapshotRefreshInFlight) {
      _queuedSnapshotRefresh = true;
      _queuedSnapshotRefreshReason = reason;
      AppLogger.info(
        'Group listening: coalescing snapshot refresh '
        '(reason=$reason, last_applied=${state.lastAppliedRoomVersion})',
      );
      return _snapshotRefreshOperation ??
          Future<GroupListeningSessionState>.value(state);
    }
    _snapshotRefreshInFlight = true;
    AppLogger.info(
      'Group listening: refreshing snapshot '
      '(reason=$reason, last_applied=${state.lastAppliedRoomVersion})',
    );
    final operation = () async {
      try {
        final snapshot = await _roomOps.runAuthenticatedWithRejoinRetry(
          (freshSession) => ref
              .read(groupListeningRepositoryProvider)
              .fetchSnapshot(
                freshSession,
                lastAppliedRoomVersion: state.lastAppliedRoomVersion,
              ),
          fallbackMessage: 'Unable to refresh Voyage room snapshot.',
          fallbackCode: GroupListeningErrorCode.transportUnavailable,
        );
        return _stateApplier.applySnapshot(snapshot);
      } on Object catch (error, stackTrace) {
        final failure = _asFailure(
          error,
          fallbackMessage: 'Unable to refresh Voyage room snapshot.',
          fallbackCode: GroupListeningErrorCode.transportUnavailable,
        );
        if (_shouldCollapseToLocalCleanup(failure.code)) {
          return _roomOps.finishInvalidatedSessionCleanup(failure);
        }
        if (state.connection.isConnected) {
          AppLogger.warning(
            'Group listening: snapshot fetch failed (reason=$reason, '
            'non-fatal, WS alive): ${failure.code.name} — ${failure.message}',
          );
          _stateApplier.scheduleSnapshotRetry();
          return state;
        }
        return _setFailure(failure, stackTrace: stackTrace);
      }
    }();
    _snapshotRefreshOperation = operation;
    try {
      return await operation;
    } finally {
      _snapshotRefreshOperation = null;
      _snapshotRefreshInFlight = false;
      final queuedRefresh = _queuedSnapshotRefresh;
      final queuedReason = _queuedSnapshotRefreshReason;
      _queuedSnapshotRefresh = false;
      _queuedSnapshotRefreshReason = null;
      if (queuedRefresh && state.snapshotRequired) {
        unawaited(
          refreshSnapshot(
            reason: queuedReason == null
                ? 'coalesced-retry'
                : 'coalesced-retry:$queuedReason',
          ),
        );
      }
    }
  }

  GroupListeningSessionState applySnapshot(GroupListeningRoomState snapshot) =>
      _stateApplier.applySnapshot(snapshot);

  GroupListeningSessionState applyRealtimeEvent(
    GroupListeningRoomEvent event,
  ) => _stateApplier.applyRealtimeEvent(event);

  GroupListeningSessionState markSnapshotRequired([
    GroupListeningErrorState? failure,
  ]) => _stateApplier.markSnapshotRequired(failure);

  Future<void> tryRestoreStoredSession() => reconnect();

  Future<void> restoreStoredSessionIfAvailable() =>
      _roomOps.restoreStoredSessionIfAvailable();

  void clearFailure() {
    state = state.copyWith(clearFailure: true);
  }

  void _handleMutationAck(GroupListeningMutationAckMessage message) {
    _mutationOutbox?.handleAck(message.clientMutationId);
    _transport.clearAckLagRecovery(upToRoomVersion: message.roomVersion);
  }

  void _handleMutationNack(GroupListeningMutationRejectedMessage message) {
    final outbox = _mutationOutbox;
    if (outbox == null) {
      return;
    }
    final mutationId = message.clientMutationId;
    if (mutationId != null && mutationId.isNotEmpty) {
      outbox.handleNack(clientMutationId: mutationId, dropInFlight: false);
    }
    final inFlight = outbox.takeInFlightForNack(mutationId);
    if (inFlight == null) {
      AppLogger.info(
        'Group listening mutation nack ignored: '
        'id=${mutationId ?? 'unknown'}, code=${message.error.code.name}',
      );
      return;
    }

    AppLogger.info(
      'Group listening mutation nack: '
      'id=${inFlight.clientMutationId}, type=${inFlight.type.name}, '
      'code=${message.error.code.name}, conflict=${message.conflict ?? 'none'}, '
      'room_version=${message.roomVersion ?? message.error.roomVersion ?? 0}, '
      'queue_version=${message.queueVersion ?? 0}, '
      'playback_version=${message.playbackVersion ?? 0}, '
      'playback_apply_id=${message.playbackApplyId ?? 0}',
    );

    final code = message.error.code;
    if (code == GroupListeningErrorCode.duplicateMutation) {
      outbox.clearInFlight();
      outbox.dispatch();
      return;
    }
    if (code == GroupListeningErrorCode.staleVersion ||
        code == GroupListeningErrorCode.snapshotRequired ||
        code == GroupListeningErrorCode.stalePlaybackEpoch) {
      outbox.clearInFlight();
      outbox.pause();
      outbox.dropPendingPlaybackMutations();
      markSnapshotRequired(message.error);
      unawaited(
        refreshSnapshot(reason: 'mutation-${code.name}').whenComplete(
          _resumeMutationOutbox,
        ),
      );
      return;
    }
    if (code == GroupListeningErrorCode.sequenceRejected) {
      outbox.clearInFlight();
      outbox.pause();
      if (!_isPlaybackOnlyMutation(inFlight.type)) {
        outbox.insertAtFront(inFlight.withoutSequence());
      }
      unawaited(reconnect().whenComplete(_resumeMutationOutbox));
      return;
    }
    if (code == GroupListeningErrorCode.forbidden) {
      outbox.clearInFlight();
      outbox.pause();
      outbox.clear();
      unawaited(
        refreshSnapshot(
          reason: 'mutation-forbidden',
        ).whenComplete(_resumeMutationOutbox),
      );
      state = state.copyWith(failure: message.error);
      return;
    }
    if (code == GroupListeningErrorCode.removed ||
        code == GroupListeningErrorCode.roomClosed) {
      _clearMutationOutbox();
      _transport.handleTransportFailure(message.error);
      return;
    }
    outbox.clearInFlight();
    outbox.dispatch();
  }

  bool _isPlaybackOnlyMutation(GroupListeningMutationType type) {
    return type == GroupListeningMutationType.playbackAnchor;
  }

  void _pauseMutationOutbox() {
    _mutationOutbox?.pause();
  }

  void _resumeMutationOutbox() {
    _mutationOutbox?.resume();
  }

  void _clearMutationOutbox() {
    _mutationOutbox?.clear();
  }

  int? _expectedQueueVersionForMutation(
    GroupListeningMutationType type, {
    GroupListeningPlaybackAnchor? playbackAnchor,
  }) {
    switch (type) {
      case GroupListeningMutationType.playbackAnchor:
        return playbackAnchor?.reason ==
                GroupListeningPlaybackAnchorReason.trackChange
            ? state.room?.queue.queueVersion
            : null;
      case GroupListeningMutationType.queueAdd:
      case GroupListeningMutationType.queueRemove:
      case GroupListeningMutationType.queueReplace:
        return state.room?.queue.queueVersion;
      case GroupListeningMutationType.transferHost:
      case GroupListeningMutationType.removeMember:
        return null;
    }
  }

  int? _expectedPlaybackVersionForMutation(
    GroupListeningMutationType type, {
    GroupListeningPlaybackAnchor? playbackAnchor,
  }) {
    switch (type) {
      case GroupListeningMutationType.playbackAnchor:
        return state.room?.playbackVersion;
      case GroupListeningMutationType.queueReplace:
        return playbackAnchor == null ? null : state.room?.playbackVersion;
      case GroupListeningMutationType.queueAdd:
      case GroupListeningMutationType.queueRemove:
      case GroupListeningMutationType.transferHost:
      case GroupListeningMutationType.removeMember:
        return null;
    }
  }

  void _logRoomAction(String action, {required String source}) {
    AppLogger.info(
      'Group listening: $action requested '
      '(source=$source, room_id=${state.room?.roomId ?? _runtimeSession?.roomId ?? 'n/a'}, '
      'room_version=${state.lastAppliedRoomVersion})',
    );
  }

  void _handleAvailabilityChanged(GroupListeningAvailability availability) {
    state = state.copyWith(availability: availability);
    if (availability != GroupListeningAvailability.ready &&
        (state.connection.status !=
                GroupListeningConnectionStatus.disconnected ||
            _runtimeSession != null ||
            state.room != null)) {
      unawaited(_resetForConfigurationLoss());
    }
  }

  void _handleConfigurationChanged(GroupListeningClientConfiguration? next) {
    final previous = _configuration;
    _configuration = next;
    state = state.copyWith(configuration: next);

    if (previous != null &&
        next != null &&
        !previous.isTransportCompatibleWith(next) &&
        !_runtimeSessionMatchesConfiguration(next) &&
        (state.room != null || _runtimeSession != null)) {
      unawaited(_resetForConfigurationLoss());
    }
  }

  Future<void> _resetForConfigurationLoss() async {
    await _transport.disposeTransport();
    _clearMutationOutbox();
    _runtimeSession = null;
    await ref.read(groupListeningSessionCredentialStoreProvider).clear();
    state = state.copyWith(
      status: GroupListeningSessionStatus.idle,
      connection: const GroupListeningConnectionState.disconnected(),
      clearRoom: true,
      clearFailure: true,
      lastAppliedRoomVersion: 0,
      lastAppliedEventId: 0,
      snapshotRequired: false,
    );
  }

  Future<void> _persistLastAppliedCursor({
    required int roomVersion,
    required int eventId,
    required GroupListeningSessionRuntimeContext? expectedSession,
  }) async {
    if (expectedSession == null || !_matchesRuntimeSession(expectedSession)) {
      return;
    }
    final store = ref.read(groupListeningSessionCredentialStoreProvider);
    final current = await store.read();
    if (current == null ||
        !_matchesStoredSession(current, expectedSession) ||
        !_matchesRuntimeSession(expectedSession)) {
      return;
    }
    await store.save(
      current.copyWith(
        lastAppliedRoomVersion: roomVersion,
        lastAppliedEventId: eventId,
      ),
    );
  }

  bool _matchesRuntimeSession(GroupListeningSessionRuntimeContext expected) {
    final current = _runtimeSession;
    if (current == null) {
      return false;
    }
    return current.roomId == expected.roomId &&
        current.memberId == expected.memberId &&
        current.sourceServerFingerprint == expected.sourceServerFingerprint;
  }

  bool _matchesStoredSession(
    GroupListeningStoredSession stored,
    GroupListeningSessionRuntimeContext expected,
  ) {
    return stored.roomId == expected.roomId &&
        stored.memberId == expected.memberId &&
        stored.sourceServerFingerprint == expected.sourceServerFingerprint;
  }

  bool _runtimeSessionMatchesConfiguration(
    GroupListeningClientConfiguration configuration,
  ) {
    final session = _runtimeSession;
    return session != null &&
        session.voyageBaseUrl == configuration.voyageBaseUrl &&
        session.sourceServerFingerprint ==
            configuration.sourceServerFingerprint;
  }

  bool _canSendMutationType(GroupListeningMutationType type) {
    final room = state.room;
    final configuration = state.configuration;
    if (room == null ||
        configuration == null ||
        state.availability != GroupListeningAvailability.ready ||
        !state.connection.isConnected ||
        state.snapshotRequired ||
        room.roomStatus != GroupListeningRoomStatus.active ||
        room.sourceServerFingerprint != configuration.sourceServerFingerprint) {
      return false;
    }

    switch (type) {
      case GroupListeningMutationType.queueAdd:
      case GroupListeningMutationType.queueRemove:
        return room.self.canControl;
      case GroupListeningMutationType.queueReplace:
        return room.self.canControl;
      case GroupListeningMutationType.playbackAnchor:
      case GroupListeningMutationType.transferHost:
      case GroupListeningMutationType.removeMember:
        return room.self.canControl;
    }
  }

  GroupListeningSessionState _setFailure(
    GroupListeningErrorState failure, {
    GroupListeningConnectionStatus? connectionStatus,
    bool clearRoom = false,
    StackTrace? stackTrace,
  }) {
    if (stackTrace != null) {
      AppLogger.warning('Group listening failure: ${failure.code.name}');
    }
    state = state.copyWith(
      status: GroupListeningSessionStatus.error,
      connection: state.connection.copyWith(
        status: connectionStatus ?? state.connection.status,
        lastDisconnectReason: failure,
      ),
      failure: failure,
      clearRoom: clearRoom,
    );
    return state;
  }

  GroupListeningErrorState _asFailure(
    Object error, {
    required String fallbackMessage,
    required GroupListeningErrorCode fallbackCode,
  }) {
    if (error is GroupListeningRepositoryException) {
      return error.failure;
    }
    return GroupListeningErrorState(
      code: fallbackCode,
      message: fallbackMessage,
    );
  }

  bool _shouldAutoReconnectAfterFailure(GroupListeningErrorState failure) {
    return failure.retryable == true &&
        _runtimeSession != null &&
        !_isFatalSessionFailure(failure.code) &&
        (failure.code == GroupListeningErrorCode.transportDisconnected ||
            failure.code == GroupListeningErrorCode.transportUnavailable);
  }

  bool _shouldCollapseToLocalCleanup(GroupListeningErrorCode code) {
    return code == GroupListeningErrorCode.unauthorized ||
        code == GroupListeningErrorCode.removed ||
        code == GroupListeningErrorCode.revoked ||
        code == GroupListeningErrorCode.roomNotFound ||
        code == GroupListeningErrorCode.roomClosed;
  }

  bool _canLeaveLocallyAfterFailure(GroupListeningErrorState failure) {
    return _isFatalSessionFailure(failure.code);
  }

  bool _isFatalSessionFailure(GroupListeningErrorCode code) {
    return code == GroupListeningErrorCode.fingerprintMismatch ||
        code == GroupListeningErrorCode.removed ||
        code == GroupListeningErrorCode.revoked ||
        code == GroupListeningErrorCode.roomClosed ||
        code == GroupListeningErrorCode.roomNotFound ||
        code == GroupListeningErrorCode.unauthorized;
  }
}
