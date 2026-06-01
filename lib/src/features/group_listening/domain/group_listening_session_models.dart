import 'package:flutter/foundation.dart';

const String voyageProtocolVersion = 'voyage-sync.v2alpha1';
const String voyageReplayResumeCapability = 'replay_resume';
const String voyageQueueEntryMetadataCapability = 'queue_entry_metadata';

enum GroupListeningAvailability { disabled, unconfigured, ready }

enum GroupListeningSessionStatus {
  idle,
  joining,
  connecting,
  connected,
  reconnecting,
  disconnecting,
  leaving,
  error,
}

enum GroupListeningConnectionStatus {
  disconnected,
  connecting,
  connected,
  reconnecting,
}

enum GroupListeningMemberRole { host, member }

enum GroupListeningMemberPresenceState { active, stale, offline }

enum GroupListeningRoomStatus { active, closed }

enum GroupListeningRoomMode { collaborative, shotgun, hostOnly }

enum GroupListeningPlaybackStatus { playing, paused }

enum GroupListeningPlaybackAnchorReason {
  play,
  pause,
  seek,
  trackChange,
  syncTick,
  snapshot,
}

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
  syncTick,
}

enum GroupListeningErrorCode {
  unsupportedProtocolVersion,
  unauthorized,
  forbidden,
  roomNotFound,
  roomClosed,
  inviteInvalid,
  inviteExpired,
  pinRequired,
  pinInvalid,
  fingerprintMismatch,
  staleVersion,
  sequenceRejected,
  duplicateMutation,
  snapshotRequired,
  removed,
  revoked,
  rateLimited,
  payloadTooLarge,
  validationFailed,
  configurationMissing,
  insecureTransport,
  sessionUnavailable,
  transportUnavailable,
  transportDisconnected,
  internalError,
  unknown,
}

@immutable
class GroupListeningClientConfiguration {
  const GroupListeningClientConfiguration({
    required this.voyageBaseUrl,
    required this.sourceServerOrigin,
    required this.sourceServerFingerprint,
    required this.displayName,
    this.deviceLabel,
    required this.autoFollowHost,
    this.allowInsecureTransport = false,
    this.protocolVersion = voyageProtocolVersion,
  });

  final Uri voyageBaseUrl;
  final String sourceServerOrigin;
  final String sourceServerFingerprint;
  final String displayName;
  final String? deviceLabel;
  final bool autoFollowHost;
  final bool allowInsecureTransport;
  final String protocolVersion;

  bool get usesSecureTransport => voyageBaseUrl.scheme == 'https';

  bool isTransportCompatibleWith(GroupListeningClientConfiguration other) {
    return voyageBaseUrl == other.voyageBaseUrl &&
        sourceServerFingerprint == other.sourceServerFingerprint;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupListeningClientConfiguration &&
          runtimeType == other.runtimeType &&
          voyageBaseUrl == other.voyageBaseUrl &&
          sourceServerOrigin == other.sourceServerOrigin &&
          sourceServerFingerprint == other.sourceServerFingerprint &&
          displayName == other.displayName &&
          deviceLabel == other.deviceLabel &&
          autoFollowHost == other.autoFollowHost &&
          allowInsecureTransport == other.allowInsecureTransport &&
          protocolVersion == other.protocolVersion;

  @override
  int get hashCode => Object.hash(
    voyageBaseUrl,
    sourceServerOrigin,
    sourceServerFingerprint,
    displayName,
    deviceLabel,
    autoFollowHost,
    allowInsecureTransport,
    protocolVersion,
  );
}

@immutable
class GroupListeningErrorState {
  const GroupListeningErrorState({
    required this.code,
    required this.message,
    this.retryable = false,
    this.details = const <String, Object?>{},
    this.roomVersion,
    this.retryAfter,
  });

  final GroupListeningErrorCode code;
  final String message;
  final bool retryable;
  final Map<String, Object?> details;
  final int? roomVersion;
  final Duration? retryAfter;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupListeningErrorState &&
          runtimeType == other.runtimeType &&
          code == other.code &&
          message == other.message &&
          retryable == other.retryable &&
          mapEquals(details, other.details) &&
          roomVersion == other.roomVersion &&
          retryAfter == other.retryAfter;

