import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_sync_policy.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_user_intent.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_sync_coordinator.dart';

void main() {
  group('GroupListening two-client integration (fake transport)', () {
    test('lagging follower suppresses outbound until epoch aligned', () {
      final coordinator = GroupListeningSyncCoordinator();
      coordinator.isApplyingRemoteState = false;

      expect(
        coordinator.canPublishOutbound(
          catchUpActive: true,
          sessionReady: true,
        ),
        isFalse,
      );

      expect(
        coordinator.canPublishOutbound(
          catchUpActive: false,
          sessionReady: true,
        ),
        isTrue,
      );
    });

    test('user intent maps to publish reasons for host play', () {
      const policy = GroupListeningSyncPolicy();
      expect(
        policy.resolvePublishReason(
          intent: UserPlaybackIntent.play,
          queueChanged: false,
          trackChanged: false,
          playingChanged: true,
          positionDelta: Duration.zero,
          correctionTolerance: const Duration(milliseconds: 500),
        ),
        GroupListeningPlaybackAnchorReason.play,
      );
    });
  });
}
