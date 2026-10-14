import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:rxdart/rxdart.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:navis/src/features/player/domain/playback_adjustments.dart';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:drift/drift.dart' show Value;
import 'package:navis/src/features/auto/data/auto_media_id.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/features/player/data/radio_metadata_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/models/models.dart' as models;
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/daos/history_dao.dart';
import 'package:navis/src/database/daos/play_queue_dao.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/cache/data/rolling_cache_manager.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/integrations/domain/integration_artwork.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/player/data/listenbrainz_feedback_service.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/recommendation_service.dart';
import 'package:navis/src/features/player/presentation/personal_radio_notifier.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/data/navis_shuffle_order.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/data/real_time_projection_audio_handler.dart';
import 'package:navis/src/features/player/data/scrobble_service.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/domain/streaming_quality.dart';

import '../../../../helpers/test_database.dart';
import '../../../../helpers/library_sync_fakes.dart';
import '../../../../helpers/library_sync_plan.dart';

class _MockRecommendationService extends Mock implements RecommendationService;

class _MockRadioDio extends Mock implements Dio;

class _MockSystemArtCache extends Mock implements BaseCacheManager;

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

class _GatedHistoryDao extends HistoryDao {
  new(super.attachedDatabase);

  final entered = Completer<void>();
  final release = Completer<void>();
  int lookups = 0;

  @override
  Stream<List<SongsTableData>> watchRecentlyPlayedSongs({
    int limit = 20,
  }) async* {
    lookups++;
    final lookup = lookups;
    if (!entered.isCompleted) entered.complete();
    await release.future;
    yield await attachedDatabase.libraryDao.getSongsByIds([
      if (lookup == 1) 'song-0' else 'song-1',
    ]);
  }
}

class _GatedPlayQueueDao extends PlayQueueDao {
  new(super.attachedDatabase);
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<PlayQueueTableData?> getQueueState() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return super.getQueueState();
  }
}

class _GatedSourceResolver extends Fake implements PlaybackSourceResolver {
  new(this.delegate);
  final PlaybackSourceResolver delegate;
  String? blockedSongId;
  StateError? failure;
  Completer<void>? entered;
  Completer<void>? release;

  @override
  Uri? resolveArtUri(SongsTableData song) => delegate.resolveArtUri(song);

  @override
  Future<ResolvedPlaybackSource> resolveForSong(
    SongsTableData song, {
    bool preferLockCaching = true,
    bool allowStreaming = true,
  }) async {
    if (song.id == blockedSongId) {
      if (entered case final signal? when !signal.isCompleted) {
        signal.complete();
      }
      await release?.future;
      if (failure case final error?) throw error;
    }
    return await delegate.resolveForSong(
      song,
      preferLockCaching: preferLockCaching,
      allowStreaming: allowStreaming,
    );
  }
}

class _NoopScrobbleService extends Fake implements ScrobbleService {
  final nowPlaying = <String>[];
  final submissions = <String>[];
  final nowPlayingSessions = <String>[];
  final submissionSessions = <String>[];
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
  }) async {
    nowPlaying.add(songId);
    nowPlayingSessions.add(sessionKey);
  }

  @override
  Future<void> enqueueSubmission({
    required String songId,
    required String sessionKey,
    ScrobbleTrackPayload? track,
  }) async {
    submissions.add(songId);
    submissionSessions.add(sessionKey);
  }
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

class _ProbeHeaders extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
}

class _ProbeResponse extends Fake implements HttpClientResponse {
  @override
  Future<List<int>> firstWhere(
    bool Function(List<int>) test, {
    List<int> Function()? orElse,
  }) async => <int>[1, 2];
}

class _ProbeRequest extends Fake implements HttpClientRequest {
  @override
  HttpHeaders get headers => _ProbeHeaders();
  @override
  Future<HttpClientResponse> close() async => _ProbeResponse();
}

class _ProbeClient extends Fake implements HttpClient {
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async => _ProbeRequest();
  @override
  void close({bool force = false}) {}
}

class _TestAudioSession extends Fake implements AudioSession {
  final interruptions = StreamController<AudioInterruptionEvent>.broadcast();
  final noisy = StreamController<void>.broadcast();

  @override
  Stream<AudioInterruptionEvent> get interruptionEventStream =>
      interruptions.stream;

  @override
  Stream<void> get becomingNoisyEventStream => noisy.stream;

  final activations = <bool>[];

  @override
  Future<bool> setActive(
    bool active, {
    AVAudioSessionSetActiveOptions? avAudioSessionSetActiveOptions,
    AndroidAudioFocusGainType? androidAudioFocusGainType,
    AndroidAudioAttributes? androidAudioAttributes,
    bool? androidWillPauseWhenDucked,
    AudioSessionConfiguration fallbackConfiguration =
        const AudioSessionConfiguration.music(),
  }) async {
    activations.add(active);
    return true;
  }

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
  bool disposed = false;

  String? get audibleSongId =>
      isPlaying && !disposed && state != ProcessingState.idle && index != null
      ? sourceIds.elementAtOrNull(index!)
      : null;
  Duration _simulatedPosition = Duration.zero;
  DateTime _positionUpdated = DateTime.now();
  bool simulateProgress = false;
  _HandlerPositionPlayer? positionPlayer;

  void emitPlayerEvent() {
    if (positionPlayer == null) return;
    positionPlayer!.events.add(
      PlayerEvent(playing: playing, playbackEvent: playbackEvent),
    );
    _events.add(playbackEvent);
  }

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
  int sourceLoads = 0;
  int seekCalls = 0;
  int stopCalls = 0;
  int? index;
  final List<double> appliedVolumes = [];
  double appliedSpeed = 1;
  double appliedPitch = 1;
  bool failPitchOnce = false;
  bool failPlay = false;
  bool ignorePlay = false;
  bool playRequested = false;
  bool failVolume = false;
  Completer<void>? volumeGate;
  Completer<void>? volumeEntered;
  Completer<void>? listenerCancelGate;
  Completer<void>? listenerCancelEntered;
  String? failAppendSongId;

  /// A load whose first song is this one fails, as a broken source would.
  String? failLoadSongId;
  Set<String> hungLoadSongs = <String>{};
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
  Stream<PlaybackEvent> get playbackEventStream =>
      _events.stream.doOnCancel(() async {
        final gate = listenerCancelGate;
        if (gate == null) return;
        listenerCancelGate = null;
        listenerCancelEntered?.complete();
        await gate.future;
      });

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
  }) =>
      positionPlayer?.createPositionStream(
        steps: steps,
        minPeriod: minPeriod,
        maxPeriod: maxPeriod,
      ) ??
      const Stream<Duration>.empty();

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

  Duration simulatedDuration = const Duration(minutes: 3);

  @override
  Duration? get duration => simulatedDuration;

  @override
  double get volume => appliedVolumes.lastOrNull ?? 1;

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
    final gate = volumeGate;
    if (gate != null) {
      volumeGate = null;
      volumeEntered?.complete();
      await gate.future;
    }
    if (failVolume) {
      failVolume = false;
      throw StateError('volume unavailable');
    }
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
  String _sourceId(AudioSource source) => switch (source) {
    IndexedAudioSource(tag: final MediaItem item) => item.id,
    UriAudioSource(:final uri) => uri.queryParameters['id']!,
    // The vendored proxy source's tag is assigned only by native loading.
    // ignore: experimental_member_use
    LockCachingAudioSource(:final uri) => uri.queryParameters['id']!,
    _ => throw StateError('Fixture source has no song identity'),
  };

  List<String> get sourceIds => _sources.map(_sourceId).toList();

  void moveTo(int value) {
    index = value;
    _indices.add(value);
  }

  @override
  Future<void> pause() async {
    simulatedPosition = position;
    isPlaying = false;
    emitPlayerEvent();
    _playing?.complete();
    _playing = null;
  }

  int focusDenials = 0;
  int focusRequests = 0;

  /// Like just_audio, play() completes only when playback pauses; the
  /// granted focus is reported by a playback event.
  bool playCompletesOnPause = false;
  Completer<void>? _playing;

  @override
  Future<void> play() async {
    focusRequests++;
    if (focusDenials-- > 0) throw AudioFocusDeniedException();
    playRequested = true;
    if (ignorePlay) return;
    if (failPlay) throw StateError('play unavailable');
    if (!isPlaying) playedFrom.add(position);
    _positionUpdated = DateTime.now();
    isPlaying = true;
    emitPlayerEvent();
    if (playCompletesOnPause) {
      _events.add(playbackEvent);
      await (_playing = Completer<void>()).future;
    }
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

  StreamController<IcyMetadata?>? icyEvents;

  @override
  Stream<IcyMetadata?> get icyMetadataStream =>
      icyEvents?.stream ?? const Stream<IcyMetadata?>.empty();

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
    sourceLoads++;
    if (source != null) attemptedSongId = _sourceId(source);
    if (source != null && hungLoadSongs.contains(_sourceId(source))) {
      await Completer<void>().future;
    }
    await _hangIf('setAudioSources');
    final failing = failLoadSongId;
    if (failing != null &&
        sources.isNotEmpty &&
        sources.first is IndexedAudioSource &&
        _sourceId(sources.first) == failing) {
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
    emitPlayerEvent();
  });

  @override
  Future<void> dispose() async {
    disposed = true;
    isPlaying = false;
    await positionPlayer?.dispose();
    await icyEvents?.close();
    if (!keepStreamsAfterDispose) {
      await _indices.close();
      await _events.close();
    }
  }
}

// Exercise the vendored timer, rather than inventing a fake position pipeline.
class _HandlerPositionPlayer extends AudioPlayer {
  new(this.native)
    : super(handleInterruptions: false, handleAudioSessionActivation: false);

  final _ControllableAudioPlayer native;
  final events = BehaviorSubject<PlayerEvent>.seeded(PlayerEvent(), sync: true);

  @override
  Stream<PlayerEvent> get playerEventStream => events.stream;
  @override
  bool get playing => native.playing;
  @override
  Duration get position => native.position;
  @override
  Duration? get duration => native.duration;

  @override
  Future<void> dispose() async {
    await events.close();
    await super.dispose();
  }
}

@visibleForTesting
void expectNativeMirrorsQueue(
  NavisAudioHandler handler,
  AudioPlayer audioPlayer,
) {
  final player = audioPlayer as _ControllableAudioPlayer;
  final diagnostics = handler.collectPlaybackDiagnostics();
  final head = diagnostics['deferredHeadLength']! as int;
  final ids = handler.snapshot.queueSongIds;
  expect(player.shuffleEnabled, isFalse);
  expect(player.sourceIds, ids.skip(head).take(player.sourceIds.length));
  expect(
    head + player.sourceIds.length + (diagnostics['deferredLength']! as int),
    ids.length,
  );
  expect(handler.queue.value.map((item) => item.id), player.sourceIds);
}

@visibleForTesting
void expectAudioMatchesMetadata(
  NavisAudioHandler handler,
  List<AudioPlayer> audioPlayers, {
  PlaybackSnapshot? emission,
  String? previousSongId,
  bool settled = false,
}) {
  final players = audioPlayers.cast<_ControllableAudioPlayer>();
  final snapshot = emission ?? handler.snapshot;
  final audible = players
      .where((player) => player.audibleSongId != null)
      .toList();
  expect(audible, hasLength(audible.isEmpty ? 0 : 1));
  if (snapshot.isLoading && snapshot.currentSongId == snapshot.loadingSongId) {
    expect(handler.mediaItem.valueOrNull?.id, snapshot.loadingSongId);
    if (audible.isNotEmpty) {
      expect(audible.single, same(handler.debugActivePlayer));
    }
  } else if (audible.isNotEmpty) {
    final player = audible.single;
    expect(player, same(handler.debugActivePlayer));
    expect(
      snapshot.currentSongId,
      player.audibleSongId,
      reason: 'snapshot vs audio',
    );
    expect(
      handler.mediaItem.valueOrNull?.id,
      player.audibleSongId,
      reason: 'media item vs audio',
    );
  } else if (snapshot.isLoading && snapshot.currentSongId != null) {
    expect(
      snapshot.currentSongId,
      isIn([previousSongId, snapshot.loadingSongId]),
    );
  }
  if (settled) {
    expectNativeMirrorsQueue(
      handler,
      handler.debugActivePlayer as _ControllableAudioPlayer,
    );
  }
}

/// Collect listener failures so they cannot escape unnoticed as stream errors.
@visibleForTesting
Future<void> Function() watchAudioMetadata(
  NavisAudioHandler handler,
  List<AudioPlayer> audioPlayers,
) {
  final players = audioPlayers.cast<_ControllableAudioPlayer>();
  final violations = <Object>[];
  var previous = handler.snapshot.currentSongId;
  handler.debugSnapshotObserver = (snapshot) {
    try {
      expectAudioMatchesMetadata(
        handler,
        players,
        emission: snapshot,
        previousSongId: previous,
      );
    } on Object catch (error, stackTrace) {
      violations.add('$error\n$stackTrace');
    }
    if (!snapshot.isLoading ||
        players.any((player) => player.audibleSongId != null)) {
      previous = snapshot.currentSongId;
    }
  };
  return () async {
    await pumpEventQueue();
    handler.debugSnapshotObserver = null;
    expect(violations, isEmpty);
    expectAudioMatchesMetadata(
      handler,
      players,
      previousSongId: previous,
      settled: true,
    );
  };
}

