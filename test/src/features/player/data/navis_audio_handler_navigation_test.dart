import 'dart:math';

import 'package:navis/src/features/player/domain/playback_adjustments.dart';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' show Value;
import 'package:navis/src/features/auto/data/auto_media_id.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/features/player/data/radio_metadata_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/cache/data/rolling_cache_manager.dart';
import 'package:navis/src/features/integrations/domain/integration_artwork.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/player/data/listenbrainz_feedback_service.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/navis_shuffle_order.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/data/real_time_projection_audio_handler.dart';
import 'package:navis/src/features/player/data/scrobble_service.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/domain/streaming_quality.dart';

import '../../../../helpers/test_database.dart';

class _MockRadioDio extends Mock implements Dio;

class _GatedLibraryDao extends LibraryDao {
  new(super.attachedDatabase);

  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<List<SongsTableData>> getSongsByIds(
    Iterable<String> songIds, {
    bool includeLocalOnly = true,
  }) async {
    if (songIds.length == 1 && songIds.single == 'missing') {
      entered.complete();
      await release.future;
    }
    return await super.getSongsByIds(
      songIds,
      includeLocalOnly: includeLocalOnly,
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

class _TeardownArtworkService extends Fake implements CoverArtHttpFileService {
  bool closed = false;

  @override
  void close({bool force = false}) {
    closed = true;
  }
}

class _TeardownHttpClient extends Fake implements HttpClient {
  final requested = Completer<void>();
  final request = Completer<HttpClientRequest>();
  bool closed = false;

  @override
  Future<HttpClientRequest> getUrl(Uri uri) {
    requested.complete();
    return request.future;
  }

  @override
  void close({bool force = false}) {
    closed = force;
    if (requested.isCompleted && !request.isCompleted) {
      request.completeError(const HttpException('fixture client closed'));
    }
  }
}

class _TestAudioSession extends Fake implements AudioSession {
  final interruptions = StreamController<AudioInterruptionEvent>.broadcast();
  final noisy = StreamController<void>.broadcast();

  @override
  Stream<AudioInterruptionEvent> get interruptionEventStream =>
      interruptions.stream;

  @override
  Stream<void> get becomingNoisyEventStream => noisy.stream;

  Future<void> close() async {
    await interruptions.close();
    await noisy.close();
  }
}

class _ControllableAudioPlayer extends Fake implements AudioPlayer {
  final StreamController<int?> _indices = StreamController<int?>.broadcast();
  final _events = StreamController<PlaybackEvent>.broadcast();
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
  int stopCalls = 0;
  int? index;
  final List<double> appliedVolumes = [];
  double appliedSpeed = 1;
  double appliedPitch = 1;
  bool failPitchOnce = false;
  String? failAppendSongId;

  /// A load whose first song is this one fails, as a broken source would.
  String? failLoadSongId;
  Completer<void>? stopGate;
  Completer<void>? stopEntered;
  Completer<void>? seekGate;
  Completer<void>? seekEntered;
  bool gateNonEmptyLoadsOnly = false;
  Completer<void>? loadGate;
  Completer<void>? loadEntered;
  StateError? blockedLoadError;
  Completer<void>? appendGate;
  Completer<void>? appendEntered;
  String? attemptedSongId;
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
  Stream<PlaybackEvent> get playbackEventStream => _events.stream;

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
  Future<void> setVolume(double value) async {
    appliedVolumes.add(value);
  }

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
    stopCalls++;
    await _hangIf('stop');
    final gate = stopGate;
    stopGate = null;
    if (gate != null) {
      stopEntered?.complete();
      await gate.future;
    }
    isPlaying = false;
    state = ProcessingState.idle;
  });

  @override
  Stream<IcyMetadata?> get icyMetadataStream =>
      const Stream<IcyMetadata?>.empty();

  IcyMetadata? currentIcyMetadata;

  @override
  IcyMetadata? get icyMetadata => currentIcyMetadata;

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
    final source = sources.isEmpty ? null : sources[initialIndex ?? 0];
    if (source is IndexedAudioSource) {
      final tag = source.tag;
      if (tag is MediaItem) attemptedSongId = tag.id;
    }
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
    if (gate != null && (!gateNonEmptyLoadsOnly || sources.isNotEmpty)) {
      loadGate = null;
      loadEntered?.complete();
      await gate.future;
      if (blockedLoadError case final error?) throw error;
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
    if (!keepStreamsAfterDispose) {
      await _indices.close();
      await _events.close();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(NavisAudioHandler, _ControllableAudioPlayer, NavisDatabase)>
  createHandler(
    Directory directory,
    int count, {
    bool crossfade = false,
    bool matchFlow = false,
    int savedQueueIndex = -1,
    NavisQueueWindow queueWindow = const NavisQueueWindow(),
    NavisPlaybackTimeouts timeouts = const NavisPlaybackTimeouts(),
    List<_ControllableAudioPlayer>? rebuiltPlayers,
    _ControllableAudioPlayer? initialPlayer,
    bool waitForReady = true,
    LibraryDao Function(NavisDatabase)? createLibraryDao,
    // Songs stream from a server, with desktop sidecar caching.
    bool sidecarStreams = false,
    Future<void> Function(NavisDatabase database)? seed,
    bool cacheSongs = true,
    SubsonicApiClient? Function()? readApiClient,
    bool Function()? readCanStream,
    bool Function(Uri)? readRadioArtworkAllowed,
    bool Function()? readRadioMetadataAllowed,
    Dio Function()? createRadioMetadataDio,
    CoverArtHttpFileService? artworkFileService,
    Future<bool> Function({required bool autoPlay})? startPersonalRadio,
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
    final player = initialPlayer ?? _ControllableAudioPlayer();
    final handler = NavisAudioHandler(
      startPersonalRadio: (autoPlay) async =>
          await startPersonalRadio?.call(autoPlay: autoPlay) ?? false,
      startPreferredMix: (_) async {},
      togglePreferredMix: (_) async {},
      artworkFileService: artworkFileService,
      readRadioMetadataAllowed: readRadioMetadataAllowed ?? () => false,
      createRadioMetadataDio: createRadioMetadataDio,
      readRadioArtworkAllowed: readRadioArtworkAllowed,
      libraryDao: createLibraryDao?.call(database) ?? database.libraryDao,
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
        matchFlowEnabled: matchFlow,
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
    if (waitForReady) await handler.waitUntilReady();
    return (handler, player, database);
  }

  group('Android Auto resume precedence', () {
    for (final (name, active, saved, recent, liked, unavailable, expected) in [
      (
        'active before saved and fallbacks',
        true,
        true,
        true,
        true,
        null,
        'song-0',
      ),
      (
        'saved before recent and liked',
        false,
        true,
        true,
        true,
        null,
        'song-1',
      ),
      ('recent before liked', false, false, true, true, null, 'song-2'),
      ('liked before radio', false, false, false, true, null, 'song-3'),
      ('radio fallback', false, false, false, false, null, 'song-4'),
      ('no available source', false, false, false, false, null, null),
      (
        'failed saved restore tries recent',
        false,
        true,
        true,
        true,
        'song-1',
        'song-2',
      ),
      (
        'unavailable recent stops fallback',
        false,
        false,
        true,
        true,
        'song-2',
        null,
      ),
      (
        'unavailable liked stops fallback',
        false,
        false,
        false,
        true,
        'song-3',
        null,
      ),
    ]) {
      test(name, () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-resume-',
        );
        final radioRequests = <bool>[];
        late NavisAudioHandler radioHandler;
        final (handler, player, database) = await createHandler(
          directory,
          5,
          readCanStream: () => false,
          startPersonalRadio: ({required autoPlay}) async {
            radioRequests.add(autoPlay);
            if (expected != 'song-4') return false;
            await radioHandler.replaceQueue(
              ['song-4'],
              autoPlay: autoPlay,
              expandMatchFlows: false,
            );
            expect(radioHandler.snapshot.playing, isFalse);
            return true;
          },
        );
        radioHandler = handler;
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        if (active) {
          await handler.replaceQueue(['song-0'], autoPlay: false);
          await handler.debugFlushQueuePersistence();
        }
        if (saved) {
          await database.playQueueDao.saveQueue(
            songIds: ['song-1'],
            currentIndex: 0,
          );
        }
        if (recent) await database.historyDao.addPlayHistory('song-2');
        if (liked) {
          await database.libraryDao.setEntityStarred(
            'song',
            'song-3',
            DateTime.now(),
          );
        }
        if (unavailable != null) {
          final cached = await database.cacheDao.getCachedTrack(unavailable);
          await File(cached!.filePath).delete();
        }

        if (unavailable == 'song-2' || unavailable == 'song-3') {
          await expectLater(
            handler.play(),
            throwsA(isA<PlaybackSourceUnavailableException>()),
          );
        } else {
          await handler.play();
        }

        expect(handler.snapshot.currentSongId, expected);
        expect(player.playing, active || expected == 'song-1');
        expect(
          radioRequests,
          !active && !saved && !recent && !liked ? [false] : isEmpty,
        );
        if (expected == null && unavailable == null) {
          expect(
            handler.playbackState.value.processingState,
            AudioProcessingState.error,
          );
        }
      });
    }
  });

  group('Android Auto collections', () {
    for (final (type, root, order) in [
      (AutoMediaContextType.downloads, AutoMediaRoot.downloads, [2, 1, 0]),
      (AutoMediaContextType.liked, AutoMediaRoot.likedSongs, [2, 0]),
      (AutoMediaContextType.recent, AutoMediaRoot.recent, [2, 0]),
    ]) {
      for (final contextual in [false, true]) {
        test('${type.name} collection (contextual=$contextual)', () async {
          final directory = await Directory.systemTemp.createTemp(
            'navis-auto-',
          );
          final (handler, player, database) = await createHandler(
            directory,
            3,
            seed: (database) async {
              await database.libraryDao.upsertSongs([
                for (var i = 0; i < 3; i++)
                  SongsTableCompanion.insert(
                    id: 'song-$i',
                    title: 'Song $i',
                    createdAt: Value(DateTime(2026, 1, i + 1)),
                  ),
              ]);
              for (final i in [0, 2]) {
                await database.libraryDao.setEntityStarred(
                  'song',
                  'song-$i',
                  DateTime(2026, 1, i + 1),
                );
                await database
                    .into(database.playHistoryTable)
                    .insert(
                      PlayHistoryTableCompanion.insert(
                        songId: 'song-$i',
                        playedAt: DateTime(2026, 1, i + 1),
                      ),
                    );
              }
            },
          );
          addTearDown(() async {
            await handler.disposeHandler();
            await database.close();
            await directory.delete(recursive: true);
          });

          await handler.prepareFromMediaId(
            contextual
                ? AutoMediaId.song('song-0', contextType: type, contextId: root)
                : root,
          );

          expect(handler.snapshot.queueSongIds, [
            for (final i in order) 'song-$i',
          ]);
          expect(
            handler.snapshot.currentSongId,
            contextual ? 'song-0' : 'song-2',
          );
          expect(player.playing, isFalse);
        });
      }
    }
  });

  test('Previous restarts the first queue song within three seconds', () async {
    final directory = await Directory.systemTemp.createTemp('navis-previous-');
    final (handler, player, database) = await createHandler(directory, 2);
    addTearDown(() async {
      await handler.disposeHandler();
      await database.close();
      await directory.delete(recursive: true);
    });
    await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
    player.simulatedPosition = const Duration(seconds: 2);
    final cues = <TransportVisualCue>[];
    final subscription = handler.transportVisualCueStream.listen(cues.add);
    addTearDown(subscription.cancel);
    await handler.skipToPrevious();
    await Future<void>.delayed(Duration.zero);
    expect(handler.snapshot.currentSongId, 'song-0');
    expect(player.position, Duration.zero);
    expect(cues.last.intent, TransportVisualIntent.restartCurrent);
    expect(
      navisResolvePreviousTrackAction(
        queueLength: 2,
        currentIndex: 0,
        position: const Duration(seconds: 2),
      ),
      NavisPreviousTrackAction.restartCurrent,
    );
  });

  for (final noisy in [false, true]) {
    test('session pause stops both crossfade decks (noisy=$noisy)', () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-interrupted-fade-',
      );
      final (handler, player, database) = await createHandler(
        directory,
        3,
        crossfade: true,
      );
      final session = _TestAudioSession();
      handler.debugWireAudioSession(session);
      addTearDown(() async {
        await handler.disposeHandler();
        await session.close();
        await database.close();
        await directory.delete(recursive: true);
      });
      await handler.replaceQueue([
        'song-0',
        'song-1',
        'song-2',
      ], expandMatchFlows: false);
      await handler.debugStartCrossfade();
      final deck = handler.debugInactiveDeck!;
      expect(deck.playing, isTrue);
      if (noisy) {
        session.noisy.add(null);
      } else {
        session.interruptions.add(
          AudioInterruptionEvent(true, AudioInterruptionType.pause),
        );
      }
      await Future<void>.delayed(Duration.zero);
      expect(player.playing, isFalse);
      expect(deck.playing, isFalse);
      expect(
        (handler.collectPlaybackDiagnostics()['crossfade']! as Map)['active'],
        isFalse,
      );
      if (!noisy) {
        session.interruptions.add(
          AudioInterruptionEvent(false, AudioInterruptionType.pause),
        );
        await Future<void>.delayed(Duration.zero);
        expect(player.playing, isTrue);
        expect(deck.playing, isFalse);
      }
    });
  }

  for (final pauseDuring in [false, true]) {
    test(
      'interruption resume respects explicit Pause ($pauseDuring)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-interruption-',
        );
        final (handler, player, database) = await createHandler(directory, 1);
        final session = _TestAudioSession();
        handler.debugWireAudioSession(session);
        addTearDown(() async {
          await handler.disposeHandler();
          expect(session.interruptions.hasListener, isFalse);
          expect(session.noisy.hasListener, isFalse);
          await session.close();
          await database.close();
          await directory.delete(recursive: true);
        });
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        session.interruptions.add(
          AudioInterruptionEvent(true, AudioInterruptionType.pause),
        );
        await Future<void>.delayed(Duration.zero);
        expect(player.playing, isFalse);
        if (pauseDuring) {
          await handler.pause();
        }
        session.interruptions.add(
          AudioInterruptionEvent(false, AudioInterruptionType.pause),
        );
        await Future<void>.delayed(Duration.zero);
        expect(player.playing, !pauseDuring);
        await handler.setVolume(0.8);
        player.appliedVolumes.clear();
        session.interruptions.add(
          AudioInterruptionEvent(true, AudioInterruptionType.duck),
        );
        await Future<void>.delayed(Duration.zero);
        session.interruptions.add(
          AudioInterruptionEvent(false, AudioInterruptionType.duck),
        );
        await Future<void>.delayed(Duration.zero);
        expect(player.appliedVolumes, [closeTo(0.32, 0.0001), 0.8]);
        handler.beginTeardown();
        await handler.disposeHandler();
      },
    );
  }

  for (final mediaClick in [false, true]) {
    test(
      'system pause during interruption sticks (click: $mediaClick)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-system-interruption-',
        );
        final (handler, player, database) = await createHandler(directory, 1);
        final system = RealTimeProjectionAudioHandler(handler);
        final session = _TestAudioSession();
        handler.debugWireAudioSession(session);
        addTearDown(() async {
          await handler.disposeHandler();
          await session.close();
          await database.close();
          await directory.delete(recursive: true);
        });
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        session.interruptions.add(
          AudioInterruptionEvent(true, AudioInterruptionType.pause),
        );
        await Future<void>.delayed(Duration.zero);
        expect(player.playing, isFalse);

        if (mediaClick) {
          await system.click();
        } else {
          await system.pause();
        }
        expect(player.playing, isFalse);
        session.interruptions.add(
          AudioInterruptionEvent(false, AudioInterruptionType.pause),
        );
        await Future<void>.delayed(Duration.zero);
        expect(player.playing, isFalse);

        await system.click();
        expect(player.playing, isTrue);
        await system.click();
        expect(player.playing, isFalse);
      },
    );
  }

  test(
    'begin then dispose closes all handler streams and browse parents',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-teardown-',
      );
      final artwork = _TeardownArtworkService();
      final (handler, player, database) = await createHandler(
        directory,
        1,
        crossfade: true,
        artworkFileService: artwork,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final closed = <Future<void>>[
        for (final stream in <Stream<dynamic>>[
          handler.snapshotStream,
          handler.playbackAdjustmentsStream,
          handler.equalizerStateStream,
          handler.transportVisualCueStream,
          handler.positionStream,
          handler.bufferStateStream,
          handler.radioStreamErrorStream,
          handler.loadFailureStream,
          handler.droppedSongsStream,
          handler.subscribeToChildren('root'),
          handler.subscribeToChildren('root/recent'),
          handler.subscribeToChildren(AudioService.recentRootId),
        ])
          stream.listen((_) {}).asFuture<void>(),
      ];
      handler.beginTeardown();
      expect(player.stopCalls, 1);
      expect(
        artwork.closed,
        Platform.isAndroid || Platform.isLinux || Platform.isWindows,
      );
      final disposal = handler.disposeHandler();
      await disposal;
      await Future.wait(closed).timeout(const Duration(seconds: 1));
      expect(identical(disposal, handler.disposeHandler()), isTrue);
      expect(player._indices.hasListener, isFalse);
      expect(handler.debugInactiveDeck, isNull);
    },
  );

  test(
    'desktop diagnostics expose bytes from the active sidecar attempt',
    () async {
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final release = Completer<void>();
      server.listen((request) async {
        try {
          request.response
            ..bufferOutput = false
            ..contentLength = 100 * 1024
            ..add(List<int>.filled(40 * 1024, 1));
          await request.response.flush();
          await release.future;
          request.response.add(List<int>.filled(60 * 1024, 1));
          await request.response.close();
        } on HttpException {
          // The handler cancels the unfinished transfer at teardown.
        }
      });
      final api = SubsonicApiClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        authConfig: const SubsonicAuthConfig(
          username: 'fixture',
          password: 'synthetic',
          apiVersion: '1.16.1',
        ),
        enableLogging: false,
      );
      final directory = await Directory.systemTemp.createTemp(
        'navis-sidecar-bytes-',
      );
      final (handler, _, database) = await createHandler(
        directory,
        1,
        sidecarStreams: true,
        readApiClient: () => api,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        release.complete();
        await database.close();
        await server.close(force: true);
        await directory.delete(recursive: true);
        HttpOverrides.global = previousHttp;
      });
      await handler.replaceQueue(['song-0'], expandMatchFlows: false);
      for (var attempt = 0; attempt < 400; attempt++) {
        final activity = handler.collectPlaybackDiagnostics()['cacheActivity'];
        if (activity is Map && (activity['progress'] as num) >= 0.4) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final diagnostics = handler.collectPlaybackDiagnostics();
      expect(diagnostics['cacheActivity'], isNotNull);
      expect(diagnostics['partialCacheBytes'], 40 * 1024);
    },
  );

  for (final fail in [false, true]) {
    test(
      'desktop cache activity clears after ${fail ? 'failure' : 'cancellation'}',
      () async {
        final previousHttp = HttpOverrides.current;
        HttpOverrides.global = null;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final release = Completer<void>();
        server.listen((request) async {
          try {
            request.response
              ..bufferOutput = false
              ..contentLength = 100 * 1024
              ..add(List<int>.filled(40 * 1024, 1));
            await request.response.flush();
            await release.future;
            await server.close(force: true);
          } on HttpException {
            // The handler cancels the unfinished transfer at teardown.
          }
        });
        final api = SubsonicApiClient(
          baseUrl: 'http://127.0.0.1:${server.port}',
          authConfig: const SubsonicAuthConfig(
            username: 'fixture',
            password: 'synthetic',
            apiVersion: '1.16.1',
          ),
          enableLogging: false,
        );
        final directory = await Directory.systemTemp.createTemp(
          'navis-sidecar-terminal-',
        );
        final (handler, _, database) = await createHandler(
          directory,
          2,
          sidecarStreams: true,
          readApiClient: () => api,
        );
        addTearDown(() async {
          await handler.disposeHandler();
          if (!release.isCompleted) release.complete();
          await database.close();
          await server.close(force: true);
          await directory.delete(recursive: true);
          HttpOverrides.global = previousHttp;
        });
        final cached = File.fromUri(directory.uri.resolve('cached.mp3'));
        await cached.writeAsBytes(<int>[1, 2, 3]);
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'song-1',
            filePath: cached.path,
            fileSize: 3,
            format: 'mp3',
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        for (var attempt = 0; attempt < 400; attempt++) {
          final activity = handler
              .collectPlaybackDiagnostics()['cacheActivity'];
          if (activity is Map && (activity['progress'] as num) >= 0.4) break;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(
          handler.collectPlaybackDiagnostics()['cacheActivity'],
          isNotNull,
        );
        if (fail) {
          release.complete();
          for (var attempt = 0; attempt < 400; attempt++) {
            if (handler
                    .collectPlaybackDiagnostics()['sidecarCacheActiveSongId'] ==
                null) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        } else {
          await handler.skipToNext();
          await pumpEventQueue();
        }
        expect(
          handler.collectPlaybackDiagnostics()['sidecarCacheActiveSongId'],
          isNull,
        );
        expect(handler.collectPlaybackDiagnostics()['cacheActivity'], isNull);
      },
    );
  }

  test('remote warm-up stops after bytes when Range is ignored', () async {
    final previousHttp = HttpOverrides.current;
    HttpOverrides.global = null;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final firstBytes = Completer<void>();
    final release = Completer<void>();
    server.listen((request) async {
      try {
        request.response
          ..bufferOutput = false
          ..contentLength = 100 * 1024
          ..add(List<int>.filled(40 * 1024, 1));
        await request.response.flush();
        if (request.headers.value(HttpHeaders.rangeHeader) == 'bytes=0-1' &&
            !firstBytes.isCompleted) {
          firstBytes.complete();
        }
        await release.future;
        request.response.add(List<int>.filled(60 * 1024, 1));
        await request.response.close();
      } on HttpException {
        // The probe closes the ignored-range response after its first chunk.
      }
    });
    final api = SubsonicApiClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      authConfig: const SubsonicAuthConfig(
        username: 'fixture',
        password: 'synthetic',
        apiVersion: '1.16.1',
      ),
      enableLogging: false,
    );
    final directory = await Directory.systemTemp.createTemp('navis-warmup-');
    final (handler, player, database) = await createHandler(
      directory,
      1,
      sidecarStreams: true,
      readApiClient: () => api,
    );
    final song = (await database.libraryDao.getSongsByIds(['song-0'])).single;
    final replacing = handler.replaceQueueWithData([
      song.copyWith(isExternal: true),
    ], expandMatchFlows: false);
    addTearDown(() async {
      release.complete();
      await replacing;
      await handler.disposeHandler();
      await database.close();
      await server.close(force: true);
      await directory.delete(recursive: true);
      HttpOverrides.global = previousHttp;
    });
    await firstBytes.future.timeout(const Duration(seconds: 2));
    for (
      var attempt = 0;
      attempt < 100 && player.sourceIds.isEmpty;
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(player.sourceIds, ['song-0']);
    expect(release.isCompleted, isFalse);
  });

  test('begin then dispose cancels an in-flight sidecar client', () async {
    final directory = await Directory.systemTemp.createTemp(
      'navis-teardown-sidecar-',
    );
    final client = _TeardownHttpClient();
    await HttpOverrides.runZoned(() async {
      final (handler, _, database) = await createHandler(
        directory,
        1,
        sidecarStreams: true,
        artworkFileService: _TeardownArtworkService(),
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      await handler.replaceQueue(['song-0'], expandMatchFlows: false);
      await client.requested.future.timeout(const Duration(seconds: 2));
      handler.beginTeardown();
      await handler.disposeHandler();
      await pumpEventQueue();
      expect(client.closed, isTrue);
      expect(
        handler.collectPlaybackDiagnostics()['sidecarCacheActiveSongId'],
        isNull,
      );
    }, createHttpClient: (_) => client);
  });

  for (final initiallyAllowed in [true, false]) {
    test(
      'radio policy refresh resumes polling (initially $initiallyAllowed)',
      () async {
        var allowed = initiallyAllowed;
        var requests = 0;
        final dio = _MockRadioDio();
        when(
          () => dio.get<Map<String, dynamic>>(
            any(),
            options: any(named: 'options'),
          ),
        ).thenAnswer((_) async {
          requests++;
          return Response<Map<String, dynamic>>(
            requestOptions: RequestOptions(),
            statusCode: 200,
            data: {
              'now_playing': {
                'song': {'title': 'Song', 'artist': 'Artist'},
              },
            },
          );
        });
        final directory = Directory.systemTemp.createTempSync('radio-policy-');
        final (handler, _, database) = await createHandler(
          directory,
          0,
          readRadioMetadataAllowed: () => allowed,
          createRadioMetadataDio: () => dio,
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          directory.deleteSync(recursive: true);
        });
        await handler.playRadioStream(
          stationId: 'fixture',
          stationName: 'Fixture',
          streamUrl: 'https://radio.example.invalid/listen/fixture/stream',
        );
        await Future<void>.delayed(Duration.zero);
        expect(requests, initiallyAllowed ? 1 : 0);
        allowed = false;
        handler.updateRadioMetadata();
        // The policy refresh stops polling synchronously.
        final before = requests;
        allowed = true;
        handler.updateRadioMetadata();
        await Future<void>.delayed(Duration.zero);
        expect(requests, before + 1);
        final radio =
            handler.collectPlaybackDiagnostics()['radio']!
                as Map<String, Object?>;
        expect(radio['metadataSource'], 'azuracast');
        expect(radio['nowPlayingTitle'], 'Song');
        expect(radio['nowPlayingArtist'], 'Artist');
      },
    );
  }

  for (final icyTitle in <String?>[null, 'ICY Song', 'ICY Artist - ICY Song']) {
    test('disabling radio lookups replaces Azuracast with $icyTitle', () async {
      var allowed = true;
      final dio = _MockRadioDio();
      when(
        () => dio.get<Map<String, dynamic>>(
          any(),
          options: any(named: 'options'),
        ),
      ).thenAnswer(
        (_) async => Response<Map<String, dynamic>>(
          requestOptions: RequestOptions(),
          statusCode: 200,
          data: {
            'now_playing': {
              'song': {
                'title': 'API Song',
                'artist': 'API Artist',
                'art': 'https://art.example.invalid/old.jpg',
              },
            },
          },
        ),
      );
      final directory = Directory.systemTemp.createTempSync('radio-disable-');
      final (handler, player, database) = await createHandler(
        directory,
        0,
        readRadioMetadataAllowed: () => allowed,
        readRadioArtworkAllowed: (_) => allowed,
        createRadioMetadataDio: () => dio,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        directory.deleteSync(recursive: true);
      });
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: 'https://radio.example.invalid/listen/fixture/stream',
      );
      await Future<void>.delayed(Duration.zero);
      expect(handler.mediaItem.value!.title, 'API Song');
      player.currentIcyMetadata = icyTitle == null
          ? null
          : IcyMetadata(
              info: IcyInfo(title: icyTitle, url: null),
              headers: null,
            );
      allowed = false;
      handler.updateRadioMetadata();
      final radio = handler.collectPlaybackDiagnostics()['radio']! as Map;
      expect(
        handler.mediaItem.value!.title,
        icyTitle == null ? 'Fixture' : 'ICY Song',
      );
      expect(
        handler.mediaItem.value!.artist,
        icyTitle != null && icyTitle.contains(' - ') ? 'ICY Artist' : 'Fixture',
      );
      expect(radio['metadataSource'], icyTitle == null ? 'none' : 'icy');
      expect(
        radio['nowPlayingArtist'],
        icyTitle != null && icyTitle.contains(' - ') ? 'ICY Artist' : null,
      );
      expect(radio['nowPlayingArtHash'], isNull);
      expect(radio['publishedArtHash'], isNull);
    });
  }

  for (final streamFailure in [false, true]) {
    test(
      'radio failure logs omit URLs carried by native errors ($streamFailure)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-radio-logs-',
        );
        const url = 'https://radio.example.invalid/private?token=fixture-token';
        final lines = <String>[];
        await runZoned(
          () async {
            final (handler, player, database) = await createHandler(
              directory,
              0,
            );
            addTearDown(() async {
              await handler.disposeHandler();
              await database.close();
              await directory.delete(recursive: true);
            });
            if (!streamFailure) {
              player
                ..loadGate = (Completer<void>()..complete())
                ..blockedLoadError = StateError(url);
              await expectLater(
                handler.playRadioStream(
                  stationId: 'fixture',
                  stationName: 'Fixture',
                  streamUrl: url,
                ),
                throwsStateError,
              );
            } else {
              await handler.playRadioStream(
                stationId: 'fixture',
                stationName: 'Fixture',
                streamUrl: url,
              );
              player._events.addError(StateError(url), StackTrace.current);
              await pumpEventQueue();
            }
          },
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => lines.add(line),
          ),
        );
        expect(lines, isNotEmpty);
        expect(lines.join('\n'), isNot(contains('fixture-token')));
        expect(lines.join('\n'), isNot(contains('/private')));
      },
    );
  }

  for (final streamFailure in [false, true]) {
    test(
      'radio restore timeout keeps saved queue (failure=$streamFailure)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-radio-restore-',
        );
        final rebuilt = <_ControllableAudioPlayer>[];
        final (handler, player, database) = await createHandler(
          directory,
          3,
          rebuiltPlayers: rebuilt,
        );
        final gate = Completer<void>();
        final entered = Completer<void>();
        addTearDown(() async {
          if (!gate.isCompleted) gate.complete();
          await pumpEventQueue();
          await handler.disposeHandler();
          player.keepStreamsAfterDispose = false;
          await player.dispose();
          await database.close();
          await directory.delete(recursive: true);
        });
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        await handler.debugFlushQueuePersistence();
        await handler.playRadioStream(
          stationId: 'fixture',
          stationName: 'Fixture',
          streamUrl: 'https://radio.example.invalid/stream',
        );
        player
          ..gateNonEmptyLoadsOnly = true
          ..loadGate = gate
          ..loadEntered = entered
          ..keepStreamsAfterDispose = true;
        if (streamFailure) {
          player._events.addError(
            StateError('fixture radio failure'),
            StackTrace.current,
          );
        } else {
          await handler.stopRadio();
        }
        await entered.future.timeout(const Duration(seconds: 2));
        await Future<void>.delayed(const Duration(seconds: 11));
        expect(
          (await database.playQueueDao.getQueueItems()).map((song) => song.id),
          ['song-0', 'song-1'],
        );
        expect(handler.debugQueueLaneIdle, isTrue);
        expect(
          handler.collectPlaybackDiagnostics()['queueRestoreOutcome'],
          'timeout',
        );
        await handler.replaceQueue(['song-2'], expandMatchFlows: false);
        gate.complete();
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(handler.snapshot.currentSongId, 'song-2');
        expect(
          (await database.playQueueDao.getQueueItems()).map((song) => song.id),
          ['song-2'],
        );
      },
    );
  }

  test(
    'published radio items keep the stream URL in handler state only',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-radio-url-',
      );
      final (handler, _, database) = await createHandler(directory, 0);
      final projection = RealTimeProjectionAudioHandler(handler);
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      const url = 'https://radio.example.invalid/listen?token=fixture-token';
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: url,
      );
      for (final update in [false, true]) {
        if (update) {
          handler.updateRadioMetadata(title: 'Track', artist: 'Artist');
        }
        await Future<void>.delayed(Duration.zero);
        expect(handler.snapshot.radioStation!.streamUrl, url);
        for (final item in [
          handler.mediaItem.value!,
          ...handler.queue.value,
          projection.mediaItem.value!,
          ...projection.queue.value,
        ]) {
          expect(item.extras, {'isRadio': true});
          expect(item.toString(), isNot(contains('fixture-token')));
        }
        expect(
          handler.collectPlaybackDiagnostics().toString(),
          isNot(contains('fixture-token')),
        );
      }
    },
  );

  group('radio metadata lifecycle', () {
    Future<(NavisAudioHandler, _ControllableAudioPlayer)> setup({
      Dio? dio,
      List<_ControllableAudioPlayer>? rebuilt,
      NavisPlaybackTimeouts timeouts = const NavisPlaybackTimeouts(),
    }) async {
      final directory = Directory.systemTemp.createTempSync('radio-lifecycle-');
      final (handler, player, database) = await createHandler(
        directory,
        0,
        readRadioMetadataAllowed: () => dio != null,
        createRadioMetadataDio: dio == null ? null : () => dio,
        readRadioArtworkAllowed: (_) => true,
        rebuiltPlayers: rebuilt,
        timeouts: timeouts,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        directory.deleteSync(recursive: true);
      });
      await handler.playRadioStream(
        stationId: 'a',
        stationName: 'Station A',
        streamUrl: 'https://radio.example.invalid/listen/a/stream',
      );
      return (handler, player);
    }

    test(
      'superseded radio source failure completes without reporting error',
      () async {
        final (handler, player) = await setup();
        final gate = Completer<void>();
        final entered = Completer<void>();
        final stopsBeforeSwitch = player.stopCalls;
        player.loadGate = gate;
        player.loadEntered = entered;
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final oldLoad = handler.playRadioStream(
          stationId: 'b',
          stationName: 'Station B',
          streamUrl: 'https://stream.example.invalid/b',
        );
        final oldResult = expectLater(oldLoad, completes);
        await entered.future;
        final newLoad = handler.playRadioStream(
          stationId: 'c',
          stationName: 'Station C',
          streamUrl: 'https://stream.example.invalid/c',
        );
        gate.completeError(StateError('superseded load failed'));
        await oldResult;
        await newLoad;
        expect(player.stopCalls, stopsBeforeSwitch + 2);
        expect(handler.snapshot.radioStation?.stationId, 'c');
        expect(handler.mediaItem.value?.title, 'Station C');
        expect(player.playing, isTrue);
      },
    );

    for (final failLoad in [false, true]) {
      test(
        'station A late poll is dropped ${failLoad ? 'after B load failure' : 'during B load'}',
        () async {
          final dio = _MockRadioDio();
          final pending = Completer<Response<Map<String, dynamic>>>();
          when(
            () => dio.get<Map<String, dynamic>>(
              any(),
              options: any(named: 'options'),
            ),
          ).thenAnswer((_) => pending.future);
          final (handler, player) = await setup(dio: dio);
          final gate = Completer<void>();
          final entered = Completer<void>();
          if (failLoad) {
            player.failLoadSongId = 'radio:b';
          } else {
            player.loadGate = gate;
            player.loadEntered = entered;
          }
          if (!failLoad) {
            addTearDown(() {
              if (!gate.isCompleted) gate.complete();
            });
          }
          final switching = handler.playRadioStream(
            stationId: 'b',
            stationName: 'Station B',
            streamUrl: 'https://stream.example.invalid/b',
          );
          if (failLoad) {
            await expectLater(switching, throwsStateError);
          } else {
            await entered.future;
          }
          // Finish A's in-flight request while B has not started listening.
          pending.complete(
            Response<Map<String, dynamic>>(
              requestOptions: RequestOptions(),
              statusCode: 200,
              data: {
                'now_playing': {
                  'song': {
                    'title': 'Old Song',
                    'artist': 'Old Artist',
                    'art': 'https://art.example.invalid/old.jpg',
                  },
                },
              },
            ),
          );
          await Future<void>.delayed(Duration.zero);
          if (failLoad) {
            // Wait one interval to prove the failed load stopped A's timer.
            await Future<void>.delayed(
              RadioMetadataService.pollingInterval +
                  const Duration(milliseconds: 50),
            );
            handler.updateRadioMetadata();
            verify(
              () => dio.get<Map<String, dynamic>>(
                any(),
                options: any(named: 'options'),
              ),
            ).called(1);
            expect(handler.snapshot.radioStation, isNull);
          } else {
            expect(handler.snapshot.radioStation!.nowPlayingTitle, isNull);
            expect(handler.snapshot.radioStation!.nowPlayingArtUrl, isNull);
            expect(handler.mediaItem.value!.title, isNot('Old Song'));
            final radio = handler.collectPlaybackDiagnostics()['radio']! as Map;
            expect(radio['metadataSource'], 'none');
            gate.complete();
            await switching;
          }
        },
      );
    }

    test(
      'diagnostics drops previous station art while the next source loads',
      () async {
        final (handler, player) = await setup();
        handler.updateRadioMetadata(
          title: 'Old Song',
          artUrl: 'https://art.example.invalid/old.jpg',
        );
        expect(
          (handler.collectPlaybackDiagnostics()['radio']!
              as Map)['publishedArtHash'],
          '522085851bcf10e0',
        );
        final gate = Completer<void>();
        final entered = Completer<void>();
        player.loadGate = gate;
        player.loadEntered = entered;
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final switching = handler.playRadioStream(
          stationId: 'b',
          stationName: 'Station B',
          streamUrl: 'https://stream.example.invalid/b',
        );
        await entered.future;
        final radio = handler.collectPlaybackDiagnostics()['radio']! as Map;
        expect(radio['stationId'], 'b');
        expect(radio['publishedArtHash'], isNull);
        gate.complete();
        await switching;
        handler.updateRadioMetadata(
          artUrl: 'https://art.example.invalid/new.jpg',
        );
        expect(
          (handler.collectPlaybackDiagnostics()['radio']!
              as Map)['publishedArtHash'],
          'b46273cb236821e0',
        );
      },
    );

    test('player rebind preserves the displayed metadata source', () async {
      final rebuilt = <_ControllableAudioPlayer>[];
      final (handler, player) = await setup(
        rebuilt: rebuilt,
        timeouts: const NavisPlaybackTimeouts(
          reset: Duration(milliseconds: 50),
        ),
      );
      player.currentIcyMetadata = IcyMetadata(
        info: IcyInfo(title: 'Artist - Song', url: null),
        headers: null,
      );
      await handler.stopRadio();
      await handler.playRadioStream(
        stationId: 'a',
        stationName: 'Station A',
        streamUrl: 'https://stream.example.invalid/a',
      );
      player.hang.add('stop');
      await expectLater(
        handler.playRadioStream(
          stationId: 'b',
          stationName: 'Station B',
          streamUrl: 'https://stream.example.invalid/b',
        ),
        throwsA(isA<PlaybackLoadTimeoutException>()),
      );
      expect(rebuilt, hasLength(1));
      final radio = handler.collectPlaybackDiagnostics()['radio']! as Map;
      expect(radio['nowPlayingTitle'], 'Song');
      expect(radio['metadataSource'], 'icy');
      player.hang.clear();
    });
  });

  group('radio artwork publication', () {
    const ownArt = 'https://music.example.org:4533/rest/getCoverArt?id=r1';
    const externalArt = 'https://art.example.invalid/cover.jpg';

    Future<NavisAudioHandler> radioHandler(
      bool Function(Uri) readRadioArtworkAllowed, {
      String? icyTitle,
      String streamUrl = 'https://example.invalid/stream',
    }) async {
      final directory = Directory.systemTemp.createTempSync('radio-art-');
      final (handler, player, database) = await createHandler(
        directory,
        0,
        readRadioArtworkAllowed: readRadioArtworkAllowed,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        directory.deleteSync(recursive: true);
      });
      if (icyTitle != null) {
        player.currentIcyMetadata = IcyMetadata(
          info: IcyInfo(title: icyTitle, url: null),
          headers: null,
        );
      }
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: streamUrl,
      );
      return handler;
    }

    test(
      'radio diagnostics report host only and no metadata before reception',
      () async {
        final handler = await radioHandler(
          (_) => true,
          streamUrl: 'https://fixture:placeholder@stream.example.invalid:8443/live?token=placeholder',
        );
        expect(handler.collectPlaybackDiagnostics()['radio'], {
          'stationId': 'fixture',
          'stationName': 'Fixture',
          'streamHost': 'stream.example.invalid',
          'metadataSource': 'none',
          'nowPlayingTitle': null,
          'nowPlayingArtist': null,
          'nowPlayingArtHost': null,
          'nowPlayingArtHash': null,
          'publishedArtHost': null,
          'publishedArtHash': null,
        });
        await handler.stopRadio();
        expect(handler.collectPlaybackDiagnostics()['radio'], isNull);
      },
    );

    test('radio artwork diagnostics redact credentials and retain identity', () async {
      final handler = await radioHandler((_) => true);
      const art =
          'https://fixture:placeholder@art.example.invalid:8443/private/cover'
          '?u=fixture&t=placeholder&s=placeholder&p=placeholder&token=placeholder#private';
      handler.updateRadioMetadata(artUrl: art);
      final radio = handler.collectPlaybackDiagnostics()['radio']! as Map;
      expect(radio, isNot(contains('nowPlayingArtUrl')));
      expect(radio, isNot(contains('publishedArtUri')));
      expect(radio['nowPlayingArtHost'], 'art.example.invalid');
      expect(radio['publishedArtHost'], 'art.example.invalid');
      final identity = radio['nowPlayingArtHash'];
      expect(identity, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(radio['publishedArtHash'], identity);
      expect(handler.collectPlaybackDiagnostics()['radio'], radio);
      expect(radio.toString(), isNot(contains('placeholder')));
      expect(radio.toString(), isNot(contains('/private')));
      handler.updateRadioMetadata(artUrl: '$art-changed');
      final changed = handler.collectPlaybackDiagnostics()['radio']! as Map;
      expect(changed['nowPlayingArtHash'], isNot(identity));
      expect(changed['publishedArtHash'], changed['nowPlayingArtHash']);
    });

    test(
      'radio diagnostics identify ICY metadata and published artwork',
      () async {
        var allowed = true;
        final handler = await radioHandler(
          (_) => allowed,
          icyTitle: 'ICY Artist - ICY Song',
        );
        var radio =
            handler.collectPlaybackDiagnostics()['radio']!
                as Map<String, Object?>;
        expect(radio['metadataSource'], 'icy');
        expect(radio['nowPlayingTitle'], 'ICY Song');
        expect(radio['nowPlayingArtist'], 'ICY Artist');
        handler.updateRadioMetadata(artUrl: externalArt);
        radio =
            handler.collectPlaybackDiagnostics()['radio']!
                as Map<String, Object?>;
        expect(radio['nowPlayingArtHost'], 'art.example.invalid');
        expect(radio['nowPlayingArtHash'], '006b2f45dd4bfe45');
        expect(radio['publishedArtHash'], radio['nowPlayingArtHash']);
        allowed = false;
        handler.updateRadioMetadata();
        radio =
            handler.collectPlaybackDiagnostics()['radio']!
                as Map<String, Object?>;
        expect(radio['nowPlayingArtHash'], isNull);
        expect(radio['publishedArtHash'], isNull);
        expect(radio['metadataSource'], 'icy');
        expect(handler.mediaItem.value!.title, 'ICY Song');
        expect(handler.mediaItem.value!.artist, 'ICY Artist');
      },
    );

    test(
      'publishes the original http(s) URL while the policy allows it',
      () async {
        final handler = await radioHandler((_) => true);
        handler.updateRadioMetadata(title: 'Track', artUrl: externalArt);
        expect(handler.mediaItem.value!.artUri, Uri.parse(externalArt));
        expect(handler.mediaItem.value!.artUri!.scheme, 'https');
        expect(handler.snapshot.radioStation!.nowPlayingArtUrl, externalArt);
      },
    );

    test('a refused URL is never published and refused art is cleared', () async {
      var allowed = true;
      final handler = await radioHandler((_) => allowed);
      handler.updateRadioMetadata(title: 'Track', artUrl: externalArt);
      expect(handler.mediaItem.value!.artUri, isNotNull);

      // The policy changes while the station plays: the next update clears it.
      allowed = false;
      handler.updateRadioMetadata();
      expect(handler.mediaItem.value!.artUri, isNull);
      expect(handler.snapshot.radioStation!.nowPlayingArtUrl, isNull);

      handler.updateRadioMetadata(
        title: 'Next',
        artUrl: 'https://art.example.invalid/next.jpg',
      );
      expect(handler.mediaItem.value!.artUri, isNull);

      allowed = true;
      handler.updateRadioMetadata(
        title: 'Allowed',
        artUrl: 'https://art.example.invalid/allowed.jpg',
      );
      expect(
        handler.mediaItem.value!.artUri,
        Uri.parse('https://art.example.invalid/allowed.jpg'),
      );
    });

    test(
      'own-server art survives Online services off, external art does not',
      () async {
        var policy = const IntegrationPolicy();
        final handler = await radioHandler(
          (uri) => integrationAllowsRadioArtworkUri(
            policy,
            uri,
            serverHost: 'music.example.org',
          ),
        );
        handler.updateRadioMetadata(title: 'Own', artUrl: ownArt);
        expect(handler.mediaItem.value!.artUri, Uri.parse(ownArt));

        policy = const IntegrationPolicy(masterEnabled: false);
        handler.updateRadioMetadata();
        expect(handler.mediaItem.value!.artUri, Uri.parse(ownArt));

        handler.updateRadioMetadata(title: 'Away', artUrl: externalArt);
        expect(handler.mediaItem.value!.artUri, isNull);

        policy = const IntegrationPolicy(disabledKeys: {'radio.nowPlaying'});
        handler.updateRadioMetadata(title: 'Radio off', artUrl: externalArt);
        expect(handler.mediaItem.value!.artUri, isNull);
        handler.updateRadioMetadata(title: 'Own again', artUrl: ownArt);
        expect(handler.mediaItem.value!.artUri, Uri.parse(ownArt));
      },
    );

    test(
      'a non-http(s) URL is never published, even if a reader allows it',
      () async {
        final handler = await radioHandler((_) => true);
        for (final url in [
          'file:///data/user/0/app/cache/cover.jpg',
          'content://app.artwork/cover/x',
          'cover.jpg',
        ]) {
          handler.updateRadioMetadata(title: url, artUrl: url);
          expect(handler.mediaItem.value!.artUri, isNull, reason: url);
          expect(handler.snapshot.radioStation!.nowPlayingArtUrl, isNull);
        }
      },
    );

    test('without a readable policy no art is published', () async {
      final directory = Directory.systemTemp.createTempSync('radio-art-');
      final (handler, _, database) = await createHandler(directory, 0);
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
      handler.updateRadioMetadata(title: 'Track', artUrl: externalArt);
      expect(handler.mediaItem.value!.artUri, isNull);
    });
  });

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

  for (final input in ['ids', 'expanded rows', 'canonical rows']) {
    for (final duplicate in [false, true]) {
      test('missing prefix preserves the selected occurrence '
          '($input, duplicate=$duplicate)', () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-missing-',
        );
        final (handler, player, database) = await createHandler(directory, 2);
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final rows = await database.libraryDao.getSongsByIds([
          'song-0',
          'song-1',
        ]);
        final requested = [
          'missing',
          'song-0',
          'song-1',
          if (duplicate) ...['song-0', 'song-1'],
        ];
        final startIndex = duplicate ? 3 : 1;
        if (input == 'ids') {
          await handler.replaceQueue(
            requested,
            startIndex: startIndex,
            expandMatchFlows: false,
          );
        } else {
          final first = input == 'canonical rows'
              ? rows.first.copyWith(id: 'retired-0')
              : rows.first;
          if (input == 'canonical rows') {
            await handler.applySongIdentityAliases({'retired-0': 'song-0'});
          }
          await handler.replaceQueueWithData(
            [
              rows.first.copyWith(id: 'missing'),
              first,
              rows.last,
              if (duplicate) ...[first, rows.last],
            ],
            startIndex: startIndex,
            expandMatchFlows: input == 'expanded rows',
          );
        }

        expect(handler.snapshot.currentSongId, 'song-0');
        expect(handler.snapshot.currentIndex, duplicate ? 2 : 0);
        expect(player.index, duplicate ? 2 : 0);
        expect(handler.snapshot.queueSongIds, requested.skip(1));
        await handler.debugFlushQueuePersistence();
        expect(
          (await database.playQueueDao.getQueueState())!.currentIndex,
          duplicate ? 2 : 0,
        );
      });
    }
  }

  group('queue replacement input contracts', () {
    for (final newerReplacement in [false, true]) {
      test('cancelled empty ID resolution preserves the newer queue command '
          '(replacement=$newerReplacement)', () async {
        final directory = await Directory.systemTemp.createTemp('navis-empty-');
        late _GatedLibraryDao dao;
        final (handler, player, database) = await createHandler(
          directory,
          3,
          createLibraryDao: (database) => dao = _GatedLibraryDao(database),
        );
        addTearDown(() async {
          if (!dao.release.isCompleted) dao.release.complete();
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final ids = ['song-0', 'song-1', 'song-2'];
        await handler.replaceQueue(ids, expandMatchFlows: false);
        final obsolete = handler.replaceQueue([
          'missing',
        ], expandMatchFlows: false);
        await dao.entered.future;
        final newer = newerReplacement
            ? handler.replaceQueue(ids, startIndex: 1, expandMatchFlows: false)
            : handler.skipToNext();
        final settled = handler.snapshotStream.firstWhere(
          (snapshot) =>
              !snapshot.isLoading && snapshot.pendingQueueIndex == null,
        );
        dao.release.complete();
        await obsolete;
        await newer;
        await settled;
        await handler.debugFlushQueuePersistence();

        expect(handler.snapshot.queueSongIds, ids);
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(player.sourceIds, ids);
        expect(
          (await database.playQueueDao.getQueueItems()).map((song) => song.id),
          ids,
        );
        expect(await database.playQueueDao.getQueueState(), isNotNull);
      });
    }

    for (final suppliedRows in [false, true]) {
      test('superseded empty clear keeps the saved queue across native awaits '
          '(rows=$suppliedRows)', () async {
        final directory = await Directory.systemTemp.createTemp('navis-clear-');
        final (handler, player, database) = await createHandler(directory, 3);
        final stopping = Completer<void>();
        final releaseStop = Completer<void>();
        final loading = Completer<void>();
        final releaseLoad = Completer<void>();
        addTearDown(() async {
          if (!releaseStop.isCompleted) releaseStop.complete();
          if (!releaseLoad.isCompleted) releaseLoad.complete();
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final ids = ['song-0', 'song-1', 'song-2'];
        await handler.replaceQueue(ids, expandMatchFlows: false);
        player
          ..stopEntered = stopping
          ..stopGate = releaseStop;
        final obsolete = suppliedRows
            ? handler.replaceQueueWithData([])
            : handler.replaceQueue(['missing'], expandMatchFlows: false);
        await stopping.future;
        player
          ..gateNonEmptyLoadsOnly = true
          ..loadEntered = loading
          ..loadGate = releaseLoad;
        final newer = handler.replaceQueue(
          ids,
          startIndex: 1,
          expandMatchFlows: false,
        );
        releaseStop.complete();
        await obsolete;
        await loading.future;
        expect(
          (await database.playQueueDao.getQueueItems()).map((song) => song.id),
          ids,
        );
        releaseLoad.complete();
        await newer;
        expect(handler.snapshot.queueSongIds, ids);
        expect(handler.snapshot.currentSongId, 'song-1');
      });
    }

    for (final suppliedRows in [false, true]) {
      test('admits and saves the logical selection before fill '
          '(rows=$suppliedRows)', () async {
        final directory = await Directory.systemTemp.createTemp('navis-admit-');
        final (handler, player, database) = await createHandler(directory, 4);
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final ids = List.generate(4, (i) => 'song-$i');
        final rows = await database.libraryDao.getSongsByIds(ids);
        final loaded = Completer<void>();
        final releaseLoad = Completer<void>();
        final filling = Completer<void>();
        final releaseFill = Completer<void>();
        player
          ..loadEntered = loaded
          ..loadGate = releaseLoad
          ..appendEntered = filling
          ..appendGate = releaseFill;
        final replacement = suppliedRows
            ? handler.replaceQueueWithData(
                rows,
                startIndex: 1,
                expandMatchFlows: false,
              )
            : handler.replaceQueue(ids, startIndex: 1, expandMatchFlows: false);
        expect(handler.snapshot.isLoading, isTrue);
        expect(handler.snapshot.queueSongIds, ids);
        expect(handler.snapshot.pendingQueueIndex, 1);
        await loaded.future;
        await handler.pause();
        releaseLoad.complete();
        await filling.future;
        final state = (await database.playQueueDao.getQueueState())!;
        expect(state.currentIndex, 1);
        expect(
          (await database.playQueueDao.getQueueItems()).map((s) => s.id),
          ids,
        );
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(handler.snapshot.hasPendingLogicalQueue, isTrue);
        expect(player.playing, isFalse);
        releaseFill.complete();
        await replacement;
        expect(handler.snapshot.queueSongIds, ids);
        expect(handler.snapshot.currentIndex, 1);
        expect(handler.snapshot.isLoading, isFalse);
        expect(player.playing, isFalse);

        if (suppliedRows) {
          await handler.replaceQueueWithData([]);
        } else {
          await handler.replaceQueue([]);
        }
        expect(handler.snapshot.queueSongIds, isEmpty);
        expect(handler.snapshot.isLoading, isFalse);
        expect(await database.playQueueDao.getQueueItems(), isEmpty);
      });

      test('timeout recovery keeps the admitted shuffle order and pause '
          '(rows=$suppliedRows)', () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-recover-',
        );
        final rebuilt = <_ControllableAudioPlayer>[];
        final (handler, player, database) = await createHandler(
          directory,
          5,
          rebuiltPlayers: rebuilt,
          timeouts: const NavisPlaybackTimeouts(
            load: Duration(milliseconds: 300),
            remoteLoad: Duration(milliseconds: 300),
            reset: Duration(milliseconds: 100),
            control: Duration(milliseconds: 100),
          ),
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final ids = List.generate(5, (i) => 'song-$i');
        final rows = [
          for (final row in await database.libraryDao.getSongsByIds(ids))
            row.copyWith(title: 'Supplied ${row.id}', isExternal: true),
        ];
        await handler.applySongIdentityAliases({'song-3': 'song-4'});
        await handler.setShuffleMode(AudioServiceShuffleMode.all);
        final inputIds = suppliedRows
            ? ids
            : ['song-0', 'song-1', 'song-2', 'song-4', 'song-4'];
        final expected = shuffledFromStart(inputIds, 2, Random(7));
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..loadGate = gate
          ..loadEntered = entered;
        final replacement = suppliedRows
            ? handler.replaceQueueWithData(rows, startIndex: 2)
            : handler.replaceQueue(ids, startIndex: 2, expandMatchFlows: false);
        await entered.future;
        await handler.pause();
        await replacement;
        if (handler.snapshot.isLoading || handler.snapshot.currentIndex != 1) {
          await handler.snapshotStream.firstWhere(
            (snapshot) => !snapshot.isLoading && snapshot.currentIndex == 1,
          );
        }
        expect(handler.snapshot.queueSongIds, expected);
        expect(handler.snapshot.currentSongId, expected[1]);
        expect(handler.snapshot.playing, isFalse);
        expect(rebuilt.last.sourceIds, expected);
        if (suppliedRows) {
          expect(handler.queue.value.map((item) => item.title), [
            for (final id in expected) 'Supplied $id',
          ]);
        }
        gate.complete();
        await handler.setShuffleMode(AudioServiceShuffleMode.none);
        expect(handler.snapshot.queueSongIds, inputIds);
        expect(handler.snapshot.currentSongId, expected[1]);
      });
    }

    for (final duplicate in [false, true]) {
      test('timeout advances beyond the resolved missing selection '
          '(duplicate=$duplicate)', () async {
        final directory = await Directory.systemTemp.createTemp('navis-next-');
        final rebuilt = <_ControllableAudioPlayer>[];
        final (handler, player, database) = await createHandler(
          directory,
          3,
          rebuiltPlayers: rebuilt,
          timeouts: const NavisPlaybackTimeouts(
            load: Duration(milliseconds: 100),
            reset: Duration(milliseconds: 100),
            control: Duration(milliseconds: 100),
          ),
        );
        final entered = Completer<void>();
        final releaseLoad = Completer<void>();
        addTearDown(() async {
          if (!releaseLoad.isCompleted) releaseLoad.complete();
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final requested = [
          'song-0',
          if (duplicate) 'song-1',
          'missing',
          'song-1',
          'song-2',
        ];
        final expected = requested.where((id) => id != 'missing').toList();
        player
          ..loadEntered = entered
          ..loadGate = releaseLoad;
        final replacement = handler.replaceQueue(
          requested,
          startIndex: duplicate ? 2 : 1,
          expandMatchFlows: false,
        );
        await entered.future;
        expect(player.attemptedSongId, 'song-1');
        await handler.pause();
        final recovered = handler.snapshotStream.firstWhere(
          (snapshot) => !snapshot.isLoading,
        );
        await replacement;
        await recovered;
        if (handler.snapshot.isLoading) {
          await handler.snapshotStream.firstWhere(
            (snapshot) => !snapshot.isLoading,
          );
        }
        await handler.debugFlushQueuePersistence();

        expect(handler.snapshot.currentSongId, 'song-2');
        expect(handler.snapshot.currentIndex, expected.length - 1);
        expect(handler.snapshot.queueSongIds, expected);
        expect(handler.snapshot.playing, isFalse);
        expect(rebuilt.single.sourceIds, expected);
        expect(
          (await database.playQueueDao.getQueueItems()).map((song) => song.id),
          expected,
        );
        expect(
          (await database.playQueueDao.getQueueState())!.currentIndex,
          expected.length - 1,
        );
      });
    }

    for (final input in [
      'ids',
      'expanded rows',
      'canonical rows',
      'exact rows',
    ]) {
      test('local row resolution preserves its read policy ($input)', () async {
        final directory = await Directory.systemTemp.createTemp('navis-rows-');
        final (handler, _, database) = await createHandler(
          directory,
          3,
          matchFlow: true,
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final flow = await database.matchFlowDao.createFlow();
        await database.matchFlowDao.addSong(flow, 'song-0');
        await database.matchFlowDao.addSong(flow, 'song-1');
        final rows = await database.libraryDao.getSongsByIds([
          'song-0',
          'song-2',
        ]);
        final supplied = [
          for (final row in rows) row.copyWith(title: 'Supplied'),
        ];
        if (input == 'ids') {
          await handler.applySongIdentityAliases({'retired-0': 'song-0'});
          await handler.replaceQueue(['retired-0', 'song-2'], startIndex: 1);
        } else {
          if (input == 'canonical rows') {
            await handler.applySongIdentityAliases({'retired-0': 'song-0'});
            supplied[0] = supplied[0].copyWith(id: 'retired-0');
          }
          await handler.replaceQueueWithData(
            supplied,
            startIndex: 1,
            expandMatchFlows: input == 'expanded rows',
          );
        }
        final expands = input == 'ids' || input == 'expanded rows';
        expect(
          handler.snapshot.queueSongIds,
          expands ? ['song-0', 'song-1', 'song-2'] : ['song-0', 'song-2'],
        );
        expect(handler.snapshot.currentIndex, expands ? 2 : 1);
        expect(handler.snapshot.currentSongId, 'song-2');
        expect(
          handler.currentMediaItem!.title,
          input == 'exact rows' ? 'Supplied' : 'Song 2',
        );
      });
    }

    test(
      'mixed rows bypass expansion and retain remote and retired local rows',
      () async {
        final directory = await Directory.systemTemp.createTemp('navis-mixed-');
        final (handler, _, database) = await createHandler(
          directory,
          3,
          matchFlow: true,
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final flow = await database.matchFlowDao.createFlow();
        await database.matchFlowDao.addSong(flow, 'song-0');
        await database.matchFlowDao.addSong(flow, 'song-2');
        final rows = await database.libraryDao.getSongsByIds([
          'song-0',
          'song-1',
        ]);
        await handler.applySongIdentityAliases({
          'song-0': 'song-2',
          'song-1': 'song-2',
        });
        await handler.replaceQueueWithData([
          rows[0].copyWith(isExternal: true, title: 'Remote exact'),
          rows[1].copyWith(title: 'Local exact'),
        ]);
        expect(handler.snapshot.queueSongIds, ['song-0', 'song-1']);
        expect(handler.queue.value.map((item) => item.title), [
          'Remote exact',
          'Local exact',
        ]);
        expect(handler.snapshot.currentSongId, 'song-0');
      },
    );
  });

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

    test(
      'OS Next is unavailable at the logical end after releasing history',
      () async {
        final (handler, player, _) = await windowed(60);
        await handler.replaceQueue(ids(60), expandMatchFlows: false);
        await handler.playFromIndex(59);
        await until(
          () =>
              !handler.snapshot.isLoading &&
              handler.snapshot.currentIndex == 59,
        );
        expect(
          handler.collectPlaybackDiagnostics()['deferredHeadLength'],
          greaterThan(0),
        );
        expect(handler.collectPlaybackDiagnostics()['deferredLength'], 0);
        expect(player.index, lessThan(59));
        expect(handler.playbackState.value.queueIndex, player.index);
        expect(
          handler.playbackState.value.controls.map((control) => control.action),
          isNot(contains(MediaAction.skipToNext)),
        );
        expect(
          handler.playbackState.value.systemActions,
          isNot(contains(MediaAction.skipToNext)),
        );
        expect(
          handler.playbackState.value.systemActions,
          contains(MediaAction.skipToPrevious),
        );
      },
    );

    test(
      'system projection composes its window offset with the deferred head',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-system-',
        );
        final (handler, player, database) = await createHandler(
          directory,
          300,
          queueWindow: const NavisQueueWindow(
            deferThreshold: 16,
            ahead: 40,
            behind: 100,
          ),
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        await handler.replaceQueue(
          ids(300),
          startIndex: 180,
          expandMatchFlows: false,
        );
        final system = RealTimeProjectionAudioHandler(handler);
        await until(() => system.queue.valueOrNull?.first.id == 'song-160');
        expect(handler.queue.value.first.id, 'song-80');
        expect(system.queue.value.first.id, 'song-160');

        await system.removeQueueItem(system.queue.value[1]);
        expect(handler.snapshot.queueSongIds, ids(300)..remove('song-161'));
        expect(player.sourceIds, isNot(contains('song-161')));
        await system.skipToQueueItem(0);
        await until(
          () =>
              handler.snapshot.currentIndex == 160 &&
              !handler.snapshot.isLoading,
        );

        expect(handler.snapshot.currentIndex, 160);
        expect(player.sourceIds[player.index!], 'song-160');
      },
    );

    test('system insert starts an empty queue', () async {
      final (handler, player, _) = await windowed(2);

      await handler.insertQueueItem(
        0,
        const MediaItem(id: 'song-1', title: 'Song 1'),
      );

      expect(handler.snapshot.queueSongIds, ['song-1']);
      expect(player.sourceIds, ['song-1']);
    });

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

      for (final projected in [false, true]) {
        test(
          'system skip selects the published occurrence with a deferred head '
          '(projected=$projected)',
          () async {
            final (handler, player, _) = await trimmed();
            final system = projected
                ? RealTimeProjectionAudioHandler(handler)
                : handler;
            await until(() => system.queue.valueOrNull?.isNotEmpty ?? false);
            final selected = system.queue.value.first.id;
            expect(selected, 'song-6');

            await system.skipToQueueItem(0);
            await until(
              () =>
                  handler.snapshot.currentSongId == selected &&
                  !handler.snapshot.isLoading,
            );

            expect(handler.snapshot.currentSongId, selected);
            expect(handler.snapshot.currentIndex, 6);
            expect(player.sourceIds[player.index!], selected);
          },
        );

        test(
          'system remove edits the published occurrence with a deferred head '
          '(projected=$projected)',
          () async {
            final (handler, player, _) = await trimmed();
            final system = projected
                ? RealTimeProjectionAudioHandler(handler)
                : handler;
            await until(() => system.queue.valueOrNull?.isNotEmpty ?? false);
            final removed = system.queue.value.first;
            expect(removed.id, 'song-6');

            await system.removeQueueItem(removed);

            expect(handler.snapshot.queueSongIds, ids(60)..remove('song-6'));
            expect(handler.snapshot.currentSongId, 'song-10');
            expect(player.sourceIds, isNot(contains('song-6')));
          },
        );
      }

      for (final projected in [false, true]) {
        test('system remove-at edits the native occurrence '
            '(projected=$projected)', () async {
          final (handler, player, _) = await trimmed();
          final system = projected
              ? RealTimeProjectionAudioHandler(handler)
              : handler;
          await until(() => system.queue.valueOrNull?.isNotEmpty ?? false);

          await system.removeQueueItemAt(0);

          expect(handler.snapshot.queueSongIds, ids(60)..remove('song-6'));
          expect(handler.snapshot.currentSongId, 'song-10');
          expect(player.sourceIds, isNot(contains('song-6')));
        });

        test('system insert edits the native position '
            '(projected=$projected)', () async {
          final (handler, player, _) = await trimmed();
          final system = projected
              ? RealTimeProjectionAudioHandler(handler)
              : handler;
          await until(() => system.queue.valueOrNull?.isNotEmpty ?? false);

          await system.insertQueueItem(
            1,
            const MediaItem(id: 'song-0', title: 'Song 0'),
          );

          expect(handler.snapshot.queueSongIds, ids(60)..insert(7, 'song-0'));
          expect(handler.snapshot.currentSongId, 'song-10');
          expect(player.sourceIds.take(3), ['song-6', 'song-0', 'song-7']);
        });
      }

      test('retaining a singleton seed clears deferred played songs', () async {
        final (handler, player, database) = await trimmed();
        for (var index = 59; index >= 6; index--) {
          if (index != 10) await handler.removeAt(index);
        }
        expect(head(handler), 6);
        expect(handler.queue.value.map((item) => item.id), ['song-10']);
        expect(handler.collectPlaybackDiagnostics()['deferredLength'], 0);
        expect(player.index, 0);
        player.simulatedPosition = const Duration(seconds: 15);
        final seeks = player.seekCalls;

        await handler.retainCurrentSongAsQueue('song-10');

        expect(handler.snapshot.queueSongIds, ['song-10']);
        expect(head(handler), 0);
        expect(handler.snapshot.currentIndex, 0);
        expect(player.sourceIds, ['song-10']);
        expect(player.simulatedPosition, const Duration(seconds: 15));
        expect(player.seekCalls, seeks);
        expect(player.isPlaying, isTrue);
        expect(
          (await database.playQueueDao.getQueueItems()).map((song) => song.id),
          ['song-10'],
        );
      });

      for (final allUnavailable in [true, false]) {
        test('offline backward jump retains temporarily unavailable history '
            '(allUnavailable=$allUnavailable)', () async {
          final (handler, player, database) = await trimmed();
          final dropped = <QueueSongsDropped>[];
          final subscription = handler.droppedSongsStream.listen(dropped.add);
          addTearDown(subscription.cancel);
          await database.cacheDao.deleteCachedTracksBySongIds(
            allUnavailable ? ids(6) : ['song-2'],
          );

          await handler.playFromIndex(4);
          await until(() => !handler.snapshot.isLoading);

          expect(handler.snapshot.queueSongIds, ids(60));
          expect(dropped, isEmpty);
          expect(head(handler), allUnavailable ? 6 : 3);
          expect(
            handler.snapshot.currentSongId,
            allUnavailable ? 'song-10' : 'song-4',
          );
          expect(
            player.sourceIds[player.index!],
            allUnavailable ? 'song-10' : 'song-4',
          );
          await handler.debugFlushQueuePersistence();
          expect(
            (await database.playQueueDao.getQueueItems()).map(
              (song) => song.id,
            ),
            ids(60),
          );
        });
      }

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
      'hung inactive deck prewarm expires without stopping active playback',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-fade-hang-',
        );
        final (handler, player, database) = await createHandler(
          directory,
          3,
          crossfade: true,
          timeouts: const NavisPlaybackTimeouts(
            load: Duration(milliseconds: 80),
          ),
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        final deck = handler.debugInactiveDeck! as _ControllableAudioPlayer;
        deck.hang.add('setAudioSources');
        final started = handler.debugStartCrossfade();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(fade(handler)['active'], isFalse);
        expect(player.playing, isTrue);
        expect(handler.debugActivePlayer, same(player));
        expect(handler.snapshot.queueSongIds, ids(3));
        expect(fade(handler)['phases'], containsPair('prewarm_failed', 1));
        expect(handler.debugInactiveDeck, isNot(same(deck)));
        await started;
        player.moveTo(1);
        await Future<void>.delayed(Duration.zero);
        await handler.debugStartCrossfade();
        expect(fade(handler)['active'], isTrue);
      },
    );

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

    for (final command in ['pause', 'selection']) {
      test('failed remote recovery yields to a newer $command', () async {
        final (handler, player, _) = await recovering(5);
        await start(handler, 5);
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..loadGate = gate
          ..loadEntered = entered
          ..blockedLoadError = StateError('retry failed');
        final recovery = handler.debugRecoverCurrentSong();
        await entered.future;
        final newerCommand = command == 'pause'
            ? handler.pause()
            : handler.playFromIndex(4);
        if (command == 'pause') await newerCommand;
        gate.complete();
        await Future.wait([recovery, newerCommand]);
        await until(() => !handler.snapshot.isLoading);
        expect(
          handler.snapshot.currentSongId,
          command == 'pause' ? 'song-1' : 'song-4',
        );
        expect(player.playing, command != 'pause');
      });
    }

    test('failed recovery of a paused song advances without playing', () async {
      final (handler, player, _) = await recovering(5);
      await start(handler, 5);
      await handler.pause();
      player.failLoadSongId = 'song-1';
      await handler.debugRecoverCurrentSong();
      await until(() => !handler.snapshot.isLoading);
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(player.playing, isFalse);
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

  for (final (count, lateFailure) in [(3, false), (3, true), (70, false)]) {
    test('timed-out saved restore cannot change a newer selection '
        '(count=$count, lateFailure=$lateFailure)', () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-restore-timeout-',
      );
      final gate = Completer<void>();
      final entered = Completer<void>();
      final initialPlayer = _ControllableAudioPlayer()
        ..loadGate = gate
        ..loadEntered = entered
        ..keepStreamsAfterDispose = true
        ..blockedLoadError = lateFailure
            ? StateError('late restore failure')
            : null;
      final rebuilt = <_ControllableAudioPlayer>[];
      final (handler, _, database) = await createHandler(
        directory,
        count,
        savedQueueIndex: 0,
        initialPlayer: initialPlayer,
        waitForReady: false,
        rebuiltPlayers: rebuilt,
      );
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        await pumpEventQueue();
        await handler.disposeHandler();
        initialPlayer.keepStreamsAfterDispose = false;
        await initialPlayer.dispose();
        await database.close();
        await directory.delete(recursive: true);
      });
      await entered.future.timeout(const Duration(seconds: 5));
      await handler.waitUntilReady().timeout(const Duration(seconds: 15));
      expect(
        handler.collectPlaybackDiagnostics()['queueRestoreOutcome'],
        'timeout',
      );
      expect((await database.playQueueDao.getQueueItems()).length, count);

      await handler.replaceQueue(['song-2'], expandMatchFlows: false);
      final selectedPlayer =
          handler.debugActivePlayer as _ControllableAudioPlayer;
      expect(selectedPlayer.isPlaying, isTrue);
      // A two-phase restore also has a native load deadline. Its later
      // timeout must not rebuild the player that now owns the selection.
      if (count > 64) {
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      gate.complete();
      await pumpEventQueue(times: 50);

      expect(identical(handler.debugActivePlayer, selectedPlayer), isTrue);
      expect(selectedPlayer.isPlaying, isTrue);
      expect(selectedPlayer.sourceIds, ['song-2']);
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(handler.mediaItem.value?.id, 'song-2');
      expect(handler.snapshot.queueSongIds, ['song-2']);
      expect(
        handler.collectPlaybackDiagnostics()['queueRestoreOutcome'],
        'timeout',
      );
      await handler.debugFlushQueuePersistence();
      expect(
        (await database.playQueueDao.getQueueItems()).map((song) => song.id),
        ['song-2'],
      );
    });
  }

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
