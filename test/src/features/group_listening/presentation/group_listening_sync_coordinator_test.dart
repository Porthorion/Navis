import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_sync_coordinator.dart';

void main() {
  group('GroupListeningSyncCoordinator', () {
    test('blocks outbound while apply is in flight', () {
      final coordinator = GroupListeningSyncCoordinator();
      coordinator.isApplyingRemoteState = true;
      expect(
        coordinator.canPublishOutbound(
          catchUpActive: false,
          sessionReady: true,
        ),
        isFalse,
      );
    });

    test('blocks outbound during catch-up', () {
      final coordinator = GroupListeningSyncCoordinator();
      expect(
        coordinator.canPublishOutbound(
          catchUpActive: true,
          sessionReady: true,
        ),
        isFalse,
      );
    });

    test('opens outbound gate after remote apply settles', () {
      final coordinator = GroupListeningSyncCoordinator();
      const remote = (
        queueSongIds: <String>['song-1'],
        currentIndex: 0,
        currentSongId: 'song-1',
        playing: true,
        position: Duration(seconds: 10),
        isRadioMode: false,
        processingStateName: 'ready',
        isLoading: false,
        loadingSongId: null,
      );
      coordinator.onApplyGateChanged(true, remote);
      expect(
        coordinator.canPublishOutbound(
          catchUpActive: false,
          sessionReady: true,
        ),
        isFalse,
      );
      coordinator.suppressOutboundUntil = DateTime.now().subtract(
        const Duration(seconds: 2),
      );
      expect(
        coordinator.canPublishOutbound(
          catchUpActive: false,
          sessionReady: true,
        ),
        isTrue,
      );
    });
  });
}
