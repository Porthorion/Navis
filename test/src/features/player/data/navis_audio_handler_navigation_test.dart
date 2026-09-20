import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
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
  int? index;
  Completer<void>? seekGate;
  Completer<void>? loadGate;
  Completer<void>? loadEntered;
  int lastSetAudioSourcesCount = 0;
  int maxConcurrentMutations = 0;
  int _activeMutations = 0;

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
  Duration get position => Duration.zero;

  @override
  Duration get bufferedPosition => Duration.zero;

  @override
  Duration? get duration => const Duration(minutes: 3);

  @override
  double get volume => 1;

  @override
  double get speed => 1;

  @override
  LoopMode get loopMode => LoopMode.off;

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
  Future<void> setVolume(double value) async {}

  @override
  Future<void> setSpeed(double value) async {}

  @override
  Future<void> setLoopMode(LoopMode value) async {}

  @override
  Future<void> setShuffleModeEnabled(bool value) async {}

  @override
  Future<void> pause() async {
    isPlaying = false;
  }

  @override
  Future<void> play() async {
    isPlaying = true;
  }

  @override
  Future<void> stop() => _mutate(() async {
    isPlaying = false;
    state = ProcessingState.idle;
  });

  @override
  Future<Duration?> setAudioSources(
    List<AudioSource> sources, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ShuffleOrder? shuffleOrder,
  }) => _mutate(() async {
    state = ProcessingState.loading;
    final gate = loadGate;
    loadGate = null;
    if (gate != null) {
      loadEntered?.complete();
      await gate.future;
    }
    _sources = List<AudioSource>.of(sources);
    lastSetAudioSourcesCount = sources.length;
    index = sources.isEmpty ? null : initialIndex ?? 0;
    state = sources.isEmpty ? ProcessingState.idle : ProcessingState.ready;
    _indices.add(index);
    return const Duration(minutes: 3);
  });

  @override
  Future<void> addAudioSource(AudioSource source) => _mutate(() async {
    _sources.add(source);
  });

  @override
  Future<void> insertAudioSource(int at, AudioSource source) =>
      _mutate(() async {
        _sources.insert(at, source);
        if (index != null && at <= index!) index = index! + 1;
        _indices.add(index);
      });

  @override
  Future<void> seek(Duration? position, {int? index}) => _mutate(() async {
    final gate = seekGate;
    seekGate = null;
    if (gate != null) await gate.future;
    if (state == ProcessingState.loading) return;
    if (index != null) this.index = index;
    _indices.add(this.index);
  });

  @override
  Future<void> dispose() async {
    await _indices.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(NavisAudioHandler, _ControllableAudioPlayer, NavisDatabase)>
  createHandler(Directory directory, int count) async {
    final database = createTestDatabase();
    final songs = <SongsTableCompanion>[];
    for (var i = 0; i < count; i++) {
      final id = 'song-$i';
      songs.add(SongsTableCompanion.insert(id: id, title: 'Song $i'));
    }
    await database.libraryDao.upsertSongs(songs);
    for (var i = 0; i < count; i++) {
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
    final cache = DriftRollingCacheManager(cacheDao: database.cacheDao);
    final player = _ControllableAudioPlayer();
    final handler = NavisAudioHandler(
      libraryDao: database.libraryDao,
      playlistDao: database.playlistDao,
      playQueueDao: database.playQueueDao,
      matchFlowDao: database.matchFlowDao,
      historyDao: database.historyDao,
      sourceResolver: PlaybackSourceResolver(
        cacheDao: database.cacheDao,
        libraryDao: database.libraryDao,
        rollingCacheManager: cache,
        readApiClient: () => null,
        readStreamingQuality: () => const StreamingQuality(label: 'original'),
        readRollingCacheDirectory: () async => directory,
        readCachedPlaybackFirst: () => true,
      ),
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
      readRuntimeSettings: () => const PlaybackRuntimeSettings.defaults(),
      starSyncDao: database.starSyncDao,
      player: player,
    );
    await handler.waitUntilReady();
    return (handler, player, database);
  }

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
      final songs = await database.libraryDao.getSongsByIds(
        <String>['song-0', 'song-1', 'song-2'],
      );
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
      final songs = await database.libraryDao.getSongsByIds(
        <String>['song-0', 'song-1', 'song-2'],
      );
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
    final songs = await database.libraryDao.getSongsByIds(
      <String>['song-0', 'song-1'],
    );
    await handler.replaceQueueWithData(
      <SongsTableData>[songs[0], songs[1], songs[0]],
      startIndex: 2,
    );

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
}
