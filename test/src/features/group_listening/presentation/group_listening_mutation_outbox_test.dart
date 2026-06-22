import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_mutation_outbox.dart';

void main() {
  group('GroupListeningMutationOutbox', () {
    test('coalesces duplicate playback anchor mutations while paused', () {
      final sent = <GroupListeningMutationType>[];
      final outbox = GroupListeningMutationOutbox(
        send: (mutation, message) async {
          sent.add(mutation.type);
        },
        canSendType: (_) => true,
        expectedQueueVersion: (_, {playbackAnchor}) => 1,
        expectedPlaybackVersion: (_, {playbackAnchor}) => 1,
        expectedPlaybackEpoch: () => 0,
        nextClientSequence: () => 1,
        readClientConnectionId: () => 'conn-1',
        isConnected: () => true,
        readLastAppliedRoomVersion: () => 1,
      );

      outbox.pause();
      outbox.enqueue(
        const PendingGroupListeningMutation(
          type: GroupListeningMutationType.playbackAnchor,
          clientMutationId: 'a',
        ),
      );
      outbox.enqueue(
        const PendingGroupListeningMutation(
          type: GroupListeningMutationType.playbackAnchor,
          clientMutationId: 'b',
        ),
      );

      expect(sent, isEmpty);
      expect(outbox.pending, hasLength(1));
      expect(outbox.pending.single.clientMutationId, 'b');
    });

    test('handleAck clears in-flight and dispatches next mutation', () async {
      final sentIds = <String>[];
      final outbox = GroupListeningMutationOutbox(
        send: (mutation, message) async {
          sentIds.add(mutation.clientMutationId);
        },
        canSendType: (_) => true,
        expectedQueueVersion: (_, {playbackAnchor}) => 1,
        expectedPlaybackVersion: (_, {playbackAnchor}) => 1,
        expectedPlaybackEpoch: () => 0,
        nextClientSequence: () => 1,
        readClientConnectionId: () => 'conn-1',
        isConnected: () => true,
        readLastAppliedRoomVersion: () => 1,
      );

      outbox.pause();
      outbox.enqueue(
        const PendingGroupListeningMutation(
          type: GroupListeningMutationType.queueRemove,
          clientMutationId: 'first',
          targetQueueEntryId: 'entry-1',
        ),
      );
      outbox.enqueue(
        const PendingGroupListeningMutation(
          type: GroupListeningMutationType.queueRemove,
          clientMutationId: 'second',
          targetQueueEntryId: 'entry-2',
        ),
      );
      outbox.resume();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(sentIds, <String>['first']);

      outbox.handleAck('first');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(sentIds, <String>['first', 'second']);
    });
  });
}
