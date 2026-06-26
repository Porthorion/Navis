import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_server_clock_estimator.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_providers.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_state_applier.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_settings_provider.dart';
import 'package:navis/src/utils/app_logger.dart';

typedef GroupListeningErrorMapper =
    GroupListeningErrorState Function(
      Object error, {
      required String fallbackMessage,
      required GroupListeningErrorCode fallbackCode,
    });

/// Room lifecycle and authenticated HTTP operations for group listening.
class GroupListeningSessionRoomOps {
  GroupListeningSessionRoomOps({
    required this.ref,
    required this.readState,
    required this.writeState,
    required this.readConfiguration,
    required this.writeConfiguration,
    required this.readRuntimeSession,
    required this.writeRuntimeSession,
    required this.stateApplier,
    required this.serverClockEstimator,
    required this.asFailure,
    required this.setFailure,
    required this.connect,
    required this.disposeTransport,
    required this.beginTransportTeardown,
    required this.endTransportTeardown,
    required this.readTransportTeardownFailureObserved,
    required this.shouldCollapseToLocalCleanup,
    required this.canLeaveLocallyAfterFailure,
    required this.shouldAutoReconnectAfterFailure,
    required this.scheduleAutoReconnect,
    required this.isFatalSessionFailure,
    required this.clearMutationOutbox,
    required this.sendMutation,
    required this.logRoomAction,
    required this.readColdStartAutoRejoinAttempted,
    required this.writeColdStartAutoRejoinAttempted,
    required this.refreshAccessTokenOverTransport,
    required this.tokenRefreshWindow,
  });

  final Ref ref;
  final GroupListeningSessionStateReader readState;
  final GroupListeningSessionStateWriter writeState;
  final GroupListeningClientConfiguration? Function() readConfiguration;
  final void Function(GroupListeningClientConfiguration? configuration)
  writeConfiguration;
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
  final Future<GroupListeningSessionState> Function() connect;
  final Future<void> Function() disposeTransport;
  final void Function() beginTransportTeardown;
  final void Function() endTransportTeardown;
  final bool Function() readTransportTeardownFailureObserved;
  final bool Function(GroupListeningErrorCode code)
  shouldCollapseToLocalCleanup;
  final bool Function(GroupListeningErrorState failure)
  canLeaveLocallyAfterFailure;
  final bool Function(GroupListeningErrorState failure)
  shouldAutoReconnectAfterFailure;
  final void Function() scheduleAutoReconnect;
  final bool Function(GroupListeningErrorCode code) isFatalSessionFailure;
  final void Function() clearMutationOutbox;
  final Future<String?> Function({
    required GroupListeningMutationType type,
    GroupListeningPlaybackAnchor? playbackAnchor,
    GroupListeningQueueState? queue,
    String? targetQueueEntryId,
    int? insertIndex,
    String? targetMemberId,
  })
  sendMutation;
  final void Function(String action, {required String source}) logRoomAction;
  final bool Function() readColdStartAutoRejoinAttempted;
  final void Function(bool attempted) writeColdStartAutoRejoinAttempted;
  final Future<GroupListeningSessionRuntimeContext> Function(
    GroupListeningSessionRuntimeContext session,
  )
  refreshAccessTokenOverTransport;
  final Duration tokenRefreshWindow;

  GroupListeningSessionState get state => readState();

  set state(GroupListeningSessionState value) => writeState(value);

