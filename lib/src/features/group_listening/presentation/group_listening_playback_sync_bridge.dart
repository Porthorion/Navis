import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_controller.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:uuid/uuid.dart';

final groupListeningPlaybackSyncBridgeProvider =
    NotifierProvider.autoDispose<GroupListeningPlaybackSyncBridge, int>(
      GroupListeningPlaybackSyncBridge.new,
    );

/// Incremented each time a remote queue-add is applied as a pure append
/// (i.e., existing playback was not interrupted). Listeners can show a
/// snackbar notification when the value changes.
final groupListeningQueueTrackAddedProvider =
    NotifierProvider<_QueueTrackAddedNotifier, int>(
      _QueueTrackAddedNotifier.new,
    );

class _QueueTrackAddedNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void increment() => state++;
}

class GroupListeningPlaybackSyncBridge extends Notifier<int> {
  static const Duration _publishThrottle = Duration(milliseconds: 400);
  static const Duration _positionTolerance = Duration(milliseconds: 500);
  static const Duration _echoTolerance = Duration(milliseconds: 1500);
  static const Duration _localPositionDebounce = Duration(milliseconds: 250);
  static const Uuid _uuid = Uuid();

  Timer? _publishTimer;
  PlaybackSnapshot _latestSnapshot = const PlaybackSnapshot.idle();
  Duration _latestPosition = Duration.zero;
  int _lastObservedRoomVersion = 0;
  _BridgePlaybackState? _lastPublishedState;
  _BridgePlaybackState? _suppressedEchoState;
  DateTime? _lastPublishedAt;
  DateTime? _lastImmediateSnapshotChangeAt;
  bool _isApplyingRemoteState = false;
  bool _isRefreshingSnapshot = false;

  @override
  int build() {
    _latestSnapshot = ref.read(playerStateProvider);
    _latestPosition =
        ref.read(playbackPositionProvider).asData?.value ??
        _latestSnapshot.position;
    _lastObservedRoomVersion =
        ref.read(groupListeningSessionControllerProvider).room?.roomVersion ??
        0;

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

    ref.onDispose(() {
      _publishTimer?.cancel();
    });
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
    final lastImmediateSnapshotChangeAt = _lastImmediateSnapshotChangeAt;
    if (lastImmediateSnapshotChangeAt != null &&
        DateTime.now().difference(lastImmediateSnapshotChangeAt) <
            _localPositionDebounce) {
      return;
    }
    _schedulePublish(immediate: false);
  }

  void _handleSessionChanged(
    GroupListeningSessionState? previous,
    GroupListeningSessionState next,
  ) {
    final previousRoomId = previous?.room?.roomId;
    final nextRoom = next.room;
    if (nextRoom == null) {
      _publishTimer?.cancel();
      _lastObservedRoomVersion = 0;
      _lastPublishedState = null;
      _suppressedEchoState = null;
      return;
    }

    if (previousRoomId != nextRoom.roomId) {
      _lastObservedRoomVersion = 0;
      _lastPublishedState = null;
      _suppressedEchoState = null;
    }

    if (next.snapshotRequired &&
        previous?.snapshotRequired != true &&
        !_isRefreshingSnapshot) {
      _isRefreshingSnapshot = true;
      unawaited(
        ref
            .read(groupListeningSessionControllerProvider.notifier)
            .refreshSnapshot()
            .whenComplete(() {
              _isRefreshingSnapshot = false;
            }),
      );
    }

    if (!_shouldApplyInboundState(next) ||
        nextRoom.roomVersion <= _lastObservedRoomVersion) {
      return;
    }
    _lastObservedRoomVersion = nextRoom.roomVersion;

    final remoteState = _playbackStateFromRoom(nextRoom);
    final localState = _currentLocalPlaybackState();
    final selfIssued =
        nextRoom.playbackAnchor.issuedByMemberId == nextRoom.self.memberId;
    if (selfIssued &&
        _playbackStatesEquivalent(
          localState,
          remoteState,
          tolerance: _echoTolerance,
        )) {
      _lastPublishedState = remoteState;
      _lastPublishedAt = DateTime.now();
      return;
    }

    if (previous?.snapshotRequired == true && !next.snapshotRequired) {
      unawaited(_applyAuthoritativeInboundState(remoteState));
      return;
    }

    unawaited(_applyInboundState(remoteState));
  }

