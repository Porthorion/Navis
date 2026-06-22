import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_playback_state_mapper.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

bool isPrefixOf(List<String> prefix, List<String> full) {
  if (prefix.length > full.length) {
    return false;
  }
  for (var i = 0; i < prefix.length; i++) {
    if (prefix[i] != full[i]) {
      return false;
    }
  }
  return true;
}

({
  GroupListeningMutationType type,
  String queueEntryId,
})? granularQueueMutation({
  required GroupListeningRoomState room,
  required GroupListeningQueueState queueState,
  required BridgePlaybackState localState,
  required BridgePlaybackState remoteState,
}) {
  if (localState.queueSongIds.length == remoteState.queueSongIds.length + 1 &&
      localState.currentIndex == remoteState.currentIndex &&
      isPrefixOf(remoteState.queueSongIds, localState.queueSongIds)) {
    return (
      type: GroupListeningMutationType.queueAdd,
      queueEntryId: queueState.entries[remoteState.queueSongIds.length].queueEntryId,
    );
  }
  if (localState.queueSongIds.length + 1 == remoteState.queueSongIds.length) {
    for (var i = 0; i < remoteState.queueSongIds.length; i++) {
      final projected = List<String>.of(remoteState.queueSongIds)..removeAt(i);
      if (listEquals(projected, localState.queueSongIds) &&
          i < room.queue.entries.length) {
        return (
          type: GroupListeningMutationType.queueRemove,
          queueEntryId: room.queue.entries[i].queueEntryId,
        );
      }
    }
  }
  return null;
}

GroupListeningQueueState queueStateFromLocalState({
  required GroupListeningRoomState room,
  required BridgePlaybackState localState,
  required String memberId,
}) {
  final existingEntriesBySongId =
      <String, ListQueue<GroupListeningQueueEntry>>{};
  for (final entry in room.queue.entries) {
    existingEntriesBySongId
        .putIfAbsent(entry.songId, ListQueue<GroupListeningQueueEntry>.new)
        .add(entry);
  }
  final now = DateTime.now();
  final entries = <GroupListeningQueueEntry>[];
  for (final songId in localState.queueSongIds) {
    final existingEntries = existingEntriesBySongId[songId];
    if (existingEntries != null && existingEntries.isNotEmpty) {
      entries.add(existingEntries.removeFirst());
      continue;
    }
    entries.add(
      GroupListeningQueueEntry(
        queueEntryId: _uuid.v4(),
        songId: songId,
        addedByMemberId: memberId,
        addedAt: now,
      ),
    );
  }
  return GroupListeningQueueState(
    queueVersion: room.queue.queueVersion,
    currentIndex: localState.currentIndex,
    entries: List<GroupListeningQueueEntry>.unmodifiable(entries),
  );
}
