// Issue #479 (sweep item 479a): on the Darwin backends the first song of a
// replaced queue must play at its ReplayGain cut while phase 2 of the load is
// still filling the queue, not only once the load commits.
//
// Self-contained on purpose: navis_audio_handler_navigation_test.dart has
// macOS-local failures, so this check lives in its own file with a trimmed
// copy of that file's fake player and handler setup.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:audio_service_platform_interface/no_op_audio_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/cache/data/rolling_cache_manager.dart';
import 'package:navis/src/features/player/data/listenbrainz_feedback_service.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/data/playback_transport_trace.dart';
import 'package:navis/src/features/player/data/scrobble_service.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';
import 'package:navis/src/features/player/domain/streaming_quality.dart';

import '../../../../helpers/test_database.dart';

/// Holds the resolve of [blockedSongId] (a song only phase 2 resolves) open
/// until [release] completes, so phase 1 has started the queue while phase 2
/// is still running.
class _GatedResolver extends Fake implements PlaybackSourceResolver {
  new(this.delegate, this.blockedSongId);
  final PlaybackSourceResolver delegate;
  final String blockedSongId;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Uri? resolveArtUri(SongsTableData song) => delegate.resolveArtUri(song);
  @override
  PlaybackTransportTrace? get transportTrace => delegate.transportTrace;
  @override
  bool get supportsTranscodeOffset => delegate.supportsTranscodeOffset;
  @override
  Object get seekPreviewRepresentation => delegate.seekPreviewRepresentation;
  @override
  bool get supportsFastSeeking => delegate.supportsFastSeeking;

  @override
  Future<ResolvedPlaybackSource> resolveForSong(
    SongsTableData song, {
    bool preferLockCaching = true,
    bool allowStreaming = true,
    Duration? transcodeOffset,
    bool fastSeekBridge = false,
  }) async {
    if (song.id == blockedSongId) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    return await delegate.resolveForSong(
      song,
      preferLockCaching: preferLockCaching,
      allowStreaming: allowStreaming,
      transcodeOffset: transcodeOffset,
      fastSeekBridge: fastSeekBridge,
    );
  }
}

class _NoopScrobbleService extends Fake implements ScrobbleService {
  @override
  Future<void> flushDue() async {}
  @override
  Future<void> dispose() async {}
  @override
  void start() {}
  @override
  Future<void> enqueueNowPlaying({
    required String songId,
    required String sessionKey,
    ScrobbleTrackPayload? track,
  }) async {}
  @override
  Future<void> enqueueSubmission({
    required String songId,
    required String sessionKey,
    ScrobbleTrackPayload? track,
  }) async {}
}

/// A trimmed copy of the navigation test's `_ControllableAudioPlayer`: just
/// enough native behaviour for a queue load, and every volume write recorded.
class _FakePlayer extends Fake implements AudioPlayer {
  final _indices = StreamController<int?>.broadcast();
  final _events = StreamController<PlaybackEvent>.broadcast();
  final _discontinuities = StreamController<PositionDiscontinuity>.broadcast();
  final _shuffleModes = StreamController<bool>.broadcast();
  final _loopModes = StreamController<LoopMode>.broadcast();
  final _bufferedPositions = StreamController<Duration>.broadcast();
  List<AudioSource> _sources = <AudioSource>[];
  ProcessingState state = ProcessingState.idle;
  bool isPlaying = false;
  int? index;
  Duration _position = Duration.zero;
  LoopMode _loopMode = LoopMode.off;
  final List<double> appliedVolumes = [];

  @override
  PlaybackEvent get playbackEvent => PlaybackEvent(
    processingState: state,
    updatePosition: _position,
    duration: duration,
    currentIndex: index,
  );
  @override
  Stream<PlaybackEvent> get playbackEventStream => _events.stream;
  @override
  Stream<int?> get currentIndexStream => _indices.stream;
  @override
  Stream<PositionDiscontinuity> get positionDiscontinuityStream =>
      _discontinuities.stream;
  @override
  Stream<bool> get shuffleModeEnabledStream => _shuffleModes.stream;
  @override
  Stream<LoopMode> get loopModeStream => _loopModes.stream;
  @override
  Stream<Duration> get bufferedPositionStream => _bufferedPositions.stream;
  @override
  Stream<Duration> createPositionStream({
    int steps = 800,
    Duration minPeriod = const Duration(milliseconds: 200),
    Duration maxPeriod = const Duration(milliseconds: 200),
  }) => const Stream<Duration>.empty();
  @override
  Stream<IcyMetadata?> get icyMetadataStream =>
      const Stream<IcyMetadata?>.empty();
  @override
  IcyMetadata? get icyMetadata => null;

