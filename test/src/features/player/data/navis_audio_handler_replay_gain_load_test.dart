// Issue #479 (sweep item 479a): on the Darwin backends the first song of a
// replaced queue must play at its ReplayGain cut while phase 2 of the load is
// still filling the queue, not only once the load commits.
//
// Self-contained on purpose: the navis_audio_handler_navigation_*_test.dart suite has
// macOS-local failures, so this check lives in its own file with a trimmed
// copy of that file's fake player and handler setup.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart'
    show AudioServiceRepeatMode, AudioServiceShuffleMode;
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:audio_service_platform_interface/no_op_audio_service.dart';
import 'package:audio_session/audio_session.dart';
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

  /// False lets [blockedSongId] resolve at once (an earlier load of the test).
  bool armed = true;

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
    if (armed && song.id == blockedSongId) {
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

/// Just the interruption stream, so ducking can be driven.
class _FakeAudioSession extends Fake implements AudioSession {
  final interruptions = StreamController<AudioInterruptionEvent>.broadcast();

  @override
  Stream<AudioInterruptionEvent> get interruptionEventStream =>
      interruptions.stream;
  @override
  Stream<void> get becomingNoisyEventStream => const Stream<void>.empty();
  @override
  Future<bool> setActive(
    bool active, {
    AVAudioSessionSetActiveOptions? avAudioSessionSetActiveOptions,
    AndroidAudioFocusGainType? androidAudioFocusGainType,
    AndroidAudioAttributes? androidAudioAttributes,
    bool? androidWillPauseWhenDucked,
    AudioSessionConfiguration fallbackConfiguration =
        const AudioSessionConfiguration.music(),
  }) async => true;
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

  /// While set, a seek to an entry reports the new index and then waits: the
  /// native player is already on the target but the seek call has not
  /// returned (an AVQueuePlayer / mpv jump in flight).
  Completer<void>? seekGate;

  /// While set, `setAudioSources` swaps the sequence in and reports it, then
  /// holds the apply open (just_audio broadcasts the new sequence before the
  /// platform load finishes).
  Completer<void>? applyGate;

  /// While true a seek returns with [currentIndex] still on the old entry and
  /// the index lands on a timer afterwards (mpv's index lag, #509).
  bool deferIndex = false;

  /// Each volume write with the native index it landed on.
  final List<(double, int?)> volumeWrites = [];

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

  /// Every update push of in-pipeline levels, in order (a copy of the map).
  final levelPushes = <Map<IndexedAudioSource, double>>[];
  @override
  Future<void> setReplayGainLevels({
    required Map<IndexedAudioSource, double> bySource,
    bool live = false,
  }) async => levelPushes.add(Map.of(bySource));
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
  Future<void> setVolume(double value) async {
    appliedVolumes.add(value);
    volumeWrites.add((value, index));
  }

  @override
  Future<void> setSpeed(double value) async {}
  @override
  Future<void> setPitch(double value) async {}
  @override
  Future<void> setLoopMode(LoopMode value) async {
    _loopMode = value;
    _loopModes.add(value);
  }

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
    if (index != null && deferIndex) {
      Timer(Duration.zero, () {
        this.index = index;
        _indices.add(index);
      });
      return;
    }
    if (index != null) this.index = index;
    _indices.add(this.index);
    final gate = seekGate;
    if (gate != null && index != null) await gate.future;
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
    final gate = applyGate;
    if (gate != null) await gate.future;
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

typedef _Rig = ({
  NavisAudioHandler handler,
  _FakePlayer player,
  _GatedResolver resolver,
  _FakeAudioSession session,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => AudioServicePlatform.instance = NoOpAudioService());

  const count = 12;
  const firstSongGainDb = -12.0;

  /// A handler on [caps] with the Dart cut through the player volume (no
  /// in-pipeline ReplayGain unless [pipeline]), whose songs carry [trackGains]
  /// and [albumGains] (by index, default: the first song at
  /// [firstSongGainDb]) and [albums]. Phase 2 blocks on [blocked].
  Future<_Rig> create(
    PlaybackAdjustmentCapabilities caps, {
    required bool ios,
    String mode = 'track',
    Map<int, double> trackGains = const {0: firstSongGainDb},
    Map<int, double> albumGains = const {},
    Map<int, String> albums = const {},
    bool pipeline = false,
    String blocked = 'song-5',
  }) async {
    final directory = await Directory.systemTemp.createTemp('navis-479a-');
    final database = createTestDatabase();
    await database.libraryDao.upsertAlbums([
      for (final id in albums.values.toSet())
        AlbumsTableCompanion.insert(id: id, name: id),
    ]);
    await database.libraryDao.upsertSongs([
      for (var i = 0; i < count; i++)
        SongsTableCompanion.insert(
          id: 'song-$i',
          title: 'Song $i',
          albumId: Value(albums[i]),
          replayGainTrackGain: Value(trackGains[i]),
          replayGainAlbumGain: Value(albumGains[i]),
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
      blocked,
    );
    final player = _FakePlayer();
    final session = _FakeAudioSession();
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
      readRuntimeSettings: () => PlaybackRuntimeSettings(
        gaplessEnabled: true,
        fastSeekingEnabled: true,
        nextSongPrefetchAllowed: true,
        crossfadeEnabled: false,
        crossfadeAllowStreaming: true,
        crossfadeDurationSeconds: 5,
        crossfadeType: 'normal',
        replayGainMode: mode,
        replayGainPreamp: 0,
        replayGainUntaggedDb: replayGainFallbackUntaggedDb,
        playbackSpeed: 1,
        albumQueueEnabled: false,
        matchFlowEnabled: false,
      ),
      adjustmentCapabilities: caps,
      replayGainInPipelineOverride: pipeline,
      starSyncDao: database.starSyncDao,
      player: player,
      desktopRuntimeOverride: !ios,
      shuffleRandom: Random(7),
    );
    handler.debugWireAudioSession(session);
    addTearDown(() async {
      if (!resolver.release.isCompleted) resolver.release.complete();
      await handler.disposeHandler();
      await session.interruptions.close();
      await database.close();
      await directory.delete(recursive: true);
    });
    await handler.waitUntilReady();
    await handler.debugWaitForStartupQueueRestore();
    return (
      handler: handler,
      player: player,
      resolver: resolver,
      session: session,
    );
  }

  List<String> ids([int n = count]) => [for (var i = 0; i < n; i++) 'song-$i'];

  /// Starts a replacement and returns once phase 1 has played the start song
  /// and phase 2 is held at the gated song.
  Future<({Future<void> done})> startLoad(
    _Rig rig, {
    int startIndex = 0,
    List<String>? songs,
  }) async {
    final replaced = rig.handler.replaceQueue(
      songs ?? ids(),
      startIndex: startIndex,
      expandMatchFlows: false,
    );
    await rig.resolver.entered.future;
    await pumpEventQueue();
    expect(rig.handler.collectPlaybackDiagnostics()['queueSettled'], isFalse);
    return (done: replaced);
  }

  Future<void> settle(_Rig rig, ({Future<void> done}) load) async {
    rig.resolver.release.complete();
    await load.done;
    await pumpEventQueue();
    expect(rig.handler.collectPlaybackDiagnostics()['queueSettled'], isTrue);
  }

  for (final (name, caps, ios, curve) in [
    // macOS mpv outside the pipeline: cubic volume.
    ('macOS mpv', PlaybackAdjustmentCapabilities.mediaKit, false, 60.0),
  ]) {
    double cutOf(double db) => pow(10, db / curve).toDouble();

    test('$name: the first song plays at its ReplayGain cut while phase 2 '
        'is still filling the queue', () async {
      final rig = await create(caps, ios: ios);
      final (:handler, :player, :resolver, session: _) = rig;
      final cut = cutOf(firstSongGainDb);

      final replaced = await startLoad(rig);

      expect(player.playing, isTrue, reason: 'phase 1 started the song');
      expect(player.currentIndex, 0);
      expect(handler.currentMediaItem?.id, 'song-0');
      expect(
        handler.collectPlaybackDiagnostics()['playerVolume'],
        closeTo(cut, 0.00001),
      );
      expect(
        player.volume,
        closeTo(cut, 0.00001),
        reason: 'song-0 is audible, so its $firstSongGainDb dB cut applies now',
      );

      await settle(rig, replaced);
      expect(player.volume, closeTo(cut, 0.00001));
    });

    test('$name: Smart reads the album run of the incoming queue during the '
        'load and does not step at the commit', () async {
      // Songs 0 and 1 share album A: album gain (-6 dB) applies to song 1,
      // though the load only holds song 1 (and, on iOS, song 2) so far.
      final rig = await create(
        caps,
        ios: ios,
        mode: 'smart',
        trackGains: const {1: -12},
        albumGains: const {1: -6},
        albums: const {0: 'A', 1: 'A'},
      );
      final replaced = await startLoad(rig, startIndex: 1);
      expect(rig.handler.currentMediaItem?.id, 'song-1');
      expect(rig.player.volume, closeTo(cutOf(-6), 0.00001));

      await settle(rig, replaced);
      expect(rig.player.volume, closeTo(cutOf(-6), 0.00001));
    });

    test('$name: nothing song-scoped is written before the new source is '
        'applied', () async {
      // song-1 plays at its own cut; the next replacement stops at its start
      // song's resolve, so song-1 is still the audible one.
      final rig = await create(
        caps,
        ios: ios,
        trackGains: const {0: -12, 1: -6},
        blocked: 'song-0',
      );
      await rig.handler.replaceQueue(['song-1', 'song-2']);
      final old = cutOf(-6);
      expect(rig.player.volume, closeTo(old, 0.00001));

      final replacing = rig.handler.replaceQueue(['song-0', 'song-3']);
      await rig.resolver.entered.future;
      await pumpEventQueue();
      final writes = rig.player.appliedVolumes.length;
      // A settings change is a volume write that goes through every load.
      await rig.handler.applyRuntimeSettings();
      await pumpEventQueue();
      expect(
        rig.player.appliedVolumes.length,
        writes,
        reason: 'song-0 is not in the player yet; song-1 is still audible',
      );
      expect(rig.player.volume, closeTo(old, 0.00001));

      await settle(rig, (done: replacing));
      expect(rig.player.volume, closeTo(cutOf(-12), 0.00001));
    });

    test('$name: ducking before the load keeps 0.4 x user x cut once the '
        'start song plays', () async {
      final rig = await create(caps, ios: ios);
      await rig.handler.setVolume(0.5);
      rig.session.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.duck),
      );
      await pumpEventQueue();

      final replaced = await startLoad(rig);
      final ducked = 0.4 * 0.5 * cutOf(firstSongGainDb);
      expect(rig.player.volume, closeTo(ducked, 0.00001));

      rig.session.interruptions.add(
        AudioInterruptionEvent(false, AudioInterruptionType.duck),
      );
      await pumpEventQueue();
      expect(rig.player.volume, closeTo(0.5 * cutOf(firstSongGainDb), 0.00001));

      await settle(rig, replaced);
      expect(rig.player.volume, closeTo(0.5 * cutOf(firstSongGainDb), 0.00001));
    });

    test('$name: the backend applies the cut in the pipeline, so the volume '
        'stays the base volume during and after the load', () async {
      final rig = await create(caps, ios: ios, pipeline: true);
      await rig.handler.setVolume(0.5);
      final replaced = await startLoad(rig);
      expect(rig.player.volume, closeTo(0.5, 0.00001));
      await settle(rig, replaced);
      expect(rig.player.volume, closeTo(0.5, 0.00001));
    });

    test('$name: radio never gets a cut', () async {
      final rig = await create(caps, ios: ios);
      await rig.handler.setVolume(0.5);
      await rig.handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: 'https://radio.example.invalid/live',
      );
      await pumpEventQueue();
      expect(rig.player.volume, closeTo(0.5, 0.00001));
    });
  }

  // Issue #479 follow-up (I38): a manual skip that lands by seeking never goes
  // through the queue apply, so the player is already on the target while the
  // seek is pending. The target's cut applies then, not at the commit.
  for (final (name, caps, ios, curve) in [
    ('macOS mpv', PlaybackAdjustmentCapabilities.mediaKit, false, 60.0),
  ]) {
    double cutOf(double db) => pow(10, db / curve).toDouble();
    const gains = {0: -12.0, 1: -6.0, 2: -3.0, 3: -9.0, 4: -2.0};

    // Settled queue on song-2, then [action] with the seek held open.
    for (final (variant, action, targetIndex, targetGain) in [
      ('skip next', (NavisAudioHandler h) => h.skipToNext(), 3, -9.0),
      ('skip previous', (NavisAudioHandler h) => h.skipToPrevious(), 1, -6.0),
      (
        'skipToQueueItem',
        (NavisAudioHandler h) => h.skipToQueueItem(4),
        4,
        -2.0,
      ),
    ]) {
      test('$name: $variant applies the target cut while the seek is '
          'pending', () async {
        final rig = await create(caps, ios: ios, trackGains: gains);
        final (:handler, :player, resolver: _, session: _) = rig;
        await settle(rig, await startLoad(rig, startIndex: 2));
        expect(player.volume, closeTo(cutOf(-3), 0.00001));

        player.seekGate = Completer<void>();
        final skip = action(handler);
        await pumpEventQueue();
        expect(player.currentIndex, targetIndex, reason: 'seek is in flight');
        expect(handler.collectPlaybackDiagnostics()['queueSettled'], isFalse);
        expect(
          player.volume,
          closeTo(cutOf(targetGain), 0.00001),
          reason: 'the player is on the target, so its cut applies now',
        );

        player.seekGate!.complete();
        await skip;
        await pumpEventQueue();
        expect(player.volume, closeTo(cutOf(targetGain), 0.00001));
      });
    }

    test(
      '$name: a replacement that starts on the song now playing writes '
      'nothing until its source is applied (Smart picks another cut)',
      () async {
        // Song 1 in [1, 2] has no album neighbour (track gain -12); in
        // [0, 1, 2] it follows song 0 of its album (album gain -6).
        final rig = await create(
          caps,
          ios: ios,
          mode: 'smart',
          trackGains: const {1: -12},
          albumGains: const {1: -6},
          albums: const {0: 'A', 1: 'A', 2: 'B'},
          blocked: 'song-1',
        );
        rig.resolver.armed = false;
        await rig.handler.replaceQueue(['song-1', 'song-2']);
        rig.resolver.armed = true;
        expect(rig.handler.currentMediaItem?.id, 'song-1');
        expect(rig.player.volume, closeTo(cutOf(-12), 0.00001));

        final replacing = rig.handler.replaceQueue([
          'song-0',
          'song-1',
          'song-2',
        ], startIndex: 1);
        await rig.resolver.entered.future;
        await pumpEventQueue();
        final writes = rig.player.appliedVolumes.length;
        await rig.handler.applyRuntimeSettings();
        await pumpEventQueue();
        expect(
          rig.player.appliedVolumes.length,
          writes,
          reason:
              'the old entry of song-1 still plays; the new source is not in',
        );
        expect(rig.player.volume, closeTo(cutOf(-12), 0.00001));

        await settle(rig, (done: replacing));
        expect(rig.player.volume, closeTo(cutOf(-6), 0.00001));
      },
    );

    test('$name: a jump to another copy of the playing song takes the '
        "copy's Smart cut once the player is on it", () async {
      // [0, 1, 2, 1]: the copy at index 3 follows song 2 (album B), so it
      // plays at its track gain; the copy at index 1 follows song 0 (album).
      final rig = await create(
        caps,
        ios: ios,
        mode: 'smart',
        trackGains: const {1: -12},
        albumGains: const {1: -6},
        albums: const {0: 'A', 1: 'A', 2: 'B'},
      );
      await settle(
        rig,
        await startLoad(
          rig,
          startIndex: 1,
          songs: ['song-0', 'song-1', 'song-2', 'song-1', 'song-5'],
        ),
      );
      expect(rig.player.volume, closeTo(cutOf(-6), 0.00001));

      rig.player.seekGate = Completer<void>();
      final skip = rig.handler.skipToQueueItem(3);
      await pumpEventQueue();
      expect(rig.player.currentIndex, 3);
      expect(rig.player.volume, closeTo(cutOf(-12), 0.00001));
      rig.player.seekGate!.complete();
      await skip;
      await pumpEventQueue();
      expect(rig.player.volume, closeTo(cutOf(-12), 0.00001));
    });

    test('$name: restarting the playing entry writes no other cut while '
        'the seek is pending', () async {
      final rig = await create(caps, ios: ios, trackGains: gains);
      await settle(rig, await startLoad(rig, startIndex: 2));
      rig.player.seekGate = Completer<void>();
      final skip = rig.handler.skipToQueueItem(2);
      await pumpEventQueue();
      expect(rig.player.volume, closeTo(cutOf(-3), 0.00001));
      rig.player.seekGate!.complete();
      await skip;
      await pumpEventQueue();
      expect(rig.player.volume, closeTo(cutOf(-3), 0.00001));
    });

    test(
      '$name: a settings change while the apply is in flight writes '
      'nothing, though the new entries are already in the sequence',
      () async {
        final rig = await create(caps, ios: ios, trackGains: gains);
        final (:handler, :player, :resolver, session: _) = rig;
        await settle(rig, await startLoad(rig, startIndex: 2));
        expect(player.volume, closeTo(cutOf(-3), 0.00001));

        player.applyGate = Completer<void>();
        final replacing = handler.replaceQueue(ids(), startIndex: 0);
        // The load does real file I/O, so a fixed number of event-loop turns
        // can end before the new sequence is in on a slow runner (#533).
        for (var i = 0; i < 400 && player.currentIndex != 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(player.currentIndex, 0, reason: 'the new sequence is in');
        expect(handler.collectPlaybackDiagnostics()['queueSettled'], isFalse);
        final writes = player.appliedVolumes.length;
        await handler.applyRuntimeSettings();
        await pumpEventQueue();
        expect(
          player.appliedVolumes.length,
          writes,
          reason: 'the apply has not returned, so song-2 may still be audible',
        );
        expect(player.volume, closeTo(cutOf(-3), 0.00001));

        player.applyGate!.complete();
        if (!resolver.release.isCompleted) resolver.release.complete();
        await replacing;
        await pumpEventQueue();
        expect(player.volume, closeTo(cutOf(-12), 0.00001));
      },
    );

    test('$name: a seek that returns before the index lands writes nothing '
        'onto the old entry', () async {
      final rig = await create(caps, ios: ios, trackGains: gains);
      final (:handler, :player, resolver: _, session: _) = rig;
      await settle(rig, await startLoad(rig, startIndex: 2));
      final before = player.volumeWrites.length;

      player.deferIndex = true;
      await handler.skipToNext();
      await pumpEventQueue();
      expect(player.currentIndex, 3);
      for (final (value, nativeIndex) in player.volumeWrites.skip(before)) {
        if ((value - cutOf(-9)).abs() < 0.00001) {
          expect(nativeIndex, 3, reason: 'the target cut only lands on it');
        }
      }
      expect(player.volume, closeTo(cutOf(-9), 0.00001));
    });

    test('$name: the backend applies the cut in the pipeline, so a pending '
        'skip leaves the volume at the base volume', () async {
      final rig = await create(
        caps,
        ios: ios,
        pipeline: true,
        trackGains: gains,
      );
      await rig.handler.setVolume(0.5);
      await settle(rig, await startLoad(rig, startIndex: 2));
      rig.player.seekGate = Completer<void>();
      final skip = rig.handler.skipToNext();
      await pumpEventQueue();
      expect(rig.player.currentIndex, 3);
      expect(rig.player.volume, closeTo(0.5, 0.00001));
      rig.player.seekGate!.complete();
      await skip;
      await pumpEventQueue();
      expect(rig.player.volume, closeTo(0.5, 0.00001));
    });
  }

  // Issue #479 (c): in the pipeline Smart decides per queue entry. A song
  // queued twice has two entries with their own neighbours, so each copy must
  // get its own level, its own stamp and its own display.
  for (final (name, caps, ios) in [
    ('mpv', PlaybackAdjustmentCapabilities.mediaKit, false),
    ('android', PlaybackAdjustmentCapabilities.android, false),
  ]) {
    const albums = {0: 'A', 1: 'A', 2: 'A', 3: 'B', 5: 'C'};

    Future<_Rig> smart(
      List<String> songs, {
      int start = 0,
      String blocked = 'song-5',
    }) async {
      final rig = await create(
        caps,
        ios: ios,
        pipeline: true,
        mode: 'smart',
        trackGains: const {1: -12},
        albumGains: const {1: -6},
        albums: albums,
        blocked: blocked,
      );
      await settle(rig, await startLoad(rig, startIndex: start, songs: songs));
      return rig;
    }

    /// Smart's level of the entry at [i] of [songs]: song-1's album gain
    /// when a neighbour shares its album (A), else its track gain. [wrap]
    /// makes the queue circular (repeat all).
    double expectedAt(List<String> songs, int i, {bool wrap = false}) {
      String? albumAt(int k) {
        final at = wrap ? (k + songs.length) % songs.length : k;
        if (at < 0 || at >= songs.length) return null;
        return albums[int.parse(songs[at].substring(5))];
      }

      return albumAt(i - 1) == 'A' || albumAt(i + 1) == 'A' ? -6.0 : -12.0;
    }

    /// Jumps to [i] and checks the display, the stamp and the last push of
    /// that entry all carry [expected].
    Future<void> expectEntry(_Rig rig, int i, double expected) async {
      await rig.handler.skipToQueueItem(i);
      await pumpEventQueue();
      final seq = rig.player.sequence;
      final diagnostics = rig.handler.collectPlaybackDiagnostics();
      final shown = (diagnostics['replayGain']! as Map)['db'];
      expect(shown, expected, reason: '$name display at $i');
      expect(rig.player.levelPushes, isNotEmpty);
      expect(
        rig.player.levelPushes.last[seq[i]],
        expected,
        reason: '$name last push for the heard entry $i',
      );
    }

    test(
      '$name: pipeline Smart gives each copy of a song its own level',
      () async {
        final songs = [
          'song-0',
          'song-1',
          'song-2',
          'song-3',
          'song-1',
          'song-5',
        ];
        final rig = await smart(songs);
        await expectEntry(rig, 1, -6);
        expect(rig.player.sequence[1].replayGainDb, -6);
        expect(rig.player.sequence[4].replayGainDb, -12);
        await expectEntry(rig, 4, -12);
        expect(rig.player.levelPushes.last[rig.player.sequence[1]], -6);
        await expectEntry(rig, 1, -6);
      },
    );

    test(
      '$name: the copies swapped (the last copy has the album neighbours)',
      () async {
        final songs = [
          'song-3',
          'song-1',
          'song-5',
          'song-0',
          'song-1',
          'song-2',
        ];
        final rig = await smart(songs);
        await expectEntry(rig, 1, -12);
        await expectEntry(rig, 4, -6);
        await expectEntry(rig, 1, -12);
      },
    );

    test('$name: the copies swapped, starting on the last one', () async {
      final songs = [
        'song-3',
        'song-1',
        'song-5',
        'song-0',
        'song-1',
        'song-2',
      ];
      final rig = await smart(songs, start: 4);
      await expectEntry(rig, 1, -12);
      await expectEntry(rig, 4, -6);
    });

    test('$name: queue edits keep each copy on its own neighbours', () async {
      var songs = ['song-0', 'song-1', 'song-2', 'song-3', 'song-1', 'song-5'];
      final rig = await smart(songs);
      await rig.handler.removeQueueItemAt(2);
      songs = [...songs]..removeAt(2);
      await pumpEventQueue();
      // [0, 1, 3, 1, 5]: the first copy has song-0 (A) before it.
      await rig.handler.playNext(['song-1'], expandMatchFlows: false);
      songs = [...songs]..insert(1, 'song-1');
      await pumpEventQueue();
      expect(
        [for (final item in rig.handler.queue.value) item.id],
        songs,
        reason: 'the queue after the edits',
      );
      for (var i = 0; i < songs.length; i++) {
        if (songs[i] != 'song-1') continue;
        await expectEntry(rig, i, expectedAt(songs, i));
      }
    });

    test('$name: repeat all moves the wrap neighbours per copy', () async {
      final songs = ['song-1', 'song-3', 'song-5', 'song-1'];
      final rig = await smart(songs);
      await rig.handler.setRepeatMode(AudioServiceRepeatMode.all);
      await pumpEventQueue();
      for (final i in [3, 0, 3]) {
        await expectEntry(rig, i, expectedAt(songs, i, wrap: true));
      }
    });

    test(
      '$name: shuffle gives each copy its neighbours in the new order',
      () async {
        final rig = await smart([
          'song-0',
          'song-1',
          'song-2',
          'song-3',
          'song-1',
          'song-5',
        ]);
        await rig.handler.setShuffleMode(AudioServiceShuffleMode.all);
        await pumpEventQueue();
        final songs = [for (final item in rig.handler.queue.value) item.id];
        for (var i = 0; i < songs.length; i++) {
          if (songs[i] != 'song-1') continue;
          await expectEntry(rig, i, expectedAt(songs, i));
        }
      },
    );

    test('$name: adjacent copies of a song both take the album gain', () async {
      final songs = ['song-0', 'song-1', 'song-1', 'song-3'];
      final rig = await smart(songs, blocked: 'song-3');
      await expectEntry(rig, 1, -6);
      await expectEntry(rig, 2, -6);
      await expectEntry(rig, 1, -6);
    });
  }
}
