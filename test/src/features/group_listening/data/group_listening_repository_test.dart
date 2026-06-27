import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';

void main() {
  group('GroupListeningCapabilityDiscovery', () {
    test('detects v4alpha1 replay resume support from capabilities', () {
      const replayDiscovery = GroupListeningCapabilityDiscovery(
        service: 'voyage',
        apiVersion: 'v1',
        serverVersion: '1.0.0',
        buildCommit: 'test',
        buildTime: 'test',
        supportedProtocolVersions: <String>[voyageProtocolVersion],
        latestProtocolVersion: voyageProtocolVersion,
        websocketPath: '/api/v1/rooms/ws',
        heartbeatInterval: Duration(seconds: 10),
        memberStaleTimeout: Duration(seconds: 45),
        capabilities: <String>{voyageReplayResumeCapability},
      );

      expect(replayDiscovery.supportsCurrentProtocol, isTrue);
      expect(replayDiscovery.supportsReplayResume, isTrue);
      expect(replayDiscovery.preferredProtocolVersion, voyageProtocolVersion);
    });
  });

  group('VoyageGroupListeningHttpClient.discover', () {
    test('parses replay resume capabilities from health', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        expect(request.method, 'GET');
        expect(request.uri.path, '/api/v1/health');
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode(<String, Object?>{
              'protocol_version': voyageProtocolVersion,
              'server_time_ms': 1_720_000_000_000,
              'data': <String, Object?>{
                'service': 'voyage',
                'api_version': 'v1',
                'server_version': '1.1.0',
                'build_commit': 'test',
                'build_time': 'test',
                'supported_protocol_versions': <String>[voyageProtocolVersion],
                'latest_protocol_version': voyageProtocolVersion,
                'websocket_path': '/api/v1/rooms/ws',
                'heartbeat_interval_ms': 10000,
                'member_stale_timeout_ms': 45000,
                'capabilities': <String, Object?>{
                  voyageReplayResumeCapability: true,
                },
              },
            }),
          );
        await request.response.close();
      });

      final client = VoyageGroupListeningHttpClient();
      final discovery = await client.discover(
        GroupListeningClientConfiguration(
          voyageBaseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
          sourceServerOrigin: 'https://sub.example.com',
          sourceServerFingerprint: 'fingerprint-1',
          displayName: 'Alice',
          deviceLabel: 'Linux box',
          autoFollowHost: true,
          allowInsecureTransport: true,
        ),
      );

      expect(discovery.supportsReplayResume, isTrue);
      expect(
        discovery.preferredProtocolVersion,
        voyageProtocolVersion,
      );
    });
  });

  group('VoyageGroupListeningHttpClient.rejoinRoom', () {
    test(
      'preserves the stored rejoin token when the server omits it',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async {
          await server.close(force: true);
        });

        server.listen((request) async {
          expect(request.method, 'POST');
          expect(request.uri.path, '/api/v1/rooms/room-1/rejoin');
          final requestBody =
              jsonDecode(
                    await utf8.decoder.bind(request).join(),
                  )
                  as Map<String, dynamic>;
          expect(requestBody['last_applied_room_version'], 41);
          expect(requestBody['last_event_id'], 55);
          expect(
            requestBody['protocol_version'],
            voyageProtocolVersion,
          );

          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode(<String, Object?>{
                'protocol_version': voyageProtocolVersion,
                'server_time_ms': 1_720_000_000_000,
                'data': <String, Object?>{
                  'room_id': 'room-1',
                  'self_member': <String, Object?>{
                    'member_id': 'member-1',
                    'role': 'member',
                    'auth_version': 7,
                    'can_control': true,
                    'can_play_audio': true,
                  },
                  'access_token': 'fresh-access-token',
                  'access_token_expires_at_ms': 1_720_000_300_000,
                  'room_snapshot': <String, Object?>{
                    'protocol_version': voyageProtocolVersion,
                    'room_id': 'room-1',
                    'room_status': 'active',
                    'room_mode': 'collaborative',
                    'requires_pin': false,
                    'room_version': 42,
                    'presence_version': 9,
                    'auth_version': 7,
                    'server_time_ms': 1_720_000_000_000,
                    'source_server_fingerprint': 'fingerprint-1',
                    'host_member_id': 'member-host',
                    'self': <String, Object?>{
                      'member_id': 'member-1',
                      'role': 'member',
                      'can_control': true,
                      'can_play_audio': true,
                    },
                    'members': <Object?>[
                      <String, Object?>{
                        'member_id': 'member-1',
                        'display_name': 'Member',
                        'device_label': 'Linux box',
                        'role': 'member',
                        'presence_state': 'active',
                        'capabilities': <String, Object?>{
                          'queue_add': true,
                        },
                        'joined_at_ms': 1_720_000_000_000,
                        'last_seen_at_ms': 1_720_000_000_000,
                      },
                    ],
                    'queue': <String, Object?>{
                      'queue_version': 1,
                      'current_index': -1,
                      'entries': <Object?>[],
                    },
                    'playback_anchor': <String, Object?>{
                      'room_version': 42,
                      'queue_version': 1,
                      'current_index': -1,
                      'current_queue_entry_id': '',
                      'current_song_id': '',
                      'playback_state': 'paused',
                      'position_ms': 0,
                      'captured_at_ms': 1_720_000_000_000,
                      'playback_rate': 1.0,
                      'reason': 'snapshot',
                      'issued_by_member_id': 'member-host',
                    },
                  },
                },
              }),
            );
          await request.response.close();
        });

        final client = VoyageGroupListeningHttpClient();
        final result = await client.rejoinRoom(
          GroupListeningRejoinRoomRequest(
            configuration: GroupListeningClientConfiguration(
              voyageBaseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
              sourceServerOrigin: 'https://sub.example.com',
              sourceServerFingerprint: 'fingerprint-1',
              displayName: 'Alice',
              deviceLabel: 'Linux box',
              autoFollowHost: true,
              allowInsecureTransport: true,
              protocolVersion: voyageProtocolVersion,
            ),
            session: GroupListeningStoredSession(
              roomId: 'room-1',
              memberId: 'member-1',
              role: GroupListeningMemberRole.member,
              authVersion: 6,
              voyageBaseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
              sourceServerFingerprint: 'fingerprint-1',
              rejoinToken: 'stored-rejoin-token',
              client: const GroupListeningClientDescriptor(
                appVersion: '1.0.0',
                platform: 'linux',
                deviceId: 'device-1',
                deviceLabel: 'Linux box',
                capabilities: <String>{'queue_add'},
              ),
              lastAppliedRoomVersion: 41,
              lastAppliedEventId: 55,
              protocolVersion: voyageProtocolVersion,
            ),
          ),
        );

        expect(result.runtimeContext.rejoinToken, 'stored-rejoin-token');
        expect(result.runtimeContext.accessToken, 'fresh-access-token');
        expect(result.roomSnapshot.roomId, 'room-1');
        expect(result.roomSnapshot.roomVersion, 42);
      },
    );
  });

  group('IOWebSocketGroupListeningRealtimeTransportClient', () {
    test('sends connection.init when connecting with v4alpha1', () async {
      final initCompleter = Completer<Map<String, dynamic>>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        expect(request.uri.path, '/api/v1/rooms/room-1/ws');
        final socket = await WebSocketTransformer.upgrade(
          request,
          protocolSelector: (protocols) {
            expect(protocols, contains(voyageProtocolVersion));
            return voyageProtocolVersion;
          },
        );
        final rawInit = await socket.first as String;
        initCompleter.complete(
          jsonDecode(rawInit) as Map<String, dynamic>,
        );
        await socket.close();
      });

      const client = IOWebSocketGroupListeningRealtimeTransportClient();
      final connection = await client.connect(
        GroupListeningTransportConnectRequest(
          session: _runtimeContext(
            Uri.parse('http://127.0.0.1:${server.port}'),
            protocolVersion: voyageProtocolVersion,
          ),
          lastAppliedRoomVersion: 12,
          lastAppliedEventId: 34,
          lastAppliedQueueVersion: 5,
          lastAppliedPresenceVersion: 6,
        ),
      );
      addTearDown(connection.disconnect);

      final init = await initCompleter.future.timeout(
        const Duration(seconds: 2),
      );
      expect(init['type'], 'connection.init');
      final data = init['data'] as Map<String, dynamic>;
      expect(data['last_event_id'], 34);
      expect(data['last_applied_room_version'], 12);
      expect(data['last_applied_queue_version'], 5);
      expect(data['last_applied_presence_version'], 6);
      expect(data['client_time_ms'], isA<int>());
    });

    test('serializes mutation domain base versions', () async {
      final mutationCompleter = Completer<Map<String, dynamic>>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(
          request,
          protocolSelector: (_) => voyageProtocolVersion,
        );
        final messages = StreamIterator<dynamic>(socket);
        await messages.moveNext();
        await messages.moveNext();
        final rawMutation = messages.current as String;
        mutationCompleter.complete(
          jsonDecode(rawMutation) as Map<String, dynamic>,
        );
        await socket.close();
      });

      const client = IOWebSocketGroupListeningRealtimeTransportClient();
      final connection = await client.connect(
        GroupListeningTransportConnectRequest(
          session: _runtimeContext(
            Uri.parse('http://127.0.0.1:${server.port}'),
          ),
          lastAppliedRoomVersion: 12,
        ),
      );
      addTearDown(connection.disconnect);

      await connection.send(
        GroupListeningMutationMessage(
          type: GroupListeningMutationType.playbackAnchor,
          expectedRoomVersion: 12,
          expectedQueueVersion: 7,
          expectedPlaybackVersion: 9,
          clientMutationId: 'mut-1',
          clientConnectionId: 'conn-1',
          clientSequence: 1,
          playbackAnchor: GroupListeningPlaybackAnchor(
            roomVersion: 12,
            queueVersion: 7,
            currentIndex: 0,
            currentQueueEntryId: 'entry-1',
            currentSongId: 'song-1',
            playbackState: GroupListeningPlaybackStatus.playing,
            position: const Duration(seconds: 4),
            capturedAt: DateTime.utc(2026, 4, 21, 12),
            playbackRate: 1,
            reason: GroupListeningPlaybackAnchorReason.trackChange,
            issuedByMemberId: 'member-1',
          ),
        ),
      );

      final mutation = await mutationCompleter.future.timeout(
        const Duration(seconds: 2),
      );
      expect(mutation['type'], 'command');
      final data = mutation['data'] as Map<String, dynamic>;
      expect(data['type'], 'playback.track_change');
      expect(data['command_id'], 'mut-1');
      expect(data['base_event_id'], 12);
      expect(data['expected_room_version'], 12);
      expect(data['expected_queue_version'], 7);
      expect(data['expected_playback_version'], 9);
    });

    test('serializes client status diagnostics frame', () async {
      final statusCompleter = Completer<Map<String, dynamic>>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await server.close(force: true);
      });

      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(
          request,
          protocolSelector: (_) => voyageProtocolVersion,
        );
        final messages = StreamIterator<dynamic>(socket);
        await messages.moveNext();
        await messages.moveNext();
        statusCompleter.complete(
          jsonDecode(messages.current as String) as Map<String, dynamic>,
        );
        await socket.close();
      });

      const client = IOWebSocketGroupListeningRealtimeTransportClient();
      final connection = await client.connect(
        GroupListeningTransportConnectRequest(
          session: _runtimeContext(
            Uri.parse('http://127.0.0.1:${server.port}'),
          ),
          lastAppliedRoomVersion: 12,
        ),
      );
      addTearDown(connection.disconnect);

      await connection.send(
        GroupListeningClientStatusMessage(
          clientConnectionId: 'conn-1',
          lastAppliedPlaybackApplyId: 7,
          observedQueueEntryId: 'entry-1',
          observedCurrentIndex: 2,
          localProcessingState: 'buffering',
          loadingAge: const Duration(milliseconds: 250),
          clientTime: DateTime.utc(2026, 4, 21, 12),
        ),
      );

      final status = await statusCompleter.future.timeout(
        const Duration(seconds: 2),
      );
      expect(status['type'], 'member.status');
      final data = status['data'] as Map<String, dynamic>;
      expect(data['last_applied_playback_apply_id'], 7);
      expect(data['observed_queue_entry_id'], 'entry-1');
      expect(data['observed_current_index'], 2);
      expect(data['local_processing_state'], 'buffering');
      expect(data['loading_age_ms'], 250);
      expect(data['client_time_ms'], isA<int>());
    });

    test(
      'parses v4alpha1 ready, snapshot, and numeric event cursors',
      () async {
        final readyToSend = Completer<void>();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() async {
          await server.close(force: true);
        });

        server.listen((request) async {
          final socket = await WebSocketTransformer.upgrade(
            request,
            protocolSelector: (_) => voyageProtocolVersion,
          );
          await socket.first;
          await readyToSend.future;
          socket
            ..add(
              jsonEncode(
                _transportEnvelope(
                  'connection.ready',
                  <String, Object?>{
                    'client_connection_id': 'conn-1',
                    'resume_status': 'replay_then_live',
                    'server_time_ms': 1_720_000_000_000,
                    'latest_event_id': 8,
                    'min_available_event_id': 3,
                    'room_version': 4,
                    'queue_version': 2,
                    'presence_version': 5,
                    'auth_version': 6,
                    'heartbeat_policy': <String, Object?>{
                      'interval_ms': 10000,
                      'member_stale_timeout_ms': 45000,
                    },
                  },
                ),
              ),
            )
            ..add(
              jsonEncode(
                _transportEnvelope(
                  'room.snapshot',
                  _snapshotPayload(latestEventId: 8),
                ),
              ),
            )
            ..add(
              jsonEncode(
                _transportEnvelope(
                  'room.event',
                  _eventPayload(eventId: 9),
                ),
              ),
            );
        });

        const client = IOWebSocketGroupListeningRealtimeTransportClient();
        final connection = await client.connect(
          GroupListeningTransportConnectRequest(
            session: _runtimeContext(
              Uri.parse('http://127.0.0.1:${server.port}'),
              protocolVersion: voyageProtocolVersion,
            ),
            lastAppliedRoomVersion: 3,
            lastAppliedEventId: 8,
          ),
        );
        addTearDown(connection.disconnect);

        final messagesFuture = connection.messages.take(3).toList();
        readyToSend.complete();
        final messages = await messagesFuture.timeout(
          const Duration(seconds: 2),
        );

        final ready = messages[0] as GroupListeningConnectionReadyMessage;
        expect(ready.resumeStatus, 'replay_then_live');
        expect(ready.latestEventId, 8);
        expect(ready.minAvailableEventId, 3);

        final snapshot = messages[1] as GroupListeningRoomSnapshotMessage;
        expect(snapshot.snapshot.latestEventId, 8);
        expect(snapshot.snapshot.playbackApplyId, 11);

        final event = messages[2] as GroupListeningRoomEventMessage;
        expect(event.event.eventId, '9');
        expect(event.event.eventCursor, 9);
        expect(event.event.playbackApplyId, 12);
      },
    );
  });
}

