import 'package:audio_service/audio_service.dart';
export 'package:audio_service/audio_service.dart' show AudioProcessingState;
import 'package:flutter/foundation.dart';
import 'package:navis/src/utils/catalog_source.dart';

const Object _unmodifiedPendingQueueIndex = Object();

enum ManualTrackChangeDirection { next, previous }

/// The visual outcome of a user-originated transport request.
///
/// This is deliberately independent from playback completion.  The handler
/// emits it immediately before applying the transport command, so touch,
/// keyboard, headset, and desktop media-session controls all lead to the same
/// visual response without ever waiting for UI animation.
enum TransportVisualIntent {
  next,
  previous,
  restartCurrent,
  unavailableNext,
  unavailablePrevious,
}

@immutable
class TransportVisualCue {
  const new({
    required this.token,
    required this.intent,
    required this.fromSongId,
  });

  final int token;
  final TransportVisualIntent intent;
  final String? fromSongId;
}

/// Lightweight buffering state for the active song timeline.
///
/// The song id prevents a late buffered-position event from being rendered on
/// a newly selected track.
///
/// [bufferedPosition] is the range playable from the start of the song. After
/// a seek past it the player buffers a second range, [aheadStart] to
/// [aheadEnd], that is not contiguous with the first (both null otherwise).
@immutable
class PlaybackBufferState {
  const new({
    required this.songId,
    required this.bufferedPosition,
    this.aheadStart,
    this.aheadEnd,
  });

  const new idle()
    : songId = null,
      bufferedPosition = Duration.zero,
      aheadStart = null,
      aheadEnd = null;

  final String? songId;
  final Duration bufferedPosition;
  final Duration? aheadStart;
  final Duration? aheadEnd;

  @override
  bool operator ==(Object other) =>
      other is PlaybackBufferState &&
      other.songId == songId &&
      other.bufferedPosition == bufferedPosition &&
      other.aheadStart == aheadStart &&
      other.aheadEnd == aheadEnd;

  @override
  int get hashCode =>
      Object.hash(songId, bufferedPosition, aheadStart, aheadEnd);
}

Duration resolveEffectivePlaybackDuration({
  required bool isRadioMode,
  required Duration? mediaDuration,
  required Duration? playerDuration,
}) {
  final validMediaDuration =
      mediaDuration != null && mediaDuration > Duration.zero
      ? mediaDuration
      : null;
  final validPlayerDuration =
      playerDuration != null && playerDuration > Duration.zero
      ? playerDuration
      : null;
  if (isRadioMode) {
    return validPlayerDuration ?? validMediaDuration ?? Duration.zero;
  }
  return validMediaDuration ?? validPlayerDuration ?? Duration.zero;
}

/// A station outside the server cannot play while online services are off.
class RadioPlaybackBlockedException implements Exception {
  const new();
}

/// Radio startup failed; the handler owns queue recovery and the error notice.
class RadioPlaybackUnavailableException implements Exception {
  const new();
}

/// Metadata for the currently playing radio station.
@immutable
class RadioStationMetadata {
  const new({
    required this.stationId,
    required this.stationName,
    required this.streamUrl,
    this.homePageUrl,
    this.nowPlayingTitle,
    this.nowPlayingArtist,
    this.nowPlayingArtUrl,
  });

  final String stationId;
  final String stationName;
  final String streamUrl;
  final String? homePageUrl;

  /// Live metadata from Azuracast or ICY headers.
  final String? nowPlayingTitle;
  final String? nowPlayingArtist;
  final String? nowPlayingArtUrl;
}

@immutable
class PlaybackSnapshot {
  const new({
    required this.queueSongIds,
    required this.currentSongId,
    required this.currentIndex,
    required this.playing,
    required this.processingState,
    required this.position,
    required this.duration,
    required this.bufferedPosition,
    required this.shuffleMode,
    required this.repeatMode,
    this.isCurrentSongLiked = false,
    this.radioStation,
    this.isLoading = false,
    this.hasPendingLogicalQueue = false,
    this.pendingQueueIndex,
    this.pendingSeekPosition,
    this.loadingSongId,
    this.lastFailedSongId,
  });

  const new idle()
    : queueSongIds = const <String>[],
      currentSongId = null,
      currentIndex = null,
      playing = false,
      processingState = AudioProcessingState.idle,
      position = Duration.zero,
      duration = Duration.zero,
      bufferedPosition = Duration.zero,
      shuffleMode = AudioServiceShuffleMode.none,
      repeatMode = AudioServiceRepeatMode.none,
      isCurrentSongLiked = false,
      radioStation = null,
      isLoading = false,
      hasPendingLogicalQueue = false,
      pendingQueueIndex = null,
      pendingSeekPosition = null,
      loadingSongId = null,
      lastFailedSongId = null;

  final List<String> queueSongIds;
  final String? currentSongId;
  final int? currentIndex;
  final bool playing;
  final AudioProcessingState processingState;
  final Duration position;
  final Duration duration;
  final Duration bufferedPosition;
  final AudioServiceShuffleMode shuffleMode;
  final AudioServiceRepeatMode repeatMode;
  final bool isCurrentSongLiked;

