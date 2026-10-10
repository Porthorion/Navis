part of 'navis_audio_handler.dart';

/// Optional startup telemetry supported by the production handler wrappers.
/// Test handlers may omit it without changing playback behavior.
abstract interface class PlaybackStartupObserver {
  int beginPlaybackSelection(String songId, {required bool isExternal});
  void notePlaybackSelectionStage(int attempt, String stage);
  bool isPlaybackSelectionCurrent(int attempt);
}

/// A run of songs inserted contiguously at a logical queue index.
@immutable
class QueueInsertRun {
  const new(this.index, this.songs);

  final int index;
  final List<SongsTableData> songs;
}

/// Outcome of a batched queue edit.
@immutable
class QueueBatchEditResult {
  const new({this.skippedSongIds = const <String>[]});

  /// Songs that could not be queued because no playable source was found.
  final List<String> skippedSongIds;
}

/// Batched queue edits for sources that grow while they play, such as an
/// artist whose releases are still loading. Optional: callers fall back to
/// [NavisPlaybackHandler.addToQueue] for handlers without it.
abstract interface class QueueBatchEditor {
  /// Inserts [songs] at uniformly random positions among the upcoming songs
  /// at or after logical index [notBefore]; the next two songs keep their
  /// place, and once part of the queue waits outside the player, every song
  /// the player holds keeps its place too. Costs at most one native removal
  /// regardless of how many songs arrive, and none once songs are deferred.
  Future<QueueBatchEditResult> mergeIntoUpcoming(
    List<SongsTableData> songs, {
    required int notBefore,
    math.Random? random,
  });

  /// Inserts each run's songs contiguously at its logical index. Indices
  /// refer to the queue before the call; runs are applied from the highest
  /// index down, so earlier runs do not shift later ones.
  Future<QueueBatchEditResult> insertQueueRuns(List<QueueInsertRun> runs);
}

abstract class NavisPlaybackHandler {
  PlaybackSnapshot get snapshot;
  Stream<PlaybackSnapshot> get snapshotStream;
  Stream<TransportVisualCue> get transportVisualCueStream;
  Stream<Duration> get positionStream;
  PlaybackBufferState get bufferState;
  Stream<PlaybackBufferState> get bufferStateStream;
  MediaItem? get currentMediaItem;
  Stream<MediaItem?> get mediaItemStream;
  Stream<PlaybackLoadFailure> get loadFailureStream;

  /// Songs the handler took out of the queue after accepting them, because
  /// they could not be prepared when the player needed them.
  Stream<QueueSongsDropped> get droppedSongsStream => const Stream.empty();

  /// Emits when a radio stream encounters a mid-playback error (e.g. HTTP 503,
  /// connection reset). The UI should show a dismissible error notification.
  Stream<void> get radioStreamErrorStream;

  Future<void> waitUntilReady();

  /// Retries a startup queue restore that was deferred because no playback
  /// source was available yet. A no-op once the user has started playback.
  Future<void> retryDeferredQueueRestore();

  /// Replaces the queue with [songIds].
  ///
  /// [originalOrder] supplies pre-shuffle occurrence IDs when the caller
  /// already shuffled [songIds]; the handler preserves that play order.
  Future<void> replaceQueue(
    List<String> songIds, {
    int startIndex,
    bool autoPlay,
    bool expandMatchFlows,
    List<String>? originalOrder,
  });

  /// Replaces the queue using pre-fetched [SongsTableData] rows.
  ///
  /// Exact supplied sources bypass the library read. Local retired identities
  /// and Match Flow expansion reread rows; queues containing external rows
  /// retain every supplied row and bypass expansion. [originalOrder] supplies
  /// pre-shuffle occurrence IDs for an already shuffled entity selection.
  Future<void> replaceQueueWithData(
    List<SongsTableData> songs, {
    int startIndex,
    bool autoPlay,
    bool expandMatchFlows,
    List<String>? originalOrder,
  });

