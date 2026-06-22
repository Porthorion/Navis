import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_mutation_outbox.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_pending_mutation_policy.dart';

void main() {
  const policy = GroupListeningPendingMutationPolicy();

  GroupListeningRoomState snapshot({
    GroupListeningQueueState? queue,
    String hostMemberId = 'host',
    String selfMemberId = 'self',
    List<GroupListeningMemberState>? members,
  }) {
    final joinedAt = DateTime.utc(2026, 4, 21, 12);
    return GroupListeningRoomState(
      protocolVersion: voyageProtocolVersion,
      roomId: 'room-1',
      roomStatus: GroupListeningRoomStatus.active,
      roomVersion: 1,
      presenceVersion: 1,
      authVersion: 1,
      serverTime: joinedAt,
      sourceServerFingerprint: 'fp',
      hostMemberId: hostMemberId,
      self: GroupListeningSelfState(
        memberId: selfMemberId,
        role: GroupListeningMemberRole.member,
        canControl: true,
        authVersion: 1,
      ),
      members:
          members ??
          <GroupListeningMemberState>[
            GroupListeningMemberState(
              memberId: hostMemberId,
              displayName: 'Host',
              deviceLabel: 'device',
              role: GroupListeningMemberRole.host,
              presenceState: GroupListeningMemberPresenceState.active,
              joinedAt: joinedAt,
              lastSeenAt: joinedAt,
            ),
          ],
      queue:
          queue ??
          const GroupListeningQueueState(
            queueVersion: 1,
            currentIndex: -1,
            entries: <GroupListeningQueueEntry>[],
          ),
      playbackAnchor: GroupListeningPlaybackAnchor(
        roomVersion: 1,
        queueVersion: 1,
        currentIndex: -1,
        currentQueueEntryId: '',
        currentSongId: '',
        playbackState: GroupListeningPlaybackStatus.paused,
        position: Duration.zero,
        capturedAt: joinedAt,
        playbackRate: 1,
        reason: GroupListeningPlaybackAnchorReason.snapshot,
        issuedByMemberId: hostMemberId,
      ),
    );
  }

  group('GroupListeningPendingMutationPolicy', () {
    test('drops playback anchor mutations after snapshot', () {
      expect(
        policy.shouldRetain(
          const PendingGroupListeningMutation(
            type: GroupListeningMutationType.playbackAnchor,
            clientMutationId: 'm-1',
          ),
          snapshot(),
        ),
        isFalse,
      );
    });

    test('retains queue remove when entry still exists', () {
      final joinedAt = DateTime.utc(2026, 4, 21, 12);
      final room = snapshot(
        queue: GroupListeningQueueState(
          queueVersion: 1,
          currentIndex: 0,
          entries: <GroupListeningQueueEntry>[
            GroupListeningQueueEntry(
              queueEntryId: 'entry-1',
              songId: 'song-1',
              addedAt: joinedAt,
            ),
          ],
        ),
      );
      expect(
        policy.shouldRetain(
          const PendingGroupListeningMutation(
            type: GroupListeningMutationType.queueRemove,
            clientMutationId: 'm-2',
            targetQueueEntryId: 'entry-1',
          ),
          room,
        ),
        isTrue,
      );
    });

    test('drops queue remove when entry is already gone', () {
      expect(
        policy.shouldRetain(
          const PendingGroupListeningMutation(
            type: GroupListeningMutationType.queueRemove,
            clientMutationId: 'm-3',
            targetQueueEntryId: 'missing',
          ),
          snapshot(),
        ),
        isFalse,
      );
    });

    test('marks playback anchor and queue replace with anchor obsolete', () {
      final joinedAt = DateTime.utc(2026, 4, 21, 12);
      expect(
        policy.isObsoletePlaybackMutation(
          const PendingGroupListeningMutation(
            type: GroupListeningMutationType.playbackAnchor,
            clientMutationId: 'm-4',
          ),
        ),
        isTrue,
      );
      expect(
        policy.isObsoletePlaybackMutation(
          PendingGroupListeningMutation(
            type: GroupListeningMutationType.queueReplace,
            clientMutationId: 'm-5',
            playbackAnchor: GroupListeningPlaybackAnchor(
              roomVersion: 1,
              queueVersion: 1,
              currentIndex: 0,
              currentQueueEntryId: 'entry-1',
              currentSongId: 'song-1',
              playbackState: GroupListeningPlaybackStatus.playing,
              position: Duration.zero,
              capturedAt: joinedAt,
              playbackRate: 1,
              reason: GroupListeningPlaybackAnchorReason.play,
              issuedByMemberId: 'host',
            ),
          ),
        ),
        isTrue,
      );
    });
  });
}
