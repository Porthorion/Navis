import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:navis/src/features/group_listening/data/group_listening_dtos.dart';
import 'package:navis/src/features/group_listening/data/group_listening_transport_messages.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';

class GroupListeningRepositoryException implements Exception {
  const GroupListeningRepositoryException(this.failure);

  final GroupListeningErrorState failure;
}

GroupListeningRepositoryException unsupported() {
  return const GroupListeningRepositoryException(
    GroupListeningErrorState(
      code: GroupListeningErrorCode.transportUnavailable,
      message: 'Voyage transport is not wired yet.',
    ),
  );
}

Map<String, dynamic> storedSessionToJson(GroupListeningStoredSession session) {
  return <String, dynamic>{
    'room_id': session.roomId,
    'member_id': session.memberId,
    'role': session.role.name,
    'auth_version': session.authVersion,
    'voyage_base_url': session.voyageBaseUrl.toString(),
    'source_server_fingerprint': session.sourceServerFingerprint,
    'rejoin_token': session.rejoinToken,
    'last_applied_room_version': session.lastAppliedRoomVersion,
    'last_applied_event_id': session.lastAppliedEventId,
    'protocol_version': session.protocolVersion,
    'client': <String, dynamic>{
      'app_version': session.client.appVersion,
      'platform': session.client.platform,
      'device_id': session.client.deviceId,
      'device_label': session.client.deviceLabel,
      'capabilities': session.client.capabilities.toList(growable: false),
    },
  };
}

GroupListeningStoredSession storedSessionFromJson(Map<String, dynamic> json) {
  final client = mapValue(json['client']);
  return GroupListeningStoredSession(
    roomId: stringValue(json['room_id']),
    memberId: stringValue(json['member_id']),
    role: _memberRoleFromWire(json['role']),
    authVersion: intValue(json['auth_version']),
    voyageBaseUrl: Uri.parse(stringValue(json['voyage_base_url'])),
    sourceServerFingerprint: stringValue(json['source_server_fingerprint']),
    rejoinToken: stringValue(json['rejoin_token']),
    lastAppliedRoomVersion: intValue(json['last_applied_room_version']),
    lastAppliedEventId: nullableIntValue(json['last_applied_event_id']) ?? 0,
    protocolVersion:
        nullableStringValue(json['protocol_version']) ?? voyageProtocolVersion,
    client: GroupListeningClientDescriptor(
      appVersion: stringValue(client['app_version']),
      platform: stringValue(client['platform']),
      deviceId: stringValue(client['device_id']),
      deviceLabel: nullableStringValue(client['device_label']),
      capabilities: stringListValue(client['capabilities']).toSet(),
    ),
  );
}

Uri voyagePathUri(Uri baseUri, List<String> trailingSegments) {
  final baseSegments = baseUri.pathSegments
      .where((segment) => segment.trim().isNotEmpty)
      .toList(growable: false);
  return baseUri.replace(
    pathSegments: <String>[...baseSegments, ...trailingSegments],
    queryParameters: null,
    fragment: null,
  );
}

