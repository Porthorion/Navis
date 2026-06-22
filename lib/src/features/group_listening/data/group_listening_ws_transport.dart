import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:navis/src/features/group_listening/data/group_listening_dtos.dart';
import 'package:navis/src/features/group_listening/data/group_listening_transport_messages.dart';
import 'package:navis/src/features/group_listening/data/group_listening_wire_codec.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/utils/app_logger.dart';

class IOWebSocketGroupListeningRealtimeTransportClient
    implements GroupListeningRealtimeTransportClient {
  const IOWebSocketGroupListeningRealtimeTransportClient();

  @override
  Future<GroupListeningRealtimeConnection> connect(
    GroupListeningTransportConnectRequest request,
  ) async {
    final uri = voyageWebSocketUri(
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
        protocols: <String>[request.session.protocolVersion],
      );
      if (request.session.protocolVersion == voyageProtocolVersion) {
        socket.add(
          jsonEncode(<String, Object?>{
            'type': 'connection.init',
            'data': <String, Object?>{
              'last_event_id': request.lastAppliedEventId,
              'last_applied_room_version': request.lastAppliedRoomVersion,
              'last_applied_queue_version': request.lastAppliedQueueVersion,
              'last_applied_playback_version':
                  request.lastAppliedPlaybackVersion,
              'last_applied_presence_version':
                  request.lastAppliedPresenceVersion,
              'client_time_ms': DateTime.now().toUtc().millisecondsSinceEpoch,
            },
          }),
        );
      }
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
    final encoded = jsonEncode(outboundTransportEnvelope(message));
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
      final envelope = mapValue(decodeJsonBody(rawMessage));
      validateProtocolVersion(envelope['protocol_version']);
      final frameType = stringValue(envelope['type']);
      final serverTime = dateTimeFromEpochMs(envelope['server_time_ms']);
      final data = envelope['data'];
      switch (frameType) {
        case 'connection.welcome':
          final payload = mapValue(data);
          _messagesController.add(
            GroupListeningConnectionWelcomeMessage(
              roomId: stringValue(payload['room_id']),
              memberId: stringValue(payload['member_id']),
              clientConnectionId: stringValue(payload['client_connection_id']),
              roomVersion: intValue(payload['room_version']),
              presenceVersion: intValue(payload['presence_version']),
              heartbeatInterval: Duration(
                milliseconds: intValue(payload['heartbeat_interval_ms']),
              ),
              memberStaleTimeout: Duration(
                milliseconds: intValue(payload['member_stale_timeout_ms']),
              ),
              serverTime: dateTimeFromEpochMs(payload['server_time_ms']),
            ),
          );
          return;
        case 'connection.ready':
          final payload = mapValue(data);
          final heartbeatPolicy = mapValue(payload['heartbeat_policy']);
          _messagesController.add(
            GroupListeningConnectionReadyMessage(
              clientConnectionId: stringValue(
                payload['client_connection_id'],
              ),
              resumeStatus: stringValue(payload['resume_status']),
              serverTime: dateTimeFromEpochMs(payload['server_time_ms']),
              latestEventId: intValue(payload['latest_event_id']),
              minAvailableEventId:
                  nullableIntValue(payload['min_available_event_id']) ?? 0,
              roomVersion: intValue(payload['room_version']),
              queueVersion: intValue(payload['queue_version']),
              playbackVersion:
                  nullableIntValue(payload['playback_version']) ?? 0,
              playbackEpoch:
                  nullableIntValue(payload['playback_epoch']) ?? 0,
              presenceVersion: intValue(payload['presence_version']),
              authVersion: intValue(payload['auth_version']),
              heartbeatInterval: Duration(
                milliseconds: intValue(heartbeatPolicy['interval_ms']),
              ),
              memberStaleTimeout: Duration(
                milliseconds: intValue(
                  heartbeatPolicy['member_stale_timeout_ms'],
                ),
              ),
            ),
          );
          return;
        case 'room.snapshot':
          _messagesController.add(
            GroupListeningRoomSnapshotMessage(
              roomStateFromJson(mapValue(data)),
            ),
          );
          return;
        case 'room.event':
          _messagesController.add(
            GroupListeningRoomEventMessage(
              roomEventFromJson(mapValue(data)),
            ),
          );
          return;
        case 'presence.updated':
          final payload = mapValue(data);
          _messagesController.add(
            GroupListeningPresenceUpdatedMessage(
              roomId: stringValue(payload['room_id']),
              roomVersion: intValue(payload['room_version']),
              presenceVersion: intValue(payload['presence_version']),
              members: memberListFromJson(payload['members']),
            ),
          );
          return;
        case 'heartbeat.ack':
          final payload = mapValue(data);
          _messagesController.add(
            GroupListeningHeartbeatAckMessage(
              serverTime: serverTime,
              roomVersion: intValue(payload['room_version']),
              latestEventId: nullableIntValue(payload['latest_event_id']) ?? 0,
              queueVersion: nullableIntValue(payload['queue_version']) ?? 0,
              playbackVersion:
                  nullableIntValue(payload['playback_version']) ?? 0,
              playbackApplyId:
                  nullableIntValue(payload['playback_apply_id']) ?? 0,
              presenceVersion: intValue(payload['presence_version']),
              authVersion: nullableIntValue(payload['auth_version']) ?? 0,
              clientTime: nullableDateTimeFromEpochMs(
                payload['client_time_ms'],
              ),
              serverReceiveTime: nullableDateTimeFromEpochMs(
                payload['server_receive_time_ms'],
              ),
              serverSendTime: nullableDateTimeFromEpochMs(
                payload['server_send_time_ms'],
              ),
              nextHeartbeatDeadline: dateTimeFromEpochMs(
                payload['next_heartbeat_deadline_ms'],
              ),
            ),
          );
          return;
        case 'mutation.ack':
          final payload = mapValue(data);
          _messagesController.add(
            GroupListeningMutationAckMessage(
              clientMutationId: stringValue(payload['client_mutation_id']),
              eventId: intValue(payload['event_id']),
              roomVersion: intValue(payload['room_version']),
              queueVersion: nullableIntValue(payload['queue_version']) ?? 0,
              playbackVersion:
                  nullableIntValue(payload['playback_version']) ?? 0,
              playbackApplyId: nullableIntValue(
                payload['playback_apply_id'],
              ),
              presenceVersion:
                  nullableIntValue(payload['presence_version']) ?? 0,
              authVersion: nullableIntValue(payload['auth_version']) ?? 0,
            ),
          );
          return;
        case 'mutation.nack':
          final payload = mapValue(data);
          _messagesController.add(
            GroupListeningMutationRejectedMessage(
              error: errorStateFromApiError(mapValue(payload['error'])),
              clientMutationId: nullableStringValue(
                payload['client_mutation_id'],
              ),
              roomVersion: nullableIntValue(payload['room_version']),
              queueVersion: nullableIntValue(payload['queue_version']),
              playbackVersion: nullableIntValue(payload['playback_version']),
              playbackApplyId: nullableIntValue(
                payload['playback_apply_id'],
              ),
              presenceVersion: nullableIntValue(payload['presence_version']),
              authVersion: nullableIntValue(payload['auth_version']),
              conflict: nullableStringValue(payload['conflict']),
            ),
          );
          return;
        case 'room.closed':
          final payload = mapValue(data);
          _receivedRoomClosed = true;
          _messagesController.add(
            GroupListeningRoomClosedMessage(
              roomId: stringValue(payload['room_id']),
              roomVersion: intValue(payload['room_version']),
              closedAt: dateTimeFromEpochMs(payload['closed_at_ms']),
            ),
          );
          return;
        case 'session.refreshed':
          final payload = mapValue(data);
          _messagesController.add(
            GroupListeningSessionRefreshedMessage(
              accessToken: stringValue(payload['access_token']),
              accessTokenExpiresAt: dateTimeFromEpochMs(
                payload['access_token_expires_at_ms'],
              ),
            ),
          );
          return;
        case 'error':
          final errorState = errorStateFromApiError(
            mapValue(envelope['error']),
          );
          // Non-fatal mutation rejections must not disconnect the session.
          // Route them to the dedicated message type so the controller can log
          // them without triggering transport teardown.
          const nonFatalCodes = {
            GroupListeningErrorCode.forbidden,
            GroupListeningErrorCode.sequenceRejected,
            GroupListeningErrorCode.duplicateMutation,
          };
          if (nonFatalCodes.contains(errorState.code)) {
            _messagesController.add(
              GroupListeningMutationRejectedMessage(error: errorState),
            );
          } else {
            _messagesController.add(
              GroupListeningTransportErrorMessage(errorState),
            );
          }
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
        error: transportDisconnectedFailure(error),
        retryable: true,
      ),
    );
  }
}
abstract class GroupListeningRealtimeTransportClient {
  Future<GroupListeningRealtimeConnection> connect(
    GroupListeningTransportConnectRequest request,
  );
}
class UnsupportedGroupListeningRealtimeTransportClient
    implements GroupListeningRealtimeTransportClient {
  const UnsupportedGroupListeningRealtimeTransportClient();

  @override
  Future<GroupListeningRealtimeConnection> connect(
    GroupListeningTransportConnectRequest request,
  ) {
    throw unsupported();
  }
}