  @override
  Future<EqualizerStateMessage> getEqualizerState() async =>
      const EqualizerStateMessage(enabled: false);
  @override
  Future<EqualizerStateMessage> setEqualizer(
    EqualizerConfigurationMessage configuration,
  ) async => const EqualizerStateMessage(enabled: false);
  @override
  Future<void> setReplayGainLevels({
    required Map<IndexedAudioSource, double> bySource,
    bool live = false,
  }) async {}
  @override
  Future<void> setReplayGainBoost({
    required double currentDb,
    Map<IndexedAudioSource, double> bySource = const {},
    Map<IndexedAudioSource, int> durationMsBySource = const {},
  }) async {}

  @override
  ProcessingState get processingState => state;
  @override
  bool get playing => isPlaying;
  @override
  int? get currentIndex => index;
  @override
  Duration get position => _position;
  @override
  Duration get bufferedPosition => Duration.zero;
  @override
  Duration? get duration => const Duration(minutes: 3);
  @override
  double get volume => appliedVolumes.lastOrNull ?? 1;
  @override
  double get speed => 1;
  @override
  double get pitch => 1;
  @override
  LoopMode get loopMode => _loopMode;
  @override
  bool get shuffleModeEnabled => false;
  @override
  List<int> get effectiveIndices =>
      List<int>.generate(_sources.length, (value) => value);
  @override
  List<AudioSource> get audioSources =>
      List<AudioSource>.unmodifiable(_sources);
  @override
  List<IndexedAudioSource> get sequence => <IndexedAudioSource>[
    for (final source in _sources) ...source.sequence,
  ];

  @override
  Future<void> setVolume(double value) async => appliedVolumes.add(value);
  @override
  Future<void> setSpeed(double value) async {}
  @override
  Future<void> setPitch(double value) async {}
  @override
  Future<void> setLoopMode(LoopMode value) async => _loopMode = value;
  @override
  Future<void> setShuffleModeEnabled(bool value) async {}
  @override
  Future<void> shuffle() async {}

  @override
  Future<void> play() async {
    isPlaying = true;
    _events.add(playbackEvent);
  }

  @override
  Future<void> pause() async {
    isPlaying = false;
    _events.add(playbackEvent);
  }

  @override
  Future<void> stop() async {
    isPlaying = false;
    state = ProcessingState.idle;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    if (position != null) _position = position;
    if (index != null) this.index = index;
    _indices.add(this.index);
  }

  @override
  Future<Duration?> setAudioSource(
    AudioSource audioSource, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) => setAudioSources(
    [audioSource],
    preload: preload,
    initialIndex: initialIndex,
    initialPosition: initialPosition,
  );

