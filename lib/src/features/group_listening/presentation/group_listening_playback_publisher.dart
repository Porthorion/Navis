import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_sync_policy.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_user_intent.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_playback_state_mapper.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_queue_mutation_diff.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_controller.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

GroupListeningPlaybackAnchor buildGroupListeningPlaybackAnchor({
  required Ref ref,
  required GroupListeningSessionState session,
  required GroupListeningQueueState queueState,
  required BridgePlaybackState localState,
  required GroupListeningPlaybackAnchorReason reason,
}) {
  final settings =
      ref.read(appSettingsProvider).asData?.value ??
      const AppSettingsModel.defaults();
  final currentEntry = queueState.currentEntry;
  return GroupListeningPlaybackAnchor(
    roomVersion: session.lastAppliedRoomVersion,
    queueVersion: queueState.queueVersion,
    currentIndex: queueState.currentIndex,
    currentQueueEntryId: currentEntry?.queueEntryId,
    currentSongId: currentEntry?.songId,
    playbackState: localState.playing
        ? GroupListeningPlaybackStatus.playing
        : GroupListeningPlaybackStatus.paused,
    position: localState.position,
    capturedAt: DateTime.now(),
    playbackRate: settings.playbackSpeed,
    reason: reason,
    playbackEpoch: session.localPlaybackEpoch,
    issuedByMemberId: session.room?.self.memberId,
    issuedByConnectionId: session.connection.clientConnectionId,
  );
}

/// Publishes user-intent playback and queue mutations upstream to Voyage.
class GroupListeningPlaybackPublisher {
  GroupListeningPlaybackPublisher({
    required this.ref,
    required this.syncPolicy,
    required this.currentLocalState,
    required this.playbackStateFromSession,
    required this.correctionTolerance,
    required this.isRemoteApplyGateBlocking,
    required this.recentLocalIntentMatches,
  });

  final Ref ref;
  final GroupListeningSyncPolicy syncPolicy;
  final BridgePlaybackState Function() currentLocalState;
  final BridgePlaybackState Function(GroupListeningSessionState session)
  playbackStateFromSession;
  final Duration Function() correctionTolerance;
  final bool Function(
    BridgePlaybackState localState,
    BridgePlaybackState latestRemoteState,
  )
  isRemoteApplyGateBlocking;
  final bool Function() recentLocalIntentMatches;

  Future<void> publishLocalState({
    required bool force,
    required UserPlaybackIntent? intent,
    required bool canPublishOutbound,
    required BridgePlaybackState? lastPublishedState,
    required BridgePlaybackState? suppressedEchoState,
    required DateTime? lastPublishedAt,
    required void Function(BridgePlaybackState state) rememberPublishedState,
    required void Function(BridgePlaybackState? state) rememberSuppressedEcho,
    required void Function(DateTime time) rememberPublishedAt,
  }) async {
    if (!canPublishOutbound || intent == null) {
      return;
    }

    final session = ref.read(groupListeningSessionControllerProvider);
    final localState = currentLocalState();
    if (localState.isRadioMode) {
      return;
    }

    if (suppressedEchoState != null &&
        syncPolicy.playbackStatesEquivalent(
          toPolicyView(localState),
          toPolicyView(suppressedEchoState),
          tolerance: GroupListeningSyncTimings.echoTolerance,
        )) {
      rememberSuppressedEcho(null);
      rememberPublishedState(localState);
      rememberPublishedAt(DateTime.now());
      return;
    }

    if (lastPublishedState != null &&
        syncPolicy.playbackStatesEquivalent(
          toPolicyView(localState),
          toPolicyView(lastPublishedState),
          tolerance: GroupListeningSyncTimings.positionTolerance,
        )) {
      return;
    }

    final room = session.room!;
    final remoteState = playbackStateFromSession(session);
    if (isRemoteApplyGateBlocking(localState, remoteState)) {
      return;
    }

    final queueChanged = !listEquals(
      localState.queueSongIds,
      remoteState.queueSongIds,
    );
    final trackChanged =
        localState.currentIndex != remoteState.currentIndex ||
        localState.currentSongId != remoteState.currentSongId;
    final playingChanged = localState.playing != remoteState.playing;
    final positionDelta = syncPolicy.durationDistance(
      localState.position,
      remoteState.position,
    );
    final tolerance = correctionTolerance();

    if (syncPolicy.shouldApplyInboundInsteadOfPublish(
      queueChanged: queueChanged,
      trackChanged: trackChanged,
      playingChanged: playingChanged,
      localPosition: localState.position,
      remotePosition: remoteState.position,
      slop: GroupListeningSyncTimings.rewindSlop,
      recentUserIntent: recentLocalIntentMatches(),
    )) {
      return;
    }

    if (!queueChanged &&
        !trackChanged &&
        !playingChanged &&
        !force &&
        positionDelta < tolerance) {
      return;
    }

    final now = DateTime.now();
    if (!queueChanged &&
        !trackChanged &&
        !playingChanged &&
        !force &&
        lastPublishedAt != null &&
        now.difference(lastPublishedAt) <
            GroupListeningSyncTimings.publishThrottle) {
      return;
    }

    final reason = syncPolicy.resolvePublishReason(
      intent: intent,
      queueChanged: queueChanged,
      trackChanged: trackChanged,
      playingChanged: playingChanged,
      positionDelta: positionDelta,
      correctionTolerance: tolerance,
    );
    if (reason == null) {
      return;
    }

    if (session.isCatchUpActive &&
        syncPolicy.blocksOutboundDuringCatchUp(
          catchUpActive: true,
          mutationType: GroupListeningMutationType.playbackAnchor,
        ) &&
        !queueChanged) {
      return;
    }

    final queueState = queueStateFromLocalState(
      room: room,
      localState: localState,
      memberId: room.self.memberId,
    );
    final playbackAnchor = buildGroupListeningPlaybackAnchor(
      ref: ref,
      session: session,
      queueState: queueState,
      localState: localState,
      reason: reason,
    );

    var mutationType = queueChanged
        ? GroupListeningMutationType.queueReplace
        : GroupListeningMutationType.playbackAnchor;
    String? targetQueueEntryId;
    if (queueChanged) {
      final queueDiff = granularQueueMutation(
        room: room,
        queueState: queueState,
        localState: localState,
        remoteState: remoteState,
      );
      if (queueDiff != null) {
        mutationType = queueDiff.type;
        targetQueueEntryId = queueDiff.queueEntryId;
      }
    }

    if (!room.self.canControl) {
      return;
    }

    rememberPublishedState(localState);
    rememberPublishedAt(now);
    final mutationId = await ref
        .read(groupListeningSessionControllerProvider.notifier)
        .sendMutation(
          type: mutationType,
          playbackAnchor: playbackAnchor,
          queue: queueChanged ? queueState : null,
          targetQueueEntryId: targetQueueEntryId,
        );
    if (mutationId == null || mutationId.isEmpty) {
      return;
    }
  }
}
