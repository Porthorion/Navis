import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_sync_policy.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_user_intent.dart';

void main() {
  const policy = GroupListeningSyncPolicy();

  group('GroupListeningSyncPolicy', () {
    test('suppresses rewind publish when local is behind remote', () {
      expect(
        policy.shouldApplyInboundInsteadOfPublish(
          queueChanged: false,
          trackChanged: false,
          playingChanged: false,
          localPosition: const Duration(seconds: 10),
          remotePosition: const Duration(seconds: 40),
          slop: const Duration(seconds: 3),
          recentUserIntent: false,
        ),
        isTrue,
      );
    });

    test('allows publish when recent user intent is present', () {
      expect(
        policy.shouldApplyInboundInsteadOfPublish(
          queueChanged: false,
          trackChanged: false,
          playingChanged: false,
          localPosition: const Duration(seconds: 10),
          remotePosition: const Duration(seconds: 40),
          slop: const Duration(seconds: 3),
          recentUserIntent: true,
        ),
        isFalse,
      );
    });

    test('does not publish drift-only sync ticks', () {
      expect(
        policy.resolvePublishReason(
          intent: UserPlaybackIntent.seek,
          queueChanged: false,
          trackChanged: false,
          playingChanged: false,
          positionDelta: const Duration(milliseconds: 200),
          correctionTolerance: const Duration(milliseconds: 500),
        ),
        isNull,
      );
    });

    test('publishes seek on user intent when beyond tolerance', () {
      expect(
        policy.resolvePublishReason(
          intent: UserPlaybackIntent.seek,
          queueChanged: false,
          trackChanged: false,
          playingChanged: false,
          positionDelta: const Duration(milliseconds: 800),
          correctionTolerance: const Duration(milliseconds: 500),
        ),
        GroupListeningPlaybackAnchorReason.seek,
      );
    });

    test('blocks playback anchor mutations during catch-up', () {
      expect(
        policy.blocksOutboundDuringCatchUp(
          catchUpActive: true,
          mutationType: GroupListeningMutationType.playbackAnchor,
        ),
        isTrue,
      );
      expect(
        policy.blocksOutboundDuringCatchUp(
          catchUpActive: true,
          mutationType: GroupListeningMutationType.queueAdd,
        ),
        isFalse,
      );
    });
  });
}