  Future<void> addToQueue(List<String> songIds, {bool expandMatchFlows});
  Future<void> playNext(List<String> songIds, {bool expandMatchFlows});
  Future<void> retainCurrentSongAsQueue(String songId);
  Future<void> playFromIndex(int index);
  Future<void> removeAt(int index);
  Future<void> reorderQueue(int oldIndex, int newIndex);
  Future<void> clearQueue();
  Future<void> resetSession();
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);

  /// Structured playback state for the Linux sync-diagnostics API.
  Map<String, Object?> collectPlaybackDiagnostics();

  Future<void> skipToNext();
  Future<void> skipToPrevious();
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode);
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode);
  Future<void> setPlaybackSpeed(double speed);
  PlaybackAdjustmentCapabilities get playbackAdjustmentCapabilities;
  PlaybackAdjustments get playbackAdjustments;
  Stream<PlaybackAdjustments> get playbackAdjustmentsStream =>
      const Stream.empty();
  Future<void> setPlaybackAdjustments(PlaybackAdjustments values);
  EqCapabilities get equalizerCapabilities => EqCapabilities.unavailable;
  EqApplicationState get equalizerState => EqApplicationState(
    desired: EqConfiguration.flat(),
    applied: EqConfiguration.flat(),
  );
  Stream<EqApplicationState> get equalizerStateStream => const Stream.empty();
  Future<void> setEqualizer(EqConfiguration values) =>
      Future.error(UnsupportedError('Equalizer is unavailable.'));
  Future<void> refreshEqualizerState() async {}
  Future<void> setVolume(double volume);
  Future<void> applyRuntimeSettings();

  /// Remap retired provisional song IDs in the logical queue after library
  /// sync without replacing or interrupting the active audio source.
  Future<void> applySongIdentityAliases(Map<String, String> aliases);

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
  ///
  /// With [replaceMetadata], null fields clear previous song metadata instead
  /// of preserving it. Policy-only refreshes leave this false.
  void updateRadioMetadata({
    String? title,
    String? artist,
    String? artUrl,
    bool replaceMetadata = false,
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

/// Why queued songs were dropped.
enum QueueDropReason {
  /// A deferred song could not be prepared when it was released.
  release,

  /// Songs could not be added (an insert or a move into the window).
  insert,

  /// A rebuild of the player (timeout recovery, far jump) could not
  /// prepare them.
  rebuild,
}

@immutable
class QueueSongsDropped {
  const new({required this.songIds, required this.reason});

  final List<String> songIds;
  final QueueDropReason reason;
}

@immutable
class PlaybackLoadFailure {
  const new({
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
  const new({
    required this.gaplessEnabled,
    this.equalizer,
    required this.crossfadeEnabled,
    required this.crossfadeDurationSeconds,
    required this.crossfadeType,
    required this.replayGainMode,
    required this.replayGainPreamp,
    required this.playbackSpeed,
    this.playbackPitchSemitones = 0,
    this.lockPitchToSpeed = false,
    required this.albumQueueEnabled,
    required this.matchFlowEnabled,
  });

  const new defaults()
    : gaplessEnabled = true,
      equalizer = null,
      crossfadeEnabled = false,
      crossfadeDurationSeconds = 5,
      crossfadeType = 'normal',
      replayGainMode = 'off',
      replayGainPreamp = 0.0,
      playbackSpeed = 1.0,
      playbackPitchSemitones = 0,
      lockPitchToSpeed = false,
      albumQueueEnabled = false,
      matchFlowEnabled = false;

  final bool gaplessEnabled;
  final EqConfiguration? equalizer;
  final bool crossfadeEnabled;
  final int crossfadeDurationSeconds;
  final String crossfadeType;

  /// ReplayGain mode: 'off', 'track', or 'album'.
  final String replayGainMode;

  /// ReplayGain pre-amp adjustment in dB (-6 to +6).
  final double replayGainPreamp;

  /// Playback speed multiplier.
  final double playbackSpeed;
  final double playbackPitchSemitones;
  final bool lockPitchToSpeed;

  /// When true, tapping a song in Android Auto queues the full album and
  /// starts at the selected track (mirrors the mobile albumQueueEnabled setting).
  final bool albumQueueEnabled;

  /// When true, user queue actions expand configured Match Flows.
  final bool matchFlowEnabled;
}
