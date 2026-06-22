import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_sync_policy.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_track_resolution_service.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_user_intent.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_playback_follower.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_playback_publisher.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_playback_state_mapper.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_playback_sync_bridge_inbound.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_queue_mutation_diff.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_controller.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_sync_coordinator.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/providers/app_providers.dart';

final groupListeningPlaybackSyncBridgeProvider =
    NotifierProvider.autoDispose<GroupListeningPlaybackSyncBridge, int>(
      GroupListeningPlaybackSyncBridge.new,
    );

/// Incremented when a remote queue-add is applied as a pure append.
final groupListeningQueueTrackAddedProvider =
    NotifierProvider<_QueueTrackAddedNotifier, int>(
      _QueueTrackAddedNotifier.new,
    );

/// Incremented when an unresolvable track is auto-skipped locally.
final groupListeningQueueTrackSkippedProvider =
    NotifierProvider<_QueueTrackSkippedNotifier, int>(
      _QueueTrackSkippedNotifier.new,
    );

class _QueueTrackAddedNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void increment() => state++;
}

class _QueueTrackSkippedNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void increment() => state++;
}

class GroupListeningPlaybackSyncBridge extends Notifier<int> {
  static const GroupListeningSyncPolicy _syncPolicy =
      GroupListeningSyncPolicy();

  final GroupListeningSyncCoordinator _coordinator =
      GroupListeningSyncCoordinator();
  GroupListeningPlaybackFollower? _follower;
  GroupListeningPlaybackPublisher? _publisher;
  late final GroupListeningPlaybackSyncBridgeInbound _inbound;
  late final GroupListeningPlaybackStateMapper _stateMapper;
  Timer? _publishTimer;
  PlaybackSnapshot _latestSnapshot = const PlaybackSnapshot.idle();
  Duration _latestPosition = Duration.zero;
  int _lastObservedQueueVersion = 0;
  int _lastObservedPlaybackApplyId = 0;
  DateTime? _lastImmediateSnapshotChangeAt;
  DateTime? _lastRemoteAnchorReceivedAt;
  bool _isRefreshingSnapshot = false;

  @override
  int build() {
    _stateMapper = GroupListeningPlaybackStateMapper(
      ref: ref,
      getLatestSnapshot: () => _latestSnapshot,
      getLatestPosition: () => _latestPosition,
      getLastRemoteAnchorReceivedAt: () => _lastRemoteAnchorReceivedAt,
    );
    _inbound = GroupListeningPlaybackSyncBridgeInbound(
      ref: ref,
      syncPolicy: _syncPolicy,
      coordinator: _coordinator,
      stateMapper: _stateMapper,
      follower: () => _follower,
      getLastObservedQueueVersion: () => _lastObservedQueueVersion,
      setLastObservedQueueVersion: (value) => _lastObservedQueueVersion = value,
      getLastObservedPlaybackApplyId: () => _lastObservedPlaybackApplyId,
      setLastObservedPlaybackApplyId: (value) =>
          _lastObservedPlaybackApplyId = value,
      setLastRemoteAnchorReceivedAt: (value) =>
          _lastRemoteAnchorReceivedAt = value,
      getIsRefreshingSnapshot: () => _isRefreshingSnapshot,
      setIsRefreshingSnapshot: (value) => _isRefreshingSnapshot = value,
    );
    final resolutionService = GroupListeningTrackResolutionService(
      api: ref.read(subsonicApiProvider),
    );
    _follower = GroupListeningPlaybackFollower(
      ref: ref,
      syncPolicy: _syncPolicy,
      resolutionService: resolutionService,
      onQueueTrackAdded: () =>
          ref.read(groupListeningQueueTrackAddedProvider.notifier).increment(),
      onQueueTrackSkipped: () => ref
          .read(groupListeningQueueTrackSkippedProvider.notifier)
          .increment(),
      currentLocalState: _stateMapper.currentLocalPlaybackState,
      playbackStateFromSession: _stateMapper.playbackStateFromSession,
      correctionTolerance: _inbound.correctionTolerance,
      isPrefixOf: isPrefixOf,
      preservedCurrentIndex: _inbound.preservedCurrentIndex,
    );
    _publisher = GroupListeningPlaybackPublisher(
      ref: ref,
      syncPolicy: _syncPolicy,
      currentLocalState: _stateMapper.currentLocalPlaybackState,
      playbackStateFromSession: _stateMapper.playbackStateFromSession,
      correctionTolerance: _inbound.correctionTolerance,
      isRemoteApplyGateBlocking: _inbound.isRemoteApplyGateBlocking,
      recentLocalIntentMatches: () =>
          ref.read(groupListeningUserIntentProvider.notifier).hasRecentIntent(),
    );

    _latestSnapshot = ref.read(playerStateProvider);
    _latestPosition =
        ref.read(playbackPositionProvider).asData?.value ??
        _latestSnapshot.position;
    final room = ref.read(groupListeningSessionControllerProvider).room;
    _lastObservedQueueVersion = room?.queue.queueVersion ?? 0;
    _lastObservedPlaybackApplyId = _inbound.effectivePlaybackApplyId(room) ?? 0;

    ref.listen<PlaybackSnapshot>(
      playerStateProvider,
      _handleLocalSnapshotChanged,
    );
    ref.listen<AsyncValue<Duration>>(
      playbackPositionProvider,
      _handleLocalPositionChanged,
    );
    ref.listen<GroupListeningSessionState>(
      groupListeningSessionControllerProvider,
      _handleSessionChanged,
    );
    ref.listen<int>(groupListeningUserIntentProvider, (_, _) {
      _schedulePublish(immediate: true);
    });

    ref.onDispose(() => _publishTimer?.cancel());
    return 0;
  }

