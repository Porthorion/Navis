import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/group_listening/data/group_listening_repository.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_sync_policy.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_track_resolution_service.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_playback_state_mapper.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_controller.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Applies authoritative Voyage room playback state to the local player.
class GroupListeningPlaybackFollower {
  GroupListeningPlaybackFollower({
    required this.ref,
    required this.syncPolicy,
    required this.resolutionService,
    required this.onQueueTrackAdded,
    required this.onQueueTrackSkipped,
    required this.currentLocalState,
    required this.playbackStateFromSession,
    required this.correctionTolerance,
    required this.isPrefixOf,
    required this.preservedCurrentIndex,
  });

  final Ref ref;
  final GroupListeningSyncPolicy syncPolicy;
  final GroupListeningTrackResolutionService resolutionService;
  final VoidCallback onQueueTrackAdded;
  final VoidCallback onQueueTrackSkipped;
  final BridgePlaybackState Function() currentLocalState;
  final BridgePlaybackState Function(GroupListeningSessionState session)
  playbackStateFromSession;
  final Duration Function() correctionTolerance;
  final bool Function(List<String> prefix, List<String> full) isPrefixOf;
  final int Function({
    required BridgePlaybackState beforeApply,
    required BridgePlaybackState remoteState,
  })
  preservedCurrentIndex;

