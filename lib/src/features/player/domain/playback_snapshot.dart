import 'package:audio_service/audio_service.dart';
export 'package:audio_service/audio_service.dart' show AudioProcessingState;
import 'package:flutter/foundation.dart';

/// Metadata for the currently playing radio station.
@immutable
class RadioStationMetadata {
  const RadioStationMetadata({
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

  RadioStationMetadata copyWith({
    String? stationId,
    String? stationName,
    String? streamUrl,
    String? homePageUrl,
    String? nowPlayingTitle,
    String? nowPlayingArtist,
    String? nowPlayingArtUrl,
  }) {
    return RadioStationMetadata(
      stationId: stationId ?? this.stationId,
      stationName: stationName ?? this.stationName,
      streamUrl: streamUrl ?? this.streamUrl,
      homePageUrl: homePageUrl ?? this.homePageUrl,
      nowPlayingTitle: nowPlayingTitle ?? this.nowPlayingTitle,
      nowPlayingArtist: nowPlayingArtist ?? this.nowPlayingArtist,
      nowPlayingArtUrl: nowPlayingArtUrl ?? this.nowPlayingArtUrl,
    );
  }
}

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
    this.isCurrentSongLiked = false,
    this.radioStation,
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
      repeatMode = AudioServiceRepeatMode.none,
      isCurrentSongLiked = false,
      radioStation = null;

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

  /// Whether the player is in radio mode (streaming a radio station).
  bool get isRadioMode => radioStation != null;

  bool get hasQueue => queueSongIds.isNotEmpty;

  /// Whether there is something active — either a song queue or a radio stream.
  bool get hasActivePlayback => hasQueue || isRadioMode;

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
    );
  }

  /// Returns a copy with radioStation explicitly set to null.
  PlaybackSnapshot clearRadioStation() {
    return PlaybackSnapshot(
      queueSongIds: queueSongIds,
      currentSongId: currentSongId,
      currentIndex: currentIndex,
      playing: playing,
      processingState: processingState,
      position: position,
      duration: duration,
      bufferedPosition: bufferedPosition,
      shuffleMode: shuffleMode,
      repeatMode: repeatMode,
      isCurrentSongLiked: isCurrentSongLiked,
    );
  }
}
