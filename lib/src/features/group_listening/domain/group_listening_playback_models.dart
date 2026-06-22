import 'package:flutter/foundation.dart';

enum GroupListeningPlaybackStatus { playing, paused }

enum GroupListeningPlaybackAnchorReason {
  play,
  pause,
  seek,
  trackChange,
  snapshot,
}

@immutable
class GroupListeningPlaybackAnchor {
  const GroupListeningPlaybackAnchor({
    required this.roomVersion,
    required this.queueVersion,
    required this.currentIndex,
    required this.currentQueueEntryId,
    required this.currentSongId,
    required this.playbackState,
    required this.position,
    required this.capturedAt,
    required this.playbackRate,
    required this.reason,
    this.playbackApplyId,
    this.playbackEpoch = 0,
    this.issuedByMemberId,
    this.issuedByConnectionId,
  });

  final int roomVersion;
  final int queueVersion;
  final int? playbackApplyId;
  final int playbackEpoch;
  final int? currentIndex;
  final String? currentQueueEntryId;
  final String? currentSongId;
  final GroupListeningPlaybackStatus playbackState;
  final Duration position;
  final DateTime capturedAt;
  final double playbackRate;
  final GroupListeningPlaybackAnchorReason reason;
  final String? issuedByMemberId;
  final String? issuedByConnectionId;

  Duration expectedPositionAt(DateTime now) {
    if (playbackState == GroupListeningPlaybackStatus.paused) {
      return position;
    }
    final elapsed = now.difference(capturedAt);
    final projectedMs =
        position.inMilliseconds + (elapsed.inMilliseconds * playbackRate);
    return Duration(milliseconds: projectedMs.round().clamp(0, 1 << 31));
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupListeningPlaybackAnchor &&
          runtimeType == other.runtimeType &&
          roomVersion == other.roomVersion &&
          queueVersion == other.queueVersion &&
          playbackApplyId == other.playbackApplyId &&
          playbackEpoch == other.playbackEpoch &&
          currentIndex == other.currentIndex &&
          currentQueueEntryId == other.currentQueueEntryId &&
          currentSongId == other.currentSongId &&
          playbackState == other.playbackState &&
          position == other.position &&
          capturedAt == other.capturedAt &&
          playbackRate == other.playbackRate &&
          reason == other.reason &&
          issuedByMemberId == other.issuedByMemberId &&
          issuedByConnectionId == other.issuedByConnectionId;

  @override
  int get hashCode => Object.hash(
    roomVersion,
    queueVersion,
    playbackApplyId,
    playbackEpoch,
    currentIndex,
    currentQueueEntryId,
    currentSongId,
    playbackState,
    position,
    capturedAt,
    playbackRate,
    reason,
    issuedByMemberId,
    issuedByConnectionId,
  );
}
