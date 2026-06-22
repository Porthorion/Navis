import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_server_clock_estimator.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_mutation_outbox.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_providers.dart';
import 'package:navis/src/utils/app_logger.dart';

typedef GroupListeningSessionStateReader =
    GroupListeningSessionState Function();
typedef GroupListeningSessionStateWriter =
    void Function(GroupListeningSessionState state);

/// Applies authoritative room snapshots and realtime events to session state.
class GroupListeningSessionStateApplier {
  GroupListeningSessionStateApplier({
    required this.ref,
    required this.readState,
    required this.writeState,
    required this.readConfiguration,
    required this.readRuntimeSession,
    required this.writeRuntimeSession,
    required this.serverClockEstimator,
    required this.readMutationOutbox,
    required this.clearAckLagRecovery,
    required this.pauseMutationOutbox,
    required this.resumeMutationOutbox,
    required this.persistLastAppliedCursor,
    required this.setFailure,
    required this.refreshSnapshot,
    required this.readConnectionConnected,
    required this.snapshotRetryDelay,
    required this.readSnapshotRetryTimer,
    required this.writeSnapshotRetryTimer,
  });

  final Ref ref;
  final GroupListeningSessionStateReader readState;
  final GroupListeningSessionStateWriter writeState;
  final GroupListeningClientConfiguration? Function() readConfiguration;
  final GroupListeningSessionRuntimeContext? Function() readRuntimeSession;
  final void Function(GroupListeningSessionRuntimeContext? session)
  writeRuntimeSession;
  final GroupListeningServerClockEstimator serverClockEstimator;
  final GroupListeningMutationOutbox? Function() readMutationOutbox;
  final void Function({int? upToRoomVersion}) clearAckLagRecovery;
  final void Function() pauseMutationOutbox;
  final void Function() resumeMutationOutbox;
  final Future<void> Function({
    required int roomVersion,
    required int eventId,
    required GroupListeningSessionRuntimeContext? expectedSession,
  })
  persistLastAppliedCursor;
  final GroupListeningSessionState Function(
    GroupListeningErrorState failure, {
    bool clearRoom,
  })
  setFailure;
  final Future<GroupListeningSessionState> Function({String reason})
  refreshSnapshot;
  final bool Function() readConnectionConnected;
  final Duration snapshotRetryDelay;
  final Timer? Function() readSnapshotRetryTimer;
  final void Function(Timer? timer) writeSnapshotRetryTimer;

  GroupListeningSessionState get state => readState();

  set state(GroupListeningSessionState value) => writeState(value);

