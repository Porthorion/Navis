import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

@immutable
class PlaybackSnapshot {
  const PlaybackSnapshot({
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
  });

  const PlaybackSnapshot.idle()
    : queueSongIds = const <String>[],
      currentSongId = null,
      currentIndex = null,
      playing = false,
      processingState = AudioProcessingState.idle,
      position = Duration.zero,
      duration = Duration.zero,
      bufferedPosition = Duration.zero,
      shuffleMode = AudioServiceShuffleMode.none,
      repeatMode = AudioServiceRepeatMode.none;

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

  bool get hasQueue => queueSongIds.isNotEmpty;

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
    );
  }
}
