import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/utils/app_logger.dart';

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

  bool get supportsCurrentProtocol =>
      latestProtocolVersion == voyageProtocolVersion &&
      supportedProtocolVersions.contains(voyageProtocolVersion);
}

@immutable
class GroupListeningAvailableRoomSummary {
  const GroupListeningAvailableRoomSummary({
    required this.roomId,
    required this.hostDisplayName,
    required this.membersTotal,
    required this.activeMembers,
    required this.queueLength,
    required this.roomVersion,
    required this.lastActivityAt,
  });

  final String roomId;
  final String hostDisplayName;
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
    Uri? voyageBaseUrl,
    int? authVersion,
    String? rejoinToken,
    int? lastAppliedRoomVersion,
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

class FlutterSecureGroupListeningSessionCredentialStore
    implements GroupListeningSessionCredentialStore {
  const FlutterSecureGroupListeningSessionCredentialStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  static const _sessionKey = 'navis.group_listening.active_session';
  static GroupListeningStoredSession? _sessionFallback;
  static bool _didLogSaveFallbackWarning = false;
  static bool _didLogReadFallbackWarning = false;
  static bool _didLogClearFallbackWarning = false;

  final FlutterSecureStorage _storage;

  @override
  Future<void> clear() async {
    _sessionFallback = null;
    try {
      await _storage.delete(key: _sessionKey);
    } on Object catch (error) {
      if (!_didLogClearFallbackWarning) {
        _didLogClearFallbackWarning = true;
        AppLogger.warning(
          'Group listening secure session clear failed: $error',
        );
      }
    }
  }

  @override
  Future<GroupListeningStoredSession?> read() async {
    try {
      final rawValue = await _storage.read(key: _sessionKey);
      if (rawValue == null || rawValue.trim().isEmpty) {
        return _sessionFallback;
      }
      final decoded = jsonDecode(rawValue);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
          'Stored session payload must be an object.',
        );
      }
      final session = _storedSessionFromJson(decoded);
      _sessionFallback = session;
      return session;
    } on Object catch (error) {
      if (!_didLogReadFallbackWarning) {
        _didLogReadFallbackWarning = true;
        AppLogger.warning(
          'Group listening secure session read failed; using session fallback: '
          '$error',
        );
      }
      return _sessionFallback;
    }
  }

  @override
  Future<void> save(GroupListeningStoredSession session) async {
    _sessionFallback = session;
    final encoded = jsonEncode(_storedSessionToJson(session));
    try {
      await _storage.write(key: _sessionKey, value: encoded);
    } on Object catch (error) {
      if (!_didLogSaveFallbackWarning) {
        _didLogSaveFallbackWarning = true;
        AppLogger.warning(
          'Group listening secure session save failed; using session fallback: '
          '$error',
        );
      }
    }
  }
}

