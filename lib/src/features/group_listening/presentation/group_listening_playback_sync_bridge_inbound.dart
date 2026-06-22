import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_sync_policy.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_user_intent.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_playback_follower.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_playback_state_mapper.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_controller.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_sync_coordinator.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';

class GroupListeningPlaybackSyncBridgeInbound {
  GroupListeningPlaybackSyncBridgeInbound({
    required this.ref,
    required this.syncPolicy,
    required this.coordinator,
    required this.stateMapper,
    required this.follower,
    required this.getLastObservedQueueVersion,
    required this.setLastObservedQueueVersion,
    required this.getLastObservedPlaybackApplyId,
    required this.setLastObservedPlaybackApplyId,
    required this.setLastRemoteAnchorReceivedAt,
    required this.getIsRefreshingSnapshot,
    required this.setIsRefreshingSnapshot,
  });

  final Ref ref;
  final GroupListeningSyncPolicy syncPolicy;
  final GroupListeningSyncCoordinator coordinator;
  final GroupListeningPlaybackStateMapper stateMapper;
  final GroupListeningPlaybackFollower? Function() follower;
  final int Function() getLastObservedQueueVersion;
  final void Function(int value) setLastObservedQueueVersion;
  final int Function() getLastObservedPlaybackApplyId;
  final void Function(int value) setLastObservedPlaybackApplyId;
  final void Function(DateTime value) setLastRemoteAnchorReceivedAt;
  final bool Function() getIsRefreshingSnapshot;
  final void Function(bool value) setIsRefreshingSnapshot;

  void handleSessionChanged(
    GroupListeningSessionState? previous,
    GroupListeningSessionState next,
  ) {
    final previousRoomId = previous?.room?.roomId;
    final nextRoom = next.room;
    if (nextRoom == null) {
      setLastObservedQueueVersion(0);
      setLastObservedPlaybackApplyId(0);
      coordinator.resetForRoomChange();
      return;
    }

    if (previousRoomId != nextRoom.roomId) {
      setLastObservedQueueVersion(0);
      setLastObservedPlaybackApplyId(0);
      coordinator.resetForRoomChange();
    }

    if (previous?.localPlaybackEpoch != next.localPlaybackEpoch &&
        next.isCatchUpActive) {
      AppLogger.debug('Group listening: catch_up_enter');
    } else if (previous?.isCatchUpActive == true && !next.isCatchUpActive) {
      AppLogger.debug('Group listening: catch_up_exit');
    }

    final queueVersionChanged =
        nextRoom.queue.queueVersion > getLastObservedQueueVersion();
    final nextPlaybackApplyId = effectivePlaybackApplyId(nextRoom) ?? 0;
    final playbackApplyChanged =
        nextPlaybackApplyId > getLastObservedPlaybackApplyId();
    if (playbackApplyChanged ||
        previousRoomId != nextRoom.roomId ||
        previous?.room?.playbackAnchor != nextRoom.playbackAnchor) {
      setLastRemoteAnchorReceivedAt(DateTime.now());
    }

    if (next.snapshotRequired &&
        previous?.snapshotRequired != true &&
        !getIsRefreshingSnapshot()) {
      refreshSnapshotWhenRequired();
    }

    final prevCanPlayAudio = previous?.room?.self.canPlayAudio ?? true;
    if (prevCanPlayAudio && !nextRoom.self.canPlayAudio) {
      unawaited(ref.read(audioHandlerProvider)?.pause());
    }

    if (!_shouldApplyInboundState(next) ||
        (!queueVersionChanged && !playbackApplyChanged)) {
      return;
    }
    setLastObservedQueueVersion(nextRoom.queue.queueVersion);
    setLastObservedPlaybackApplyId(nextPlaybackApplyId);

    if (!nextRoom.self.canPlayAudio) {
      coordinator.lastPublishedState = stateMapper.playbackStateFromSession(
        next,
      );
      coordinator.lastPublishedAt = DateTime.now();
      return;
    }

    final remoteState = stateMapper.playbackStateFromSession(next);
    final localState = stateMapper.currentLocalPlaybackState();
    final anchor = nextRoom.playbackAnchor;
    final selfIssued =
        anchor != null &&
        (anchor.issuedByConnectionId != null
            ? anchor.issuedByConnectionId == next.connection.clientConnectionId
            : anchor.issuedByMemberId == nextRoom.self.memberId);
    if (selfIssued &&
        syncPolicy.playbackStatesEquivalent(
          toPolicyView(localState),
          toPolicyView(remoteState),
          tolerance: GroupListeningSyncTimings.echoTolerance,
        )) {
      coordinator.lastPublishedState = remoteState;
      coordinator.lastPublishedAt = DateTime.now();
      return;
    }

    final followPlayback =
        playbackApplyChanged && (next.configuration?.autoFollowHost ?? true);
    final forcePosition = playbackApplyChanged;
    if (previous?.snapshotRequired == true && !next.snapshotRequired) {
      unawaited(
        applyInbound(remoteState, followPlayback: followPlayback, force: true),
      );
      return;
    }
    unawaited(
      applyInbound(
        remoteState,
        followPlayback: followPlayback,
        force: forcePosition,
      ),
    );
  }

