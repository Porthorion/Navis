import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';

@immutable
class GroupListeningClientDescriptor {
  const GroupListeningClientDescriptor({
    required this.appVersion,
    required this.platform,
    required this.deviceId,
    this.deviceLabel,
    this.capabilities = const <String>{},
  });

  final String appVersion;
  final String platform;
  final String deviceId;
  final String? deviceLabel;
  final Set<String> capabilities;
}

@immutable
class GroupListeningRoomSeed {
  const GroupListeningRoomSeed({
    required this.queue,
    required this.playbackAnchor,
  });

  final GroupListeningQueueState queue;
  final GroupListeningPlaybackAnchor playbackAnchor;
}

@immutable
class GroupListeningCapabilityDiscovery {
  const GroupListeningCapabilityDiscovery({
    required this.service,
    required this.apiVersion,
    required this.supportedProtocolVersions,
    required this.latestProtocolVersion,
    required this.websocketPath,
    required this.heartbeatInterval,
    required this.memberStaleTimeout,
  });

  final String service;
  final String apiVersion;
  final List<String> supportedProtocolVersions;
  final String latestProtocolVersion;
  final String websocketPath;
  final Duration heartbeatInterval;
  final Duration memberStaleTimeout;

  bool get supportsCurrentProtocol =>
      supportedProtocolVersions.contains(voyageProtocolVersion);
}

@immutable
class GroupListeningSessionRuntimeContext {
  const GroupListeningSessionRuntimeContext({
    required this.roomId,
    required this.memberId,
    required this.role,
    required this.authVersion,
    required this.voyageBaseUrl,
    required this.sourceServerFingerprint,
    required this.accessToken,
    required this.accessTokenExpiresAt,
    required this.rejoinToken,
  });

  final String roomId;
  final String memberId;
  final GroupListeningMemberRole role;
  final int authVersion;
  final Uri voyageBaseUrl;
  final String sourceServerFingerprint;
  final String accessToken;
  final DateTime accessTokenExpiresAt;
  final String rejoinToken;
}

@immutable
class GroupListeningStoredSession {
  const GroupListeningStoredSession({
    required this.roomId,
    required this.memberId,
    required this.role,
    required this.authVersion,
    required this.voyageBaseUrl,
    required this.sourceServerFingerprint,
    required this.rejoinToken,
    required this.client,
    this.lastAppliedRoomVersion = 0,
  });

  final String roomId;
  final String memberId;
  final GroupListeningMemberRole role;
  final int authVersion;
  final Uri voyageBaseUrl;
  final String sourceServerFingerprint;
  final String rejoinToken;
  final GroupListeningClientDescriptor client;
  final int lastAppliedRoomVersion;

  GroupListeningStoredSession copyWith({
    int? authVersion,
    String? rejoinToken,
    int? lastAppliedRoomVersion,
  }) {
    return GroupListeningStoredSession(
      roomId: roomId,
      memberId: memberId,
      role: role,
      authVersion: authVersion ?? this.authVersion,
      voyageBaseUrl: voyageBaseUrl,
      sourceServerFingerprint: sourceServerFingerprint,
      rejoinToken: rejoinToken ?? this.rejoinToken,
      client: client,
      lastAppliedRoomVersion:
          lastAppliedRoomVersion ?? this.lastAppliedRoomVersion,
    );
  }
}

@immutable
class GroupListeningCreateRoomRequest {
  const GroupListeningCreateRoomRequest({
    required this.configuration,
    required this.client,
    this.roomSeed,
  });

  final GroupListeningClientConfiguration configuration;
  final GroupListeningClientDescriptor client;
  final GroupListeningRoomSeed? roomSeed;
}

@immutable
class GroupListeningJoinRoomRequest {
  const GroupListeningJoinRoomRequest({
    required this.configuration,
    required this.client,
    required this.inviteCode,
  });

  final GroupListeningClientConfiguration configuration;
  final GroupListeningClientDescriptor client;
  final String inviteCode;
}

@immutable
class GroupListeningRejoinRoomRequest {
  const GroupListeningRejoinRoomRequest({
    required this.configuration,
    required this.session,
  });

  final GroupListeningClientConfiguration configuration;
  final GroupListeningStoredSession session;
}

@immutable
class GroupListeningJoinResponse {
  const GroupListeningJoinResponse({
    required this.runtimeContext,
    required this.roomSnapshot,
    this.inviteCode,
  });

  final GroupListeningSessionRuntimeContext runtimeContext;
  final GroupListeningRoomState roomSnapshot;
  final String? inviteCode;
}