class VoyageGroupListeningHttpClient implements GroupListeningHttpClient {
  VoyageGroupListeningHttpClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(seconds: 10),
              headers: const <String, Object?>{
                HttpHeaders.acceptHeader: 'application/json',
                HttpHeaders.userAgentHeader: 'Navis Group Listening',
              },
            ),
          );

  final Dio _dio;

  @override
  Future<GroupListeningJoinResponse> createRoom(
    GroupListeningCreateRoomRequest request,
  ) async {
    final data = await _sendJson(
      method: 'POST',
      uri: _voyagePathUri(request.configuration.voyageBaseUrl, <String>[
        'api',
        'v1',
        'rooms',
      ]),
      body: <String, Object?>{
        'protocol_version': voyageProtocolVersion,
        'client': _clientPayload(request.client),
        'member': <String, Object?>{
          'display_name': request.configuration.displayName,
        },
        'source_server_fingerprint':
            request.configuration.sourceServerFingerprint,
        if (request.roomSeed != null)
          'room_seed': _roomSeedPayload(request.roomSeed!),
      },
      fallbackMessage: 'Unable to create Voyage room.',
      fallbackCode: GroupListeningErrorCode.transportUnavailable,
    );
    return _joinResponseFromData(
      data,
      voyageBaseUrl: request.configuration.voyageBaseUrl,
    );
  }

  @override
  Future<GroupListeningCapabilityDiscovery> discover(
    GroupListeningClientConfiguration configuration,
  ) async {
    final data = await _sendJson(
      method: 'GET',
      uri: _voyagePathUri(configuration.voyageBaseUrl, <String>[
        'api',
        'v1',
        'health',
      ]),
      fallbackMessage: 'Unable to discover Voyage capabilities.',
      fallbackCode: GroupListeningErrorCode.transportUnavailable,
    );
    final discovery = GroupListeningCapabilityDiscovery(
      service: _stringValue(data['service']),
      apiVersion: _stringValue(data['api_version']),
      serverVersion:
          _nullableStringValue(data['server_version']) ?? '0.0.0-dev',
      buildCommit: _nullableStringValue(data['build_commit']) ?? 'unknown',
      buildTime: _nullableStringValue(data['build_time']) ?? 'unknown',
      supportedProtocolVersions: _stringListValue(
        data['supported_protocol_versions'],
      ),
      latestProtocolVersion: _stringValue(data['latest_protocol_version']),
      websocketPath: _stringValue(data['websocket_path']),
      heartbeatInterval: Duration(
        milliseconds: _intValue(data['heartbeat_interval_ms']),
      ),
      memberStaleTimeout: Duration(
        milliseconds: _intValue(data['member_stale_timeout_ms']),
      ),
    );
    _ensureDiscoverySupportsCurrentProtocol(discovery);
    return discovery;
  }

  @override
  Future<List<GroupListeningAvailableRoomSummary>> listAvailableRooms(
    GroupListeningClientConfiguration configuration,
  ) async {
    final data = await _sendJson(
      method: 'GET',
      uri: _voyagePathUri(configuration.voyageBaseUrl, <String>[
        'api',
        'v1',
        'rooms',
      ]),
      includeProtocolHeader: true,
      sourceServerFingerprint: configuration.sourceServerFingerprint,
      fallbackMessage: 'Unable to load available Voyage rooms.',
      fallbackCode: GroupListeningErrorCode.transportUnavailable,
    );
    return _availableRoomsFromData(data);
  }

  @override
  Future<GroupListeningRoomState> fetchSnapshot(
    GroupListeningSessionRuntimeContext session, {
    int? lastAppliedRoomVersion,
  }) async {
    final data = await _sendJson(
      method: 'GET',
      uri: _voyagePathUri(session.voyageBaseUrl, <String>[
        'api',
        'v1',
        'rooms',
        session.roomId,
        'snapshot',
      ]),
      accessToken: session.accessToken,
      includeProtocolHeader: true,
      fallbackMessage: 'Unable to refresh Voyage room snapshot.',
      fallbackCode: GroupListeningErrorCode.transportUnavailable,
    );
    return _roomStateFromJson(
      _mapValue(data['room_snapshot']),
      fallbackSelfMemberId: session.memberId,
      fallbackSelfRole: session.role,
      fallbackSelfAuthVersion: session.authVersion,
    );
  }

  @override
  Future<GroupListeningJoinResponse> joinAvailableRoom({
    required String roomId,
    required GroupListeningClientConfiguration configuration,
    required GroupListeningClientDescriptor client,
  }) async {
    final data = await _sendJson(
      method: 'POST',
      uri: _voyagePathUri(configuration.voyageBaseUrl, <String>[
        'api',
        'v1',
        'rooms',
        roomId,
        'join',
      ]),
      body: <String, Object?>{
        'protocol_version': voyageProtocolVersion,
        'client': _clientPayload(client),
        'member': <String, Object?>{
          'display_name': configuration.displayName,
        },
        'source_server_fingerprint': configuration.sourceServerFingerprint,
      },
      fallbackMessage: 'Unable to join available Voyage room.',
      fallbackCode: GroupListeningErrorCode.transportUnavailable,
    );
    return _joinResponseFromData(
      data,
      voyageBaseUrl: configuration.voyageBaseUrl,
    );
  }

  @override
  Future<GroupListeningJoinResponse> joinRoom(
    GroupListeningJoinRoomRequest request,
  ) async {
    final data = await _sendJson(
      method: 'POST',
      uri: _voyagePathUri(request.configuration.voyageBaseUrl, <String>[
        'api',
        'v1',
        'rooms',
        'join',
      ]),
      body: <String, Object?>{
        'protocol_version': voyageProtocolVersion,
        'invite_code': request.inviteCode,
        'client': _clientPayload(request.client),
        'member': <String, Object?>{
          'display_name': request.configuration.displayName,
        },
        'source_server_fingerprint':
            request.configuration.sourceServerFingerprint,
      },
      fallbackMessage: 'Unable to join Voyage room.',
      fallbackCode: GroupListeningErrorCode.transportUnavailable,
    );
    return _joinResponseFromData(
      data,
      voyageBaseUrl: request.configuration.voyageBaseUrl,
    );
  }

  @override
  Future<GroupListeningLeaveResponse> leaveRoom(
    GroupListeningSessionRuntimeContext session, {
    int? lastAppliedRoomVersion,
  }) async {
    final data = await _sendJson(
      method: 'POST',
      uri: _voyagePathUri(session.voyageBaseUrl, <String>[
        'api',
        'v1',
        'rooms',
        session.roomId,
        'leave',
      ]),
      accessToken: session.accessToken,
      includeProtocolHeader: true,
      body: <String, Object?>{
        if (lastAppliedRoomVersion != null)
          'last_applied_room_version': lastAppliedRoomVersion,
      },
      fallbackMessage: 'Unable to leave Voyage room cleanly.',
      fallbackCode: GroupListeningErrorCode.transportUnavailable,
    );
    return GroupListeningLeaveResponse(
      roomId: _stringValue(data['room_id']),
      leftMemberId: _stringValue(data['left_member_id']),
      roomStatus: _roomStatusFromWire(data['room_status']),
      roomVersion: _intValue(data['room_version']),
    );
  }

  @override
  Future<GroupListeningCloseRoomResponse> closeRoom(
    GroupListeningSessionRuntimeContext session, {
    int? expectedRoomVersion,
  }) async {
    final data = await _sendJson(
      method: 'POST',
      uri: _voyagePathUri(session.voyageBaseUrl, <String>[
        'api',
        'v1',
        'rooms',
        session.roomId,
        'close',
      ]),
      accessToken: session.accessToken,
      includeProtocolHeader: true,
      body: <String, Object?>{
        if (expectedRoomVersion != null)
          'expected_room_version': expectedRoomVersion,
      },
      fallbackMessage: 'Unable to close Voyage room.',
      fallbackCode: GroupListeningErrorCode.transportUnavailable,
    );
    return GroupListeningCloseRoomResponse(
      roomId: _stringValue(data['room_id']),
      roomStatus: _roomStatusFromWire(data['room_status']),
      roomVersion: _intValue(data['room_version']),
      closedAt: _dateTimeFromEpochMs(data['closed_at_ms']),
    );
  }

  @override
  Future<GroupListeningRotateInviteResponse> rotateInvite(
    GroupListeningSessionRuntimeContext session, {
    int? expectedRoomVersion,
  }) async {
    final data = await _sendJson(
      method: 'POST',
      uri: _voyagePathUri(session.voyageBaseUrl, <String>[
        'api',
        'v1',
        'rooms',
        session.roomId,
        'rotate-invite',
      ]),
      accessToken: session.accessToken,
      includeProtocolHeader: true,
      body: <String, Object?>{
        if (expectedRoomVersion != null)
          'expected_room_version': expectedRoomVersion,
      },
      fallbackMessage: 'Unable to rotate Voyage invite.',
      fallbackCode: GroupListeningErrorCode.transportUnavailable,
    );
    return GroupListeningRotateInviteResponse(
      roomId: _stringValue(data['room_id']),
      roomVersion: _intValue(data['room_version']),
      inviteCode: _stringValue(data['invite_code']),
    );
  }

  @override
  Future<GroupListeningJoinResponse> rejoinRoom(
    GroupListeningRejoinRoomRequest request,
  ) async {
    final data = await _sendJson(
      method: 'POST',
      uri: _voyagePathUri(
        request.configuration.voyageBaseUrl,
        <String>[
          'api',
          'v1',
          'rooms',
          request.session.roomId,
          'rejoin',
        ],
      ),
      body: <String, Object?>{
        'protocol_version': voyageProtocolVersion,
        'rejoin_token': request.session.rejoinToken,
        'client': _clientPayload(request.session.client),
        'source_server_fingerprint':
            request.configuration.sourceServerFingerprint,
        if (request.session.lastAppliedRoomVersion > 0)
          'last_applied_room_version': request.session.lastAppliedRoomVersion,
      },
      fallbackMessage: 'Unable to rejoin Voyage room.',
      fallbackCode: GroupListeningErrorCode.transportUnavailable,
    );
    return _joinResponseFromData(
      data,
      voyageBaseUrl: request.configuration.voyageBaseUrl,
    );
  }

  Future<Map<String, dynamic>> _sendJson({
    required String method,
    required Uri uri,
    required String fallbackMessage,
    required GroupListeningErrorCode fallbackCode,
    Map<String, Object?>? body,
    String? accessToken,
    bool includeProtocolHeader = false,
    String? sourceServerFingerprint,
  }) async {
    Response<Object?> response;
    try {
      response = await _dio.requestUri<Object?>(
        uri,
        data: body,
        options: Options(
          method: method,
          validateStatus: (_) => true,
          headers: <String, Object?>{
            if (includeProtocolHeader)
              'X-Voyage-Protocol-Version': voyageProtocolVersion,
            if (sourceServerFingerprint != null)
              'X-Voyage-Source-Server-Fingerprint': sourceServerFingerprint,
            if (accessToken != null)
              HttpHeaders.authorizationHeader: 'Bearer $accessToken',
          },
        ),
      );
    } on DioException catch (error) {
      throw _failureFromDio(
        error,
        fallbackMessage: fallbackMessage,
        fallbackCode: fallbackCode,
      );
    }

    final payload = _mapValue(_decodeJsonBody(response.data));
    _validateEnvelopeProtocolVersion(payload);
    final statusCode = response.statusCode ?? HttpStatus.internalServerError;
    if (statusCode >= HttpStatus.ok &&
        statusCode < HttpStatus.multipleChoices) {
      return _mapValue(payload['data']);
    }

    throw _failureFromResponse(
      payload,
      headers: response.headers.map,
      fallbackMessage: fallbackMessage,
      fallbackCode: fallbackCode,
    );
  }
}

