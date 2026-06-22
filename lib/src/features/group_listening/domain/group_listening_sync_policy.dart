import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_user_intent.dart';

/// Named timing constants for group-listening playback synchronization.
abstract final class GroupListeningSyncTimings {
  static const Duration publishThrottle = Duration(milliseconds: 400);
  static const Duration positionTolerance = Duration(milliseconds: 500);
  static const Duration echoTolerance = Duration(milliseconds: 1500);
  static const Duration localPositionDebounce = Duration(milliseconds: 250);
  static const Duration remoteApplyPublishGate = Duration(milliseconds: 1200);
  static const Duration remoteApplyStableTimeout = Duration(seconds: 6);
  static const Duration recentLocalIntentWindow = Duration(seconds: 3);
  static const Duration catchUpWindow = Duration(seconds: 10);
  static const Duration rewindSlop = Duration(seconds: 3);
}

@immutable
class GroupListeningPlaybackStateView {
  const GroupListeningPlaybackStateView({
    required this.queueSongIds,
    required this.currentIndex,
    required this.currentSongId,
    required this.playing,
    required this.position,
    required this.isRadioMode,
    this.processingStateName = 'ready',
    this.isLoading = false,
    this.loadingSongId,
  });

  final List<String> queueSongIds;
  final int? currentIndex;
  final String? currentSongId;
  final bool playing;
  final Duration position;
  final bool isRadioMode;
  final String processingStateName;
  final bool isLoading;
  final String? loadingSongId;
}

/// Encodes monotonic playback sync rules for the Listen Together bridge.
class GroupListeningSyncPolicy {
  const GroupListeningSyncPolicy();

  Duration correctionTolerance({Duration? roundTripTime}) {
    final rtt = roundTripTime;
    if (rtt == null || rtt <= Duration.zero) {
      return GroupListeningSyncTimings.positionTolerance;
    }
    final extraMs = math.min(1500, rtt.inMilliseconds ~/ 2);
    return Duration(
      milliseconds:
          GroupListeningSyncTimings.positionTolerance.inMilliseconds + extraMs,
    );
  }

  Duration durationDistance(Duration left, Duration right) {
    final delta = left.inMilliseconds - right.inMilliseconds;
    return Duration(milliseconds: delta.abs());
  }

  bool playbackStatesEquivalent(
    GroupListeningPlaybackStateView left,
    GroupListeningPlaybackStateView right, {
    required Duration tolerance,
  }) {
    return listEquals(left.queueSongIds, right.queueSongIds) &&
        left.currentIndex == right.currentIndex &&
        left.currentSongId == right.currentSongId &&
        left.playing == right.playing &&
        left.isRadioMode == right.isRadioMode &&
        durationDistance(left.position, right.position) <= tolerance;
  }

  bool isTransientLocalPlaybackState(
    GroupListeningPlaybackStateView localState,
    GroupListeningPlaybackStateView remoteState,
  ) {
    if (localState.isLoading ||
        localState.processingStateName == 'loading' ||
        localState.processingStateName == 'buffering' ||
        localState.processingStateName == 'idle') {
      return true;
    }
    if (remoteState.queueSongIds.isNotEmpty &&
        (localState.currentIndex != remoteState.currentIndex ||
            localState.currentSongId != remoteState.currentSongId)) {
      return true;
    }
    if (remoteState.position > Duration.zero &&
        localState.position == Duration.zero &&
        !localState.playing) {
      return true;
    }
    return false;
  }

  /// Returns true when local playback is behind the room anchor without a
  /// recent user gesture — outbound publish must be suppressed and inbound
  /// apply preferred instead (anti-rewind).
  bool shouldApplyInboundInsteadOfPublish({
    required bool queueChanged,
    required bool trackChanged,
    required bool playingChanged,
    required Duration localPosition,
    required Duration remotePosition,
    required Duration slop,
    required bool recentUserIntent,
  }) {
    if (queueChanged || trackChanged || playingChanged || recentUserIntent) {
      return false;
    }
    return localPosition + slop < remotePosition;
  }

  GroupListeningPlaybackAnchorReason? resolvePublishReason({
    required UserPlaybackIntent intent,
    required bool queueChanged,
    required bool trackChanged,
    required bool playingChanged,
    required Duration positionDelta,
    required Duration correctionTolerance,
  }) {
    return switch (intent) {
      UserPlaybackIntent.queueAdd ||
      UserPlaybackIntent.queueRemove ||
      UserPlaybackIntent.queueReplace => queueChanged || trackChanged
          ? GroupListeningPlaybackAnchorReason.trackChange
          : null,
      UserPlaybackIntent.play => GroupListeningPlaybackAnchorReason.play,
      UserPlaybackIntent.pause => GroupListeningPlaybackAnchorReason.pause,
      UserPlaybackIntent.seek =>
        positionDelta > correctionTolerance
            ? GroupListeningPlaybackAnchorReason.seek
            : null,
      UserPlaybackIntent.trackChange =>
        GroupListeningPlaybackAnchorReason.trackChange,
    };
  }

  GroupListeningPlaybackAnchorReason resolvePlayingChangeReason({
    required bool playing,
  }) {
    return playing
        ? GroupListeningPlaybackAnchorReason.play
        : GroupListeningPlaybackAnchorReason.pause;
  }

  bool blocksOutboundDuringCatchUp({
    required bool catchUpActive,
    required GroupListeningMutationType mutationType,
  }) {
    if (!catchUpActive) {
      return false;
    }
    return switch (mutationType) {
      GroupListeningMutationType.playbackAnchor => true,
      GroupListeningMutationType.queueReplace => false,
      GroupListeningMutationType.queueAdd => false,
      GroupListeningMutationType.queueRemove => false,
      GroupListeningMutationType.transferHost => false,
      GroupListeningMutationType.removeMember => false,
    };
  }
}
