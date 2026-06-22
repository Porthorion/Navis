import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';

abstract class GroupListeningOutboundTransportMessage {
  const GroupListeningOutboundTransportMessage();
}

class GroupListeningHeartbeatMessage
    extends GroupListeningOutboundTransportMessage {
  const GroupListeningHeartbeatMessage({
    required this.clientConnectionId,
    required this.clientTime,
    required this.lastAppliedRoomVersion,
    this.lastAppliedEventId = 0,
    this.lastAppliedQueueVersion = 0,
    this.lastAppliedPlaybackVersion = 0,
    this.lastAppliedPresenceVersion = 0,
    this.observedPosition,
    this.transportRtt,
  });

  final String clientConnectionId;
  final DateTime clientTime;
  final int lastAppliedRoomVersion;
  final int lastAppliedEventId;
  final int lastAppliedQueueVersion;
  final int lastAppliedPlaybackVersion;
  final int lastAppliedPresenceVersion;
  final Duration? observedPosition;
  final Duration? transportRtt;
}

class GroupListeningClientStatusMessage
    extends GroupListeningOutboundTransportMessage {
  const GroupListeningClientStatusMessage({
    required this.clientConnectionId,
    required this.lastAppliedPlaybackApplyId,
    this.observedQueueEntryId,
    this.observedCurrentIndex,
    this.localProcessingState,
    this.loadingAge,
    required this.clientTime,
  });

  final String clientConnectionId;
  final int lastAppliedPlaybackApplyId;
  final String? observedQueueEntryId;
  final int? observedCurrentIndex;
  final String? localProcessingState;
  final Duration? loadingAge;
  final DateTime clientTime;
}

class GroupListeningSessionRefreshMessage
    extends GroupListeningOutboundTransportMessage {
  const GroupListeningSessionRefreshMessage({
    required this.clientConnectionId,
  });

  final String clientConnectionId;
}

enum GroupListeningMutationType {
  playbackAnchor,
  queueAdd,
  queueRemove,
  queueReplace,
  transferHost,
  removeMember,
}

class GroupListeningTrackReadinessMessage
    extends GroupListeningOutboundTransportMessage {
  const GroupListeningTrackReadinessMessage({
    required this.clientConnectionId,
    required this.queueEntryId,
    required this.status,
    this.resolvedSongId,
  });

  final String clientConnectionId;
  final String queueEntryId;
  final String status;
  final String? resolvedSongId;
}

class GroupListeningMutationMessage
    extends GroupListeningOutboundTransportMessage {
  const GroupListeningMutationMessage({
    required this.type,
    required this.expectedRoomVersion,
    this.expectedQueueVersion,
    this.expectedPlaybackVersion,
    this.expectedPlaybackEpoch,
    required this.clientMutationId,
    required this.clientConnectionId,
    required this.clientSequence,
    this.playbackAnchor,
    this.queue,
    this.targetQueueEntryId,
    this.insertIndex,
    this.targetMemberId,
  });

  final GroupListeningMutationType type;
  final int expectedRoomVersion;
  final int? expectedQueueVersion;
  final int? expectedPlaybackVersion;
  final int? expectedPlaybackEpoch;
  final String clientMutationId;
  final String clientConnectionId;
  final int clientSequence;
  final GroupListeningPlaybackAnchor? playbackAnchor;
  final GroupListeningQueueState? queue;
  final String? targetQueueEntryId;
  final int? insertIndex;
  final String? targetMemberId;
}

abstract class GroupListeningTransportMessage {
  const GroupListeningTransportMessage();
}

class GroupListeningConnectionWelcomeMessage
    extends GroupListeningTransportMessage {
  const GroupListeningConnectionWelcomeMessage({
    required this.roomId,
    required this.memberId,
    required this.clientConnectionId,
    required this.roomVersion,
    required this.presenceVersion,
    required this.heartbeatInterval,
    required this.memberStaleTimeout,
    required this.serverTime,
  });

  final String roomId;
  final String memberId;
  final String clientConnectionId;
  final int roomVersion;
  final int presenceVersion;
  final Duration heartbeatInterval;
  final Duration memberStaleTimeout;
  final DateTime serverTime;
}

class GroupListeningConnectionReadyMessage
    extends GroupListeningTransportMessage {
  const GroupListeningConnectionReadyMessage({
    required this.clientConnectionId,
    required this.resumeStatus,
    required this.serverTime,
    required this.latestEventId,
    required this.minAvailableEventId,
    required this.roomVersion,
    required this.queueVersion,
    required this.playbackVersion,
    this.playbackEpoch = 0,
    required this.presenceVersion,
    required this.authVersion,
    required this.heartbeatInterval,
    required this.memberStaleTimeout,
  });

  final String clientConnectionId;
  final String resumeStatus;
  final DateTime serverTime;
  final int latestEventId;
  final int minAvailableEventId;
  final int roomVersion;
  final int queueVersion;
  final int playbackVersion;
  final int playbackEpoch;
  final int presenceVersion;
  final int authVersion;
  final Duration heartbeatInterval;
  final Duration memberStaleTimeout;

  bool get requiresSnapshot => resumeStatus == 'snapshot_required';
}

