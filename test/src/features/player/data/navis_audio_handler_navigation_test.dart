import 'dart:math';

import 'package:navis/src/features/player/domain/playback_adjustments.dart';

import 'package:audio_service/audio_service.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/cache/data/rolling_cache_manager.dart';
import 'package:navis/src/features/player/data/listenbrainz_feedback_service.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/data/scrobble_service.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_database.dart';

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

class _ControllableAudioPlayer extends Fake implements AudioPlayer {
  final StreamController<int?> _indices = StreamController<int?>.broadcast();
  List<AudioSource> _sources = <AudioSource>[];
  ProcessingState state = ProcessingState.idle;
  bool isPlaying = false;
  Duration _simulatedPosition = Duration.zero;
  DateTime _positionUpdated = DateTime.now();
  bool simulateProgress = false;
  Duration get simulatedPosition => _simulatedPosition;
  set simulatedPosition(Duration value) {
    _simulatedPosition = value;
    _positionUpdated = DateTime.now();
  }

  bool ignoreSeeks = false;

  /// This many further seeks are ignored, as a native no-op would be.
  int ignoredSeeks = 0;

  /// Loads start at zero whatever initial position they were given.
  bool ignoreInitialPosition = false;

  /// The position at each play() call.
  final List<Duration> playedFrom = <Duration>[];
  bool nativePositionFrozen = false;
  bool keepStreamsAfterDispose = false;
  int seekCalls = 0;
  int? index;
  double appliedSpeed = 1;
  double appliedPitch = 1;
  bool failPitchOnce = false;
  String? failAppendSongId;

  /// A load whose first song is this one fails, as a broken source would.
  String? failLoadSongId;
  Completer<void>? seekGate;
  Completer<void>? seekEntered;
  Completer<void>? loadGate;
  Completer<void>? loadEntered;
  Completer<void>? appendGate;
  Completer<void>? appendEntered;
  int lastSetAudioSourcesCount = 0;
  int maxConcurrentMutations = 0;
  int _activeMutations = 0;

  /// Mutations named here never complete, as a stuck native call would.
  final Set<String> hang = <String>{};

  Future<void> _hangIf(String method) =>
      hang.contains(method) ? Completer<void>().future : Future<void>.value();

  Future<T> _mutate<T>(Future<T> Function() action) async {
    _activeMutations++;
    if (_activeMutations > maxConcurrentMutations) {
      maxConcurrentMutations = _activeMutations;
    }
    try {
      return await action();
    } finally {
      _activeMutations--;
    }
  }

  @override
  PlaybackEvent get playbackEvent => PlaybackEvent(
    processingState: state,
    updatePosition: nativePositionFrozen ? simulatedPosition : position,
    bufferedPosition: bufferedPosition,
    duration: duration,
    currentIndex: index,
  );

  @override
  Stream<PlaybackEvent> get playbackEventStream =>
      const Stream<PlaybackEvent>.empty();

  @override
  Stream<int?> get currentIndexStream => _indices.stream;

  @override
  Stream<bool> get shuffleModeEnabledStream => const Stream<bool>.empty();

  @override
  Stream<LoopMode> get loopModeStream => const Stream<LoopMode>.empty();

  @override
  Stream<Duration> get bufferedPositionStream => const Stream<Duration>.empty();

  @override
  Stream<Duration> createPositionStream({
    int steps = 800,
    Duration minPeriod = const Duration(milliseconds: 200),
    Duration maxPeriod = const Duration(milliseconds: 200),
  }) => const Stream<Duration>.empty();

  @override
  ProcessingState get processingState => state;

  @override
  bool get playing => isPlaying;

  @override
  int? get currentIndex => index;

  @override
  Duration get position =>
      _simulatedPosition +
      (simulateProgress && isPlaying
          ? DateTime.now().difference(_positionUpdated)
          : Duration.zero);

  Duration simulatedBuffered = Duration.zero;

  @override
  Duration get bufferedPosition => simulatedBuffered;

  @override
  Duration? get duration => const Duration(minutes: 3);

  @override
  double get volume => 1;

  @override
  double get speed => appliedSpeed;

  @override
  double get pitch => appliedPitch;

  LoopMode appliedLoopMode = LoopMode.off;
  bool shuffleEnabled = false;

  @override
  LoopMode get loopMode => appliedLoopMode;

  @override
  bool get shuffleModeEnabled => shuffleEnabled;

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
  Future<void> setVolume(double value) async {}

  @override
  Future<void> setSpeed(double value) async {
    appliedSpeed = value;
  }

  @override
  Future<void> setPitch(double value) async {
    if (failPitchOnce) {
      failPitchOnce = false;
      throw StateError('pitch failed');
    }
    appliedPitch = value;
  }

  @override
  Future<void> setLoopMode(LoopMode value) async {
    appliedLoopMode = value;
  }

  @override
  Future<void> setShuffleModeEnabled(bool value) async {
    shuffleEnabled = value;
  }

  @override
  Future<void> shuffle() async {}

  int rangeRemovals = 0;

  @override
  Future<void> removeAudioSourceAt(int index) => _mutate(() async {
    await _hangIf('removeAudioSourceAt');
    _sources.removeAt(index);
    if (this.index != null && index < this.index!) this.index = this.index! - 1;
  });

  @override
  Future<void> removeAudioSourceRange(int start, int end) => _mutate(() async {
    await _hangIf('removeAudioSourceRange');
    rangeRemovals++;
    _sources.removeRange(start, end);
    // Like just_audio: the current item keeps its place in the playlist.
    final current = index;
    if (current != null && current >= end) index = current - (end - start);
  });

  /// Song ids in the native playlist.
  List<String> get sourceIds => <String>[
    for (final source in sequence) (source.tag as MediaItem).id,
  ];

  void moveTo(int value) {
    index = value;
    _indices.add(value);
  }

  @override
  Future<void> pause() async {
    simulatedPosition = position;
    isPlaying = false;
  }

  @override
  Future<void> play() async {
    if (!isPlaying) playedFrom.add(position);
    _positionUpdated = DateTime.now();
    isPlaying = true;
  }

  @override
  Future<void> stop() => _mutate(() async {
    isPlaying = false;
    state = ProcessingState.idle;
  });

  @override
  Stream<IcyMetadata?> get icyMetadataStream =>
      const Stream<IcyMetadata?>.empty();