  @override
  Future<Duration?> setAudioSources(
    List<AudioSource> sources, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ShuffleOrder? shuffleOrder,
  }) async {
    _position = initialPosition ?? Duration.zero;
    _sources = List<AudioSource>.of(sources);
    index = sources.isEmpty ? null : initialIndex ?? 0;
    state = sources.isEmpty || !preload
        ? ProcessingState.idle
        : ProcessingState.ready;
    _indices.add(index);
    return const Duration(minutes: 3);
  }

  @override
  Future<void> addAudioSource(AudioSource source) async => _sources.add(source);
  @override
  Future<void> addAudioSources(List<AudioSource> sources) async =>
      _sources.addAll(sources);
  @override
  Future<void> insertAudioSource(int at, AudioSource source) =>
      insertAudioSources(at, [source]);
  @override
  Future<void> insertAudioSources(int at, List<AudioSource> sources) async {
    _sources.insertAll(at, sources);
    if (index != null && at <= index!) index = index! + sources.length;
    _indices.add(index);
  }

  @override
  Future<void> moveAudioSource(int currentIndex, int newIndex) async {
    _sources.insert(newIndex, _sources.removeAt(currentIndex));
  }

  @override
  Future<void> removeAudioSourceAt(int index) async {
    _sources.removeAt(index);
    if (this.index != null && index < this.index!) this.index = this.index! - 1;
  }

  @override
  Future<void> removeAudioSourceRange(int start, int end) async {
    _sources.removeRange(start, end);
    final current = index;
    if (current != null && current >= end) index = current - (end - start);
  }

  @override
  Future<void> dispose() async {
    isPlaying = false;
    await _indices.close();
    await _events.close();
    await _discontinuities.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => AudioServicePlatform.instance = NoOpAudioService());

  const count = 12;
  const firstSongGainDb = -12.0;

  /// A handler on [caps] with the Dart cut through the player volume (no
  /// in-pipeline ReplayGain), mode 'track', whose first song is tagged
  /// [firstSongGainDb]. Phase 2 blocks on song-5.
  Future<(NavisAudioHandler, _FakePlayer, _GatedResolver)> create(
    PlaybackAdjustmentCapabilities caps, {
    required bool ios,
  }) async {
    final directory = await Directory.systemTemp.createTemp('navis-479a-');
    final database = createTestDatabase();
    await database.libraryDao.upsertSongs([
      for (var i = 0; i < count; i++)
        SongsTableCompanion.insert(
          id: 'song-$i',
          title: 'Song $i',
          replayGainTrackGain: Value(i == 0 ? firstSongGainDb : null),
        ),
    ]);
    for (var i = 0; i < count; i++) {
      final file = File('${directory.path}/song-$i.mp3');
      await file.writeAsBytes(<int>[1, 2, 3]);
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'song-$i',
          filePath: file.path,
          fileSize: 3,
          format: 'mp3',
          cacheType: CacheType.permanent,
          downloadStatus: DownloadStatus.complete,
          lastAccessedAt: DateTime.now(),
        ),
      );
    }
    final cache = RollingCacheManager(cacheDao: database.cacheDao);
    final resolver = _GatedResolver(
      PlaybackSourceResolver(
        cacheDao: database.cacheDao,
        libraryDao: database.libraryDao,
        rollingCacheManager: cache,
        readApiClient: () => null,
        readStreamingQuality: () => const StreamingQuality(label: 'original'),
        readRollingCacheDirectory: () async => directory,
        readCachedPlaybackFirst: () => true,
      ),
      'song-5',
    );
    final player = _FakePlayer();
    final handler = NavisAudioHandler(
      startPersonalRadio: (autoPlay, {isCurrent}) async => false,
      startPreferredMix: (_) async {},
      togglePreferredMix: (_) async {},
      libraryDao: database.libraryDao,
      playlistDao: database.playlistDao,
      playQueueDao: database.playQueueDao,
      matchFlowDao: database.matchFlowDao,
      historyDao: database.historyDao,
      sourceResolver: resolver,
      readApiClient: () => null,
      rollingCacheManager: cache,
      readRollingCacheBudgetBytes: () => 1024 * 1024,
      scrobbleService: _NoopScrobbleService(),
      listenBrainzFeedbackService: ListenBrainzFeedbackService(
        dao: database.listenBrainzFeedbackDao,
        libraryDao: database.libraryDao,
        readCredentials: () async => null,
        createClient: () => throw StateError('not used'),
        readReachable: () => false,
      ),
      readRuntimeSettings: () => const PlaybackRuntimeSettings(
        gaplessEnabled: true,
        fastSeekingEnabled: true,
        nextSongPrefetchAllowed: true,
        crossfadeEnabled: false,
        crossfadeAllowStreaming: true,
        crossfadeDurationSeconds: 5,
        crossfadeType: 'normal',
        replayGainMode: 'track',
        replayGainPreamp: 0,
        replayGainUntaggedDb: replayGainFallbackUntaggedDb,
        playbackSpeed: 1,
        albumQueueEnabled: false,
        matchFlowEnabled: false,
      ),
      adjustmentCapabilities: caps,
      replayGainInPipelineOverride: false,
      starSyncDao: database.starSyncDao,
      player: player,
      iosRuntimeOverride: ios,
      desktopRuntimeOverride: !ios,
      shuffleRandom: Random(7),
    );
    addTearDown(() async {
      if (!resolver.release.isCompleted) resolver.release.complete();
      await handler.disposeHandler();
      await database.close();
      await directory.delete(recursive: true);
    });
    await handler.waitUntilReady();
    await handler.debugWaitForStartupQueueRestore();
    return (handler, player, resolver);
  }

  for (final (name, caps, ios, curve) in [
    // AVQueuePlayer: linear volume.
    ('iOS', PlaybackAdjustmentCapabilities.ios, true, 20.0),
    // macOS mpv outside the pipeline: cubic volume.
    ('macOS mpv', PlaybackAdjustmentCapabilities.mediaKit, false, 60.0),
  ]) {
    test('$name: the first song plays at its ReplayGain cut while phase 2 '
        'is still filling the queue', () async {
      final (handler, player, resolver) = await create(caps, ios: ios);
      final cut = pow(10, firstSongGainDb / curve).toDouble();

      final replaced = handler.replaceQueue([
        for (var i = 0; i < count; i++) 'song-$i',
      ], expandMatchFlows: false);
      // Phase 2 resolving song-5 means phase 1 has loaded song-0 and issued
      // Play.
      await resolver.entered.future;
      await pumpEventQueue();

      expect(player.playing, isTrue, reason: 'phase 1 started the song');
      expect(player.currentIndex, 0);
      expect(handler.currentMediaItem?.id, 'song-0');
      expect(
        handler.collectPlaybackDiagnostics()['queueSettled'],
        isFalse,
        reason: 'phase 2 is still running',
      );
      expect(
        player.volume,
        closeTo(cut, 0.00001),
        reason: 'song-0 is audible, so its $firstSongGainDb dB cut applies now',
      );

      resolver.release.complete();
      await replaced;
      await pumpEventQueue();
      expect(handler.collectPlaybackDiagnostics()['queueSettled'], isTrue);
      expect(player.volume, closeTo(cut, 0.00001));
    });
  }
}