  GroupListeningSessionState applySnapshot(GroupListeningRoomState snapshot) {
    final configuration = readConfiguration();
    if (configuration == null) {
      return setFailure(
        const GroupListeningErrorState(
          code: GroupListeningErrorCode.configurationMissing,
          message: 'Voyage configuration is not ready.',
        ),
      );
    }
    if (snapshot.sourceServerFingerprint !=
        configuration.sourceServerFingerprint) {
      unawaited(ref.read(groupListeningSessionCredentialStoreProvider).clear());
      writeRuntimeSession(null);
      return setFailure(
        const GroupListeningErrorState(
          code: GroupListeningErrorCode.fingerprintMismatch,
          message:
              'Voyage snapshot fingerprint does not match the active server.',
        ),
        clearRoom: true,
      );
    }
    if (state.room != null && snapshot.roomId != state.room!.roomId) {
      return state;
    }
    if (snapshot.roomVersion < state.lastAppliedRoomVersion) {
      return state;
    }

    serverClockEstimator.recordInstantSample(
      serverTime: snapshot.serverTime,
      clientReceiveTime: DateTime.now().toUtc(),
    );
    final nextConnection =
        snapshot.roomStatus == GroupListeningRoomStatus.closed
        ? const GroupListeningConnectionState.disconnected()
        : state.connection.copyWith(
            serverClockOffset: serverClockEstimator.clockOffset,
          );
    state = withSyncHealth(
      state.copyWith(
        status: snapshot.roomStatus == GroupListeningRoomStatus.closed
            ? GroupListeningSessionStatus.idle
            : state.connection.isConnected
            ? GroupListeningSessionStatus.connected
            : GroupListeningSessionStatus.idle,
        connection: nextConnection,
        room: snapshot,
        lastAppliedRoomVersion: snapshot.roomVersion,
        lastAppliedEventId: snapshot.latestEventId,
        snapshotRequired: false,
        lastSnapshotAt: DateTime.now(),
        localPlaybackEpoch: snapshot.playbackEpoch,
        catchUpAligned: true,
        clearActiveInviteCode:
            snapshot.roomStatus == GroupListeningRoomStatus.closed,
        clearFailure: true,
      ),
    );
    readSnapshotRetryTimer()?.cancel();
    writeSnapshotRetryTimer(null);
    clearAckLagRecovery(upToRoomVersion: snapshot.roomVersion);
    readMutationOutbox()?.dropPendingPlaybackMutations();
    readMutationOutbox()?.revalidateAgainstSnapshot(snapshot);
    resumeMutationOutbox();
    if (snapshot.roomStatus == GroupListeningRoomStatus.closed) {
      writeRuntimeSession(null);
      unawaited(ref.read(groupListeningSessionCredentialStoreProvider).clear());
    }
    unawaited(
      persistLastAppliedCursor(
        roomVersion: snapshot.roomVersion,
        eventId: snapshot.latestEventId,
        expectedSession: readRuntimeSession(),
      ),
    );
    return state;
  }

  GroupListeningSessionState applyRealtimeEvent(GroupListeningRoomEvent event) {
    final room = state.room;
    if (room == null || room.roomId != event.roomId) {
      return requestSnapshotRecovery(
        'room-event-before-snapshot',
        const GroupListeningErrorState(
          code: GroupListeningErrorCode.snapshotRequired,
          message: 'Voyage room event arrived before a room snapshot.',
        ),
      );
    }
    final eventCursor = event.eventCursor;
    if (eventCursor != null) {
      if (eventCursor <= state.lastAppliedEventId) {
        return state;
      }
      if (eventCursor != state.lastAppliedEventId + 1) {
        return requestSnapshotRecovery(
          'room-event-cursor-gap',
          GroupListeningErrorState(
            code: GroupListeningErrorCode.snapshotRequired,
            message: 'Voyage event cursor gap detected.',
            retryable: true,
            roomVersion: event.roomVersion,
            details: <String, Object?>{
              'last_applied_event_id': state.lastAppliedEventId,
              'incoming_event_id': eventCursor,
            },
          ),
        );
      }
    } else if (event.roomVersion <= state.lastAppliedRoomVersion) {
      return state;
    }
    if (eventCursor == null &&
        (event.previousRoomVersion != state.lastAppliedRoomVersion ||
            event.roomVersion != state.lastAppliedRoomVersion + 1)) {
      return requestSnapshotRecovery(
        'room-event-gap',
        GroupListeningErrorState(
          code: GroupListeningErrorCode.snapshotRequired,
          message: 'Voyage room version gap detected.',
          retryable: true,
          roomVersion: event.roomVersion,
          details: <String, Object?>{
            'last_applied_room_version': state.lastAppliedRoomVersion,
            'incoming_room_version': event.roomVersion,
          },
        ),
      );
    }

    state = state.copyWith(
      room: room.applyEvent(event),
      lastAppliedRoomVersion: event.roomVersion,
      lastAppliedEventId: eventCursor ?? state.lastAppliedEventId,
      snapshotRequired: false,
      clearFailure: true,
    );
    clearAckLagRecovery(upToRoomVersion: event.roomVersion);
    unawaited(
      persistLastAppliedCursor(
        roomVersion: event.roomVersion,
        eventId: eventCursor ?? state.lastAppliedEventId,
        expectedSession: readRuntimeSession(),
      ),
    );

    if (event.roomStatus == GroupListeningRoomStatus.closed ||
        event.eventType == GroupListeningRoomEventType.roomClosed) {
      state = state.copyWith(
        status: GroupListeningSessionStatus.idle,
        connection: const GroupListeningConnectionState.disconnected(),
      );
    }
    return state;
  }

