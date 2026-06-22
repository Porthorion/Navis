import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';

void main() {
  group('GroupListeningSessionState playback epoch', () {
    final serverTime = DateTime.utc(2026, 1, 1);

    GroupListeningSessionState buildSession({
      required int localEpoch,
      required int serverEpoch,
      required bool aligned,
    }) {
      return GroupListeningSessionState(
        availability: GroupListeningAvailability.ready,
        status: GroupListeningSessionStatus.connected,
        connection: const GroupListeningConnectionState(
          status: GroupListeningConnectionStatus.connected,
        ),
        localPlaybackEpoch: localEpoch,
        catchUpAligned: aligned,
        room: GroupListeningRoomState(
          protocolVersion: voyageProtocolVersionV3,
          roomId: 'room-1',
          roomStatus: GroupListeningRoomStatus.active,
          roomVersion: 1,
          playbackEpoch: serverEpoch,
          presenceVersion: 1,
          authVersion: 1,
          serverTime: serverTime,
          sourceServerFingerprint: 'fp',
          hostMemberId: 'host',
          self: const GroupListeningSelfState(
            memberId: 'member',
            role: GroupListeningMemberRole.member,
            canControl: true,
            authVersion: 1,
          ),
          members: const <GroupListeningMemberState>[],
          queue: const GroupListeningQueueState(queueVersion: 0),
        ),
      );
    }

    test('catch-up active when local epoch lags server', () {
      final session = buildSession(localEpoch: 1, serverEpoch: 3, aligned: true);
      expect(session.isCatchUpActive, isTrue);
    });

    test('catch-up active when not position aligned', () {
      final session = buildSession(localEpoch: 3, serverEpoch: 3, aligned: false);
      expect(session.isCatchUpActive, isTrue);
    });

    test('synced when epoch matches and aligned', () {
      final session = buildSession(localEpoch: 3, serverEpoch: 3, aligned: true);
      expect(session.isCatchUpActive, isFalse);
    });
  });
}
