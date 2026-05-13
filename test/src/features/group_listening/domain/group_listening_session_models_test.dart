import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/group_listening/data/group_listening_configuration.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';

void main() {
  group('group listening configuration', () {
    const activeServer = ServerConfigModel(
      url: 'HTTPS://Sub.Example.com:443/navidrome/?ignored=yes',
      username: 'alice',
      password: 'secret',
      apiVersion: '1.16.1',
    );

    test(
      'canonicalizes the active server origin for same-server fingerprinting',
      () {
        expect(
          canonicalizeSourceServerOrigin(activeServer.url),
          'https://sub.example.com/navidrome',
        );
        expect(computeSourceServerFingerprint(activeServer.url), isNotEmpty);
      },
    );

    test('builds a ready client configuration from active server identity', () {
      final configuration = buildGroupListeningClientConfiguration(
        enabled: true,
        voyageServerUrl: 'https://voyage.example.com/',
        activeServer: activeServer,
      );

      expect(configuration, isNotNull);
      expect(configuration!.displayName, 'alice');
      expect(configuration.deviceLabel, isNotEmpty);
      expect(configuration.autoFollowHost, isTrue);
      expect(
        configuration.voyageBaseUrl.toString(),
        'https://voyage.example.com',
      );
      expect(
        configuration.sourceServerOrigin,
        'https://sub.example.com/navidrome',
      );
    });
  });

  group('GroupListeningPlaybackAnchor', () {
    test('projects elapsed position only while playing', () {
      final capturedAt = DateTime.utc(2026, 4, 21, 12);
      final playingAnchor = GroupListeningPlaybackAnchor(
        roomVersion: 3,
        queueVersion: 2,
        currentIndex: 0,
        currentQueueEntryId: 'entry-1',
        currentSongId: 'song-1',
        playbackState: GroupListeningPlaybackStatus.playing,
        position: const Duration(seconds: 30),
        capturedAt: capturedAt,
        playbackRate: 1.5,
        reason: GroupListeningPlaybackAnchorReason.play,
        issuedByMemberId: 'host-1',
      );
      final pausedAnchor = GroupListeningPlaybackAnchor(
        roomVersion: 3,
        queueVersion: 2,
        currentIndex: 0,
        currentQueueEntryId: 'entry-1',
        currentSongId: 'song-1',
        playbackState: GroupListeningPlaybackStatus.paused,
        position: const Duration(seconds: 30),
        capturedAt: capturedAt,
        playbackRate: 1.5,
        reason: GroupListeningPlaybackAnchorReason.pause,
        issuedByMemberId: 'host-1',
      );

      expect(
        playingAnchor.expectedPositionAt(
          capturedAt.add(const Duration(seconds: 4)),
        ),
        const Duration(seconds: 36),
      );
      expect(
        pausedAnchor.expectedPositionAt(
          capturedAt.add(const Duration(seconds: 4)),
        ),
        const Duration(seconds: 30),
      );
    });
  });

  group('GroupListeningRoomState', () {
    test('exposes host and presence-aware member counts', () {
      final now = DateTime.utc(2026, 4, 21, 12);
      final room = GroupListeningRoomState(
        protocolVersion: voyageProtocolVersion,
        roomId: 'room-1',
        roomStatus: GroupListeningRoomStatus.active,
        roomVersion: 1,
        presenceVersion: 1,
        authVersion: 1,
        serverTime: now,
        sourceServerFingerprint: 'fingerprint',
        hostMemberId: 'member-1',
        self: const GroupListeningSelfState(
          memberId: 'member-1',
          role: GroupListeningMemberRole.host,
          canControl: true,
          authVersion: 1,
        ),
        members: <GroupListeningMemberState>[
          GroupListeningMemberState(
            memberId: 'member-1',
            displayName: 'Alice',
            role: GroupListeningMemberRole.host,
            presenceState: GroupListeningMemberPresenceState.active,
            joinedAt: now,
            lastSeenAt: now,
          ),
          GroupListeningMemberState(
            memberId: 'member-2',
            displayName: 'Bob',
            role: GroupListeningMemberRole.member,
            presenceState: GroupListeningMemberPresenceState.stale,
            joinedAt: now,
            lastSeenAt: now,
          ),
        ],
        queue: const GroupListeningQueueState(
          queueVersion: 1,
          currentIndex: 0,
          entries: <GroupListeningQueueEntry>[],
        ),
        playbackAnchor: GroupListeningPlaybackAnchor(
          roomVersion: 1,
          queueVersion: 1,
          currentIndex: 0,
          currentQueueEntryId: null,
          currentSongId: null,
          playbackState: GroupListeningPlaybackStatus.paused,
          position: Duration.zero,
          capturedAt: now,
          playbackRate: 1,
          reason: GroupListeningPlaybackAnchorReason.snapshot,
          issuedByMemberId: 'member-1',
        ),
      );

      expect(room.hostMember?.displayName, 'Alice');
      expect(room.activeMemberCount, 1);
      expect(room.staleMemberCount, 1);
    });
  });
}