  void refreshSnapshotWhenRequired() {
    setIsRefreshingSnapshot(true);
    unawaited(
      ref
          .read(groupListeningSessionControllerProvider.notifier)
          .refreshSnapshot(reason: 'bridge-snapshot-required')
          .whenComplete(() {
            setIsRefreshingSnapshot(false);
            final current = ref.read(groupListeningSessionControllerProvider);
            if (current.snapshotRequired && current.connection.isConnected) {
              refreshSnapshotWhenRequired();
            }
          }),
    );
  }

  Future<void> applyInbound(
    BridgePlaybackState remoteState, {
    required bool followPlayback,
    required bool force,
  }) async {
    final follower = this.follower();
    if (follower == null) {
      return;
    }
    if (!coordinator.canApplyNow) {
      coordinator.queueInboundApply(
        remoteState,
        followPlayback: followPlayback,
      );
      return;
    }
    coordinator.isApplyingRemoteState = true;
    try {
      await follower.applyInboundState(
        remoteState,
        followPlayback: followPlayback,
        forcePositionCorrection: force,
        onApplyGateChanged: (gate) =>
            coordinator.onApplyGateChanged(gate, remoteState),
      );
      coordinator.suppressedEchoState = remoteState;
      coordinator.lastPublishedState = remoteState;
      coordinator.lastPublishedAt = DateTime.now();
    } finally {
      coordinator.isApplyingRemoteState = false;
      final queued = coordinator.queuedRemoteState;
      final queuedFollow = coordinator.queuedFollowPlayback;
      coordinator.clearQueuedInboundApply();
      if (queued != null &&
          !syncPolicy.playbackStatesEquivalent(
            toPolicyView(stateMapper.currentLocalPlaybackState()),
            toPolicyView(queued),
            tolerance: correctionTolerance(),
          )) {
        await applyInbound(
          queued,
          followPlayback: queuedFollow,
          force: true,
        );
      }
    }
  }

  bool isRemoteApplyGateBlocking(
    BridgePlaybackState localState,
    BridgePlaybackState latestRemoteState,
  ) {
    return coordinator.isRemoteApplyGateBlocking(
      localState: localState,
      latestRemoteState: latestRemoteState,
      correctionTolerance: correctionTolerance(),
      recentUserIntent: ref
          .read(groupListeningUserIntentProvider.notifier)
          .hasRecentIntent(),
      isTransientLocalPlaybackState: isTransientLocalPlaybackState,
      playbackStatesEquivalent: (left, right, tolerance) =>
          syncPolicy.playbackStatesEquivalent(
            toPolicyView(left),
            toPolicyView(right),
            tolerance: tolerance,
          ),
      requestInboundReconcile: () => unawaited(
        applyInbound(latestRemoteState, followPlayback: true, force: true),
      ),
    );
  }

  int preservedCurrentIndex({
    required BridgePlaybackState beforeApply,
    required BridgePlaybackState remoteState,
  }) {
    final currentSongId = beforeApply.currentSongId;
    if (currentSongId != null) {
      final index = remoteState.queueSongIds.indexOf(currentSongId);
      if (index >= 0) {
        return index;
      }
    }
    final currentIndex = beforeApply.currentIndex;
    if (currentIndex == null || remoteState.queueSongIds.isEmpty) {
      return 0;
    }
    if (currentIndex >= remoteState.queueSongIds.length) {
      return remoteState.queueSongIds.length - 1;
    }
    return currentIndex;
  }

  Duration correctionTolerance() {
    final rtt = ref
        .read(groupListeningSessionControllerProvider)
        .connection
        .lastRoundTripTime;
    return syncPolicy.correctionTolerance(roundTripTime: rtt);
  }

  bool isTransientLocalPlaybackState(
    BridgePlaybackState localState,
    BridgePlaybackState remoteState,
  ) {
    return syncPolicy.isTransientLocalPlaybackState(
      toPolicyView(localState),
      toPolicyView(remoteState),
    );
  }

  bool _shouldApplyInboundState(GroupListeningSessionState session) {
    final room = session.room;
    final configuration = session.configuration;
    if (room == null ||
        configuration == null ||
        session.snapshotRequired ||
        room.sourceServerFingerprint != configuration.sourceServerFingerprint) {
      return false;
    }
    return true;
  }

  int? effectivePlaybackApplyId(GroupListeningRoomState? room) {
    if (room == null) {
      return null;
    }
    if (room.playbackApplyId > 0) {
      return room.playbackApplyId;
    }
    final anchorApplyId = room.playbackAnchor?.playbackApplyId;
    if (anchorApplyId != null && anchorApplyId > 0) {
      return anchorApplyId;
    }
    if (room.playbackVersion > 0) {
      return room.playbackVersion;
    }
    return room.playbackAnchor?.roomVersion ?? 0;
  }
}
