import 'package:flutter/foundation.dart';

import 'group_listening_playback_models.dart';
import 'group_listening_queue_models.dart';

enum GroupListeningMemberRole { host, member }

enum GroupListeningMemberPresenceState { active, stale, offline }

enum GroupListeningRoomStatus { active, closed }

enum GroupListeningRoomMode { collaborative, shotgun, hostOnly }

enum GroupListeningRoomEventType {
  play,
  pause,
  seek,
  trackChange,
  queueAdd,
  queueRemove,
  queueReplace,
  transferHost,
  memberJoined,
  memberLeft,
  memberRemoved,
  roomClosed,
  roomModeSet,
}

@immutable
class GroupListeningSelfState {
  const GroupListeningSelfState({
    required this.memberId,
    required this.role,
    required this.canControl,
    this.canPlayAudio = true,
    required this.authVersion,
  });

  final String memberId;
  final GroupListeningMemberRole role;
  final bool canControl;
  final bool canPlayAudio;
  final int authVersion;

  bool get isHost => role == GroupListeningMemberRole.host;

  bool get canManageRoom => isHost;

  GroupListeningSelfState copyWith({
    String? memberId,
    GroupListeningMemberRole? role,
    bool? canControl,
    bool? canPlayAudio,
    int? authVersion,
  }) {
    return GroupListeningSelfState(
      memberId: memberId ?? this.memberId,
      role: role ?? this.role,
      canControl: canControl ?? this.canControl,
      canPlayAudio: canPlayAudio ?? this.canPlayAudio,
      authVersion: authVersion ?? this.authVersion,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupListeningSelfState &&
          runtimeType == other.runtimeType &&
          memberId == other.memberId &&
          role == other.role &&
          canControl == other.canControl &&
          canPlayAudio == other.canPlayAudio &&
          authVersion == other.authVersion;

  @override
  int get hashCode =>
      Object.hash(memberId, role, canControl, canPlayAudio, authVersion);
}

@immutable
class GroupListeningMemberState {
  const GroupListeningMemberState({
    required this.memberId,
    required this.displayName,
    this.deviceLabel,
    required this.role,
    required this.presenceState,
    this.capabilities = const <String>{},
    required this.joinedAt,
    required this.lastSeenAt,
  });

  final String memberId;
  final String displayName;
  final String? deviceLabel;
  final GroupListeningMemberRole role;
  final GroupListeningMemberPresenceState presenceState;
  final Set<String> capabilities;
  final DateTime joinedAt;
  final DateTime lastSeenAt;

  GroupListeningMemberState copyWith({
    String? memberId,
    String? displayName,
    String? deviceLabel,
    GroupListeningMemberRole? role,
    GroupListeningMemberPresenceState? presenceState,
    Set<String>? capabilities,
    DateTime? joinedAt,
    DateTime? lastSeenAt,
  }) {
    return GroupListeningMemberState(
      memberId: memberId ?? this.memberId,
      displayName: displayName ?? this.displayName,
      deviceLabel: deviceLabel ?? this.deviceLabel,
      role: role ?? this.role,
      presenceState: presenceState ?? this.presenceState,
      capabilities: capabilities ?? this.capabilities,
      joinedAt: joinedAt ?? this.joinedAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupListeningMemberState &&
          runtimeType == other.runtimeType &&
          memberId == other.memberId &&
          displayName == other.displayName &&
          deviceLabel == other.deviceLabel &&
          role == other.role &&
          presenceState == other.presenceState &&
          setEquals(capabilities, other.capabilities) &&
          joinedAt == other.joinedAt &&
          lastSeenAt == other.lastSeenAt;

  @override
  int get hashCode => Object.hash(
    memberId,
    displayName,
    deviceLabel,
    role,
    presenceState,
    Object.hashAll(capabilities.toList()..sort()),
    joinedAt,
    lastSeenAt,
  );
}

@immutable
class GroupListeningRoomEvent {
  const GroupListeningRoomEvent({
    required this.eventId,
    this.eventCursor,
    required this.eventType,
    required this.roomId,
    required this.previousRoomVersion,
    required this.roomVersion,
    this.queueVersion,
    this.playbackVersion,
    this.playbackApplyId,
    this.causedByMemberId,
    this.clientMutationId,
    this.playbackAnchor,
    this.playbackAnchorCleared = false,
    this.queue,
    this.members = const <GroupListeningMemberState>[],
    this.removedMemberIds = const <String>[],
    this.hostMemberId,
    this.roomStatus,
    this.roomMode,
    this.playbackPhase,
    this.presenceVersion,
    this.authVersion,
    this.self,
  });

  final String eventId;
  final int? eventCursor;
  final GroupListeningRoomEventType eventType;
  final String roomId;
  final int previousRoomVersion;
  final int roomVersion;
  final int? queueVersion;
  final int? playbackVersion;
  final int? playbackApplyId;
  final String? causedByMemberId;
  final String? clientMutationId;
  final GroupListeningPlaybackAnchor? playbackAnchor;
  final bool playbackAnchorCleared;
  final GroupListeningQueueState? queue;
  final List<GroupListeningMemberState> members;
  final List<String> removedMemberIds;
  final String? hostMemberId;
  final GroupListeningRoomStatus? roomStatus;
  final GroupListeningRoomMode? roomMode;
  final String? playbackPhase;
  final int? presenceVersion;
  final int? authVersion;
  final GroupListeningSelfState? self;
}

@immutable
class GroupListeningRoomState {
  const GroupListeningRoomState({
    required this.protocolVersion,
    required this.roomId,
    required this.roomStatus,
    this.roomMode = GroupListeningRoomMode.collaborative,
    this.playbackPhase = 'idle',
    this.requiresPin = false,
    required this.roomVersion,
    this.latestEventId = 0,
    this.playbackVersion = 0,
    this.playbackApplyId = 0,
    this.playbackEpoch = 0,
    required this.presenceVersion,
    required this.authVersion,
    required this.serverTime,
    required this.sourceServerFingerprint,
    required this.hostMemberId,
    required this.self,
    required this.members,
    required this.queue,
    this.playbackAnchor,
  });

  final String protocolVersion;
  final String roomId;
  final GroupListeningRoomStatus roomStatus;
  final GroupListeningRoomMode roomMode;
  final String playbackPhase;
  final bool requiresPin;
  final int roomVersion;
  final int latestEventId;
  final int playbackVersion;
  final int playbackApplyId;
  final int playbackEpoch;
  final int presenceVersion;
  final int authVersion;
  final DateTime serverTime;
  final String sourceServerFingerprint;
  final String hostMemberId;
  final GroupListeningSelfState self;
  final List<GroupListeningMemberState> members;
  final GroupListeningQueueState queue;
  final GroupListeningPlaybackAnchor? playbackAnchor;

  GroupListeningMemberState? get hostMember {
    for (final member in members) {
      if (member.memberId == hostMemberId) {
        return member;
      }
    }
    return null;
  }

  int get activeMemberCount => members
      .where(
        (member) =>
            member.presenceState == GroupListeningMemberPresenceState.active,
      )
      .length;

  int get staleMemberCount => members
      .where(
        (member) =>
            member.presenceState == GroupListeningMemberPresenceState.stale,
      )
      .length;

  GroupListeningRoomState copyWith({
    String? protocolVersion,
    String? roomId,
    GroupListeningRoomStatus? roomStatus,
    GroupListeningRoomMode? roomMode,
    String? playbackPhase,
    bool? requiresPin,
    int? roomVersion,
    int? latestEventId,
    int? playbackVersion,
    int? playbackApplyId,
    int? playbackEpoch,
    int? presenceVersion,
    int? authVersion,
    DateTime? serverTime,
    String? sourceServerFingerprint,
    String? hostMemberId,
    GroupListeningSelfState? self,
    List<GroupListeningMemberState>? members,
    GroupListeningQueueState? queue,
    GroupListeningPlaybackAnchor? playbackAnchor,
    bool clearPlaybackAnchor = false,
  }) {
    return GroupListeningRoomState(
      protocolVersion: protocolVersion ?? this.protocolVersion,
      roomId: roomId ?? this.roomId,
      roomStatus: roomStatus ?? this.roomStatus,
      roomMode: roomMode ?? this.roomMode,
      playbackPhase: playbackPhase ?? this.playbackPhase,
      requiresPin: requiresPin ?? this.requiresPin,
      roomVersion: roomVersion ?? this.roomVersion,
      latestEventId: latestEventId ?? this.latestEventId,
      playbackVersion: playbackVersion ?? this.playbackVersion,
      playbackApplyId: playbackApplyId ?? this.playbackApplyId,
      playbackEpoch: playbackEpoch ?? this.playbackEpoch,
      presenceVersion: presenceVersion ?? this.presenceVersion,
      authVersion: authVersion ?? this.authVersion,
      serverTime: serverTime ?? this.serverTime,
      sourceServerFingerprint:
          sourceServerFingerprint ?? this.sourceServerFingerprint,
      hostMemberId: hostMemberId ?? this.hostMemberId,
      self: self ?? this.self,
      members: members ?? this.members,
      queue: queue ?? this.queue,
      playbackAnchor: clearPlaybackAnchor
          ? null
          : playbackAnchor ?? this.playbackAnchor,
    );
  }

  GroupListeningRoomState applyEvent(GroupListeningRoomEvent event) {
    final updatedMembers = _mergeMembers(
      existing: members,
      updates: event.members,
      removedMemberIds: event.removedMemberIds,
    );
    final nextHostMemberId = event.hostMemberId ?? hostMemberId;
    final explicitSelf = event.self;
    GroupListeningMemberState? updatedSelfMember;
    for (final member in updatedMembers) {
      if (member.memberId == self.memberId) {
        updatedSelfMember = member;
        break;
      }
    }
    final nextSelfRole =
        explicitSelf?.role ??
        updatedSelfMember?.role ??
        (self.memberId == nextHostMemberId
            ? GroupListeningMemberRole.host
            : self.role == GroupListeningMemberRole.host
            ? GroupListeningMemberRole.member
            : self.role);
    final nextRoomStatus = event.roomStatus ?? roomStatus;
    final nextRoomMode = event.roomMode ?? roomMode;
    final nextSelf =
        explicitSelf ??
        self.copyWith(
          role: nextSelfRole,
          canControl:
              nextRoomStatus == GroupListeningRoomStatus.active &&
              (nextRoomMode != GroupListeningRoomMode.hostOnly ||
                  nextSelfRole == GroupListeningMemberRole.host),
          canPlayAudio:
              nextRoomStatus == GroupListeningRoomStatus.active &&
              (nextRoomMode != GroupListeningRoomMode.shotgun ||
                  nextSelfRole == GroupListeningMemberRole.host),
          authVersion: event.authVersion,
        );
    return copyWith(
      roomStatus: nextRoomStatus,
      roomMode: nextRoomMode,
      playbackPhase: event.playbackPhase,
      roomVersion: event.roomVersion,
      latestEventId: event.eventCursor ?? latestEventId,
      playbackVersion: event.playbackVersion ?? playbackVersion,
      playbackApplyId: event.playbackApplyId ?? playbackApplyId,
      presenceVersion: event.presenceVersion,
      authVersion: event.authVersion,
      hostMemberId: nextHostMemberId,
      self: nextSelf,
      members: updatedMembers,
      queue: event.queue,
      playbackAnchor: event.playbackAnchor,
      clearPlaybackAnchor: event.playbackAnchorCleared,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupListeningRoomState &&
          runtimeType == other.runtimeType &&
          protocolVersion == other.protocolVersion &&
          roomId == other.roomId &&
          roomStatus == other.roomStatus &&
          roomMode == other.roomMode &&
          playbackPhase == other.playbackPhase &&
          requiresPin == other.requiresPin &&
          roomVersion == other.roomVersion &&
          latestEventId == other.latestEventId &&
          playbackVersion == other.playbackVersion &&
          playbackApplyId == other.playbackApplyId &&
          playbackEpoch == other.playbackEpoch &&
          presenceVersion == other.presenceVersion &&
          authVersion == other.authVersion &&
          serverTime == other.serverTime &&
          sourceServerFingerprint == other.sourceServerFingerprint &&
          hostMemberId == other.hostMemberId &&
          self == other.self &&
          listEquals(members, other.members) &&
          queue == other.queue &&
          playbackAnchor == other.playbackAnchor;

  @override
  int get hashCode => Object.hash(
    protocolVersion,
    roomId,
    roomStatus,
    roomMode,
    playbackPhase,
    requiresPin,
    roomVersion,
    latestEventId,
    playbackVersion,
    playbackApplyId,
    playbackEpoch,
    presenceVersion,
    authVersion,
    serverTime,
    sourceServerFingerprint,
    hostMemberId,
    self,
    Object.hashAll(members),
    queue,
    playbackAnchor,
  );

  static List<GroupListeningMemberState> _mergeMembers({
    required List<GroupListeningMemberState> existing,
    required List<GroupListeningMemberState> updates,
    required List<String> removedMemberIds,
  }) {
    final byId = <String, GroupListeningMemberState>{
      for (final member in existing) member.memberId: member,
    };
    for (final member in updates) {
      byId[member.memberId] = member;
    }
    for (final memberId in removedMemberIds) {
      byId.remove(memberId);
    }
    final merged = byId.values.toList(growable: false)
      ..sort((a, b) => a.joinedAt.compareTo(b.joinedAt));
    return merged;
  }
}