  @override
  IcyMetadata? get icyMetadata => null;

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
  }) => _mutate(() async {
    await _hangIf('setAudioSources');
    final failing = failLoadSongId;
    if (failing != null &&
        sources.isNotEmpty &&
        sources.first is IndexedAudioSource &&
        ((sources.first as IndexedAudioSource).tag as MediaItem?)?.id ==
            failing) {
      throw StateError('load failed');
    }
    state = ProcessingState.loading;
    final gate = loadGate;
    loadGate = null;
    if (gate != null) {
      loadEntered?.complete();
      await gate.future;
    }
    simulatedPosition = ignoreInitialPosition
        ? Duration.zero
        : initialPosition ?? Duration.zero;
    _sources = List<AudioSource>.of(sources);
    lastSetAudioSourcesCount = sources.length;
    index = sources.isEmpty ? null : initialIndex ?? 0;
    state = sources.isEmpty ? ProcessingState.idle : ProcessingState.ready;
    _indices.add(index);
    return const Duration(minutes: 3);
  });

  @override
  Future<void> addAudioSource(AudioSource source) => _mutate(() async {
    if (failAppendSongId != null &&
        source is IndexedAudioSource &&
        (source.tag as MediaItem?)?.id == failAppendSongId) {
      throw StateError('append unavailable');
    }
    _sources.add(source);
  });

  @override
  Future<void> insertAudioSource(int at, AudioSource source) =>
      _mutate(() async {
        _sources.insert(at, source);
        if (index != null && at <= index!) index = index! + 1;
        _indices.add(index);
      });

  int batchMutationCount = 0;

  @override
  Future<void> moveAudioSource(int currentIndex, int newIndex) =>
      _mutate(() async {
        _sources.insert(newIndex, _sources.removeAt(currentIndex));
        // Like just_audio: the playing item keeps playing wherever it moves.
        final playing = index;
        if (playing == null) return;
        if (playing == currentIndex) {
          index = newIndex;
        } else if (currentIndex < playing && newIndex >= playing) {
          index = playing - 1;
        } else if (currentIndex > playing && newIndex <= playing) {
          index = playing + 1;
        }
      });

  @override
  Future<void> addAudioSources(List<AudioSource> sources) => _mutate(() async {
    await _hangIf('addAudioSources');
    final gate = appendGate;
    if (gate != null) {
      appendGate = null;
      appendEntered?.complete();
      await gate.future;
    }
    batchMutationCount++;
    // Like a native batch: one failing source fails the whole call.
    if (failAppendSongId != null &&
        sources.any(
          (source) =>
              source is IndexedAudioSource &&
              (source.tag as MediaItem?)?.id == failAppendSongId,
        )) {
      throw StateError('append unavailable');
    }
    _sources.addAll(sources);
  });

  @override
  Future<void> insertAudioSources(int at, List<AudioSource> sources) =>
      _mutate(() async {
        await _hangIf('insertAudioSources');
        batchMutationCount++;
        _sources.insertAll(at, sources);
        if (index != null && at <= index!) index = index! + sources.length;
        _indices.add(index);
      });

  @override
  Future<void> seek(Duration? position, {int? index}) => _mutate(() async {
    seekCalls++;
    await _hangIf('seek');
    final gate = seekGate;
    seekGate = null;
    if (gate != null) {
      if (seekEntered case final entered? when !entered.isCompleted) {
        entered.complete();
      }
      await gate.future;
    }
    if (state == ProcessingState.loading) return;
    final ignored = ignoreSeeks || ignoredSeeks > 0;
    if (ignoredSeeks > 0) ignoredSeeks--;
    if (position != null && !ignored) simulatedPosition = position;
    if (index != null) this.index = index;
    _indices.add(this.index);
  });

  @override
  Future<void> dispose() async {
    if (!keepStreamsAfterDispose) await _indices.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(NavisAudioHandler, _ControllableAudioPlayer, NavisDatabase)>
  createHandler(
    Directory directory,
    int count, {
    bool crossfade = false,
    int savedQueueIndex = -1,
    NavisQueueWindow queueWindow = const NavisQueueWindow(),
    NavisPlaybackTimeouts timeouts = const NavisPlaybackTimeouts(),
    List<_ControllableAudioPlayer>? rebuiltPlayers,
    // Songs stream from a server, with desktop sidecar caching.
    bool sidecarStreams = false,
    Future<void> Function(NavisDatabase database)? seed,
    bool cacheSongs = true,
    SubsonicApiClient? Function()? readApiClient,
    bool Function()? readCanStream,
    bool Function(Uri)? readRadioArtworkAllowed,
    Future<Uri?> Function(Uri)? fetchRadioArtwork,
  }) async {
    final database = createTestDatabase();
    final apiClient = sidecarStreams
        ? SubsonicApiClient(
            baseUrl: 'https://example.com',
            authConfig: const SubsonicAuthConfig(
              username: 'alice',
              password: 'secret',
              apiVersion: '1.16.1',
            ),
            enableLogging: false,
          )
        : null;
    final songs = <SongsTableCompanion>[];
    for (var i = 0; i < count; i++) {
      final id = 'song-$i';
      songs.add(SongsTableCompanion.insert(id: id, title: 'Song $i'));
    }
    await database.libraryDao.upsertSongs(songs);
    for (var i = 0; i < count && cacheSongs && !sidecarStreams; i++) {
      final id = 'song-$i';
      final file = File('${directory.path}/$id.mp3');
      await file.writeAsBytes(<int>[1, 2, 3]);
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: id,
          filePath: file.path,
          fileSize: 3,
          format: 'mp3',
          cacheType: CacheType.permanent,
          downloadStatus: DownloadStatus.complete,
          lastAccessedAt: DateTime.now(),
        ),
      );
    }
    if (savedQueueIndex >= 0) {
      await database.playQueueDao.saveQueue(
        currentIndex: savedQueueIndex,
        songIds: List<String>.generate(count, (index) => 'song-$index'),
      );
    }
    await seed?.call(database);
    final cache = DriftRollingCacheManager(cacheDao: database.cacheDao);
    final player = _ControllableAudioPlayer();
    final handler = NavisAudioHandler(
      readRadioMetadataAllowed: () => false,
      readRadioArtworkAllowed: readRadioArtworkAllowed,
      fetchRadioArtwork: fetchRadioArtwork,
      libraryDao: database.libraryDao,
      playlistDao: database.playlistDao,
      playQueueDao: database.playQueueDao,
      matchFlowDao: database.matchFlowDao,
      historyDao: database.historyDao,
      sourceResolver: PlaybackSourceResolver(
        cacheDao: database.cacheDao,
        libraryDao: database.libraryDao,
        rollingCacheManager: cache,
        readApiClient: readApiClient ?? () => apiClient,
        readStreamingQuality: () => const StreamingQuality(label: 'original'),
        readRollingCacheDirectory: () async => directory,
        readCachedPlaybackFirst: () => true,
        readCanStream: readCanStream,
        readUsesSidecarRollingCache: () => sidecarStreams,
      ),
      readApiClient: readApiClient ?? () => apiClient,
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

        crossfadeEnabled: crossfade,
        crossfadeDurationSeconds: 5,
        crossfadeType: 'normal',
        replayGainMode: 'off',
        replayGainPreamp: 0,
        playbackSpeed: 1,
        albumQueueEnabled: false,
        matchFlowEnabled: false,
      ),
      adjustmentCapabilities: PlaybackAdjustmentCapabilities.android,
      crossfadePlayerFactory: _ControllableAudioPlayer.new,
      starSyncDao: database.starSyncDao,
      player: player,
      queueWindow: queueWindow,
      timeouts: timeouts,
      shuffleRandom: Random(7),
      playerFactory: rebuiltPlayers == null
          ? null
          : () {
              final rebuilt = _ControllableAudioPlayer()
                ..simulateProgress = true;
              rebuiltPlayers.add(rebuilt);
              return rebuilt;
            },
    );
    await handler.waitUntilReady();
    return (handler, player, database);
  }

  test(
    'radio publishes only guarded local artwork and clears refused art',
    () async {
      final directory = Directory.systemTemp.createTempSync('radio-art-');
      var allowed = true;
      var fetches = 0;
      final pending = Completer<Uri?>();
      final (handler, _, database) = await createHandler(
        directory,
        0,
        readRadioArtworkAllowed: (_) => allowed,
        fetchRadioArtwork: (_) {
          fetches++;
          return pending.future;
        },
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        directory.deleteSync(recursive: true);
      });
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: 'https://example.invalid/stream',
      );
      handler.updateRadioMetadata(
        title: 'Track',
        artUrl: 'https://art.example.invalid/cover',
      );
      expect(handler.mediaItem.value!.artUri, isNull);
      expect(fetches, 1);
      allowed = false;
      handler.updateRadioMetadata();
      pending.complete(Uri.file('${directory.path}/cover.jpg'));
      await Future<void>.delayed(Duration.zero);
      expect(handler.mediaItem.value!.artUri, isNull);
      expect(handler.snapshot.radioStation!.nowPlayingArtUrl, isNull);
      handler.updateRadioMetadata(
        title: 'Next',
        artUrl: 'https://art.example.invalid/next',
      );
      expect(fetches, 1);
      allowed = true;
      handler.updateRadioMetadata(
        title: 'Allowed',
        artUrl: 'https://art.example.invalid/local',
      );
      await Future<void>.delayed(Duration.zero);
      expect(handler.mediaItem.value!.artUri!.scheme, 'file');
    },
  );

  for (final preparationFailure in [true, false]) {
    test(
      'append skips ${preparationFailure ? 'unavailable sources' : 'failed native insertions'} and persists valid occurrences',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-append-',
        );
        final (handler, player, database) = await createHandler(directory, 4);
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        await handler.replaceQueue([
          'song-0',
          'song-0',
        ], expandMatchFlows: false);
        if (preparationFailure) {
          await database.cacheDao.removeCachedTrack('song-2');
        } else {
          player.failAppendSongId = 'song-2';
        }
        await handler.addToQueue([
          'song-1',
          'song-2',
          'song-3',
        ], expandMatchFlows: false);
        expect(handler.snapshot.queueSongIds, [
          'song-0',
          'song-0',
          'song-1',
          'song-3',
        ]);
        expect(handler.snapshot.currentIndex, 0);
        expect(player.isPlaying, isTrue);
        await handler.debugFlushQueuePersistence();
        expect((await database.playQueueDao.getQueueItems()).map((s) => s.id), [
          'song-0',
          'song-0',
          'song-1',
          'song-3',
        ]);
      },
    );
  }

  test(
    'speed and pitch apply to both decks, survive clear, and rollback together',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis_adjustment_decks_',
      );
      final (handler, player, database) = await createHandler(
        directory,
        2,
        crossfade: true,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      const values = PlaybackAdjustments(speed: 1.2735, pitchSemitones: -2.37);
      await handler.setPlaybackAdjustments(values);
      var diagnostics = handler.collectPlaybackDiagnostics();
      expect(player.appliedSpeed, values.speed);
      expect(player.appliedPitch, closeTo(values.pitchFactor, 0.000001));
      expect(diagnostics['crossfadeSpeed'], values.speed);
      expect(
        diagnostics['crossfadePitchFactor'],
        closeTo(values.pitchFactor, 0.000001),
      );
      await handler.clearQueue();
      diagnostics = handler.collectPlaybackDiagnostics();
      expect(diagnostics['playerSpeed'], values.speed);
      expect(
        diagnostics['crossfadePitchFactor'],
        closeTo(values.pitchFactor, 0.000001),
      );
      player.failPitchOnce = true;
      await expectLater(
        handler.setPlaybackAdjustments(
          const PlaybackAdjustments(speed: 1.75, pitchSemitones: 2),
        ),
        throwsStateError,
      );
      expect(player.appliedSpeed, values.speed);
      expect(player.appliedPitch, closeTo(values.pitchFactor, 0.000001));
      await handler.setPlaybackSpeed(1.375);
      expect(player.appliedPitch, closeTo(values.pitchFactor, 0.000001));
      expect(player.appliedSpeed, 1.375);
      final confirmations = <PlaybackAdjustments>[];
      final subscription = handler.playbackAdjustmentsStream.listen(
        confirmations.add,
      );
      const linked = PlaybackAdjustments(speed: 1.25, lockPitchToSpeed: true);
      final lockOperation = handler.setPlaybackAdjustments(linked);
      final directOperation = handler.setSpeed(1.3);
      await Future.wait([lockOperation, directOperation]);
      expect(player.appliedSpeed, 1.3);
      expect(player.appliedPitch, 1.3);
      expect(handler.playbackAdjustments.lockPitchToSpeed, isTrue);
      expect(handler.collectPlaybackDiagnostics()['crossfadePitchFactor'], 1.3);
      final frozen = handler.playbackAdjustments.copyWith(
        lockPitchToSpeed: false,
      );
      await handler.setPlaybackAdjustments(frozen);
      await handler.setPlaybackSpeed(1.5);
      expect(player.appliedPitch, closeTo(1.3, 1e-14));
      await Future<void>.delayed(Duration.zero);
      expect(confirmations.last, handler.playbackAdjustments);
      await subscription.cancel();
    },
  );

  test(
    'ignored seek during loading reloads the full queue at target',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-nav-test-',
      );
      final (handler, player, database) = await createHandler(directory, 3);
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final songs = await database.libraryDao.getSongsByIds(<String>[
        'song-0',
        'song-1',
        'song-2',
      ]);
      await handler.replaceQueueWithData(songs);
      expect(player.audioSources.length, 3);

      player.state = ProcessingState.loading;
      await handler.skipToNext();
      await handler.snapshotStream
          .firstWhere(
            (snapshot) =>
                snapshot.currentIndex == 1 &&
                snapshot.pendingQueueIndex == null &&
                snapshot.processingState == AudioProcessingState.ready,
          )
          .timeout(const Duration(seconds: 5));

      expect(player.currentIndex, 1);
      expect(player.lastSetAudioSourcesCount, 3);
      expect(player.audioSources.length, 3);
    },
  );

  test('large queue fill applies sources in batches, in order', () async {
    final directory = await Directory.systemTemp.createTemp('navis-nav-test-');
    final (handler, player, database) = await createHandler(directory, 100);
    addTearDown(() async {
      await handler.disposeHandler();
      await database.close();
      await directory.delete(recursive: true);
    });
    final ids = List<String>.generate(100, (index) => 'song-$index');
    final songs = await database.libraryDao.getSongsByIds(ids);
    final byId = {for (final song in songs) song.id: song};
    final filled = handler.snapshotStream
        .firstWhere((snapshot) => snapshot.queueSongIds.length == 100)
        .timeout(const Duration(seconds: 60));
    await handler.replaceQueueWithData([
      for (final id in ids) byId[id]!,
    ], startIndex: 50);
    await filled;

    // A small first batch then 64-song batches on each side of the start,
    // instead of one native mutation per song.
    expect(player.batchMutationCount, 4);
    expect(handler.snapshot.queueSongIds, ids);
    expect(player.sequence.map((source) => (source.tag as MediaItem).id), ids);
    expect(handler.snapshot.currentIndex, 50);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'large saved queue restores the current item first, then fills in order',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-nav-test-',
      );
      final (handler, player, database) = await createHandler(
        directory,
        100,
        savedQueueIndex: 40,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final ids = List<String>.generate(100, (index) => 'song-$index');

      // Ready resolves before the background fill, with the saved current
      // item already loaded and the full logical queue visible.
      expect(handler.snapshot.currentSongId, 'song-40');
      expect(handler.snapshot.queueSongIds, ids);

      await handler.snapshotStream
          .firstWhere((snapshot) => player.sequence.length == 100)
          .timeout(const Duration(seconds: 30));
      await pumpEventQueue();
      expect(
        player.sequence.map((source) => (source.tag as MediaItem).id),
        ids,
      );
      expect(handler.snapshot.currentIndex, 40);
      expect(handler.snapshot.currentSongId, 'song-40');
      expect(
        (await database.playQueueDao.getQueueItems()).map((song) => song.id),
        ids,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('a burst of reorders persists the final queue once', () async {
    final directory = await Directory.systemTemp.createTemp('navis-nav-test-');
    final (handler, player, database) = await createHandler(directory, 6);
    addTearDown(() async {
      await handler.disposeHandler();
      await database.close();
      await directory.delete(recursive: true);
    });
    final ids = List<String>.generate(6, (index) => 'song-$index');
    await handler.replaceQueueWithData(
      await database.libraryDao.getSongsByIds(ids),
    );

    for (var i = 0; i < 4; i++) {
      await handler.reorderQueue(5, 1);
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final persistence =
        handler.collectPlaybackDiagnostics()['persistence']!
            as Map<String, Object?>;
    final byContext = persistence['byContext']! as Map<String, int>;
    expect(byContext['reorder queue'], 1);
    expect(
      (await database.playQueueDao.getQueueItems()).map((song) => song.id),
      handler.snapshot.queueSongIds,
    );
    expect(handler.snapshot.queueSongIds, isNot(ids));
  });

  test('skipping right after a queue edit still persists the edit', () async {
    final directory = await Directory.systemTemp.createTemp('navis-nav-test-');
    final (handler, player, database) = await createHandler(directory, 6);
    addTearDown(() async {
      await handler.disposeHandler();
      await database.close();
      await directory.delete(recursive: true);
    });
    final ids = List<String>.generate(6, (index) => 'song-$index');
    await handler.replaceQueueWithData(
      await database.libraryDao.getSongsByIds(ids),
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));

    await handler.reorderQueue(5, 1);
    await handler.skipToNext();
    await Future<void>.delayed(const Duration(milliseconds: 2500));

    expect(handler.snapshot.queueSongIds, isNot(ids));
    expect(
      (await database.playQueueDao.getQueueItems()).map((song) => song.id),
      handler.snapshot.queueSongIds,
    );
  });

  test('burst keeps latest target and serializes player mutations', () async {
    final directory = await Directory.systemTemp.createTemp('navis-nav-test-');
    final (handler, player, database) = await createHandler(directory, 20);
    addTearDown(() async {
      await handler.disposeHandler();
      await database.close();
      await directory.delete(recursive: true);
    });
    final ids = List<String>.generate(20, (index) => 'song-$index');
    await handler.replaceQueueWithData(
      await database.libraryDao.getSongsByIds(ids),
    );
    final gate = Completer<void>();
    player.seekGate = gate;
    await handler.skipToNext();
    for (var i = 0; i < 99; i++) {
      await handler.skipToNext();
    }
    expect(handler.snapshot.pendingQueueIndex, 19);
    expect(
      handler.collectPlaybackDiagnostics()['navigation'],
      containsPair('pendingQueueMutations', 1),
    );
    gate.complete();
    await handler.snapshotStream
        .firstWhere(
          (snapshot) =>
              snapshot.currentIndex == 19 && snapshot.pendingQueueIndex == null,
        )
        .timeout(const Duration(seconds: 5));
    expect(player.maxConcurrentMutations, 1);
  });

  test(
    'Pause during a delayed selection stays paused when load completes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-nav-test-',
      );
      final (handler, player, database) = await createHandler(directory, 3);
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final songs = await database.libraryDao.getSongsByIds(<String>[
        'song-0',
        'song-1',
        'song-2',
      ]);
      await handler.replaceQueueWithData(songs);

      final loadEntered = Completer<void>();
      final releaseLoad = Completer<void>();
      player.state = ProcessingState.loading;
      player.loadGate = releaseLoad;
      player.loadEntered = loadEntered;
      await handler.playFromIndex(2);
      await loadEntered.future.timeout(const Duration(seconds: 5));
      await handler.pause();
      final settled = handler.snapshotStream
          .firstWhere(
            (snapshot) =>
                snapshot.currentIndex == 2 &&
                snapshot.pendingQueueIndex == null &&
                snapshot.processingState == AudioProcessingState.ready,
          )
          .timeout(const Duration(seconds: 5));
      releaseLoad.complete();
      final snapshot = await settled;

      expect(snapshot.playing, isFalse);
      expect(player.playing, isFalse);
    },
  );

  test('duplicate song IDs retain the selected queue occurrence', () async {
    final directory = await Directory.systemTemp.createTemp('navis-nav-test-');
    final (handler, player, database) = await createHandler(directory, 2);
    addTearDown(() async {
      await handler.disposeHandler();
      await database.close();
      await directory.delete(recursive: true);
    });
    final songs = await database.libraryDao.getSongsByIds(<String>[
      'song-0',
      'song-1',
    ]);
    await handler.replaceQueueWithData(<SongsTableData>[
      songs[0],
      songs[1],
      songs[0],
    ], startIndex: 2);

    expect(handler.snapshot.queueSongIds, <String>[
      'song-0',
      'song-1',
      'song-0',
    ]);
    expect(handler.snapshot.currentIndex, 2);
    expect(player.currentIndex, 2);

    await handler.skipToPrevious();
    await handler.snapshotStream
        .firstWhere(
          (snapshot) =>
              snapshot.currentIndex == 1 && snapshot.pendingQueueIndex == null,
        )
        .timeout(const Duration(seconds: 5));
    expect(player.currentIndex, 1);
  });

  test(
    'an edit made after a navigation never overtakes one made before it',
    () async {
      final directory = await Directory.systemTemp.createTemp('navis-fifo-');
      final (handler, player, database) = await createHandler(directory, 10);
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final ids = List<String>.generate(10, (i) => 'song-$i');
      // Hold the replacement in its native load.
      final gate = Completer<void>();
      final entered = Completer<void>();
      player
        ..loadGate = gate
        ..loadEntered = entered;
      final replacing = handler.replaceQueue(ids, expandMatchFlows: false);
      await entered.future;

      // A waits for the load a later navigation completes; B arrives after
      // that navigation.
      final first = handler.addToQueue(<String>[
        'song-1',
      ], expandMatchFlows: false);
      final navigation = handler.playFromIndex(2);
      final second = handler.addToQueue(<String>[
        'song-2',
      ], expandMatchFlows: false);
      gate.complete();
      await Future.wait(<Future<void>>[replacing, first, navigation, second])
          .timeout(const Duration(seconds: 5));

      expect(handler.snapshot.queueSongIds, <String>[
        ...ids,
        'song-1',
        'song-2',
      ]);
    },
  );

  test('an edit a replacement discards reports it was cancelled', () async {
    final directory = await Directory.systemTemp.createTemp('navis-cancel-');
    final (handler, player, database) = await createHandler(directory, 10);
    addTearDown(() async {
      await handler.disposeHandler();
      await database.close();
      await directory.delete(recursive: true);
    });
    final ids = List<String>.generate(10, (i) => 'song-$i');
    final gate = Completer<void>();
    final entered = Completer<void>();
    player
      ..loadGate = gate
      ..loadEntered = entered;
    final replacing = handler.replaceQueue(ids, expandMatchFlows: false);
    await entered.future;

    final edit = handler.addToQueue(<String>[
      'song-1',
    ], expandMatchFlows: false);
    final replacement = handler.replaceQueue(
      ids.reversed.toList(),
      expandMatchFlows: false,
    );
    gate.complete();

    await expectLater(edit, throwsA(isA<OperationCancelledException>()));
    await Future.wait(<Future<void>>[replacing, replacement]);
    expect(handler.snapshot.queueSongIds, ids.reversed.toList());
  });

  group('a queue edit whose native call never returns', () {
    const timeouts = NavisPlaybackTimeouts(
      load: Duration(milliseconds: 150),
      reset: Duration(milliseconds: 150),
    );
    List<String> ids(int count) =>
        List<String>.generate(count, (i) => 'song-$i');

    Future<
      (
        NavisAudioHandler,
        _ControllableAudioPlayer,
        List<_ControllableAudioPlayer>,
      )
    >
    playingAt(int index) async {
      final directory = await Directory.systemTemp.createTemp('navis-hang-');
      final rebuilt = <_ControllableAudioPlayer>[];
      final (handler, player, database) = await createHandler(
        directory,
        10,
        timeouts: timeouts,
        rebuiltPlayers: rebuilt,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      await handler.replaceQueue(ids(10), expandMatchFlows: false);
      expect(player.sourceIds, ids(10));
      player
        ..moveTo(index)
        ..isPlaying = true;
      return (handler, player, rebuilt);
    }

    test('an insert that times out reloads the queue it left', () async {
      final (handler, player, rebuilt) = await playingAt(3);
      player.hang.add('insertAudioSources');

      await expectLater(
        handler.playNext(<String>['song-0'], expandMatchFlows: false),
        throwsA(isA<PlaybackLoadTimeoutException>()),
      );

      final active = rebuilt.first;
      expect(active.sourceIds, ids(10));
      expect(active.index, 3);
      expect(active.isPlaying, isTrue);
      expect(handler.snapshot.queueSongIds, ids(10));
      expect(handler.snapshot.currentSongId, 'song-3');

      // The next edit lands on the reloaded player.
      await handler.addToQueue(<String>['song-1'], expandMatchFlows: false);
      expect(active.sourceIds, <String>[...ids(10), 'song-1']);
    });

    test('a removal that times out still removes the song', () async {
      final (handler, player, rebuilt) = await playingAt(3);
      player.hang.add('removeAudioSourceAt');

      await expectLater(
        handler.removeAt(6),
        throwsA(isA<PlaybackLoadTimeoutException>()),
      );

      final expected = ids(10)..removeAt(6);
      expect(rebuilt.first.sourceIds, expected);
      expect(rebuilt.first.index, 3);
      expect(handler.snapshot.queueSongIds, expected);
    });
  });

  test(
    'a seek served from a completed sidecar file keeps the whole queue',
    () async {
      final directory = await Directory.systemTemp.createTemp('navis-sidecar-');
      final (handler, player, database) = await createHandler(
        directory,
        5,
        sidecarStreams: true,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final ids = List<String>.generate(5, (i) => 'song-$i');
      await handler.replaceQueue(ids, startIndex: 1, expandMatchFlows: false);
      expect(player.sourceIds, ids);
      final sidecar =
          handler.queue.value[1].extras!['sidecarCacheFilePath'] as String;
      // Simulate a no-op native seek, then use the completed local source.
      player
        ..ignoreSeeks = true
        ..simulateProgress = true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await File(sidecar).writeAsBytes(List<int>.filled(64, 1));
      bool served() =>
          handler.queue.value.length == 5 &&
          handler.queue.value[1].extras!['sourceKind'] == 'file' &&
          player.sourceIds.length == 5 &&
          !handler.snapshot.isLoading;

      await handler.seek(const Duration(seconds: 30));
      for (var i = 0; i < 300 && !served(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(player.sourceIds, ids);
      expect(player.index, 1);
      expect(handler.snapshot.queueSongIds, ids);
      expect(handler.queue.value[1].extras!['sourceKind'], 'file');
    },
  );

  group('released queue window', () {
    const window = NavisQueueWindow(
      deferThreshold: 16,
      ahead: 8,
      lowWater: 3,
      page: 8,
      nearJump: 16,
    );
    List<String> ids(int count, [int from = 0]) =>
        List<String>.generate(count - from, (i) => 'song-${i + from}');

    Future<(NavisAudioHandler, _ControllableAudioPlayer, NavisDatabase)>
    windowed(int count) async {
      final directory = await Directory.systemTemp.createTemp('navis-window-');
      final created = await createHandler(
        directory,
        count,
        queueWindow: window,
      );
      addTearDown(() async {
        await created.$1.disposeHandler();
        await created.$3.close();
        await directory.delete(recursive: true);
      });
      return created;
    }

    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 200 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(condition(), isTrue);
    }

    test('a long queue hands only a window to the player', () async {
      final (handler, player, database) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      expect(handler.snapshot.queueSongIds, ids(60));
      expect(player.sourceIds, ids(9));
      expect(handler.collectPlaybackDiagnostics()['deferredLength'], 51);
      await handler.debugFlushQueuePersistence();
      expect(
        (await database.playQueueDao.getQueueItems()).map((song) => song.id),
        ids(60),
      );
    });

    test('nearing the window end releases a page with one append', () async {
      final (handler, player, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      final batches = player.batchMutationCount;
      player.moveTo(6);
      await until(() => player.sourceIds.length == 17);
      expect(player.batchMutationCount, batches + 1);
      expect(player.sourceIds, ids(17));
      expect(handler.snapshot.queueSongIds, ids(60));
    });

    test(
      'songs that cannot play yet stay deferred instead of dropping',
      () async {
        final (handler, player, database) = await windowed(60);
        await handler.replaceQueue(ids(60), expandMatchFlows: false);
        // Without a cached copy or a session the tail cannot resolve for now.
        for (final id in ids(60, 9)) {
          await database.cacheDao.removeCachedTrack(id);
        }
        player.moveTo(6);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(player.sourceIds, ids(9));
        expect(handler.snapshot.queueSongIds, ids(60));
        expect(handler.collectPlaybackDiagnostics()['deferredLength'], 51);
        await handler.debugFlushQueuePersistence();
        expect(
          (await database.playQueueDao.getQueueItems()).map((song) => song.id),
          ids(60),
        );
      },
    );

    test(
      'a deferred song that can no longer be prepared is reported',
      () async {
        final (handler, player, database) = await windowed(60);
        final dropped = <QueueSongsDropped>[];
        final subscription = handler.droppedSongsStream.listen(dropped.add);
        addTearDown(subscription.cancel);
        await handler.replaceQueue(ids(60), expandMatchFlows: false);
        // Gone from the library while it waited in the tail.
        await database.customStatement(
          "DELETE FROM songs WHERE id = 'song-10'",
        );

        player.moveTo(6);
        await until(() => player.sourceIds.length == 16);

        expect(player.sourceIds, isNot(contains('song-10')));
        expect(dropped.single.songIds, <String>['song-10']);
        expect(dropped.single.reason, QueueDropReason.release);
      },
    );

    test('a near jump into the tail releases through it and seeks', () async {
      final (handler, player, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      // Navigation is admitted immediately and applied in the queue lane.
      await handler.playFromIndex(12);
      await until(() => handler.snapshot.currentSongId == 'song-12');
      expect(player.index, 12);
      expect(handler.snapshot.currentIndex, 12);
      expect(handler.snapshot.currentSongId, 'song-12');
      expect(player.sourceIds, ids(21));
      expect(handler.snapshot.queueSongIds, ids(60));
    });

    test('a far jump rebuilds the player around the target', () async {
      final (handler, player, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      await handler.playFromIndex(50);
      await until(
        () =>
            handler.snapshot.currentSongId == 'song-50' &&
            !handler.snapshot.isLoading,
      );
      expect(handler.snapshot.currentIndex, 50);
      expect(handler.snapshot.currentSongId, 'song-50');
      expect(handler.snapshot.queueSongIds, ids(60));
      // Only a window around the target: 32 before it, 8 after.
      expect(player.sourceIds, ids(59, 18));
      expect(handler.collectPlaybackDiagnostics()['deferredHeadLength'], 18);
      expect(player.index, 32);
    });

    test('jumping back into released songs brings them back', () async {
      final (handler, player, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      await handler.playFromIndex(50);
      await until(
        () =>
            handler.snapshot.currentSongId == 'song-50' &&
            !handler.snapshot.isLoading,
      );

      // Near: the head releases back into the player.
      await handler.playFromIndex(5);
      await until(
        () =>
            handler.snapshot.currentSongId == 'song-5' &&
            !handler.snapshot.isLoading,
      );
      expect(handler.snapshot.currentIndex, 5);
      expect(handler.snapshot.queueSongIds, ids(60));
      // The target, the songs after it and a page before it (here the rest
      // of the 18 released songs).
      expect(player.sourceIds, ids(59));
      expect(player.sourceIds[player.index!], 'song-5');
    });

    group('played songs', () {
      const small = NavisQueueWindow(
        deferThreshold: 16,
        ahead: 4,
        lowWater: 2,
        page: 4,
        nearJump: 8,
        behind: 4,
        trimSlack: 2,
      );

      Future<(NavisAudioHandler, _ControllableAudioPlayer, NavisDatabase)>
      trimmed() async {
        final directory = await Directory.systemTemp.createTemp('navis-trim-');
        final created = await createHandler(directory, 60, queueWindow: small);
        final (handler, player, database) = created;
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        await handler.replaceQueue(ids(60), expandMatchFlows: false);
        // Play through ten songs.
        for (var i = 0; i < 10; i++) {
          player.moveTo(player.index! + 1);
          await until(() => handler.snapshot.currentSongId == 'song-${i + 1}');
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        return created;
      }

      int head(NavisAudioHandler handler) =>
          handler.collectPlaybackDiagnostics()['deferredHeadLength'] as int;

      test('beyond the window leave the player in batches', () async {
        final (handler, player, database) = await trimmed();
        expect(head(handler), 6);
        expect(player.sourceIds.first, 'song-6');
        expect(player.index, 4);
        expect(handler.snapshot.currentIndex, 10);
        expect(handler.snapshot.queueSongIds, ids(60));
        await handler.debugFlushQueuePersistence();
        expect(
          (await database.playQueueDao.getQueueItems()).map((s) => s.id),
          ids(60),
        );
        expect((await database.playQueueDao.getQueueState())!.currentIndex, 10);
      });

      test(
        'come back with Previous past the first song the player holds',
        () async {
          final (handler, player, _) = await trimmed();
          for (var target = 9; target >= 4; target--) {
            await handler.skipToPrevious();
            await until(
              () =>
                  handler.snapshot.currentSongId == 'song-$target' &&
                  !handler.snapshot.isLoading,
            );
          }
          expect(handler.snapshot.currentIndex, 4);
          expect(player.sourceIds[player.index!], 'song-4');
          expect(handler.snapshot.queueSongIds, ids(60));
          // One release of the target and a page before it.
          expect(head(handler), 1);
        },
      );
    });

    test('a far jump whose song cannot load keeps the old queue', () async {
      final (handler, player, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      player
        ..moveTo(3)
        ..isPlaying = true;
      await until(() => handler.snapshot.currentSongId == 'song-3');
      player.failLoadSongId = 'song-50';

      await handler.playFromIndex(50);
      await until(
        () =>
            handler.snapshot.lastFailedSongId == 'song-50' &&
            !handler.snapshot.isLoading,
      );

      expect(handler.snapshot.currentSongId, 'song-3');
      expect(handler.snapshot.currentIndex, 3);
      expect(handler.snapshot.queueSongIds, ids(60));
      expect(player.sourceIds.first, 'song-0');
      expect(player.sourceIds[player.index!], 'song-3');
    });

    test('a far jump back rebuilds around the first song', () async {
      final (handler, player, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      await handler.playFromIndex(50);
      await until(
        () =>
            handler.snapshot.currentSongId == 'song-50' &&
            !handler.snapshot.isLoading,
      );

      await handler.playFromIndex(0);
      await until(
        () =>
            handler.snapshot.currentSongId == 'song-0' &&
            !handler.snapshot.isLoading,
      );
      expect(handler.snapshot.currentIndex, 0);
      expect(handler.snapshot.queueSongIds, ids(60));
      expect(player.sourceIds, ids(9));
      expect(handler.collectPlaybackDiagnostics()['deferredHeadLength'], 0);
    });

    group('a remote row matched to a local song', () {
      // The caller's remote row shares a local id; re-reading it by id would
      // silently swap in the local row.
      Future<List<SongsTableData>> queueWithRemote(
        NavisDatabase database,
      ) async {
        final rows = await database.libraryDao.getSongsByIds(ids(60));
        return <SongsTableData>[
          for (final row in rows)
            row.id == 'song-3'
                ? row.copyWith(title: 'Remote 3', isExternal: true)
                : row,
        ];
      }

      String titleOf(NavisAudioHandler handler, String id) =>
          handler.queue.value.firstWhere((item) => item.id == id).title;

      test('keeps its row through a far jump rebuild', () async {
        final (handler, _, database) = await windowed(60);
        await handler.replaceQueueWithData(
          await queueWithRemote(database),
          startIndex: 0,
          autoPlay: false,
          expandMatchFlows: false,
        );
        expect(titleOf(handler, 'song-3'), 'Remote 3');
        await handler.playFromIndex(50);
        await until(
          () =>
              handler.snapshot.currentSongId == 'song-50' &&
              !handler.snapshot.isLoading,
        );
        // Now among the released songs; bring it back.
        await handler.playFromIndex(3);
        await until(
          () =>
              handler.snapshot.currentSongId == 'song-3' &&
              !handler.snapshot.isLoading,
        );
        expect(titleOf(handler, 'song-3'), 'Remote 3');
      });

      test('keeps its row when moved behind the window and back', () async {
        final (handler, player, database) = await windowed(60);
        await handler.replaceQueueWithData(
          await queueWithRemote(database),
          startIndex: 0,
          autoPlay: false,
          expandMatchFlows: false,
        );
        await handler.reorderQueue(3, 40);
        expect(player.sourceIds, isNot(contains('song-3')));
        await handler.reorderQueue(
          handler.snapshot.queueSongIds.indexOf('song-3'),
          3,
        );
        await until(() => player.sourceIds.contains('song-3'));
        expect(titleOf(handler, 'song-3'), 'Remote 3');
      });
    });

    test('edits inside the deferred tail touch no native state', () async {
      final (handler, player, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      final sources = player.sourceIds;
      final mutations = player.batchMutationCount;
      await handler.removeAt(40);
      await handler.reorderQueue(50, 30);
      await handler.addToQueue(['song-0'], expandMatchFlows: false);
      final expected = ids(60)..removeAt(40);
      expected.insert(30, expected.removeAt(50));
      expected.add('song-0');
      expect(handler.snapshot.queueSongIds, expected);
      expect(player.sourceIds, sources);
      expect(player.batchMutationCount, mutations);
    });

    test('moving a deferred song into the window inserts it once', () async {
      final (handler, player, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      await handler.reorderQueue(40, 3);
      expect(handler.snapshot.queueSongIds[3], 'song-40');
      expect(player.sourceIds[3], 'song-40');
      expect(player.sourceIds, hasLength(10));
      expect(handler.snapshot.queueSongIds, hasLength(60));
    });

    group('Navis-owned shuffle', () {
      void expectNativeMirrorsQueue(
        NavisAudioHandler handler,
        _ControllableAudioPlayer player,
      ) {
        final queue = handler.snapshot.queueSongIds;
        final diagnostics = handler.collectPlaybackDiagnostics();
        final head = diagnostics['deferredHeadLength'] as int;
        expect(player.shuffleEnabled, isFalse);
        expect(
          player.sourceIds,
          queue.skip(head).take(player.sourceIds.length),
        );
        expect(
          head +
              player.sourceIds.length +
              (diagnostics['deferredLength'] as int),
          queue.length,
        );
      }

      test('turning shuffle on shuffles only what follows the current song '
          'and keeps deferring', () async {
        final (handler, player, _) = await windowed(60);
        await handler.replaceQueue(ids(60), expandMatchFlows: false);
        player.moveTo(5);
        await handler.setShuffleMode(AudioServiceShuffleMode.all);

        final queue = handler.snapshot.queueSongIds;
        expect(queue.take(6), ids(6));
        expect(queue.skip(6).toSet(), ids(60, 6).toSet());
        expect(queue.skip(6), isNot(ids(60, 6)));
        expect(handler.snapshot.shuffleMode, AudioServiceShuffleMode.all);
        expect(
          handler.collectPlaybackDiagnostics()['deferredLength'],
          isPositive,
        );
        expect(player.index, 5);
        expectNativeMirrorsQueue(handler, player);
      });

      test('turning shuffle off restores the order, with songs added while '
          'shuffled', () async {
        final (handler, player, _) = await windowed(60);
        await handler.replaceQueue(ids(60), expandMatchFlows: false);
        player.moveTo(5);
        await handler.setShuffleMode(AudioServiceShuffleMode.all);
        await handler.playNext(<String>['song-0'], expandMatchFlows: false);
        await handler.addToQueue(<String>['song-1'], expandMatchFlows: false);
        // Two songs later, in shuffled order.
        player.moveTo(7);
        final playing = handler.snapshot.queueSongIds[7];

        await handler.setShuffleMode(AudioServiceShuffleMode.none);

        final expected = <String>[...ids(6), 'song-0', ...ids(60, 6), 'song-1'];
        expect(handler.snapshot.queueSongIds, expected);
        expect(handler.snapshot.shuffleMode, AudioServiceShuffleMode.none);
        expect(handler.snapshot.currentSongId, playing);
        expect(player.index, expected.indexOf(playing));
        expectNativeMirrorsQueue(handler, player);
      });

      test(
        'a queue started with shuffle on begins at the chosen song',
        () async {
          final (handler, player, _) = await windowed(60);
          await handler.setShuffleMode(AudioServiceShuffleMode.all);
          await handler.replaceQueue(
            ids(60),
            startIndex: 10,
            expandMatchFlows: false,
          );
          final queue = handler.snapshot.queueSongIds;
          expect(queue.first, 'song-10');
          expect(queue.toSet(), ids(60).toSet());
          expect(queue, isNot(ids(60)));
          expectNativeMirrorsQueue(handler, player);

          await handler.setShuffleMode(AudioServiceShuffleMode.none);
          expect(handler.snapshot.queueSongIds, ids(60));
          expect(handler.snapshot.currentSongId, 'song-10');
        },
      );

      Future<(NavisAudioHandler, _ControllableAudioPlayer)> restoring({
        required List<String> playOrder,
        required int currentIndex,
        List<int>? originalOrder,
      }) async {
        final directory = await Directory.systemTemp.createTemp('navis-shuf-');
        final (handler, player, database) = await createHandler(
          directory,
          60,
          queueWindow: window,
          seed: (database) => database.playQueueDao.saveQueue(
            currentIndex: currentIndex,
            songIds: playOrder,
            shuffleMode: ShuffleMode.all,
            originalOrder: originalOrder,
          ),
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        await until(
          () =>
              handler.snapshot.queueSongIds.length == 60 &&
              !handler.snapshot.isLoading,
        );
        return (handler, player);
      }

      test(
        'a saved shuffled queue restores in play order and unshuffles',
        () async {
          final playOrder = ids(60).reversed.toList();
          final (handler, player) = await restoring(
            playOrder: playOrder,
            currentIndex: 2,
            originalOrder: <int>[for (var i = 59; i >= 0; i--) i],
          );
          expect(handler.snapshot.queueSongIds, playOrder);
          expect(handler.snapshot.shuffleMode, AudioServiceShuffleMode.all);
          expect(handler.snapshot.currentSongId, 'song-57');

          await handler.setShuffleMode(AudioServiceShuffleMode.none);
          expect(handler.snapshot.queueSongIds, ids(60));
          expect(handler.snapshot.currentSongId, 'song-57');
          expectNativeMirrorsQueue(handler, player);
        },
      );

      test('a queue saved before Navis owned shuffle is shuffled again after '
          'the current song', () async {
        final (handler, player) = await restoring(
          playOrder: ids(60),
          currentIndex: 4,
        );
        final queue = handler.snapshot.queueSongIds;
        expect(queue.take(5), ids(5));
        expect(queue.skip(5).toSet(), ids(60, 5).toSet());
        expect(queue.skip(5), isNot(ids(60, 5)));
        expect(handler.snapshot.currentSongId, 'song-4');

        await handler.setShuffleMode(AudioServiceShuffleMode.none);
        expect(handler.snapshot.queueSongIds, ids(60));
        expectNativeMirrorsQueue(handler, player);
      });

      test('the play order and the original order are both saved', () async {
        final (handler, player, database) = await windowed(60);
        await handler.replaceQueue(ids(60), expandMatchFlows: false);
        player.moveTo(3);
        await handler.setShuffleMode(AudioServiceShuffleMode.all);
        await handler.debugFlushQueuePersistence();

        final saved = await database.playQueueDao.getQueueEntries();
        expect(
          saved.map((entry) => entry.song.id),
          handler.snapshot.queueSongIds,
        );
        final byOriginal = List.of(saved)
          ..sort((a, b) => a.originalOrder!.compareTo(b.originalOrder!));
        expect(byOriginal.map((entry) => entry.song.id), ids(60));
      });
    });

    test('repeat all waits until nothing is deferred on either side', () async {
      final (handler, player, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      expect(handler.snapshot.repeatMode, AudioServiceRepeatMode.all);
      expect(player.appliedLoopMode, LoopMode.off);
      await handler.playFromIndex(59);
      await until(
        () =>
            handler.snapshot.currentSongId == 'song-59' &&
            !handler.snapshot.isLoading,
      );
      // The first songs were released from the player, so it cannot wrap to
      // them itself; Navis wraps once the last song ends.
      expect(player.appliedLoopMode, LoopMode.off);
      player.state = ProcessingState.completed;
      await handler.play();
      await until(
        () =>
            handler.snapshot.currentSongId == 'song-0' &&
            !handler.snapshot.isLoading,
      );
      expect(handler.snapshot.currentIndex, 0);
      expect(player.appliedLoopMode, LoopMode.off);
    });

    test('repeat all resumes when a new queue has nothing deferred', () async {
      final (handler, player, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      expect(player.appliedLoopMode, LoopMode.off);
      await handler.replaceQueue(['song-3'], expandMatchFlows: false);
      expect(player.appliedLoopMode, LoopMode.all);
      expect(handler.snapshot.repeatMode, AudioServiceRepeatMode.all);
    });

    test('previous from the first song wraps into the deferred tail with '
        'repeat all', () async {
      final (handler, _, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      await handler.skipToPrevious();
      await until(
        () =>
            handler.snapshot.currentSongId == 'song-59' &&
            !handler.snapshot.isLoading,
      );
      expect(handler.snapshot.queueSongIds, ids(60));
    });

    test('an upcoming merge keeps the next two songs and one native '
        'removal', () async {
      final (handler, player, database) = await windowed(30);
      await handler.replaceQueue(ids(10), expandMatchFlows: false);
      final incoming = await database.libraryDao.getSongsByIds(ids(30, 10));
      final removals = player.rangeRemovals;
      await handler.mergeIntoUpcoming(
        incoming,
        notBefore: 1,
        random: Random(7),
      );
      final queue = handler.snapshot.queueSongIds;
      expect(queue, hasLength(30));
      expect(queue.take(3), ['song-0', 'song-1', 'song-2']);
      expect(queue.toSet(), ids(30).toSet());
      expect(player.rangeRemovals, removals + 1);
      // The earlier songs keep their relative order among the new ones.
      final earlier = queue.where(ids(10).contains).toList();
      expect(earlier, ids(10));
    });

    test('a merge into a queue with deferred songs makes no native call '
        'and spreads over the deferred songs', () async {
      final (handler, player, database) = await windowed(60);
      await handler.replaceQueue(ids(40), expandMatchFlows: false);
      final held = player.sourceIds;
      expect(held, ids(9));
      final removals = player.rangeRemovals;
      final batches = player.batchMutationCount;
      final incoming = await database.libraryDao.getSongsByIds(ids(60, 40));
      await handler.mergeIntoUpcoming(
        incoming,
        notBefore: 1,
        random: Random(7),
      );
      expect(player.sourceIds, held);
      expect(player.rangeRemovals, removals);
      expect(player.batchMutationCount, batches);
      final queue = handler.snapshot.queueSongIds;
      expect(queue.take(9), held);
      expect(queue.toSet(), ids(60).toSet());
      expect(queue.where(ids(40).contains).toList(), ids(40));
      // Not simply appended: new songs land among the deferred ones.
      expect(
        queue.skip(9).take(31).toSet().intersection(ids(60, 40).toSet()),
        isNotEmpty,
      );
    });

    test('a song refreshed in place does not stop a release', () async {
      final (handler, player, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      // Liked-state (and art) updates replace queue entries outside the
      // queue lane, any time.
      var refreshing = true;
      var liked = false;
      final refresher = () async {
        while (refreshing) {
          liked = !liked;
          await handler.syncSongLikedState('song-0', liked: liked);
          await Future<void>.delayed(Duration.zero);
        }
      }();
      addTearDown(() => refreshing = false);
      player.moveTo(6);
      await until(() => player.sourceIds.length == 17);
      refreshing = false;
      await refresher;
      expect(player.sourceIds, ids(17));
      expect(handler.snapshot.queueSongIds, ids(60));
    });
    test('an alias update from inside a database transaction does not wait '
        'for queue work', () async {
      final (handler, player, database) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      // As sync does, before it remaps the rows in the same transaction: the
      // queue must not make the transaction wait for it.
      await database.transaction(() async {
        await handler
            .applySongIdentityAliases(<String, String>{'song-30': 'song-31'})
            .timeout(const Duration(seconds: 2));
      });
      await until(
        () =>
            handler.debugQueueLaneIdle &&
            handler.snapshot.queueSongIds[30] == 'song-31',
      );
      // Queue work started from inside the transaction must not keep using
      // it after it closed: its coalesced save lands, and a release still
      // reads the database.
      await Future<void>.delayed(const Duration(seconds: 1));
      final saved = await database.playQueueDao.getQueueItems();
      expect(saved.elementAt(30).id, 'song-31');
      player.moveTo(6);
      await until(() => player.sourceIds.length == 17);
    });
  });

  Map<String, Object?> fade(NavisAudioHandler handler) =>
      handler.collectPlaybackDiagnostics()['crossfade']!
          as Map<String, Object?>;

  group('cross-fade deck', () {
    List<String> ids(int count, [int from = 0]) =>
        List<String>.generate(count - from, (i) => 'song-${i + from}');

    Future<(NavisAudioHandler, _ControllableAudioPlayer, NavisDatabase)>
    crossfading(int count, {bool sidecarStreams = false}) async {
      final directory = await Directory.systemTemp.createTemp('navis-fade-');
      final created = await createHandler(
        directory,
        count,
        crossfade: true,
        sidecarStreams: sidecarStreams,
      );
      addTearDown(() async {
        await created.$1.disposeHandler();
        await created.$3.close();
        await directory.delete(recursive: true);
      });
      return created;
    }

    test(
      'a deck load that races a queue edit loads again before it plays',
      () async {
        final (handler, player, _) = await crossfading(8);
        await handler.replaceQueue(ids(6), expandMatchFlows: false);
        final deck = handler.debugInactiveDeck! as _ControllableAudioPlayer;
        final gate = Completer<void>();
        final entered = Completer<void>();
        deck
          ..loadGate = gate
          ..loadEntered = entered;

        final started = handler.debugStartCrossfade();
        await entered.future;
        // Queue edits do not wait for a fade.
        await handler.addToQueue(<String>[
          'song-6',
          'song-7',
        ], expandMatchFlows: false);
        gate.complete();
        await started;

        expect(player.sourceIds, ids(8));
        expect(deck.sourceIds, ids(8));
        expect(deck.isPlaying, isTrue);
        expect(fade(handler)['phases'], containsPair('deck_resynced', 1));

        await handler.debugCompleteCrossfade();
        expect(identical(handler.debugActivePlayer, deck), isTrue);
        expect(
          handler.collectPlaybackDiagnostics()['playerMatchesQueue'],
          true,
        );
        expect(handler.snapshot.queueSongIds, ids(8));
      },
    );

    test('a deck that missed an edit is never handed over', () async {
      final (handler, player, _) = await crossfading(6);
      await handler.replaceQueue(ids(6), expandMatchFlows: false);
      final deck = handler.debugInactiveDeck! as _ControllableAudioPlayer;
      await handler.debugStartCrossfade();
      expect(deck.isPlaying, isTrue);
      // A mirror the deck did not get.
      await deck.removeAudioSourceAt(5);

      await handler.debugCompleteCrossfade();

      expect(identical(handler.debugActivePlayer, player), isTrue);
      expect(deck.isPlaying, isFalse);
      expect(fade(handler)['active'], isFalse);
      expect(fade(handler)['phases'], containsPair('deck_mismatch', 1));
      expect(handler.collectPlaybackDiagnostics()['playerMatchesQueue'], true);
    });

    test(
      'a transition that cannot be prepared is not retried every tick',
      () async {
        final (handler, player, _) = await crossfading(6);
        await handler.replaceQueue(ids(6), expandMatchFlows: false);
        player.isPlaying = true;
        final deck = handler.debugInactiveDeck! as _ControllableAudioPlayer;
        // The deck cannot load the queue.
        deck.failLoadSongId = 'song-0';
        int failures() =>
            (fade(handler)['phases']! as Map<String, int>)['prewarm_failed'] ??
            0;
        const nearEnd = Duration(minutes: 2, seconds: 56);

        handler.debugCheckCrossfadeTrigger(nearEnd);
        for (var i = 0; i < 100 && failures() == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(failures(), 1);
        for (var tick = 0; tick < 5; tick++) {
          handler.debugCheckCrossfadeTrigger(nearEnd);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        expect(failures(), 1);
        expect(fade(handler)['active'], isFalse);
      },
    );

    test(
      'a transition that could not be prepared is tried again on a later play',
      () async {
        final (handler, player, _) = await crossfading(6);
        await handler.replaceQueue(ids(6), expandMatchFlows: false);
        player.isPlaying = true;
        final deck = handler.debugInactiveDeck! as _ControllableAudioPlayer;
        deck.failLoadSongId = 'song-0';
        int failures() =>
            (fade(handler)['phases']! as Map<String, int>)['prewarm_failed'] ??
            0;
        const nearEnd = Duration(minutes: 2, seconds: 56);
        Future<void> trigger(int expected) async {
          handler.debugCheckCrossfadeTrigger(nearEnd);
          for (var i = 0; i < 100 && failures() < expected; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        }

        await trigger(1);
        expect(failures(), 1);

        // Another song plays, then the first one again (as on repeat).
        await handler.playFromIndex(1);
        await handler.playFromIndex(0);
        for (var i = 0; i < 100 && handler.snapshot.isLoading; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        player.isPlaying = true;
        await trigger(2);

        expect(failures(), 2);
      },
    );

    test('a deck with the same length but other songs is reloaded', () async {
      final (handler, _, _) = await crossfading(7);
      await handler.replaceQueue(ids(6), expandMatchFlows: false);
      final deck = handler.debugInactiveDeck! as _ControllableAudioPlayer;
      // Same length as the queue, different last song.
      await deck.setAudioSources(<AudioSource>[
        for (final id in <String>[...ids(5), 'song-6'])
          AudioSource.uri(
            Uri.parse('file:///$id.mp3'),
            tag: MediaItem(id: id, title: id),
          ),
      ]);

      await handler.debugStartCrossfade();

      expect(deck.sourceIds, ids(6));
    });
  });

  group('remote first load', () {
    // A server that fetches a remote song before answering needs longer than
    // the ordinary load deadline on its first play.
    for (final external in [true, false]) {
      test('a slow first load of a ${external ? 'remote' : 'library'} '
          'stream ${external ? 'waits' : 'times out'}', () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-remote-',
        );
        final (handler, player, database) = await createHandler(
          directory,
          2,
          sidecarStreams: true,
          rebuiltPlayers: <_ControllableAudioPlayer>[],
          timeouts: const NavisPlaybackTimeouts(
            load: Duration(milliseconds: 300),
            remoteLoad: Duration(seconds: 5),
            control: Duration(milliseconds: 100),
            reset: Duration(milliseconds: 150),
          ),
          seed: (database) async {
            if (external) {
              await database.customStatement(
                "UPDATE songs SET is_external = 1 WHERE id = 'song-0'",
              );
            }
          },
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final gate = Completer<void>();
        player.loadGate = gate;
        final release = Timer(const Duration(milliseconds: 900), gate.complete);
        addTearDown(release.cancel);

        await handler
            .replaceQueue(['song-0', 'song-1'], expandMatchFlows: false)
            .catchError((Object _) {});

        final attempts =
            handler.collectPlaybackDiagnostics()['startupAttempts']! as List;
        final stages = [
          for (final attempt in attempts)
            for (final event in (attempt as Map)['events'] as List)
              (event as Map)['stage'],
        ];
        expect(stages.contains('player:active queue apply:timeout'), !external);
        if (external) {
          expect(player.sourceIds.first, 'song-0');
          expect(player.processingState, ProcessingState.ready);
        }
      });
    }
  });

  group('seek requests', () {
    const fastTimeouts = NavisPlaybackTimeouts(
      load: Duration(seconds: 2),
      control: Duration(milliseconds: 100),
      reset: Duration(milliseconds: 150),
      seekBufferingRecovery: Duration(milliseconds: 150),
    );
    Future<(NavisAudioHandler, _ControllableAudioPlayer, NavisDatabase)> setup({
      List<_ControllableAudioPlayer>? rebuilt,
    }) async {
      final directory = await Directory.systemTemp.createTemp('navis-seek-');
      final created = await createHandler(
        directory,
        4,
        timeouts: fastTimeouts,
        rebuiltPlayers: rebuilt,
      );
      addTearDown(() async {
        await created.$1.disposeHandler();
        await created.$3.close();
        await directory.delete(recursive: true);
      });
      created.$2.simulateProgress = true;
      return created;
    }

    for (final play in [true, false]) {
      test('latest seek survives loading with playing=$play', () async {
        final (handler, player, _) = await setup();
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..loadGate = gate
          ..loadEntered = entered;
        final load = handler.replaceQueue(
          ['song-0', 'song-1'],
          expandMatchFlows: false,
          autoPlay: play,
        );
        await entered.future;
        final old = handler.seek(const Duration(seconds: 30));
        final latest = handler.seek(const Duration(seconds: 90));
        expect(
          handler.snapshot.pendingSeekPosition,
          const Duration(seconds: 90),
        );
        expect(player.seekCalls, 0);
        expect(handler.snapshot.playing, play);
        gate.complete();
        await Future.wait([load, old, latest]);
        expect(
          (player.position - const Duration(seconds: 90)).abs().inMilliseconds,
          lessThan(1000),
        );
        expect(player.playing, play);
        expect(handler.snapshot.pendingSeekPosition, isNull);
        expect(
          (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
          'completed',
        );
      });
    }

    test('hung seek retires the engine before a newer seek uses it', () async {
      final rebuilt = <_ControllableAudioPlayer>[];
      final (handler, player, _) = await setup(rebuilt: rebuilt);
      await handler.replaceQueue(
        ['song-0', 'song-1', 'song-0'],
        startIndex: 2,
        expandMatchFlows: false,
      );
      const adjustments = PlaybackAdjustments(speed: 1.25, pitchSemitones: -2);
      await handler.setPlaybackAdjustments(adjustments);
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      player.hang.add('seek');
      final old = handler.seek(const Duration(seconds: 90));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final latest = handler.seek(const Duration(seconds: 40));
      await Future.wait([old, latest]);
      expect(rebuilt, hasLength(1));
      expect(
        (rebuilt.single.position - const Duration(seconds: 40))
            .abs()
            .inMilliseconds,
        lessThan(1000),
      );
      expect(rebuilt.single.index, 2);
      expect(rebuilt.single.sourceIds, ['song-0', 'song-1', 'song-0']);
      expect(rebuilt.single.playing, isTrue);
      expect(rebuilt.single.appliedSpeed, adjustments.speed);
      expect(
        rebuilt.single.appliedPitch,
        closeTo(adjustments.pitchFactor, 0.000001),
      );
      expect(rebuilt.single.appliedLoopMode, LoopMode.all);
      expect(player.seekCalls, 1);
    });

    test(
      'late callbacks from a timed-out engine cannot change the new selection',
      () async {
        final rebuilt = <_ControllableAudioPlayer>[];
        final (handler, player, _) = await setup(rebuilt: rebuilt);
        player.keepStreamsAfterDispose = true;
        addTearDown(player._indices.close);
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..seekGate = gate
          ..seekEntered = entered;
        final seek = handler.seek(const Duration(seconds: 90));
        await entered.future;
        final selection = handler.playFromIndex(1);
        await Future.wait([seek, selection]);
        // Navigation acknowledges admission before its serialized load settles.
        for (var attempt = 0; attempt < 100; attempt++) {
          if (rebuilt.length == 1 &&
              !handler.snapshot.isLoading &&
              handler.snapshot.currentIndex == 1) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(rebuilt, hasLength(1));
        expect(handler.snapshot.isLoading, isFalse);
        gate.complete();
        player._indices.add(0);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(handler.snapshot.currentIndex, 1);
        expect(handler.snapshot.pendingSeekPosition, isNull);
        expect(rebuilt.single.position.inMilliseconds, lessThan(1000));
      },
    );

    test(
      'removing the selected duplicate cancels its pending target',
      () async {
        final (handler, player, _) = await setup();
        await handler.replaceQueue([
          'song-0',
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        player.ignoreSeeks = true;
        final seek = handler.seek(const Duration(seconds: 90));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await handler.removeAt(0);
        await seek;
        expect(handler.snapshot.pendingSeekPosition, isNull);
        expect(handler.snapshot.queueSongIds, ['song-0', 'song-1']);
        expect(
          (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
          'superseded',
        );
      },
    );

    test(
      'an interpolated clock cannot confirm a stalled native seek',
      () async {
        final (handler, player, _) = await setup();
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        player.nativePositionFrozen = true;
        await handler.seek(const Duration(seconds: 90));
        final outcome = handler.collectPlaybackDiagnostics()['seek']! as Map;
        expect(outcome['outcome'], 'failed');
        expect(outcome['recoveryAttempts'], 1);
        await handler.debugRecoverCurrentSong();
        expect(
          (handler.collectPlaybackDiagnostics()['seek']!
              as Map)['recoveryAttempts'],
          1,
        );
        expect(handler.snapshot.queueSongIds, ['song-0', 'song-1']);
        expect(player.playing, isTrue);
        expect(handler.snapshot.pendingSeekPosition, isNull);
      },
    );

    test('a backend flapping between ready and buffering while it fetches '
        'still lands without recovery', () async {
      final (handler, player, _) = await setup();
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      // mpv reports the target at once but produces no packets yet, while
      // its buffering flag toggles many times a second.
      player.nativePositionFrozen = true;
      final flap = Timer.periodic(const Duration(milliseconds: 40), (_) {
        player.state = player.state == ProcessingState.ready
            ? ProcessingState.buffering
            : ProcessingState.ready;
      });
      final landed = Timer(const Duration(milliseconds: 700), () {
        flap.cancel();
        player
          ..state = ProcessingState.ready
          ..simulatedPosition = player.simulatedPosition
          ..nativePositionFrozen = false;
      });
      addTearDown(() {
        flap.cancel();
        landed.cancel();
      });
      await handler.seek(const Duration(seconds: 90));
      final outcome = handler.collectPlaybackDiagnostics()['seek']! as Map;
      expect(outcome['outcome'], 'completed');
      expect(outcome['recoveryAttempts'], 0);
      expect(
        (player.position - const Duration(seconds: 90)).abs(),
        lessThan(const Duration(seconds: 2)),
      );
    });

    for (final growing in [true, false]) {
      test(
        'a seek still buffering at the load deadline '
        '${growing ? 'waits while its buffer grows' : 'recovers when stuck'}',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'navis-seek-',
          );
          final (handler, player, database) = await createHandler(
            directory,
            2,
            rebuiltPlayers: <_ControllableAudioPlayer>[],
            timeouts: const NavisPlaybackTimeouts(
              load: Duration(milliseconds: 300),
              control: Duration(milliseconds: 100),
              reset: Duration(milliseconds: 150),
              seekBufferingRecovery: Duration(milliseconds: 150),
              seekProgress: Duration(seconds: 5),
            ),
          );
          addTearDown(() async {
            await handler.disposeHandler();
            await database.close();
            await directory.delete(recursive: true);
          });
          player.simulateProgress = true;
          await handler.replaceQueue([
            'song-0',
            'song-1',
          ], expandMatchFlows: false);
          player
            ..state = ProcessingState.buffering
            ..nativePositionFrozen = true;
          final fill = Timer.periodic(const Duration(milliseconds: 50), (_) {
            if (growing) {
              player.simulatedBuffered += const Duration(milliseconds: 500);
            }
          });
          final landed = Timer(const Duration(milliseconds: 900), () {
            player
              ..state = ProcessingState.ready
              ..simulatedPosition = player.simulatedPosition
              ..nativePositionFrozen = false;
          });
          addTearDown(() {
            fill.cancel();
            landed.cancel();
          });
          await handler.seek(const Duration(seconds: 90));
          final outcome = handler.collectPlaybackDiagnostics()['seek']! as Map;
          expect(outcome['recoveryAttempts'], growing ? 0 : 1);
          if (growing) expect(outcome['outcome'], 'completed');
        },
      );
    }

    test(
      'buffering range probes can outlast the short stall interval',
      () async {
        final (handler, player, _) = await setup();
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        player
          ..state = ProcessingState.buffering
          ..nativePositionFrozen = true;
        final ready = Timer(const Duration(milliseconds: 350), () {
          player
            ..state = ProcessingState.ready
            ..nativePositionFrozen = false;
        });
        addTearDown(ready.cancel);
        await handler.seek(const Duration(seconds: 90));
        final outcome = handler.collectPlaybackDiagnostics()['seek']! as Map;
        expect(outcome['outcome'], 'completed');
        expect(outcome['recoveryAttempts'], 0);
        expect(handler.snapshot.queueSongIds, ['song-0', 'song-1']);
      },
    );

    test(
      'recovery waits for a progressing sidecar to become a complete file',
      () async {
        final previousHttp = HttpOverrides.current;
        HttpOverrides.global = null;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        unawaited(() async {
          await for (final request in server) {
            request.response
              ..headers.contentType = ContentType('audio', 'mpeg')
              ..contentLength = 100
              ..add(List<int>.filled(80, 1));
            await request.response.flush();
            for (var chunk = 0; chunk < 4; chunk++) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
              request.response.add(List<int>.filled(5, 1));
              await request.response.flush();
            }
            await request.response.close();
          }
        }());
        final api = SubsonicApiClient(
          baseUrl: 'http://127.0.0.1:${server.port}',
          authConfig: const SubsonicAuthConfig(
            username: 'fixture',
            password: 'synthetic',
            apiVersion: '1.16.1',
          ),
          enableLogging: false,
        );
        final directory = await Directory.systemTemp.createTemp('navis-seek-');
        final (handler, player, database) = await createHandler(
          directory,
          2,
          sidecarStreams: true,
          readApiClient: () => api,
          timeouts: fastTimeouts,
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await server.close(force: true);
          await directory.delete(recursive: true);
          HttpOverrides.global = previousHttp;
        });
        await handler.replaceQueue(
          ['song-0', 'song-1', 'song-0'],
          startIndex: 2,
          expandMatchFlows: false,
        );
        player
          ..ignoreSeeks = true
          ..simulateProgress = true;
        for (var attempt = 0; attempt < 100; attempt++) {
          final activity = handler
              .collectPlaybackDiagnostics()['cacheActivity'];
          if (activity is Map && (activity['progress'] as num) >= 0.8) break;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await handler.seek(const Duration(seconds: 90));
        final outcome = handler.collectPlaybackDiagnostics()['seek']! as Map;
        expect(outcome['outcome'], 'completed');
        expect(outcome['recoveryAttempts'], 1);
        expect(handler.snapshot.queueSongIds, ['song-0', 'song-1', 'song-0']);
        expect(handler.snapshot.currentIndex, 2);
        expect(handler.queue.value[2].extras!['sourceKind'], 'file');
        expect(player.playing, isTrue);
      },
    );

    test('backward native no-op recovers to the requested position', () async {
      final (handler, player, _) = await setup();
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      player
        ..simulatedPosition = const Duration(seconds: 90)
        ..ignoreSeeks = true;
      await handler.seek(const Duration(seconds: 20));
      expect(
        (player.position - const Duration(seconds: 20)).abs().inMilliseconds,
        lessThan(1000),
      );
      expect(player.playing, isTrue);
      expect(
        (handler.collectPlaybackDiagnostics()['seek']!
            as Map)['recoveryAttempts'],
        1,
      );
    });

    for (final resetAccount in [true, false]) {
      test(
        'pending seek is cancelled by ${resetAccount ? 'account reset' : 'track selection'}',
        () async {
          final (handler, player, _) = await setup();
          final gate = Completer<void>();
          final entered = Completer<void>();
          player
            ..loadGate = gate
            ..loadEntered = entered;
          final load = handler.replaceQueue([
            'song-0',
            'song-1',
          ], expandMatchFlows: false);
          await entered.future;
          final seek = handler.seek(const Duration(seconds: 90));
          final selection = resetAccount
              ? handler.resetSession()
              : handler.replaceQueue(['song-1'], expandMatchFlows: false);
          gate.complete();
          await Future.wait([load, seek, selection]);
          expect(handler.snapshot.pendingSeekPosition, isNull);
          expect(player.position.inMilliseconds, lessThan(1000));
          expect(
            handler.snapshot.currentSongId,
            resetAccount ? isNull : 'song-1',
          );
        },
      );
    }
  });

  group('seek recovery', () {
    List<String> ids(int count, [int from = 0]) =>
        List<String>.generate(count - from, (i) => 'song-${i + from}');

    Future<(NavisAudioHandler, _ControllableAudioPlayer, NavisDatabase)>
    recovering(int count, {bool crossfade = false}) async {
      final directory = await Directory.systemTemp.createTemp('navis-recover-');
      final created = await createHandler(
        directory,
        count,
        crossfade: crossfade,
        sidecarStreams: true,
      );
      addTearDown(() async {
        await created.$1.disposeHandler();
        await created.$3.close();
        await directory.delete(recursive: true);
      });
      created.$2
        ..ignoreSeeks = true
        ..simulateProgress = true;
      return created;
    }

    /// Plays [count] songs from the second one, with its stream already cached
    /// in a completed sidecar file so a seek that does not land reloads the
    /// queue (the fake player never lands a seek).
    Future<void> start(NavisAudioHandler handler, int count) async {
      await handler.replaceQueue(
        ids(count),
        startIndex: 1,
        expandMatchFlows: false,
      );
      final sidecar =
          handler.queue.value[1].extras!['sidecarCacheFilePath'] as String;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await File(sidecar).writeAsBytes(List<int>.filled(64, 1));
    }

    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 300 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(condition(), isTrue);
    }

    test('reloads paused and resumes only once landed on the target', () async {
      final (handler, player, _) = await recovering(5);
      await start(handler, 5);
      // The native seek is a no-op and the reload ignores its initial
      // position: only the correction seek lands.
      player
        ..ignoreSeeks = false
        ..ignoredSeeks = 1
        ..ignoreInitialPosition = true;
      final playsBefore = player.playedFrom.length;

      await handler.seek(const Duration(seconds: 30));

      final outcome = handler.collectPlaybackDiagnostics()['seek']! as Map;
      expect(outcome['outcome'], 'completed');
      expect(outcome['recoveryAttempts'], 1);
      final resumed = player.playedFrom.skip(playsBefore).toList();
      expect(resumed, isNotEmpty);
      // Never heard from the start of the song.
      for (final position in resumed) {
        expect(
          (position - const Duration(seconds: 30)).abs(),
          lessThan(const Duration(seconds: 2)),
        );
      }
      expect(player.playing, isTrue);
    });

    test(
      'restores the whole queue even when playback is paused meanwhile',
      () async {
        final (handler, player, _) = await recovering(5);
        await start(handler, 5);
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..loadGate = gate
          ..loadEntered = entered;

        final seek = handler.seek(const Duration(seconds: 30));
        await entered.future;
        // A newer transport command while the current song reloads.
        await handler.pause();
        gate.complete();

        await until(
          () => player.sourceIds.length == 5 && !handler.snapshot.isLoading,
        );
        await seek;
        expect(player.position, const Duration(seconds: 30));
        expect(player.playing, isFalse);
        expect(player.sourceIds, ids(5));
        expect(handler.snapshot.queueSongIds, ids(5));
        expect(
          handler.collectPlaybackDiagnostics()['playerMatchesQueue'],
          true,
        );
      },
    );

    test(
      'Play during recovery of a paused song resumes at the target',
      () async {
        final (handler, player, _) = await recovering(5);
        await start(handler, 5);
        await handler.pause();
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..loadGate = gate
          ..loadEntered = entered;
        final seek = handler.seek(const Duration(seconds: 30));
        await entered.future;
        await handler.play();
        gate.complete();
        await seek;
        await until(
          () => player.sourceIds.length == 5 && !handler.snapshot.isLoading,
        );
        expect(player.playing, isTrue);
        expect(
          (player.position - const Duration(seconds: 30)).abs().inMilliseconds,
          lessThan(1000),
        );
        expect(handler.snapshot.queueSongIds, ids(5));
      },
    );

    test(
      'overlapping seeks during recovery restore the full duplicate queue',
      () async {
        final (handler, player, _) = await recovering(5);
        await handler.replaceQueue(
          ['song-0', 'song-1', 'song-1', 'song-2'],
          startIndex: 2,
          expandMatchFlows: false,
        );
        final sidecar =
            handler.queue.value[2].extras!['sidecarCacheFilePath']! as String;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await File(sidecar).writeAsBytes(List<int>.filled(64, 1));
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..loadGate = gate
          ..loadEntered = entered;
        final first = handler.seek(const Duration(seconds: 30));
        await entered.future;
        final latest = handler.seek(const Duration(seconds: 60));
        expect(
          handler.snapshot.pendingSeekPosition,
          const Duration(seconds: 60),
        );
        gate.complete();
        await Future.wait([first, latest]);
        await until(() => !handler.snapshot.isLoading);
        expect(player.index, 2);
        expect(player.sourceIds, ['song-0', 'song-1', 'song-1', 'song-2']);
        expect(
          (player.position - const Duration(seconds: 60)).abs().inMilliseconds,
          lessThan(1000),
        );
        expect(player.playing, isTrue);
        expect(
          (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
          'completed',
        );
      },
    );

    test('keeps an edit made while the current song reloads', () async {
      final (handler, player, _) = await recovering(7);
      await start(handler, 5);
      final gate = Completer<void>();
      final entered = Completer<void>();
      player
        ..loadGate = gate
        ..loadEntered = entered;

      unawaited(handler.seek(const Duration(seconds: 30)));
      await entered.future;
      final edit = handler.addToQueue(<String>[
        'song-5',
        'song-6',
      ], expandMatchFlows: false);
      gate.complete();
      await edit;

      await until(
        () => player.sourceIds.length == 7 && !handler.snapshot.isLoading,
      );
      expect(handler.snapshot.queueSongIds, ids(7));
      expect(player.sourceIds, ids(7));
    });

    test(
      'a song that cannot be reloaded keeps the queue and moves on',
      () async {
        final (handler, player, _) = await recovering(5);
        await start(handler, 5);
        // The stream that stalled fails again when reloaded.
        player.failLoadSongId = 'song-1';

        await handler.debugRecoverCurrentSong();

        await until(
          () =>
              handler.snapshot.currentSongId == 'song-2' &&
              !handler.snapshot.isLoading,
        );
        expect(handler.snapshot.queueSongIds, ids(5));
        expect(player.sourceIds, ids(5));
      },
    );

    /// Starts replacing the queue with [count] songs at [startIndex] and
    /// returns once the fill (phase 2) is held open, with the player
    /// holding only the start song.
    Future<Completer<void>> fillHeldOpen(
      NavisAudioHandler handler,
      _ControllableAudioPlayer player,
      int count, {
      required int startIndex,
    }) async {
      final gate = Completer<void>();
      final entered = Completer<void>();
      player
        ..appendGate = gate
        ..appendEntered = entered;
      unawaited(
        handler.replaceQueue(
          ids(count),
          startIndex: startIndex,
          expandMatchFlows: false,
        ),
      );
      await entered.future.timeout(const Duration(seconds: 5));
      return gate;
    }

    for (final startIndex in <int>[0, 2]) {
      test('keeps the whole queue when the stream stalls while the queue fills '
          '(start $startIndex)', () async {
        final (handler, player, _) = await recovering(6);
        final gate = await fillHeldOpen(
          handler,
          player,
          6,
          startIndex: startIndex,
        );

        final recovery = handler.debugRecoverCurrentSong();
        gate.complete();
        await recovery;

        await until(
          () => !handler.snapshot.isLoading && player.sourceIds.length == 6,
        );
        expect(handler.snapshot.queueSongIds, ids(6));
        expect(player.sourceIds, ids(6));
        expect(handler.snapshot.currentSongId, 'song-$startIndex');
        final events =
            handler.collectPlaybackDiagnostics()['seekEvents']!
                as List<Map<String, Object?>>;
        if (startIndex == 0) {
          expect(events.last['outcome'], 'reloaded');
        } else {
          // Until the fill places the start song, the song cannot be located
          // for recovery; the stall watchdog retries once it has.
          expect(events, isEmpty);
        }
      });
    }

    test('a stalled song that cannot be reloaded while the queue fills keeps '
        'the queue and moves on', () async {
      final (handler, player, _) = await recovering(6);
      final gate = await fillHeldOpen(handler, player, 6, startIndex: 0);
      player.failLoadSongId = 'song-0';

      final recovery = handler.debugRecoverCurrentSong();
      gate.complete();
      await recovery;

      await until(
        () =>
            handler.snapshot.currentSongId == 'song-1' &&
            !handler.snapshot.isLoading,
      );
      expect(handler.snapshot.queueSongIds, ids(6));
    });

    test('a skip rebuilds a player that lost its songs', () async {
      final (handler, player, _) = await recovering(5);
      await start(handler, 5);
      // As after a timed-out reload: the rebuilt player holds nothing.
      await player.setAudioSources(const <AudioSource>[]);

      await handler.playFromIndex(3);

      await until(
        () =>
            handler.snapshot.currentSongId == 'song-3' &&
            !handler.snapshot.isLoading,
      );
      expect(handler.snapshot.queueSongIds, ids(5));
      expect(player.sourceIds, ids(5));
      expect(player.index, 3);
    });

    test('cancels a cross-fade in progress', () async {
      final (handler, player, _) = await recovering(5, crossfade: true);
      await start(handler, 5);
      await handler.debugStartCrossfade();
      expect(fade(handler)['active'], isTrue);

      await handler.debugRecoverCurrentSong();

      await until(
        () => player.sourceIds.length == 5 && !handler.snapshot.isLoading,
      );
      expect(fade(handler)['active'], isFalse);
      expect(identical(handler.debugActivePlayer, player), isTrue);
      expect(handler.debugInactiveDeck!.playing, isFalse);
    });
  });

  group('deferred startup queue restore', () {
    SubsonicApiClient createApiClient() => SubsonicApiClient(
      baseUrl: 'https://example.com',
      authConfig: const SubsonicAuthConfig(
        username: 'alice',
        password: 'secret',
        apiVersion: '1.16.1',
      ),
      enableLogging: false,
    );

    String restoreOutcome(NavisAudioHandler handler) =>
        handler.collectPlaybackDiagnostics()['queueRestoreOutcome']! as String;

    test('retries paused once a session becomes available', () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-deferred-restore-',
      );
      SubsonicApiClient? api;
      final (handler, player, database) = await createHandler(
        directory,
        3,
        savedQueueIndex: 1,
        cacheSongs: false,
        readApiClient: () => api,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });

      expect(restoreOutcome(handler), 'deferred_auth');
      expect(handler.snapshot.queueSongIds, isEmpty);

      // Still no session: the retry defers again and keeps the saved queue.
      await handler.retryDeferredQueueRestore();
      expect(restoreOutcome(handler), 'deferred_auth');
      expect(handler.snapshot.queueSongIds, isEmpty);

      api = createApiClient();
      await handler.retryDeferredQueueRestore();

      expect(restoreOutcome(handler), 'restored');
      expect(handler.snapshot.queueSongIds, ['song-0', 'song-1', 'song-2']);
      expect(handler.snapshot.currentIndex, 1);
      expect(player.isPlaying, isFalse);
      expect((await database.playQueueDao.getQueueItems()).map((s) => s.id), [
        'song-0',
        'song-1',
        'song-2',
      ]);

      // Once restored, a later session change does not restore again.
      await handler.replaceQueue(
        ['song-2'],
        autoPlay: false,
        expandMatchFlows: false,
      );
      await handler.retryDeferredQueueRestore();
      expect(handler.snapshot.queueSongIds, ['song-2']);
    });

    test('yields to a queue the user starts meanwhile', () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-deferred-restore-user-',
      );
      SubsonicApiClient? api;
      final (handler, player, database) = await createHandler(
        directory,
        3,
        savedQueueIndex: 0,
        cacheSongs: false,
        readApiClient: () => api,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      expect(restoreOutcome(handler), 'deferred_auth');

      api = createApiClient();
      // The session arrives together with the user's own selection.
      final retry = handler.retryDeferredQueueRestore();
      final userQueue = handler.replaceQueue([
        'song-2',
      ], expandMatchFlows: false);
      await Future.wait([retry, userQueue]);
      await handler.retryDeferredQueueRestore();

      expect(restoreOutcome(handler), 'superseded');
      expect(handler.snapshot.queueSongIds, ['song-2']);
      expect(player.isPlaying, isTrue);
    });

    test('retries once an offline start comes back online', () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-deferred-restore-offline-',
      );
      final api = createApiClient();
      var online = false;
      final (handler, player, database) = await createHandler(
        directory,
        2,
        savedQueueIndex: 1,
        cacheSongs: false,
        readApiClient: () => api,
        readCanStream: () => online,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      expect(restoreOutcome(handler), 'deferred_auth');

      online = true;
      await handler.retryDeferredQueueRestore();

      expect(restoreOutcome(handler), 'restored');
      expect(handler.snapshot.queueSongIds, ['song-0', 'song-1']);
      expect(handler.snapshot.currentIndex, 1);
      expect(player.isPlaying, isFalse);
    });
  });

  group('queue window model', () {
    // A tiny window, so heads, tails, releases and trims happen constantly.
    const tiny = NavisQueueWindow(
      deferThreshold: 12,
      ahead: 3,
      lowWater: 2,
      page: 3,
      nearJump: 5,
      behind: 3,
      trimSlack: 1,
    );
    final seeds =
        int.tryParse(Platform.environment['NAVIS_QUEUE_MODEL_SEEDS'] ?? '') ??
        500;
    const steps = 24;
    const songCount = 30;

    Future<void> settle(NavisAudioHandler handler) async {
      var quiet = 0;
      for (var i = 0; i < 2000 && quiet < 3; i++) {
        await Future<void>.delayed(Duration.zero);
        quiet = handler.debugQueueLaneIdle && !handler.snapshot.isLoading
            ? quiet + 1
            : 0;
      }
      if (quiet < 3) fail('queue work did not settle');
    }

    test('matches a plain list through random edits and navigation', () async {
      final directory = await Directory.systemTemp.createTemp('navis-model-');
      addTearDown(() => directory.delete(recursive: true));
      for (var seed = 0; seed < seeds; seed++) {
        final random = Random(seed);
        final (handler, player, database) = await createHandler(
          directory,
          songCount,
          queueWindow: tiny,
        );
        final log = <String>[];
        try {
          var model = List<String>.generate(20, (i) => 'song-$i');
          var current = random.nextInt(model.length);
          await handler.replaceQueue(
            model,
            startIndex: current,
            expandMatchFlows: false,
          );
          await settle(handler);

          void check(String step) {
            final reason = 'seed $seed after ${log.join(', ')}';
            final snapshot = handler.snapshot;
            expect(snapshot.queueSongIds, model, reason: reason);
            expect(snapshot.currentIndex, current, reason: reason);
            expect(snapshot.currentSongId, model[current], reason: reason);
            final head =
                handler.collectPlaybackDiagnostics()['deferredHeadLength']
                    as int;
            final native = player.sourceIds;
            expect(
              native,
              model.sublist(head, head + native.length),
              reason: reason,
            );
            expect(player.index! + head, current, reason: reason);
            expect(player.shuffleEnabled, isFalse, reason: reason);
          }

          check('start');
          for (var step = 0; step < steps; step++) {
            final song = 'song-${random.nextInt(songCount)}';
            switch (random.nextInt(9)) {
              case 0:
                log.add('next');
                await handler.skipToNext();
                if (current < model.length - 1) current++;
              case 1:
                log.add('previous');
                await handler.skipToPrevious();
                if (current > 0) current--;
              case 2:
                final target = random.nextInt(model.length);
                log.add('jump $target');
                await handler.playFromIndex(target);
                current = target;
              case 3:
                final index = player.index!;
                if (index + 1 >= player.sourceIds.length) continue;
                log.add('advance');
                player.moveTo(index + 1);
                current++;
              case 4:
                log.add('add $song');
                await handler.addToQueue(<String>[
                  song,
                ], expandMatchFlows: false);
                model = <String>[...model, song];
              case 5:
                log.add('play next $song');
                await handler.playNext(<String>[song], expandMatchFlows: false);
                model = <String>[...model]..insert(current + 1, song);
              case 6:
                if (model.length < 3) continue;
                var index = random.nextInt(model.length);
                if (index == current) index = (index + 1) % model.length;
                log.add('remove $index');
                await handler.removeAt(index);
                model = <String>[...model]..removeAt(index);
                if (index < current) current--;
              case 7:
                var from = random.nextInt(model.length);
                if (from == current) from = (from + 1) % model.length;
                final to = random.nextInt(model.length + 1);
                final adjusted = from < to ? to - 1 : to;
                if (from == adjusted) continue;
                log.add('move $from to $to');
                await handler.reorderQueue(from, to);
                final next = <String>[...model];
                next.insert(adjusted, next.removeAt(from));
                model = next;
                if (from < current && adjusted >= current) {
                  current--;
                } else if (from > current && adjusted <= current) {
                  current++;
                }
              case 8:
                final on =
                    handler.snapshot.shuffleMode ==
                    AudioServiceShuffleMode.none;
                log.add(on ? 'shuffle on' : 'shuffle off');
                final playing = model[current];
                await handler.setShuffleMode(
                  on
                      ? AudioServiceShuffleMode.all
                      : AudioServiceShuffleMode.none,
                );
                await settle(handler);
                final reordered = handler.snapshot.queueSongIds;
                expect(
                  List<String>.of(reordered)..sort(),
                  List<String>.of(model)..sort(),
                  reason: 'seed $seed: ${log.join(', ')}',
                );
                expect(
                  handler.snapshot.currentSongId,
                  playing,
                  reason: 'seed $seed: ${log.join(', ')}',
                );
                if (on) {
                  expect(
                    reordered.take(current + 1),
                    model.take(current + 1),
                    reason: 'seed $seed: ${log.join(', ')}',
                  );
                }
                model = List<String>.of(reordered);
                current = handler.snapshot.currentIndex!;
            }
            await settle(handler);
            check(log.last);
          }
          await handler.debugFlushQueuePersistence();
          final saved = await database.playQueueDao.getQueueItems();
          expect(
            saved.map((song) => song.id),
            model,
            reason: 'seed $seed saved: ${log.join(', ')}',
          );
          expect(
            (await database.playQueueDao.getQueueState())!.currentIndex,
            current,
            reason: 'seed $seed saved index: ${log.join(', ')}',
          );
        } finally {
          await handler.disposeHandler();
          await database.close();
        }
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