  GroupListeningSessionState markSnapshotRequired([
    GroupListeningErrorState? failure,
  ]) {
    clearAckLagRecovery();
    pauseMutationOutbox();
    state = state.copyWith(
      snapshotRequired: true,
      failure:
          failure ??
          const GroupListeningErrorState(
            code: GroupListeningErrorCode.snapshotRequired,
            message: 'Voyage state is stale and requires a fresh snapshot.',
            retryable: true,
          ),
      status: state.connection.isConnected
          ? GroupListeningSessionStatus.connected
          : state.status,
    );
    scheduleSnapshotRetry();
    return state;
  }

  void scheduleSnapshotRetry() {
    readSnapshotRetryTimer()?.cancel();
    if (!readConnectionConnected()) {
      return;
    }
    writeSnapshotRetryTimer(
      Timer(snapshotRetryDelay, () {
        if (!ref.mounted) {
          return;
        }
        if (state.snapshotRequired && readConnectionConnected()) {
          AppLogger.info(
            'Group listening: retrying snapshot refresh via timer',
          );
          unawaited(refreshSnapshot(reason: 'snapshot-retry-timer'));
        }
      }),
    );
  }

  GroupListeningSessionState requestSnapshotRecovery(
    String reason, [
    GroupListeningErrorState? failure,
  ]) {
    final effectiveFailure =
        failure ??
        const GroupListeningErrorState(
          code: GroupListeningErrorCode.snapshotRequired,
          message: 'Voyage state is stale and requires a fresh snapshot.',
          retryable: true,
        );
    AppLogger.info(
      'Group listening: snapshot required '
      '(reason=$reason, code=${effectiveFailure.code.name}, '
      'last_applied=${state.lastAppliedRoomVersion}, '
      'room_version=${effectiveFailure.roomVersion ?? state.room?.roomVersion ?? 0})',
    );
    return markSnapshotRequired(effectiveFailure);
  }

  GroupListeningSessionState withSyncHealth(GroupListeningSessionState next) {
    return next.copyWith(
      syncHealth: GroupListeningSessionState.resolveSyncHealth(
        snapshotRequired: next.snapshotRequired,
        catchUpActive: next.isCatchUpActive,
        connectionConnected: next.connection.isConnected,
        failure: next.failure,
      ),
    );
  }

  void enterCatchUpFromServer({required int serverEpoch}) {
    AppLogger.debug('Group listening: catch_up_enter epoch=$serverEpoch');
    state = withSyncHealth(
      state.copyWith(
        localPlaybackEpoch: state.localPlaybackEpoch,
        catchUpAligned: false,
        room: state.room?.copyWith(playbackEpoch: serverEpoch),
      ),
    );
  }

  void markPlaybackCatchUpAligned({required int serverEpoch}) {
    state = withSyncHealth(
      state.copyWith(
        localPlaybackEpoch: serverEpoch,
        catchUpAligned: true,
      ),
    );
  }

  List<GroupListeningMemberState> mergeMembers({
    required List<GroupListeningMemberState> existing,
    required List<GroupListeningMemberState> updates,
    required List<String> removedMemberIds,
  }) {
    final byId = <String, GroupListeningMemberState>{
      for (final member in existing) member.memberId: member,
    };
    for (final memberId in removedMemberIds) {
      byId.remove(memberId);
    }
    for (final member in updates) {
      byId[member.memberId] = member;
    }
    final merged = byId.values.toList(growable: false)
      ..sort((a, b) => a.joinedAt.compareTo(b.joinedAt));
    return merged;
  }
}