  Future<void> _applyAuthoritativeInboundState(
    _BridgePlaybackState remoteState,
  ) async {
    await _applyInboundState(remoteState);
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
      if (_isApplyingRemoteState) {
        return;
      }

      final localState = _currentLocalPlaybackState();
      if (_playbackStatesEquivalent(
        localState,
        remoteState,
        tolerance: _positionTolerance,
      )) {
        return;
      }

      await _applyInboundState(remoteState);
    }
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

  void _schedulePublish({required bool immediate}) {
    if (_isApplyingRemoteState) {
      return;
    }

    final session = ref.read(groupListeningSessionControllerProvider);
    if (!_canPublishOutbound(session)) {
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
    _publishTimer = Timer(_publishThrottle, () {
      _publishTimer = null;
      unawaited(_publishLocalState(force: false));
    });
  }

  bool _canPublishOutbound(GroupListeningSessionState session) {
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
    if (!_canPublishOutbound(session)) {
      return;
    }

    final localState = _currentLocalPlaybackState();
    if (localState.isRadioMode) {
      return;
    }

    final suppressedEchoState = _suppressedEchoState;
    if (suppressedEchoState != null &&
        _playbackStatesEquivalent(
          localState,
          suppressedEchoState,
          tolerance: _echoTolerance,
        )) {
      _suppressedEchoState = null;
      _lastPublishedState = localState;
      _lastPublishedAt = DateTime.now();
      return;
    }

    final lastPublishedState = _lastPublishedState;
    if (lastPublishedState != null &&
        _playbackStatesEquivalent(
          localState,
          lastPublishedState,
          tolerance: _positionTolerance,
        )) {
      return;
    }

    final room = session.room!;
    final remoteState = _playbackStateFromRoom(room);
    final queueChanged = !listEquals(
      localState.queueSongIds,
      remoteState.queueSongIds,
    );
    final trackChanged =
        localState.currentIndex != remoteState.currentIndex ||
        localState.currentSongId != remoteState.currentSongId;
    final playingChanged = localState.playing != remoteState.playing;
    final positionDelta = _durationDistance(
      localState.position,
      remoteState.position,
    );

    if (!queueChanged &&
        !trackChanged &&
        !playingChanged &&
        !force &&
        positionDelta < _positionTolerance) {
      return;
    }

    final now = DateTime.now();
    final lastPublishedAt = _lastPublishedAt;
    if (!queueChanged &&
        !trackChanged &&
        !playingChanged &&
        !force &&
        lastPublishedAt != null &&
        now.difference(lastPublishedAt) < _publishThrottle) {
      return;
    }

    final queueState = _queueStateFromLocalState(session, localState);
    final reason = _resolveAnchorReason(
      queueChanged: queueChanged,
      trackChanged: trackChanged,
      playingChanged: playingChanged,
      localState: localState,
      remoteState: remoteState,
    );
    final playbackAnchor = _buildPlaybackAnchor(
      session: session,
      queueState: queueState,
      localState: localState,
      reason: reason,
    );

    final mutationType = queueChanged
        ? GroupListeningMutationType.queueReplace
        : GroupListeningMutationType.playbackAnchor;
    final canSendMutation =
        queueChanged ||
        room.self.canControl ||
        reason == GroupListeningPlaybackAnchorReason.seek;
    if (!canSendMutation) {
      return;
    }
    _lastPublishedState = localState;
    _lastPublishedAt = now;
    final mutationId = await ref
        .read(groupListeningSessionControllerProvider.notifier)
        .sendMutation(
          type: mutationType,
          playbackAnchor: playbackAnchor,
          queue: queueChanged ? queueState : null,
        );
    if (mutationId == null || mutationId.isEmpty) {
      return;
    }
  }

  Future<void> _applyInboundState(_BridgePlaybackState remoteState) async {
    final handler = ref.read(audioHandlerProvider);
    if (handler == null) {
      return;
    }

    _isApplyingRemoteState = true;
    try {
      final queueController = ref.read(queueProvider.notifier);
      final beforeApply = _currentLocalPlaybackState();
      final queueChanged = !listEquals(
        beforeApply.queueSongIds,
        remoteState.queueSongIds,
      );
      final trackChanged = beforeApply.currentIndex != remoteState.currentIndex;

      // Whether we performed a full queue replace (requires seek + play/pause sync).
      var didFullQueueReplace = false;

      if (remoteState.queueSongIds.isEmpty) {
        if (beforeApply.queueSongIds.isNotEmpty || beforeApply.isRadioMode) {
          await queueController.clear();
        }
      } else if (queueChanged) {
        // Detect a pure append: old items are unchanged and new items were
        // appended at the end without shifting the current track.
        final isPureAppend =
            remoteState.queueSongIds.length > beforeApply.queueSongIds.length &&
            remoteState.currentIndex == beforeApply.currentIndex &&
            _isPrefixOf(beforeApply.queueSongIds, remoteState.queueSongIds);

        if (isPureAppend) {
          final newIds = remoteState.queueSongIds.sublist(
            beforeApply.queueSongIds.length,
          );
          for (final id in newIds) {
            await queueController.add(id);
          }
          // Notify the UI to show a snackbar without interrupting playback.
          ref.read(groupListeningQueueTrackAddedProvider.notifier).increment();
        } else {
          await queueController.replace(
            remoteState.queueSongIds,
            startIndex: remoteState.currentIndex ?? 0,
            autoPlay: remoteState.playing,
          );
          didFullQueueReplace = true;
        }
      } else if (trackChanged && remoteState.currentIndex != null) {
        if (remoteState.playing) {
          await queueController.playFromIndex(remoteState.currentIndex!);
        } else {
          await queueController.replace(
            remoteState.queueSongIds,
            startIndex: remoteState.currentIndex!,
            autoPlay: false,
          );
        }
      }

      final afterQueueApply = _currentLocalPlaybackState();
      if (remoteState.queueSongIds.isNotEmpty) {
        final shouldSeek =
            didFullQueueReplace ||
            trackChanged ||
            _durationDistance(afterQueueApply.position, remoteState.position) >
                _positionTolerance;
        if (shouldSeek) {
          await handler.seek(remoteState.position);
        }
      }

      final refreshedState = _currentLocalPlaybackState();
      if (remoteState.playing != refreshedState.playing) {
        if (remoteState.playing) {
          await handler.play();
        } else {
          await handler.pause();
        }
      }

      _suppressedEchoState = remoteState;
      _lastPublishedState = remoteState;
      _lastPublishedAt = DateTime.now();
    } on Object catch (error, stackTrace) {
      AppLogger.warning('Group listening playback apply failed: $error');
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'group_listening_playback_sync_bridge',
          context: ErrorDescription('applying Voyage room state to playback'),
        ),
      );
    } finally {
      _isApplyingRemoteState = false;
    }
  }

  GroupListeningQueueState _queueStateFromLocalState(
    GroupListeningSessionState session,
    _BridgePlaybackState localState,
  ) {
    final room = session.room!;
    final existingEntriesBySongId =
        <String, ListQueue<GroupListeningQueueEntry>>{};
    for (final entry in room.queue.entries) {
      existingEntriesBySongId
          .putIfAbsent(entry.songId, ListQueue<GroupListeningQueueEntry>.new)
          .add(entry);
    }

    final memberId = room.self.memberId;
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

  GroupListeningPlaybackAnchor _buildPlaybackAnchor({
    required GroupListeningSessionState session,
    required GroupListeningQueueState queueState,
    required _BridgePlaybackState localState,
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
      issuedByMemberId: session.room?.self.memberId,
    );
  }

  GroupListeningPlaybackAnchorReason _resolveAnchorReason({
    required bool queueChanged,
    required bool trackChanged,
    required bool playingChanged,
    required _BridgePlaybackState localState,
    required _BridgePlaybackState remoteState,
  }) {
    if (queueChanged || trackChanged) {
      return GroupListeningPlaybackAnchorReason.trackChange;
    }
    if (playingChanged) {
      return localState.playing
          ? GroupListeningPlaybackAnchorReason.play
          : GroupListeningPlaybackAnchorReason.pause;
    }
    if (_durationDistance(localState.position, remoteState.position) >
        _positionTolerance) {
      return GroupListeningPlaybackAnchorReason.seek;
    }
    return GroupListeningPlaybackAnchorReason.syncTick;
  }

  _BridgePlaybackState _playbackStateFromRoom(GroupListeningRoomState room) {
    final anchor = room.playbackAnchor;
    return _BridgePlaybackState(
      queueSongIds: List<String>.unmodifiable(
        room.queue.entries.map((entry) => entry.songId),
      ),
      currentIndex: anchor.currentIndex ?? room.queue.currentIndex,
      currentSongId: anchor.currentSongId ?? room.queue.currentSongId,
      playing: anchor.playbackState == GroupListeningPlaybackStatus.playing,
      position: anchor.position,
      isRadioMode: false,
    );
  }

  _BridgePlaybackState _currentLocalPlaybackState() {
    final snapshot =
        ref.read(audioHandlerProvider)?.snapshot ?? _latestSnapshot;
    final currentIndex = snapshot.currentIndex;
    final queueSongIds = List<String>.unmodifiable(snapshot.queueSongIds);
    final position = _latestPosition == Duration.zero
        ? snapshot.position
        : _latestPosition;
    final currentSongId =
        currentIndex != null &&
            currentIndex >= 0 &&
            currentIndex < queueSongIds.length
        ? queueSongIds[currentIndex]
        : snapshot.currentSongId;
    return _BridgePlaybackState(
      queueSongIds: queueSongIds,
      currentIndex: currentIndex,
      currentSongId: currentSongId,
      playing: snapshot.playing,
      position: position,
      isRadioMode: snapshot.isRadioMode,
    );
  }

  bool _playbackStatesEquivalent(
    _BridgePlaybackState left,
    _BridgePlaybackState right, {
    required Duration tolerance,
  }) {
    return listEquals(left.queueSongIds, right.queueSongIds) &&
        left.currentIndex == right.currentIndex &&
        left.currentSongId == right.currentSongId &&
        left.playing == right.playing &&
        left.isRadioMode == right.isRadioMode &&
        _durationDistance(left.position, right.position) <= tolerance;
  }

  Duration _durationDistance(Duration left, Duration right) {
    final delta = left.inMilliseconds - right.inMilliseconds;
    return Duration(milliseconds: delta.abs());
  }

  /// Returns true if [prefix] is an exact prefix of [full] (same order,
  /// same values). Used to detect pure-append queue changes.
  bool _isPrefixOf(List<String> prefix, List<String> full) {
    if (prefix.length > full.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (prefix[i] != full[i]) return false;
    }
    return true;
  }
}

@immutable
class _BridgePlaybackState {
  const _BridgePlaybackState({
    required this.queueSongIds,
    required this.currentIndex,
    required this.currentSongId,
    required this.playing,
    required this.position,
    required this.isRadioMode,
  });

  final List<String> queueSongIds;
  final int? currentIndex;
  final String? currentSongId;
  final bool playing;
  final Duration position;
  final bool isRadioMode;
}