  Future<void> applyInboundState(
    BridgePlaybackState remoteState, {
    required bool followPlayback,
    bool forcePositionCorrection = false,
    required void Function(bool gateOutbound) onApplyGateChanged,
  }) async {
    final handler = ref.read(audioHandlerProvider);
    if (handler == null) {
      return;
    }

    var shouldGateOutboundAfterApply = false;
    try {
      final queueController = ref.read(queueProvider.notifier);
      final beforeApply = currentLocalState();
      final remoteRoom = ref.read(groupListeningSessionControllerProvider).room;
      final entries =
          remoteRoom?.queue.entries ?? const <GroupListeningQueueEntry>[];
      await _prefetchUpcoming(entries, remoteState.currentIndex);
      final resolvedRemoteState = await _resolveRemoteState(
        remoteState,
        entries,
      );
      final queueChanged = !listEquals(
        beforeApply.queueSongIds,
        resolvedRemoteState.queueSongIds,
      );
      final trackChanged =
          beforeApply.currentIndex != resolvedRemoteState.currentIndex;
      shouldGateOutboundAfterApply = queueChanged || trackChanged;
      if (remoteRoom != null && queueChanged) {
        await queueController.cacheGroupListeningQueueMetadata(entries);
      }

      var didFullQueueReplace = false;

      if (resolvedRemoteState.queueSongIds.isEmpty) {
        if (beforeApply.queueSongIds.isNotEmpty || beforeApply.isRadioMode) {
          await queueController.clear(syncGroupListening: false);
        }
      } else if (queueChanged) {
        final isPureAppend =
            resolvedRemoteState.queueSongIds.length >
                beforeApply.queueSongIds.length &&
            resolvedRemoteState.currentIndex == beforeApply.currentIndex &&
            isPrefixOf(
              beforeApply.queueSongIds,
              resolvedRemoteState.queueSongIds,
            );

        if (isPureAppend) {
          final newIds = resolvedRemoteState.queueSongIds.sublist(
            beforeApply.queueSongIds.length,
          );
          for (final id in newIds) {
            if (id.isEmpty) {
              continue;
            }
            await queueController.add(id, syncGroupListening: false);
          }
          onQueueTrackAdded();
        } else {
          final startIndex = followPlayback
              ? resolvedRemoteState.currentIndex ?? 0
              : preservedCurrentIndex(
                  beforeApply: beforeApply,
                  remoteState: resolvedRemoteState,
                );
          await queueController.replace(
            resolvedRemoteState.queueSongIds
                .where((id) => id.isNotEmpty)
                .toList(growable: false),
            startIndex: startIndex,
            autoPlay: followPlayback
                ? resolvedRemoteState.playing
                : beforeApply.playing,
            syncGroupListening: false,
          );
          didFullQueueReplace = followPlayback;
        }
      } else if (followPlayback &&
          trackChanged &&
          resolvedRemoteState.currentIndex != null) {
        if (resolvedRemoteState.playing) {
          await queueController.playFromIndex(
            resolvedRemoteState.currentIndex!,
          );
        } else {
          await queueController.replace(
            resolvedRemoteState.queueSongIds
                .where((id) => id.isNotEmpty)
                .toList(growable: false),
            startIndex: resolvedRemoteState.currentIndex!,
            autoPlay: false,
            syncGroupListening: false,
          );
        }
      }

      final afterQueueApply = currentLocalState();
      if (followPlayback && resolvedRemoteState.queueSongIds.isNotEmpty) {
        final shouldSeek =
            didFullQueueReplace ||
            trackChanged ||
            (forcePositionCorrection &&
                syncPolicy.durationDistance(
                      afterQueueApply.position,
                      resolvedRemoteState.position,
                    ) >
                    correctionTolerance());
        if (shouldSeek) {
          shouldGateOutboundAfterApply = true;
          await handler.seek(resolvedRemoteState.position);
        }
      }

      final refreshedState = currentLocalState();
      if (followPlayback &&
          resolvedRemoteState.playing != refreshedState.playing) {
        if (resolvedRemoteState.playing) {
          await handler.play();
        } else {
          await handler.pause();
        }
      }

      ref
          .read(groupListeningSessionControllerProvider.notifier)
          .markPlaybackCatchUpAligned(
            serverEpoch: remoteRoom?.playbackEpoch ?? 0,
          );
    } on Object catch (error, stackTrace) {
      if (_isBenignPlaybackApplyFailure(error)) {
        AppLogger.info(
          'Group listening: ignoring benign playback apply interruption: $error',
        );
        return;
      }
      AppLogger.warning('Group listening playback apply failed: $error');
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'group_listening_playback_follower',
          context: ErrorDescription('applying Voyage room state to playback'),
        ),
      );
    } finally {
      onApplyGateChanged(shouldGateOutboundAfterApply);
    }
  }

  Future<void> _prefetchUpcoming(
    List<GroupListeningQueueEntry> entries,
    int? currentIndex,
  ) async {
    if (entries.isEmpty || currentIndex == null || currentIndex < 0) {
      return;
    }
    final prefetch = <GroupListeningQueueEntry>[];
    if (currentIndex < entries.length) {
      prefetch.add(entries[currentIndex]);
    }
    final nextIndex = currentIndex + 1;
    if (nextIndex < entries.length) {
      prefetch.add(entries[nextIndex]);
    }
    await resolutionService.prefetchEntries(prefetch);
  }

  Future<BridgePlaybackState> _resolveRemoteState(
    BridgePlaybackState remoteState,
    List<GroupListeningQueueEntry> entries,
  ) async {
    if (entries.isEmpty) {
      return remoteState;
    }
    final resolvedIds = <String>[];
    for (final entry in entries) {
      final result = await resolutionService.resolveEntry(entry: entry);
      switch (result) {
        case GroupListeningTrackResolved(:final songId):
          resolvedIds.add(songId);
          unawaited(
            ref
                .read(groupListeningSessionControllerProvider.notifier)
                .sendTrackReadiness(
                  queueEntryId: entry.queueEntryId,
                  status: 'ready',
                  resolvedSongId: songId,
                ),
          );
        case GroupListeningTrackUnavailable(:final reason):
          AppLogger.debug(
            'Group listening: resolution_fail entry=${entry.queueEntryId} '
            'reason=$reason',
          );
          unawaited(
            ref
                .read(groupListeningSessionControllerProvider.notifier)
                .sendTrackReadiness(
                  queueEntryId: entry.queueEntryId,
                  status: 'unavailable',
                ),
          );
          final skipped = await _autoSkipUnavailable(
            entry: entry,
            entries: entries,
            remoteState: remoteState,
          );
          if (skipped) {
            onQueueTrackSkipped();
          }
          resolvedIds.add('');
      }
    }
    if (listEquals(resolvedIds, remoteState.queueSongIds)) {
      return remoteState;
    }
    final currentIndex = remoteState.currentIndex;
    final currentSongId =
        currentIndex != null &&
            currentIndex >= 0 &&
            currentIndex < resolvedIds.length &&
            resolvedIds[currentIndex].isNotEmpty
        ? resolvedIds[currentIndex]
        : remoteState.currentSongId;
    return (
      queueSongIds: resolvedIds,
      currentIndex: currentIndex,
      currentSongId: currentSongId,
      playing: remoteState.playing,
      position: remoteState.position,
      isRadioMode: remoteState.isRadioMode,
      processingStateName: remoteState.processingStateName,
      isLoading: remoteState.isLoading,
      loadingSongId: remoteState.loadingSongId,
    );
  }

  Future<bool> _autoSkipUnavailable({
    required GroupListeningQueueEntry entry,
    required List<GroupListeningQueueEntry> entries,
    required BridgePlaybackState remoteState,
  }) async {
    final currentIndex = remoteState.currentIndex;
    final entryIndex = entries.indexWhere(
      (candidate) => candidate.queueEntryId == entry.queueEntryId,
    );
    if (entryIndex < 0) {
      return false;
    }
    final isCurrent = currentIndex == entryIndex;
    if (!isCurrent) {
      return false;
    }
    AppLogger.debug(
      'Group listening: auto_skip entry=${entry.queueEntryId}',
    );
    final session = ref.read(groupListeningSessionControllerProvider);
    final room = session.room;
    if (room != null && room.self.canControl) {
      await ref
          .read(groupListeningSessionControllerProvider.notifier)
          .sendMutation(
            type: GroupListeningMutationType.queueRemove,
            targetQueueEntryId: entry.queueEntryId,
          );
      return true;
    }
    await ref
        .read(queueProvider.notifier)
        .skipUnresolvableGroupListening(
          queueEntryId: entry.queueEntryId,
        );
    return true;
  }

  bool _isBenignPlaybackApplyFailure(Object error) {
    final message = error.toString();
    return message.contains('Loading interrupted') ||
        message.contains('OperationCancelledException');
  }
}