  void _handleLocalSnapshotChanged(
    PlaybackSnapshot? previous,
    PlaybackSnapshot next,
  ) {
    _latestSnapshot = next;
    _latestPosition = next.position;
    final immediate =
        previous != null &&
        (!listEquals(previous.queueSongIds, next.queueSongIds) ||
            previous.currentIndex != next.currentIndex ||
            previous.currentSongId != next.currentSongId ||
            previous.playing != next.playing ||
            previous.isRadioMode != next.isRadioMode);
    if (immediate) {
      _lastImmediateSnapshotChangeAt = DateTime.now();
      final intent = switch ((previous?.playing, next.playing)) {
        (false, true) => UserPlaybackIntent.play,
        (true, false) => UserPlaybackIntent.pause,
        _
            when !listEquals(previous?.queueSongIds, next.queueSongIds) ||
                previous?.currentIndex != next.currentIndex =>
          UserPlaybackIntent.trackChange,
        _ => UserPlaybackIntent.seek,
      };
      ref.read(groupListeningUserIntentProvider.notifier).record(intent);
    }
    _schedulePublish(immediate: immediate);
  }

  void _handleLocalPositionChanged(
    AsyncValue<Duration>? previous,
    AsyncValue<Duration> next,
  ) {
    final value = next.asData?.value;
    if (value == null) {
      return;
    }
    _latestPosition = value;
    final lastImmediate = _lastImmediateSnapshotChangeAt;
    if (lastImmediate != null &&
        DateTime.now().difference(lastImmediate) <
            GroupListeningSyncTimings.localPositionDebounce) {
      return;
    }
    ref
        .read(groupListeningUserIntentProvider.notifier)
        .record(
          UserPlaybackIntent.seek,
        );
    _schedulePublish(immediate: false);
  }

  void _handleSessionChanged(
    GroupListeningSessionState? previous,
    GroupListeningSessionState next,
  ) {
    if (next.room == null) {
      _publishTimer?.cancel();
    }
    _inbound.handleSessionChanged(previous, next);
  }

  void _schedulePublish({required bool immediate}) {
    if (_coordinator.isApplyingRemoteState) {
      return;
    }
    if (!_sessionReadyForPublish()) {
      return;
    }
    if (immediate) {
      _publishTimer?.cancel();
      _publishTimer = null;
      unawaited(_publishLocalState(force: true));
      return;
    }
    if (_publishTimer?.isActive ?? false) {
      return;
    }
    _publishTimer = Timer(GroupListeningSyncTimings.publishThrottle, () {
      _publishTimer = null;
      unawaited(_publishLocalState(force: false));
    });
  }

  bool _sessionReadyForPublish() {
    final session = ref.read(groupListeningSessionControllerProvider);
    final room = session.room;
    final configuration = session.configuration;
    return room != null &&
        configuration != null &&
        session.availability == GroupListeningAvailability.ready &&
        session.connection.isConnected &&
        !session.snapshotRequired &&
        room.roomStatus == GroupListeningRoomStatus.active &&
        room.sourceServerFingerprint == configuration.sourceServerFingerprint;
  }

  Future<void> _publishLocalState({required bool force}) async {
    final session = ref.read(groupListeningSessionControllerProvider);
    final intent = ref
        .read(groupListeningUserIntentProvider.notifier)
        .consumeIntent();
    if (intent == null && !force) {
      return;
    }
    await _publisher?.publishLocalState(
      force: force,
      intent: intent,
      canPublishOutbound: _coordinator.canPublishOutbound(
        catchUpActive: session.isCatchUpActive,
        sessionReady: _sessionReadyForPublish(),
      ),
      lastPublishedState: _coordinator.lastPublishedState,
      suppressedEchoState: _coordinator.suppressedEchoState,
      lastPublishedAt: _coordinator.lastPublishedAt,
      rememberPublishedState: (state) =>
          _coordinator.lastPublishedState = state,
      rememberSuppressedEcho: (state) =>
          _coordinator.suppressedEchoState = state,
      rememberPublishedAt: (time) => _coordinator.lastPublishedAt = time,
    );
  }
}