Uri voyageWebSocketUri(Uri baseUri, {required String roomId}) {
  final httpUri = voyagePathUri(baseUri, <String>[
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

GroupListeningRepositoryException failureFromDio(
  DioException error, {
  required String fallbackMessage,
  required GroupListeningErrorCode fallbackCode,
}) {
  final response = error.response;
  if (response != null) {
    final payload = mapValue(decodeJsonBody(response.data));
    validateEnvelopeProtocolVersion(payload);
    return failureFromResponse(
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

GroupListeningRepositoryException failureFromResponse(
  Map<String, dynamic> payload, {
  required Map<String, List<String>> headers,
  required String fallbackMessage,
  required GroupListeningErrorCode fallbackCode,
}) {
  final rawError = payload['error'];
  if (rawError is Map) {
    return GroupListeningRepositoryException(
      errorStateFromApiError(
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

GroupListeningJoinResponse joinResponseFromData(
  Map<String, dynamic> data, {
  required Uri voyageBaseUrl,
  String? fallbackRejoinToken,
}) {
  final selfMember = mapValue(data['self_member']);
  final authVersion = intValue(selfMember['auth_version']);
  final rejoinToken =
      nullableStringValue(data['rejoin_token']) ??
      nullableStringValue(fallbackRejoinToken);
  if (rejoinToken == null) {
    throw const FormatException('Expected a non-empty string value.');
  }
  final runtimeContext = GroupListeningSessionRuntimeContext(
    roomId: stringValue(data['room_id']),
    memberId: stringValue(selfMember['member_id']),
    role: _memberRoleFromWire(selfMember['role']),
    authVersion: authVersion,
    voyageBaseUrl: voyageBaseUrl,
    sourceServerFingerprint: _roomFingerprintFromSnapshot(
      mapValue(data['room_snapshot']),
    ),
    accessToken: stringValue(data['access_token']),
    accessTokenExpiresAt: dateTimeFromEpochMs(
      data['access_token_expires_at_ms'],
    ),
    rejoinToken: rejoinToken,
    protocolVersion: stringValue(
      mapValue(data['room_snapshot'])['protocol_version'],
    ),
  );
  return GroupListeningJoinResponse(
    runtimeContext: runtimeContext,
    roomSnapshot: roomStateFromJson(
      mapValue(data['room_snapshot']),
      fallbackSelfMemberId: runtimeContext.memberId,
      fallbackSelfRole: runtimeContext.role,
      fallbackSelfAuthVersion: authVersion,
    ),
    inviteCode: nullableStringValue(data['invite_code']),
  );
}

List<GroupListeningAvailableRoomSummary> availableRoomsFromData(
  Map<String, dynamic> data,
) {
  return (data['rooms'] as List<dynamic>? ?? const <dynamic>[])
      .map(mapValue)
      .map(
        (room) => GroupListeningAvailableRoomSummary(
          roomId: stringValue(room['room_id']),
          hostDisplayName: stringValue(room['host_display_name']),
          roomMode: _roomModeFromWire(room['room_mode']),
          requiresPin: boolValue(room['requires_pin']),
          membersTotal: intValue(room['members_total']),
          activeMembers: intValue(room['active_members']),
          queueLength: intValue(room['queue_length']),
          roomVersion: intValue(room['room_version']),
          lastActivityAt: dateTimeFromEpochMs(room['last_activity_at_ms']),
        ),
      )
      .toList(growable: false);
}

void ensureDiscoverySupportsCurrentProtocol(
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
  return stringValue(snapshot['source_server_fingerprint']);
}

GroupListeningRoomState roomStateFromJson(
  Map<String, dynamic> json, {
  String? fallbackSelfMemberId,
  GroupListeningMemberRole? fallbackSelfRole,
  int? fallbackSelfAuthVersion,
}) {
  validateProtocolVersion(json['protocol_version']);
  final roomVersion = intValue(json['room_version']);
  final authVersion = intValue(json['auth_version']);
  final queue = _queueStateFromJson(mapValue(json['queue']));
  final playbackAnchor = _nullableMapValue(json['playback_anchor']) != null
      ? _playbackAnchorFromJson(mapValue(json['playback_anchor']))
      : null;
  final self = _nullableMapValue(json['self']);
  return GroupListeningRoomState(
    protocolVersion: stringValue(json['protocol_version']),
    roomId: stringValue(json['room_id']),
    roomStatus: roomStatusFromWire(json['room_status']),
    roomMode: _roomModeFromWire(json['room_mode']),
    playbackPhase: nullableStringValue(json['playback_phase']) ?? 'idle',
    requiresPin: boolValue(json['requires_pin']),
    roomVersion: roomVersion,
    latestEventId: nullableIntValue(json['latest_event_id']) ?? 0,
    playbackVersion: nullableIntValue(json['playback_version']) ?? 0,
    playbackApplyId: nullableIntValue(json['playback_apply_id']) ?? 0,
    playbackEpoch: nullableIntValue(json['playback_epoch']) ?? 0,
    presenceVersion: intValue(json['presence_version']),
    authVersion: authVersion,
    serverTime: dateTimeFromEpochMs(json['server_time_ms']),
    sourceServerFingerprint: stringValue(json['source_server_fingerprint']),
    hostMemberId: stringValue(json['host_member_id']),
    self: GroupListeningSelfState(
      memberId:
          nullableStringValue(self?['member_id']) ?? fallbackSelfMemberId ?? '',
      role: self != null
          ? _memberRoleFromWire(self['role'])
          : (fallbackSelfRole ?? GroupListeningMemberRole.member),
      canControl: self != null && boolValue(self['can_control']),
      canPlayAudio: self == null
          ? true
          : (_nullableBoolValue(self['can_play_audio']) ?? true),
      authVersion: fallbackSelfAuthVersion ?? authVersion,
    ),
    members: memberListFromJson(json['members']),
    queue: queue,
    playbackAnchor: playbackAnchor,
  );
}

GroupListeningRoomEvent roomEventFromJson(Map<String, dynamic> json) {
  final eventType = _roomEventTypeFromWire(json['event_type']);
  final members = memberListFromJson(json['members']);
  final explicitRemovedMemberIds =
      (json['removed_member_ids'] as List<dynamic>? ?? const <dynamic>[])
          .map(stringValue)
          .toList(growable: false);
  final removedMemberIds = explicitRemovedMemberIds.isNotEmpty
      ? explicitRemovedMemberIds
      : (eventType == GroupListeningRoomEventType.memberLeft ||
            eventType == GroupListeningRoomEventType.memberRemoved)
      ? members.map((member) => member.memberId).toList(growable: false)
      : const <String>[];
  final causedBy = _nullableMapValue(json['caused_by']);
  return GroupListeningRoomEvent(
    eventId: stringValue(json['event_id']),
    eventCursor: nullableIntValue(json['event_id']),
    eventType: eventType,
    roomId: stringValue(json['room_id']),
    previousRoomVersion: intValue(json['previous_room_version']),
    roomVersion: intValue(json['room_version']),
    queueVersion: nullableIntValue(json['queue_version']),
    playbackVersion: nullableIntValue(json['playback_version']),
    playbackApplyId: nullableIntValue(json['playback_apply_id']),
    causedByMemberId: nullableStringValue(causedBy?['member_id']),
    clientMutationId: nullableStringValue(causedBy?['client_mutation_id']),
    playbackAnchor: _nullableMapValue(json['playback_anchor']) != null
        ? _playbackAnchorFromJson(mapValue(json['playback_anchor']))
        : null,
    playbackAnchorCleared:
        _nullableBoolValue(
          json['playback_anchor_cleared'],
        ) ??
        false,
    queue: _nullableMapValue(json['queue']) != null
        ? _queueStateFromJson(mapValue(json['queue']))
        : null,
    members: members,
    removedMemberIds: removedMemberIds,
    hostMemberId: nullableStringValue(json['host_member_id']),
    roomStatus: nullableStringValue(json['room_status']) == null
        ? null
        : roomStatusFromWire(json['room_status']),
    roomMode: nullableStringValue(json['room_mode']) == null
        ? null
        : _roomModeFromWire(json['room_mode']),
    playbackPhase: nullableStringValue(json['playback_phase']),
    presenceVersion: nullableIntValue(json['presence_version']),
    authVersion: nullableIntValue(json['auth_version']),
  );
}

GroupListeningQueueState _queueStateFromJson(Map<String, dynamic> json) {
  final entries = (json['entries'] as List<dynamic>? ?? const <dynamic>[])
      .map(mapValue)
      .map(
        (entry) => GroupListeningQueueEntry(
          queueEntryId: stringValue(entry['queue_entry_id']),
          songId: stringValue(entry['song_id']),
          addedByMemberId: nullableStringValue(entry['added_by_member_id']),
          addedAt: dateTimeFromEpochMs(entry['added_at_ms']),
          title: nullableStringValue(entry['title']),
          artist: nullableStringValue(entry['artist']),
          artistId: nullableStringValue(entry['artist_id']),
          album: nullableStringValue(entry['album']),
          albumId: nullableStringValue(entry['album_id']),
          durationSeconds: nullableIntValue(entry['duration_seconds']),
          track: nullableIntValue(entry['track']),
          discNumber: nullableIntValue(entry['disc_number']),
          year: nullableIntValue(entry['year']),
          coverArt: nullableStringValue(entry['cover_art']),
          contentType: nullableStringValue(entry['content_type']),
          suffix: nullableStringValue(entry['suffix']),
          bitRate: nullableIntValue(entry['bit_rate']),
          sampleRate: nullableIntValue(entry['sample_rate']),
          size: nullableIntValue(entry['size']),
          replayGainTrackGain: _nullableDoubleValue(
            entry['replay_gain_track_gain'],
          ),
          replayGainAlbumGain: _nullableDoubleValue(
            entry['replay_gain_album_gain'],
          ),
          replayGainTrackPeak: _nullableDoubleValue(
            entry['replay_gain_track_peak'],
          ),
          replayGainAlbumPeak: _nullableDoubleValue(
            entry['replay_gain_album_peak'],
          ),
          trackRef: _nullableTrackRefFromJson(entry['track_ref']),
          playability: _playabilityFromWire(entry['playability']),
        ),
      )
      .toList(growable: false);
  final currentIndex = nullableIntValue(json['current_index']);
  return GroupListeningQueueState(
    queueVersion: intValue(json['queue_version']),
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
  final currentIndex = nullableIntValue(json['current_index']);
  return GroupListeningPlaybackAnchor(
    roomVersion: intValue(json['room_version']),
    queueVersion: intValue(json['queue_version']),
    playbackApplyId: nullableIntValue(json['playback_apply_id']),
    playbackEpoch: nullableIntValue(json['playback_epoch']) ?? 0,
    currentIndex: currentIndex == null || currentIndex < 0
        ? null
        : currentIndex,
    currentQueueEntryId: nullableStringValue(json['current_queue_entry_id']),
    currentSongId: nullableStringValue(json['current_song_id']),
    playbackState: _playbackStatusFromWire(json['playback_state']),
    position: Duration(milliseconds: intValue(json['position_ms'])),
    capturedAt: dateTimeFromEpochMs(json['captured_at_ms']),
    playbackRate: _doubleValue(json['playback_rate']),
    reason: _anchorReasonFromWire(json['reason']),
    issuedByMemberId: nullableStringValue(json['issued_by_member_id']),
    issuedByConnectionId: nullableStringValue(
      json['issued_by_connection_id'],
    ),
  );
}

List<GroupListeningMemberState> memberListFromJson(Object? rawMembers) {
  return (rawMembers as List<dynamic>? ?? const <dynamic>[])
      .map(mapValue)
      .map(
        (member) => GroupListeningMemberState(
          memberId: stringValue(member['member_id']),
          displayName: stringValue(member['display_name']),
          deviceLabel: nullableStringValue(member['device_label']),
          role: _memberRoleFromWire(member['role']),
          presenceState: _presenceStateFromWire(member['presence_state']),
          capabilities: capabilitySetFromWire(member['capabilities']),
          joinedAt: dateTimeFromEpochMs(member['joined_at_ms']),
          lastSeenAt: dateTimeFromEpochMs(member['last_seen_at_ms']),
        ),
      )
      .toList(growable: false);
}

Map<String, dynamic> outboundTransportEnvelope(
  GroupListeningOutboundTransportMessage message,
) {
  if (message is GroupListeningHeartbeatMessage) {
    return <String, Object?>{
      'type': 'heartbeat',
      'data': <String, Object?>{
        'client_connection_id': message.clientConnectionId,
        'client_time_ms': message.clientTime.toUtc().millisecondsSinceEpoch,
        'last_applied_room_version': message.lastAppliedRoomVersion,
        'last_event_id': message.lastAppliedEventId,
        'last_applied_queue_version': message.lastAppliedQueueVersion,
        'last_applied_playback_version': message.lastAppliedPlaybackVersion,
        'last_applied_presence_version': message.lastAppliedPresenceVersion,
        if (message.observedPosition != null)
          'observed_position_ms': message.observedPosition!.inMilliseconds,
        if (message.transportRtt != null)
          'transport_rtt_ms': message.transportRtt!.inMilliseconds,
      },
    };
  }
  if (message is GroupListeningClientStatusMessage) {
    return <String, Object?>{
      'type': 'member.status',
      'data': <String, Object?>{
        'client_connection_id': message.clientConnectionId,
        'last_applied_playback_apply_id': message.lastAppliedPlaybackApplyId,
        if (message.observedQueueEntryId != null)
          'observed_queue_entry_id': message.observedQueueEntryId,
        if (message.observedCurrentIndex != null)
          'observed_current_index': message.observedCurrentIndex,
        if (message.localProcessingState != null)
          'local_processing_state': message.localProcessingState,
        if (message.loadingAge != null)
          'loading_age_ms': message.loadingAge!.inMilliseconds,
        'client_time_ms': message.clientTime.toUtc().millisecondsSinceEpoch,
      },
    };
  }
  if (message is GroupListeningSessionRefreshMessage) {
    return <String, Object?>{
      'type': 'session.refresh',
      'data': <String, Object?>{
        'client_connection_id': message.clientConnectionId,
      },
    };
  }
  if (message is GroupListeningTrackReadinessMessage) {
    return <String, Object?>{
      'type': 'member.status',
      'data': <String, Object?>{
        'client_connection_id': message.clientConnectionId,
        'queue_entry_id': message.queueEntryId,
        'track_readiness_status': message.status,
        if (message.resolvedSongId != null)
          'resolved_song_id': message.resolvedSongId,
        'client_time_ms': DateTime.now().toUtc().millisecondsSinceEpoch,
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
        'type': 'command',
        'data': <String, Object?>{
          'type': _playbackCommandType(playbackAnchor.reason),
          'command_id': message.clientMutationId,
          'base_event_id': message.expectedRoomVersion,
          'expected_room_version': message.expectedRoomVersion,
          if (message.expectedQueueVersion != null)
            'expected_queue_version': message.expectedQueueVersion,
          if (message.expectedPlaybackVersion != null)
            'expected_playback_version': message.expectedPlaybackVersion,
          if (message.expectedPlaybackEpoch != null)
            'expected_playback_epoch': message.expectedPlaybackEpoch,
          'client_connection_id': message.clientConnectionId,
          'client_seq': message.clientSequence,
          if (playbackAnchor.currentIndex != null)
            'current_index': playbackAnchor.currentIndex,
          'position_ms': playbackAnchor.position.inMilliseconds,
          'playback_state': playbackAnchor.playbackState.name,
          'playback_rate': playbackAnchor.playbackRate,
          if (playbackAnchor.reason == GroupListeningPlaybackAnchorReason.seek)
            'intent_source': 'user',
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
        'type': 'command',
        'data': <String, Object?>{
          'type': 'queue.replace',
          'command_id': message.clientMutationId,
          'base_event_id': message.expectedRoomVersion,
          'expected_room_version': message.expectedRoomVersion,
          if (message.expectedQueueVersion != null)
            'expected_queue_version': message.expectedQueueVersion,
          if (message.expectedPlaybackVersion != null)
            'expected_playback_version': message.expectedPlaybackVersion,
          if (message.expectedPlaybackEpoch != null)
            'expected_playback_epoch': message.expectedPlaybackEpoch,
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
                  ..._queueEntryMetadataPayload(entry),
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
        'type': 'command',
        'data': <String, Object?>{
          'type': 'queue.add',
          'command_id': message.clientMutationId,
          'base_event_id': message.expectedRoomVersion,
          'expected_room_version': message.expectedRoomVersion,
          if (message.expectedQueueVersion != null)
            'expected_queue_version': message.expectedQueueVersion,
          'client_connection_id': message.clientConnectionId,
          'client_seq': message.clientSequence,
          'song_id': queueEntry.songId,
          'queue_entry_id': queueEntry.queueEntryId,
          if (message.insertIndex != null) 'insert_index': message.insertIndex,
          ..._queueEntryMetadataPayload(queueEntry),
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
        'type': 'command',
        'data': <String, Object?>{
          'type': 'queue.remove',
          'command_id': message.clientMutationId,
          'base_event_id': message.expectedRoomVersion,
          'expected_room_version': message.expectedRoomVersion,
          if (message.expectedQueueVersion != null)
            'expected_queue_version': message.expectedQueueVersion,
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
        'type': 'command',
        'data': <String, Object?>{
          'type': 'host.transfer',
          'command_id': message.clientMutationId,
          'base_event_id': message.expectedRoomVersion,
          'expected_room_version': message.expectedRoomVersion,
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
        'type': 'command',
        'data': <String, Object?>{
          'type': 'member.remove',
          'command_id': message.clientMutationId,
          'base_event_id': message.expectedRoomVersion,
          'expected_room_version': message.expectedRoomVersion,
          'client_connection_id': message.clientConnectionId,
          'client_seq': message.clientSequence,
          'target_member_id': targetMemberId,
        },
      };
  }
}

Map<String, Object?> clientPayload(GroupListeningClientDescriptor client) {
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

Map<String, Object?> roomOptionsPayload(GroupListeningRoomOptions options) {
  return <String, Object?>{
    'room_mode': _roomModeToWire(options.roomMode),
    if (options.pinCode != null && options.pinCode!.isNotEmpty)
      'pin_code': options.pinCode,
  };
}

Map<String, Object?> roomSeedPayload(GroupListeningRoomSeed seed) {
  return <String, Object?>{
    'queue': <String, Object?>{
      'queue_version': seed.queue.queueVersion,
      'current_index': seed.queue.currentIndex ?? -1,
      'entries': seed.queue.entries
          .map(
            (entry) => <String, Object?>{
              'queue_entry_id': entry.queueEntryId,
              'song_id': entry.songId,
              ..._queueEntryMetadataPayload(entry),
              ..._queueEntryTrackRefPayload(entry),
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
      if (seed.playbackAnchor.playbackApplyId != null)
        'playback_apply_id': seed.playbackAnchor.playbackApplyId,
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

Map<String, Object?> _queueEntryMetadataPayload(
  GroupListeningQueueEntry entry,
) {
  return <String, Object?>{
    if (entry.title != null) 'title': entry.title,
    if (entry.artist != null) 'artist': entry.artist,
    if (entry.artistId != null) 'artist_id': entry.artistId,
    if (entry.album != null) 'album': entry.album,
    if (entry.albumId != null) 'album_id': entry.albumId,
    if (entry.durationSeconds != null)
      'duration_seconds': entry.durationSeconds,
    if (entry.track != null) 'track': entry.track,
    if (entry.discNumber != null) 'disc_number': entry.discNumber,
    if (entry.year != null) 'year': entry.year,
    if (entry.coverArt != null) 'cover_art': entry.coverArt,
    if (entry.contentType != null) 'content_type': entry.contentType,
    if (entry.suffix != null) 'suffix': entry.suffix,
    if (entry.bitRate != null) 'bit_rate': entry.bitRate,
    if (entry.sampleRate != null) 'sample_rate': entry.sampleRate,
    if (entry.size != null) 'size': entry.size,
    if (entry.replayGainTrackGain != null)
      'replay_gain_track_gain': entry.replayGainTrackGain,
    if (entry.replayGainAlbumGain != null)
      'replay_gain_album_gain': entry.replayGainAlbumGain,
    if (entry.replayGainTrackPeak != null)
      'replay_gain_track_peak': entry.replayGainTrackPeak,
    if (entry.replayGainAlbumPeak != null)
      'replay_gain_album_peak': entry.replayGainAlbumPeak,
  };
}

Map<String, Object?> _queueEntryTrackRefPayload(
  GroupListeningQueueEntry entry,
) {
  final trackRef = entry.trackRef;
  return <String, Object?>{
    if (trackRef != null) 'track_ref': _trackRefToWire(trackRef),
    if (entry.playability != GroupListeningPlayability.serverAddressable)
      'playability': _playabilityToWire(entry.playability),
  };
}

Map<String, Object?> _trackRefToWire(GroupListeningTrackRef trackRef) {
  return <String, Object?>{
    'kind': _trackRefKindToWire(trackRef.kind),
    if (trackRef.librarySongId != null)
      'library_song_id': trackRef.librarySongId,
    if (trackRef.mbid != null) 'mbid': trackRef.mbid,
    if (trackRef.searchFingerprint != null)
      'search_fingerprint': <String, Object?>{
        'title': trackRef.searchFingerprint!.title,
        'artist': trackRef.searchFingerprint!.artist,
        if (trackRef.searchFingerprint!.album != null)
          'album': trackRef.searchFingerprint!.album,
        'duration_seconds': trackRef.searchFingerprint!.durationSeconds,
      },
    if (trackRef.source != null)
      'source': _trackRefSourceToWire(trackRef.source!),
  };
}

GroupListeningTrackRef? _nullableTrackRefFromJson(Object? value) {
  if (value == null) {
    return null;
  }
  return _trackRefFromJson(mapValue(value));
}

GroupListeningTrackRef _trackRefFromJson(Map<String, dynamic> json) {
  final fingerprintRaw = _nullableMapValue(json['search_fingerprint']);
  return GroupListeningTrackRef(
    kind: _trackRefKindFromWire(json['kind']),
    librarySongId: nullableStringValue(json['library_song_id']),
    mbid: nullableStringValue(json['mbid']),
    searchFingerprint: fingerprintRaw == null
        ? null
        : GroupListeningSearchFingerprint(
            title: stringValue(fingerprintRaw['title']),
            artist: stringValue(fingerprintRaw['artist']),
            album: nullableStringValue(fingerprintRaw['album']),
            durationSeconds: intValue(fingerprintRaw['duration_seconds']),
          ),
    source: _nullableTrackRefSourceFromWire(json['source']),
  );
}

GroupListeningTrackRefKind _trackRefKindFromWire(Object? value) {
  return switch (stringValue(value)) {
    'library_id' => GroupListeningTrackRefKind.libraryId,
    'search_fingerprint' => GroupListeningTrackRefKind.searchFingerprint,
    'mbid' => GroupListeningTrackRefKind.mbid,
    final unknown => throw _protocolFormatFailure(
      'Unsupported Voyage track_ref kind: $unknown.',
    ),
  };
}

String _trackRefKindToWire(GroupListeningTrackRefKind kind) {
  return switch (kind) {
    GroupListeningTrackRefKind.libraryId => 'library_id',
    GroupListeningTrackRefKind.searchFingerprint => 'search_fingerprint',
    GroupListeningTrackRefKind.mbid => 'mbid',
  };
}

GroupListeningTrackRefSource? _nullableTrackRefSourceFromWire(Object? value) {
  final normalized = nullableStringValue(value);
  if (normalized == null) {
    return null;
  }
  return switch (normalized) {
    'navidrome' => GroupListeningTrackRefSource.navidrome,
    'octo_fiesta' => GroupListeningTrackRefSource.octoFiesta,
    'search3_remote' => GroupListeningTrackRefSource.search3Remote,
    _ => null,
  };
}

String _trackRefSourceToWire(GroupListeningTrackRefSource source) {
  return switch (source) {
    GroupListeningTrackRefSource.navidrome => 'navidrome',
    GroupListeningTrackRefSource.octoFiesta => 'octo_fiesta',
    GroupListeningTrackRefSource.search3Remote => 'search3_remote',
  };
}

GroupListeningPlayability _playabilityFromWire(Object? value) {
  return switch (nullableStringValue(value)) {
    'requires_resolution' => GroupListeningPlayability.requiresResolution,
    _ => GroupListeningPlayability.serverAddressable,
  };
}

String _playabilityToWire(GroupListeningPlayability playability) {
  return switch (playability) {
    GroupListeningPlayability.serverAddressable => 'server_addressable',
    GroupListeningPlayability.requiresResolution => 'requires_resolution',
  };
}

GroupListeningErrorState errorStateFromApiError(
  Map<String, dynamic> rawError, {
  String? retryAfterHeader,
}) {
  final details = _mapObjectValue(rawError['details']);
  final roomVersion =
      nullableIntValue(rawError['room_version']) ??
      nullableIntValue(details['room_version']);
  return GroupListeningErrorState(
    code: _errorCodeFromWire(rawError['code']),
    message: stringValue(rawError['message']),
    retryable: boolValue(rawError['retryable']),
    details: details,
    roomVersion: roomVersion,
    retryAfter: _retryAfterFromHeader(retryAfterHeader),
  );
}

GroupListeningErrorState transportDisconnectedFailure(Object error) {
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
  return switch (nullableStringValue(value)) {
    'unsupported_protocol_version' =>
      GroupListeningErrorCode.unsupportedProtocolVersion,
    'unauthorized' => GroupListeningErrorCode.unauthorized,
    'forbidden' => GroupListeningErrorCode.forbidden,
    'room_not_found' => GroupListeningErrorCode.roomNotFound,
    'room_closed' => GroupListeningErrorCode.roomClosed,
    'invite_invalid' => GroupListeningErrorCode.inviteInvalid,
    'invite_expired' => GroupListeningErrorCode.inviteExpired,
    'pin_required' => GroupListeningErrorCode.pinRequired,
    'pin_invalid' => GroupListeningErrorCode.pinInvalid,
    'fingerprint_mismatch' => GroupListeningErrorCode.fingerprintMismatch,
    'stale_version' => GroupListeningErrorCode.staleVersion,
    'sequence_rejected' => GroupListeningErrorCode.sequenceRejected,
    'duplicate_mutation' => GroupListeningErrorCode.duplicateMutation,
    'snapshot_required' => GroupListeningErrorCode.snapshotRequired,
    'playback_rewind_rejected' =>
      GroupListeningErrorCode.playbackRewindRejected,
    'stale_playback_epoch' => GroupListeningErrorCode.stalePlaybackEpoch,
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
  return switch (stringValue(value)) {
    'host' => GroupListeningMemberRole.host,
    'member' => GroupListeningMemberRole.member,
    final unknown => throw _protocolFormatFailure(
      'Unsupported Voyage member role: $unknown.',
    ),
  };
}

GroupListeningMemberPresenceState _presenceStateFromWire(Object? value) {
  return switch (stringValue(value)) {
    'active' => GroupListeningMemberPresenceState.active,
    'stale' => GroupListeningMemberPresenceState.stale,
    'offline' => GroupListeningMemberPresenceState.offline,
    final unknown => throw _protocolFormatFailure(
      'Unsupported Voyage presence state: $unknown.',
    ),
  };
}

GroupListeningRoomStatus roomStatusFromWire(Object? value) {
  return switch (stringValue(value)) {
    'active' => GroupListeningRoomStatus.active,
    'closed' => GroupListeningRoomStatus.closed,
    final unknown => throw _protocolFormatFailure(
      'Unsupported Voyage room status: $unknown.',
    ),
  };
}

GroupListeningRoomMode _roomModeFromWire(Object? value) {
  return switch (nullableStringValue(value)) {
    null || '' => GroupListeningRoomMode.collaborative,
    'collaborative' => GroupListeningRoomMode.collaborative,
    'shotgun' => GroupListeningRoomMode.shotgun,
    'host_only' => GroupListeningRoomMode.hostOnly,
    final unknown => throw _protocolFormatFailure(
      'Unsupported Voyage room mode: $unknown.',
    ),
  };
}

String _roomModeToWire(GroupListeningRoomMode value) {
  return switch (value) {
    GroupListeningRoomMode.collaborative => 'collaborative',
    GroupListeningRoomMode.shotgun => 'shotgun',
    GroupListeningRoomMode.hostOnly => 'host_only',
  };
}

GroupListeningPlaybackStatus _playbackStatusFromWire(Object? value) {
  return switch (stringValue(value)) {
    'playing' => GroupListeningPlaybackStatus.playing,
    'paused' => GroupListeningPlaybackStatus.paused,
    final unknown => throw _protocolFormatFailure(
      'Unsupported Voyage playback state: $unknown.',
    ),
  };
}

GroupListeningPlaybackAnchorReason _anchorReasonFromWire(Object? value) {
  return switch (stringValue(value)) {
    'play' => GroupListeningPlaybackAnchorReason.play,
    'pause' => GroupListeningPlaybackAnchorReason.pause,
    'seek' => GroupListeningPlaybackAnchorReason.seek,
    'track_change' => GroupListeningPlaybackAnchorReason.trackChange,
    'sync_tick' => GroupListeningPlaybackAnchorReason.seek,
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
    GroupListeningPlaybackAnchorReason.snapshot => 'snapshot',
  };
}

GroupListeningRoomEventType _roomEventTypeFromWire(Object? value) {
  return switch (stringValue(value)) {
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
    'room_mode_set' => GroupListeningRoomEventType.roomModeSet,
    'sync_tick' => GroupListeningRoomEventType.seek,
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

void validateProtocolVersion(Object? value) {
  final protocolVersion = nullableStringValue(value) ?? '';
  if (protocolVersion == voyageProtocolVersion ||
      protocolVersion == voyageProtocolVersionV3) {
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

void validateEnvelopeProtocolVersion(Map<String, dynamic> payload) {
  validateProtocolVersion(payload['protocol_version']);
}

String _playbackCommandType(GroupListeningPlaybackAnchorReason reason) {
  switch (reason) {
    case GroupListeningPlaybackAnchorReason.play:
      return 'playback.play';
    case GroupListeningPlaybackAnchorReason.pause:
      return 'playback.pause';
    case GroupListeningPlaybackAnchorReason.trackChange:
      return 'playback.track_change';
    case GroupListeningPlaybackAnchorReason.seek:
    case GroupListeningPlaybackAnchorReason.snapshot:
      return 'playback.seek';
  }
}

Set<String> capabilitySetFromWire(Object? rawCapabilities) {
  if (rawCapabilities is Map) {
    return rawCapabilities.entries
        .where((entry) => entry.value == true)
        .map((entry) => entry.key.toString())
        .toSet();
  }
  return const <String>{};
}

Map<String, dynamic> mapValue(Object? value) {
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
  return mapValue(value);
}

Object? decodeJsonBody(Object? body) {
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

String stringValue(Object? value) {
  final normalized = nullableStringValue(value);
  if (normalized == null) {
    throw const FormatException('Expected a non-empty string value.');
  }
  return normalized;
}

String? nullableStringValue(Object? value) {
  final normalized = value?.toString().trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  return normalized;
}

int intValue(Object? value) {
  final normalized = nullableIntValue(value);
  if (normalized == null) {
    throw const FormatException('Expected an integer value.');
  }
  return normalized;
}

int? nullableIntValue(Object? value) {
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

double? _nullableDoubleValue(Object? value) {
  return switch (value) {
    null => null,
    double value => value,
    num value => value.toDouble(),
    String value => double.tryParse(value.trim()),
    _ => null,
  };
}

bool boolValue(Object? value) {
  return switch (value) {
    bool value => value,
    String value => value.trim().toLowerCase() == 'true',
    num value => value != 0,
    _ => false,
  };
}

bool? _nullableBoolValue(Object? value) {
  return switch (value) {
    null => null,
    bool value => value,
    String value =>
      value.trim().isEmpty ? null : value.trim().toLowerCase() == 'true',
    num value => value != 0,
    _ => null,
  };
}

List<String> stringListValue(Object? value) {
  return (value as List<dynamic>? ?? const <dynamic>[])
      .map((entry) => entry.toString())
      .toList(growable: false);
}

DateTime dateTimeFromEpochMs(Object? value) {
  return DateTime.fromMillisecondsSinceEpoch(intValue(value), isUtc: true);
}

DateTime? nullableDateTimeFromEpochMs(Object? value) {
  final milliseconds = nullableIntValue(value);
  return milliseconds == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
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
