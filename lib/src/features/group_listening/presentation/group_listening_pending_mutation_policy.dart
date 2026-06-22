import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_mutation_outbox.dart';

/// Decides whether a queued mutation is still worth sending after a snapshot refresh.
class GroupListeningPendingMutationPolicy {
  const GroupListeningPendingMutationPolicy();

  bool shouldRetain(
    PendingGroupListeningMutation mutation,
    GroupListeningRoomState snapshot,
  ) {
    switch (mutation.type) {
      case GroupListeningMutationType.playbackAnchor:
        return false;
      case GroupListeningMutationType.queueAdd:
        final targetQueueEntryId = mutation.targetQueueEntryId;
        final desiredQueue = mutation.queue;
        if (targetQueueEntryId == null ||
            targetQueueEntryId.isEmpty ||
            desiredQueue == null) {
          return false;
        }
        if (_queueContainsEntry(snapshot.queue, targetQueueEntryId)) {
          return false;
        }
        if (!_queueContainsEntry(desiredQueue, targetQueueEntryId)) {
          return false;
        }
        final insertIndex = mutation.insertIndex;
        return insertIndex == null ||
            (insertIndex >= 0 && insertIndex <= snapshot.queue.entries.length);
      case GroupListeningMutationType.queueRemove:
        final targetQueueEntryId = mutation.targetQueueEntryId;
        return targetQueueEntryId != null &&
            targetQueueEntryId.isNotEmpty &&
            _queueContainsEntry(snapshot.queue, targetQueueEntryId);
      case GroupListeningMutationType.queueReplace:
        final desiredQueue = mutation.queue;
        if (desiredQueue == null) {
          return false;
        }
        return !_queueEntryOrderMatches(snapshot.queue, desiredQueue);
      case GroupListeningMutationType.transferHost:
        final targetMember = _activeMember(snapshot, mutation.targetMemberId);
        return targetMember != null &&
            targetMember.memberId != snapshot.hostMemberId;
      case GroupListeningMutationType.removeMember:
        final targetMember = _activeMember(snapshot, mutation.targetMemberId);
        return targetMember != null &&
            targetMember.memberId != snapshot.self.memberId;
    }
  }

  bool isObsoletePlaybackMutation(PendingGroupListeningMutation mutation) {
    return mutation.type == GroupListeningMutationType.playbackAnchor ||
        (mutation.type == GroupListeningMutationType.queueReplace &&
            mutation.playbackAnchor != null);
  }

  bool _queueContainsEntry(
    GroupListeningQueueState queue,
    String queueEntryId,
  ) {
    return queue.entries.any((entry) => entry.queueEntryId == queueEntryId);
  }

  bool _queueEntryOrderMatches(
    GroupListeningQueueState current,
    GroupListeningQueueState desired,
  ) {
    if (current.entries.length != desired.entries.length) {
      return false;
    }
    for (var i = 0; i < current.entries.length; i++) {
      final left = current.entries[i];
      final right = desired.entries[i];
      if (left.queueEntryId != right.queueEntryId ||
          left.songId != right.songId) {
        return false;
      }
    }
    return current.currentIndex == desired.currentIndex;
  }

  GroupListeningMemberState? _activeMember(
    GroupListeningRoomState snapshot,
    String? memberId,
  ) {
    if (memberId == null || memberId.isEmpty) {
      return null;
    }
    for (final member in snapshot.members) {
      if (member.memberId == memberId &&
          member.presenceState == GroupListeningMemberPresenceState.active) {
        return member;
      }
    }
    return null;
  }
}
