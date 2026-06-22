import 'package:flutter/foundation.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_sync_policy.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_playback_state_mapper.dart';

/// Owns apply-in-flight state and outbound suppression for Listen Together sync.
class GroupListeningSyncCoordinator {
  GroupListeningSyncCoordinator({GroupListeningSyncPolicy? syncPolicy})
    : _syncPolicy = syncPolicy ?? const GroupListeningSyncPolicy();

  final GroupListeningSyncPolicy _syncPolicy;

  bool isApplyingRemoteState = false;
  BridgePlaybackState? queuedRemoteState;
  bool queuedFollowPlayback = false;
  DateTime? suppressOutboundUntil;
  BridgePlaybackState? remoteApplyGateState;
  DateTime? remoteApplyGateDeadline;
  BridgePlaybackState? lastPublishedState;
  BridgePlaybackState? suppressedEchoState;
  DateTime? lastPublishedAt;

  bool get canApplyNow => !isApplyingRemoteState;

  void queueInboundApply(
    BridgePlaybackState remoteState, {
    required bool followPlayback,
  }) {
    queuedRemoteState = remoteState;
    queuedFollowPlayback = queuedFollowPlayback || followPlayback;
  }

  void clearQueuedInboundApply() {
    queuedRemoteState = null;
    queuedFollowPlayback = false;
  }

  void onApplyGateChanged(bool gateOutbound, BridgePlaybackState remoteState) {
    if (!gateOutbound) {
      return;
    }
    suppressOutboundUntil = DateTime.now().add(
      GroupListeningSyncTimings.remoteApplyPublishGate,
    );
    remoteApplyGateState = remoteState;
    remoteApplyGateDeadline = DateTime.now().add(
      GroupListeningSyncTimings.remoteApplyStableTimeout,
    );
  }

  void resetForRoomChange() {
    suppressOutboundUntil = null;
    remoteApplyGateState = null;
    remoteApplyGateDeadline = null;
    lastPublishedState = null;
    suppressedEchoState = null;
    lastPublishedAt = null;
    clearQueuedInboundApply();
  }

  bool canPublishOutbound({
    required bool catchUpActive,
    required bool sessionReady,
  }) {
    if (isApplyingRemoteState || catchUpActive || !sessionReady) {
      return false;
    }
    final suppressUntil = suppressOutboundUntil;
    if (suppressUntil != null && DateTime.now().isBefore(suppressUntil)) {
      return false;
    }
    return true;
  }

  bool isRemoteApplyGateBlocking({
    required BridgePlaybackState localState,
    required BridgePlaybackState latestRemoteState,
    required Duration correctionTolerance,
    required bool recentUserIntent,
    required bool Function(BridgePlaybackState local, BridgePlaybackState remote)
    isTransientLocalPlaybackState,
    required bool Function(
      BridgePlaybackState left,
      BridgePlaybackState right,
      Duration tolerance,
    )
    playbackStatesEquivalent,
    required void Function() requestInboundReconcile,
  }) {
    final gateState = remoteApplyGateState;
    final deadline = remoteApplyGateDeadline;
    if (gateState == null || deadline == null) {
      return false;
    }

    if (_localPlayerReachedRemoteState(
      localState,
      gateState,
      isTransientLocalPlaybackState: isTransientLocalPlaybackState,
    )) {
      remoteApplyGateState = null;
      remoteApplyGateDeadline = null;
      return false;
    }

    final now = DateTime.now();
    final transient = isTransientLocalPlaybackState(localState, gateState);
    if (now.isBefore(deadline) || transient) {
      return true;
    }

    if (!playbackStatesEquivalent(
      localState,
      latestRemoteState,
      correctionTolerance,
    )) {
      if (recentUserIntent) {
        remoteApplyGateState = null;
        remoteApplyGateDeadline = null;
        return false;
      }
      remoteApplyGateDeadline = now.add(
        GroupListeningSyncTimings.remoteApplyStableTimeout,
      );
      requestInboundReconcile();
      return true;
    }

    remoteApplyGateState = null;
    remoteApplyGateDeadline = null;
    return false;
  }

  bool _localPlayerReachedRemoteState(
    BridgePlaybackState localState,
    BridgePlaybackState remoteState, {
    required bool Function(BridgePlaybackState local, BridgePlaybackState remote)
    isTransientLocalPlaybackState,
  }) {
    return listEquals(localState.queueSongIds, remoteState.queueSongIds) &&
        localState.currentIndex == remoteState.currentIndex &&
        localState.currentSongId == remoteState.currentSongId &&
        !isTransientLocalPlaybackState(localState, remoteState);
  }
}