@visibleForTesting
Future<void> settleQueue(NavisAudioHandler handler) async {
  if (handler.snapshot.isLoading) {
    await handler.snapshotStream.firstWhere((snapshot) => !snapshot.isLoading);
  }
  var quiet = 0;
  for (var i = 0; i < 10000 && quiet < 3; i++) {
    await Future<void>.delayed(Duration.zero);
    quiet = handler.debugQueueLaneIdle && !handler.snapshot.isLoading
        ? quiet + 1
        : 0;
  }
  expect(quiet, 3, reason: 'queue lane did not settle');
  expectNativeMirrorsQueue(handler, handler.debugActivePlayer);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(const RadioFilters()));

  Future<(NavisAudioHandler, _ControllableAudioPlayer, NavisDatabase)>
  createHandler(
    Directory directory,
    int count, {
    bool crossfade = false,
    bool crossfadeAllowStreaming = true,
    PlaybackSourceResolver Function(PlaybackSourceResolver)? wrapResolver,
    bool positionStreams = false,
    String crossfadeType = 'normal',
    String Function()? readCrossfadeType,
    bool matchFlow = false,
    int savedQueueIndex = -1,
    NavisQueueWindow queueWindow = const NavisQueueWindow(),
    NavisPlaybackTimeouts timeouts = const NavisPlaybackTimeouts(),
    List<_ControllableAudioPlayer>? rebuiltPlayers,
    List<_ControllableAudioPlayer>? players,
    FakeAsync? clock,
    Set<String>? hungLoadSongs,
    ScrobbleService? scrobbleService,
    String replayGainMode = 'off',
    _ControllableAudioPlayer? initialPlayer,
    bool waitForReady = true,
    NavisDatabase? sharedDatabase,
    LibraryDao Function(NavisDatabase)? createLibraryDao,
    PlayQueueDao Function(NavisDatabase)? createPlayQueueDao,
    HistoryDao Function(NavisDatabase)? createHistoryDao,
    // Songs stream from a server, with desktop sidecar caching.
    Future<NetworkReconciliation> Function()? reconcileNetwork,
    Stream<void>? recoveredNetwork,
    bool sidecarStreams = false,
    Future<void> Function(NavisDatabase database)? seed,
    bool cacheSongs = true,
    SubsonicApiClient? Function()? readApiClient,
    bool Function()? readCanStream,
    bool Function(Uri stream)? readRadioPlaybackAllowed,
    bool Function(Uri)? readRadioArtworkAllowed,
    bool Function()? readRadioMetadataAllowed,
    Dio Function()? createRadioMetadataDio,
    CoverArtHttpFileService? artworkFileService,
    Future<bool> Function({required bool autoPlay, bool Function()? isCurrent})?
    startPersonalRadio,
    void Function(({int index, String songId})? queueEndSkip)?
    onPersonalRadioQueueEnd,
  }) async {
    final database = sharedDatabase ?? createTestDatabase();
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
    final cache = RollingCacheManager(cacheDao: database.cacheDao);
    final player = initialPlayer ?? _ControllableAudioPlayer();
    if (positionStreams) player.positionPlayer = _HandlerPositionPlayer(player);
    if (hungLoadSongs != null) player.hungLoadSongs = hungLoadSongs;
    players?.add(player);
    final baseResolver = PlaybackSourceResolver(
      cacheDao: database.cacheDao,
      libraryDao: database.libraryDao,
      rollingCacheManager: cache,
      readApiClient: readApiClient ?? () => apiClient,
      readStreamingQuality: () => const StreamingQuality(label: 'original'),
      readRollingCacheDirectory: () async => directory,
      readCachedPlaybackFirst: () => true,
      readCanStream: readCanStream,
      readUsesSidecarRollingCache: () => sidecarStreams,
    );
    final resolver = wrapResolver?.call(baseResolver) ?? baseResolver;
    NavisAudioHandler buildHandler() => NavisAudioHandler(
      reconcileNetwork: reconcileNetwork,
      recoveredNetwork: recoveredNetwork,
      startPersonalRadio: (autoPlay, {isCurrent}) async =>
          await startPersonalRadio?.call(
            autoPlay: autoPlay,
            isCurrent: isCurrent,
          ) ??
          false,
      onPersonalRadioQueueEnd: onPersonalRadioQueueEnd,
      startPreferredMix: (_) async {},
      togglePreferredMix: (_) async {},
      artworkFileService: artworkFileService,
      readRadioMetadataAllowed: readRadioMetadataAllowed ?? () => false,
      createRadioMetadataDio: createRadioMetadataDio,
      readRadioPlaybackAllowed: readRadioPlaybackAllowed,
      readRadioArtworkAllowed: readRadioArtworkAllowed,
      libraryDao: createLibraryDao?.call(database) ?? database.libraryDao,
      playlistDao: database.playlistDao,
      playQueueDao: createPlayQueueDao?.call(database) ?? database.playQueueDao,
      matchFlowDao: database.matchFlowDao,
      historyDao: createHistoryDao?.call(database) ?? database.historyDao,
      sourceResolver: resolver,
      readApiClient: readApiClient ?? () => apiClient,
      rollingCacheManager: cache,
      readRollingCacheBudgetBytes: () => 1024 * 1024,
      scrobbleService: scrobbleService ?? _NoopScrobbleService(),
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
        crossfadeAllowStreaming: crossfadeAllowStreaming,
        crossfadeDurationSeconds: 5,
        crossfadeType: readCrossfadeType?.call() ?? crossfadeType,
        replayGainMode: replayGainMode,
        replayGainPreamp: 0,
        playbackSpeed: 1,
        albumQueueEnabled: false,
        matchFlowEnabled: matchFlow,
      ),
      adjustmentCapabilities: PlaybackAdjustmentCapabilities.android,
      crossfadePlayerFactory: () {
        final deck = _ControllableAudioPlayer();
        if (positionStreams) deck.positionPlayer = _HandlerPositionPlayer(deck);
        players?.add(deck);
        return deck;
      },
      starSyncDao: database.starSyncDao,
      player: player,
      queueWindow: queueWindow,
      timeouts: timeouts,
      shuffleRandom: Random(7),
      playerFactory: rebuiltPlayers == null && players == null
          ? null
          : () {
              final rebuilt = _ControllableAudioPlayer()
                ..simulateProgress = true;
              if (positionStreams) {
                rebuilt.positionPlayer = _HandlerPositionPlayer(rebuilt);
              }
              if (hungLoadSongs != null) rebuilt.hungLoadSongs = hungLoadSongs;
              rebuiltPlayers?.add(rebuilt);
              players?.add(rebuilt);
              return rebuilt;
            },
    );
    final handler = clock == null
        ? buildHandler()
        : HttpOverrides.runZoned(
            () => clock.run((_) => buildHandler()),
            createHttpClient: (_) => _ProbeClient(),
          );
    if (waitForReady) {
      var ready = false;
      final waiting = handler
          .waitUntilReady()
          .then((_) => handler.debugWaitForStartupQueueRestore())
          .then((_) => ready = true);
      if (clock != null) {
        for (var i = 0; i < 10000 && !ready; i++) {
          clock.flushMicrotasks();
          await Future<void>.delayed(Duration.zero);
        }
      }
      await waiting;
    }
    return (handler, player, database);
  }

  group('idle playback recovery', () {
    NetworkReconciliation net({required bool online}) =>
        (connected: online, serverReachable: online);

    Future<(NavisAudioHandler, _ControllableAudioPlayer, NavisDatabase)> setup({
      Future<NetworkReconciliation> Function()? reconcile,
      Stream<void>? recovered,
      bool remote = false,
      NavisPlaybackTimeouts timeouts = const NavisPlaybackTimeouts(),
    }) async {
      final directory = await Directory.systemTemp.createTemp('navis-idle-');
      final created = await createHandler(
        directory,
        3,
        reconcileNetwork: reconcile,
        recoveredNetwork: recovered,
        sidecarStreams: remote,
        timeouts: timeouts,
      );
      addTearDown(() async {
        await created.$1.disposeHandler();
        await created.$3.close();
        await directory.delete(recursive: true);
      });
      return created;
    }

    test('permanent focus loss permits a later explicit Play', () async {
      final (handler, player, _) = await setup();
      final session = _TestAudioSession();
      handler.debugWireAudioSession(session);
      addTearDown(session.close);
      await handler.replaceQueue(['song-0'], expandMatchFlows: false);
      session.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown),
      );
      await pumpEventQueue();
      expect(player.playing, isFalse);
      await handler.play();
      await pumpEventQueue();
      expect(player.playing, isTrue);
    });

    test('headphone removal cancels a pending denied Play', () async {
      final (handler, player, _) = await setup();
      final session = _TestAudioSession();
      handler.debugWireAudioSession(session);
      addTearDown(session.close);
      await handler.replaceQueue(
        ['song-0'],
        autoPlay: false,
        expandMatchFlows: false,
      );
      player.focusDenials = 1;
      await handler.play();
      await pumpEventQueue();
      session.noisy.add(null);
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 1150));
      expect(player.focusRequests, 1);
      expect(player.playing, isFalse);
    });

    test('denied Play resumes silently without another user command', () async {
      final (handler, player, _) = await setup();
      await handler.replaceQueue(
        ['song-0'],
        autoPlay: false,
        expandMatchFlows: false,
      );
      player.focusDenials = 1;
      final failures = <PlaybackLoadFailure>[];
      final subscription = handler.loadFailureStream.listen(failures.add);
      addTearDown(subscription.cancel);
      await handler.play();
      await Future<void>.delayed(const Duration(milliseconds: 1150));
      expect(player.focusRequests, 2);
      expect(player.playing, isTrue);
      expect(failures, isEmpty);
    });

    test(
      'a phone interruption blocks the focus retry until the call ends',
      () async {
        final (handler, player, _) = await setup();
        final session = _TestAudioSession();
        handler.debugWireAudioSession(session);
        addTearDown(session.close);
        await handler.replaceQueue(
          ['song-0'],
          autoPlay: false,
          expandMatchFlows: false,
        );
        player.focusDenials = 1;
        await handler.play();
        await pumpEventQueue();
        session.interruptions.add(
          AudioInterruptionEvent(true, AudioInterruptionType.pause),
        );
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 1150));
        expect(player.focusRequests, 1);
        expect(player.playing, isFalse);
        session.interruptions.add(
          AudioInterruptionEvent(false, AudioInterruptionType.pause),
        );
        await pumpEventQueue();
        expect(player.focusRequests, 2);
        expect(player.playing, isTrue);
      },
    );

    test('Pause cancels the pending denied Play', () async {
      final (handler, player, _) = await setup();
      await handler.replaceQueue(
        ['song-0'],
        autoPlay: false,
        expandMatchFlows: false,
      );
      player.focusDenials = 1;
      await handler.play();
      await pumpEventQueue();
      await handler.pause();
      await Future<void>.delayed(const Duration(milliseconds: 1150));
      expect(player.focusRequests, 1);
      expect(player.playing, isFalse);
    });

    test('offline recovery waits before spending the reload retry and preserves position', () async {
      var online = false;
      final recovered = StreamController<void>.broadcast();
      addTearDown(recovered.close);
      final (handler, player, _) = await setup(
        reconcile: () async => net(online: online),
        recovered: recovered.stream,
        remote: true,
      );
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      player
        ..simulatedPosition = const Duration(seconds: 42)
        ..state = ProcessingState.buffering;
      final loads = player.sourceLoads;
      await handler.debugRecoverCurrentSong();
      await handler.debugRecoverCurrentSong();
      expect(player.sourceLoads, loads);
      expect(handler.snapshot.currentSongId, 'song-0');
      online = true;
      recovered.add(null);
      await pumpEventQueue(times: 100);
      await settleQueue(handler);
      expect(player.sourceLoads, greaterThan(loads));
      expect(handler.snapshot.currentSongId, 'song-0');
      expect(player.position, const Duration(seconds: 42));
      expect(player.playing, isTrue);
    });

    test(
      'a second verified network outage reloads the same song again',
      () async {
        var online = true;
        final recovered = StreamController<void>.broadcast();
        addTearDown(recovered.close);
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: online),
          recovered: recovered.stream,
          remote: true,
        );
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        for (var outage = 0; outage < 2; outage++) {
          online = false;
          player
            ..simulatedPosition = const Duration(seconds: 42)
            ..state = ProcessingState.buffering;
          final loads = player.sourceLoads;
          await handler.debugRecoverCurrentSong();
          online = true;
          recovered.add(null);
          await pumpEventQueue(times: 100);
          await settleQueue(handler);
          expect(player.sourceLoads, loads + 1);
          expect(handler.snapshot.currentSongId, 'song-0');
          expect(player.position, const Duration(seconds: 42));
        }
      },
    );

    for (final radio in [false, true]) {
      test(
        'native error fields recover ${radio ? 'radio' : 'a song'} after the network returns',
        () async {
          var online = false;
          final recovered = StreamController<void>.broadcast();
          addTearDown(recovered.close);
          final (handler, player, _) = await setup(
            reconcile: () async => net(online: online),
            recovered: recovered.stream,
            remote: !radio,
          );
          if (radio) {
            await handler.playRadioStream(
              stationId: 'fixture',
              stationName: 'Fixture',
              streamUrl: 'https://radio.example.invalid/live',
            );
          } else {
            await handler.replaceQueue([
              'song-0',
              'song-1',
            ], expandMatchFlows: false);
          }
          player
            ..simulatedPosition = const Duration(seconds: 42)
            ..state = ProcessingState.idle
            ..isPlaying = false;
          final loads = player.sourceLoads;
          final error = PlaybackEvent(
            processingState: ProcessingState.idle,
            updatePosition: const Duration(seconds: 42),
            currentIndex: 0,
            errorCode: 0,
            errorMessage: 'Source error',
          );
          player._events.add(error);
          player._events.add(error);
          await pumpEventQueue();
          expect(player.sourceLoads, loads);
          online = true;
          recovered.add(null);
          await pumpEventQueue(times: 100);
          expect(player.sourceLoads, greaterThan(loads));
          if (!radio) await settleQueue(handler);
          expect(handler.snapshot.currentIndex, radio ? null : 0);
          expect(player.playing, isTrue);
          if (!radio) expect(player.position, const Duration(seconds: 42));
        },
      );
    }

    test(
      'a rejected station start clears its pending network recovery state',
      () async {
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: false),
        );
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..loadGate = gate
          ..loadEntered = entered
          ..blockedLoadError = StateError('fixture start failure');
        final starting = handler.playRadioStream(
          stationId: 'fixture',
          stationName: 'Fixture',
          streamUrl: 'https://radio.example.invalid/live',
        );
        final failed = expectLater(starting, throwsStateError);
        await entered.future;
        player._events.addError(PlayerException(0, 'Source error', 0));
        await pumpEventQueue();
        gate.complete();
        await failed;
        await pumpEventQueue();
        expect(handler.snapshot.isRadioMode, isFalse);
        expect(
          handler.snapshot.processingState,
          isNot(AudioProcessingState.buffering),
        );
      },
    );

    test('Pause then Play rearms radio recovery while older reconciliation finishes', () async {
      final reconciliation = Completer<bool>();
      final entered = Completer<void>();
      var checks = 0;
      final (handler, player, _) = await setup(
        reconcile: () {
          if (checks++ == 0) {
            entered.complete();
            return reconciliation.future.then((online) => net(online: online));
          }
          return Future.value(net(online: true));
        },
      );
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: 'https://radio.example.invalid/live',
      );
      final loads = player.sourceLoads;
      player
        ..state = ProcessingState.idle
        ..isPlaying = false;
      player._events.addError(PlayerException(0, 'network unavailable', null));
      await entered.future;
      await handler.pause();
      await handler.play();
      reconciliation.complete(true);
      await pumpEventQueue(times: 100);
      await Future<void>.delayed(const Duration(milliseconds: 3200));
      expect(player.sourceLoads, greaterThan(loads));
      expect(player.playing, isTrue);
      expect(handler.snapshot.radioStation?.stationId, 'fixture');
    });

    for (final cancel in ['none', 'stop', 'pause', 'replace']) {
      test('radio network recovery preserves intent ($cancel)', () async {
        var online = false;
        final recovered = StreamController<void>.broadcast();
        addTearDown(recovered.close);
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: online),
          recovered: recovered.stream,
        );
        await handler.playRadioStream(
          stationId: 'fixture',
          stationName: 'Fixture',
          streamUrl: 'https://radio.example.invalid/live',
        );
        final notices = <void>[];
        final subscription = handler.radioStreamErrorStream.listen(notices.add);
        addTearDown(subscription.cancel);
        final loads = player.sourceLoads;
        player.isPlaying = false;
        player._events.addError(
          PlayerException(0, 'network unavailable', null),
        );
        await pumpEventQueue();
        expect(handler.snapshot.isRadioMode, isTrue);
        expect(notices, isEmpty);
        if (cancel == 'stop') await handler.stopRadio();
        if (cancel == 'pause') await handler.pause();
        if (cancel == 'replace')
          await handler.replaceQueue(
            ['song-2'],
            autoPlay: false,
            expandMatchFlows: false,
          );
        final loadsAfterCommand = player.sourceLoads;
        online = true;
        recovered.add(null);
        await pumpEventQueue(times: 100);
        if (cancel == 'none') {
          expect(player.sourceLoads, greaterThan(loads));
          expect(player.playing, isTrue);
          expect(handler.snapshot.radioStation?.stationId, 'fixture');
        } else {
          expect(player.sourceLoads, loadsAfterCommand);
          expect(player.playing, isFalse);
        }
      });
    }
    PlaybackEvent nativeError(int code, {String message = 'Source error'}) =>
        PlaybackEvent(
          processingState: ProcessingState.idle,
          updatePosition: const Duration(seconds: 42),
          currentIndex: 0,
          errorCode: code,
          errorMessage: message,
        );

    Future<void> failSong(_ControllableAudioPlayer player) async {
      player
        ..simulatedPosition = const Duration(seconds: 42)
        ..state = ProcessingState.idle
        ..isPlaying = false;
      player._events.add(nativeError(0));
      await pumpEventQueue();
    }

    test('a natural advance clears a pending song recovery', () async {
      var online = false;
      final recovered = StreamController<void>.broadcast();
      addTearDown(recovered.close);
      final (handler, player, _) = await setup(
        reconcile: () async => net(online: online),
        recovered: recovered.stream,
        remote: true,
      );
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      player.state = ProcessingState.buffering;
      await handler.debugRecoverCurrentSong();
      expect(handler.snapshot.processingState, AudioProcessingState.buffering);
      player
        ..state = ProcessingState.ready
        ..moveTo(1);
      await pumpEventQueue();
      expect(handler.snapshot.currentSongId, 'song-1');
      expect(
        handler.snapshot.processingState,
        isNot(AudioProcessingState.buffering),
      );
      final loads = player.sourceLoads;
      online = true;
      recovered.add(null);
      await pumpEventQueue(times: 100);
      expect(player.sourceLoads, loads);
      expect(handler.snapshot.currentSongId, 'song-1');
    });

    test('a song that recovered by itself is not reloaded online', () async {
      var online = false;
      final recovered = StreamController<void>.broadcast();
      addTearDown(recovered.close);
      final (handler, player, _) = await setup(
        reconcile: () async => net(online: online),
        recovered: recovered.stream,
        remote: true,
      );
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      player
        ..simulatedPosition = const Duration(seconds: 42)
        ..state = ProcessingState.buffering;
      await handler.debugRecoverCurrentSong();
      player
        ..state = ProcessingState.ready
        ..simulatedPosition = const Duration(seconds: 50);
      final loads = player.sourceLoads;
      online = true;
      recovered.add(null);
      await pumpEventQueue(times: 100);
      expect(player.sourceLoads, loads);
      expect(player.position, const Duration(seconds: 50));
      expect(
        handler.snapshot.processingState,
        isNot(AudioProcessingState.buffering),
      );
    });

    test(
      'Pause in the offline hold, then Play once online, resumes the song',
      () async {
        var online = false;
        final recovered = StreamController<void>.broadcast();
        addTearDown(recovered.close);
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: online),
          recovered: recovered.stream,
          remote: true,
        );
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        await failSong(player);
        await handler.pause();
        online = true;
        recovered.add(null);
        await pumpEventQueue(times: 100);
        final loads = player.sourceLoads;
        await handler.play();
        await pumpEventQueue(times: 100);
        await settleQueue(handler);
        expect(player.sourceLoads, loads + 1);
        expect(handler.snapshot.currentSongId, 'song-0');
        expect(player.position, const Duration(seconds: 42));
        expect(player.playing, isTrue);
      },
    );

    test('a seek in the offline hold moves the recovery target', () async {
      var online = false;
      final recovered = StreamController<void>.broadcast();
      addTearDown(recovered.close);
      final (handler, player, _) = await setup(
        reconcile: () async => net(online: online),
        recovered: recovered.stream,
        remote: true,
        timeouts: const NavisPlaybackTimeouts(
          load: Duration(milliseconds: 300),
        ),
      );
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      final failures = <PlaybackLoadFailure>[];
      final subscription = handler.loadFailureStream.listen(failures.add);
      addTearDown(subscription.cancel);
      await failSong(player);
      await handler.seek(const Duration(seconds: 60));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final loads = player.sourceLoads;
      online = true;
      recovered.add(null);
      await pumpEventQueue(times: 100);
      await settleQueue(handler);
      expect(player.sourceLoads, loads + 1);
      expect(player.position, const Duration(seconds: 60));
      expect(player.playing, isTrue);
      expect(failures, isEmpty);
    });

    test('a station reconnects on device connectivity alone', () async {
      final (handler, player, _) = await setup(
        reconcile: () async => (connected: true, serverReachable: false),
      );
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: 'https://radio.example.invalid/live',
      );
      final loads = player.sourceLoads;
      player
        ..state = ProcessingState.idle
        ..isPlaying = false;
      player._events.add(nativeError(2001));
      await pumpEventQueue(times: 100);
      expect(player.sourceLoads, loads + 1);
      expect(player.playing, isTrue);
      expect(handler.snapshot.radioStation?.stationId, 'fixture');
    });

    for (final (code, message) in [
      (2005, 'Source error'),
      (2004, 'Source error (HTTP 404)'),
    ]) {
      test('a dead station ($code $message) stops with one notice', () async {
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: true),
        );
        await handler.replaceQueue(
          ['song-0'],
          autoPlay: false,
          expandMatchFlows: false,
        );
        await handler.playRadioStream(
          stationId: 'fixture',
          stationName: 'Fixture',
          streamUrl: 'https://radio.example.invalid/live',
        );
        final notices = <void>[];
        final subscription = handler.radioStreamErrorStream.listen(notices.add);
        addTearDown(subscription.cancel);
        player
          ..state = ProcessingState.idle
          ..isPlaying = false;
        player._events.add(nativeError(code, message: message));
        await pumpEventQueue(times: 100);
        await settleQueue(handler);
        expect(handler.snapshot.isRadioMode, isFalse);
        expect(notices, hasLength(1));
        expect(handler.snapshot.queueSongIds, ['song-0']);
        expect(player.playing, isFalse);
      });
    }

    test('transient station failures stop after the recovery budget', () async {
      final (handler, player, _) = await setup(
        reconcile: () async => net(online: false),
        timeouts: const NavisPlaybackTimeouts(
          radioRecovery: Duration(milliseconds: 300),
        ),
      );
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: 'https://radio.example.invalid/live',
      );
      final notices = <void>[];
      final subscription = handler.radioStreamErrorStream.listen(notices.add);
      addTearDown(subscription.cancel);
      player
        ..state = ProcessingState.idle
        ..isPlaying = false;
      player._events.add(nativeError(2001));
      await pumpEventQueue();
      expect(handler.snapshot.isRadioMode, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await pumpEventQueue(times: 100);
      expect(handler.snapshot.isRadioMode, isFalse);
      expect(notices, hasLength(1));
    });

    test(
      'an explicit Play overrides a focus holder that never returns focus',
      () async {
        final (handler, player, _) = await setup();
        final session = _TestAudioSession();
        handler.debugWireAudioSession(session);
        addTearDown(session.close);
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        session.interruptions.add(
          AudioInterruptionEvent(true, AudioInterruptionType.pause),
        );
        await pumpEventQueue();
        expect(player.playing, isFalse);
        await handler.play();
        await pumpEventQueue();
        expect(player.playing, isTrue);
        expect(session.activations, [false]);
      },
    );

    test(
      'denied focus stops retrying after its budget and stays paused',
      () async {
        final (handler, player, _) = await setup(
          timeouts: const NavisPlaybackTimeouts(
            focusRetry: Duration(milliseconds: 500),
          ),
        );
        await handler.replaceQueue(
          ['song-0'],
          autoPlay: false,
          expandMatchFlows: false,
        );
        player.focusDenials = 100;
        await handler.play();
        await Future<void>.delayed(const Duration(milliseconds: 3500));
        expect(player.focusRequests, 2);
        expect(player.playing, isFalse);
        expect(handler.playbackState.value.playing, isFalse);
      },
    );

    test(
      'granted focus restarts the retry budget for a later denial',
      () async {
        final (handler, player, _) = await setup(
          timeouts: const NavisPlaybackTimeouts(
            focusRetry: Duration(milliseconds: 1500),
          ),
        );
        final session = _TestAudioSession();
        handler.debugWireAudioSession(session);
        addTearDown(session.close);
        await handler.replaceQueue(
          ['song-0'],
          autoPlay: false,
          expandMatchFlows: false,
        );
        player
          ..playCompletesOnPause = true
          ..focusDenials = 1;
        await handler.play();
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        expect(player.playing, isTrue);
        // A native reload interrupts the pending play() call while playing.
        player._playing!.completeError(PlayerInterruptedException('reload'));
        player._playing = null;
        session.interruptions.add(
          AudioInterruptionEvent(true, AudioInterruptionType.pause),
        );
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        player.focusDenials = 1;
        final requests = player.focusRequests;
        session.interruptions.add(
          AudioInterruptionEvent(false, AudioInterruptionType.pause),
        );
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        expect(player.focusRequests, requests + 2);
        expect(player.playing, isTrue);
      },
    );
  });

  for (final fails in [false, true]) {
    test('bootstrap includes local initialization (failure: $fails)', () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-local-init-',
      );
      final gate = Completer<void>();
      final player = _ControllableAudioPlayer()
        ..volumeGate = gate
        ..volumeEntered = Completer<void>()
        ..failVolume = fails;
      final (handler, _, database) = await createHandler(
        directory,
        1,
        initialPlayer: player,
        waitForReady: false,
      );
      final container = ProviderContainer(
        overrides: [
          audioHandlerInitializerProvider.overrideWithValue(
            () async => handler,
          ),
          audioBootstrapTimeoutProvider.overrideWithValue(
            const Duration(milliseconds: 30),
          ),
          audioBootstrapRetryDelayProvider.overrideWithValue(
            const Duration(days: 1),
          ),
        ],
      );
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        container.dispose();
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final bootstrap = container.read(
        audioBootstrapControllerProvider.notifier,
      );
      final initialization = bootstrap.retry();
      await player.volumeEntered!.future;
      if (fails) gate.complete();
      await initialization;
      final state = container.read(audioBootstrapControllerProvider);
      expect(state.status, AudioBootstrapStatus.failed);
      expect(state.timedOut, !fails);
      expect(container.read(audioHandlerProvider), isNull);
      if (!fails) {
        gate.complete();
        await pumpEventQueue(times: 100);
        expect(
          container.read(audioBootstrapControllerProvider).isReady,
          isTrue,
        );
      } else {
        expect(bootstrap.isRetryScheduled, isTrue);
      }
    });
  }

  test('bootstrap readiness excludes saved queue restoration', () async {
    final directory = await Directory.systemTemp.createTemp(
      'navis-ready-without-restore-',
    );
    late _GatedPlayQueueDao library;
    final (handler, player, database) = await createHandler(
      directory,
      3,
      savedQueueIndex: 1,
      waitForReady: false,
      createPlayQueueDao: (db) => library = _GatedPlayQueueDao(db),
    );
    final container = ProviderContainer(
      overrides: [
        audioHandlerInitializerProvider.overrideWithValue(() async => handler),
      ],
    );
    addTearDown(() async {
      if (!library.release.isCompleted) library.release.complete();
      container.dispose();
      await handler.disposeHandler();
      await database.close();
      await directory.delete(recursive: true);
    });
    await container.read(audioBootstrapControllerProvider.notifier).retry();
    await library.entered.future.timeout(const Duration(seconds: 1));
    expect(container.read(audioBootstrapControllerProvider).isReady, isTrue);
    expect(library.release.isCompleted, isFalse);
    expect(player.sequence, isEmpty);
    library.release.complete();
    await handler.debugWaitForStartupQueueRestore();
    expect(handler.snapshot.currentIndex, 1);
    expect(player.sequence, isEmpty);
  });

  for (final recent in [false, true]) {
    test(
      'large unavailable saved queue falls back on first Play (recent: $recent)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-large-fallback-',
        );
        final (handler, player, database) = await createHandler(
          directory,
          70,
          savedQueueIndex: 0,
          seed: (db) async {
            final cached = await db.cacheDao.getCachedTrack('song-0');
            await File(cached!.filePath).delete();
            if (recent) {
              await db.historyDao.addPlayHistory('song-1');
            } else {
              await db.libraryDao.setEntityStarred(
                'song',
                'song-1',
                DateTime.now(),
              );
            }
          },
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        await handler.play();
        expect(handler.snapshot.queueSongIds, ['song-1']);
        await settleQueue(handler);
        expect(player.sourceIds, ['song-1']);
        expect(player.isPlaying, isTrue);
        expect(handler.playbackState.value.errorMessage, isNull);
        await handler.debugFlushQueuePersistence();
        expect((await database.playQueueDao.getQueueItems()).map((s) => s.id), [
          'song-1',
        ]);
      },
    );
  }

  test(
    'second Play restarts superseded recent preparation for the newest command',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-second-play-',
      );
      late _GatedHistoryDao history;
      final (handler, player, database) = await createHandler(
        directory,
        2,
        createHistoryDao: (db) => history = _GatedHistoryDao(db),
      );
      addTearDown(() async {
        if (!history.release.isCompleted) history.release.complete();
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final first = handler.play();
      await history.entered.future.timeout(const Duration(seconds: 1));
      final second = handler.play();
      await pumpEventQueue();
      history.release.complete();
      await Future.wait([first, second]);
      await settleQueue(handler);
      expect(history.lookups, 2);
      expect(handler.snapshot.queueSongIds, ['song-1']);
      expect(player.sourceIds, ['song-1']);
      expect(player.isPlaying, isTrue);
      expect(player.sourceLoads, 1);
      expect(handler.playbackState.value.errorMessage, isNull);
    },
  );

  for (final command in ['pause', 'stop', 'replace', 'play']) {
    test(
      'overlapping empty-queue Plays respect newer $command during radio fetch',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-radio-transport-',
        );
        final entered = Completer<void>();
        final batch = Completer<RecommendationBatch>();
        final service = _MockRecommendationService();
        var fetches = 0;
        when(
          () => service.personalRadio(
            any(),
            excludedIds: any(named: 'excludedIds'),
            count: any(named: 'count'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) {
          fetches++;
          if (!entered.isCompleted) entered.complete();
          return batch.future;
        });
        late ProviderContainer container;
        final (handler, player, database) = await createHandler(
          directory,
          2,
          startPersonalRadio: ({required autoPlay, isCurrent}) async =>
              (await container
                      .read(personalRadioProvider.notifier)
                      .start(autoPlay: autoPlay, isCurrent: isCurrent))
                  .succeeded,
        );
        container = ProviderContainer(
          overrides: [
            navisDatabaseProvider.overrideWithValue(database),
            audioHandlerProvider.overrideWithValue(handler),
            subsonicApiProvider.overrideWithValue(null),
            recommendationServiceProvider.overrideWithValue(service),
            lyricsPrewarmProvider.overrideWithValue((_) async {}),
          ],
        );
        addTearDown(() async {
          if (!batch.isCompleted) {
            batch.complete(
              const RecommendationBatch(
                songs: [],
                source: RecommendationSource.server,
              ),
            );
          }
          container.dispose();
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final first = handler.play();
        await entered.future.timeout(const Duration(seconds: 1));
        final second = handler.play();
        await pumpEventQueue();
        expect(fetches, 1, reason: 'both Plays join the held radio fetch');
        switch (command) {
          case 'pause':
            await handler.pause();
          case 'stop':
            await handler.stop();
          case 'replace':
            await handler.replaceQueue(['song-1'], autoPlay: false);
          case 'play':
            // The second Play remains the newest intent.
            break;
        }
        batch.complete(
          const RecommendationBatch(
            songs: [models.Song(id: 'song-0', title: 'Song 0')],
            source: RecommendationSource.server,
          ),
        );
        await Future.wait([first, second]);
        await settleQueue(handler);
        expect(handler.snapshot.queueSongIds, switch (command) {
          'replace' => ['song-1'],
          'play' => ['song-0'],
          _ => isEmpty,
        });
        expect(handler.snapshot.playing, command == 'play');
        expect(player.isPlaying, command == 'play');
        expect(
          player.sourceLoads,
          command == 'pause' || command == 'stop' ? 0 : 1,
        );
        expect(fetches, command == 'play' ? 2 : 1);
        expect(container.read(personalRadioProvider).busy, isFalse);
        expect(handler.playbackState.value.errorMessage, isNull);
        await handler.debugFlushQueuePersistence();
        expect(
          (await database.playQueueDao.getQueueItems()).map((song) => song.id),
          handler.snapshot.queueSongIds,
        );
      },
    );
  }

  for (final replacement in [false, true]) {
    test(
      'cancelled first Play preserves newer queue (replacement: $replacement)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-cancel-play-',
        );
        late _GatedSourceResolver resolver;
        final (handler, player, database) = await createHandler(
          directory,
          3,
          savedQueueIndex: 0,
          wrapResolver: (base) => resolver = _GatedSourceResolver(base)
            ..blockedSongId = 'song-0'
            ..entered = Completer<void>()
            ..release = Completer<void>(),
          seed: (db) => db.libraryDao.upsertSongs([
            SongsTableCompanion.insert(
              id: 'song-1',
              title: 'Fallback',
              starred: Value(DateTime.now()),
            ),
          ]),
        );
        addTearDown(() async {
          if (!resolver.release!.isCompleted) resolver.release!.complete();
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final play = handler.play();
        await resolver.entered!.future.timeout(const Duration(seconds: 1));
        final newer = replacement
            ? handler.replaceQueue(
                ['song-2'],
                autoPlay: false,
                expandMatchFlows: false,
              )
            : handler.clearQueue();
        resolver.release!.complete();
        await Future.wait([play, newer]);
        await settleQueue(handler);
        expect(
          handler.snapshot.queueSongIds,
          replacement ? ['song-2'] : isEmpty,
        );
        expect(player.isPlaying, isFalse);
      },
    );
  }

  for (final index in [0, 1]) {
    for (final seconds in [2, 42]) {
      test(
        'first Previous uses saved position (index: $index, seconds: $seconds)',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'navis-first-previous-',
          );
          final (handler, player, database) = await createHandler(
            directory,
            3,
            savedQueueIndex: index,
            seed: (db) => db.playQueueDao.saveQueue(
              songIds: ['song-0', 'song-1', 'song-2'],
              currentIndex: index,
              positionMs: seconds * 1000,
            ),
          );
          addTearDown(() async {
            await handler.disposeHandler();
            await database.close();
            await directory.delete(recursive: true);
          });
          expect(player.sequence, isEmpty);
          await handler.skipToPrevious();
          await settleQueue(handler);
          expect(
            handler.snapshot.currentIndex,
            seconds > 3 ? index : (index - 1).clamp(0, 2),
          );
          expect(player.position, Duration.zero);
          expect(player.isPlaying, isFalse);
        },
      );
    }
  }

  test(
    'radio after metadata restore retains station media-session metadata',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-restored-radio-',
      );
      final (handler, _, database) = await createHandler(
        directory,
        3,
        savedQueueIndex: 1,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final items = <MediaItem?>[];
      final subscription = handler.mediaItem.listen(items.add);
      addTearDown(subscription.cancel);
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture Radio',
        streamUrl: 'https://fixture.invalid/radio',
      );
      await pumpEventQueue();
      expect(handler.snapshot.radioStation?.stationId, 'fixture');
      expect(handler.mediaItem.value?.id, 'radio:fixture');
      final stationPublished = items.indexWhere(
        (item) => item?.id == 'radio:fixture',
      );
      expect(stationPublished, greaterThanOrEqualTo(0));
      expect(items.skip(stationPublished), everyElement(isNotNull));
      expect(handler.snapshot.queueSongIds, isEmpty);
    },
  );

  test('uncached saved queue publishes metadata and position before any source resolution', () async {
    final directory = await Directory.systemTemp.createTemp(
      'navis-lazy-restore-',
    );
    final api = SubsonicApiClient(
      baseUrl: 'https://example.com',
      authConfig: const SubsonicAuthConfig(
        username: 'fixture',
        password: 'synthetic',
        apiVersion: '1.16.1',
      ),
      enableLogging: false,
    );
    late _GatedSourceResolver resolver;
    final (handler, player, database) = await createHandler(
      directory,
      3,
      savedQueueIndex: 2,
      cacheSongs: false,
      readApiClient: () => api,
      wrapResolver: (base) => resolver = _GatedSourceResolver(base)
        ..blockedSongId = 'song-1'
        ..entered = Completer<void>()
        ..release = Completer<void>(),
      seed: (db) => db.playQueueDao.saveQueue(
        songIds: ['song-1', 'song-0', 'song-1'],
        currentIndex: 2,
        positionMs: 42000,
        repeatMode: RepeatMode.all,
      ),
    );
    addTearDown(() async {
      if (!resolver.release!.isCompleted) resolver.release!.complete();
      await handler.disposeHandler();
      await database.close();
      api.close();
      await directory.delete(recursive: true);
    });
    expect(resolver.entered!.isCompleted, isFalse);
    expect(player.sequence, isEmpty);
    expect(handler.snapshot.currentIndex, 2);
    expect(handler.snapshot.position, const Duration(seconds: 42));
    expect(handler.snapshot.queueSongIds, ['song-1', 'song-0', 'song-1']);
    expect(handler.queue.value.map((item) => item.id), [
      'song-1',
      'song-0',
      'song-1',
    ]);
    expect(handler.mediaItem.value?.id, 'song-1');
    expect(handler.playbackState.value.queueIndex, 2);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.ready,
    );
    expect(handler.playbackState.value.playing, isFalse);
    expect(
      handler.playbackState.value.updatePosition,
      const Duration(seconds: 42),
    );
    final play = handler.play();
    await resolver.entered!.future.timeout(const Duration(seconds: 1));
    expect(handler.snapshot.isLoading, isTrue);
    resolver.release!.complete();
    await play;
    expect(handler.snapshot.currentIndex, 2);
    expect(player.position, const Duration(seconds: 42));
    expect(player.isPlaying, isTrue);
    expect(handler.snapshot.repeatMode, AudioServiceRepeatMode.all);
    expect(handler.snapshot.queueSongIds, ['song-1', 'song-0', 'song-1']);
  });

  for (final command in ['prepare', 'seek', 'next']) {
    test('first $command lazily materializes the restored queue', () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-lazy-transport-',
      );
      final (handler, player, database) = await createHandler(
        directory,
        3,
        savedQueueIndex: 1,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      expect(player.sequence, isEmpty);
      switch (command) {
        case 'prepare':
          await handler.prepare();
        case 'seek':
          await handler.seek(const Duration(seconds: 9));
        case 'next':
          await handler.skipToNext();
      }
      await settleQueue(handler);
      expect(player.sequence, hasLength(3));
      expect(handler.snapshot.currentIndex, command == 'next' ? 2 : 1);
      expect(player.isPlaying, isFalse);
    });
  }

  group('pending selection metadata', () {
    for (final path in ['ids', 'rows', 'remote', 'skip', 'jump']) {
      test(
        'publishes target before source preparation completes ($path)',
        () async {
          late _GatedSourceResolver resolver;
          final directory = await Directory.systemTemp.createTemp(
            'navis-pending-',
          );
          final (handler, player, database) = await createHandler(
            directory,
            4,
            wrapResolver: (base) => resolver = _GatedSourceResolver(base),
            queueWindow: const NavisQueueWindow(
              deferThreshold: 1,
              ahead: 0,
              behind: 0,
              lowWater: 0,
              page: 1,
              nearJump: 0,
            ),
          );
          addTearDown(() async {
            resolver.release?.complete();
            await handler.disposeHandler();
            await database.close();
            await directory.delete(recursive: true);
          });
          final rows = await database.libraryDao.getSongsByIds([
            'song-0',
            'song-1',
            'song-2',
            'song-3',
          ]);
          await handler.replaceQueueWithData(
            path == 'skip' || path == 'jump' ? rows : [rows[0]],
            expandMatchFlows: false,
          );
          final target = rows[path == 'jump' ? 3 : 1].copyWith(
            title: 'Picked title',
            artistName: const Value('Picked artist'),
            albumName: const Value('Picked album'),
            duration: const Value(123),
          );
          await database.libraryDao.upsertSongs([
            SongsTableCompanion.insert(
              id: target.id,
              title: target.title,
              artistName: Value(target.artistName),
              albumName: Value(target.albumName),
              duration: Value(target.duration),
            ),
          ]);
          resolver.blockedSongId = target.id;
          resolver.entered = Completer<void>();
          resolver.release = Completer<void>();
          Future<void> operation;
          if (path == 'remote') {
            handler.beginPlaybackSelection(
              target.id,
              isExternal: true,
              song: target.copyWith(isExternal: true),
            );
            expect(handler.mediaItem.valueOrNull?.title, target.title);
            expect(handler.snapshot.loadingSongId, target.id);
            operation = handler.replaceQueueWithData([
              target.copyWith(isExternal: true),
            ], expandMatchFlows: false);
          } else if (path == 'ids') {
            operation = handler.replaceQueue([
              target.id,
            ], expandMatchFlows: false);
          } else if (path == 'rows') {
            operation = handler.replaceQueueWithData([
              target,
            ], expandMatchFlows: false);
            expect(handler.mediaItem.valueOrNull?.id, target.id);
          } else if (path == 'skip') {
            operation = handler.skipToNext();
          } else {
            operation = handler.playFromIndex(3);
          }
          await resolver.entered!.future;
          expect(player.audibleSongId, 'song-0');
          final pending = handler.mediaItem.valueOrNull!;
          expect(pending.id, target.id);
          expect(pending.title, target.title);
          expect(pending.artist, target.artistName);
          expect(pending.album, target.albumName);
          expect(pending.duration, const Duration(seconds: 123));
          expect(handler.snapshot.currentSongId, target.id);
          expect(handler.snapshot.isLoading, isTrue);
          expect(handler.snapshot.loadingSongId, target.id);
          resolver.blockedSongId = null;
          resolver.release!.complete();
          resolver.release = null;
          await operation;
          await settleQueue(handler);
          expect(handler.mediaItem.valueOrNull?.id, target.id);
          expect(handler.mediaItem.valueOrNull?.title, pending.title);
          expect(handler.snapshot.isLoading, isFalse);
        },
      );
    }

    test(
      'failed source preparation restores metadata for the held source',
      () async {
        late _GatedSourceResolver resolver;
        final directory = await Directory.systemTemp.createTemp(
          'navis-pending-failed-',
        );
        final (handler, player, database) = await createHandler(
          directory,
          2,
          wrapResolver: (base) => resolver = _GatedSourceResolver(base),
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final rows = await database.libraryDao.getSongsByIds([
          'song-0',
          'song-1',
        ]);
        await handler.replaceQueueWithData([rows[0]], expandMatchFlows: false);
        resolver.blockedSongId = 'song-1';
        resolver.entered = Completer<void>();
        resolver.release = Completer<void>();
        resolver.failure = StateError('source failed');
        final operation = handler.replaceQueueWithData([
          rows[1],
        ], expandMatchFlows: false);
        final failed = expectLater(operation, throwsStateError);
        await resolver.entered!.future;
        expect(handler.mediaItem.valueOrNull?.id, 'song-1');
        resolver.release!.complete();
        await failed;
        expect(handler.mediaItem.valueOrNull?.id, 'song-0');
        expect(handler.snapshot.currentSongId, 'song-0');
        expect(handler.snapshot.isLoading, isFalse);
        expect(player.audibleSongId, 'song-0');
      },
    );

    test('failed provisional persistence retains the radio session', () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-radio-held-',
      );
      final (handler, player, database) = await createHandler(directory, 1);
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      player.icyEvents = StreamController<IcyMetadata?>.broadcast();
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture FM',
        streamUrl: 'https://radio.example.invalid/stream',
      );
      player.icyEvents!.add(
        IcyMetadata(
          info: IcyInfo(title: 'Held artist - Held title', url: null),
          headers: null,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final held = handler.snapshot.radioStation;
      final heldItem = handler.mediaItem.valueOrNull;
      final song = (await database.libraryDao.getSongsByIds(['song-0'])).single;
      final attempt = handler.beginPlaybackSelection(
        'song-0',
        isExternal: true,
        song: song,
      );
      expect(handler.mediaItem.valueOrNull?.id, 'song-0');
      handler.notePlaybackSelectionStage(
        attempt,
        'provisionalPersistenceFailed',
      );
      expect(handler.snapshot.radioStation, held);
      expect(handler.mediaItem.valueOrNull, heldItem);
      expect(handler.snapshot.isLoading, isFalse);
      expect(player.audibleSongId, 'radio:fixture');
      expect(player.icyEvents!.hasListener, isTrue);
      player.icyEvents!.add(
        IcyMetadata(
          info: IcyInfo(title: 'New artist - New title', url: null),
          headers: null,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(handler.snapshot.radioStation?.nowPlayingTitle, 'New title');
      expect(handler.mediaItem.valueOrNull?.title, 'New title');
    });

    test('failed provisional persistence restores held metadata', () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-provisional-failed-',
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
      await handler.replaceQueueWithData([rows[0]], expandMatchFlows: false);
      final attempt = handler.beginPlaybackSelection(
        'song-1',
        isExternal: true,
        song: rows[1],
      );
      expect(handler.mediaItem.valueOrNull?.id, 'song-1');
      handler.notePlaybackSelectionStage(
        attempt,
        'provisionalPersistenceFailed',
      );
      expect(handler.mediaItem.valueOrNull?.id, 'song-0');
      expect(handler.snapshot.isLoading, isFalse);
      expect(player.audibleSongId, 'song-0');
    });

    for (final command in ['next', 'previous', 'index']) {
      test(
        'materialized $command publishes metadata before seek settles',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'navis-pending-seek-',
          );
          final (handler, player, database) = await createHandler(directory, 3);
          addTearDown(() async {
            await handler.disposeHandler();
            await database.close();
            await directory.delete(recursive: true);
          });
          await handler.replaceQueue(
            ['song-0', 'song-1', 'song-2'],
            startIndex: 1,
            expandMatchFlows: false,
          );
          player.simulatedPosition = Duration.zero;
          player.seekGate = Completer<void>();
          player.seekEntered = Completer<void>();
          final gate = player.seekGate!;
          final operation = switch (command) {
            'next' => handler.skipToNext(),
            'previous' => handler.skipToPrevious(),
            _ => handler.playFromIndex(0),
          };
          final target = command == 'next' ? 'song-2' : 'song-0';
          expect(handler.mediaItem.valueOrNull?.id, target);
          await player.seekEntered!.future;
          expect(player.audibleSongId, 'song-1');
          expect(handler.snapshot.currentSongId, target);
          expect(
            handler.playbackState.value.processingState,
            AudioProcessingState.loading,
          );
          gate.complete();
          await operation;
          await settleQueue(handler);
          expect(player.audibleSongId, target);
          expect(handler.mediaItem.valueOrNull?.id, target);
        },
      );
    }

    test(
      'superseded source preparation cannot overwrite a newer target',
      () async {
        late _GatedSourceResolver resolver;
        final directory = await Directory.systemTemp.createTemp(
          'navis-pending-race-',
        );
        final (handler, _, database) = await createHandler(
          directory,
          3,
          wrapResolver: (base) => resolver = _GatedSourceResolver(base),
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final rows = await database.libraryDao.getSongsByIds([
          'song-0',
          'song-1',
          'song-2',
        ]);
        await handler.replaceQueueWithData([rows[0]], expandMatchFlows: false);
        resolver.blockedSongId = 'song-1';
        resolver.entered = Completer<void>();
        resolver.release = Completer<void>();
        final older = handler.replaceQueueWithData([
          rows[1],
        ], expandMatchFlows: false);
        await resolver.entered!.future;
        expect(handler.mediaItem.valueOrNull?.id, 'song-1');
        final published = <String?>[];
        final sub = handler.mediaItem.listen((item) => published.add(item?.id));
        addTearDown(sub.cancel);
        final newer = handler.replaceQueueWithData([
          rows[2],
        ], expandMatchFlows: false);
        expect(handler.mediaItem.valueOrNull?.id, 'song-2');
        await pumpEventQueue();
        published.clear();
        resolver.release!.complete();
        await Future.wait([older, newer]);
        expect(handler.mediaItem.valueOrNull?.id, 'song-2');
        expect(published, isNot(contains('song-1')));
        expect(handler.snapshot.isLoading, isFalse);
      },
    );
  });

  group('audio metadata invariants', () {
    const tiny = NavisQueueWindow(
      deferThreshold: 12,
      ahead: 3,
      lowWater: 2,
      page: 3,
      nearJump: 5,
      behind: 3,
      trimSlack: 1,
    );
    const deadlines = NavisPlaybackTimeouts(
      control: Duration(milliseconds: 100),
      load: Duration(milliseconds: 300),
      reset: Duration(milliseconds: 150),
      remoteLoad: Duration(seconds: 5),
    );
    List<String> ids(int count) => List.generate(count, (i) => 'song-$i');

    Future<(NavisAudioHandler, _ControllableAudioPlayer, NavisDatabase)>
    fixture(
      List<_ControllableAudioPlayer> players, {
      bool crossfade = false,
      int count = 60,
      NavisQueueWindow queueWindow = tiny,
      SubsonicApiClient? api,
      Future<void> Function(NavisDatabase)? seed,
      FakeAsync? clock,
      Set<String>? hungLoadSongs,
      ScrobbleService? scrobbleService,
      String replayGainMode = 'off',
    }) async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-invariant-',
      );
      final created = await createHandler(
        directory,
        count,
        crossfade: crossfade,
        players: players,
        queueWindow: queueWindow,
        timeouts: deadlines,
        readApiClient: () => api,
        seed: seed,
        clock: clock,
        hungLoadSongs: hungLoadSongs,
        scrobbleService: scrobbleService,
        replayGainMode: replayGainMode,
      );
      addTearDown(() async {
        var disposed = false;
        final disposing = created.$1.disposeHandler().then(
          (_) => disposed = true,
        );
        if (clock != null) {
          for (var i = 0; i < 10000 && !disposed; i++) {
            clock.flushMicrotasks();
            clock.elapse(const Duration(seconds: 1));
            await Future<void>.delayed(Duration.zero);
          }
        }
        await disposing;
        await created.$3.close();
        await directory.delete(recursive: true);
      });
      return created;
    }

    for (final crossfade in [false, true]) {
      for (final repeat in [
        AudioServiceRepeatMode.none,
        AudioServiceRepeatMode.all,
        AudioServiceRepeatMode.one,
      ]) {
        for (final state in ['stopped', 'playing', 'paused']) {
          test(
            'entity shuffle from $state, fade=$crossfade repeat=$repeat',
            () async {
              final players = <_ControllableAudioPlayer>[];
              final (handler, _, database) = await fixture(
                players,
                crossfade: crossfade,
              );
              await handler.replaceQueue(ids(60), expandMatchFlows: false);
              await handler.setRepeatMode(repeat);
              if (state == 'stopped') await handler.stop();
              if (state == 'paused') await handler.pause();
              final check = watchAudioMetadata(handler, players);
              final rows = await database.libraryDao.getSongsByIds(ids(60));
              rows.shuffle(Random(19));
              await handler.replaceQueueWithData(
                rows,
                originalOrder: ids(60),
                expandMatchFlows: false,
              );
              await settleQueue(handler);
              expect(
                handler.snapshot.queueSongIds,
                rows.map((song) => song.id),
              );
              await check();
            },
          );
        }

        for (final hang in [
          null,
          'removeAudioSourceRange',
          'insertAudioSources',
        ]) {
          test(
            'shuffle toggle rollback, fade=$crossfade repeat=$repeat hang=$hang',
            () async {
              final players = <_ControllableAudioPlayer>[];
              final (handler, player, database) = await fixture(
                players,
                crossfade: crossfade,
              );
              await handler.replaceQueue(
                ids(60),
                startIndex: 5,
                expandMatchFlows: false,
              );
              await handler.setRepeatMode(repeat);
              final check = watchAudioMetadata(handler, players);
              if (hang == 'removeAudioSourceRange') player.hang.add(hang!);
              await handler.setShuffleMode(AudioServiceShuffleMode.all);
              await settleQueue(handler);
              if (hang == 'removeAudioSourceRange') {
                expect(
                  handler.snapshot.shuffleMode,
                  AudioServiceShuffleMode.none,
                );
                expect(handler.snapshot.queueSongIds, ids(60));
                expect(player.audibleSongId, isNull);
                expect(player.appliedVolumes.last, 0);
              } else {
                expect(
                  handler.snapshot.shuffleMode,
                  AudioServiceShuffleMode.all,
                );
                if (hang == 'insertAudioSources') {
                  await handler.playFromIndex(10);
                  await settleQueue(handler);
                  (handler.debugActivePlayer as _ControllableAudioPlayer).hang
                      .add(hang!);
                }
                await handler.setShuffleMode(AudioServiceShuffleMode.none);
                await settleQueue(handler);
                if (hang == null) {
                  expect(handler.snapshot.queueSongIds, ids(60));
                } else {
                  expect(
                    handler.snapshot.shuffleMode,
                    AudioServiceShuffleMode.all,
                  );
                }
              }
              await check();
              await handler.debugFlushQueuePersistence();
              expect(
                (await database.playQueueDao.getQueueItems()).map(
                  (song) => song.id,
                ),
                handler.snapshot.queueSongIds,
              );
            },
          );
        }

        test(
          'handler shuffle plus entity shuffle restores playlist order, fade=$crossfade repeat=$repeat',
          () async {
            final players = <_ControllableAudioPlayer>[];
            final (handler, _, database) = await fixture(
              players,
              crossfade: crossfade,
            );
            await handler.setShuffleMode(AudioServiceShuffleMode.all);
            final rows = await database.libraryDao.getSongsByIds(ids(60));
            rows.shuffle(Random(19));
            await handler.setRepeatMode(repeat);
            final check = watchAudioMetadata(handler, players);
            await handler.replaceQueueWithData(
              rows,
              originalOrder: ids(60),
              expandMatchFlows: false,
            );
            expect(handler.snapshot.queueSongIds, rows.map((song) => song.id));
            await handler.setShuffleMode(AudioServiceShuffleMode.none);
            await settleQueue(handler);
            expect(handler.snapshot.queueSongIds, ids(60));
            expect(handler.snapshot.currentSongId, rows.first.id);
            await check();
          },
        );

        for (final forward in [true, false]) {
          test(
            'shuffle then navigation during Phase 2, fade=$crossfade repeat=$repeat forward=$forward',
            () async {
              final players = <_ControllableAudioPlayer>[];
              final (handler, player, _) = await fixture(
                players,
                crossfade: crossfade,
                count: 6,
                queueWindow: const NavisQueueWindow(),
              );
              await handler.replaceQueue(ids(6), expandMatchFlows: false);
              await handler.setShuffleMode(AudioServiceShuffleMode.all);
              await handler.setRepeatMode(repeat);
              final check = watchAudioMetadata(handler, players);
              final gate = Completer<void>();
              final entered = Completer<void>();
              player
                ..appendGate = gate
                ..appendEntered = entered;
              final replacing = handler.replaceQueue(
                ids(6),
                startIndex: 2,
                expandMatchFlows: false,
              );
              await entered.future;
              final order = List<String>.of(handler.snapshot.queueSongIds);
              if (forward) {
                await handler.skipToNext();
              } else {
                // Advance desired intent then supersede it with Previous.
                await handler.skipToNext();
                await handler.skipToPrevious();
              }
              gate.complete();
              await replacing;
              await settleQueue(handler);
              expect(handler.snapshot.currentSongId, order[forward ? 1 : 0]);
              await check();
            },
          );
        }

        test(
          'shuffle toggle during replacement waits for the new queue, fade=$crossfade repeat=$repeat',
          () async {
            final players = <_ControllableAudioPlayer>[];
            final (handler, player, _) = await fixture(
              players,
              crossfade: crossfade,
              count: 6,
              queueWindow: const NavisQueueWindow(),
            );
            await handler.replaceQueue(ids(6), expandMatchFlows: false);
            await handler.setRepeatMode(repeat);
            final check = watchAudioMetadata(handler, players);
            final gate = Completer<void>();
            final entered = Completer<void>();
            player
              ..loadGate = gate
              ..loadEntered = entered;
            final replacing = handler.replaceQueue(
              ids(6),
              startIndex: 2,
              expandMatchFlows: false,
            );
            await entered.future;
            final toggle = handler.setShuffleMode(AudioServiceShuffleMode.all);
            gate.complete();
            await Future.wait([replacing, toggle]);
            await handler.setShuffleMode(AudioServiceShuffleMode.none);
            await settleQueue(handler);
            expect(handler.snapshot.queueSongIds, ids(6));
            expect(handler.snapshot.currentSongId, 'song-2');
            await check();
          },
        );
      }
    }

    for (final crossfade in [false, true]) {
      test(
        'ReplayGain waits for the selected queue to commit, fade=$crossfade',
        () async {
          final players = <_ControllableAudioPlayer>[];
          final (handler, player, _) = await fixture(
            players,
            count: 3,
            crossfade: crossfade,
            replayGainMode: 'track',
            queueWindow: const NavisQueueWindow(),
            seed: (database) async {
              await (database.update(
                database.songsTable,
              )..where((song) => song.id.equals('song-0'))).write(
                const SongsTableCompanion(replayGainTrackGain: Value(-6)),
              );
              await (database.update(
                database.songsTable,
              )..where((song) => song.id.equals('song-1'))).write(
                const SongsTableCompanion(replayGainTrackGain: Value(-12)),
              );
            },
          );
          await handler.replaceQueue(['song-0'], expandMatchFlows: false);
          expect(
            player.appliedVolumes.last,
            closeTo(pow(10, -6 / 20), 0.00001),
          );
          final gate = Completer<void>();
          final entered = Completer<void>();
          player
            ..appendGate = gate
            ..appendEntered = entered;
          final check = watchAudioMetadata(handler, players);
          final replacement = handler.replaceQueue([
            'song-1',
            'song-2',
          ], expandMatchFlows: false);
          await entered.future;
          expect(handler.snapshot.hasPendingLogicalQueue, isTrue);
          // Source application restores user volume; song-scoped gain must
          // wait until the replacement's logical queue has committed.
          expect(player.appliedVolumes.last, 1);
          gate.complete();
          await replacement;
          await settleQueue(handler);
          expect(
            player.appliedVolumes.last,
            closeTo(pow(10, -12 / 20), 0.00001),
          );
          await check();
        },
      );
    }
    for (final repeat in [
      AudioServiceRepeatMode.none,
      AudioServiceRepeatMode.all,
      AudioServiceRepeatMode.one,
    ]) {
      for (final replaceSelection in [false, true]) {
        test(
          'Shuffle cancels a crossfade, replace=$replaceSelection repeat=$repeat',
          () async {
            final players = <_ControllableAudioPlayer>[];
            final (handler, player, database) = await fixture(
              players,
              crossfade: true,
              count: 6,
              queueWindow: const NavisQueueWindow(),
            );
            await handler.replaceQueue(ids(6), expandMatchFlows: false);
            await handler.setRepeatMode(repeat);
            await handler.debugStartCrossfade();
            expect(
              (handler.collectPlaybackDiagnostics()['crossfade']!
                  as Map)['active'],
              isTrue,
            );
            final rows = await database.libraryDao.getSongsByIds(ids(6));
            rows.shuffle(Random(7));
            final check = watchAudioMetadata(handler, players);
            final replacement = replaceSelection
                ? handler.replaceQueueWithData(
                    rows,
                    originalOrder: ids(6),
                    expandMatchFlows: false,
                  )
                : handler.setShuffleMode(AudioServiceShuffleMode.all);
            await pumpEventQueue();
            await replacement;
            await settleQueue(handler);
            expect(
              players.where((player) => player.audibleSongId != null),
              hasLength(1),
            );
            expect(
              player.audibleSongId,
              replaceSelection ? rows.first.id : 'song-0',
            );
            await check();
          },
        );
      }
    }

    for (final crossfade in [false, true]) {
      for (final repeat in [
        AudioServiceRepeatMode.none,
        AudioServiceRepeatMode.all,
        AudioServiceRepeatMode.one,
      ]) {
        for (final failure in ['none', 'stop', 'load']) {
          test(
            'cold remote replacement publishes selected paused metadata, fade=$crossfade repeat=$repeat failure=$failure',
            () async {
              final previousHttp = HttpOverrides.current;
              HttpOverrides.global = null;
              final server = await HttpServer.bind(
                InternetAddress.loopbackIPv4,
                0,
              );
              final requested = Completer<void>();
              final firstBytes = Completer<void>();
              server.listen((request) async {
                if (!requested.isCompleted) requested.complete();
                await firstBytes.future;
                try {
                  request.response
                    ..bufferOutput = false
                    ..contentLength = 2
                    ..add([1, 2]);
                  await request.response.close();
                } on HttpException {
                  // A timed-out/superseded probe can close its socket first.
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
              final scrobbles = _NoopScrobbleService();
              final hungLoadSongs = <String>{};
              final players = <_ControllableAudioPlayer>[];
              final (handler, player, database) = await fixture(
                players,
                count: 3,
                crossfade: crossfade,
                hungLoadSongs: hungLoadSongs,
                scrobbleService: scrobbles,
                api: api,
                queueWindow: const NavisQueueWindow(),
              );
              addTearDown(() async {
                if (!firstBytes.isCompleted) firstBytes.complete();
                await server.close(force: true);
                HttpOverrides.global = previousHttp;
              });
              await handler.replaceQueue(ids(3), expandMatchFlows: false);
              await handler.setRepeatMode(repeat);
              final check = watchAudioMetadata(handler, players);
              final rows = await database.libraryDao.getSongsByIds(ids(3));
              final remote = rows[1].copyWith(
                id: 'cold-external',
                isExternal: true,
              );
              await database.libraryDao.upsertSongs([
                SongsTableCompanion.insert(
                  id: remote.id,
                  title: remote.title,
                  isExternal: const Value(true),
                ),
              ]);
              if (failure == 'stop') player.hang.add('stop');
              if (failure == 'load') hungLoadSongs.add(remote.id);
              final replacement = handler.replaceQueueWithData(
                [remote, rows[2]],
                originalOrder: [remote.id, rows[2].id],
                expandMatchFlows: false,
              );
              await requested.future;
              expect(
                players.every((player) => player.audibleSongId == null),
                isTrue,
              );
              expect(handler.snapshot.currentSongId, remote.id);
              expect(handler.snapshot.playing, isFalse);
              expect(handler.playbackState.value.playing, isFalse);
              expect(handler.mediaItem.valueOrNull?.id, remote.id);
              expect(handler.snapshot.loadingSongId, remote.id);
              // Old native callbacks cannot notify or scrobble an unrelated song.
              if (failure != 'stop') {
                player.moveTo(2);
                player._events.add(player.playbackEvent);
                player._events.addError(StateError('old source failed'));
                await pumpEventQueue();
                expect(handler.snapshot.currentSongId, remote.id);
                expect(handler.mediaItem.valueOrNull?.id, remote.id);
                expect(scrobbles.nowPlaying, isNot(contains('song-2')));
                expect(scrobbles.submissions, isNot(contains('song-2')));
                expect(
                  handler.collectPlaybackDiagnostics()['seekEvents'],
                  isEmpty,
                );
              }
              firstBytes.complete();
              await replacement;
              if (failure == 'load') {
                if (handler.snapshot.currentSongId != 'song-2' ||
                    handler.snapshot.isLoading) {
                  await handler.snapshotStream.firstWhere(
                    (snapshot) =>
                        snapshot.currentSongId == 'song-2' &&
                        !snapshot.isLoading,
                  );
                }
                expect(player.attemptedSongId, remote.id);
                expect(player.audibleSongId, isNull);
                expect(
                  players.where((player) => player.attemptedSongId == 'song-2'),
                  isNotEmpty,
                );
              } else {
                expect(handler.snapshot.currentSongId, remote.id);
              }
              await settleQueue(handler);
              await check();
            },
          );
        }
      }
    }
    final api = SubsonicApiClient(
      baseUrl: 'http://127.0.0.1:1',
      authConfig: const SubsonicAuthConfig(
        username: 'fixture',
        password: 'synthetic',
        apiVersion: '1.16.1',
      ),
      enableLogging: false,
    );
    for (final crossfade in [false, true]) {
      for (final repeat in [
        AudioServiceRepeatMode.none,
        AudioServiceRepeatMode.all,
        AudioServiceRepeatMode.one,
      ]) {
        for (final external in [false, true]) {
          for (final timesOut in [false, true]) {
            for (final direction in ['next', 'previous', 'tap']) {
              test(
                'navigation requested occurrence, external=$external timeout=$timesOut direction=$direction fade=$crossfade repeat=$repeat',
                () async {
                  final clock = HttpOverrides.runZoned(
                    FakeAsync.new,
                    createHttpClient: (_) => _ProbeClient(),
                  );
                  final players = <_ControllableAudioPlayer>[];
                  final (handler, player, database) = await fixture(
                    players,
                    count: 3,
                    crossfade: crossfade,
                    clock: clock,
                    api: api,
                    queueWindow: const NavisQueueWindow(),
                    seed: (database) async {
                      if (external) {
                        await database.cacheDao.removeCachedTrack('song-1');
                        await (database.update(
                          database.songsTable,
                        )..where((song) => song.id.equals('song-1'))).write(
                          const SongsTableCompanion(isExternal: Value(true)),
                        );
                      }
                    },
                  );
                  var loaded = false;
                  final replacing = handler
                      .replaceQueue(
                        ids(3),
                        startIndex: direction == 'previous' ? 2 : 0,
                        expandMatchFlows: false,
                      )
                      .then((_) => loaded = true);
                  for (var i = 0; i < 10000 && !loaded; i++) {
                    clock.flushMicrotasks();
                    await Future<void>.delayed(Duration.zero);
                  }
                  clock.flushMicrotasks();
                  await replacing;
                  var repeatApplied = false;
                  final repeating = handler
                      .setRepeatMode(repeat)
                      .then((_) => repeatApplied = true);
                  for (var i = 0; i < 10000 && !repeatApplied; i++) {
                    clock.flushMicrotasks();
                    await Future<void>.delayed(Duration.zero);
                  }
                  await repeating;
                  final failures = <PlaybackLoadFailure>[];
                  final subscription = handler.loadFailureStream.listen(
                    failures.add,
                  );
                  addTearDown(subscription.cancel);
                  final check = watchAudioMetadata(handler, players);
                  final initialPlayerCount = players.length;
                  final gate = Completer<void>();
                  player
                    ..seekGate = gate
                    ..seekEntered = Completer<void>();
                  clock.run(
                    (_) => unawaited(switch (direction) {
                      'next' => handler.skipToNext(),
                      'previous' => handler.skipToPrevious(),
                      _ => handler.playFromIndex(1),
                    }),
                  );
                  for (
                    var i = 0;
                    i < 10000 && !player.seekEntered!.isCompleted;
                    i++
                  ) {
                    clock.flushMicrotasks();
                    clock.elapse(const Duration(milliseconds: 10));
                    await Future<void>.delayed(Duration.zero);
                  }
                  expect(player.seekEntered!.isCompleted, isTrue);
                  clock.elapse(
                    timesOut
                        ? const Duration(seconds: 6)
                        : const Duration(milliseconds: 900),
                  );
                  if (external && !timesOut) {
                    expect(handler.snapshot.loadingSongId, 'song-1');
                    expect(
                      failures.where(
                        (event) => event.operation == 'manual queue navigation',
                      ),
                      isEmpty,
                    );
                    gate.complete();
                    clock.flushMicrotasks();
                  } else {
                    expect(
                      failures.any(
                        (event) =>
                            event.operation == 'manual queue navigation' &&
                            event.isTimeout,
                      ),
                      isTrue,
                    );
                  }
                  for (
                    var i = 0;
                    i < 10000 &&
                        (handler.snapshot.isLoading ||
                            !handler.debugQueueLaneIdle);
                    i++
                  ) {
                    clock.flushMicrotasks();
                    clock.elapse(const Duration(milliseconds: 100));
                    await Future<void>.delayed(Duration.zero);
                  }
                  clock.flushMicrotasks();
                  await settleQueue(handler);
                  expect(handler.snapshot.currentSongId, 'song-1');
                  if (timesOut || !external) {
                    expect(
                      players.skip(initialPlayerCount).first.attemptedSongId,
                      'song-1',
                      reason:
                          'first rebuild must retry the requested occurrence',
                    );
                  }
                  if (!gate.isCompleted) gate.complete();
                  await check();
                  clock.elapse(const Duration(seconds: 1));
                  clock.flushMicrotasks();
                  var persisted = false;
                  final persistence = handler.debugFlushQueuePersistence().then(
                    (_) => persisted = true,
                  );
                  for (var i = 0; i < 10000 && !persisted; i++) {
                    clock.flushMicrotasks();
                    await Future<void>.delayed(Duration.zero);
                  }
                  await persistence;
                  expect(
                    (await database.playQueueDao.getQueueState())!.currentIndex,
                    1,
                  );
                },
              );
            }
          }
        }
      }
    }
  });

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
          startPersonalRadio: ({required autoPlay, isCurrent}) async {
            radioRequests.add(autoPlay);
            if (expected != 'song-4') return false;
            await radioHandler.replaceQueue(
              ['song-4'],
              autoPlay: autoPlay,
              expandMatchFlows: false,
            );
            expect(radioHandler.snapshot.playing, isTrue);
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
        expect(player.playing, expected != null);
        expect(
          radioRequests,
          !active && !saved && !recent && !liked ? [true] : isEmpty,
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
    for (final crossfade in [false, true]) {
      test(
        'Shuffle liked preserves collection order, fade=$crossfade',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'navis-auto-shuffle-',
          );
          final players = <_ControllableAudioPlayer>[];
          final (handler, _, database) = await createHandler(
            directory,
            6,
            crossfade: crossfade,
            players: players,
            seed: (database) async {
              for (var i = 0; i < 6; i++) {
                await database.libraryDao.setEntityStarred(
                  'song',
                  'song-$i',
                  DateTime(2026, 1, i + 1),
                );
              }
            },
          );
          addTearDown(() async {
            await handler.disposeHandler();
            await database.close();
            await directory.delete(recursive: true);
          });
          final original =
              (await database.libraryDao.watchAllStarredSongs().first)
                  .map((song) => song.id)
                  .toList();
          // This is the only Shuffle liked permutation; the handler must not
          // shuffle it again or save its random ranks as the original order.
          final expected = List<String>.of(original)..shuffle(Random(7));
          await handler.setShuffleMode(AudioServiceShuffleMode.all);
          final check = watchAudioMetadata(handler, players);
          await handler.prepareFromMediaId(AutoMediaRoot.shuffleLiked);
          await settleQueue(handler);
          expect(handler.snapshot.queueSongIds, expected);
          expect(handler.snapshot.playing, isFalse);
          await check();
          final restoreCheck = watchAudioMetadata(handler, players);
          await handler.setShuffleMode(AudioServiceShuffleMode.none);
          await settleQueue(handler);
          expect(handler.snapshot.queueSongIds, original);
          expect(handler.snapshot.currentSongId, expected.first);
          await restoreCheck();
        },
      );
    }

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

  for (final (master, host, allowed) in [
    (false, 'foreign.example', false),
    (true, 'foreign.example', true),
    (false, 'SERVER.example', true),
  ]) {
    test('radio playback policy master=$master host=$host', () async {
      final directory = await Directory.systemTemp.createTemp('radio-policy-');
      final (handler, player, database) = await createHandler(
        directory,
        0,
        readRadioPlaybackAllowed: (stream) =>
            master || stream.host.toLowerCase() == 'server.example',
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final stops = player.stopCalls;
      final result = handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: 'https://$host/live',
      );
      if (allowed) {
        await result;
        expect(handler.snapshot.radioStation?.stationId, 'fixture');
      } else {
        await expectLater(
          result,
          throwsA(isA<RadioPlaybackBlockedException>()),
        );
        expect(player.stopCalls, stops);
        expect(handler.snapshot.radioStation, isNull);
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
          await system.dispose();
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
    'mobile bootstrap rebuilds after begin then dispose in one process',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-reconnect-',
      );
      final fixtures =
          <(NavisAudioHandler, _ControllableAudioPlayer, NavisDatabase)>[];
      final database = createTestDatabase();
      final cache = _MockSystemArtCache();
      final services = <SwitchAudioHandler>[];
      final projections = <RealTimeProjectionAudioHandler>[];
      final container = ProviderContainer(
        overrides: [
          audioHandlerInitializerProvider.overrideWithValue(() async {
            final fixture = await createHandler(
              directory,
              1,
              sharedDatabase: database,
            );
            fixtures.add(fixture);
            final initialized = await initNavisAudioServiceHandler(
              builder: () {
                final projection = RealTimeProjectionAudioHandler(fixture.$1);
                projections.add(projection);
                return projection;
              },
              cacheManager: cache,
            );
            services.add(initialized.service);
            return initialized.handler;
          }),
        ],
      );
      addTearDown(() async {
        await container
            .read(audioBootstrapControllerProvider.notifier)
            .abortForSessionTeardown();
        container.dispose();
        for (final (handler, _, _) in fixtures) {
          await handler.disposeHandler();
        }
        await database.close();
        await directory.delete(recursive: true);
      });
      final bootstrap = container.read(
        audioBootstrapControllerProvider.notifier,
      );
      await bootstrap.retry();
      expect(container.read(audioBootstrapControllerProvider).isReady, isTrue);
      final first = fixtures.single.$1;
      final projectionClosed = projections.single.playbackState
          .listen((_) {})
          .asFuture<void>();
      await first.replaceQueue(['song-0'], expandMatchFlows: false);
      await bootstrap.abortForSessionTeardown();
      expect(container.read(audioHandlerProvider), isNull);
      await projectionClosed.timeout(const Duration(seconds: 1));
      expect(services.single.inner, isA<BaseAudioHandler>());

      bootstrap.ensureInitialized();
      await Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return !container.read(audioBootstrapControllerProvider).isReady;
      }).timeout(const Duration(seconds: 2));

      expect(container.read(audioBootstrapControllerProvider).isReady, isTrue);
      final rebuilt = container.read(audioHandlerProvider)!;
      expect(rebuilt, isNot(same(first)));
      await rebuilt.waitUntilReady();
      await rebuilt.replaceQueue(['song-0'], expandMatchFlows: false);
      expect(fixtures.last.$2.playing, isTrue);
      expect(services.last, same(services.first));
      await services.last.pause();
      expect(fixtures.last.$2.playing, isFalse);
      await services.last.click();
      expect(fixtures.last.$2.playing, isTrue);
    },
  );

  test(
    'mobile bootstrap completions retain their own session handler',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-init-race-',
      );
      final database = createTestDatabase();
      final first = await createHandler(directory, 1, sharedDatabase: database);
      final second = await createHandler(
        directory,
        1,
        sharedDatabase: database,
      );
      final projections = [
        RealTimeProjectionAudioHandler(first.$1),
        RealTimeProjectionAudioHandler(second.$1),
      ];
      addTearDown(() async {
        for (final (handler, _, _) in [first, second]) {
          await disposeNavisPlaybackHandler(handler);
        }
        await database.close();
        await directory.delete(recursive: true);
      });
      final initializations = await Future.wait([
        for (final projection in projections)
          initNavisAudioServiceHandler(
            builder: () => projection,
            cacheManager: _MockSystemArtCache(),
          ),
      ]);
      expect(initializations.first.handler, same(first.$1));
      expect(initializations.last.handler, same(second.$1));
      expect(initializations.first.service, same(initializations.last.service));
      final closed = projections.first.queue.listen((_) {}).asFuture<void>();

      beginNavisPlaybackHandlerTeardown(first.$1);
      await disposeNavisPlaybackHandler(first.$1);

      await closed.timeout(const Duration(seconds: 1));
      expect(initializations.last.service.inner, same(projections.last));
      await second.$1.replaceQueue(['song-0'], expandMatchFlows: false);
      await initializations.last.service.pause();
      expect(second.$2.playing, isFalse);
    },
  );

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

  test(
    'radio refuses non-HTTP schemes before loading a player source',
    () async {
      final directory = Directory.systemTemp.createTempSync('radio-schemes-');
      final (handler, player, database) = await createHandler(directory, 0);
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        directory.deleteSync(recursive: true);
      });
      for (final url in [
        'file:///tmp/audio',
        'lavfi://test',
        'edl://test',
        'intent://test',
        'https:///missing-host',
      ]) {
        await expectLater(
          handler.playRadioStream(
            stationId: 'fixture',
            stationName: 'Fixture',
            streamUrl: url,
          ),
          throwsArgumentError,
        );
        expect(player._sources, isEmpty);
        expect(handler.mediaItem.value, isNull);
      }
    },
    skip: !sqliteAvailable,
  );

  for (final path in [
    'stream',
    'listen/fixture/stream',
    'hls/fixture/live.m3u8',
  ]) {
    test('radio polling uses only AzuraCast stream shape: $path', () async {
      final dio = _MockRadioDio();
      final requested = <String>[];
      when(
        () => dio.get<Map<String, dynamic>>(
          any(),
          options: any(named: 'options'),
        ),
      ).thenAnswer((invocation) async {
        requested.add(invocation.positionalArguments.first as String);
        return Response<Map<String, dynamic>>(
          requestOptions: RequestOptions(),
          statusCode: 200,
          data: {
            'now_playing': {
              'song': {'title': 'Track'},
            },
          },
        );
      });
      final directory = Directory.systemTemp.createTempSync('radio-url-');
      final (handler, _, database) = await createHandler(
        directory,
        0,
        readRadioMetadataAllowed: () => true,
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
        streamUrl: 'https://radio.example.invalid/$path',
        homePageUrl: 'http://192.168.1.2/public/secret',
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        requested,
        path == 'stream'
            ? isEmpty
            : equals(['https://radio.example.invalid/api/nowplaying/fixture']),
      );
      expect(handler.mediaItem.value!.extras, {'isRadio': true});
      handler.updateRadioMetadata(title: 'Changed');
      expect(handler.mediaItem.value!.extras, {'isRadio': true});
    }, skip: !sqliteAvailable);
  }

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

      expect(player.sequence, isEmpty);
      await handler.prepare();
      if (player.sequence.length != 100)
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

  test(
    'unavailable Next reports the desired radio tail during a burst',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-nav-test-',
      );
      final requests = <({int index, String songId})?>[];
      final (handler, player, database) = await createHandler(
        directory,
        3,
        onPersonalRadioQueueEnd: requests.add,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      await handler.replaceQueueWithData(
        await database.libraryDao.getSongsByIds(['song-0', 'song-1', 'song-2']),
      );

      final gate = Completer<void>();
      player.seekGate = gate;
      await handler.skipToNext();
      await handler.skipToNext();
      // Applied skips cancel any held tail skip.
      expect(requests, [null, null]);
      await handler.skipToNext();
      expect(requests.last, (index: 2, songId: 'song-2'));
      expect(handler.snapshot.pendingQueueIndex, 2);
      gate.complete();
      await handler.snapshotStream
          .firstWhere(
            (snapshot) =>
                snapshot.currentIndex == 2 &&
                snapshot.pendingQueueIndex == null,
          )
          .timeout(const Duration(seconds: 5));

      // Ordinary end-of-queue Next stays on the current song until append.
      await handler.skipToNext();
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(requests.nonNulls, [
        (index: 2, songId: 'song-2'),
        (index: 2, songId: 'song-2'),
      ]);

      // Repeat-all still wraps rather than requesting a refill skip.
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      await handler.skipToNext();
      await handler.snapshotStream
          .firstWhere(
            (snapshot) =>
                snapshot.currentIndex == 0 &&
                snapshot.pendingQueueIndex == null,
          )
          .timeout(const Duration(seconds: 5));
      // The wrap is an applied skip, so it only cancels.
      expect(requests.nonNulls, hasLength(2));
      expect(requests.last, isNull);
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
    crossfading(
      int count, {
      bool sidecarStreams = false,
      bool positionStreams = false,
      String crossfadeType = 'normal',
      String Function()? readCrossfadeType,
      ScrobbleService? scrobbleService,
      String replayGainMode = 'off',
    }) async {
      final directory = await Directory.systemTemp.createTemp('navis-fade-');
      final created = await createHandler(
        directory,
        count,
        crossfade: true,
        sidecarStreams: sidecarStreams,
        positionStreams: positionStreams,
        crossfadeType: crossfadeType,
        readCrossfadeType: readCrossfadeType,
        scrobbleService: scrobbleService,
        replayGainMode: replayGainMode,
      );
      addTearDown(() async {
        await created.$1.disposeHandler();
        await created.$3.close();
        await directory.delete(recursive: true);
      });
      return created;
    }

    Future<void> waitForFade(bool Function() condition) async {
      for (var i = 0; i < 800 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(condition(), isTrue, reason: 'crossfade did not settle');
    }

    test(
      'incoming play preserves outgoing playback and reports both decks',
      () async {
        final (handler, outgoing, _) = await crossfading(2);
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        final incoming = handler.debugInactiveDeck! as _ControllableAudioPlayer;
        incoming.simulateProgress = true;
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        await waitForFade(() => incoming.playing && incoming.volume > 0);
        expect(outgoing.playing, isTrue);
        final status = fade(handler);
        expect((status['outgoing']! as Map)['playing'], isTrue);
        expect((status['incoming']! as Map)['playing'], isTrue);
        expect((status['incoming']! as Map)['positionMs'], greaterThan(0));
        expect(outgoing.volume, greaterThan(0));
        await handler.setVolume(0);
        expect(outgoing.volume, 0);
        expect(incoming.volume, 0);
        await handler.setVolume(.5);
        expect(incoming.volume, lessThan(.5));
        await handler.debugCompleteCrossfade();
        expect(handler.debugActivePlayer, same(incoming));
        expect(incoming.volume, .5);
      },
    );

    for (final adjustment in ['mute', 'duck']) {
      test('awaited fade tick preserves a newer $adjustment', () async {
        final (handler, outgoing, _) = await crossfading(2);
        final session = _TestAudioSession();
        handler.debugWireAudioSession(session);
        addTearDown(session.close);
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        final incoming = handler.debugInactiveDeck! as _ControllableAudioPlayer;
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        await waitForFade(() => incoming.volume > 0);
        final gate = Completer<void>();
        incoming.volumeGate = gate;
        incoming.volumeEntered = Completer<void>();
        await incoming.volumeEntered!.future;
        if (adjustment == 'mute') {
          await handler.setVolume(0);
        } else {
          session.interruptions.add(
            AudioInterruptionEvent(true, AudioInterruptionType.duck),
          );
          await waitForFade(() => outgoing.volume <= .4);
        }
        final adjusted = outgoing.volume;
        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(outgoing.volume, lessThanOrEqualTo(adjusted + .001));
        expect(
          incoming.volume,
          lessThanOrEqualTo(adjustment == 'mute' ? 0 : .4),
        );
        await handler.stop();
      });
    }

    test(
      'supersession during listener cancellation rebinds the active deck',
      () async {
        final (handler, outgoing, _) = await crossfading(
          3,
          positionStreams: true,
        );
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        final incoming = handler.debugInactiveDeck! as _ControllableAudioPlayer;
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        await waitForFade(() => incoming.playing);
        final gate = Completer<void>();
        outgoing.listenerCancelGate = gate;
        outgoing.listenerCancelEntered = Completer<void>();
        final handoff = handler.debugCompleteCrossfade();
        await outgoing.listenerCancelEntered!.future;
        await handler.playFromIndex(2);
        gate.complete();
        await handoff;
        expect(handler.debugActivePlayer, same(outgoing));
        outgoing.moveTo(1);
        await waitForFade(() => handler.snapshot.currentSongId == 'song-1');
        expect(handler.mediaItem.valueOrNull?.id, 'song-1');
        final positions = <Duration>[];
        final positionSubscription = handler.positionStream.listen(
          positions.add,
        );
        addTearDown(positionSubscription.cancel);
        outgoing.simulatedPosition = const Duration(seconds: 42);
        outgoing.emitPlayerEvent();
        await waitForFade(
          () => positions.contains(const Duration(seconds: 42)),
        );
        outgoing.isPlaying = false;
        outgoing.emitPlayerEvent();
        await waitForFade(() => !handler.snapshot.playing);
        expect(outgoing.volume, 1);
        outgoing.isPlaying = true;
        outgoing.simulatedPosition = const Duration(seconds: 175);
        outgoing.emitPlayerEvent();
        await waitForFade(() => fade(handler)['active'] == true);
        await handler.stop();
      },
    );

    test(
      'cellular handoff times out a resolver that never completes',
      () async {
        late _GatedSourceResolver resolver;
        final directory = await Directory.systemTemp.createTemp(
          'navis-handoff-timeout-',
        );
        final (handler, outgoing, database) = await createHandler(
          directory,
          3,
          crossfade: true,
          crossfadeAllowStreaming: false,
          timeouts: const NavisPlaybackTimeouts(
            load: Duration(milliseconds: 100),
          ),
          wrapResolver: (base) => resolver = _GatedSourceResolver(base),
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        final incoming = handler.debugInactiveDeck! as _ControllableAudioPlayer;
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        await waitForFade(() => incoming.playing);
        await outgoing.setVolume(0); // The outgoing fade has finished.
        resolver.blockedSongId = 'song-2';
        resolver.entered = Completer<void>();
        resolver.release = Completer<void>(); // Deliberately never released.
        var completed = false;
        unawaited(
          handler.debugCompleteCrossfade().then((_) => completed = true),
        );
        await resolver.entered!.future;
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(completed, isTrue);
        expect(fade(handler)['active'], isFalse);
        expect(
          fade(handler)['lastFailure'],
          'handoff_queue_failed:TimeoutException',
        );
        expect(handler.debugActivePlayer, same(outgoing));
        expect(outgoing.volume, 1);
        expect(outgoing.playing, isTrue);
        expect(incoming.playing, isFalse);
        expect(incoming.volume, 0);
      },
    );

    for (final failure in ['play', 'volume']) {
      test(
        'incoming $failure failure reports and falls back gaplessly',
        () async {
          final (handler, outgoing, _) = await crossfading(2);
          await handler.replaceQueue(ids(2), expandMatchFlows: false);
          final incoming =
              handler.debugInactiveDeck! as _ControllableAudioPlayer;
          incoming.failPlay = failure == 'play';
          handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
          if (failure == 'volume') {
            await waitForFade(() => incoming.playing);
            incoming.failVolume = true;
          }
          await waitForFade(() => fade(handler)['active'] == false);
          final phase = failure == 'play'
              ? 'incoming_play_failed'
              : 'fade_failed';
          expect(fade(handler)['lastFailure'], '$phase:StateError');
          expect(fade(handler)['phases'], containsPair(phase, 1));
          expect(handler.debugActivePlayer, same(outgoing));
          expect(outgoing.playing, isTrue);
          expect(outgoing.volume, 1);
          expect(incoming.playing, isFalse);
          expect(incoming.volume, 0);
        },
      );
    }

    for (final cacheType in [null, CacheType.permanent, CacheType.rolling]) {
      test(
        'cellular crossfade allows only local incoming ($cacheType)',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'navis-cellular-fade-',
          );
          final (handler, outgoing, database) = await createHandler(
            directory,
            3,
            crossfade: true,
            crossfadeAllowStreaming: false,
            sidecarStreams: true,
            seed: (database) async {
              if (cacheType == null) return;
              final file = File(p.join(directory.path, 'incoming.mp3'));
              await file.writeAsBytes([1, 2, 3]);
              await database.cacheDao.upsertCachedTrack(
                CachedTracksTableCompanion.insert(
                  songId: 'song-1',
                  filePath: file.path,
                  fileSize: 3,
                  format: 'mp3',
                  cacheType: cacheType,
                  downloadStatus: DownloadStatus.complete,
                  lastAccessedAt: DateTime.now(),
                ),
              );
            },
          );
          addTearDown(() async {
            await handler.disposeHandler();
            await database.close();
            await directory.delete(recursive: true);
          });
          await handler.replaceQueue(ids(3), expandMatchFlows: false);
          final incoming =
              handler.debugInactiveDeck! as _ControllableAudioPlayer;
          handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
          await waitForFade(
            () => incoming.playing || fade(handler)['active'] == false,
          );
          expect(outgoing.playing, isTrue);
          if (cacheType == null) {
            expect(fade(handler)['disabledReason'], 'cellular');
            expect(incoming.sourceIds, isEmpty);
            expect(fade(handler)['lastFailure'], isNull);
          } else {
            expect(fade(handler)['disabledReason'], isNull);
            expect(incoming.sourceIds, ['song-1']);
            await handler.debugCompleteCrossfade();
            expect(handler.debugActivePlayer, same(incoming));
            expect(incoming.sourceIds, ids(3));
            expect(incoming.currentIndex, 1);
            expect(incoming.playing, isTrue);
            expect(handler.snapshot.currentSongId, 'song-1');
            expectNativeMirrorsQueue(handler, incoming);
          }
        },
      );
    }

    test(
      'navigation supersedes a cellular handoff waiting to append',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-cellular-handoff-',
        );
        final (handler, outgoing, database) = await createHandler(
          directory,
          3,
          crossfade: true,
          crossfadeAllowStreaming: false,
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        final incoming = handler.debugInactiveDeck! as _ControllableAudioPlayer;
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        await waitForFade(() => incoming.playing);
        incoming.appendGate = Completer<void>();
        incoming.appendEntered = Completer<void>();
        final gate = incoming.appendGate!;
        final handoff = handler.debugCompleteCrossfade();
        await incoming.appendEntered!.future;
        await handler.playFromIndex(2);
        expect(handler.snapshot.currentSongId, 'song-2');
        gate.complete();
        await handoff;
        expect(handler.debugActivePlayer, same(outgoing));
        expect(outgoing.audibleSongId, 'song-2');
        expect(incoming.playing, isFalse);
        expect(handler.mediaItem.valueOrNull?.id, 'song-2');
        expect(fade(handler)['active'], isFalse);
      },
    );

    test('an incoming deck that never starts cannot be handed over', () async {
      final (handler, outgoing, _) = await crossfading(2);
      await handler.replaceQueue(ids(2), expandMatchFlows: false);
      final incoming = handler.debugInactiveDeck! as _ControllableAudioPlayer;
      incoming.ignorePlay = true;
      handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
      await waitForFade(() => incoming.playRequested);
      expect(outgoing.volume, 1);
      await handler.debugCompleteCrossfade();
      expect(handler.debugActivePlayer, same(outgoing));
      expect(outgoing.playing, isTrue);
      expect(fade(handler)['lastFailure'], 'incoming_not_ready:StateError');
      expect(fade(handler)['phases'], containsPair('incoming_not_ready', 1));
    });

    test(
      'fade and handoff preserve each song ReplayGain volume base',
      () async {
        final (handler, outgoing, database) = await crossfading(
          2,
          replayGainMode: 'track',
        );
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(
            id: 'song-0',
            title: 'Outgoing',
            replayGainTrackGain: const Value(0),
          ),
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Incoming',
            replayGainTrackGain: const Value(-20),
          ),
        ]);
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        await handler.setVolume(.8);
        final incoming = handler.debugInactiveDeck! as _ControllableAudioPlayer;
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        await waitForFade(() => incoming.playing && incoming.volume > 0);
        expect(outgoing.volume, lessThan(.8));
        expect(outgoing.volume, greaterThan(.4));
        expect(incoming.volume, lessThan(.08));
        await handler.debugCompleteCrossfade();
        expect(incoming.volume, closeTo(.08, .000001));
        expect(outgoing.playing, isFalse);
      },
    );

    test(
      'normal repeat one self-crossfades through multiple handoffs',
      () async {
        final scrobbles = _NoopScrobbleService();
        final (handler, player, database) = await crossfading(
          3,
          positionStreams: true,
          scrobbleService: scrobbles,
        );
        final positions = <Duration>[];
        final subscription = handler.positionStream.listen(positions.add);
        addTearDown(subscription.cancel);
        player.simulateProgress = true;
        await handler.replaceQueue(
          ids(3),
          startIndex: 1,
          expandMatchFlows: false,
        );
        await settleQueue(handler);
        await handler.setRepeatMode(AudioServiceRepeatMode.one);
        await Future<void>.delayed(Duration.zero);
        expect(scrobbles.nowPlaying, ['song-1']);
        for (var wrap = 0; wrap < 2; wrap++) {
          final outgoing =
              handler.debugActivePlayer as _ControllableAudioPlayer;
          final incoming =
              handler.debugInactiveDeck! as _ControllableAudioPlayer;
          incoming.simulateProgress = true;
          outgoing.simulatedPosition = const Duration(seconds: 175);
          outgoing.emitPlayerEvent();
          handler.debugCheckCrossfadeTrigger(outgoing.position);
          expect(fade(handler)['active'], isTrue);
          await waitForFade(() => incoming.playing);
          expect(incoming.currentIndex, 1);
          expect(incoming.playedFrom.last, Duration.zero);
          expect(incoming.sourceIds, ids(3));
          expect(incoming.loopMode, LoopMode.one);
          expect(scrobbles.nowPlaying, hasLength(wrap + 1));
          expect(scrobbles.submissions, hasLength(wrap + 1));
          // Use the existing fade timer, not the manual completion seam.
          await waitForFade(
            () =>
                identical(handler.debugActivePlayer, incoming) &&
                fade(handler)['active'] == false,
          );
          expect(outgoing.playing, isFalse);
          expect(incoming.playing, isTrue);
          expect(incoming.loopMode, LoopMode.one);
          expect(handler.snapshot.queueSongIds, ids(3));
          expect(handler.snapshot.currentIndex, 1);
          expect(handler.currentMediaItem?.id, 'song-1');
          expect(handler.snapshot.repeatMode, AudioServiceRepeatMode.one);
          expect(handler.playbackState.value.queueIndex, 1);
          expect(
            handler.playbackState.value.repeatMode,
            AudioServiceRepeatMode.one,
          );
          await Future<void>.delayed(const Duration(milliseconds: 250));
          final afterSwap = positions.last;
          expect(afterSwap, lessThan(const Duration(seconds: 8)));
          await Future<void>.delayed(const Duration(milliseconds: 350));
          expect(positions.last, greaterThan(afterSwap));
          expect(scrobbles.nowPlaying, hasLength(wrap + 2));
          await handler.debugFlushQueuePersistence();
          final saved = (await database.playQueueDao.getQueueState())!;
          expect(saved.currentIndex, 1);
          expect(saved.repeatMode, RepeatMode.one);
          expect(saved.positionMs, lessThan(8000));
          expect(
            (await database.playQueueDao.getQueueItems()).map((row) => row.id),
            ids(3),
          );
        }
        final active = handler.debugActivePlayer as _ControllableAudioPlayer;
        active.simulatedPosition = const Duration(seconds: 91);
        for (var event = 0; event < 5; event++) {
          active.emitPlayerEvent();
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(scrobbles.nowPlaying, List.filled(3, 'song-1'));
        expect(scrobbles.submissions, List.filled(3, 'song-1'));
        expect(scrobbles.nowPlayingSessions.toSet(), hasLength(3));
        expect(scrobbles.submissionSessions, scrobbles.nowPlayingSessions);
        expect(
          await database.select(database.playHistoryTable).get(),
          hasLength(3),
        );
        expect(fade(handler)['phases'], containsPair('completed', 2));
      },
    );

    test('self-crossfade waits for a pending seek to settle', () async {
      final (handler, player, _) = await crossfading(2, positionStreams: true);
      player.simulateProgress = true;
      await handler.replaceQueue(ids(2), expandMatchFlows: false);
      await handler.setRepeatMode(AudioServiceRepeatMode.one);
      final entered = Completer<void>();
      final release = Completer<void>();
      player
        ..seekGate = release
        ..seekEntered = entered;
      final seeking = handler.seek(const Duration(seconds: 175));
      await entered.future;
      try {
        // just_audio can publish an optimistic position while native seek
        // confirmation is pending; that must not start a second deck.
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        expect(fade(handler)['active'], isFalse);
      } finally {
        release.complete();
        await seeking;
      }
      expect(handler.snapshot.pendingSeekPosition, isNull);
      handler.debugCheckCrossfadeTrigger(player.position);
      expect(fade(handler)['active'], isTrue);
      await waitForFade(() => handler.debugInactiveDeck!.playing);
      await handler.debugCompleteCrossfade();
      expect(handler.snapshot.pendingSeekPosition, isNull);
      expect(handler.debugActivePlayer.loopMode, LoopMode.one);
    });

    test('self-crossfade deducts preparation from its boundary wait', () async {
      final (handler, player, _) = await crossfading(2);
      await handler.replaceQueue(ids(2), expandMatchFlows: false);
      await handler.setRepeatMode(AudioServiceRepeatMode.one);
      final incoming = handler.debugInactiveDeck! as _ControllableAudioPlayer;
      final entered = Completer<void>();
      final release = Completer<void>();
      incoming
        ..loadGate = release
        ..loadEntered = entered;
      player.simulatedPosition = const Duration(seconds: 174);
      handler.debugCheckCrossfadeTrigger(player.position);
      await entered.future.timeout(const Duration(seconds: 1));
      // Native playback progressed 900 ms while the deck prepared.
      player
        ..simulateProgress = true
        ..simulatedPosition = const Duration(seconds: 174, milliseconds: 900);
      final elapsed = Stopwatch()..start();
      release.complete();
      await waitForFade(() => incoming.playing);
      expect(elapsed.elapsed, lessThan(const Duration(milliseconds: 600)));
      expect(
        player.position,
        greaterThanOrEqualTo(const Duration(seconds: 175)),
      );
      await handler.debugCompleteCrossfade();
      expect(handler.debugActivePlayer, same(incoming));
    });

    test('self-crossfade retries after a native wrap during prewarm', () async {
      final (handler, player, _) = await crossfading(2);
      await handler.replaceQueue(ids(2), expandMatchFlows: false);
      await handler.setRepeatMode(AudioServiceRepeatMode.one);
      final incoming = handler.debugInactiveDeck! as _ControllableAudioPlayer;
      final entered = Completer<void>();
      final release = Completer<void>();
      incoming
        ..loadGate = release
        ..loadEntered = entered;
      player.simulatedPosition = const Duration(seconds: 175);
      handler.debugCheckCrossfadeTrigger(player.position);
      await entered.future;
      player.simulatedPosition = const Duration(seconds: 1);
      release.complete();
      await waitForFade(() => fade(handler)['active'] == false);
      expect(handler.debugActivePlayer, same(player));
      expect(incoming.playing, isFalse);
      expect(fade(handler)['phases'], isNot(contains('prewarm_failed')));
      player.simulatedPosition = const Duration(seconds: 175);
      handler.debugCheckCrossfadeTrigger(player.position);
      expect(fade(handler)['active'], isTrue);
      await waitForFade(() => incoming.playing);
      await handler.debugCompleteCrossfade();
      expect(handler.debugActivePlayer, same(incoming));
      expect(handler.snapshot.queueSongIds, ids(2));
    });

    test(
      'smart repeat one never crossfades even without album metadata',
      () async {
        final (handler, player, _) = await crossfading(
          3,
          positionStreams: true,
          crossfadeType: 'smart',
        );
        player.simulateProgress = true;
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        await handler.setRepeatMode(AudioServiceRepeatMode.one);
        final positions = <Duration>[];
        final subscription = handler.positionStream.listen(positions.add);
        addTearDown(subscription.cancel);
        for (var wrap = 0; wrap < 2; wrap++) {
          player.simulatedPosition = const Duration(seconds: 175);
          player.emitPlayerEvent();
          handler.debugCheckCrossfadeTrigger(player.position);
          await Future<void>.delayed(const Duration(milliseconds: 350));
          expect(fade(handler)['active'], isFalse);
          expect(handler.debugInactiveDeck!.playing, isFalse);
          player.simulatedPosition = Duration.zero;
          player.emitPlayerEvent();
          await Future<void>.delayed(const Duration(milliseconds: 350));
          expect(positions.last, lessThan(const Duration(seconds: 1)));
          final before = positions.last;
          await Future<void>.delayed(const Duration(milliseconds: 350));
          expect(positions.last, greaterThan(before));
        }
        expect(handler.debugActivePlayer, same(player));
        expect(handler.snapshot.queueSongIds, ids(3));
        expect(fade(handler)['phases'], isNot(contains('completed')));
      },
    );

    for (final seconds in [9, 10]) {
      test(
        'normal repeat one minimum length is twice the fade ($seconds s)',
        () async {
          final (handler, player, _) = await crossfading(1);
          player.simulatedDuration = Duration(seconds: seconds);
          await handler.replaceQueue(ids(1), expandMatchFlows: false);
          await handler.setRepeatMode(AudioServiceRepeatMode.one);
          player.simulatedPosition = Duration(seconds: seconds - 5);
          handler.debugCheckCrossfadeTrigger(player.position);
          expect(fade(handler)['active'], seconds >= 10);
          if (seconds >= 10) {
            await waitForFade(() => handler.debugInactiveDeck!.playing);
            await handler.debugCompleteCrossfade();
            expect(handler.snapshot.queueSongIds, ids(1));
            expect(handler.debugActivePlayer.loopMode, LoopMode.one);
          }
        },
      );
    }

    for (final type in ['normal', 'smart']) {
      for (final repeat in [
        AudioServiceRepeatMode.none,
        AudioServiceRepeatMode.all,
      ]) {
        for (final index in [0, 1]) {
          test(
            'crossfade keeps $type $repeat next index from $index',
            () async {
              final (handler, player, _) = await crossfading(
                2,
                crossfadeType: type,
              );
              await handler.replaceQueue(
                ids(2),
                startIndex: index,
                expandMatchFlows: false,
              );
              await handler.setRepeatMode(repeat);
              handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
              final target = index == 0
                  ? 1
                  : repeat == AudioServiceRepeatMode.all
                  ? 0
                  : null;
              expect(fade(handler)['active'], target != null);
              if (target != null) {
                final incoming = handler.debugInactiveDeck!;
                await waitForFade(() => incoming.playing);
                expect(incoming.currentIndex, target);
                await handler.debugCompleteCrossfade();
                expect(handler.debugActivePlayer, same(incoming));
                expect(handler.snapshot.currentIndex, target);
                expect(handler.snapshot.repeatMode, repeat);
              } else {
                expect(handler.debugActivePlayer, same(player));
              }
              expect(handler.snapshot.queueSongIds, ids(2));
            },
          );
        }
      }
    }

    for (final change in ['repeat', 'smart']) {
      test('self-crossfade cancels when policy changes to $change', () async {
        var type = 'normal';
        final (handler, player, _) = await crossfading(
          2,
          readCrossfadeType: () => type,
        );
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        await handler.setRepeatMode(AudioServiceRepeatMode.one);
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        expect(fade(handler)['active'], isTrue);
        final incoming = handler.debugInactiveDeck!;
        await waitForFade(() => incoming.playing);
        if (change == 'repeat') {
          await handler.setRepeatMode(AudioServiceRepeatMode.none);
        } else {
          type = 'smart';
          await handler.applyRuntimeSettings();
        }
        expect(fade(handler)['active'], isFalse);
        expect(handler.debugActivePlayer, same(player));
        expect(player.playing, isTrue);
        expect(incoming.playing, isFalse);
      });
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

  group('repeat one timeline', () {
    for (final crossfade in [false, true]) {
      test('paused initial snapshot cannot retain a settled seek target, '
          'fade=$crossfade', () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-timeline-',
        );
        final (handler, player, database) = await createHandler(
          directory,
          3,
          crossfade: crossfade,
          positionStreams: true,
        );
        final container = ProviderContainer(
          overrides: [audioHandlerProvider.overrideWithValue(handler)],
        );
        addTearDown(() async {
          container.dispose();
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        player.simulateProgress = true;
        await handler.replaceQueue([
          'song-0',
          'song-1',
          'song-2',
        ], expandMatchFlows: false);
        await handler.setRepeatMode(AudioServiceRepeatMode.one);
        await settleQueue(handler);
        container.listen(playbackPositionProvider, (_, _) {});
        final seeking = handler.seek(const Duration(seconds: 166));
        final initial = Completer<void>();
        late ProviderSubscription<AsyncValue<PlaybackSnapshot>> subscription;
        subscription = container.listen(playbackSnapshotProvider, (_, next) {
          if (!initial.isCompleted &&
              next.asData?.value.pendingSeekPosition != null) {
            // Riverpod pauses the source when its last visible listener pauses.
            // Pause at the initial yield, before the live broadcast is attached.
            subscription.pause();
            initial.complete();
          }
        });
        await initial.future;
        await seeking;
        expect(handler.snapshot.pendingSeekPosition, isNull);
        expect(
          (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
          'completed',
        );
        subscription.resume();
        await Future<void>.delayed(const Duration(milliseconds: 350));

        final before = container.read(playbackPositionProvider).requireValue;
        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect(
          container.read(playbackPositionProvider).requireValue,
          greaterThan(before),
        );
        player.simulatedPosition = const Duration(seconds: 1);
        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect(
          container.read(playbackPositionProvider).requireValue,
          lessThan(const Duration(seconds: 2)),
        );
        expect(container.read(playerStateProvider).pendingSeekPosition, isNull);
      });
    }

    for (final crossfade in [false, true]) {
      for (final recovery in [false, true]) {
        test('seek, skip and native wrap keep provider position moving, '
            'fade=$crossfade recovery=$recovery', () async {
          final directory = await Directory.systemTemp.createTemp(
            'navis-timeline-',
          );
          final (handler, player, database) = await createHandler(
            directory,
            3,
            crossfade: crossfade,
            positionStreams: true,
            rebuiltPlayers: <_ControllableAudioPlayer>[],
            timeouts: const NavisPlaybackTimeouts(
              control: Duration(milliseconds: 100),
              reset: Duration(milliseconds: 150),
              load: Duration(seconds: 2),
            ),
          );
          final container = ProviderContainer(
            overrides: [audioHandlerProvider.overrideWithValue(handler)],
          );
          addTearDown(() async {
            container.dispose();
            await handler.disposeHandler();
            await database.close();
            await directory.delete(recursive: true);
          });
          final displayedPosition = Provider<Duration>((ref) {
            final snapshot = ref.watch(playerStateProvider);
            return snapshot.pendingSeekPosition ??
                ref.watch(playbackPositionProvider).asData?.value ??
                snapshot.position;
          });
          container.listen(displayedPosition, (_, _) {});
          final snapshots = <PlaybackSnapshot>[];
          container.listen(playbackSnapshotProvider, (_, next) {
            if (next.asData case final data?) snapshots.add(data.value);
          });

          player.simulateProgress = true;
          await handler.replaceQueue([
            'song-0',
            'song-1',
            'song-2',
          ], expandMatchFlows: false);
          await handler.setRepeatMode(AudioServiceRepeatMode.one);
          await handler.skipToNext();
          await settleQueue(handler);
          expect(player.index, 1);
          await Future<void>.delayed(const Duration(milliseconds: 250));
          final afterNext = container
              .read(playbackPositionProvider)
              .requireValue;
          await Future<void>.delayed(const Duration(milliseconds: 350));
          expect(container.read(displayedPosition), greaterThan(afterNext));
          if (recovery) player.hang.add('seek');
          final seeking = handler.seek(const Duration(minutes: 2, seconds: 46));
          expect(
            handler.snapshot.pendingSeekPosition,
            const Duration(minutes: 2, seconds: 46),
          );
          await seeking;
          await Future<void>.delayed(const Duration(milliseconds: 350));
          expect(snapshots.last.pendingSeekPosition, isNull);
          final active = handler.debugActivePlayer as _ControllableAudioPlayer;
          expect(identical(active, player), !recovery);
          expect(active.loopMode, LoopMode.one);
          expect(
            (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
            'completed',
          );
          expect(active.position, greaterThan(const Duration(seconds: 166)));
          expect(active.position, lessThan(const Duration(seconds: 170)));
          final first = container.read(playbackPositionProvider).requireValue;
          await Future<void>.delayed(const Duration(milliseconds: 350));
          final second = container.read(playbackPositionProvider).requireValue;
          expect(second, greaterThan(first));
          expect(container.read(displayedPosition), second);
          expect(fade(handler)['active'], isFalse);
          // Native loop-one changes position without changing queue occurrence.
          active.simulatedPosition = const Duration(seconds: 1);
          // Keep the same PlayerEvent: progress must not need another event
          // to rearm its timer after seek settlement or a loop wrap.
          await Future<void>.delayed(const Duration(milliseconds: 350));
          final wrapped = container.read(playbackPositionProvider).requireValue;
          expect(wrapped, lessThan(const Duration(seconds: 2)));
          expect(handler.snapshot.currentSongId, 'song-1');
          expect(handler.snapshot.currentIndex, 1);
          expect(handler.snapshot.queueSongIds, ['song-0', 'song-1', 'song-2']);
          await Future<void>.delayed(const Duration(milliseconds: 350));
          expect(
            container.read(playbackPositionProvider).requireValue,
            greaterThan(wrapped),
          );
          await handler.skipToPrevious();
          await settleQueue(handler);
          expect(active.index, 0);
          await Future<void>.delayed(const Duration(milliseconds: 250));
          final afterSkip = container
              .read(playbackPositionProvider)
              .requireValue;
          await Future<void>.delayed(const Duration(milliseconds: 350));
          expect(
            container.read(playbackPositionProvider).requireValue,
            greaterThan(afterSkip),
          );
          expect(handler.snapshot.pendingSeekPosition, isNull);
          expect(handler.snapshot.repeatMode, AudioServiceRepeatMode.one);
        });
      }
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
        player.state = ProcessingState.buffering; // A stall.
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
        player.state = ProcessingState.buffering; // A stall.
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
      player.state = ProcessingState.buffering; // A stall.
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

        player.state = ProcessingState.buffering; // A stall.
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

        player.state = ProcessingState.buffering; // A stall.
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
        // Queue fill owns the selected source; recovery must wait for it.
        expect(events, isEmpty);
      });
    }

    test(
      'a stalled song waits for queue fill before retrying and moving on',
      () async {
        final (handler, player, _) = await recovering(6);
        final gate = await fillHeldOpen(handler, player, 6, startIndex: 0);
        player.failLoadSongId = 'song-0';

        player.state = ProcessingState.buffering; // A stall.
        final recovery = handler.debugRecoverCurrentSong();
        gate.complete();
        await recovery;
        await settleQueue(handler);
        expect(handler.snapshot.currentSongId, 'song-0');
        expect(handler.collectPlaybackDiagnostics()['seekEvents'], isEmpty);
        player.state = ProcessingState.buffering; // A stall.
        await handler.debugRecoverCurrentSong();

        await until(
          () =>
              handler.snapshot.currentSongId == 'song-1' &&
              !handler.snapshot.isLoading,
        );
        expect(handler.snapshot.queueSongIds, ids(6));
      },
    );

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

      player.state = ProcessingState.buffering; // A stall.
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
    test('timed-out explicit saved queue preparation cannot change a newer selection '
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
      await handler.waitUntilReady();
      await handler.debugWaitForStartupQueueRestore();
      expect(initialPlayer.sequence, isEmpty);
      final preparing = handler.prepare();
      await entered.future.timeout(const Duration(seconds: 5));
      await preparing.timeout(const Duration(seconds: 30));
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

    test('restores a reconfirmed song after the library rebuild', () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-rebuilt-queue-restore-',
      );
      final api = createApiClient();
      final (handler, player, database) = await createHandler(
        directory,
        1,
        savedQueueIndex: 0,
        cacheSongs: false,
        readApiClient: () => api,
        seed: (database) async {
          final repository = await seedSyncSession(database);
          await database.libraryDao.clearLibraryData();
          const album = models.Album(
            id: 'album',
            name: 'Album',
            songCount: 1,
            songs: [
              models.Song(
                id: 'song-0',
                title: 'Reconfirmed song',
                albumId: 'album',
              ),
            ],
          );
          final syncApi = FakeLibrarySyncApi()
            ..fastPathPages[0] = [album]
            ..albumDetails['album'] = album;
          final result = await serialDriftEngine(
            api: syncApi,
            database: database,
            repository: repository,
          ).executeSyncPlan(syncPlanForTest(LibrarySyncPlanKind.fullRepair));
          expect(result.freshness, LibrarySyncFreshness.current);
        },
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      expect(restoreOutcome(handler), 'restored');
      expect(handler.snapshot.queueSongIds, ['song-0']);
      expect(handler.snapshot.currentIndex, 0);
      expect(handler.mediaItem.value?.title, 'Reconfirmed song');
      expect(player.isPlaying, isFalse);
      expect(await database.playQueueDao.getQueueItems(), hasLength(1));
    });

    test(
      'publishes paused metadata before the session becomes available',
      () async {
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

        expect(restoreOutcome(handler), 'restored');
        expect(handler.snapshot.queueSongIds, ['song-0', 'song-1', 'song-2']);
        expect(player.sequence, isEmpty);

        // Still no session: the retry defers again and keeps the saved queue.
        await handler.retryDeferredQueueRestore();
        expect(restoreOutcome(handler), 'restored');
        expect(handler.snapshot.queueSongIds, ['song-0', 'song-1', 'song-2']);
        expect(player.sequence, isEmpty);

        api = createApiClient();
        await handler.prepare();

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
      },
    );

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
      expect(restoreOutcome(handler), 'restored');

      api = createApiClient();
      // The session arrives together with the user's own selection.
      final retry = handler.retryDeferredQueueRestore();
      final userQueue = handler.replaceQueue([
        'song-2',
      ], expandMatchFlows: false);
      await Future.wait([retry, userQueue]);
      await handler.retryDeferredQueueRestore();

      expect(handler.snapshot.queueSongIds, ['song-2']);
      expect(handler.snapshot.queueSongIds, ['song-2']);
      expect(player.isPlaying, isTrue);
    });

    test(
      'restores offline metadata and streams only after explicit Play',
      () async {
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
        expect(restoreOutcome(handler), 'restored');
        expect(player.sequence, isEmpty);
        expect(handler.snapshot.currentIndex, 1);

        online = true;
        await handler.play();

        expect(restoreOutcome(handler), 'restored');
        expect(handler.snapshot.queueSongIds, ['song-0', 'song-1']);
        expect(handler.snapshot.currentIndex, 1);
        expect(player.isPlaying, isTrue);
      },
    );
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
      if (handler.snapshot.isLoading) {
        await handler.snapshotStream.firstWhere(
          (snapshot) => !snapshot.isLoading,
        );
      }
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
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      Completer<void>? warmEntered;
      Completer<void>? warmGate;
      server.listen((request) async {
        final gate = warmGate;
        if (gate != null) {
          if (warmEntered case final entered? when !entered.isCompleted) {
            entered.complete();
          }
          await gate.future;
        }
        try {
          request.response
            ..contentLength = 2
            ..add([1, 2]);
          await request.response.close();
        } on HttpException {
          // Navigation may supersede a warm-up probe.
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
      addTearDown(() async {
        if (warmGate case final gate? when !gate.isCompleted) gate.complete();
        await server.close(force: true);
        HttpOverrides.global = previousHttp;
      });
      final directory = await Directory.systemTemp.createTemp('navis-model-');
      addTearDown(() => directory.delete(recursive: true));
      for (var seed = 0; seed < seeds; seed++) {
        final random = Random(seed);
        final players = <_ControllableAudioPlayer>[];
        final (handler, player, database) = await createHandler(
          directory,
          songCount,
          queueWindow: tiny,
          players: players,
          readApiClient: () => api,
        );
        final invariant = watchAudioMetadata(handler, players);
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
            expectAudioMatchesMetadata(handler, players, settled: true);
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
            switch (random.nextInt(10)) {
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
              case 9:
                final cold = seed % 10 == 0;
                log.add('replace shuffled rows external cold=$cold');
                final ids = List<String>.generate(20, (i) => 'song-$i');
                final rows = await database.libraryDao.getSongsByIds(ids);
                rows[1] = rows[1].copyWith(
                  id: cold ? 'cold-model-$seed-$step' : rows[1].id,
                  isExternal: true,
                );
                if (cold) {
                  await database.libraryDao.upsertSongs([
                    SongsTableCompanion.insert(
                      id: rows[1].id,
                      title: rows[1].title,
                      isExternal: const Value(true),
                    ),
                  ]);
                }
                final original = rows.map((song) => song.id).toList();
                rows.shuffle(Random(seed * steps + step));
                // A cold external selection tests the same first-byte gate as
                // entity Shuffle while the model continues editing its queue.
                if (cold) {
                  final remote = rows.indexWhere((song) => song.isExternal);
                  rows.insert(0, rows.removeAt(remote));
                  warmEntered = Completer<void>();
                  warmGate = Completer<void>();
                }
                final replacing = handler.replaceQueueWithData(
                  rows,
                  originalOrder: original,
                  expandMatchFlows: false,
                );
                if (cold) {
                  await warmEntered!.future;
                  expectAudioMatchesMetadata(
                    handler,
                    players,
                    previousSongId: model[current],
                  );
                  warmGate!.complete();
                  warmGate = null;
                }
                await replacing;
                model = rows.map((song) => song.id).toList();
                current = 0;
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
          await invariant();
        } finally {
          handler.debugSnapshotObserver = null;
          await handler.disposeHandler();
          await database.close();
        }
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