@immutable
class GroupListeningLeaveResponse {
  const GroupListeningLeaveResponse({
    required this.roomId,
    required this.leftMemberId,
    required this.roomStatus,
    required this.roomVersion,
  });

  final String roomId;
  final String leftMemberId;
  final GroupListeningRoomStatus roomStatus;
  final int roomVersion;
}

@immutable
class GroupListeningTransportConnectRequest {
  const GroupListeningTransportConnectRequest({
    required this.session,
    required this.lastAppliedRoomVersion,
  });

  final GroupListeningSessionRuntimeContext session;
  final int lastAppliedRoomVersion;
}

abstract class GroupListeningOutboundTransportMessage {
  const GroupListeningOutboundTransportMessage();
}

class GroupListeningHeartbeatMessage
    extends GroupListeningOutboundTransportMessage {
  const GroupListeningHeartbeatMessage({
    required this.clientConnectionId,
    required this.clientTime,
    required this.lastAppliedRoomVersion,
    this.observedPosition,
    this.transportRtt,
  });

  final String clientConnectionId;
  final DateTime clientTime;
  final int lastAppliedRoomVersion;
  final Duration? observedPosition;
  final Duration? transportRtt;
}

enum GroupListeningMutationType {
  playbackAnchor,
  queueAdd,
  queueRemove,
  queueReplace,
  transferHost,
  removeMember,
}

class GroupListeningMutationMessage
    extends GroupListeningOutboundTransportMessage {
  const GroupListeningMutationMessage({
    required this.type,
    required this.expectedRoomVersion,
    required this.clientMutationId,
    required this.clientConnectionId,
    required this.clientSequence,
    this.playbackAnchor,
    this.queue,
    this.targetQueueEntryId,
    this.targetMemberId,
  });

  final GroupListeningMutationType type;
  final int expectedRoomVersion;
  final String clientMutationId;
  final String clientConnectionId;
  final int clientSequence;
  final GroupListeningPlaybackAnchor? playbackAnchor;
  final GroupListeningQueueState? queue;
  final String? targetQueueEntryId;
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
    required this.presenceVersion,
    required this.nextHeartbeatDeadline,
  });

  final DateTime serverTime;
  final int roomVersion;
  final int presenceVersion;
  final DateTime nextHeartbeatDeadline;
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

abstract class GroupListeningRealtimeConnection {
  Stream<GroupListeningTransportMessage> get messages;

  Future<void> send(GroupListeningOutboundTransportMessage message);

  Future<void> disconnect();
}

abstract class GroupListeningSessionCredentialStore {
  Future<void> save(GroupListeningStoredSession session);

  Future<GroupListeningStoredSession?> read();

  Future<void> clear();
}

class InMemoryGroupListeningSessionCredentialStore
    implements GroupListeningSessionCredentialStore {
  GroupListeningStoredSession? _session;

  @override
  Future<void> clear() async {
    _session = null;
  }

  @override
  Future<GroupListeningStoredSession?> read() async => _session;

  @override
  Future<void> save(GroupListeningStoredSession session) async {
    _session = session;
  }
}

abstract class GroupListeningHttpClient {
  Future<GroupListeningCapabilityDiscovery> discover(
    GroupListeningClientConfiguration configuration,
  );

  Future<GroupListeningJoinResponse> createRoom(
    GroupListeningCreateRoomRequest request,
  );

  Future<GroupListeningJoinResponse> joinRoom(
    GroupListeningJoinRoomRequest request,
  );

  Future<GroupListeningJoinResponse> rejoinRoom(
    GroupListeningRejoinRoomRequest request,
  );

  Future<GroupListeningRoomState> fetchSnapshot(
    GroupListeningSessionRuntimeContext session, {
    int? lastAppliedRoomVersion,
  });

  Future<GroupListeningLeaveResponse> leaveRoom(
    GroupListeningSessionRuntimeContext session, {
    int? lastAppliedRoomVersion,
  });
}

abstract class GroupListeningRealtimeTransportClient {
  Future<GroupListeningRealtimeConnection> connect(
    GroupListeningTransportConnectRequest request,
  );
}

abstract class GroupListeningRepository {
  Future<GroupListeningCapabilityDiscovery> discover(
    GroupListeningClientConfiguration configuration,
  );

  Future<GroupListeningJoinResponse> createRoom(
    GroupListeningCreateRoomRequest request,
  );

  Future<GroupListeningJoinResponse> joinRoom(
    GroupListeningJoinRoomRequest request,
  );