  @override
  int get hashCode => Object.hash(
    code,
    message,
    retryable,
    Object.hashAll(
      details.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
    roomVersion,
    retryAfter,
  );
}

@immutable
class GroupListeningConnectionState {
  const GroupListeningConnectionState({
    required this.status,
    this.clientConnectionId,
    this.heartbeatInterval,
    this.memberStaleTimeout,
    this.connectedAt,
    this.lastServerTime,
    this.lastHeartbeatAckAt,
    this.connectedServerUrl,
    this.connectedServerVersion,
    this.reconnectAttempt = 0,
    this.lastDisconnectReason,
    this.serverClockOffset = Duration.zero,
    this.lastRoundTripTime,
  });

  const GroupListeningConnectionState.disconnected()
    : status = GroupListeningConnectionStatus.disconnected,
      clientConnectionId = null,
      heartbeatInterval = null,
      memberStaleTimeout = null,
      connectedAt = null,
      lastServerTime = null,
      lastHeartbeatAckAt = null,
      connectedServerUrl = null,
      connectedServerVersion = null,
      reconnectAttempt = 0,
      lastDisconnectReason = null,
      serverClockOffset = Duration.zero,
      lastRoundTripTime = null;

  final GroupListeningConnectionStatus status;
  final String? clientConnectionId;
  final Duration? heartbeatInterval;
  final Duration? memberStaleTimeout;
  final DateTime? connectedAt;
  final DateTime? lastServerTime;
  final DateTime? lastHeartbeatAckAt;
  final Uri? connectedServerUrl;
  final String? connectedServerVersion;
  final int reconnectAttempt;
  final GroupListeningErrorState? lastDisconnectReason;
  final Duration serverClockOffset;
  final Duration? lastRoundTripTime;

  bool get isConnected => status == GroupListeningConnectionStatus.connected;