GroupListeningSessionRuntimeContext _runtimeContext(
  Uri voyageBaseUrl, {
  String protocolVersion = voyageProtocolVersion,
}) {
  return GroupListeningSessionRuntimeContext(
    roomId: 'room-1',
    memberId: 'member-1',
    role: GroupListeningMemberRole.host,
    authVersion: 1,
    voyageBaseUrl: voyageBaseUrl,
    sourceServerFingerprint: 'fingerprint-1',
    accessToken: 'access-token',
    accessTokenExpiresAt: DateTime.utc(2026, 4, 21, 13),
    rejoinToken: 'rejoin-token',
    protocolVersion: protocolVersion,
  );
}

Map<String, Object?> _transportEnvelope(
  String type,
  Map<String, Object?> data,
) {
  return <String, Object?>{
    'protocol_version': voyageProtocolVersion,
    'type': type,
    'server_time_ms': 1_720_000_000_000,
    'data': data,
  };
}

Map<String, Object?> _snapshotPayload({required int latestEventId}) {
  return <String, Object?>{
    'protocol_version': voyageProtocolVersion,
    'room_id': 'room-1',
    'room_status': 'active',
    'room_mode': 'collaborative',
    'requires_pin': false,
    'room_version': 4,
    'latest_event_id': latestEventId,
    'playback_version': 10,
    'playback_apply_id': 11,
    'presence_version': 5,
    'auth_version': 6,
    'server_time_ms': 1_720_000_000_000,
    'source_server_fingerprint': 'fingerprint-1',
    'host_member_id': 'member-1',
    'self': <String, Object?>{
      'member_id': 'member-1',
      'role': 'host',
      'can_control': true,
      'can_play_audio': true,
    },
    'members': <Object?>[
      <String, Object?>{
        'member_id': 'member-1',
        'display_name': 'Alice',
        'device_label': 'Linux box',
        'role': 'host',
        'presence_state': 'active',
        'capabilities': <String, Object?>{
          'playback_anchor': true,
        },
        'joined_at_ms': 1_720_000_000_000,
        'last_seen_at_ms': 1_720_000_000_000,
      },
    ],
    'queue': <String, Object?>{
      'queue_version': 2,
      'current_index': -1,
      'entries': <Object?>[],
    },
  };
}

Map<String, Object?> _eventPayload({required int eventId}) {
  return <String, Object?>{
    'event_id': eventId,
    'event_type': 'seek',
    'room_id': 'room-1',
    'previous_room_version': 4,
    'room_version': 5,
    'playback_version': 12,
    'playback_apply_id': 12,
    'presence_version': 5,
    'auth_version': 6,
    'members': <Object?>[
      <String, Object?>{
        'member_id': 'member-1',
        'display_name': 'Alice',
        'device_label': 'Linux box',
        'role': 'host',
        'presence_state': 'active',
        'capabilities': <String, Object?>{
          'playback_anchor': true,
        },
        'joined_at_ms': 1_720_000_000_000,
        'last_seen_at_ms': 1_720_000_000_000,
      },
    ],
  };
}