class IOWebSocketGroupListeningRealtimeTransportClient
    implements GroupListeningRealtimeTransportClient {
  const IOWebSocketGroupListeningRealtimeTransportClient();

  @override
  Future<GroupListeningRealtimeConnection> connect(
    GroupListeningTransportConnectRequest request,
  ) async {
    final uri = _voyageWebSocketUri(
      request.session.voyageBaseUrl,
      roomId: request.session.roomId,
    );
    try {
      final socket = await WebSocket.connect(
        uri.toString(),
        headers: <String, Object?>{
          HttpHeaders.authorizationHeader:
              'Bearer ${request.session.accessToken}',
        },
        protocols: const <String>[voyageProtocolVersion],
      );
      return _IOWebSocketGroupListeningRealtimeConnection(socket);
    } on WebSocketException catch (error) {
      throw GroupListeningRepositoryException(
        GroupListeningErrorState(
          code: GroupListeningErrorCode.transportUnavailable,
          message: error.message,
          retryable: true,
        ),
      );
    } on SocketException catch (error) {
      throw GroupListeningRepositoryException(
        GroupListeningErrorState(
          code: GroupListeningErrorCode.transportUnavailable,
          message: error.message,
          retryable: true,
        ),
      );
    } on HttpException catch (error) {
      throw GroupListeningRepositoryException(
        GroupListeningErrorState(
          code: GroupListeningErrorCode.transportUnavailable,
          message: error.message,
          retryable: true,
        ),
      );
    } on Object {
      throw const GroupListeningRepositoryException(
        GroupListeningErrorState(
          code: GroupListeningErrorCode.transportUnavailable,
          message: 'Unable to connect to Voyage realtime transport.',
          retryable: true,
        ),
      );
    }
  }
}

class _IOWebSocketGroupListeningRealtimeConnection
    implements GroupListeningRealtimeConnection {
  _IOWebSocketGroupListeningRealtimeConnection(this._socket) {
    _subscription = _socket.listen(
      _handleRawMessage,
      onError: _handleSocketError,
      onDone: _handleSocketDone,
      cancelOnError: false,
    );
  }

  final WebSocket _socket;
  final StreamController<GroupListeningTransportMessage> _messagesController =
      StreamController<GroupListeningTransportMessage>.broadcast();
  late final StreamSubscription<dynamic> _subscription;
  bool _closedByClient = false;
  bool _receivedRoomClosed = false;

  @override
  Stream<GroupListeningTransportMessage> get messages =>
      _messagesController.stream;

  @override
  Future<void> disconnect() async {
    _closedByClient = true;
    await _subscription.cancel();
    await _socket.close(WebSocketStatus.normalClosure);
    if (!_messagesController.isClosed) {
      await _messagesController.close();
    }
  }

  @override
  Future<void> send(GroupListeningOutboundTransportMessage message) async {
    if (_closedByClient) {
      throw const GroupListeningRepositoryException(
        GroupListeningErrorState(
          code: GroupListeningErrorCode.transportDisconnected,
          message: 'Voyage realtime transport is disconnected.',
          retryable: true,
        ),
      );
    }
    final encoded = jsonEncode(_outboundTransportEnvelope(message));
    try {
      _socket.add(encoded);
    } on Object {
      throw const GroupListeningRepositoryException(
        GroupListeningErrorState(
          code: GroupListeningErrorCode.transportDisconnected,
          message: 'Unable to send Voyage realtime transport message.',
          retryable: true,
        ),
      );
    }
  }

  void _handleRawMessage(dynamic rawMessage) {
    try {
      final envelope = _mapValue(_decodeJsonBody(rawMessage));
      _validateProtocolVersion(envelope['protocol_version']);
      final frameType = _stringValue(envelope['type']);
      final serverTime = _dateTimeFromEpochMs(envelope['server_time_ms']);
      final data = envelope['data'];
      switch (frameType) {
        case 'connection.welcome':
          final payload = _mapValue(data);
          _messagesController.add(
            GroupListeningConnectionWelcomeMessage(
              roomId: _stringValue(payload['room_id']),
              memberId: _stringValue(payload['member_id']),
              clientConnectionId: _stringValue(payload['client_connection_id']),
              roomVersion: _intValue(payload['room_version']),
              presenceVersion: _intValue(payload['presence_version']),
              heartbeatInterval: Duration(
                milliseconds: _intValue(payload['heartbeat_interval_ms']),
              ),
              memberStaleTimeout: Duration(
                milliseconds: _intValue(payload['member_stale_timeout_ms']),
              ),
              serverTime: _dateTimeFromEpochMs(payload['server_time_ms']),
            ),
          );
          return;
        case 'room.snapshot':
          _messagesController.add(
            GroupListeningRoomSnapshotMessage(
              _roomStateFromJson(_mapValue(data)),
            ),
          );
          return;
        case 'room.event':
          _messagesController.add(
            GroupListeningRoomEventMessage(
              _roomEventFromJson(_mapValue(data)),
            ),
          );
          return;
        case 'presence.updated':
          final payload = _mapValue(data);
          _messagesController.add(
            GroupListeningPresenceUpdatedMessage(
              roomId: _stringValue(payload['room_id']),
              roomVersion: _intValue(payload['room_version']),
              presenceVersion: _intValue(payload['presence_version']),
              members: _memberListFromJson(payload['members']),
            ),
          );
          return;
        case 'heartbeat.ack':
          final payload = _mapValue(data);
          _messagesController.add(
            GroupListeningHeartbeatAckMessage(
              serverTime: serverTime,
              roomVersion: _intValue(payload['room_version']),
              presenceVersion: _intValue(payload['presence_version']),
              nextHeartbeatDeadline: _dateTimeFromEpochMs(
                payload['next_heartbeat_deadline_ms'],
              ),
            ),
          );
          return;
        case 'room.closed':
          final payload = _mapValue(data);
          _receivedRoomClosed = true;
          _messagesController.add(
            GroupListeningRoomClosedMessage(
              roomId: _stringValue(payload['room_id']),
              roomVersion: _intValue(payload['room_version']),
              closedAt: _dateTimeFromEpochMs(payload['closed_at_ms']),
            ),
          );
          return;
        case 'error':
          _messagesController.add(
            GroupListeningTransportErrorMessage(
              _errorStateFromApiError(_mapValue(envelope['error'])),
            ),
          );
          return;
        default:
          _messagesController.add(
            const GroupListeningTransportErrorMessage(
              GroupListeningErrorState(
                code: GroupListeningErrorCode.validationFailed,
                message: 'Voyage sent an unsupported realtime frame.',
              ),
            ),
          );
          return;
      }
    } on GroupListeningRepositoryException catch (error) {
      _messagesController.add(
        GroupListeningTransportErrorMessage(error.failure),
      );
    } on Object catch (error) {
      AppLogger.warning('Failed to decode Voyage websocket frame: $error');
      _messagesController.add(
        const GroupListeningTransportErrorMessage(
          GroupListeningErrorState(
            code: GroupListeningErrorCode.validationFailed,
            message: 'Voyage realtime payload was malformed.',
          ),
        ),
      );
    }
  }

  void _handleSocketDone() {
    if (_closedByClient || _receivedRoomClosed) {
      unawaited(_messagesController.close());
      return;
    }
    _messagesController.add(
      const GroupListeningTransportDisconnectedMessage(
        retryable: true,
      ),
    );
    unawaited(_messagesController.close());
  }

  void _handleSocketError(Object error, StackTrace stackTrace) {
    AppLogger.warning('Voyage websocket transport failed: $error');
    if (_closedByClient) {
      return;
    }
    _messagesController.add(
      GroupListeningTransportDisconnectedMessage(
        error: _transportDisconnectedFailure(error),
        retryable: true,
      ),
    );
  }
}