class GroupListeningRoomSnapshotMessage extends GroupListeningTransportMessage {
  const GroupListeningRoomSnapshotMessage(this.snapshot);

  final GroupListeningRoomState snapshot;
}

class GroupListeningRoomEventMessage extends GroupListeningTransportMessage {
  const GroupListeningRoomEventMessage(this.event);

  final GroupListeningRoomEvent event;
}

class GroupListeningPresenceUpdatedMessage
    extends GroupListeningTransportMessage {
  const GroupListeningPresenceUpdatedMessage({
    required this.roomId,
    required this.roomVersion,
    required this.presenceVersion,
    required this.members,
  });

  final String roomId;
  final int roomVersion;
  final int presenceVersion;
  final List<GroupListeningMemberState> members;
}

class GroupListeningTransportErrorMessage
    extends GroupListeningTransportMessage {
  const GroupListeningTransportErrorMessage(this.error);

  final GroupListeningErrorState error;
}

class GroupListeningHeartbeatAckMessage extends GroupListeningTransportMessage {
  const GroupListeningHeartbeatAckMessage({
    required this.serverTime,
    required this.roomVersion,
    this.latestEventId = 0,
    this.queueVersion = 0,
    this.playbackVersion = 0,
    this.playbackApplyId = 0,
    required this.presenceVersion,
    this.authVersion = 0,
    this.clientTime,
    this.serverReceiveTime,
    this.serverSendTime,
    required this.nextHeartbeatDeadline,
  });

  final DateTime serverTime;
  final int roomVersion;
  final int latestEventId;
  final int queueVersion;
  final int playbackVersion;
  final int playbackApplyId;
  final int presenceVersion;
  final int authVersion;
  final DateTime? clientTime;
  final DateTime? serverReceiveTime;
  final DateTime? serverSendTime;
  final DateTime nextHeartbeatDeadline;
}

class GroupListeningMutationAckMessage extends GroupListeningTransportMessage {
  const GroupListeningMutationAckMessage({
    required this.clientMutationId,
    required this.eventId,
    required this.roomVersion,
    required this.queueVersion,
    required this.playbackVersion,
    this.playbackApplyId,
    required this.presenceVersion,
    required this.authVersion,
  });

  final String clientMutationId;
  final int eventId;
  final int roomVersion;
  final int queueVersion;
  final int playbackVersion;
  final int? playbackApplyId;
  final int presenceVersion;
  final int authVersion;
}

class GroupListeningRoomClosedMessage extends GroupListeningTransportMessage {
  const GroupListeningRoomClosedMessage({
    required this.roomId,
    required this.roomVersion,
    required this.closedAt,
  });

  final String roomId;
  final int roomVersion;
  final DateTime closedAt;
}

class GroupListeningTransportDisconnectedMessage
    extends GroupListeningTransportMessage {
  const GroupListeningTransportDisconnectedMessage({
    this.error,
    this.retryable = true,
  });

  final GroupListeningErrorState? error;
  final bool retryable;
}

/// Emitted when the server rejects a mutation with a non-fatal error code
/// (forbidden, sequence_rejected, duplicate_mutation).  The session must NOT
/// be disconnected; the rejection is informational only.
class GroupListeningMutationRejectedMessage
    extends GroupListeningTransportMessage {
  const GroupListeningMutationRejectedMessage({
    required this.error,
    this.clientMutationId,
    this.roomVersion,
    this.queueVersion,
    this.playbackVersion,
    this.playbackApplyId,
    this.presenceVersion,
    this.authVersion,
    this.conflict,
  });

  final GroupListeningErrorState error;
  final String? clientMutationId;
  final int? roomVersion;
  final int? queueVersion;
  final int? playbackVersion;
  final int? playbackApplyId;
  final int? presenceVersion;
  final int? authVersion;
  final String? conflict;
}

class GroupListeningSessionRefreshedMessage
    extends GroupListeningTransportMessage {
  const GroupListeningSessionRefreshedMessage({
    required this.accessToken,
    required this.accessTokenExpiresAt,
  });

  final String accessToken;
  final DateTime accessTokenExpiresAt;
}

abstract class GroupListeningRealtimeConnection {
  Stream<GroupListeningTransportMessage> get messages;

  Future<void> send(GroupListeningOutboundTransportMessage message);

  Future<void> disconnect();
}
