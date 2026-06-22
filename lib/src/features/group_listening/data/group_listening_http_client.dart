import 'dart:io';

import 'package:dio/dio.dart';
import 'package:navis/src/features/group_listening/data/group_listening_dtos.dart';
import 'package:navis/src/features/group_listening/data/group_listening_wire_codec.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';

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
      uri: voyagePathUri(request.configuration.voyageBaseUrl, <String>[
        'api',
        'v1',
        'rooms',
      ]),
      body: <String, Object?>{
        'protocol_version': request.configuration.protocolVersion,
        'client': clientPayload(request.client),
        'member': <String, Object?>{
          'display_name': request.configuration.displayName,
        },
        'source_server_fingerprint':
            request.configuration.sourceServerFingerprint,
        if (request.roomSeed != null)
          'room_seed': roomSeedPayload(request.roomSeed!),
        'room_options': roomOptionsPayload(request.roomOptions),
      },
      fallbackMessage: 'Unable to create Voyage room.',
      fallbackCode: GroupListeningErrorCode.transportUnavailable,
    );
    return joinResponseFromData(
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
      uri: voyagePathUri(configuration.voyageBaseUrl, <String>[
        'api',
        'v1',
        'health',
      ]),
      fallbackMessage: 'Unable to discover Voyage capabilities.',
      fallbackCode: GroupListeningErrorCode.transportUnavailable,
    );
    final discovery = GroupListeningCapabilityDiscovery(
      service: stringValue(data['service']),
      apiVersion: stringValue(data['api_version']),
      serverVersion: nullableStringValue(data['server_version']) ?? '0.0.0-dev',
      buildCommit: nullableStringValue(data['build_commit']) ?? 'unknown',
      buildTime: nullableStringValue(data['build_time']) ?? 'unknown',
      supportedProtocolVersions: stringListValue(
        data['supported_protocol_versions'],
      ),
      latestProtocolVersion: stringValue(data['latest_protocol_version']),
      websocketPath: stringValue(data['websocket_path']),
      heartbeatInterval: Duration(
        milliseconds: intValue(data['heartbeat_interval_ms']),
      ),
      memberStaleTimeout: Duration(
        milliseconds: intValue(data['member_stale_timeout_ms']),
      ),
      capabilities: capabilitySetFromWire(data['capabilities']),
    );
    ensureDiscoverySupportsCurrentProtocol(discovery);
    return discovery;
  }

  @override
  Future<List<GroupListeningAvailableRoomSummary>> listAvailableRooms(
    GroupListeningClientConfiguration configuration,
  ) async {
    final data = await _sendJson(
      method: 'GET',
      uri: voyagePathUri(configuration.voyageBaseUrl, <String>[
        'api',
        'v1',
        'rooms',
      ]),
      includeProtocolHeader: true,
      protocolVersion: configuration.protocolVersion,
      sourceServerFingerprint: configuration.sourceServerFingerprint,
      fallbackMessage: 'Unable to load available Voyage rooms.',
      fallbackCode: GroupListeningErrorCode.transportUnavailable,
    );
    return availableRoomsFromData(data);
  }

  @override
  Future<GroupListeningRoomState> fetchSnapshot(
    GroupListeningSessionRuntimeContext session, {
    int? lastAppliedRoomVersion,
  }) async {
    final data = await _sendJson(
      method: 'GET',
      uri: voyagePathUri(session.voyageBaseUrl, <String>[
        'api',
        'v1',
        'rooms',
        session.roomId,
        'snapshot',
      ]),
      accessToken: session.accessToken,
      includeProtocolHeader: true,
      protocolVersion: session.protocolVersion,
      fallbackMessage: 'Unable to refresh Voyage room snapshot.',
      fallbackCode: GroupListeningErrorCode.transportUnavailable,
    );
    return roomStateFromJson(
      mapValue(data['room_snapshot']),
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
    String? pinCode,
  }) async {
    final data = await _sendJson(
      method: 'POST',
      uri: voyagePathUri(configuration.voyageBaseUrl, <String>[
        'api',
        'v1',
        'rooms',
        roomId,
        'join',
      ]),
      body: <String, Object?>{
        'protocol_version': configuration.protocolVersion,
        'client': clientPayload(client),
        'member': <String, Object?>{
          'display_name': configuration.displayName,
        },
        'source_server_fingerprint': configuration.sourceServerFingerprint,
        if (pinCode != null && pinCode.isNotEmpty) 'pin_code': pinCode,
      },
      fallbackMessage: 'Unable to join available Voyage room.',
      fallbackCode: GroupListeningErrorCode.transportUnavailable,
    );
    return joinResponseFromData(
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
      uri: voyagePathUri(request.configuration.voyageBaseUrl, <String>[
        'api',
        'v1',
        'rooms',
        'join',
      ]),
      body: <String, Object?>{
        'protocol_version': request.configuration.protocolVersion,
        'invite_code': request.inviteCode,
        if (request.pinCode != null && request.pinCode!.isNotEmpty)
          'pin_code': request.pinCode,
        'client': clientPayload(request.client),
        'member': <String, Object?>{
          'display_name': request.configuration.displayName,
        },
        'source_server_fingerprint':
            request.configuration.sourceServerFingerprint,
      },
      fallbackMessage: 'Unable to join Voyage room.',
      fallbackCode: GroupListeningErrorCode.transportUnavailable,
    );
    return joinResponseFromData(
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
      uri: voyagePathUri(session.voyageBaseUrl, <String>[
        'api',
        'v1',
        'rooms',
        session.roomId,
        'leave',
      ]),
      accessToken: session.accessToken,
      includeProtocolHeader: true,
      protocolVersion: session.protocolVersion,
      body: <String, Object?>{
        if (lastAppliedRoomVersion != null)
          'last_applied_room_version': lastAppliedRoomVersion,
      },
      fallbackMessage: 'Unable to leave Voyage room cleanly.',
      fallbackCode: GroupListeningErrorCode.transportUnavailable,
    );
    return GroupListeningLeaveResponse(
      roomId: stringValue(data['room_id']),
      leftMemberId: stringValue(data['left_member_id']),
      roomStatus: roomStatusFromWire(data['room_status']),
      roomVersion: intValue(data['room_version']),
    );
  }

  @override
  Future<GroupListeningCloseRoomResponse> closeRoom(
    GroupListeningSessionRuntimeContext session, {
    int? expectedRoomVersion,
  }) async {
    final data = await _sendJson(
      method: 'POST',
      uri: voyagePathUri(session.voyageBaseUrl, <String>[
        'api',
        'v1',
        'rooms',
        session.roomId,
        'close',
      ]),
      accessToken: session.accessToken,
      includeProtocolHeader: true,
      protocolVersion: session.protocolVersion,
      body: <String, Object?>{
        if (expectedRoomVersion != null)
          'expected_room_version': expectedRoomVersion,
      },
      fallbackMessage: 'Unable to close Voyage room.',
      fallbackCode: GroupListeningErrorCode.transportUnavailable,
    );
    return GroupListeningCloseRoomResponse(
      roomId: stringValue(data['room_id']),
      roomStatus: roomStatusFromWire(data['room_status']),
      roomVersion: intValue(data['room_version']),
      closedAt: dateTimeFromEpochMs(data['closed_at_ms']),
    );
  }

  @override
  Future<GroupListeningRotateInviteResponse> rotateInvite(
    GroupListeningSessionRuntimeContext session, {
    int? expectedRoomVersion,
  }) async {
    final data = await _sendJson(
      method: 'POST',
      uri: voyagePathUri(session.voyageBaseUrl, <String>[
        'api',
        'v1',
        'rooms',
        session.roomId,
        'rotate-invite',
      ]),
      accessToken: session.accessToken,
      includeProtocolHeader: true,
      protocolVersion: session.protocolVersion,
      body: <String, Object?>{
        if (expectedRoomVersion != null)
          'expected_room_version': expectedRoomVersion,
      },
      fallbackMessage: 'Unable to rotate Voyage invite.',
      fallbackCode: GroupListeningErrorCode.transportUnavailable,
    );
    return GroupListeningRotateInviteResponse(
      roomId: stringValue(data['room_id']),
      roomVersion: intValue(data['room_version']),
      inviteCode: stringValue(data['invite_code']),
    );
  }

  @override
  Future<GroupListeningJoinResponse> rejoinRoom(
    GroupListeningRejoinRoomRequest request,
  ) async {
    final data = await _sendJson(
      method: 'POST',
      uri: voyagePathUri(
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
        'protocol_version': request.configuration.protocolVersion,
        'rejoin_token': request.session.rejoinToken,
        'client': clientPayload(request.session.client),
        'source_server_fingerprint':
            request.configuration.sourceServerFingerprint,
        if (request.session.lastAppliedRoomVersion > 0)
          'last_applied_room_version': request.session.lastAppliedRoomVersion,
        if (request.session.lastAppliedEventId > 0)
          'last_event_id': request.session.lastAppliedEventId,
      },
      fallbackMessage: 'Unable to rejoin Voyage room.',
      fallbackCode: GroupListeningErrorCode.transportUnavailable,
    );
    return joinResponseFromData(
      data,
      voyageBaseUrl: request.configuration.voyageBaseUrl,
      fallbackRejoinToken: request.session.rejoinToken,
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
    String protocolVersion = voyageProtocolVersion,
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
              'X-Voyage-Protocol-Version': protocolVersion,
            if (sourceServerFingerprint != null)
              'X-Voyage-Source-Server-Fingerprint': sourceServerFingerprint,
            if (accessToken != null)
              HttpHeaders.authorizationHeader: 'Bearer $accessToken',
          },
        ),
      );
    } on DioException catch (error) {
      throw failureFromDio(
        error,
        fallbackMessage: fallbackMessage,
        fallbackCode: fallbackCode,
      );
    }

    final payload = mapValue(decodeJsonBody(response.data));
    validateEnvelopeProtocolVersion(payload);
    final statusCode = response.statusCode ?? HttpStatus.internalServerError;
    if (statusCode >= HttpStatus.ok &&
        statusCode < HttpStatus.multipleChoices) {
      return mapValue(payload['data']);
    }

    throw failureFromResponse(
      payload,
      headers: response.headers.map,
      fallbackMessage: fallbackMessage,
      fallbackCode: fallbackCode,
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
    String? pinCode,
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

class UnsupportedGroupListeningHttpClient implements GroupListeningHttpClient {
  const UnsupportedGroupListeningHttpClient();

  @override
  Future<List<GroupListeningAvailableRoomSummary>> listAvailableRooms(
    GroupListeningClientConfiguration configuration,
  ) {
    throw unsupported();
  }

  @override
  Future<GroupListeningJoinResponse> createRoom(
    GroupListeningCreateRoomRequest request,
  ) {
    throw unsupported();
  }

  @override
  Future<GroupListeningJoinResponse> joinAvailableRoom({
    required String roomId,
    required GroupListeningClientConfiguration configuration,
    required GroupListeningClientDescriptor client,
    String? pinCode,
  }) {
    throw unsupported();
  }

  @override
  Future<GroupListeningCapabilityDiscovery> discover(
    GroupListeningClientConfiguration configuration,
  ) {
    throw unsupported();
  }

  @override
  Future<GroupListeningRoomState> fetchSnapshot(
    GroupListeningSessionRuntimeContext session, {
    int? lastAppliedRoomVersion,
  }) {
    throw unsupported();
  }

  @override
  Future<GroupListeningJoinResponse> joinRoom(
    GroupListeningJoinRoomRequest request,
  ) {
    throw unsupported();
  }

  @override
  Future<GroupListeningLeaveResponse> leaveRoom(
    GroupListeningSessionRuntimeContext session, {
    int? lastAppliedRoomVersion,
  }) {
    throw unsupported();
  }

  @override
  Future<GroupListeningJoinResponse> rejoinRoom(
    GroupListeningRejoinRoomRequest request,
  ) {
    throw unsupported();
  }

  @override
  Future<GroupListeningCloseRoomResponse> closeRoom(
    GroupListeningSessionRuntimeContext session, {
    int? expectedRoomVersion,
  }) {
    throw unsupported();
  }

  @override
  Future<GroupListeningRotateInviteResponse> rotateInvite(
    GroupListeningSessionRuntimeContext session, {
    int? expectedRoomVersion,
  }) {
    throw unsupported();
  }
}
