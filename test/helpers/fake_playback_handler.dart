import 'package:audio_service/audio_service.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';

/// A playback handler whose every member is inert: idle snapshot, empty
/// streams, unsupported equalizer and no-op commands. Test fakes extend it and
/// override only the behaviour they exercise.
class InertPlaybackHandler implements NavisPlaybackHandler {
  @override
  PlaybackSnapshot get snapshot => const PlaybackSnapshot.idle();
  @override
  Stream<PlaybackSnapshot> get snapshotStream => const Stream.empty();
  @override
  Stream<TransportVisualCue> get transportVisualCueStream =>
      const Stream.empty();
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  PlaybackBufferState get bufferState => const PlaybackBufferState.idle();
  @override
  Stream<PlaybackBufferState> get bufferStateStream => const Stream.empty();
  @override
  MediaItem? get currentMediaItem => null;
  @override
  Stream<MediaItem?> get mediaItemStream => const Stream.empty();
  @override
  Stream<PlaybackLoadFailure> get loadFailureStream => const Stream.empty();
  @override
  Stream<QueueSongsDropped> get droppedSongsStream => const Stream.empty();
  @override
  Stream<void> get radioStreamErrorStream => const Stream.empty();

  @override
  PlaybackAdjustments get playbackAdjustments => const PlaybackAdjustments();
  @override
  Stream<PlaybackAdjustments> get playbackAdjustmentsStream =>
      const Stream.empty();
  @override
  PlaybackAdjustmentCapabilities get playbackAdjustmentCapabilities =>
      PlaybackAdjustmentCapabilities.android;

  @override
  EqCapabilities get equalizerCapabilities => EqCapabilities.unavailable;
  @override
  EqApplicationState get equalizerState => EqApplicationState(
    desired: EqConfiguration.flat(),
    applied: EqConfiguration.flat(),
  );
  @override
  Stream<EqApplicationState> get equalizerStateStream => const Stream.empty();
  @override
  Future<void> setEqualizer(EqConfiguration values) async =>
      throw UnsupportedError('This fake has no EQ backend');
  @override
  Future<void> refreshEqualizerState() async {}

  @override
  Future<void> waitUntilReady() async {}
  @override
  Future<void> retryDeferredQueueRestore() async {}
  @override
  Future<void> applyRuntimeSettings() async {}
  @override
  Future<void> applySongIdentityAliases(Map<String, String> aliases) async {}

  @override
  Future<void> replaceQueue(
    List<String> songIds, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    List<String>? originalOrder,
  }) async {}
  @override
  Future<void> replaceQueueWithData(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    List<String>? originalOrder,
  }) async {}
  @override
  Future<void> addToQueue(
    List<String> songIds, {
    bool expandMatchFlows = true,
  }) async {}
  @override
  Future<void> playNext(
    List<String> songIds, {
    bool expandMatchFlows = true,
  }) async {}
  @override
  Future<void> retainCurrentSongAsQueue(String songId) async {}
  @override
  Future<void> playFromIndex(int index) async {}
  @override
  Future<void> removeAt(int index) async {}
  @override
  Future<void> reorderQueue(int oldIndex, int newIndex) async {}
  @override
  Future<void> clearQueue() async {}
  @override
  Future<void> resetSession() => clearQueue();

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> skipToNext() async {}
  @override
  Future<void> skipToPrevious() async {}
  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {}
  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setPlaybackSpeed(double speed) async {}
  @override
  Future<void> setPlaybackAdjustments(PlaybackAdjustments values) =>
      setPlaybackSpeed(values.speed);

  @override
  Future<void> toggleLike() async {}
  @override
  Future<void> syncSongLikedState(String songId, {required bool liked}) async {}

  @override
  Future<void> playRadioStream({
    required String stationId,
    required String stationName,
    required String streamUrl,
    String? homePageUrl,
  }) async {}
  @override
  Future<void> stopRadio() async {}
  @override
  void updateRadioMetadata({
    String? title,
    String? artist,
    String? artUrl,
    bool replaceMetadata = false,
  }) {}

  @override
  Map<String, Object?> collectPlaybackDiagnostics() =>
      const <String, Object?>{};

  @override
  void registerPreferredMixCallback(
    Future<void> Function(String seedSongId) callback,
  ) {}
  @override
  void registerPreferredMixToggleCallback(
    Future<void> Function(String seedSongId) callback,
  ) {}
}
