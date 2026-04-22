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
}
