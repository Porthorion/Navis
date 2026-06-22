import 'package:flutter/foundation.dart';

import 'group_listening_protocol_constants.dart';
import 'group_listening_room_models.dart';

enum GroupListeningSyncHealth { synced, catchingUp, snapshotRecovery, degraded }

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
  playbackRewindRejected,
  stalePlaybackEpoch,
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
    this.syncHealth = GroupListeningSyncHealth.synced,
    this.localPlaybackEpoch = 0,
    this.catchUpAligned = true,
    this.hasStoredSession = false,
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
      failure = null,
      syncHealth = GroupListeningSyncHealth.synced,
      localPlaybackEpoch = 0,
      catchUpAligned = true,
      hasStoredSession = false;

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
  final GroupListeningSyncHealth syncHealth;
  final int localPlaybackEpoch;
  final bool catchUpAligned;
  final bool hasStoredSession;

  bool get hasActiveRoom => room != null;

  int get serverPlaybackEpoch => room?.playbackEpoch ?? 0;

  bool get isCatchUpActive =>
      localPlaybackEpoch < serverPlaybackEpoch || !catchUpAligned;

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
    GroupListeningSyncHealth? syncHealth,
    int? localPlaybackEpoch,
    bool? catchUpAligned,
    bool? hasStoredSession,
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
      syncHealth: syncHealth ?? this.syncHealth,
      localPlaybackEpoch: localPlaybackEpoch ?? this.localPlaybackEpoch,
      catchUpAligned: catchUpAligned ?? this.catchUpAligned,
      hasStoredSession: hasStoredSession ?? this.hasStoredSession,
    );
  }

  static GroupListeningSyncHealth resolveSyncHealth({
    required bool snapshotRequired,
    required bool catchUpActive,
    required bool connectionConnected,
    GroupListeningErrorState? failure,
  }) {
    if (snapshotRequired) {
      return GroupListeningSyncHealth.snapshotRecovery;
    }
    if (catchUpActive) {
      return GroupListeningSyncHealth.catchingUp;
    }
    if (!connectionConnected || failure != null) {
      return GroupListeningSyncHealth.degraded;
    }
    return GroupListeningSyncHealth.synced;
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
          failure == other.failure &&
          syncHealth == other.syncHealth &&
          localPlaybackEpoch == other.localPlaybackEpoch &&
          catchUpAligned == other.catchUpAligned &&
          hasStoredSession == other.hasStoredSession;

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
    syncHealth,
    localPlaybackEpoch,
    catchUpAligned,
    hasStoredSession,
  );
}