  /// Non-null when playing a radio stream instead of a song queue.
  final RadioStationMetadata? radioStation;

  /// True while the handler is actively switching/loading a target source.
  final bool isLoading;

  /// True when `queueSongIds` represents the requested logical queue while
  /// the transport queue is still preparing audio sources.
  final bool hasPendingLogicalQueue;

  /// Latest requested queue entry while the player confirms a transition.
  final int? pendingQueueIndex;

  /// Target retained while the selected source loads or confirms a seek.
  final Duration? pendingSeekPosition;

  /// Song id currently being loaded, if known.
  final String? loadingSongId;

  /// Most recent song id that failed or timed out during load.
  final String? lastFailedSongId;

  /// Whether the player is in radio mode (streaming a radio station).
  bool get isRadioMode => radioStation != null;

  bool get hasQueue => queueSongIds.isNotEmpty;

  /// Whether there is something active — either a song queue or a radio stream.
  bool get hasActivePlayback => hasQueue || isRadioMode;

  /// Playing or loading takes priority over automatic background catalog work.
  /// A paused queue remains visible without indefinitely deferring sync.
  bool get defersBackgroundSync =>
      playing ||
      isLoading ||
      processingState == AudioProcessingState.loading ||
      processingState == AudioProcessingState.buffering;

  PlaybackSnapshot copyWith({
    List<String>? queueSongIds,
    String? currentSongId,
    int? currentIndex,
    bool? playing,
    AudioProcessingState? processingState,
    Duration? position,
    Duration? duration,
    Duration? bufferedPosition,
    AudioServiceShuffleMode? shuffleMode,
    AudioServiceRepeatMode? repeatMode,
    bool? isCurrentSongLiked,
    RadioStationMetadata? radioStation,
    bool? isLoading,
    bool? hasPendingLogicalQueue,
    Object? pendingQueueIndex = _unmodifiedPendingQueueIndex,
    Object? pendingSeekPosition = _unmodifiedPendingQueueIndex,
    String? loadingSongId,
    String? lastFailedSongId,
  }) {
    return PlaybackSnapshot(
      queueSongIds: queueSongIds ?? this.queueSongIds,
      currentSongId: currentSongId ?? this.currentSongId,
      currentIndex: currentIndex ?? this.currentIndex,
      playing: playing ?? this.playing,
      processingState: processingState ?? this.processingState,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      bufferedPosition: bufferedPosition ?? this.bufferedPosition,
      shuffleMode: shuffleMode ?? this.shuffleMode,
      repeatMode: repeatMode ?? this.repeatMode,
      isCurrentSongLiked: isCurrentSongLiked ?? this.isCurrentSongLiked,
      radioStation: radioStation ?? this.radioStation,
      isLoading: isLoading ?? this.isLoading,
      hasPendingLogicalQueue:
          hasPendingLogicalQueue ?? this.hasPendingLogicalQueue,
      pendingQueueIndex:
          identical(pendingQueueIndex, _unmodifiedPendingQueueIndex)
          ? this.pendingQueueIndex
          : pendingQueueIndex as int?,
      pendingSeekPosition:
          identical(pendingSeekPosition, _unmodifiedPendingQueueIndex)
          ? this.pendingSeekPosition
          : pendingSeekPosition as Duration?,
      loadingSongId: loadingSongId ?? this.loadingSongId,
      lastFailedSongId: lastFailedSongId ?? this.lastFailedSongId,
    );
  }
}

/// Whether a remote source is actually preventing the active song from playing.
/// Queue fill may continue after the selected source is already ready.
bool shouldShowRemotePlaybackLoading({
  required PlaybackSnapshot playback,
  required bool currentIsExternal,
}) {
  if (playback.isRadioMode) {
    return false;
  }

  final loadingSongId = playback.loadingSongId;
  final loadingTargetIsExternal = loadingSongId == playback.currentSongId
      ? currentIsExternal ||
            (loadingSongId != null &&
                isExternalCatalogSource(id: loadingSongId))
      : loadingSongId != null && isExternalCatalogSource(id: loadingSongId);
  if (playback.isLoading &&
      loadingSongId != null &&
      playback.currentSongId != loadingSongId) {
    // A new selection owns the button even while the previous song's metadata
    // and buffering state are still on screen.
    return loadingTargetIsExternal;
  }
  if (playback.isLoading && loadingTargetIsExternal) {
    if (playback.currentSongId != loadingSongId ||
        playback.processingState != AudioProcessingState.ready) {
      return true;
    }
  }

  final currentSongId = playback.currentSongId;
  final activeIsExternal =
      currentIsExternal ||
      (currentSongId != null && isExternalCatalogSource(id: currentSongId));
  return activeIsExternal &&
      playback.playing &&
      (playback.processingState == AudioProcessingState.loading ||
          playback.processingState == AudioProcessingState.buffering);
}