  Future<GroupListeningJoinResponse> rejoinRoom(
    GroupListeningRejoinRoomRequest request,
  );

  Future<GroupListeningRoomState> fetchSnapshot(
    GroupListeningSessionRuntimeContext session, {
    int? lastAppliedRoomVersion,
  });

  Future<GroupListeningLeaveResponse> leaveRoom(
    GroupListeningSessionRuntimeContext session, {
    int? lastAppliedRoomVersion,
  });

  Future<GroupListeningRealtimeConnection> connect(
    GroupListeningTransportConnectRequest request,
  );
}

class GroupListeningRepositoryException implements Exception {
  const GroupListeningRepositoryException(this.failure);

  final GroupListeningErrorState failure;
}

class UnsupportedGroupListeningHttpClient implements GroupListeningHttpClient {
  const UnsupportedGroupListeningHttpClient();

  @override
  Future<GroupListeningJoinResponse> createRoom(
    GroupListeningCreateRoomRequest request,
  ) {
    throw _unsupported();
  }

  @override
  Future<GroupListeningCapabilityDiscovery> discover(
    GroupListeningClientConfiguration configuration,
  ) {
    throw _unsupported();
  }

  @override
  Future<GroupListeningRoomState> fetchSnapshot(
    GroupListeningSessionRuntimeContext session, {
    int? lastAppliedRoomVersion,
  }) {
    throw _unsupported();
  }

  @override
  Future<GroupListeningJoinResponse> joinRoom(
    GroupListeningJoinRoomRequest request,
  ) {
    throw _unsupported();
  }

  @override
  Future<GroupListeningLeaveResponse> leaveRoom(
    GroupListeningSessionRuntimeContext session, {
    int? lastAppliedRoomVersion,
  }) {
    throw _unsupported();
  }

  @override
  Future<GroupListeningJoinResponse> rejoinRoom(
    GroupListeningRejoinRoomRequest request,
  ) {
    throw _unsupported();
  }
}

class UnsupportedGroupListeningRealtimeTransportClient
    implements GroupListeningRealtimeTransportClient {
  const UnsupportedGroupListeningRealtimeTransportClient();

  @override
  Future<GroupListeningRealtimeConnection> connect(
    GroupListeningTransportConnectRequest request,
  ) {
    throw _unsupported();
  }
}

class DefaultGroupListeningRepository implements GroupListeningRepository {
  const DefaultGroupListeningRepository({
    required GroupListeningHttpClient httpClient,
    required GroupListeningRealtimeTransportClient realtimeTransport,
  }) : _httpClient = httpClient,
       _realtimeTransport = realtimeTransport;

  final GroupListeningHttpClient _httpClient;
  final GroupListeningRealtimeTransportClient _realtimeTransport;

  @override
  Future<GroupListeningRealtimeConnection> connect(
    GroupListeningTransportConnectRequest request,
  ) {
    return _realtimeTransport.connect(request);
  }

  @override
  Future<GroupListeningJoinResponse> createRoom(
    GroupListeningCreateRoomRequest request,
  ) {
    return _httpClient.createRoom(request);
  }

  @override
  Future<GroupListeningCapabilityDiscovery> discover(
    GroupListeningClientConfiguration configuration,
  ) {
    return _httpClient.discover(configuration);
  }

  @override
  Future<GroupListeningRoomState> fetchSnapshot(
    GroupListeningSessionRuntimeContext session, {
    int? lastAppliedRoomVersion,
  }) {
    return _httpClient.fetchSnapshot(
      session,
      lastAppliedRoomVersion: lastAppliedRoomVersion,
    );
  }

  @override
  Future<GroupListeningJoinResponse> joinRoom(
    GroupListeningJoinRoomRequest request,
  ) {
    return _httpClient.joinRoom(request);
  }

  @override
  Future<GroupListeningLeaveResponse> leaveRoom(
    GroupListeningSessionRuntimeContext session, {
    int? lastAppliedRoomVersion,
  }) {
    return _httpClient.leaveRoom(
      session,
      lastAppliedRoomVersion: lastAppliedRoomVersion,
    );
  }

  @override
  Future<GroupListeningJoinResponse> rejoinRoom(
    GroupListeningRejoinRoomRequest request,
  ) {
    return _httpClient.rejoinRoom(request);
  }
}

GroupListeningRepositoryException _unsupported() {
  return const GroupListeningRepositoryException(
    GroupListeningErrorState(
      code: GroupListeningErrorCode.transportUnavailable,
      message: 'Voyage transport is not wired yet.',
    ),
  );
}
