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
    required this.serverVersion,
    required this.buildCommit,
    required this.buildTime,
    required this.supportedProtocolVersions,
    required this.latestProtocolVersion,
    required this.websocketPath,
    required this.heartbeatInterval,
    required this.memberStaleTimeout,
    this.capabilities = const <String>{},
  });

  final String service;
  final String apiVersion;
  final String serverVersion;
  final String buildCommit;
  final String buildTime;
  final List<String> supportedProtocolVersions;
  final String latestProtocolVersion;
  final String websocketPath;
  final Duration heartbeatInterval;
  final Duration memberStaleTimeout;
  final Set<String> capabilities;

  bool get supportsCurrentProtocol =>
      supportedProtocolVersions.contains(voyageProtocolVersionV3) ||
      supportedProtocolVersions.contains(voyageProtocolVersion);

  bool get supportsReplayResume =>
      (supportedProtocolVersions.contains(voyageProtocolVersionV3) ||
          supportedProtocolVersions.contains(voyageProtocolVersion)) &&
      capabilities.contains(voyageReplayResumeCapability);

  String get preferredProtocolVersion {
    if (supportedProtocolVersions.contains(voyageProtocolVersionV3)) {
      return voyageProtocolVersionV3;
    }
    return voyageProtocolVersion;
  }
}

@immutable
class GroupListeningAvailableRoomSummary {
  const GroupListeningAvailableRoomSummary({
    required this.roomId,
    required this.hostDisplayName,
    this.roomMode = GroupListeningRoomMode.collaborative,
    this.requiresPin = false,
    required this.membersTotal,
    required this.activeMembers,
    required this.queueLength,
    required this.roomVersion,
    required this.lastActivityAt,
  });

  final String roomId;
  final String hostDisplayName;
  final GroupListeningRoomMode roomMode;
  final bool requiresPin;
  final int membersTotal;
  final int activeMembers;
  final int queueLength;
  final int roomVersion;
  final DateTime lastActivityAt;
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
    this.protocolVersion = voyageProtocolVersion,
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
  final String protocolVersion;
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
    this.lastAppliedEventId = 0,
    this.protocolVersion = voyageProtocolVersion,
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
  final int lastAppliedEventId;
  final String protocolVersion;

  GroupListeningStoredSession copyWith({
    Uri? voyageBaseUrl,
    int? authVersion,
    String? rejoinToken,
    int? lastAppliedRoomVersion,
    int? lastAppliedEventId,
    String? protocolVersion,
  }) {
    return GroupListeningStoredSession(
      roomId: roomId,
      memberId: memberId,
      role: role,
      authVersion: authVersion ?? this.authVersion,
      voyageBaseUrl: voyageBaseUrl ?? this.voyageBaseUrl,
      sourceServerFingerprint: sourceServerFingerprint,
      rejoinToken: rejoinToken ?? this.rejoinToken,
      client: client,
      lastAppliedRoomVersion:
          lastAppliedRoomVersion ?? this.lastAppliedRoomVersion,
      lastAppliedEventId: lastAppliedEventId ?? this.lastAppliedEventId,
      protocolVersion: protocolVersion ?? this.protocolVersion,
    );
  }
}

@immutable
class GroupListeningCreateRoomRequest {
  const GroupListeningCreateRoomRequest({
    required this.configuration,
    required this.client,
    this.roomOptions = const GroupListeningRoomOptions(),
    this.roomSeed,
  });

  final GroupListeningClientConfiguration configuration;
  final GroupListeningClientDescriptor client;
  final GroupListeningRoomOptions roomOptions;
  final GroupListeningRoomSeed? roomSeed;
}

@immutable
class GroupListeningRoomOptions {
  const GroupListeningRoomOptions({
    this.roomMode = GroupListeningRoomMode.collaborative,
    this.pinCode,
  });

  final GroupListeningRoomMode roomMode;
  final String? pinCode;
}

@immutable
class GroupListeningJoinRoomRequest {
  const GroupListeningJoinRoomRequest({
    required this.configuration,
    required this.client,
    required this.inviteCode,
    this.pinCode,
  });

  final GroupListeningClientConfiguration configuration;
  final GroupListeningClientDescriptor client;
  final String inviteCode;
  final String? pinCode;
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
class GroupListeningCloseRoomResponse {
  const GroupListeningCloseRoomResponse({
    required this.roomId,
    required this.roomStatus,
    required this.roomVersion,
    required this.closedAt,
  });

  final String roomId;
  final GroupListeningRoomStatus roomStatus;
  final int roomVersion;
  final DateTime closedAt;
}

@immutable
class GroupListeningRotateInviteResponse {
  const GroupListeningRotateInviteResponse({
    required this.roomId,
    required this.roomVersion,
    required this.inviteCode,
  });

  final String roomId;
  final int roomVersion;
  final String inviteCode;
}

@immutable
class GroupListeningTransportConnectRequest {
  const GroupListeningTransportConnectRequest({
    required this.session,
    required this.lastAppliedRoomVersion,
    this.lastAppliedEventId = 0,
    this.lastAppliedQueueVersion = 0,
    this.lastAppliedPlaybackVersion = 0,
    this.lastAppliedPresenceVersion = 0,
  });

  final GroupListeningSessionRuntimeContext session;
  final int lastAppliedRoomVersion;
  final int lastAppliedEventId;
  final int lastAppliedQueueVersion;
  final int lastAppliedPlaybackVersion;
  final int lastAppliedPresenceVersion;
}
