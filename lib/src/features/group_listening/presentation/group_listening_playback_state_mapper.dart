import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_sync_policy.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_controller.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/providers/app_providers.dart';

typedef BridgePlaybackState = ({
  List<String> queueSongIds,
  int? currentIndex,
  String? currentSongId,
  bool playing,
  Duration position,
  bool isRadioMode,
  String processingStateName,
  bool isLoading,
  String? loadingSongId,
});

GroupListeningPlaybackStateView toPolicyView(BridgePlaybackState state) {
  return GroupListeningPlaybackStateView(
    queueSongIds: state.queueSongIds,
    currentIndex: state.currentIndex,
    currentSongId: state.currentSongId,
    playing: state.playing,
    position: state.position,
    isRadioMode: state.isRadioMode,
    processingStateName: state.processingStateName,
    isLoading: state.isLoading,
    loadingSongId: state.loadingSongId,
  );
}

class GroupListeningPlaybackStateMapper {
  GroupListeningPlaybackStateMapper({
    required this.ref,
    required this.getLatestSnapshot,
    required this.getLatestPosition,
    required this.getLastRemoteAnchorReceivedAt,
  });

  final Ref ref;
  final PlaybackSnapshot Function() getLatestSnapshot;
  final Duration Function() getLatestPosition;
  final DateTime? Function() getLastRemoteAnchorReceivedAt;

  BridgePlaybackState playbackStateFromSession(
    GroupListeningSessionState session,
  ) {
    final room = session.room!;
    final anchor = room.playbackAnchor;
    if (anchor == null) {
      return (
        queueSongIds: List<String>.unmodifiable(
          room.queue.entries.map((entry) => entry.songId),
        ),
        currentIndex: room.queue.currentIndex,
        currentSongId: room.queue.currentSongId,
        playing: false,
        position: Duration.zero,
        isRadioMode: false,
        processingStateName: AudioProcessingState.ready.name,
        isLoading: false,
        loadingSongId: null,
      );
    }
    return (
      queueSongIds: List<String>.unmodifiable(
        room.queue.entries.map((entry) => entry.songId),
      ),
      currentIndex: anchor.currentIndex ?? room.queue.currentIndex,
      currentSongId: anchor.currentSongId ?? room.queue.currentSongId,
      playing: anchor.playbackState == GroupListeningPlaybackStatus.playing,
      position: projectedAnchorPosition(anchor),
      isRadioMode: false,
      processingStateName: AudioProcessingState.ready.name,
      isLoading: false,
      loadingSongId: null,
    );
  }

  Duration projectedAnchorPosition(GroupListeningPlaybackAnchor anchor) {
    final receivedAt = getLastRemoteAnchorReceivedAt();
    if (receivedAt == null ||
        anchor.playbackState != GroupListeningPlaybackStatus.playing) {
      return anchor.position;
    }
    final session = ref.read(groupListeningSessionControllerProvider);
    final serverNow = DateTime.now().toUtc().add(session.connection.serverClockOffset);
    final elapsed = serverNow.difference(anchor.capturedAt);
    return anchor.expectedPositionAt(
      anchor.capturedAt.add(elapsed.isNegative ? Duration.zero : elapsed),
    );
  }

  BridgePlaybackState currentLocalPlaybackState() {
    final snapshot =
        ref.read(audioHandlerProvider)?.snapshot ?? getLatestSnapshot();
    final currentIndex = snapshot.currentIndex;
    final queueSongIds = List<String>.unmodifiable(snapshot.queueSongIds);
    final latestPosition = getLatestPosition();
    final position = latestPosition == Duration.zero
        ? snapshot.position
        : latestPosition;
    final currentSongId =
        currentIndex != null &&
            currentIndex >= 0 &&
            currentIndex < queueSongIds.length
        ? queueSongIds[currentIndex]
        : snapshot.currentSongId;
    return (
      queueSongIds: queueSongIds,
      currentIndex: currentIndex,
      currentSongId: currentSongId,
      playing: snapshot.playing,
      position: position,
      isRadioMode: snapshot.isRadioMode,
      processingStateName: snapshot.processingState.name,
      isLoading: snapshot.isLoading,
      loadingSongId: snapshot.loadingSongId,
    );
  }
}
