part of 'navis_audio_handler.dart';

abstract class NavisPlaybackHandler {
  PlaybackSnapshot get snapshot;
  Stream<PlaybackSnapshot> get snapshotStream;
  Stream<ManualTrackChangeCue> get manualTrackChangeCueStream;
  Stream<Duration> get positionStream;
  MediaItem? get currentMediaItem;
  Stream<MediaItem?> get mediaItemStream;
  Stream<PlaybackLoadFailure> get loadFailureStream;

  /// Emits when a radio stream encounters a mid-playback error (e.g. HTTP 503,
  /// connection reset). The UI should show a dismissible error notification.
  Stream<void> get radioStreamErrorStream;

  Future<void> waitUntilReady();

  Future<void> replaceQueue(
    List<String> songIds, {
    int startIndex,
    bool autoPlay,
    bool expandMatchFlows,
  });

  /// Like [replaceQueue] but accepts pre-fetched [SongsTableData] rows,
  /// skipping the DB read entirely. Use this when the caller already has the
  /// song data in memory (e.g. album-detail, artist-detail, playlist screens)
  /// to avoid a potentially-blocked read during an ongoing library sync.
  Future<void> replaceQueueWithData(
    List<SongsTableData> songs, {
    int startIndex,
    bool autoPlay,
    bool expandMatchFlows,
  });

  Future<void> addToQueue(List<String> songIds, {bool expandMatchFlows});
  Future<void> playNext(List<String> songIds, {bool expandMatchFlows});
  Future<void> retainCurrentSongAsQueue(String songId);
  Future<void> playFromIndex(int index);
  Future<void> removeAt(int index);
  Future<void> reorderQueue(int oldIndex, int newIndex);
  Future<void> clearQueue();
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> skipToNext();
  Future<void> skipToPrevious();
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode);
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode);
  Future<void> setPlaybackSpeed(double speed);
  Future<void> setVolume(double volume);
  Future<void> applyRuntimeSettings();
  Future<void> toggleLike();

  /// Synchronise the liked state of every queue item whose id matches
  /// [songId]. Call this after an external star/unstar (e.g. from a context
  /// menu) so the now-playing UI reflects the change immediately.
  Future<void> syncSongLikedState(String songId, {required bool liked});

  /// Start playing a radio stream from the given URL.
  ///
  /// Radio playback is independent from the song queue: the existing queue
  /// is preserved and can be resumed by calling [stopRadio].
  Future<void> playRadioStream({
    required String stationId,
    required String stationName,
    required String streamUrl,
    String? homePageUrl,
  });

  /// Stop radio playback. If there was a song queue before radio was started,
  /// it remains intact (but paused).
  Future<void> stopRadio();

  /// Update live metadata for the current radio station (from Azuracast / ICY).
  void updateRadioMetadata({
    String? title,
    String? artist,
    String? artUrl,
  });

  /// Register a callback that implements the user's preferred mix mode
  /// (SameVibes / Last.fm or legacy Subsonic Instant Mix) for Android Auto's
  /// More-tab actions (Instant Mix and Instant Radio).
  ///
  /// Called from the app shell (which has access to both the handler and the
  /// mix-mode providers) to avoid circular-import issues.
  void registerPreferredMixCallback(
    Future<void> Function(String seedSongId) callback,
  );

  /// Register a toggle callback for the Android Auto More-tab Instant Mix
  /// action. Behaves like the in-app player button: deactivates if already
  /// running with the same seed; activates otherwise.
  void registerPreferredMixToggleCallback(
    Future<void> Function(String seedSongId) callback,
  );
}

@immutable
class PlaybackLoadFailure {
  const PlaybackLoadFailure({
    required this.operation,
    required this.message,
    this.songId,
    this.isTimeout = false,
  });

  final String operation;
  final String message;
  final String? songId;
  final bool isTimeout;
}

class PlaybackRuntimeSettings {
  const PlaybackRuntimeSettings({
    required this.gaplessEnabled,
    required this.equalizerEnabled,
    required this.equalizerBandGains,
    required this.loudnessEnabled,
    required this.loudnessTargetGainDb,
    required this.crossfadeEnabled,
    required this.crossfadeDurationSeconds,
    required this.crossfadeType,
    required this.replayGainMode,
    required this.replayGainPreamp,
    required this.playbackSpeed,
    required this.albumQueueEnabled,
    required this.matchFlowEnabled,
  });

  const PlaybackRuntimeSettings.defaults()
    : gaplessEnabled = true,
      equalizerEnabled = false,
      equalizerBandGains = const <double>[],
      loudnessEnabled = false,
      loudnessTargetGainDb = 0,
      crossfadeEnabled = false,
      crossfadeDurationSeconds = 5,
      crossfadeType = 'normal',
      replayGainMode = 'off',
      replayGainPreamp = 0.0,
      playbackSpeed = 1.0,
      albumQueueEnabled = false,
      matchFlowEnabled = false;

  final bool gaplessEnabled;
  final bool equalizerEnabled;
  final List<double> equalizerBandGains;
  final bool loudnessEnabled;
  final double loudnessTargetGainDb;
  final bool crossfadeEnabled;
  final int crossfadeDurationSeconds;
  final String crossfadeType;

  /// ReplayGain mode: 'off', 'track', or 'album'.
  final String replayGainMode;

  /// ReplayGain pre-amp adjustment in dB (-6 to +6).
  final double replayGainPreamp;

  /// Playback speed multiplier (0.5-2.0).
  final double playbackSpeed;

  /// When true, tapping a song in Android Auto queues the full album and
  /// starts at the selected track (mirrors the mobile albumQueueEnabled setting).
  final bool albumQueueEnabled;

  /// When true, user queue actions expand configured Match Flows.
  final bool matchFlowEnabled;
}
