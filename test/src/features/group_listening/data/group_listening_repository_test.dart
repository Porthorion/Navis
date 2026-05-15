import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';

void main() {
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
}