abstract class GroupListeningHttpClient {
  Future<GroupListeningCapabilityDiscovery> discover(
    GroupListeningClientConfiguration configuration,
  );

  Future<List<GroupListeningAvailableRoomSummary>> listAvailableRooms(
    GroupListeningClientConfiguration configuration,
  );

  Future<GroupListeningJoinResponse> createRoom(
    GroupListeningCreateRoomRequest request,
  );

  Future<GroupListeningJoinResponse> joinAvailableRoom({
    required String roomId,
    required GroupListeningClientConfiguration configuration,
    required GroupListeningClientDescriptor client,
  });

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

  Future<GroupListeningCloseRoomResponse> closeRoom(
    GroupListeningSessionRuntimeContext session, {
    int? expectedRoomVersion,
  });

  Future<GroupListeningRotateInviteResponse> rotateInvite(
    GroupListeningSessionRuntimeContext session, {
    int? expectedRoomVersion,
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

  Future<List<GroupListeningAvailableRoomSummary>> listAvailableRooms(
    GroupListeningClientConfiguration configuration,
  );

  Future<GroupListeningJoinResponse> createRoom(
    GroupListeningCreateRoomRequest request,
  );

  Future<GroupListeningJoinResponse> joinAvailableRoom({
    required String roomId,
    required GroupListeningClientConfiguration configuration,
    required GroupListeningClientDescriptor client,
  });

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

  Future<GroupListeningCloseRoomResponse> closeRoom(
    GroupListeningSessionRuntimeContext session, {
    int? expectedRoomVersion,
  });

  Future<GroupListeningRotateInviteResponse> rotateInvite(
    GroupListeningSessionRuntimeContext session, {
    int? expectedRoomVersion,
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
  Future<List<GroupListeningAvailableRoomSummary>> listAvailableRooms(
    GroupListeningClientConfiguration configuration,
  ) {
    throw _unsupported();
  }

  @override
  Future<GroupListeningJoinResponse> createRoom(
    GroupListeningCreateRoomRequest request,
  ) {
    throw _unsupported();
  }

  @override
  Future<GroupListeningJoinResponse> joinAvailableRoom({
    required String roomId,
    required GroupListeningClientConfiguration configuration,
    required GroupListeningClientDescriptor client,
  }) {
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

  @override
  Future<GroupListeningCloseRoomResponse> closeRoom(
    GroupListeningSessionRuntimeContext session, {
    int? expectedRoomVersion,
  }) {
    throw _unsupported();
  }

  @override
  Future<GroupListeningRotateInviteResponse> rotateInvite(
    GroupListeningSessionRuntimeContext session, {
    int? expectedRoomVersion,
  }) {
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
  Future<List<GroupListeningAvailableRoomSummary>> listAvailableRooms(
    GroupListeningClientConfiguration configuration,
  ) {
    return _httpClient.listAvailableRooms(configuration);
  }

  @override
  Future<GroupListeningCapabilityDiscovery> discover(
    GroupListeningClientConfiguration configuration,
  ) {
    return _httpClient.discover(configuration);
  }

  @override
  Future<GroupListeningJoinResponse> joinAvailableRoom({
    required String roomId,
    required GroupListeningClientConfiguration configuration,
    required GroupListeningClientDescriptor client,
  }) {
    return _httpClient.joinAvailableRoom(
      roomId: roomId,
      configuration: configuration,
      client: client,
    );
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

  @override
  Future<GroupListeningCloseRoomResponse> closeRoom(
    GroupListeningSessionRuntimeContext session, {
    int? expectedRoomVersion,
  }) {
    return _httpClient.closeRoom(
      session,
      expectedRoomVersion: expectedRoomVersion,
    );
  }

  @override
  Future<GroupListeningRotateInviteResponse> rotateInvite(
    GroupListeningSessionRuntimeContext session, {
    int? expectedRoomVersion,
  }) {
    return _httpClient.rotateInvite(
      session,
      expectedRoomVersion: expectedRoomVersion,
    );
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

Map<String, dynamic> _storedSessionToJson(GroupListeningStoredSession session) {
  return <String, dynamic>{
    'room_id': session.roomId,
    'member_id': session.memberId,
    'role': session.role.name,
    'auth_version': session.authVersion,
    'voyage_base_url': session.voyageBaseUrl.toString(),
    'source_server_fingerprint': session.sourceServerFingerprint,
    'rejoin_token': session.rejoinToken,
    'last_applied_room_version': session.lastAppliedRoomVersion,
    'client': <String, dynamic>{
      'app_version': session.client.appVersion,
      'platform': session.client.platform,
      'device_id': session.client.deviceId,
      'device_label': session.client.deviceLabel,
      'capabilities': session.client.capabilities.toList(growable: false),
    },
  };
}

GroupListeningStoredSession _storedSessionFromJson(Map<String, dynamic> json) {
  final client = _mapValue(json['client']);
  return GroupListeningStoredSession(
    roomId: _stringValue(json['room_id']),
    memberId: _stringValue(json['member_id']),
    role: _memberRoleFromWire(json['role']),
    authVersion: _intValue(json['auth_version']),
    voyageBaseUrl: Uri.parse(_stringValue(json['voyage_base_url'])),
    sourceServerFingerprint: _stringValue(json['source_server_fingerprint']),
    rejoinToken: _stringValue(json['rejoin_token']),
    lastAppliedRoomVersion: _intValue(json['last_applied_room_version']),
    client: GroupListeningClientDescriptor(
      appVersion: _stringValue(client['app_version']),
      platform: _stringValue(client['platform']),
      deviceId: _stringValue(client['device_id']),
      deviceLabel: _nullableStringValue(client['device_label']),
      capabilities: _stringListValue(client['capabilities']).toSet(),
    ),
  );
}

Uri _voyagePathUri(Uri baseUri, List<String> trailingSegments) {
  final baseSegments = baseUri.pathSegments
      .where((segment) => segment.trim().isNotEmpty)
      .toList(growable: false);
  return baseUri.replace(
    pathSegments: <String>[...baseSegments, ...trailingSegments],
    queryParameters: null,
    fragment: null,
  );
}

Uri _voyageWebSocketUri(Uri baseUri, {required String roomId}) {
  final httpUri = _voyagePathUri(baseUri, <String>[
    'api',
    'v1',
    'rooms',
    roomId,
    'ws',
  ]);
  return httpUri.replace(
    scheme: switch (httpUri.scheme) {
      'https' => 'wss',
      'http' => 'ws',
      _ => httpUri.scheme,
    },
  );
}

GroupListeningRepositoryException _failureFromDio(
  DioException error, {
  required String fallbackMessage,
  required GroupListeningErrorCode fallbackCode,
}) {
  final response = error.response;
  if (response != null) {
    final payload = _mapValue(_decodeJsonBody(response.data));
    _validateEnvelopeProtocolVersion(payload);
    return _failureFromResponse(
      payload,
      headers: response.headers.map,
      fallbackMessage: fallbackMessage,
      fallbackCode: fallbackCode,
    );
  }
  return GroupListeningRepositoryException(
    GroupListeningErrorState(
      code: fallbackCode,
      message: error.message ?? fallbackMessage,
      retryable: true,
    ),
  );
}

GroupListeningRepositoryException _failureFromResponse(
  Map<String, dynamic> payload, {
  required Map<String, List<String>> headers,
  required String fallbackMessage,
  required GroupListeningErrorCode fallbackCode,
}) {
  final rawError = payload['error'];
  if (rawError is Map) {
    return GroupListeningRepositoryException(
      _errorStateFromApiError(
        Map<String, dynamic>.from(rawError),
        retryAfterHeader: headers[HttpHeaders.retryAfterHeader]?.first,
      ),
    );
  }
  return GroupListeningRepositoryException(
    GroupListeningErrorState(
      code: fallbackCode,
      message: fallbackMessage,
      retryable: true,
    ),
  );
}

GroupListeningJoinResponse _joinResponseFromData(
  Map<String, dynamic> data, {
  required Uri voyageBaseUrl,
}) {
  final selfMember = _mapValue(data['self_member']);
  final authVersion = _intValue(selfMember['auth_version']);
  final runtimeContext = GroupListeningSessionRuntimeContext(
    roomId: _stringValue(data['room_id']),
    memberId: _stringValue(selfMember['member_id']),
    role: _memberRoleFromWire(selfMember['role']),
    authVersion: authVersion,
    voyageBaseUrl: voyageBaseUrl,
    sourceServerFingerprint: _roomFingerprintFromSnapshot(
      _mapValue(data['room_snapshot']),
    ),
    accessToken: _stringValue(data['access_token']),
    accessTokenExpiresAt: _dateTimeFromEpochMs(
      data['access_token_expires_at_ms'],
    ),
    rejoinToken: _stringValue(data['rejoin_token']),
  );
  return GroupListeningJoinResponse(
    runtimeContext: runtimeContext,
    roomSnapshot: _roomStateFromJson(
      _mapValue(data['room_snapshot']),
      fallbackSelfMemberId: runtimeContext.memberId,
      fallbackSelfRole: runtimeContext.role,
      fallbackSelfAuthVersion: authVersion,
    ),
    inviteCode: _nullableStringValue(data['invite_code']),
  );
}

List<GroupListeningAvailableRoomSummary> _availableRoomsFromData(
  Map<String, dynamic> data,
) {
  return (data['rooms'] as List<dynamic>? ?? const <dynamic>[])
      .map(_mapValue)
      .map(
        (room) => GroupListeningAvailableRoomSummary(
          roomId: _stringValue(room['room_id']),
          hostDisplayName: _stringValue(room['host_display_name']),
          membersTotal: _intValue(room['members_total']),
          activeMembers: _intValue(room['active_members']),
          queueLength: _intValue(room['queue_length']),
          roomVersion: _intValue(room['room_version']),
          lastActivityAt: _dateTimeFromEpochMs(room['last_activity_at_ms']),
        ),
      )
      .toList(growable: false);
}

void _ensureDiscoverySupportsCurrentProtocol(
  GroupListeningCapabilityDiscovery discovery,
) {
  if (discovery.supportsCurrentProtocol) {
    return;
  }
  throw GroupListeningRepositoryException(
    GroupListeningErrorState(
      code: GroupListeningErrorCode.unsupportedProtocolVersion,
      message: 'Voyage does not support $voyageProtocolVersion.',
      details: <String, Object?>{
        'supported_protocol_versions': discovery.supportedProtocolVersions,
        'latest_protocol_version': discovery.latestProtocolVersion,
        'expected_protocol_version': voyageProtocolVersion,
      },
    ),
  );
}

String _roomFingerprintFromSnapshot(Map<String, dynamic> snapshot) {
  return _stringValue(snapshot['source_server_fingerprint']);
}

GroupListeningRoomState _roomStateFromJson(
  Map<String, dynamic> json, {
  String? fallbackSelfMemberId,
  GroupListeningMemberRole? fallbackSelfRole,
  int? fallbackSelfAuthVersion,
}) {
  _validateProtocolVersion(json['protocol_version']);
  final roomVersion = _intValue(json['room_version']);
  final authVersion = _intValue(json['auth_version']);
  final queue = _queueStateFromJson(_mapValue(json['queue']));
  final playbackAnchor = _nullableMapValue(json['playback_anchor']) != null
      ? _playbackAnchorFromJson(_mapValue(json['playback_anchor']))
      : GroupListeningPlaybackAnchor(
          roomVersion: roomVersion,
          queueVersion: queue.queueVersion,
          currentIndex: queue.currentIndex,
          currentQueueEntryId: queue.currentEntry?.queueEntryId,
          currentSongId: queue.currentEntry?.songId,
          playbackState: GroupListeningPlaybackStatus.paused,
          position: Duration.zero,
          capturedAt: _dateTimeFromEpochMs(json['server_time_ms']),
          playbackRate: 1,
          reason: GroupListeningPlaybackAnchorReason.snapshot,
          issuedByMemberId: fallbackSelfMemberId,
        );
  final self = _nullableMapValue(json['self']);
  return GroupListeningRoomState(
    protocolVersion: _stringValue(json['protocol_version']),
    roomId: _stringValue(json['room_id']),
    roomStatus: _roomStatusFromWire(json['room_status']),
    roomVersion: roomVersion,
    presenceVersion: _intValue(json['presence_version']),
    authVersion: authVersion,
    serverTime: _dateTimeFromEpochMs(json['server_time_ms']),
    sourceServerFingerprint: _stringValue(json['source_server_fingerprint']),
    hostMemberId: _stringValue(json['host_member_id']),
    self: GroupListeningSelfState(
      memberId:
          _nullableStringValue(self?['member_id']) ??
          fallbackSelfMemberId ??
          '',
      role: self != null
          ? _memberRoleFromWire(self['role'])
          : (fallbackSelfRole ?? GroupListeningMemberRole.member),
      canControl: self != null && _boolValue(self['can_control']),
      authVersion: fallbackSelfAuthVersion ?? authVersion,
    ),
    members: _memberListFromJson(json['members']),
    queue: queue,
    playbackAnchor: playbackAnchor,
  );
}

GroupListeningRoomEvent _roomEventFromJson(Map<String, dynamic> json) {
  final eventType = _roomEventTypeFromWire(json['event_type']);
  final members = _memberListFromJson(json['members']);
  final removedMemberIds =
      eventType == GroupListeningRoomEventType.memberLeft ||
          eventType == GroupListeningRoomEventType.memberRemoved
      ? members.map((member) => member.memberId).toList(growable: false)
      : const <String>[];
  final causedBy = _nullableMapValue(json['caused_by']);
  return GroupListeningRoomEvent(
    eventId: _stringValue(json['event_id']),
    eventType: eventType,
    roomId: _stringValue(json['room_id']),
    previousRoomVersion: _intValue(json['previous_room_version']),
    roomVersion: _intValue(json['room_version']),
    causedByMemberId: _nullableStringValue(causedBy?['member_id']),
    clientMutationId: _nullableStringValue(causedBy?['client_mutation_id']),
    playbackAnchor: _nullableMapValue(json['playback_anchor']) != null
        ? _playbackAnchorFromJson(_mapValue(json['playback_anchor']))
        : null,
    queue: _nullableMapValue(json['queue']) != null
        ? _queueStateFromJson(_mapValue(json['queue']))
        : null,
    members: members,
    removedMemberIds: removedMemberIds,
    hostMemberId: _nullableStringValue(json['host_member_id']),
    roomStatus: _nullableStringValue(json['room_status']) == null
        ? null
        : _roomStatusFromWire(json['room_status']),
    presenceVersion: _nullableIntValue(json['presence_version']),
    authVersion: _nullableIntValue(json['auth_version']),
  );
}

GroupListeningQueueState _queueStateFromJson(Map<String, dynamic> json) {
  final entries = (json['entries'] as List<dynamic>? ?? const <dynamic>[])
      .map(_mapValue)
      .map(
        (entry) => GroupListeningQueueEntry(
          queueEntryId: _stringValue(entry['queue_entry_id']),
          songId: _stringValue(entry['song_id']),
          addedByMemberId: _nullableStringValue(entry['added_by_member_id']),
          addedAt: _dateTimeFromEpochMs(entry['added_at_ms']),
        ),
      )
      .toList(growable: false);
  final currentIndex = _nullableIntValue(json['current_index']);
  return GroupListeningQueueState(
    queueVersion: _intValue(json['queue_version']),
    currentIndex:
        currentIndex == null ||
            currentIndex < 0 ||
            currentIndex >= entries.length
        ? null
        : currentIndex,
    entries: entries,
  );
}

GroupListeningPlaybackAnchor _playbackAnchorFromJson(
  Map<String, dynamic> json,
) {
  final currentIndex = _nullableIntValue(json['current_index']);
  return GroupListeningPlaybackAnchor(
    roomVersion: _intValue(json['room_version']),
    queueVersion: _intValue(json['queue_version']),
    currentIndex: currentIndex == null || currentIndex < 0
        ? null
        : currentIndex,
    currentQueueEntryId: _nullableStringValue(json['current_queue_entry_id']),
    currentSongId: _nullableStringValue(json['current_song_id']),
    playbackState: _playbackStatusFromWire(json['playback_state']),
    position: Duration(milliseconds: _intValue(json['position_ms'])),
    capturedAt: _dateTimeFromEpochMs(json['captured_at_ms']),
    playbackRate: _doubleValue(json['playback_rate']),
    reason: _anchorReasonFromWire(json['reason']),
    issuedByMemberId: _nullableStringValue(json['issued_by_member_id']),
  );
}

List<GroupListeningMemberState> _memberListFromJson(Object? rawMembers) {
  return (rawMembers as List<dynamic>? ?? const <dynamic>[])
      .map(_mapValue)
      .map(
        (member) => GroupListeningMemberState(
          memberId: _stringValue(member['member_id']),
          displayName: _stringValue(member['display_name']),
          deviceLabel: _nullableStringValue(member['device_label']),
          role: _memberRoleFromWire(member['role']),
          presenceState: _presenceStateFromWire(member['presence_state']),
          capabilities: _capabilitySetFromWire(member['capabilities']),
          joinedAt: _dateTimeFromEpochMs(member['joined_at_ms']),
          lastSeenAt: _dateTimeFromEpochMs(member['last_seen_at_ms']),
        ),
      )
      .toList(growable: false);
}

Map<String, dynamic> _outboundTransportEnvelope(
  GroupListeningOutboundTransportMessage message,
) {
  if (message is GroupListeningHeartbeatMessage) {
    return <String, Object?>{
      'type': 'heartbeat',
      'data': <String, Object?>{
        'client_connection_id': message.clientConnectionId,
        'client_time_ms': message.clientTime.toUtc().millisecondsSinceEpoch,
        'last_applied_room_version': message.lastAppliedRoomVersion,
        if (message.observedPosition != null)
          'observed_position_ms': message.observedPosition!.inMilliseconds,
        if (message.transportRtt != null)
          'transport_rtt_ms': message.transportRtt!.inMilliseconds,
      },
    };
  }
  if (message is! GroupListeningMutationMessage) {
    throw const GroupListeningRepositoryException(
      GroupListeningErrorState(
        code: GroupListeningErrorCode.validationFailed,
        message: 'Unsupported Voyage outbound transport message.',
      ),
    );
  }

  switch (message.type) {
    case GroupListeningMutationType.playbackAnchor:
      final playbackAnchor = message.playbackAnchor;
      if (playbackAnchor == null) {
        throw const GroupListeningRepositoryException(
          GroupListeningErrorState(
            code: GroupListeningErrorCode.validationFailed,
            message: 'Playback mutations require a playback anchor payload.',
          ),
        );
      }
      return <String, Object?>{
        'type': 'mutation.playback_anchor',
        'data': <String, Object?>{
          'event_type': _playbackMutationEventType(playbackAnchor.reason),
          'expected_room_version': message.expectedRoomVersion,
          'client_mutation_id': message.clientMutationId,
          'client_connection_id': message.clientConnectionId,
          'client_seq': message.clientSequence,
          if (playbackAnchor.currentIndex != null)
            'current_index': playbackAnchor.currentIndex,
          'position_ms': playbackAnchor.position.inMilliseconds,
          'playback_state': playbackAnchor.playbackState.name,
          'playback_rate': playbackAnchor.playbackRate,
        },
      };
    case GroupListeningMutationType.queueReplace:
      final queue = message.queue;
      if (queue == null) {
        throw const GroupListeningRepositoryException(
          GroupListeningErrorState(
            code: GroupListeningErrorCode.validationFailed,
            message: 'Queue replace mutations require a queue payload.',
          ),
        );
      }
      return <String, Object?>{
        'type': 'mutation.queue_replace',
        'data': <String, Object?>{
          'expected_room_version': message.expectedRoomVersion,
          'client_mutation_id': message.clientMutationId,
          'client_connection_id': message.clientConnectionId,
          'client_seq': message.clientSequence,
          if (queue.currentIndex != null) 'current_index': queue.currentIndex,
          if (message.playbackAnchor != null)
            'position_ms': message.playbackAnchor!.position.inMilliseconds,
          if (message.playbackAnchor != null)
            'playback_state': message.playbackAnchor!.playbackState.name,
          if (message.playbackAnchor != null)
            'playback_rate': message.playbackAnchor!.playbackRate,
          'entries': queue.entries
              .map(
                (entry) => <String, Object?>{
                  'queue_entry_id': entry.queueEntryId,
                  'song_id': entry.songId,
                },
              )
              .toList(growable: false),
        },
      };
    case GroupListeningMutationType.queueAdd:
      final queue = message.queue;
      final queueEntryId = message.targetQueueEntryId?.trim();
      if (queue == null || queueEntryId == null || queueEntryId.isEmpty) {
        throw const GroupListeningRepositoryException(
          GroupListeningErrorState(
            code: GroupListeningErrorCode.validationFailed,
            message: 'Queue add mutations require a queue entry target.',
          ),
        );
      }
      GroupListeningQueueEntry? queueEntry;
      for (final entry in queue.entries) {
        if (entry.queueEntryId == queueEntryId) {
          queueEntry = entry;
          break;
        }
      }
      if (queueEntry == null) {
        throw const GroupListeningRepositoryException(
          GroupListeningErrorState(
            code: GroupListeningErrorCode.validationFailed,
            message: 'Queue add target was not found in the queue payload.',
          ),
        );
      }
      return <String, Object?>{
        'type': 'mutation.queue_add',
        'data': <String, Object?>{
          'expected_room_version': message.expectedRoomVersion,
          'client_mutation_id': message.clientMutationId,
          'client_connection_id': message.clientConnectionId,
          'client_seq': message.clientSequence,
          'song_id': queueEntry.songId,
          'queue_entry_id': queueEntry.queueEntryId,
        },
      };
    case GroupListeningMutationType.queueRemove:
      final queueEntryId = message.targetQueueEntryId?.trim();
      if (queueEntryId == null || queueEntryId.isEmpty) {
        throw const GroupListeningRepositoryException(
          GroupListeningErrorState(
            code: GroupListeningErrorCode.validationFailed,
            message: 'Queue remove mutations require a queue entry target.',
          ),
        );
      }
      return <String, Object?>{
        'type': 'mutation.queue_remove',
        'data': <String, Object?>{
          'expected_room_version': message.expectedRoomVersion,
          'client_mutation_id': message.clientMutationId,
          'client_connection_id': message.clientConnectionId,
          'client_seq': message.clientSequence,
          'queue_entry_id': queueEntryId,
        },
      };
    case GroupListeningMutationType.transferHost:
      final targetMemberId = message.targetMemberId?.trim();
      if (targetMemberId == null || targetMemberId.isEmpty) {
        throw const GroupListeningRepositoryException(
          GroupListeningErrorState(
            code: GroupListeningErrorCode.validationFailed,
            message: 'Host transfer mutations require a target member.',
          ),
        );
      }
      return <String, Object?>{
        'type': 'mutation.transfer_host',
        'data': <String, Object?>{
          'expected_room_version': message.expectedRoomVersion,
          'client_mutation_id': message.clientMutationId,
          'client_connection_id': message.clientConnectionId,
          'client_seq': message.clientSequence,
          'target_member_id': targetMemberId,
        },
      };
    case GroupListeningMutationType.removeMember:
      final targetMemberId = message.targetMemberId?.trim();
      if (targetMemberId == null || targetMemberId.isEmpty) {
        throw const GroupListeningRepositoryException(
          GroupListeningErrorState(
            code: GroupListeningErrorCode.validationFailed,
            message: 'Member removal mutations require a target member.',
          ),
        );
      }
      return <String, Object?>{
        'type': 'mutation.remove_member',
        'data': <String, Object?>{
          'expected_room_version': message.expectedRoomVersion,
          'client_mutation_id': message.clientMutationId,
          'client_connection_id': message.clientConnectionId,
          'client_seq': message.clientSequence,
          'target_member_id': targetMemberId,
        },
      };
  }
}

Map<String, Object?> _clientPayload(GroupListeningClientDescriptor client) {
  return <String, Object?>{
    'app_version': client.appVersion,
    'platform': client.platform,
    'device_id': client.deviceId,
    if (client.deviceLabel != null) 'device_label': client.deviceLabel,
    if (client.capabilities.isNotEmpty)
      'capabilities': <String, bool>{
        for (final capability in client.capabilities) capability: true,
      },
  };
}

Map<String, Object?> _roomSeedPayload(GroupListeningRoomSeed seed) {
  return <String, Object?>{
    'queue': <String, Object?>{
      'queue_version': seed.queue.queueVersion,
      'current_index': seed.queue.currentIndex ?? -1,
      'entries': seed.queue.entries
          .map(
            (entry) => <String, Object?>{
              'queue_entry_id': entry.queueEntryId,
              'song_id': entry.songId,
              if (entry.addedByMemberId != null)
                'added_by_member_id': entry.addedByMemberId,
              'added_at_ms': entry.addedAt.toUtc().millisecondsSinceEpoch,
            },
          )
          .toList(growable: false),
    },
    'playback_anchor': <String, Object?>{
      'room_version': seed.playbackAnchor.roomVersion,
      'queue_version': seed.playbackAnchor.queueVersion,
      'current_index': seed.playbackAnchor.currentIndex ?? -1,
      'current_queue_entry_id': seed.playbackAnchor.currentQueueEntryId ?? '',
      'current_song_id': seed.playbackAnchor.currentSongId ?? '',
      'playback_state': seed.playbackAnchor.playbackState.name,
      'position_ms': seed.playbackAnchor.position.inMilliseconds,
      'captured_at_ms': seed.playbackAnchor.capturedAt
          .toUtc()
          .millisecondsSinceEpoch,
      'playback_rate': seed.playbackAnchor.playbackRate,
      'reason': _anchorReasonToWire(seed.playbackAnchor.reason),
      if (seed.playbackAnchor.issuedByMemberId != null)
        'issued_by_member_id': seed.playbackAnchor.issuedByMemberId,
    },
  };
}

GroupListeningErrorState _errorStateFromApiError(
  Map<String, dynamic> rawError, {
  String? retryAfterHeader,
}) {
  final details = _mapObjectValue(rawError['details']);
  final roomVersion =
      _nullableIntValue(rawError['room_version']) ??
      _nullableIntValue(details['room_version']);
  return GroupListeningErrorState(
    code: _errorCodeFromWire(rawError['code']),
    message: _stringValue(rawError['message']),
    retryable: _boolValue(rawError['retryable']),
    details: details,
    roomVersion: roomVersion,
    retryAfter: _retryAfterFromHeader(retryAfterHeader),
  );
}

GroupListeningErrorState _transportDisconnectedFailure(Object error) {
  final message = switch (error) {
    WebSocketException(:final message) => message,
    SocketException(:final message) => message,
    HttpException(:final message) => message,
    _ => 'Voyage realtime transport disconnected.',
  };
  return GroupListeningErrorState(
    code: GroupListeningErrorCode.transportDisconnected,
    message: message,
    retryable: true,
  );
}

GroupListeningErrorCode _errorCodeFromWire(Object? value) {
  return switch (_nullableStringValue(value)) {
    'unsupported_protocol_version' =>
      GroupListeningErrorCode.unsupportedProtocolVersion,
    'unauthorized' => GroupListeningErrorCode.unauthorized,
    'forbidden' => GroupListeningErrorCode.forbidden,
    'room_not_found' => GroupListeningErrorCode.roomNotFound,
    'room_closed' => GroupListeningErrorCode.roomClosed,
    'invite_invalid' => GroupListeningErrorCode.inviteInvalid,
    'invite_expired' => GroupListeningErrorCode.inviteExpired,
    'fingerprint_mismatch' => GroupListeningErrorCode.fingerprintMismatch,
    'stale_version' => GroupListeningErrorCode.staleVersion,
    'sequence_rejected' => GroupListeningErrorCode.sequenceRejected,
    'duplicate_mutation' => GroupListeningErrorCode.duplicateMutation,
    'snapshot_required' => GroupListeningErrorCode.snapshotRequired,
    'removed' => GroupListeningErrorCode.removed,
    'revoked' => GroupListeningErrorCode.revoked,
    'rate_limited' => GroupListeningErrorCode.rateLimited,
    'validation_failed' => GroupListeningErrorCode.validationFailed,
    'payload_too_large' => GroupListeningErrorCode.payloadTooLarge,
    'internal_error' => GroupListeningErrorCode.internalError,
    _ => GroupListeningErrorCode.unknown,
  };
}

GroupListeningMemberRole _memberRoleFromWire(Object? value) {
  return switch (_stringValue(value)) {
    'host' => GroupListeningMemberRole.host,
    'member' => GroupListeningMemberRole.member,
    final unknown => throw _protocolFormatFailure(
      'Unsupported Voyage member role: $unknown.',
    ),
  };
}

GroupListeningMemberPresenceState _presenceStateFromWire(Object? value) {
  return switch (_stringValue(value)) {
    'active' => GroupListeningMemberPresenceState.active,
    'stale' => GroupListeningMemberPresenceState.stale,
    'offline' => GroupListeningMemberPresenceState.offline,
    final unknown => throw _protocolFormatFailure(
      'Unsupported Voyage presence state: $unknown.',
    ),
  };
}

GroupListeningRoomStatus _roomStatusFromWire(Object? value) {
  return switch (_stringValue(value)) {
    'active' => GroupListeningRoomStatus.active,
    'closed' => GroupListeningRoomStatus.closed,
    final unknown => throw _protocolFormatFailure(
      'Unsupported Voyage room status: $unknown.',
    ),
  };
}

GroupListeningPlaybackStatus _playbackStatusFromWire(Object? value) {
  return switch (_stringValue(value)) {
    'playing' => GroupListeningPlaybackStatus.playing,
    'paused' => GroupListeningPlaybackStatus.paused,
    final unknown => throw _protocolFormatFailure(
      'Unsupported Voyage playback state: $unknown.',
    ),
  };
}

GroupListeningPlaybackAnchorReason _anchorReasonFromWire(Object? value) {
  return switch (_stringValue(value)) {
    'play' => GroupListeningPlaybackAnchorReason.play,
    'pause' => GroupListeningPlaybackAnchorReason.pause,
    'seek' => GroupListeningPlaybackAnchorReason.seek,
    'track_change' => GroupListeningPlaybackAnchorReason.trackChange,
    'sync_tick' => GroupListeningPlaybackAnchorReason.syncTick,
    'snapshot' => GroupListeningPlaybackAnchorReason.snapshot,
    final unknown => throw _protocolFormatFailure(
      'Unsupported Voyage playback anchor reason: $unknown.',
    ),
  };
}

String _anchorReasonToWire(GroupListeningPlaybackAnchorReason value) {
  return switch (value) {
    GroupListeningPlaybackAnchorReason.play => 'play',
    GroupListeningPlaybackAnchorReason.pause => 'pause',
    GroupListeningPlaybackAnchorReason.seek => 'seek',
    GroupListeningPlaybackAnchorReason.trackChange => 'track_change',
    GroupListeningPlaybackAnchorReason.syncTick => 'sync_tick',
    GroupListeningPlaybackAnchorReason.snapshot => 'snapshot',
  };
}

GroupListeningRoomEventType _roomEventTypeFromWire(Object? value) {
  return switch (_stringValue(value)) {
    'play' => GroupListeningRoomEventType.play,
    'pause' => GroupListeningRoomEventType.pause,
    'seek' => GroupListeningRoomEventType.seek,
    'track_change' => GroupListeningRoomEventType.trackChange,
    'queue_add' => GroupListeningRoomEventType.queueAdd,
    'queue_remove' => GroupListeningRoomEventType.queueRemove,
    'queue_replace' => GroupListeningRoomEventType.queueReplace,
    'transfer_host' => GroupListeningRoomEventType.transferHost,
    'member_joined' => GroupListeningRoomEventType.memberJoined,
    'member_left' => GroupListeningRoomEventType.memberLeft,
    'member_removed' => GroupListeningRoomEventType.memberRemoved,
    'room_closed' => GroupListeningRoomEventType.roomClosed,
    'sync_tick' => GroupListeningRoomEventType.syncTick,
    _ => throw const GroupListeningRepositoryException(
      GroupListeningErrorState(
        code: GroupListeningErrorCode.snapshotRequired,
        message: 'Voyage sent an unsupported room event.',
        retryable: true,
      ),
    ),
  };
}

GroupListeningRepositoryException _protocolFormatFailure(String message) {
  return GroupListeningRepositoryException(
    GroupListeningErrorState(
      code: GroupListeningErrorCode.validationFailed,
      message: message,
    ),
  );
}

void _validateProtocolVersion(Object? value) {
  final protocolVersion = _nullableStringValue(value) ?? '';
  if (protocolVersion == voyageProtocolVersion) {
    return;
  }
  throw GroupListeningRepositoryException(
    GroupListeningErrorState(
      code: GroupListeningErrorCode.unsupportedProtocolVersion,
      message: 'Voyage protocol $protocolVersion is not supported.',
      details: <String, Object?>{
        'expected_protocol_version': voyageProtocolVersion,
        'received_protocol_version': protocolVersion,
      },
    ),
  );
}

void _validateEnvelopeProtocolVersion(Map<String, dynamic> payload) {
  _validateProtocolVersion(payload['protocol_version']);
}

String _playbackMutationEventType(GroupListeningPlaybackAnchorReason reason) {
  switch (reason) {
    case GroupListeningPlaybackAnchorReason.play:
      return 'play';
    case GroupListeningPlaybackAnchorReason.pause:
      return 'pause';
    case GroupListeningPlaybackAnchorReason.trackChange:
      return 'track_change';
    case GroupListeningPlaybackAnchorReason.seek:
    case GroupListeningPlaybackAnchorReason.syncTick:
    case GroupListeningPlaybackAnchorReason.snapshot:
      return 'seek';
  }
}

Set<String> _capabilitySetFromWire(Object? rawCapabilities) {
  if (rawCapabilities is Map) {
    return rawCapabilities.entries
        .where((entry) => entry.value == true)
        .map((entry) => entry.key.toString())
        .toSet();
  }
  return const <String>{};
}

Map<String, dynamic> _mapValue(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map(
      (key, value) => MapEntry(key.toString(), value),
    );
  }
  throw const FormatException('Expected a JSON object.');
}

Map<String, Object?> _mapObjectValue(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return value.map(
      (key, value) => MapEntry(key.toString(), value),
    );
  }
  return const <String, Object?>{};
}

Map<String, dynamic>? _nullableMapValue(Object? value) {
  if (value == null) {
    return null;
  }
  return _mapValue(value);
}

Object? _decodeJsonBody(Object? body) {
  if (body == null) {
    return const <String, dynamic>{};
  }
  if (body is String) {
    if (body.trim().isEmpty) {
      return const <String, dynamic>{};
    }
    return jsonDecode(body);
  }
  return body;
}

String _stringValue(Object? value) {
  final normalized = _nullableStringValue(value);
  if (normalized == null) {
    throw const FormatException('Expected a non-empty string value.');
  }
  return normalized;
}

String? _nullableStringValue(Object? value) {
  final normalized = value?.toString().trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  return normalized;
}

int _intValue(Object? value) {
  final normalized = _nullableIntValue(value);
  if (normalized == null) {
    throw const FormatException('Expected an integer value.');
  }
  return normalized;
}

int? _nullableIntValue(Object? value) {
  return switch (value) {
    null => null,
    int value => value,
    num value => value.toInt(),
    String value => int.tryParse(value.trim()),
    _ => null,
  };
}

double _doubleValue(Object? value) {
  return switch (value) {
    double value => value,
    num value => value.toDouble(),
    String value => double.parse(value.trim()),
    _ => 1,
  };
}

bool _boolValue(Object? value) {
  return switch (value) {
    bool value => value,
    String value => value.trim().toLowerCase() == 'true',
    num value => value != 0,
    _ => false,
  };
}

List<String> _stringListValue(Object? value) {
  return (value as List<dynamic>? ?? const <dynamic>[])
      .map((entry) => entry.toString())
      .toList(growable: false);
}

DateTime _dateTimeFromEpochMs(Object? value) {
  return DateTime.fromMillisecondsSinceEpoch(_intValue(value), isUtc: true);
}

Duration? _retryAfterFromHeader(String? rawValue) {
  final normalized = rawValue?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  final seconds = int.tryParse(normalized);
  if (seconds != null) {
    return Duration(seconds: seconds);
  }
  final timestamp = DateTime.tryParse(normalized);
  if (timestamp == null) {
    return null;
  }
  final remaining = timestamp.toUtc().difference(DateTime.now().toUtc());
  return remaining.isNegative ? Duration.zero : remaining;
}
