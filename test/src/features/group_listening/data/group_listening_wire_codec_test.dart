import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/data/group_listening_wire_codec.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';

void main() {
  group('group_listening_wire_codec', () {
    test('stored session round-trips through json helpers', () {
      final session = GroupListeningStoredSession(
        roomId: 'room-1',
        memberId: 'member-1',
        role: GroupListeningMemberRole.host,
        authVersion: 3,
        voyageBaseUrl: Uri.parse('https://voyage.example.com'),
        sourceServerFingerprint: 'fingerprint-1',
        rejoinToken: 'rejoin-token',
        client: const GroupListeningClientDescriptor(
          appVersion: '1.0.0',
          platform: 'linux',
          deviceId: 'device-1',
          deviceLabel: 'Linux box',
          capabilities: <String>{'queue_add'},
        ),
        lastAppliedRoomVersion: 12,
        lastAppliedEventId: 34,
        protocolVersion: voyageProtocolVersion,
      );

      final restored = storedSessionFromJson(storedSessionToJson(session));

      expect(restored.roomId, session.roomId);
      expect(restored.memberId, session.memberId);
      expect(restored.role, session.role);
      expect(restored.authVersion, session.authVersion);
      expect(restored.voyageBaseUrl, session.voyageBaseUrl);
      expect(restored.sourceServerFingerprint, session.sourceServerFingerprint);
      expect(restored.rejoinToken, session.rejoinToken);
      expect(restored.lastAppliedRoomVersion, session.lastAppliedRoomVersion);
      expect(restored.lastAppliedEventId, session.lastAppliedEventId);
      expect(restored.protocolVersion, session.protocolVersion);
      expect(restored.client.deviceId, session.client.deviceId);
    });

    test('decodeJsonBody unwraps string payloads', () {
      expect(
        decodeJsonBody('{"ok":true}'),
        <String, dynamic>{'ok': true},
      );
      expect(
        decodeJsonBody(<String, dynamic>{'ok': true}),
        <String, dynamic>{'ok': true},
      );
    });
  });
}