  GroupListeningConnectionState copyWith({
    GroupListeningConnectionStatus? status,
    String? clientConnectionId,
    Duration? heartbeatInterval,
    Duration? memberStaleTimeout,
    DateTime? connectedAt,
    DateTime? lastServerTime,
    DateTime? lastHeartbeatAckAt,
    Uri? connectedServerUrl,
    String? connectedServerVersion,
    int? reconnectAttempt,
    GroupListeningErrorState? lastDisconnectReason,
    Duration? serverClockOffset,
    Duration? lastRoundTripTime,
    bool clearClientConnectionId = false,
    bool clearConnectedServer = false,
    bool clearDisconnectReason = false,
    bool clearLastRoundTripTime = false,
  }) {
    return GroupListeningConnectionState(
      status: status ?? this.status,
      clientConnectionId: clearClientConnectionId
          ? null
          : clientConnectionId ?? this.clientConnectionId,
      heartbeatInterval: heartbeatInterval ?? this.heartbeatInterval,
      memberStaleTimeout: memberStaleTimeout ?? this.memberStaleTimeout,
      connectedAt: connectedAt ?? this.connectedAt,
      lastServerTime: lastServerTime ?? this.lastServerTime,
      lastHeartbeatAckAt: lastHeartbeatAckAt ?? this.lastHeartbeatAckAt,
      connectedServerUrl: clearConnectedServer
          ? null
          : connectedServerUrl ?? this.connectedServerUrl,
      connectedServerVersion: clearConnectedServer
          ? null
          : connectedServerVersion ?? this.connectedServerVersion,
      reconnectAttempt: reconnectAttempt ?? this.reconnectAttempt,
      lastDisconnectReason: clearDisconnectReason
          ? null
          : lastDisconnectReason ?? this.lastDisconnectReason,
      serverClockOffset: serverClockOffset ?? this.serverClockOffset,
      lastRoundTripTime: clearLastRoundTripTime
          ? null
          : lastRoundTripTime ?? this.lastRoundTripTime,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupListeningConnectionState &&
          runtimeType == other.runtimeType &&
          status == other.status &&
          clientConnectionId == other.clientConnectionId &&
          heartbeatInterval == other.heartbeatInterval &&
          memberStaleTimeout == other.memberStaleTimeout &&
          connectedAt == other.connectedAt &&
          lastServerTime == other.lastServerTime &&
          lastHeartbeatAckAt == other.lastHeartbeatAckAt &&
          connectedServerUrl == other.connectedServerUrl &&
          connectedServerVersion == other.connectedServerVersion &&
          reconnectAttempt == other.reconnectAttempt &&
          lastDisconnectReason == other.lastDisconnectReason &&
          serverClockOffset == other.serverClockOffset &&
          lastRoundTripTime == other.lastRoundTripTime;

  @override
  int get hashCode => Object.hash(
    status,
    clientConnectionId,
    heartbeatInterval,
    memberStaleTimeout,
    connectedAt,
    lastServerTime,
    lastHeartbeatAckAt,
    connectedServerUrl,
    connectedServerVersion,
    reconnectAttempt,
    lastDisconnectReason,
    serverClockOffset,
    lastRoundTripTime,
  );
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
class GroupListeningQueueEntry {
  const GroupListeningQueueEntry({
    required this.queueEntryId,
    required this.songId,
    this.addedByMemberId,
    required this.addedAt,
    this.title,
    this.artist,
    this.artistId,
    this.album,
    this.albumId,
    this.durationSeconds,
    this.track,
    this.discNumber,
    this.year,
    this.coverArt,
    this.contentType,
    this.suffix,
    this.bitRate,
    this.sampleRate,
    this.size,
    this.replayGainTrackGain,
    this.replayGainAlbumGain,
    this.replayGainTrackPeak,
    this.replayGainAlbumPeak,
  });

  final String queueEntryId;
  final String songId;
  final String? addedByMemberId;
  final DateTime addedAt;
  final String? title;
  final String? artist;
  final String? artistId;
  final String? album;
  final String? albumId;
  final int? durationSeconds;
  final int? track;
  final int? discNumber;
  final int? year;
  final String? coverArt;
  final String? contentType;
  final String? suffix;
  final int? bitRate;
  final int? sampleRate;
  final int? size;
  final double? replayGainTrackGain;
  final double? replayGainAlbumGain;
  final double? replayGainTrackPeak;
  final double? replayGainAlbumPeak;

  bool get hasMetadata =>
      title != null ||
      artist != null ||
      artistId != null ||
      album != null ||
      albumId != null ||
      durationSeconds != null ||
      track != null ||
      discNumber != null ||
      year != null ||
      coverArt != null ||
      contentType != null ||
      suffix != null ||
      bitRate != null ||
      sampleRate != null ||
      size != null ||
      replayGainTrackGain != null ||
      replayGainAlbumGain != null ||
      replayGainTrackPeak != null ||
      replayGainAlbumPeak != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupListeningQueueEntry &&
          runtimeType == other.runtimeType &&
          queueEntryId == other.queueEntryId &&
          songId == other.songId &&
          addedByMemberId == other.addedByMemberId &&
          addedAt == other.addedAt &&
          title == other.title &&
          artist == other.artist &&
          artistId == other.artistId &&
          album == other.album &&
          albumId == other.albumId &&
          durationSeconds == other.durationSeconds &&
          track == other.track &&
          discNumber == other.discNumber &&
          year == other.year &&
          coverArt == other.coverArt &&
          contentType == other.contentType &&
          suffix == other.suffix &&
          bitRate == other.bitRate &&
          sampleRate == other.sampleRate &&
          size == other.size &&
          replayGainTrackGain == other.replayGainTrackGain &&
          replayGainAlbumGain == other.replayGainAlbumGain &&
          replayGainTrackPeak == other.replayGainTrackPeak &&
          replayGainAlbumPeak == other.replayGainAlbumPeak;

  @override
  int get hashCode => Object.hashAll(<Object?>[
    queueEntryId,
    songId,
    addedByMemberId,
    addedAt,
    title,
    artist,
    artistId,
    album,
    albumId,
    durationSeconds,
    track,
    discNumber,
    year,
    coverArt,
    contentType,
    suffix,
    bitRate,
    sampleRate,
    size,
    replayGainTrackGain,
    replayGainAlbumGain,
    replayGainTrackPeak,
    replayGainAlbumPeak,
  ]);
}

@immutable
class GroupListeningQueueState {
  const GroupListeningQueueState({
    required this.queueVersion,
    this.currentIndex,
    this.entries = const <GroupListeningQueueEntry>[],
  });

  final int queueVersion;
  final int? currentIndex;
  final List<GroupListeningQueueEntry> entries;

  GroupListeningQueueEntry? get currentEntry {
    final index = currentIndex;
    if (index == null || index < 0 || index >= entries.length) {
      return null;
    }
    return entries[index];
  }

  String? get currentSongId => currentEntry?.songId;

  GroupListeningQueueState copyWith({
    int? queueVersion,
    int? currentIndex,
    List<GroupListeningQueueEntry>? entries,
  }) {
    return GroupListeningQueueState(
      queueVersion: queueVersion ?? this.queueVersion,
      currentIndex: currentIndex ?? this.currentIndex,
      entries: entries ?? this.entries,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupListeningQueueState &&
          runtimeType == other.runtimeType &&
          queueVersion == other.queueVersion &&
          currentIndex == other.currentIndex &&
          listEquals(entries, other.entries);

  @override
  int get hashCode =>
      Object.hash(queueVersion, currentIndex, Object.hashAll(entries));
}

@immutable
class GroupListeningPlaybackAnchor {
  const GroupListeningPlaybackAnchor({
    required this.roomVersion,
    required this.queueVersion,
    required this.currentIndex,
    required this.currentQueueEntryId,
    required this.currentSongId,
    required this.playbackState,
    required this.position,
    required this.capturedAt,
    required this.playbackRate,
    required this.reason,
    this.playbackApplyId,
    this.issuedByMemberId,
    this.issuedByConnectionId,
  });

  final int roomVersion;
  final int queueVersion;
  final int? playbackApplyId;
  final int? currentIndex;
  final String? currentQueueEntryId;
  final String? currentSongId;
  final GroupListeningPlaybackStatus playbackState;
  final Duration position;
  final DateTime capturedAt;
  final double playbackRate;
  final GroupListeningPlaybackAnchorReason reason;
  final String? issuedByMemberId;
  final String? issuedByConnectionId;

  Duration expectedPositionAt(DateTime now) {
    if (playbackState == GroupListeningPlaybackStatus.paused) {
      return position;
    }
    final elapsed = now.difference(capturedAt);
    final projectedMs =
        position.inMilliseconds + (elapsed.inMilliseconds * playbackRate);
    return Duration(milliseconds: projectedMs.round().clamp(0, 1 << 31));
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupListeningPlaybackAnchor &&
          runtimeType == other.runtimeType &&
          roomVersion == other.roomVersion &&
          queueVersion == other.queueVersion &&
          playbackApplyId == other.playbackApplyId &&
          currentIndex == other.currentIndex &&
          currentQueueEntryId == other.currentQueueEntryId &&
          currentSongId == other.currentSongId &&
          playbackState == other.playbackState &&
          position == other.position &&
          capturedAt == other.capturedAt &&
          playbackRate == other.playbackRate &&
          reason == other.reason &&
          issuedByMemberId == other.issuedByMemberId &&
          issuedByConnectionId == other.issuedByConnectionId;

  @override
  int get hashCode => Object.hash(
    roomVersion,
    queueVersion,
    playbackApplyId,
    currentIndex,
    currentQueueEntryId,
    currentSongId,
    playbackState,
    position,
    capturedAt,
    playbackRate,
    reason,
    issuedByMemberId,
    issuedByConnectionId,
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
    this.requiresPin = false,
    required this.roomVersion,
    this.latestEventId = 0,
    this.playbackVersion = 0,
    this.playbackApplyId = 0,
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
  final bool requiresPin;
  final int roomVersion;
  final int latestEventId;
  final int playbackVersion;
  final int playbackApplyId;
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
    bool? requiresPin,
    int? roomVersion,
    int? latestEventId,
    int? playbackVersion,
    int? playbackApplyId,
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
      requiresPin: requiresPin ?? this.requiresPin,
      roomVersion: roomVersion ?? this.roomVersion,
      latestEventId: latestEventId ?? this.latestEventId,
      playbackVersion: playbackVersion ?? this.playbackVersion,
      playbackApplyId: playbackApplyId ?? this.playbackApplyId,
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
    final nextSelf =
        explicitSelf ??
        self.copyWith(
          role: nextSelfRole,
          canControl:
              nextRoomStatus == GroupListeningRoomStatus.active &&
              (roomMode != GroupListeningRoomMode.hostOnly ||
                  nextSelfRole == GroupListeningMemberRole.host),
          canPlayAudio:
              nextRoomStatus == GroupListeningRoomStatus.active &&
              (roomMode != GroupListeningRoomMode.shotgun ||
                  nextSelfRole == GroupListeningMemberRole.host),
          authVersion: event.authVersion,
        );
    return copyWith(
      roomStatus: nextRoomStatus,
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
          requiresPin == other.requiresPin &&
          roomVersion == other.roomVersion &&
          latestEventId == other.latestEventId &&
          playbackVersion == other.playbackVersion &&
          playbackApplyId == other.playbackApplyId &&
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
    requiresPin,
    roomVersion,
    latestEventId,
    playbackVersion,
    playbackApplyId,
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

@immutable
class GroupListeningSessionState {
  const GroupListeningSessionState({
    required this.availability,
    required this.status,
    required this.connection,
    this.configuration,
    this.room,
    this.lastAppliedRoomVersion = 0,
    this.lastAppliedEventId = 0,
    this.snapshotRequired = false,
    this.lastSnapshotAt,
    this.activeInviteCode,
    this.failure,
  });

  const GroupListeningSessionState.disabled()
    : availability = GroupListeningAvailability.disabled,
      status = GroupListeningSessionStatus.idle,
      connection = const GroupListeningConnectionState.disconnected(),
      configuration = null,
      room = null,
      lastAppliedRoomVersion = 0,
      lastAppliedEventId = 0,
      snapshotRequired = false,
      lastSnapshotAt = null,
      activeInviteCode = null,
      failure = null;

  final GroupListeningAvailability availability;
  final GroupListeningSessionStatus status;
  final GroupListeningConnectionState connection;
  final GroupListeningClientConfiguration? configuration;
  final GroupListeningRoomState? room;
  final int lastAppliedRoomVersion;
  final int lastAppliedEventId;
  final bool snapshotRequired;
  final DateTime? lastSnapshotAt;
  final String? activeInviteCode;
  final GroupListeningErrorState? failure;

  bool get hasActiveRoom => room != null;

  bool get canSendRoomMutations =>
      availability == GroupListeningAvailability.ready &&
      connection.isConnected &&
      !snapshotRequired &&
      (room?.self.canControl ?? false);

  GroupListeningSessionState copyWith({
    GroupListeningAvailability? availability,
    GroupListeningSessionStatus? status,
    GroupListeningConnectionState? connection,
    GroupListeningClientConfiguration? configuration,
    GroupListeningRoomState? room,
    int? lastAppliedRoomVersion,
    int? lastAppliedEventId,
    bool? snapshotRequired,
    DateTime? lastSnapshotAt,
    GroupListeningErrorState? failure,
    bool clearFailure = false,
    bool clearRoom = false,
    bool clearConfiguration = false,
    String? activeInviteCode,
    bool clearActiveInviteCode = false,
  }) {
    return GroupListeningSessionState(
      availability: availability ?? this.availability,
      status: status ?? this.status,
      connection: connection ?? this.connection,
      configuration: clearConfiguration
          ? null
          : configuration ?? this.configuration,
      room: clearRoom ? null : room ?? this.room,
      lastAppliedRoomVersion:
          lastAppliedRoomVersion ?? this.lastAppliedRoomVersion,
      lastAppliedEventId: lastAppliedEventId ?? this.lastAppliedEventId,
      snapshotRequired: snapshotRequired ?? this.snapshotRequired,
      lastSnapshotAt: lastSnapshotAt ?? this.lastSnapshotAt,
      activeInviteCode: clearRoom || clearActiveInviteCode
          ? null
          : activeInviteCode ?? this.activeInviteCode,
      failure: clearFailure ? null : failure ?? this.failure,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupListeningSessionState &&
          runtimeType == other.runtimeType &&
          availability == other.availability &&
          status == other.status &&
          connection == other.connection &&
          configuration == other.configuration &&
          room == other.room &&
          lastAppliedRoomVersion == other.lastAppliedRoomVersion &&
          lastAppliedEventId == other.lastAppliedEventId &&
          snapshotRequired == other.snapshotRequired &&
          lastSnapshotAt == other.lastSnapshotAt &&
          activeInviteCode == other.activeInviteCode &&
          failure == other.failure;

  @override
  int get hashCode => Object.hash(
    availability,
    status,
    connection,
    configuration,
    room,
    lastAppliedRoomVersion,
    lastAppliedEventId,
    snapshotRequired,
    lastSnapshotAt,
    activeInviteCode,
    failure,
  );
}