  Future<GroupListeningCapabilityDiscovery> discoverCapabilities() async {
    try {
      final resolved = await resolveBestBundledServer();
      if (resolved != null) {
        return resolved.discovery;
      }
      return ref
          .read(groupListeningRepositoryProvider)
          .discover(
            requireConfiguration(),
          );
    } on Object catch (error, stackTrace) {
      setFailure(
        asFailure(
          error,
          fallbackMessage: 'Unable to discover Voyage capabilities.',
          fallbackCode: GroupListeningErrorCode.transportUnavailable,
        ),
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<GroupListeningSessionState> createRoom({
    required GroupListeningClientDescriptor client,
    GroupListeningRoomOptions roomOptions = const GroupListeningRoomOptions(),
    GroupListeningRoomSeed? roomSeed,
    bool connectAfterCreate = true,
  }) async {
    try {
      final configuration = await configurationForRoomOperation();
      state = state.copyWith(
        status: GroupListeningSessionStatus.joining,
        clearFailure: true,
      );
      final result = await ref
          .read(groupListeningRepositoryProvider)
          .createRoom(
            GroupListeningCreateRoomRequest(
              configuration: configuration,
              client: client,
              roomOptions: roomOptions,
              roomSeed: roomSeed,
            ),
          );
      await bindJoinedSession(
        result: result,
        client: client,
        connectAfterJoin: connectAfterCreate,
      );
      return state;
    } on Object catch (error, stackTrace) {
      return setFailure(
        asFailure(
          error,
          fallbackMessage: 'Unable to create Voyage room.',
          fallbackCode: GroupListeningErrorCode.transportUnavailable,
        ),
        stackTrace: stackTrace,
      );
    }
  }

  Future<GroupListeningSessionState> joinRoom({
    required String inviteCode,
    required GroupListeningClientDescriptor client,
    String? pinCode,
    bool connectAfterJoin = true,
  }) async {
    try {
      final configuration = await configurationForRoomOperation();
      state = state.copyWith(
        status: GroupListeningSessionStatus.joining,
        clearFailure: true,
      );
      final result = await ref
          .read(groupListeningRepositoryProvider)
          .joinRoom(
            GroupListeningJoinRoomRequest(
              configuration: configuration,
              client: client,
              inviteCode: inviteCode,
              pinCode: pinCode,
            ),
          );
      await bindJoinedSession(
        result: result,
        client: client,
        connectAfterJoin: connectAfterJoin,
      );
      return state;
    } on Object catch (error, stackTrace) {
      return setFailure(
        asFailure(
          error,
          fallbackMessage: 'Unable to join Voyage room.',
          fallbackCode: GroupListeningErrorCode.transportUnavailable,
        ),
        stackTrace: stackTrace,
      );
    }
  }

  Future<GroupListeningSessionState> joinAvailableRoom({
    required String roomId,
    required GroupListeningClientDescriptor client,
    String? pinCode,
    bool connectAfterJoin = true,
  }) async {
    try {
      final configuration = await configurationForRoomOperation();
      state = state.copyWith(
        status: GroupListeningSessionStatus.joining,
        clearFailure: true,
        clearActiveInviteCode: true,
      );
      final result = await ref
          .read(groupListeningRepositoryProvider)
          .joinAvailableRoom(
            roomId: roomId,
            configuration: configuration,
            client: client,
            pinCode: pinCode,
          );
      await bindJoinedSession(
        result: result,
        client: client,
        connectAfterJoin: connectAfterJoin,
      );
      return state;
    } on Object catch (error, stackTrace) {
      return setFailure(
        asFailure(
          error,
          fallbackMessage: 'Unable to join available Voyage room.',
          fallbackCode: GroupListeningErrorCode.transportUnavailable,
        ),
        stackTrace: stackTrace,
      );
    }
  }

  Future<GroupListeningSessionState> leaveRoom({
    String source = 'unknown',
  }) async {
    final session = readRuntimeSession();
    if (session == null) {
      return disconnect(preserveSession: false);
    }
    logRoomAction('leave room', source: source);

    state = state.copyWith(
      status: GroupListeningSessionStatus.leaving,
      clearFailure: true,
    );
    beginTransportTeardown();
    try {
      try {
        await runAuthenticatedWithRejoinRetry(
          (freshSession) => ref
              .read(groupListeningRepositoryProvider)
              .leaveRoom(
                freshSession,
                lastAppliedRoomVersion: state.lastAppliedRoomVersion,
              ),
          fallbackMessage: 'Unable to leave Voyage room cleanly.',
          fallbackCode: GroupListeningErrorCode.transportUnavailable,
        );
      } on Object catch (error, stackTrace) {
        final failure = asFailure(
          error,
          fallbackMessage: 'Unable to leave Voyage room cleanly.',
          fallbackCode: GroupListeningErrorCode.transportUnavailable,
        );
        if (canLeaveLocallyAfterFailure(failure)) {
          AppLogger.warning(
            'Leave request rejected (${failure.code}), leaving locally.',
          );
          return finishLocalLeave();
        }
        final retryResult = await retryLeaveAfterRejoin(
          session,
          initialFailure: failure,
        );
        if (retryResult != null) {
          return retryResult;
        }
        return finishLocalLeaveAfterUnconfirmedLeave(
          failure,
          stackTrace: stackTrace,
        );
      }

      return finishLocalLeave();
    } finally {
      endTransportTeardown();
    }
  }

  Future<GroupListeningSessionState> closeRoom({
    String source = 'unknown',
  }) async {
    final session = readRuntimeSession();
    final room = state.room;
    if (session == null || room == null) {
      return setFailure(
        const GroupListeningErrorState(
          code: GroupListeningErrorCode.sessionUnavailable,
          message: 'No active Voyage room is available to close.',
        ),
      );
    }
    if (!room.self.canManageRoom) {
      return setFailure(
        const GroupListeningErrorState(
          code: GroupListeningErrorCode.forbidden,
          message: 'Only the host can close this room.',
        ),
      );
    }
    logRoomAction('close room', source: source);

    state = state.copyWith(
      status: GroupListeningSessionStatus.disconnecting,
      clearFailure: true,
    );
    beginTransportTeardown();
    try {
      try {
        final result = await runAuthenticatedWithRejoinRetry(
          (freshSession) => ref
              .read(groupListeningRepositoryProvider)
              .closeRoom(
                freshSession,
                expectedRoomVersion: state.lastAppliedRoomVersion,
              ),
          fallbackMessage: 'Unable to close Voyage room.',
          fallbackCode: GroupListeningErrorCode.transportUnavailable,
        );
        await disposeTransport();
        writeRuntimeSession(null);
        await ref.read(groupListeningSessionCredentialStoreProvider).clear();
        final latestRoom = state.room ?? room;
        state = state.copyWith(
          status: GroupListeningSessionStatus.idle,
          connection: const GroupListeningConnectionState.disconnected(),
          room: latestRoom.copyWith(
            roomStatus: result.roomStatus,
            roomVersion: result.roomVersion,
            serverTime: result.closedAt,
          ),
          lastAppliedRoomVersion: result.roomVersion,
          lastAppliedEventId: latestRoom.latestEventId,
          snapshotRequired: false,
          clearActiveInviteCode: true,
          clearFailure: true,
        );
        return state;
      } on Object catch (error, stackTrace) {
        final failure = asFailure(
          error,
          fallbackMessage: 'Unable to close Voyage room.',
          fallbackCode: GroupListeningErrorCode.transportUnavailable,
        );
        final roomAlreadyClosed =
            state.room?.roomStatus == GroupListeningRoomStatus.closed ||
            failure.code == GroupListeningErrorCode.roomClosed;
        final gracefulTransportTeardown =
            failure.code == GroupListeningErrorCode.transportUnavailable &&
            readTransportTeardownFailureObserved();
        if (!roomAlreadyClosed && !gracefulTransportTeardown) {
          if (shouldCollapseToLocalCleanup(failure.code)) {
            return finishInvalidatedSessionCleanup(failure);
          }
          return setFailure(failure, stackTrace: stackTrace);
        }

        AppLogger.warning(
          'Close request rejected (${failure.code}), cleaning up locally.',
        );
        await disposeTransport();
        writeRuntimeSession(null);
        await ref.read(groupListeningSessionCredentialStoreProvider).clear();
        final latestRoom = switch (state.room) {
          final current?
              when failure.code == GroupListeningErrorCode.roomClosed ||
                  gracefulTransportTeardown =>
            current.copyWith(
              roomStatus: GroupListeningRoomStatus.closed,
              serverTime: DateTime.now(),
            ),
          final current? => current,
          null => null,
        };
        state = state.copyWith(
          status: GroupListeningSessionStatus.idle,
          connection: const GroupListeningConnectionState.disconnected(),
          room: latestRoom,
          clearRoom: latestRoom == null,
          lastAppliedRoomVersion: latestRoom?.roomVersion ?? 0,
          lastAppliedEventId: latestRoom?.latestEventId ?? 0,
          snapshotRequired: false,
          clearActiveInviteCode: true,
          clearFailure: true,
        );
        return state;
      }
    } finally {
      endTransportTeardown();
    }
  }

  Future<GroupListeningSessionState> rotateInvite({
    String source = 'unknown',
  }) async {
    final room = state.room;
    if (readRuntimeSession() == null || room == null) {
      return setFailure(
        const GroupListeningErrorState(
          code: GroupListeningErrorCode.sessionUnavailable,
          message: 'No active Voyage room is available.',
        ),
      );
    }
    if (!room.self.canManageRoom) {
      return setFailure(
        const GroupListeningErrorState(
          code: GroupListeningErrorCode.forbidden,
          message: 'Only the host can rotate the invite.',
        ),
      );
    }
    logRoomAction('rotate invite', source: source);

    try {
      final result = await runAuthenticatedWithRejoinRetry(
        (freshSession) => ref
            .read(groupListeningRepositoryProvider)
            .rotateInvite(
              freshSession,
              expectedRoomVersion: state.lastAppliedRoomVersion,
            ),
        fallbackMessage: 'Unable to rotate Voyage invite.',
        fallbackCode: GroupListeningErrorCode.transportUnavailable,
      );
      state = state.copyWith(
        room: state.room?.copyWith(roomVersion: result.roomVersion),
        lastAppliedRoomVersion: result.roomVersion,
        lastAppliedEventId: state.lastAppliedEventId,
        activeInviteCode: result.inviteCode,
        clearFailure: true,
      );
      return state;
    } on Object catch (error, stackTrace) {
      final failure = asFailure(
        error,
        fallbackMessage: 'Unable to rotate Voyage invite.',
        fallbackCode: GroupListeningErrorCode.transportUnavailable,
      );
      if (shouldCollapseToLocalCleanup(failure.code)) {
        return finishInvalidatedSessionCleanup(failure);
      }
      return setFailure(
        failure,
        stackTrace: stackTrace,
      );
    }
  }

  Future<String?> transferHost({
    required String targetMemberId,
    String source = 'unknown',
  }) async {
    final room = state.room;
    if (readRuntimeSession() == null || room == null) {
      state = state.copyWith(
        failure: const GroupListeningErrorState(
          code: GroupListeningErrorCode.sessionUnavailable,
          message: 'No active Voyage room is available.',
        ),
      );
      return null;
    }
    if (!room.self.canManageRoom) {
      state = state.copyWith(
        failure: const GroupListeningErrorState(
          code: GroupListeningErrorCode.forbidden,
          message: 'Only the host can transfer room ownership.',
        ),
      );
      return null;
    }
    if (targetMemberId == room.self.memberId) {
      state = state.copyWith(
        failure: const GroupListeningErrorState(
          code: GroupListeningErrorCode.validationFailed,
          message: 'Select a different active member as the new host.',
        ),
      );
      return null;
    }
    GroupListeningMemberState? targetMember;
    for (final member in room.members) {
      if (member.memberId == targetMemberId) {
        targetMember = member;
        break;
      }
    }
    if (targetMember == null) {
      state = state.copyWith(
        failure: const GroupListeningErrorState(
          code: GroupListeningErrorCode.validationFailed,
          message: 'The selected member is no longer in the room.',
        ),
      );
      return null;
    }
    if (targetMember.presenceState !=
        GroupListeningMemberPresenceState.active) {
      state = state.copyWith(
        failure: const GroupListeningErrorState(
          code: GroupListeningErrorCode.validationFailed,
          message: 'Select an active member as the new host.',
        ),
      );
      return null;
    }
    logRoomAction('transfer host', source: source);
    return sendMutation(
      type: GroupListeningMutationType.transferHost,
      targetMemberId: targetMemberId,
    );
  }

  Future<GroupListeningSessionState> reconnect({
    bool silentStaleSessionInvalidation = false,
  }) async {
    try {
      final configuration = await configurationForRoomOperation(
        preferStoredServer: true,
      );
      final storedSession = await ref
          .read(groupListeningSessionCredentialStoreProvider)
          .read();
      if (storedSession == null) {
        _clearStoredSessionFlag();
        if (silentStaleSessionInvalidation) {
          return discardStaleStoredSessionSilently();
        }
        return setFailure(
          const GroupListeningErrorState(
            code: GroupListeningErrorCode.sessionUnavailable,
            message: 'No stored Voyage rejoin session is available.',
          ),
        );
      }
      if (storedSession.sourceServerFingerprint !=
          configuration.sourceServerFingerprint) {
        if (silentStaleSessionInvalidation) {
          return discardStaleStoredSessionSilently(
            const GroupListeningErrorState(
              code: GroupListeningErrorCode.fingerprintMismatch,
              message: 'Stored Voyage session does not match the active server.',
            ),
          );
        }
        await ref.read(groupListeningSessionCredentialStoreProvider).clear();
        writeRuntimeSession(null);
        _clearStoredSessionFlag();
        return setFailure(
          const GroupListeningErrorState(
            code: GroupListeningErrorCode.fingerprintMismatch,
            message: 'Stored Voyage session does not match the active server.',
          ),
        );
      }

      state = state.copyWith(
        status: GroupListeningSessionStatus.reconnecting,
        connection: state.connection.copyWith(
          status: GroupListeningConnectionStatus.reconnecting,
          reconnectAttempt: state.connection.reconnectAttempt + 1,
          clearDisconnectReason: true,
        ),
        clearFailure: true,
      );
      final result = await ref
          .read(groupListeningRepositoryProvider)
          .rejoinRoom(
            GroupListeningRejoinRoomRequest(
              configuration: configuration,
              session: storedSession.copyWith(
                lastAppliedRoomVersion: state.lastAppliedRoomVersion,
                lastAppliedEventId: state.lastAppliedEventId,
              ),
            ),
          );
      await bindJoinedSession(
        result: result,
        client: storedSession.client,
        connectAfterJoin: true,
      );
      return state;
    } on Object catch (error, stackTrace) {
      final failure = asFailure(
        error,
        fallbackMessage: 'Unable to rejoin Voyage room.',
        fallbackCode: GroupListeningErrorCode.transportUnavailable,
      );
      if (silentStaleSessionInvalidation) {
        if (shouldCollapseToLocalCleanup(failure.code) ||
            isFatalSessionFailure(failure.code)) {
          return discardStaleStoredSessionSilently(failure);
        }
        state = state.copyWith(
          status: GroupListeningSessionStatus.idle,
          connection: const GroupListeningConnectionState.disconnected(),
          clearFailure: true,
        );
        return state;
      }
      if (shouldCollapseToLocalCleanup(failure.code)) {
        return finishInvalidatedSessionCleanup(failure);
      }
      if (shouldAutoReconnectAfterFailure(failure)) {
        scheduleAutoReconnect();
      }
      if (isFatalSessionFailure(failure.code)) {
        await ref.read(groupListeningSessionCredentialStoreProvider).clear();
        writeRuntimeSession(null);
      }
      if (isFatalSessionFailure(failure.code) ||
          shouldCollapseToLocalCleanup(failure.code)) {
        _clearStoredSessionFlag();
      }
      return setFailure(failure, stackTrace: stackTrace);
    }
  }

  Future<GroupListeningSessionState> disconnect({
    bool preserveSession = true,
  }) async {
    state = state.copyWith(
      status: GroupListeningSessionStatus.disconnecting,
      connection: state.connection.copyWith(
        status: GroupListeningConnectionStatus.disconnected,
      ),
      clearFailure: true,
    );
    await disposeTransport();
    if (!preserveSession) {
      clearMutationOutbox();
      writeRuntimeSession(null);
      await ref.read(groupListeningSessionCredentialStoreProvider).clear();
    }
    state = state.copyWith(
      status: GroupListeningSessionStatus.idle,
      connection: const GroupListeningConnectionState.disconnected(),
      clearRoom: !preserveSession,
      lastAppliedRoomVersion: preserveSession
          ? state.lastAppliedRoomVersion
          : 0,
      lastAppliedEventId: preserveSession ? state.lastAppliedEventId : 0,
      snapshotRequired: preserveSession ? state.snapshotRequired : false,
      hasStoredSession: preserveSession ? state.hasStoredSession : false,
    );
    return state;
  }

  Future<void> probeStoredSession() async {
    final stored = await ref
        .read(groupListeningSessionCredentialStoreProvider)
        .read();
    if (!ref.mounted) {
      return;
    }
    if (stored != null && !state.hasStoredSession) {
      state = stateApplier.withSyncHealth(
        state.copyWith(hasStoredSession: true),
      );
    } else if (stored == null && state.hasStoredSession) {
      state = stateApplier.withSyncHealth(
        state.copyWith(hasStoredSession: false),
      );
    }
  }

  Future<void> restoreStoredSessionIfAvailable() async {
    await attemptValidatedColdStartAutoRejoin();
  }

  Future<void> attemptValidatedColdStartAutoRejoin() async {
    if (readColdStartAutoRejoinAttempted() || state.hasActiveRoom) {
      return;
    }
    writeColdStartAutoRejoinAttempted(true);
    final settings = ref.read(groupListeningSettingsProvider);
    if (!settings.enabled) {
      return;
    }
    if (ref.read(groupListeningAvailabilityProvider) !=
        GroupListeningAvailability.ready) {
      return;
    }
    final stored = await ref
        .read(groupListeningSessionCredentialStoreProvider)
        .read();
    if (!ref.mounted) {
      return;
    }
    if (stored == null) {
      return;
    }
    state = stateApplier.withSyncHealth(state.copyWith(hasStoredSession: true));
    await reconnect(silentStaleSessionInvalidation: true);
    if (!ref.mounted) {
      return;
    }
  }

  Future<T> runAuthenticatedWithRejoinRetry<T>(
    Future<T> Function(GroupListeningSessionRuntimeContext session) operation, {
    required String fallbackMessage,
    required GroupListeningErrorCode fallbackCode,
  }) async {
    var session = await ensureFreshSession();
    try {
      return await operation(session);
    } on Object catch (error) {
      final failure = asFailure(
        error,
        fallbackMessage: fallbackMessage,
        fallbackCode: fallbackCode,
      );
      if (failure.code != GroupListeningErrorCode.unauthorized) {
        rethrow;
      }
      session = await ensureFreshSession(force: true);
      return operation(session);
    }
  }

  Future<GroupListeningSessionRuntimeContext> ensureFreshSession({
    bool force = false,
  }) async {
    final session = readRuntimeSession();
    if (session == null) {
      throw const GroupListeningRepositoryException(
        GroupListeningErrorState(
          code: GroupListeningErrorCode.sessionUnavailable,
          message: 'No active Voyage session is available.',
        ),
      );
    }
    if (!force &&
        session.accessTokenExpiresAt
                .difference(DateTime.now().toUtc())
                .compareTo(tokenRefreshWindow) >
            0) {
      return session;
    }
    if (!force &&
        state.connection.isConnected &&
        state.connection.clientConnectionId != null) {
      try {
        return await refreshAccessTokenOverTransport(session);
      } on Object {
        // Fall back to HTTP rejoin when WS refresh is unavailable.
      }
    }
    return rejoinCurrentSession(session);
  }

  Future<GroupListeningSessionRuntimeContext> rejoinCurrentSession(
    GroupListeningSessionRuntimeContext expectedSession,
  ) async {
    final store = ref.read(groupListeningSessionCredentialStoreProvider);
    final storedSession = await store.read();
    if (storedSession == null ||
        !_matchesStoredSession(storedSession, expectedSession)) {
      throw const GroupListeningRepositoryException(
        GroupListeningErrorState(
          code: GroupListeningErrorCode.sessionUnavailable,
          message: 'No stored Voyage rejoin session is available.',
        ),
      );
    }
    final configuration = configurationWithVoyageBaseUrl(
      requireConfiguration(),
      expectedSession.voyageBaseUrl,
      protocolVersion: storedSession.protocolVersion,
    );
    final result = await ref
        .read(groupListeningRepositoryProvider)
        .rejoinRoom(
          GroupListeningRejoinRoomRequest(
            configuration: configuration,
            session: storedSession.copyWith(
              lastAppliedRoomVersion: state.lastAppliedRoomVersion,
              lastAppliedEventId: state.lastAppliedEventId,
            ),
          ),
        );
    writeRuntimeSession(result.runtimeContext);
    stateApplier.applySnapshot(result.roomSnapshot);
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
        sourceServerFingerprint: result.runtimeContext.sourceServerFingerprint,
        rejoinToken: result.runtimeContext.rejoinToken,
        client: storedSession.client,
        lastAppliedRoomVersion: result.roomSnapshot.roomVersion,
        lastAppliedEventId: result.roomSnapshot.latestEventId,
        protocolVersion: result.runtimeContext.protocolVersion,
      ),
    );
    return result.runtimeContext;
  }

  Future<void> bindJoinedSession({
    required GroupListeningJoinResponse result,
    required GroupListeningClientDescriptor client,
    required bool connectAfterJoin,
  }) async {
    serverClockEstimator.clear();
    writeRuntimeSession(result.runtimeContext);
    final storedSession = GroupListeningStoredSession(
      roomId: result.runtimeContext.roomId,
      memberId: result.runtimeContext.memberId,
      role: result.runtimeContext.role,
      authVersion: result.runtimeContext.authVersion,
      voyageBaseUrl: result.runtimeContext.voyageBaseUrl,
      sourceServerFingerprint: result.runtimeContext.sourceServerFingerprint,
      rejoinToken: result.runtimeContext.rejoinToken,
      client: client,
      lastAppliedRoomVersion: result.roomSnapshot.roomVersion,
      lastAppliedEventId: result.roomSnapshot.latestEventId,
      protocolVersion: result.runtimeContext.protocolVersion,
    );
    stateApplier.applySnapshot(result.roomSnapshot);
    state = state.copyWith(
      activeInviteCode: result.inviteCode,
      clearActiveInviteCode: result.inviteCode == null,
    );
    await ref
        .read(groupListeningSessionCredentialStoreProvider)
        .save(storedSession);
    if (connectAfterJoin) {
      await connect();
    } else {
      state = state.copyWith(
        status: GroupListeningSessionStatus.idle,
        connection: const GroupListeningConnectionState.disconnected(),
      );
    }
  }

  Future<GroupListeningSessionState> discardStaleStoredSessionSilently([
    GroupListeningErrorState? failure,
  ]) async {
    AppLogger.debug(
      'Group listening: discarding stale stored session'
      '${failure == null ? '' : ' (${failure.code.name})'}.',
    );
    await disposeTransport();
    writeRuntimeSession(null);
    await ref.read(groupListeningSessionCredentialStoreProvider).clear();
    state = state.copyWith(
      status: GroupListeningSessionStatus.idle,
      connection: const GroupListeningConnectionState.disconnected(),
      clearRoom: true,
      lastAppliedRoomVersion: 0,
      lastAppliedEventId: 0,
      snapshotRequired: false,
      clearActiveInviteCode: true,
      clearFailure: true,
      hasStoredSession: false,
    );
    return state;
  }

  Future<GroupListeningSessionState> finishInvalidatedSessionCleanup(
    GroupListeningErrorState failure,
  ) async {
    AppLogger.warning(
      'Group listening: session invalidated by ${failure.code.name}; '
      'cleaning up locally.',
    );
    await disposeTransport();
    writeRuntimeSession(null);
    await ref.read(groupListeningSessionCredentialStoreProvider).clear();
    state = state.copyWith(
      status: GroupListeningSessionStatus.idle,
      connection: const GroupListeningConnectionState.disconnected(),
      clearRoom: true,
      lastAppliedRoomVersion: 0,
      lastAppliedEventId: 0,
      snapshotRequired: false,
      clearActiveInviteCode: true,
      failure: failure,
      hasStoredSession: false,
    );
    return state;
  }

  Future<GroupListeningSessionState> finishLocalLeave() async {
    await disposeTransport();
    clearMutationOutbox();
    writeRuntimeSession(null);
    await ref.read(groupListeningSessionCredentialStoreProvider).clear();
    state = state.copyWith(
      status: GroupListeningSessionStatus.idle,
      connection: const GroupListeningConnectionState.disconnected(),
      clearRoom: true,
      clearFailure: true,
      lastAppliedRoomVersion: 0,
      lastAppliedEventId: 0,
      snapshotRequired: false,
      hasStoredSession: false,
    );
    return state;
  }

  Future<GroupListeningSessionState?> retryLeaveAfterRejoin(
    GroupListeningSessionRuntimeContext expectedSession, {
    required GroupListeningErrorState initialFailure,
  }) async {
    if (initialFailure.code != GroupListeningErrorCode.transportUnavailable &&
        initialFailure.code != GroupListeningErrorCode.transportDisconnected) {
      return null;
    }

    try {
      final refreshedSession = await rejoinCurrentSession(expectedSession);
      await ref
          .read(groupListeningRepositoryProvider)
          .leaveRoom(
            refreshedSession,
            lastAppliedRoomVersion: state.lastAppliedRoomVersion,
          );
      return finishLocalLeave();
    } on Object catch (error, stackTrace) {
      final retryFailure = asFailure(
        error,
        fallbackMessage: 'Unable to leave Voyage room cleanly.',
        fallbackCode: GroupListeningErrorCode.transportUnavailable,
      );
      if (canLeaveLocallyAfterFailure(retryFailure)) {
        AppLogger.warning(
          'Leave retry rejected (${retryFailure.code}), leaving locally.',
        );
        return finishLocalLeave();
      }
      return finishLocalLeaveAfterUnconfirmedLeave(
        retryFailure,
        stackTrace: stackTrace,
      );
    }
  }

  Future<GroupListeningSessionState> finishLocalLeaveAfterUnconfirmedLeave(
    GroupListeningErrorState failure, {
    StackTrace? stackTrace,
  }) async {
    AppLogger.warning(
      'Leave was not confirmed by Voyage (${failure.code}); '
      'clearing local session anyway.${stackTrace == null ? '' : '\n$stackTrace'}',
    );
    return finishLocalLeave();
  }

  Future<GroupListeningClientConfiguration> configurationForRoomOperation({
    bool preferStoredServer = false,
  }) async {
    final configuration = requireConfiguration();
    final resolved = await resolveBestBundledServer(
      preferredUrl: preferStoredServer
          ? (await ref
                    .read(groupListeningSessionCredentialStoreProvider)
                    .read())
                ?.voyageBaseUrl
                .toString()
          : null,
    );
    if (resolved == null) {
      final discovery = await ref
          .read(groupListeningRepositoryProvider)
          .discover(configuration);
      return configurationWithVoyageBaseUrl(
        configuration,
        configuration.voyageBaseUrl,
        protocolVersion: discovery.preferredProtocolVersion,
      );
    }
    return configurationWithVoyageBaseUrl(
      configuration,
      Uri.parse(resolved.option.url),
      protocolVersion: resolved.discovery.preferredProtocolVersion,
    );
  }

  Future<GroupListeningResolvedVoyageServer?> resolveBestBundledServer({
    String? preferredUrl,
  }) async {
    final configuration = readConfiguration();
    if (configuration == null ||
        state.availability != GroupListeningAvailability.ready) {
      return null;
    }
    return resolveBestBundledVoyageServer(
      ref,
      configuration,
      preferredUrl: preferredUrl,
    );
  }

  Future<GroupListeningCapabilityDiscovery> discoverSessionServer(
    GroupListeningSessionRuntimeContext session,
  ) {
    final configuration = requireConfiguration();
    return ref
        .read(groupListeningRepositoryProvider)
        .discover(
          configurationWithVoyageBaseUrl(configuration, session.voyageBaseUrl),
        );
  }

  GroupListeningClientConfiguration requireConfiguration() {
    final configuration = readConfiguration();
    if (configuration == null ||
        state.availability != GroupListeningAvailability.ready) {
      throw const GroupListeningRepositoryException(
        GroupListeningErrorState(
          code: GroupListeningErrorCode.configurationMissing,
          message: 'Voyage settings are incomplete or disabled.',
        ),
      );
    }
    return configuration;
  }

  void _clearStoredSessionFlag() {
    if (!state.hasStoredSession) {
      return;
    }
    state = stateApplier.withSyncHealth(
      state.copyWith(hasStoredSession: false),
    );
  }

  bool _matchesStoredSession(
    GroupListeningStoredSession stored,
    GroupListeningSessionRuntimeContext expected,
  ) {
    return stored.roomId == expected.roomId &&
        stored.memberId == expected.memberId &&
        stored.sourceServerFingerprint == expected.sourceServerFingerprint;
  }
}
