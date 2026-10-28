import 'package:navis/src/features/cache/data/rolling_cache_sidecar_downloader.dart';

import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:rxdart/rxdart.dart';
import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        debugDefaultTargetPlatformOverride,
        debugPrint,
        listEquals,
        visibleForTesting;

import 'package:navis/src/features/player/domain/playback_adjustments.dart';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:navis/src/features/player/data/playback_art_cache.dart';
import 'package:navis/src/features/player/data/android_system_art.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:navis/src/utils/constants.dart';
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
import 'package:navis/src/features/player/data/lock_cache_follower_source.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/data/playback_transport_trace.dart';
import 'package:navis/src/features/player/data/real_time_projection_audio_handler.dart';
import 'package:navis/src/features/player/data/scrobble_service.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/domain/streaming_quality.dart';

import '../../../../helpers/cached_audio_builders.dart';
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

class _GatedQueueEntriesDao extends PlayQueueDao {
  new(super.attachedDatabase, this.release);
  final Future<void> release;

  @override
  Future<List<({SongsTableData song, int? originalOrder})>>
  getQueueEntries() async {
    await release;
    return super.getQueueEntries();
  }
}

class _GatedSourceResolver extends Fake implements PlaybackSourceResolver {
  new(this.delegate);
  final PlaybackSourceResolver delegate;
  String? blockedSongId;
  StateError? failure;
  bool rejectBridge = false;
  Completer<void>? entered;
  Completer<void>? release;

  @override
  Uri? resolveArtUri(SongsTableData song) => delegate.resolveArtUri(song);

  @override
  PlaybackTransportTrace? get transportTrace => delegate.transportTrace;
  @override
  bool get supportsTranscodeOffset => delegate.supportsTranscodeOffset;
  @override
  Object get seekPreviewRepresentation =>
      previewRepresentation ?? delegate.seekPreviewRepresentation;

  Object? previewRepresentation;

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
    if (fastSeekBridge && rejectBridge) throw StateError('bridge unavailable');
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
      transcodeOffset: transcodeOffset,
      fastSeekBridge: fastSeekBridge,
    );
  }
}

// ignore: experimental_member_use, reason: exercises the mobile lock-cache owner.
class _RangeCacheSource extends LockCachingAudioSource {
  new(String id, File file)
    : super(Uri.parse('https://fixture.invalid/song?id=$id'), cacheFile: file);
  bool activeRange = false;
  bool paused = false;
  int receivedRangeBytes = 0;
  final progress = BehaviorSubject<double>.seeded(0);
  @override
  Stream<double> get downloadProgressStream => progress.stream;
  @override
  int get downloadedBytes => 0;
  @override
  bool get originSupportsRangeRequests => true;
  @override
  bool get hasActiveRangeFetch => activeRange;
  @override
  int get rangeFetchBytes => receivedRangeBytes;
  @override
  void pauseDownload() => paused = true;
  @override
  void resumeDownload() => paused = false;
  @override
  Future<void> cancelDownload() async {
    activeRange = false;
    resumeDownload();
  }
}

// ignore: experimental_member_use, reason: a range-fetch stand-in whose warm is observable.
class _WarmRangeSource extends _RangeCacheSource {
  new(super.id, super.file);
  bool warmed = false;
  @override
  Future<void> prefetch() async => warmed = true;
}

// ignore: experimental_member_use, reason: as above.
class _OutOfOrderResolver extends _GatedSourceResolver {
  new(super.delegate);
  var calls = 0;
  final secondDone = Completer<void>();
  @override
  Future<ResolvedPlaybackSource> resolveForSong(
    SongsTableData song, {
    bool preferLockCaching = true,
    bool allowStreaming = true,
    Duration? transcodeOffset,
    bool fastSeekBridge = false,
  }) async {
    // The first occurrence of song-1 resolves after the second one.
    final first = song.id == 'song-1' && ++calls == 1;
    if (first) await secondDone.future;
    final resolved = await delegate.resolveForSong(
      song,
      preferLockCaching: preferLockCaching,
      allowStreaming: allowStreaming,
      transcodeOffset: transcodeOffset,
      fastSeekBridge: fastSeekBridge,
    );
    if (song.id == 'song-1' && !first) secondDone.complete();
    return resolved;
  }
}

class _FreshRangeResolver extends _GatedSourceResolver {
  new(super.delegate, this.directory, this.created);
  final Directory directory;
  final List<_WarmRangeSource> created;
  @override
  Future<ResolvedPlaybackSource> resolveForSong(
    SongsTableData song, {
    bool preferLockCaching = true,
    bool allowStreaming = true,
    Duration? transcodeOffset,
    bool fastSeekBridge = false,
  }) async {
    final source = _WarmRangeSource(
      song.id,
      File('${directory.path}/${song.id}.mp3'),
    );
    if (!preferLockCaching) {
      return ResolvedPlaybackSource.directStream(
        songId: song.id,
        uri: source.uri,
        metadata: const ResolvedPlaybackMetadata(isTranscoded: false),
      );
    }
    created.add(source);
    return ResolvedPlaybackSource.lockCachedStream(
      songId: song.id,
      lockCachingStreamUri: source.uri,
      lockCachingAudioSource: source,
      cachedFilePath: (await source.cacheFile).path,
      metadata: const ResolvedPlaybackMetadata(isTranscoded: false),
    );
  }
}

class _SlowDisposeDownloader extends RollingCacheSidecarDownloader {
  _SlowDisposeDownloader(this.gate);
  final Completer<void> gate;
  @override
  Future<void> dispose() async {
    await gate.future;
    await super.dispose();
  }
}

class _RangeCacheResolver extends _GatedSourceResolver {
  new(super.delegate, this.sources);
  final Map<String, _RangeCacheSource> sources;
  @override
  Future<ResolvedPlaybackSource> resolveForSong(
    SongsTableData song, {
    bool preferLockCaching = true,
    bool allowStreaming = true,
    Duration? transcodeOffset,
    bool fastSeekBridge = false,
  }) async {
    final source = sources[song.id]!;
    if (!preferLockCaching) {
      return ResolvedPlaybackSource.directStream(
        songId: song.id,
        uri: source.uri,
        metadata: const ResolvedPlaybackMetadata(isTranscoded: false),
      );
    }
    return ResolvedPlaybackSource.lockCachedStream(
      songId: song.id,
      lockCachingStreamUri: source.uri,
      lockCachingAudioSource: source,
      cachedFilePath: (await source.cacheFile).path,
      metadata: const ResolvedPlaybackMetadata(isTranscoded: false),
    );
  }
}

/// Lock-cached streams of a server transcode (what the seek planners check).
class _TranscodedLockResolver extends _GatedSourceResolver {
  new(super.delegate);
  @override
  Future<ResolvedPlaybackSource> resolveForSong(
    SongsTableData song, {
    bool preferLockCaching = true,
    bool allowStreaming = true,
    Duration? transcodeOffset,
    bool fastSeekBridge = false,
  }) async {
    final source = await super.resolveForSong(
      song,
      preferLockCaching: preferLockCaching,
      allowStreaming: allowStreaming,
      transcodeOffset: transcodeOffset,
      fastSeekBridge: fastSeekBridge,
    );
    if (transcodeOffset != null &&
        source.kind == PlaybackSourceKind.directStream) {
      // The seek preview's transcode that starts at the offset.
      return ResolvedPlaybackSource.directStream(
        songId: song.id,
        uri: source.uri!.replace(
          queryParameters: {
            ...source.uri!.queryParameters,
            'timeOffset': '${transcodeOffset.inSeconds}',
          },
        ),
        metadata: const ResolvedPlaybackMetadata(isTranscoded: true),
        positionOffset: Duration(seconds: transcodeOffset.inSeconds),
      );
    }
    if (source.kind != PlaybackSourceKind.lockCachedStream) return source;
    return ResolvedPlaybackSource.lockCachedStream(
      songId: song.id,
      lockCachingStreamUri: source.lockCachingStreamUri!,
      lockCachingAudioSource: source.lockCachingAudioSource!,
      cachedFilePath: source.cachedFilePath!,
      metadata: const ResolvedPlaybackMetadata(isTranscoded: true),
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

class _JpegResponse implements FileServiceResponse {
  @override
  Stream<List<int>> get content =>
      Stream.value(<int>[0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 5, 6, 7, 8]);
  @override
  int? get contentLength => 12;
  @override
  int get statusCode => 200;
  @override
  DateTime get validTill => DateTime.now().add(const Duration(days: 1));
  @override
  String? get eTag => null;
  @override
  String get fileExtension => '.jpg';
}

class _JpegArtworkService extends Fake implements CoverArtHttpFileService {
  int gets = 0;
  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    gets++;
    return _JpegResponse();
  }

  @override
  void close({bool force = false}) {}
}

class _TeardownArtworkService extends Fake implements CoverArtHttpFileService {
  bool closed = false;

  @override
  void close({bool force = false}) {
    closed = true;
  }
}

class _SeekPreviewHttpClient extends Fake implements HttpClient {
  final body = StreamController<List<int>>();
  final headers = Completer<HttpClientResponse>();
  bool closed = false;
  int gets = 0;
  @override
  String? userAgent;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    gets++;
    return _SeekPreviewHttpRequest(headers.future);
  }

  void respond() {
    if (!headers.isCompleted) {
      headers.complete(_SeekPreviewHttpResponse(body.stream));
    }
  }

  @override
  void close({bool force = false}) {
    closed = force;
  }
}

class _SeekPreviewHttpRequest extends Fake implements HttpClientRequest {
  new(this.response);
  final Future<HttpClientResponse> response;
  @override
  Future<HttpClientResponse> close() => response;
}

class _SeekPreviewHttpResponse extends Fake implements HttpClientResponse {
  new(this.body);
  final Stream<List<int>> body;
  @override
  int get statusCode => 200;
  @override
  int get contentLength => -1;
  @override
  HttpHeaders get headers => _SeekPreviewHttpHeaders();
  @override
  Stream<E> asyncExpand<E>(Stream<E>? Function(List<int>) convert) =>
      body.asyncExpand(convert);
}

class _SeekPreviewHttpHeaders extends Fake implements HttpHeaders {
  @override
  ContentType? get contentType => ContentType('audio', 'ogg');
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

class _BridgeSidecar extends RollingCacheSidecarDownloader {
  String? song;
  String? path;
  int bytes = 65536;
  double? rate = 10000;
  int starts = 0;
  bool paused = false;
  Future<void> Function(File)? complete;
  void Function(double)? progress;
  void Function()? terminated;
  Uri? downloadUri;
  @override
  String? get activeSongId => song;
  @override
  int? get activeReceivedBytes => song == null ? null : bytes;
  @override
  double? get activeBytesPerSecond => rate;
  @override
  bool get isPaused => paused;
  @override
  void pause() {
    if (song != null) paused = true;
  }

  @override
  void resume() {
    paused = false;
  }

  @override
  Future<void> cancel() async {
    resume();
    song = null;
    terminated?.call();
  }

  @override
  Future<void> start({
    required String songId,
    required Uri uri,
    required String cacheFilePath,
    required void Function(double) onProgress,
    required Future<void> Function(File) onComplete,
    required void Function() onTerminated,
    bool isTranscoded = false,
  }) async {
    if (song == songId && path == cacheFilePath) return;
    starts++;
    song = songId;
    path = cacheFilePath;
    downloadUri = uri;
    complete = onComplete;
    progress = onProgress;
    terminated = onTerminated;
    onProgress(.1);
  }

  Future<void> finish() async {
    final file = File(path!);
    await file.writeAsBytes(List<int>.filled(bytes, 1));
    progress!(1);
    await complete!(file);
    song = null;
    resume();
    terminated!();
  }
}

class _ControllableAudioPlayer extends Fake implements AudioPlayer {
  final StreamController<int?> _indices = StreamController<int?>.broadcast();
  final _events = StreamController<PlaybackEvent>.broadcast();
  final _discontinuities = StreamController<PositionDiscontinuity>.broadcast();
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
  bool rejectNextSeek = false;
  bool rejectBridgeLoad = false;
  final bridgeInitialPositions = <Duration?>[];

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

  /// Every volume write waits for this, as a slow native write would.
  Completer<void>? volumeHold;
  Completer<void>? listenerCancelGate;
  Completer<void>? listenerCancelEntered;
  String? failAppendSongId;

  /// A load whose first song is this one fails, as a broken source would.
  String? failLoadSongId;
  Set<String> hungLoadSongs = <String>{};
  Set<AudioSource>? claimedSources;
  Completer<void>? replacementLoadGate;
  Completer<void>? stopGate;
  int stopGateFrom = 0;
  bool Function()? pauseGateWhen;
  Completer<void>? stopEntered;

  /// Every stop from this call number on never completes.
  int? hangStopsFrom;
  Completer<void>? seekGate;
  Completer<void>? seekEntered;
  bool gateNonEmptyLoadsOnly = false;
  bool bufferAfterLoad = false;
  Completer<void>? loadGate;
  Completer<void>? loadEntered;
  StateError? blockedLoadError;
  Completer<void>? appendGate;
  Completer<void>? appendEntered;
  Completer<void>? afterAppendGate;
  Completer<void>? afterAppendEntered;
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

  /// A native failure, kept until the next load as on Android.
  int? errorCode;

  /// Loads succeed and then fail at once, as a stream that drops.
  bool failAfterLoad = false;
  StateError? loadErrorAfterApply;

  @override
  PlaybackEvent get playbackEvent => PlaybackEvent(
    processingState: state,
    updatePosition: nativePositionFrozen ? simulatedPosition : position,
    bufferedPosition: bufferedPosition,
    duration: duration,
    currentIndex: index,
    errorCode: errorCode,
    errorMessage: errorCode == null ? null : 'Source error',
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
  Stream<PositionDiscontinuity> get positionDiscontinuityStream =>
      _discontinuities.stream;

  @override
  Stream<bool> get shuffleModeEnabledStream => const Stream<bool>.empty();

  @override
  Stream<LoopMode> get loopModeStream => const Stream<LoopMode>.empty();

  final _bufferedPositions = StreamController<Duration>.broadcast();

  /// Sets the native buffered position and announces it, as the player does.
  void emitBuffered(Duration value) {
    simulatedBuffered = value;
    _bufferedPositions.add(value);
  }

  @override
  Stream<Duration> get bufferedPositionStream => _bufferedPositions.stream;

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
    await volumeHold?.future;
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

  bool emitQueueEditDiscontinuity = false;

  Future<void> _emitQueueEditDiscontinuity(PlaybackEvent before) async {
    if (!emitQueueEditDiscontinuity) return;
    _discontinuities.add(
      PositionDiscontinuity(
        PositionDiscontinuityReason.autoAdvance,
        before,
        playbackEvent,
      ),
    );
    _indices.add(index);
    _events.add(playbackEvent);
    await pumpEventQueue(times: 5);
  }

  int rangeRemovals = 0;
  Completer<void>? removeGate;
  Completer<void>? removeEntered;

  @override
  Future<void> removeAudioSourceAt(int index) => _mutate(() async {
    await _hangIf('removeAudioSourceAt');
    final gate = removeGate;
    removeGate = null;
    if (gate != null) {
      removeEntered?.complete();
      await gate.future;
    }
    final before = playbackEvent;
    _sources.removeAt(index);
    if (this.index != null && index < this.index!) this.index = this.index! - 1;
    if (emitQueueEditDiscontinuity && before.currentIndex == index) {
      simulatedPosition = Duration.zero;
    }
    await _emitQueueEditDiscontinuity(before);
  });

  @override
  Future<void> removeAudioSourceRange(int start, int end) => _mutate(() async {
    await _hangIf('removeAudioSourceRange');
    final gate = removeGate;
    removeGate = null;
    if (gate != null) {
      removeEntered?.complete();
      await gate.future;
    }
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

  /// A native end-of-track transition, including the player's loop policy.
  void finishCurrentTrack({
    Duration? endPosition,
    bool discontinuityFirst = false,
  }) {
    if (endPosition != null) simulatedPosition = endPosition;
    final before = playbackEvent;
    final next = index! + 1;
    if (appliedLoopMode == LoopMode.one) {
      // A looped offset stream restarts at its own start, which is song time
      // equal to its offset.
      final current = _sources[index!];
      simulatedPosition = current is IndexedAudioSource
          ? current.positionOffset
          : Duration.zero;
    } else if (next < _sources.length || appliedLoopMode == LoopMode.all) {
      if (discontinuityFirst) {
        index = next % _sources.length;
      } else {
        moveTo(next % _sources.length);
      }
      simulatedPosition = Duration.zero;
    } else {
      simulatedPosition = endPosition ?? simulatedDuration;
      state = ProcessingState.completed;
    }
    if (state != ProcessingState.completed) {
      // Like just_audio, a loop or an advance is an autoAdvance discontinuity
      // between the last event before it and the one after, with no events
      // in between (ExoPlayer is sparse).
      _discontinuities.add(
        PositionDiscontinuity(
          PositionDiscontinuityReason.autoAdvance,
          before,
          playbackEvent,
        ),
      );
    }
    _events.add(playbackEvent);
    if (discontinuityFirst) {
      scheduleMicrotask(() {
        scheduleMicrotask(() {
          scheduleMicrotask(() => _indices.add(index));
        });
      });
    }
  }

  Completer<void>? pauseGate;
  Completer<void>? pauseEntered;

  @override
  Future<void> pause() async {
    simulatedPosition = position;
    isPlaying = false;
    emitPlayerEvent();
    _playing?.complete();
    _playing = null;
    final gate = pauseGateWhen?.call() != false ? pauseGate : null;
    if (gate != null) pauseGate = null;
    if (gate != null) {
      pauseEntered?.complete();
      await gate.future;
    }
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
    // Like a native player after an error: Play neither re-prepares nor
    // plays the failed source.
    if (state == ProcessingState.idle && errorCode != null) return;
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
    if (stopCalls >= (hangStopsFrom ?? 1 << 30)) {
      await Completer<void>().future;
    }
    final gate = stopCalls >= stopGateFrom ? stopGate : null;
    if (gate != null) stopGate = null;
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
    final claimed = claimedSources;
    if (claimed != null && source != null && !claimed.add(source)) {
      // Retiring just_audio disposes its attached sources. Reusing one on
      // the replacement can fail after its optimistic loading event.
      state = ProcessingState.loading;
      throw StateError('Source belongs to the retired player');
    }
    // Like just_audio, only a prepared, non-empty load clears the idle
    // player's error.
    if (preload && sources.isNotEmpty) errorCode = null;
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
      state = ProcessingState.idle;
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
    state = sources.isEmpty || !preload
        ? ProcessingState.idle
        : bufferAfterLoad
        ? ProcessingState.buffering
        : ProcessingState.ready;
    if (failAfterLoad) {
      // Like a native load: a loading event, then the error.
      _events.add(
        PlaybackEvent(
          processingState: ProcessingState.loading,
          currentIndex: index,
        ),
      );
      state = ProcessingState.idle;
      errorCode = 0;
      _events.add(playbackEvent);
    }
    if (source is IndexedAudioSource &&
        (source.tag as MediaItem?)?.extras?['bridgeFormat'] != null) {
      bridgeInitialPositions.add(initialPosition);
      if (rejectBridgeLoad) throw StateError('bridge load failed');
    }
    _indices.add(index);
    if (loadErrorAfterApply case final error?) {
      loadErrorAfterApply = null;
      state = ProcessingState.idle;
      throw error;
    }
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
        final before = playbackEvent;
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
        await _emitQueueEditDiscontinuity(before);
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
    final after = afterAppendGate;
    if (after != null) {
      afterAppendGate = null;
      afterAppendEntered?.complete();
      await after.future;
    }
  });

  @override
  Future<void> insertAudioSources(int at, List<AudioSource> sources) =>
      _mutate(() async {
        await _hangIf('insertAudioSources');
        final gate = insertGate;
        insertGate = null;
        if (gate != null) {
          insertEntered?.complete();
          await gate.future;
        }
        final before = playbackEvent;
        batchMutationCount++;
        _sources.insertAll(at, sources);
        if (index != null && at <= index!) index = index! + sources.length;
        _indices.add(index);
        afterInsertSources?.call();
        await _emitQueueEditDiscontinuity(before);
      });

  /// Holds the next batch insert until completed.
  Completer<void>? insertGate;
  Completer<void>? insertEntered;

  /// Runs once a batch insert has landed, before the call returns.
  void Function()? afterInsertSources;

  @override
  Future<void> seek(Duration? position, {int? index}) => _mutate(() async {
    seekCalls++;
    if (rejectNextSeek) {
      rejectNextSeek = false;
      throw StateError('native seek failed');
    }
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
    if (position != null && !ignored) {
      simulatedPosition = position;
      if (state == ProcessingState.completed && position < simulatedDuration) {
        state = ProcessingState.ready;
      }
    }
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
      await _discontinuities.close();
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
    bool fastSeeking = true,
    RollingCacheSidecarDownloader? sidecarDownloader,
    bool crossfadeAllowStreaming = true,
    bool nextSongPrefetchAllowed = true,
    bool Function()? readNextSongPrefetchAllowed,
    PlaybackSourceResolver Function(PlaybackSourceResolver)? wrapResolver,
    bool positionStreams = false,
    int rollingCacheBudgetBytes = 1024 * 1024,
    String crossfadeType = 'normal',
    String Function()? readCrossfadeType,
    bool matchFlow = false,
    int savedQueueIndex = -1,
    NavisQueueWindow queueWindow = const NavisQueueWindow(),
    bool? desktopRuntimeOverride,
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
    Future<bool> Function()? checkDeviceConnected,
    Stream<void>? recoveredNetwork,
    bool sidecarStreams = false,
    StreamingQuality streamingQuality = const StreamingQuality(
      label: 'original',
    ),
    bool supportsTranscodeOffset = false,
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
      readStreamingQuality: () => streamingQuality,
      readRollingCacheDirectory: () async => directory,
      readCachedPlaybackFirst: () => true,
      readCanStream: readCanStream,
      readUsesSidecarRollingCache: () => sidecarStreams,
      readSupportsTranscodeOffset: () => supportsTranscodeOffset,
    );
    final resolver = wrapResolver?.call(baseResolver) ?? baseResolver;
    NavisAudioHandler buildHandler() => NavisAudioHandler(
      reconcileNetwork: reconcileNetwork,
      checkDeviceConnected: checkDeviceConnected,
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
      sidecarDownloader: sidecarDownloader,
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
      readRollingCacheBudgetBytes: () => rollingCacheBudgetBytes,
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
        fastSeekingEnabled: fastSeeking,
        nextSongPrefetchAllowed:
            readNextSongPrefetchAllowed?.call() ?? nextSongPrefetchAllowed,
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
      desktopRuntimeOverride: desktopRuntimeOverride,
      shuffleRandom: Random(7),
      playerFactory: rebuiltPlayers == null && players == null
          ? null
          : () {
              final rebuilt = _ControllableAudioPlayer()
                ..simulateProgress = true;
              if (positionStreams) {
                rebuilt.positionPlayer = _HandlerPositionPlayer(rebuilt);
              }
              rebuilt
                ..claimedSources = player.claimedSources
                ..loadGate = player.replacementLoadGate
                ..gateNonEmptyLoadsOnly = true;
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
      Future<bool> Function()? deviceConnected,
      Stream<void>? recovered,
      bool remote = false,
      int count = 3,
      NavisPlaybackTimeouts timeouts = const NavisPlaybackTimeouts(),
    }) async {
      final directory = await Directory.systemTemp.createTemp('navis-idle-');
      final created = await createHandler(
        directory,
        count,
        reconcileNetwork: reconcile,
        checkDeviceConnected: deviceConnected,
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
          if (radio) {
            expect(
              (player.sequence.single as ProgressiveAudioSource)
                  .options!
                  .androidUseDefaultLoadErrorHandling,
              isTrue,
            );
          }
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
        final failed = expectLater(
          starting,
          throwsA(isA<RadioPlaybackUnavailableException>()),
        );
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
        ..isPlaying = false
        ..errorCode = 0;
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

    test('a normal build installs no seek trace callback', () async {
      final (handler, _, _) = await setup();
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      await handler.seek(const Duration(seconds: 30));
      expect(handler.debugSeekTraceInstalled, isFalse);
    });

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

    test(
      'a dead station restores a queue over the eager limit paused',
      () async {
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: true),
          count: 70,
        );
        final songIds = List<String>.generate(70, (index) => 'song-$index');
        await handler.replaceQueue(
          songIds,
          autoPlay: false,
          expandMatchFlows: false,
        );
        await handler.playRadioStream(
          stationId: 'fixture',
          stationName: 'Fixture',
          streamUrl: 'https://radio.example.invalid/live',
        );
        player
          ..state = ProcessingState.idle
          ..isPlaying = false;
        final playRequests = player.focusRequests;
        player._events.add(nativeError(2005));
        await pumpEventQueue(times: 100);
        await settleQueue(handler);
        expect(handler.snapshot.isRadioMode, isFalse);
        expect(handler.snapshot.queueSongIds, songIds);
        // A real Play waits for audio focus, so one requested here lands after
        // the restore's pause and starts the old queue.
        expect(player.focusRequests, playRequests);
        expect(player.playing, isFalse);
      },
    );

    for (final count in [1, 80]) {
      test(
        'rejected station start restores $count playing songs paused with one notice',
        () async {
          final (handler, player, _) = await setup(count: count);
          final songIds = List.generate(count, (index) => 'song-$index');
          await handler.replaceQueue(songIds, expandMatchFlows: false);
          await settleQueue(handler);
          await handler.debugFlushQueuePersistence();
          expect(player.playing, isTrue);
          final notices = <void>[];
          final subscription = handler.radioStreamErrorStream.listen(
            notices.add,
          );
          addTearDown(subscription.cancel);
          // The native load can fail without emitting a playback stream error,
          // and just_audio retains its separate playing flag after that failure.
          player.failLoadSongId = 'radio:dead';
          await expectLater(
            handler.playRadioStream(
              stationId: 'dead',
              stationName: 'Dead station',
              streamUrl: 'http://127.0.0.1:9/dead.mp3',
            ),
            throwsA(isA<RadioPlaybackUnavailableException>()),
          );
          await pumpEventQueue(times: 100);
          await settleQueue(handler);
          expect(handler.snapshot.queueSongIds, songIds);
          expect(handler.snapshot.isRadioMode, isFalse);
          expect(handler.snapshot.isLoading, isFalse);
          expect(player.playing, isFalse);
          expect(handler.snapshot.playing, isFalse);
          expect(handler.playbackState.value.playing, isFalse);
          expect(notices, hasLength(1));
        },
      );
    }

    test(
      'a dead station on first start does not leave the load stuck',
      () async {
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: true),
        );
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        await handler.debugFlushQueuePersistence();
        final notices = <void>[];
        final subscription = handler.radioStreamErrorStream.listen(notices.add);
        addTearDown(subscription.cancel);
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..loadGate = gate
          ..loadEntered = entered;
        final starting = handler.playRadioStream(
          stationId: 'fixture',
          stationName: 'Fixture',
          streamUrl: 'https://radio.example.invalid/live',
        );
        await entered.future;
        player._events.add(nativeError(2005));
        await pumpEventQueue();
        gate.completeError(StateError('source load also rejected'));
        await starting;
        await pumpEventQueue(times: 100);
        await settleQueue(handler);
        expect(handler.snapshot.isRadioMode, isFalse);
        expect(handler.snapshot.isLoading, isFalse);
        expect(handler.snapshot.queueSongIds, ['song-0']);
        expect(handler.snapshot.playing, isFalse);
        expect(player.playing, isFalse);
        expect(notices, hasLength(1));
      },
    );

    Future<void> dropStation(_ControllableAudioPlayer player) async {
      player
        ..state = ProcessingState.idle
        ..isPlaying = false;
      // A stream error, unlike a repeated native error event, is never merged.
      player._events.addError(PlayerException(0, 'network unavailable', null));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await pumpEventQueue(times: 50);
    }

    test(
      'a station that keeps connecting and dropping stops after the budget',
      () async {
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: true),
          timeouts: const NavisPlaybackTimeouts(
            radioRecovery: Duration(milliseconds: 600),
            radioHealthyPlay: Duration(seconds: 30),
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
        for (var i = 0; i < 12 && handler.snapshot.isRadioMode; i++) {
          // Each reconnect takes a while: that failure time adds up.
          final reconnect = Completer<void>();
          player.loadGate = reconnect;
          await dropStation(player);
          reconnect.complete();
          await pumpEventQueue(times: 50);
        }
        expect(handler.snapshot.isRadioMode, isFalse);
        expect(notices, hasLength(1));
      },
    );

    test(
      'a station that played healthily gets a fresh recovery budget',
      () async {
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: true),
          timeouts: const NavisPlaybackTimeouts(
            radioRecovery: Duration(milliseconds: 600),
            radioHealthyPlay: Duration(milliseconds: 200),
          ),
        );
        await handler.playRadioStream(
          stationId: 'fixture',
          stationName: 'Fixture',
          streamUrl: 'https://radio.example.invalid/live',
        );
        // About 250 ms of failure per drop would exceed the budget by the
        // fourth drop if it carried over.
        for (var i = 0; i < 5; i++) {
          final reconnect = Completer<void>();
          player.loadGate = reconnect;
          await dropStation(player);
          await Future<void>.delayed(const Duration(milliseconds: 150));
          reconnect.complete();
          await Future<void>.delayed(const Duration(milliseconds: 1200));
        }
        expect(handler.snapshot.isRadioMode, isTrue);
        expect(player.playing, isTrue);
      },
    );

    test(
      'a station on a flaky network that mostly plays keeps playing',
      () async {
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: true),
          timeouts: const NavisPlaybackTimeouts(
            radioRecovery: Duration(seconds: 1),
            radioHealthyPlay: Duration(seconds: 30),
          ),
        );
        await handler.playRadioStream(
          stationId: 'fixture',
          stationName: 'Fixture',
          streamUrl: 'https://radio.example.invalid/live',
        );
        // Each drop reconnects at once; only the play time between drops
        // adds up past the budget.
        for (var i = 0; i < 5; i++) {
          await dropStation(player);
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        expect(handler.snapshot.isRadioMode, isTrue);
        expect(player.playing, isTrue);
      },
    );

    test('being offline never stops a station or shows a notice', () async {
      var online = false;
      final recovered = StreamController<void>.broadcast();
      addTearDown(recovered.close);
      final (handler, player, _) = await setup(
        reconcile: () async => net(online: online),
        recovered: recovered.stream,
        timeouts: const NavisPlaybackTimeouts(
          radioRecovery: Duration(seconds: 3),
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
      final loads = player.sourceLoads;
      player
        ..state = ProcessingState.idle
        ..isPlaying = false;
      player._events.add(nativeError(2001));
      await pumpEventQueue();
      // Offline past the budget: the retry at 3 s finds no connection.
      await Future<void>.delayed(const Duration(milliseconds: 4500));
      await pumpEventQueue(times: 100);
      expect(handler.snapshot.isRadioMode, isTrue);
      expect(notices, isEmpty);
      online = true;
      recovered.add(null);
      await pumpEventQueue(times: 100);
      expect(player.sourceLoads, greaterThan(loads));
      expect(player.playing, isTrue);
      expect(handler.snapshot.isRadioMode, isTrue);
    });

    test('a station reconnect never waits for the server probe', () async {
      final (handler, player, _) = await setup(
        reconcile: () => Completer<NetworkReconciliation>().future,
        deviceConnected: () async => true,
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

    test('Play while recovery waits to reload plays with one press', () async {
      final (handler, player, _) = await setup(
        reconcile: () async => net(online: true),
        remote: true,
      );
      await handler.replaceQueue(
        ['song-0', 'song-1'],
        autoPlay: false,
        expandMatchFlows: false,
      );
      // A queue edit holds the lane, so the reload waits behind it.
      final gate = Completer<void>();
      final entered = Completer<void>();
      player
        ..appendGate = gate
        ..appendEntered = entered;
      final adding = handler
          .addToQueue(['song-2'], expandMatchFlows: false)
          .catchError((Object _) {});
      await entered.future;
      await failSong(player);
      await pumpEventQueue(times: 20);
      await handler.play();
      gate.complete();
      await adding;
      await pumpEventQueue(times: 100);
      await settleQueue(handler);
      expect(player.playing, isTrue);
      expect(
        handler.snapshot.processingState,
        isNot(AudioProcessingState.buffering),
      );
    });

    test(
      'Play survives a reload that fails again while the queue fills',
      () async {
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: true),
          remote: true,
        );
        await handler.replaceQueue(
          ['song-0', 'song-1'],
          autoPlay: false,
          expandMatchFlows: false,
        );
        // A queue edit holds the lane, so the reload waits behind it.
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..appendGate = gate
          ..appendEntered = entered;
        final adding = handler
            .addToQueue(['song-2'], expandMatchFlows: false)
            .catchError((Object _) {});
        await entered.future;
        await failSong(player);
        await pumpEventQueue(times: 20);
        await handler.play();
        // The reloaded stream fails at once, and the rest of the queue is
        // still being restored, so recovery cannot start again.
        final fill = Completer<void>();
        player
          ..failAfterLoad = true
          ..appendGate = fill
          ..appendEntered = Completer<void>();
        gate.complete();
        await adding;
        await pumpEventQueue(times: 100);
        player.failAfterLoad = false;
        fill.complete();
        await pumpEventQueue(times: 100);
        await settleQueue(handler);
        expect(player.state, ProcessingState.ready);
        expect(player.playing, isTrue);
      },
    );

    test('a held Play applies once a restore reloads its song', () async {
      final (handler, player, database) = await setup(
        reconcile: () async => net(online: false),
        remote: true,
        count: 70,
      );
      final ids = List<String>.generate(70, (index) => 'song-$index');
      await handler.replaceQueue(ids, autoPlay: false, expandMatchFlows: false);
      await settleQueue(handler);
      await database.playQueueDao.saveQueue(currentIndex: 0, songIds: ids);
      await failSong(player);
      // Offline, Play holds its request for the failed song.
      await handler.play();
      await pumpEventQueue(times: 20);
      // Android Auto restores the saved queue in two phases without
      // superseding the Play; the restore reloads the same song.
      await handler.prepareFromMediaId('recent/resume');
      await pumpEventQueue(times: 100);
      await settleQueue(handler);
      expect(player.state, ProcessingState.ready);
      expect(player.playing, isTrue);
      expect(
        handler.snapshot.processingState,
        isNot(AudioProcessingState.buffering),
      );
    });

    test('an error event that is not idle still counts as a failure', () async {
      var online = false;
      final recovered = StreamController<void>.broadcast();
      addTearDown(recovered.close);
      final (handler, player, _) = await setup(
        reconcile: () async => net(online: online),
        recovered: recovered.stream,
        remote: true,
      );
      await handler.replaceQueue(
        ['song-0', 'song-1'],
        autoPlay: false,
        expandMatchFlows: false,
      );
      player
        ..simulatedPosition = const Duration(seconds: 42)
        ..state = ProcessingState.idle
        ..errorCode = 0;
      player._events.add(
        PlaybackEvent(
          processingState: ProcessingState.buffering,
          updatePosition: const Duration(seconds: 42),
          currentIndex: 0,
          errorCode: 0,
          errorMessage: 'Source error',
        ),
      );
      await pumpEventQueue(times: 20);
      await handler.play();
      await pumpEventQueue(times: 20);
      final loads = player.sourceLoads;
      online = true;
      recovered.add(null);
      await pumpEventQueue(times: 100);
      await settleQueue(handler);
      expect(player.sourceLoads, greaterThan(loads));
      expect(player.playing, isTrue);
    });

    test('Play on a failed song during a seek never hangs', () async {
      final (handler, player, _) = await setup(
        reconcile: () async => net(online: false),
        remote: true,
        timeouts: const NavisPlaybackTimeouts(
          load: Duration(milliseconds: 300),
          seekProgress: Duration(milliseconds: 300),
        ),
      );
      await handler.replaceQueue(
        ['song-0', 'song-1'],
        autoPlay: false,
        expandMatchFlows: false,
      );
      await failSong(player);
      await handler.pause();
      // The seek waits for the failed source to become ready.
      final seeking = handler.seek(const Duration(seconds: 60));
      await pumpEventQueue();
      await handler.play();
      await seeking;
      await settleQueue(handler);
      expect(
        handler.snapshot.processingState,
        isNot(AudioProcessingState.buffering),
      );
    });

    test('Play on a song that was never prepared plays it directly', () async {
      final (handler, player, _) = await setup(remote: true);
      await handler.replaceQueue(
        ['song-0', 'song-1'],
        autoPlay: false,
        expandMatchFlows: false,
      );
      // With gapless off, an autoPlay:false load stays unprepared.
      player.state = ProcessingState.idle;
      final loads = player.sourceLoads;
      await handler.play();
      await pumpEventQueue(times: 100);
      expect(player.sourceLoads, loads);
      expect(player.playing, isTrue);
    });

    test(
      'Play on a song loaded after another one failed plays it directly',
      () async {
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: false),
          remote: true,
        );
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        await failSong(player);
        await pumpEventQueue(times: 20);
        await handler.replaceQueue(
          ['song-1', 'song-2'],
          autoPlay: false,
          expandMatchFlows: false,
        );
        // just_audio's idle player keeps the failed song's error until the
        // next song is prepared (a load with preload: false); its Play loads
        // the song.
        player
          ..state = ProcessingState.idle
          ..errorCode = 0
          ..playRequested = false;
        final loads = player.sourceLoads;
        await handler.play();
        await pumpEventQueue(times: 100);
        expect(player.sourceLoads, loads);
        expect(player.playRequested, isTrue);
      },
    );

    test('Play during the probe keeps a seek made during a stall', () async {
      final probe = Completer<NetworkReconciliation>();
      final (handler, player, _) = await setup(
        reconcile: () => probe.future,
        remote: true,
      );
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      player
        ..simulatedPosition = const Duration(seconds: 42)
        ..state = ProcessingState.buffering;
      final recovering = handler.debugRecoverCurrentSong();
      await pumpEventQueue();
      await handler.seek(const Duration(seconds: 180));
      // The stream resumes by itself at 1:00 while the probe still runs.
      player
        ..simulatedPosition = const Duration(seconds: 60)
        ..state = ProcessingState.ready;
      await handler.play();
      probe.complete(net(online: true));
      await recovering;
      await pumpEventQueue(times: 100);
      await settleQueue(handler);
      expect(player.position, const Duration(seconds: 180));
      expect(player.playing, isTrue);
    });

    test(
      'a seek during a stall applies once the song resumes by itself',
      () async {
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: false),
          remote: true,
        );
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        player
          ..simulatedPosition = const Duration(seconds: 42)
          ..state = ProcessingState.buffering;
        await handler.debugRecoverCurrentSong();
        player.state = ProcessingState.ready;
        await handler.seek(const Duration(seconds: 60));
        await pumpEventQueue(times: 100);
        await settleQueue(handler);
        expect(player.position, const Duration(seconds: 60));
        expect(
          handler.snapshot.processingState,
          isNot(AudioProcessingState.buffering),
        );
      },
    );

    test('Play in the offline hold keeps an earlier seek target', () async {
      var online = false;
      final recovered = StreamController<void>.broadcast();
      addTearDown(recovered.close);
      final (handler, player, _) = await setup(
        reconcile: () async => net(online: online),
        recovered: recovered.stream,
        remote: true,
      );
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      await failSong(player);
      await handler.seek(const Duration(seconds: 60));
      await handler.play();
      await pumpEventQueue(times: 20);
      online = true;
      recovered.add(null);
      await pumpEventQueue(times: 100);
      await settleQueue(handler);
      expect(player.position, const Duration(seconds: 60));
      expect(player.playing, isTrue);
    });

    test(
      'a resume after a long interruption has a fresh focus budget',
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
        player.focusDenials = 1;
        await handler.play();
        await pumpEventQueue();
        session.interruptions.add(
          AudioInterruptionEvent(true, AudioInterruptionType.pause),
        );
        // Past the first denial's budget; the resume retries after 1 s.
        await Future<void>.delayed(const Duration(milliseconds: 2600));
        player.focusDenials = 1;
        session.interruptions.add(
          AudioInterruptionEvent(false, AudioInterruptionType.pause),
        );
        await Future<void>.delayed(const Duration(milliseconds: 2500));
        expect(player.playing, isTrue);
      },
    );

    test(
      'a Play that re-arms recovery leaves no old focus budget behind',
      () async {
        var online = false;
        final recovered = StreamController<void>.broadcast();
        addTearDown(recovered.close);
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: online),
          recovered: recovered.stream,
          remote: true,
          timeouts: const NavisPlaybackTimeouts(
            focusRetry: Duration(milliseconds: 1500),
          ),
        );
        await handler.replaceQueue(
          ['song-0', 'song-1'],
          autoPlay: false,
          expandMatchFlows: false,
        );
        player.focusDenials = 100;
        await handler.play();
        await failSong(player);
        // Re-arms recovery of the failed song without requesting focus.
        await handler.play();
        await pumpEventQueue(times: 20);
        // Offline for longer than the first denial's budget.
        await Future<void>.delayed(const Duration(milliseconds: 2600));
        player.focusDenials = 1;
        online = true;
        recovered.add(null);
        await pumpEventQueue(times: 100);
        await settleQueue(handler);
        // The reloaded song's denied play retries after 1 s.
        await Future<void>.delayed(const Duration(milliseconds: 2500));
        expect(player.playing, isTrue);
      },
    );

    test('the media button cancels a pending focus retry', () async {
      final (handler, player, _) = await setup();
      await handler.replaceQueue(
        ['song-0'],
        autoPlay: false,
        expandMatchFlows: false,
      );
      player.focusDenials = 100;
      await handler.play();
      await pumpEventQueue();
      await handler.click();
      // Between the cancelled retry at 1 s and the next one at 3 s.
      await Future<void>.delayed(const Duration(milliseconds: 2000));
      expect(player.focusRequests, 1);
      expect(player.playing, isFalse);
    });

    test('Play during a pending focus retry keeps its budget', () async {
      final (handler, player, _) = await setup(
        timeouts: const NavisPlaybackTimeouts(focusRetry: Duration(seconds: 5)),
      );
      await handler.replaceQueue(
        ['song-0'],
        autoPlay: false,
        expandMatchFlows: false,
      );
      player.focusDenials = 100;
      await handler.play();
      await Future<void>.delayed(const Duration(milliseconds: 2000));
      await handler.play();
      await Future<void>.delayed(const Duration(milliseconds: 6000));
      // Denied at 0, 1, 2 (this Play), 3 and the budget's end at 5 s. A
      // fresh budget would retry again at 7 s.
      expect(player.focusRequests, 5);
      expect(handler.playbackState.value.playing, isFalse);
    });
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

    for (final count in [6, 300]) {
      for (final crossfade in [false, true]) {
        for (final action in [
          'auto',
          'next',
          'paused-next',
          'play',
          'restart',
          if (crossfade) 'fade',
        ]) {
          test(
            'shuffled next pass count=$count fade=$crossfade action=$action',
            () async {
              final players = <_ControllableAudioPlayer>[];
              final (handler, _, database) = await fixture(
                players,
                count: count,
                crossfade: crossfade,
                queueWindow: const NavisQueueWindow(),
              );
              await handler.replaceQueue(
                ids(count),
                startIndex: 2,
                expandMatchFlows: false,
              );
              await handler.setShuffleMode(AudioServiceShuffleMode.all);
              await handler.setRepeatMode(
                action == 'restart'
                    ? AudioServiceRepeatMode.none
                    : AudioServiceRepeatMode.all,
              );
              final previous = List<String>.of(handler.snapshot.queueSongIds);
              await handler.playFromIndex(count - 1);
              await settleQueue(handler);
              expect(handler.snapshot.currentIndex, count - 1);
              if (action == 'paused-next') await handler.pause();
              final finished = handler.snapshot.currentSongId;
              // A real overlap intentionally runs both decks. Assert its
              // settled handoff; other paths retain per-emission checks.
              final check = action == 'fade' && count == 6
                  ? () async => expectAudioMatchesMetadata(
                      handler,
                      players,
                      settled: true,
                    )
                  : watchAudioMetadata(handler, players);
              final active =
                  handler.debugActivePlayer as _ControllableAudioPlayer;
              switch (action) {
                case 'auto':
                  active.finishCurrentTrack();
                  await pumpEventQueue();
                case 'next':
                case 'paused-next':
                  await handler.skipToNext();
                case 'play':
                case 'restart':
                  active
                    ..state = ProcessingState.completed
                    ..simulatedPosition = active.simulatedDuration;
                  await handler.play();
                case 'fade':
                  if (count == 6) {
                    await handler.debugStartCrossfade();
                    await handler.debugCompleteCrossfade();
                  } else {
                    // Released windows already wrap through navigation.
                    handler.debugCheckCrossfadeTrigger(
                      active.simulatedDuration - const Duration(seconds: 5),
                    );
                    active.finishCurrentTrack();
                    await pumpEventQueue();
                  }
              }
              await settleQueue(handler);
              final order = handler.snapshot.queueSongIds;
              expect(order, isNot(previous));
              expect(order.toSet(), previous.toSet());
              expect(order, hasLength(count));
              expect(order.first, isNot(finished));
              expect(handler.snapshot.currentIndex, 0);
              expect(handler.snapshot.currentSongId, order.first);
              expect(
                (handler.debugActivePlayer as _ControllableAudioPlayer)
                    .audibleSongId,
                action == 'paused-next' ? null : order.first,
              );
              expect(handler.snapshot.playing, action != 'paused-next');
              await check();
              await handler.debugFlushQueuePersistence();
              expect(
                (await database.playQueueDao.getQueueItems()).map(
                  (song) => song.id,
                ),
                order,
              );
              await handler.setShuffleMode(AudioServiceShuffleMode.none);
              await settleQueue(handler);
              expect(handler.snapshot.queueSongIds, ids(count));
              expect(handler.snapshot.currentSongId, order.first);
            },
          );
        }
      }
    }

    for (final original in <List<String>>[
      ['song-0', 'song-1'],
      ['song-0', 'song-1', 'song-0', 'song-2', 'song-2'],
      ['song-0', 'song-0', 'song-0'],
    ]) {
      test('shuffled next pass preserves occurrences $original', () async {
        final players = <_ControllableAudioPlayer>[];
        final (handler, _, _) = await fixture(players, count: 3);
        await handler.replaceQueue(original, expandMatchFlows: false);
        await handler.setShuffleMode(AudioServiceShuffleMode.all);
        await handler.setRepeatMode(AudioServiceRepeatMode.all);
        await handler.playFromIndex(original.length - 1);
        expect(handler.snapshot.shuffleMode, AudioServiceShuffleMode.all);
        await settleQueue(handler);
        final finished = handler.snapshot.currentSongId;
        final check = watchAudioMetadata(handler, players);
        (handler.debugActivePlayer as _ControllableAudioPlayer)
            .finishCurrentTrack();
        await pumpEventQueue();
        await settleQueue(handler);
        final order = List<String>.of(handler.snapshot.queueSongIds);
        expect(order..sort(), List<String>.of(original)..sort());
        if (original.toSet().length > 1) {
          expect(handler.snapshot.currentSongId, isNot(finished));
        }
        await check();
        await handler.setShuffleMode(AudioServiceShuffleMode.none);
        await settleQueue(handler);
        expect(handler.snapshot.queueSongIds, original);
      });
    }

    test(
      'failed shuffled wrap crossfade advances through completion',
      () async {
        final players = <_ControllableAudioPlayer>[];
        final (handler, _, _) = await fixture(
          players,
          count: 6,
          crossfade: true,
        );
        await handler.replaceQueue(ids(6), expandMatchFlows: false);
        await handler.setShuffleMode(AudioServiceShuffleMode.all);
        await handler.setRepeatMode(AudioServiceRepeatMode.all);
        await handler.playFromIndex(5);
        await settleQueue(handler);
        expect(handler.snapshot.shuffleMode, AudioServiceShuffleMode.all);
        final active = handler.debugActivePlayer as _ControllableAudioPlayer;
        final finished = handler.snapshot.currentSongId;
        (handler.debugInactiveDeck as _ControllableAudioPlayer).failPlay = true;
        final check = watchAudioMetadata(handler, players);
        await handler.debugStartCrossfade();
        await pumpEventQueue();
        expect(active.index, active.sourceIds.length - 1);
        expect(handler.snapshot.currentSongId, finished);
        active.finishCurrentTrack();
        await pumpEventQueue();
        await settleQueue(handler);
        expect(handler.snapshot.currentIndex, 0);
        expect(handler.snapshot.currentSongId, isNot(finished));
        expect(handler.snapshot.queueSongIds.toSet(), ids(6).toSet());
        await check();
      },
    );

    for (final count in [6, 300]) {
      for (final crossfade in [false, true]) {
        for (final repeat in [
          AudioServiceRepeatMode.none,
          AudioServiceRepeatMode.all,
          AudioServiceRepeatMode.one,
        ]) {
          for (final (shuffled, entity) in [
            // Toggled on after the plain replace has started (see below).
            (true, false),
            (true, true),
            // Native Repeat All must not loop the one-song fill unshuffled
            // either. Entity Shuffle always turns shuffle on.
            (false, false),
          ]) {
            test('first ${shuffled ? 'shuffled ' : ''}song completes during '
                'initial fill count=$count fade=$crossfade repeat=$repeat '
                'entity=$entity', () async {
              final players = <_ControllableAudioPlayer>[];
              final (handler, player, database) = await fixture(
                players,
                count: count,
                crossfade: crossfade,
                queueWindow: const NavisQueueWindow(),
              );
              if (shuffled && entity) {
                await handler.setShuffleMode(AudioServiceShuffleMode.all);
              }
              await handler.setRepeatMode(repeat);
              final gate = Completer<void>();
              final entered = Completer<void>();
              addTearDown(() {
                if (!gate.isCompleted) gate.complete();
              });
              player
                ..appendGate = gate
                ..appendEntered = entered;
              final rows = await database.libraryDao.getSongsByIds(ids(count));
              rows.shuffle(Random(19));
              final replacing = entity
                  ? handler.replaceQueueWithData(
                      rows,
                      originalOrder: ids(count),
                      expandMatchFlows: false,
                    )
                  : handler.replaceQueue(
                      ids(count),
                      startIndex: 2,
                      expandMatchFlows: false,
                    );
              await entered.future;
              final order = List<String>.of(handler.snapshot.queueSongIds);
              // Entity Shuffle supplies the play order with the start song
              // first; a plain replace plays in order from the start song,
              // whatever the previous queue's shuffle mode was.
              final start = entity ? 0 : 2;
              expect(player.sourceIds, [order[start]]);
              expect(player.index, 0);
              final check = watchAudioMetadata(handler, players);
              player.finishCurrentTrack();
              // Only Repeat One may replay the temporary one-song playlist.
              expect(
                player.processingState,
                repeat == AudioServiceRepeatMode.one
                    ? ProcessingState.ready
                    : ProcessingState.completed,
              );
              gate.complete();
              await replacing;
              await settleQueue(handler);
              final expected =
                  order[start + (repeat == AudioServiceRepeatMode.one ? 0 : 1)];
              expect(handler.snapshot.currentSongId, expected);
              expect(player.audibleSongId, expected);
              expect(player.simulatedPosition, Duration.zero);
              expect(handler.snapshot.queueSongIds, order);
              if (shuffled && !entity) {
                // Shuffle toggled on after the plain replace shuffles around
                // the current song and restores the order when turned off.
                await handler.setShuffleMode(AudioServiceShuffleMode.all);
                await settleQueue(handler);
                expect(handler.snapshot.currentSongId, expected);
                expect(handler.snapshot.queueSongIds.first, expected);
                expect(handler.snapshot.queueSongIds.toSet(), order.toSet());
                await handler.setShuffleMode(AudioServiceShuffleMode.none);
                await settleQueue(handler);
                expect(handler.snapshot.queueSongIds, order);
                expect(handler.snapshot.currentSongId, expected);
              }
              await check();
            });
          }
        }
      }
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
              expect(handler.snapshot.shuffleMode, AudioServiceShuffleMode.all);
              await handler.debugFlushQueuePersistence();
              expect(
                (await database.playQueueDao.getQueueState())!.shuffleMode,
                ShuffleMode.all,
              );
              final saved = await database.playQueueDao.getQueueEntries();
              final original = List.of(saved)
                ..sort((a, b) => a.originalOrder!.compareTo(b.originalOrder!));
              expect(original.map((entry) => entry.song.id), ids(60));
              await handler.setShuffleMode(AudioServiceShuffleMode.none);
              await settleQueue(handler);
              expect(handler.snapshot.queueSongIds, ids(60));
              expect(handler.snapshot.currentSongId, rows.first.id);
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
              final (handler, player, database) = await fixture(
                players,
                crossfade: crossfade,
                count: 6,
                queueWindow: const NavisQueueWindow(),
              );
              await handler.replaceQueue(ids(6), expandMatchFlows: false);
              await handler.setShuffleMode(AudioServiceShuffleMode.all);
              await handler.setRepeatMode(repeat);
              final rows = await database.libraryDao.getSongsByIds(ids(6));
              rows.shuffle(Random(19));
              final check = watchAudioMetadata(handler, players);
              final gate = Completer<void>();
              final entered = Completer<void>();
              player
                ..appendGate = gate
                ..appendEntered = entered;
              // Entity Shuffle: the supplied play order starts at its first song.
              final replacing = handler.replaceQueueWithData(
                rows,
                originalOrder: ids(6),
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
          'plain replace during Phase 2 after a shuffled queue plays in order, fade=$crossfade repeat=$repeat',
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
            expect(handler.snapshot.queueSongIds, ids(6));
            expect(handler.snapshot.currentSongId, 'song-2');
            gate.complete();
            await replacing;
            await settleQueue(handler);
            expect(handler.snapshot.queueSongIds, ids(6));
            expect(handler.snapshot.currentSongId, 'song-2');
            expect(handler.snapshot.shuffleMode, AudioServiceShuffleMode.none);
            await check();
          },
        );

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
                    expect(failures, isEmpty);
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
                  expect(failures, isEmpty);
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
    'a cleared cover file is downloaded once and republished with art',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-stale-art-',
      );
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      PlaybackArtCache.resetKeyForTesting();
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        PlaybackArtCache.resetKeyForTesting();
      });
      await PlaybackArtCache.initializeKey(supportDirectory: directory);
      final art = _JpegArtworkService();
      final (handler, _, database) = await createHandler(
        directory,
        3,
        sidecarStreams: true,
        artworkFileService: art,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
      });
      await database.libraryDao.upsertSongs([
        for (final id in ['song-0', 'song-1', 'song-2'])
          SongsTableCompanion.insert(
            id: id,
            title: id,
            duration: const Value(300),
            coverArt: Value('cover-$id'),
          ),
      ]);
      final projection = RealTimeProjectionAudioHandler(
        handler,
        systemArt: AndroidSystemArt(
          authority: 'app.test.artwork',
          fetch: handler.cacheSystemArtwork,
          cachedPath: handler.cachedSystemArtwork,
        ),
      );
      addTearDown(projection.dispose);
      final published = <MediaItem?>[];
      final sub = projection.mediaItem.listen(published.add);
      addTearDown(sub.cancel);

      await handler.replaceQueue(
        ['song-0', 'song-1', 'song-2'],
        startIndex: 0,
        expandMatchFlows: false,
      );
      await settleQueue(handler);
      await handler.play();
      for (
        var i = 0;
        i < 300 &&
            !(published.isNotEmpty &&
                published.last?.artUri?.scheme == 'content');
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(published.last?.artUri?.scheme, 'content');
      final file = File(published.last!.extras!['artCacheFile']! as String);
      expect(file.existsSync(), isTrue);

      // Move to song-1 and wait for its art, then delete song-0's file (Android
      // clears cacheDir) and come back to song-0.
      await handler.skipToQueueItem(1);
      await settleQueue(handler);
      for (
        var i = 0;
        i < 300 &&
            !(published.last?.id == 'song-1' &&
                published.last?.artUri?.scheme == 'content');
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      file.deleteSync();
      final getsBefore = art.gets;
      await handler.skipToQueueItem(0);
      await settleQueue(handler);
      await pumpEventQueue(times: 200);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await pumpEventQueue(times: 200);
      expect(art.gets - getsBefore, 1);
      expect(file.existsSync(), isTrue);
      final last = projection.mediaItem.value!;
      expect(last.id, 'song-0');
      expect(last.artUri?.scheme, 'content');
      expect(last.extras?['artCacheFile'], file.path);
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

  group('desktop next-song prefetch', () {
    const size = 8 * 1024;
    Future<
      ({
        NavisAudioHandler handler,
        _ControllableAudioPlayer player,
        RollingCacheSidecarDownloader downloader,
        List<String> requests,
        Completer<void> release,
        List<bool> gate,
      })
    >
    serveQueue(
      int count, {
      bool allowed = true,
      Set<String> hold = const <String>{},
      Set<String> failFirst = const <String>{},
      Future<void> Function(NavisDatabase)? seed,
      int startIndex = 0,
      Future<void> Function(NavisAudioHandler)? beforePlay,
    }) async {
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final release = Completer<void>();
      final requests = <String>[];
      final gate = <bool>[allowed];
      server.listen((request) async {
        final id = request.uri.queryParameters['id']!;
        requests.add(id);
        if (failFirst.contains(id) &&
            requests.where((r) => r == id).length == 1) {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
          return;
        }
        try {
          request.response
            ..bufferOutput = false
            ..headers.contentType = ContentType('audio', 'mpeg')
            ..contentLength = size;
          if (hold.contains(id)) {
            request.response.add(List<int>.filled(size ~/ 2, 1));
            await request.response.flush();
            await release.future;
            request.response.add(List<int>.filled(size ~/ 2, 1));
          } else {
            request.response.add(List<int>.filled(size, 1));
          }
          await request.response.close();
        } on Object {
          // The handler cancels unfinished transfers at teardown.
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
        'navis-prefetch-',
      );
      final downloader = RollingCacheSidecarDownloader();
      final (handler, player, database) = await createHandler(
        directory,
        count,
        sidecarStreams: true,
        positionStreams: true,
        sidecarDownloader: downloader,
        readApiClient: () => api,
        nextSongPrefetchAllowed: allowed,
        readNextSongPrefetchAllowed: () => gate.first,
        seed: seed,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        if (!release.isCompleted) release.complete();
        await database.close();
        await server.close(force: true);
        await directory.delete(recursive: true);
        HttpOverrides.global = previousHttp;
      });
      await beforePlay?.call(handler);
      await handler.replaceQueue(
        [for (var i = 0; i < count; i++) 'song-$i'],
        startIndex: startIndex,
        expandMatchFlows: false,
      );
      return (
        handler: handler,
        player: player,
        downloader: downloader,
        requests: requests,
        release: release,
        gate: gate,
      );
    }

    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 600 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(condition(), isTrue);
    }

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 400));

    test('the next song downloads once the current one completes', () async {
      final s = await serveQueue(3);
      await until(() => s.requests.contains('song-1'));
      await settle();
      expect(s.requests, ['song-0', 'song-1']);
      final next = s.handler.queue.value[1].extras!['sidecarCacheFilePath'];
      expect(File(next as String).existsSync(), isTrue);
    });

    test('no next-song download when prefetch is not allowed', () async {
      final s = await serveQueue(3, allowed: false);
      final first = s.handler.queue.value[0].extras!['sidecarCacheFilePath'];
      await until(() => File(first as String).existsSync());
      await settle();
      expect(s.requests, ['song-0']);
    });

    test('a next song that is already downloaded is not fetched', () async {
      final s = await serveQueue(
        3,
        seed: (database) async {
          final dir = await Directory.systemTemp.createTemp('navis-warm-');
          final file = File('${dir.path}/song-1.mp3')
            ..writeAsBytesSync(<int>[1, 2, 3]);
          await database.cacheDao.upsertCachedTrack(
            CachedTracksTableCompanion.insert(
              songId: 'song-1',
              filePath: file.path,
              fileSize: 3,
              format: 'mp3',
              cacheType: CacheType.permanent,
              downloadStatus: DownloadStatus.complete,
              lastAccessedAt: DateTime.now(),
            ),
          );
        },
      );
      final first = s.handler.queue.value[0].extras!['sidecarCacheFilePath'];
      await until(() => File(first as String).existsSync());
      await settle();
      expect(s.requests, ['song-0']);
    });

    test('Repeat One warms nothing', () async {
      final s = await serveQueue(
        3,
        beforePlay: (handler) =>
            handler.setRepeatMode(AudioServiceRepeatMode.one),
      );
      final first = s.handler.queue.value[0].extras!['sidecarCacheFilePath'];
      await until(() => File(first as String).existsSync());
      await settle();
      expect(s.requests, ['song-0']);
    });

    test('Repeat All at the last song warms the first song', () async {
      final s = await serveQueue(
        2,
        startIndex: 1,
        beforePlay: (handler) =>
            handler.setRepeatMode(AudioServiceRepeatMode.all),
      );
      await until(() => s.requests.contains('song-0'));
      expect(s.requests, ['song-1', 'song-0']);
    });

    test('shuffle warms the next song in play order', () async {
      final s = await serveQueue(
        6,
        beforePlay: (handler) =>
            handler.setShuffleMode(AudioServiceShuffleMode.all),
      );
      final queue = s.handler.queue.value;
      await until(() => s.requests.length >= 2);
      final current = s.handler.mediaItem.value!.id;
      final at = queue.indexWhere((item) => item.id == current);
      expect(s.requests, [current, queue[at + 1].id]);
    });

    test(
      'the chained download continues when its song becomes current',
      () async {
        final s = await serveQueue(3, hold: {'song-1'});
        await until(() => s.downloader.activeSongId == 'song-1');
        await until(() => s.downloader.activeReceivedBytes == size ~/ 2);
        s.player.moveTo(1);
        await pumpEventQueue();
        expect(s.downloader.activeSongId, 'song-1');
        expect(s.downloader.activeReceivedBytes, size ~/ 2);
        s.release.complete();
        await settle();
        expect(s.requests.where((id) => id == 'song-1'), hasLength(1));
      },
    );

    test(
      're-publishing the finished current song keeps the warm running',
      () async {
        final s = await serveQueue(3, hold: {'song-1'});
        await until(() => s.downloader.activeReceivedBytes == size ~/ 2);
        final part = s.downloader.activePartFilePath;
        // Dropping the last song keeps next = song-1 and re-publishes song-0.
        await s.handler.removeQueueItemAt(2);
        await pumpEventQueue();
        expect(s.downloader.activeSongId, 'song-1');
        expect(s.downloader.activePartFilePath, part);
        expect(s.downloader.activeReceivedBytes, size ~/ 2);
        s.release.complete();
        await settle();
        expect(s.requests, ['song-0', 'song-1']);
      },
    );

    test('turning the gate off cancels an in-flight warm', () async {
      final s = await serveQueue(3, hold: {'song-1'});
      await until(() => s.downloader.activeReceivedBytes == size ~/ 2);
      s.gate[0] = false;
      await s.handler.removeQueueItemAt(2);
      await until(() => s.downloader.activeSongId == null);
      s.release.complete();
      await settle();
      expect(s.requests, ['song-0', 'song-1']);
    });

    test('a warm that failed is retried after the retry delay', () async {
      sidecarChainRetryDelay = const Duration(milliseconds: 150);
      addTearDown(() => sidecarChainRetryDelay = const Duration(seconds: 30));
      final s = await serveQueue(3, failFirst: {'song-1'});
      s.player.simulateProgress = true;
      s.player.emitPlayerEvent();
      await until(() => s.requests.contains('song-1'));
      await settle();
      // Position ticks must retry without a queue edit clearing the pair key.
      await until(() => s.requests.where((id) => id == 'song-1').length == 2);
    });

    test('a failed pair does not block the next pair', () async {
      final s = await serveQueue(4, failFirst: {'song-1'});
      await until(() => s.requests.contains('song-1'));
      await settle();
      s.player.moveTo(2);
      await until(() => s.requests.contains('song-3'));
    });

    test(
      'refilling a deleted current file immediately re-arms the warm',
      () async {
        final s = await serveQueue(3, hold: {'song-1'});
        await until(() => s.downloader.activeSongId == 'song-1');
        await until(() => s.downloader.activeReceivedBytes == size ~/ 2);
        final path =
            s.handler.queue.value[0].extras!['sidecarCacheFilePath']! as String;
        await until(() => File(path).existsSync());
        await settle();
        await File(path).delete();
        await s.handler.removeQueueItemAt(2);
        await until(() => s.requests.where((id) => id == 'song-0').length == 2);
        await until(() => File(path).existsSync());
        await settle();
        expect(s.requests, ['song-0', 'song-1', 'song-0', 'song-1']);
        expect(s.downloader.activeSongId, 'song-1');
        await until(() => s.downloader.activeReceivedBytes == size ~/ 2);
        s.release.complete();
      },
    );

    for (final (repeat, index, kept) in [
      (RepeatMode.off, 1, {1, 2}),
      (RepeatMode.one, 1, {1}),
      (RepeatMode.all, 2, {2, 0}),
    ]) {
      test(
        'startup eviction protects saved shuffled files with ${repeat.name}',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'navis-startup-keep-',
          );
          final paths = <String>[];
          final restore = Completer<void>();
          final (handler, _, database) = await createHandler(
            directory,
            3,
            cacheSongs: false,
            savedQueueIndex: index,
            rollingCacheBudgetBytes: 1,
            waitForReady: false,
            createPlayQueueDao: (db) =>
                _GatedQueueEntriesDao(db, restore.future),
            seed: (database) async {
              await database.playQueueDao.saveQueue(
                songIds: ['song-0', 'song-1', 'song-2'],
                currentIndex: index,
                repeatMode: repeat,
                shuffleMode: ShuffleMode.all,
                originalOrder: [2, 0, 1],
              );
              for (var i = 0; i < 3; i++) {
                final path = p.join(directory.path, 'song-$i.mp3');
                paths.add(path);
                await File(path).writeAsBytes([1, 2, 3]);
                await database.cacheDao.upsertCachedTrack(
                  CachedTracksTableCompanion.insert(
                    songId: 'song-$i',
                    filePath: path,
                    fileSize: 3,
                    format: 'mp3',
                    cacheType: CacheType.rolling,
                    downloadStatus: DownloadStatus.complete,
                    lastAccessedAt: DateTime.now(),
                  ),
                );
              }
            },
          );
          addTearDown(() async {
            if (!restore.isCompleted) restore.complete();
            await handler.disposeHandler();
            await database.close();
            await directory.delete(recursive: true);
          });
          // Startup maintenance is concurrent with metadata restoration.
          final evicted = List.generate(
            3,
            (i) => i,
          ).firstWhere((i) => !kept.contains(i));
          await until(() => !File(paths[evicted]).existsSync());
          await settle();
          for (var i = 0; i < paths.length; i++) {
            expect(File(paths[i]).existsSync(), kept.contains(i));
          }
          restore.complete();
          await handler.debugWaitForStartupQueueRestore();
        },
      );
    }

    test(
      'the handler reports the current and next song as protected',
      () async {
        final s = await serveQueue(3);
        await until(() => s.requests.contains('song-1'));
        expect(s.handler.rollingCacheProtectedSongIds, {'song-0', 'song-1'});
      },
    );

    test('a queue edit cancels a chain that is no longer next', () async {
      final s = await serveQueue(3, hold: {'song-1'});
      await until(() => s.downloader.activeSongId == 'song-1');
      await s.handler.removeQueueItemAt(1);
      await until(() => s.downloader.activeSongId != 'song-1');
      await until(() => s.requests.contains('song-2'));
    });
  });

  group('android next-song warm', () {
    const size = 8 * 1024;
    Future<
      ({
        NavisAudioHandler handler,
        _ControllableAudioPlayer player,
        int port,
        Map<String, int> maxActive,
        List<String> requests,
        Completer<void> release,
        List<bool> gate,
      })
    >
    serveQueue(
      int count, {
      bool allowed = true,
      Set<String> hold = const <String>{},
      Set<String> cached = const <String>{},
      Set<String> silent = const <String>{},
      Set<String> failFirst = const <String>{},
      Set<String> cutFirst = const <String>{},
      List<String>? ids,
      int startIndex = 0,
      RollingCacheSidecarDownloader? downloader,
      bool build = true,
      NavisQueueWindow window = const NavisQueueWindow(),
      PlaybackSourceResolver Function(PlaybackSourceResolver)? wrap,
      bool crossfade = false,
      bool supportsTranscodeOffset = false,
      // Songs whose second and later downloads stop half-way until the gate.
      Set<String> holdLater = const <String>{},
      Completer<void>? laterGate,
      List<_ControllableAudioPlayer>? rebuiltPlayers,
      NavisPlaybackTimeouts timeouts = const NavisPlaybackTimeouts(),
    }) async {
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final release = Completer<void>();
      final requests = <String>[];
      final gate = <bool>[allowed];
      final active = <String, int>{};
      final maxActive = <String, int>{};
      server.listen((request) async {
        final id = request.uri.queryParameters['id']!;
        requests.add(id);
        final nth = requests.where((r) => r == id).length;
        active[id] = (active[id] ?? 0) + 1;
        maxActive[id] = max(maxActive[id] ?? 0, active[id]!);
        try {
          if (failFirst.contains(id) && nth == 1) {
            request.response.statusCode = HttpStatus.internalServerError;
            await request.response.close();
            return;
          }
          request.response
            ..bufferOutput = false
            ..headers.contentType = ContentType('audio', 'mpeg')
            ..contentLength = size;
          if (cutFirst.contains(id) && nth == 1) {
            request.response.add(List<int>.filled(size ~/ 2, 1));
            await request.response.flush();
            // Expiry destroys the socket without a terminating chunk.
            request.response.deadline = Duration.zero;
            await Future<void>.delayed(const Duration(milliseconds: 100));
            return;
          }
          if (holdLater.contains(id) && nth > 1) {
            request.response.add(List<int>.filled(size ~/ 2, 1));
            await request.response.flush();
            await laterGate?.future;
            request.response.add(List<int>.filled(size ~/ 2, 1));
          } else if (silent.contains(id)) {
            // Headers only: the warm has reported no progress yet.
            await request.response.flush();
            await release.future;
            request.response.add(List<int>.filled(size, 1));
          } else if (hold.contains(id)) {
            request.response.add(List<int>.filled(size ~/ 2, 1));
            await request.response.flush();
            await release.future;
            request.response.add(List<int>.filled(size ~/ 2, 1));
          } else {
            request.response.add(List<int>.filled(size, 1));
          }
          await request.response.close();
        } on Object {
          // The handler cancels unfinished transfers at teardown.
        } finally {
          active[id] = active[id]! - 1;
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
      final directory = await Directory.systemTemp.createTemp('navis-warm-a-');
      final (handler, player, database) = await createHandler(
        directory,
        count,
        desktopRuntimeOverride: false,
        sidecarDownloader: downloader,
        wrapResolver: wrap,
        queueWindow: window,
        crossfade: crossfade,
        supportsTranscodeOffset: supportsTranscodeOffset,
        timeouts: timeouts,
        rebuiltPlayers: rebuiltPlayers,
        cacheSongs: false,
        positionStreams: true,
        readApiClient: () => api,
        nextSongPrefetchAllowed: allowed,
        readNextSongPrefetchAllowed: () => gate.first,
        seed: (database) async {
          for (final id in cached) {
            final file = File('${directory.path}/$id.mp3')
              ..writeAsBytesSync(<int>[1, 2, 3]);
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
        },
      );
      addTearDown(() async {
        await handler.disposeHandler();
        if (!release.isCompleted) release.complete();
        await database.close();
        await server.close(force: true);
        await directory.delete(recursive: true);
        HttpOverrides.global = previousHttp;
      });
      if (build) {
        await handler.replaceQueue(
          ids ?? [for (var i = 0; i < count; i++) 'song-$i'],
          startIndex: startIndex,
          expandMatchFlows: false,
        );
        await settleQueue(handler);
      }
      return (
        handler: handler,
        player: player,
        port: server.port,
        maxActive: maxActive,
        requests: requests,
        release: release,
        gate: gate,
      );
    }

    // ignore: experimental_member_use, reason: the lock-cache source the player requests.
    LockCachingAudioSource sourceAt(_ControllableAudioPlayer p, int i) =>
        // ignore: experimental_member_use, reason: as above.
        p.audioSources[i] as LockCachingAudioSource;

    // A download can finish (and rename its partial file) between a response
    // and its first read: that is a finished download, not a failure.
    // ignore: experimental_member_use, reason: the lock-cache source response.
    Future<void> drain(StreamAudioResponse r) =>
        r.stream.drain<void>().onError<PathNotFoundException>((_, _) {});

    // The player's own request for the current song; its completion is what
    // starts the warm.
    Future<void> playCurrent(_ControllableAudioPlayer p) =>
        sourceAt(p, 0).request().then(drain);

    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 600 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(condition(), isTrue);
    }

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 400));

    test('completion of the current song downloads the next one', () async {
      final s = await serveQueue(3);
      await playCurrent(s.player);
      await until(() => s.requests.contains('song-1'));
      await settle();
      expect(s.requests, ['song-0', 'song-1']);
    });

    test('no next-song download when prefetch is not allowed', () async {
      final s = await serveQueue(3, allowed: false);
      await playCurrent(s.player);
      await settle();
      expect(s.requests, ['song-0']);
    });

    test('a next song without a lock-cache source is not fetched', () async {
      final s = await serveQueue(3, cached: {'song-1'});
      await playCurrent(s.player);
      await settle();
      expect(s.requests, ['song-0']);
    });

    test('Repeat One warms nothing', () async {
      final s = await serveQueue(3);
      await s.handler.setRepeatMode(AudioServiceRepeatMode.one);
      await playCurrent(s.player);
      await settle();
      expect(s.requests, ['song-0']);
    });

    test(
      'the warm continues, not restarts, when its song becomes current',
      () async {
        final s = await serveQueue(3, hold: {'song-1'});
        await playCurrent(s.player);
        await until(() => s.requests.contains('song-1'));
        s.player.moveTo(1);
        await pumpEventQueue();
        // The player now asks for the song the warm is fetching.
        final asked = sourceAt(s.player, 1).request();
        s.release.complete();
        await drain(await asked);
        await settle();
        expect(s.requests.where((id) => id == 'song-1'), hasLength(1));
      },
    );

    // The partial file of the song at [i], which a cancelled download removes.
    Future<File> partOf(_ControllableAudioPlayer p, int i) async =>
        File('${(await sourceAt(p, i).cacheFile).path}.part');

    test('a queue edit cancels a warm that is no longer next', () async {
      final s = await serveQueue(3, hold: {'song-1'});
      final part = await partOf(s.player, 1);
      await playCurrent(s.player);
      await until(() => s.requests.contains('song-1'));
      await until(() => part.existsSync());
      await s.handler.removeQueueItemAt(1);
      await until(() => s.requests.contains('song-2'));
      await until(() => !part.existsSync());
      await settle();
    });

    test(
      'returning to a finished song re-arms the warm of its successor',
      () async {
        final s = await serveQueue(3, hold: {'song-1'});
        final part = await partOf(s.player, 1);
        await playCurrent(s.player);
        await until(() => part.existsSync());
        s.player.moveTo(2);
        await until(() => !part.existsSync());
        s.player.moveTo(0);
        await until(() => s.requests.where((id) => id == 'song-1').length == 2);
        await settle();
      },
    );

    test('switching to radio cancels a running warm', () async {
      final s = await serveQueue(3, silent: {'song-1'});
      final warm = sourceAt(s.player, 1);
      await playCurrent(s.player);
      await until(() => s.requests.contains('song-1') && warm.isDownloading);
      unawaited(
        s.handler
            .playRadioStream(
              stationId: 'r',
              stationName: 'R',
              streamUrl: 'http://127.0.0.1:${s.port}/radio?id=radio',
            )
            .catchError((Object _) {}),
      );
      await until(() => !warm.isDownloading);
    });

    test(
      'a shuffle that keeps the warmed song next reuses its source',
      () async {
        final s = await serveQueue(2, hold: {'song-1'});
        final warm = sourceAt(s.player, 1);
        await playCurrent(s.player);
        await until(() => s.requests.contains('song-1') && warm.isDownloading);
        await s.handler.setShuffleMode(AudioServiceShuffleMode.all);
        await settleQueue(s.handler);
        expect(identical(sourceAt(s.player, 1), warm), isTrue);
        final asked = sourceAt(s.player, 1).request();
        s.release.complete();
        await drain(await asked);
        await settle();
        expect(s.requests.where((id) => id == 'song-1'), hasLength(1));
      },
    );

    test(
      'a shuffle before the warm starts keeps one source for the song',
      () async {
        final s = await serveQueue(2, hold: {'song-1'});
        final next = sourceAt(s.player, 1);
        await s.handler.setShuffleMode(AudioServiceShuffleMode.all);
        await settleQueue(s.handler);
        expect(identical(sourceAt(s.player, 1), next), isTrue);
        await playCurrent(s.player);
        await until(() => s.requests.contains('song-1') && next.isDownloading);
        final asked = sourceAt(s.player, 1).request();
        s.release.complete();
        await drain(await asked);
        await settle();
        expect(s.requests.where((id) => id == 'song-1'), hasLength(1));
      },
    );

    test('disposing the handler cancels a running warm', () async {
      final s = await serveQueue(3, hold: {'song-1'});
      final part = await partOf(s.player, 1);
      await playCurrent(s.player);
      await until(() => part.existsSync());
      await s.handler.disposeHandler();
      await until(() => !part.existsSync());
    });

    int count(List<String> requests, String id) =>
        requests.where((r) => r == id).length;

    // Position ticks drive the chain between track changes.
    void ticks(_ControllableAudioPlayer p) {
      p.simulateProgress = true;
      p.emitPlayerEvent();
    }

    test('a failed warm backs off, then retries', () async {
      sidecarChainRetryDelay = const Duration(milliseconds: 900);
      addTearDown(() => sidecarChainRetryDelay = const Duration(seconds: 30));
      final s = await serveQueue(3, failFirst: {'song-1'});
      ticks(s.player);
      await playCurrent(s.player);
      await until(() => s.requests.contains('song-1'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(count(s.requests, 'song-1'), 1);
      await until(() => count(s.requests, 'song-1') == 2);
      await settle();
    });

    test('a warm cut mid-body is detected and retried', () async {
      sidecarChainRetryDelay = const Duration(milliseconds: 900);
      addTearDown(() => sidecarChainRetryDelay = const Duration(seconds: 30));
      final s = await serveQueue(3, cutFirst: {'song-1'});
      ticks(s.player);
      await playCurrent(s.player);
      await until(() => s.requests.contains('song-1'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(count(s.requests, 'song-1'), 1);
      await until(() => count(s.requests, 'song-1') == 2);
      await settle();
    });

    test(
      'closing the gate cancels the warm; reopening restarts at once',
      () async {
        final s = await serveQueue(3, hold: {'song-1'});
        ticks(s.player);
        final warm = sourceAt(s.player, 1);
        await playCurrent(s.player);
        await until(() => s.requests.contains('song-1') && warm.isDownloading);
        s.gate[0] = false;
        await until(() => !warm.isDownloading);
        s.gate[0] = true;
        await until(() => count(s.requests, 'song-1') == 2);
        await settle();
      },
    );

    test('the chain continues after the warm becomes current', () async {
      final s = await serveQueue(3, hold: {'song-1'});
      ticks(s.player);
      await playCurrent(s.player);
      await until(() => s.requests.contains('song-1'));
      s.player.moveTo(1);
      await pumpEventQueue();
      final asked = sourceAt(s.player, 1).request();
      s.release.complete();
      await drain(await asked);
      await until(() => s.requests.contains('song-2'));
      expect(s.requests, ['song-0', 'song-1', 'song-2']);
      await settle();
    });

    test('Repeat All wraps the warm to the first song', () async {
      final s = await serveQueue(2, startIndex: 1);
      await s.handler.setRepeatMode(AudioServiceRepeatMode.all);
      ticks(s.player);
      await sourceAt(s.player, 1).request().then(drain);
      await until(() => s.requests.contains('song-0'));
      expect(s.requests, ['song-1', 'song-0']);
      await settle();
    });

    test('replacing the queue with the warmed song first reuses it', () async {
      final s = await serveQueue(3, hold: {'song-1'});
      ticks(s.player);
      final warm = sourceAt(s.player, 1);
      await playCurrent(s.player);
      await until(() => s.requests.contains('song-1') && warm.isDownloading);
      await s.handler.replaceQueue([
        'song-1',
        'song-2',
        'song-0',
      ], expandMatchFlows: false);
      await settleQueue(s.handler);
      expect(identical(sourceAt(s.player, 0), warm), isTrue);
      final asked = sourceAt(s.player, 0).request();
      s.release.complete();
      await drain(await asked);
      await settle();
      expect(count(s.requests, 'song-1'), 1);
    });

    test(
      'a song twice in the queue has one lock-cache source and one download',
      () async {
        final s = await serveQueue(
          3,
          hold: {'song-1'},
          ids: ['song-0', 'song-1', 'song-1'],
        );
        ticks(s.player);
        // One writer per cache file, and one instance never at two playlist
        // positions (just_audio derives the native id from it): the repeat
        // streams without downloading.
        // ignore: experimental_member_use, reason: the lock-cache source.
        expect(s.player.audioSources[1], isA<LockCachingAudioSource>());
        // ignore: experimental_member_use, reason: the lock-cache source.
        expect(s.player.audioSources[2], isNot(isA<LockCachingAudioSource>()));
        expect(
          s.player.audioSources.toSet(),
          hasLength(s.player.audioSources.length),
        );
        await playCurrent(s.player);
        await until(() => s.requests.contains('song-1'));
        s.player.moveTo(1);
        await pumpEventQueue();
        final asked = sourceAt(s.player, 1).request();
        s.release.complete();
        await drain(await asked);
        await settle();
        expect(count(s.requests, 'song-1'), 1);
        expect(s.maxActive['song-1'], 1);
      },
    );

    // What the native player does with an occurrence: a stream source is read
    // through its proxy request, a plain URI source is fetched from its origin.
    Future<int> readOccurrence(_ControllableAudioPlayer p, int i) async {
      final source = p.audioSources[i];
      // ignore: experimental_member_use, reason: the proxy request contract.
      if (source is StreamAudioSource) {
        final response = await source.request();
        await drain(response);
        return response.contentLength ?? -1;
      }
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(
          (source as UriAudioSource).uri,
        )).close();
        return (await response.fold<int>(0, (n, chunk) => n + chunk.length));
      } finally {
        client.close(force: true);
      }
    }

    test(
      'a repeat occurrence of a completed song reads the cache file',
      () async {
        final s = await serveQueue(3, ids: ['song-0', 'song-1', 'song-1']);
        ticks(s.player);
        final leader = sourceAt(s.player, 1);
        await drain(await leader.request());
        final file = await leader.cacheFile;
        await until(() => file.existsSync());
        expect(count(s.requests, 'song-1'), 1);
        expect(await readOccurrence(s.player, 2), size);
        // The completed file is served: the origin is not asked again.
        expect(count(s.requests, 'song-1'), 1);
        // ignore: experimental_member_use, reason: the proxy request contract.
        expect(s.player.audioSources[2], isA<StreamAudioSource>());
      },
    );

    test('a repeat occurrence joins the leader download', () async {
      final s = await serveQueue(
        3,
        hold: {'song-1'},
        ids: ['song-0', 'song-1', 'song-1'],
      );
      ticks(s.player);
      final leader = sourceAt(s.player, 1);
      final first = leader.request();
      await until(() => s.requests.contains('song-1') && leader.isDownloading);
      final reading = readOccurrence(s.player, 2);
      await pumpEventQueue();
      s.release.complete();
      expect(await reading, size);
      await drain(await first);
      await settle();
      expect(count(s.requests, 'song-1'), 1);
      expect(s.maxActive['song-1'], 1);
    });

    // The cache file of a completed song is evicted while the song is queued:
    // the held writer downloads it again, registered like any running download,
    // and a new occurrence follows it instead of becoming a second writer.
    for (final edit in ['addToQueue', 'playNext', 'replaceQueue']) {
      test(
        'an evicted song re-downloads through its held writer, $edit',
        () async {
          final gate = Completer<void>();
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
          final s = await serveQueue(
            3,
            ids: ['song-0', 'song-1', 'song-1'],
            holdLater: {'song-1'},
            laterGate: gate,
          );
          ticks(s.player);
          final leader = sourceAt(s.player, 1);
          await drain(await leader.request());
          final file = await leader.cacheFile;
          await until(() => file.existsSync());
          await until(
            () => s.handler.debugRegisteredLockCacheSource('song-1') == null,
          );
          file.deleteSync();
          final reading = leader.request();
          await until(() => leader.isDownloading);
          expect(
            identical(
              s.handler.debugRegisteredLockCacheSource('song-1'),
              leader,
            ),
            isTrue,
            reason: 'the re-download must be registered again',
          );
          switch (edit) {
            case 'addToQueue':
              await s.handler.addToQueue(['song-1'], expandMatchFlows: false);
            case 'playNext':
              await s.handler.playNext(['song-1'], expandMatchFlows: false);
            default:
              await s.handler.replaceQueue([
                'song-0',
                'song-1',
                'song-1',
                'song-1',
              ], expandMatchFlows: false);
          }
          await settleQueue(s.handler);
          expect(
            identical(
              s.handler.debugRegisteredLockCacheSource('song-1'),
              leader,
            ),
            isTrue,
          );
          final ids = [for (final m in s.handler.queue.value) m.id];
          final writers = [
            for (var i = 0; i < ids.length; i++)
              // ignore: experimental_member_use, reason: the lock-cache source.
              if (ids[i] == 'song-1' &&
                  // ignore: experimental_member_use, reason: the lock-cache source.
                  s.player.audioSources[i] is LockCachingAudioSource)
                s.player.audioSources[i],
          ];
          expect(writers, hasLength(1));
          expect(identical(writers.single, leader), isTrue);
          for (var i = 0; i < ids.length; i++) {
            if (ids[i] == 'song-1' &&
                !identical(s.player.audioSources[i], leader)) {
              expect(s.player.audioSources[i], isA<LockCacheFollowerSource>());
            }
          }
          final last = ids.lastIndexOf('song-1');
          final second = readOccurrence(s.player, last);
          gate.complete();
          await second;
          await drain(await reading);
          await settle();
          // One origin download, then one re-download: never a second writer.
          expect(count(s.requests, 'song-1'), 2);
          expect(s.maxActive['song-1'], 1);
          // The re-download completed through the progress observer, so the
          // rolling cache registered the file and the registry entry is gone.
          await until(
            () => s.handler.debugRegisteredLockCacheSource('song-1') == null,
          );
          expect(file.existsSync(), isTrue);
        },
      );
    }

    test(
      'a new occurrence of an evicted song follows its idle held writer',
      () async {
        final s = await serveQueue(3, ids: ['song-0', 'song-1', 'song-1']);
        ticks(s.player);
        final leader = sourceAt(s.player, 1);
        await drain(await leader.request());
        final file = await leader.cacheFile;
        await until(() => file.existsSync());
        await until(
          () => s.handler.debugRegisteredLockCacheSource('song-1') == null,
        );
        file.deleteSync();
        await s.handler.addToQueue(['song-1'], expandMatchFlows: false);
        await settleQueue(s.handler);
        final added = s.player.audioSources.last;
        expect(added, isA<LockCacheFollowerSource>());
        expect(
          identical((added as LockCacheFollowerSource).leader, leader),
          isTrue,
        );
        await readOccurrence(s.player, s.player.audioSources.length - 1);
        await settle();
        expect(count(s.requests, 'song-1'), 2);
        expect(s.maxActive['song-1'], 1);
      },
    );

    test('a rebuild onto an idle evicted writer does not replay its completion', () async {
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final s = await serveQueue(
        4,
        ids: ['song-0', 'song-1', 'song-1', 'song-2'],
        holdLater: {'song-1'},
        laterGate: gate,
      );
      ticks(s.player);
      final leader = sourceAt(s.player, 1);
      await drain(await leader.request());
      final file = await leader.cacheFile;
      await until(() => file.existsSync());
      await until(
        () => s.handler.debugRegisteredLockCacheSource('song-1') == null,
      );
      await s.handler.skipToQueueItem(3);
      await settleQueue(s.handler);
      await settle();
      file.deleteSync();
      await s.handler.replaceQueue(
        ['song-1', 'song-0', 'song-1'],
        startIndex: 0,
        expandMatchFlows: false,
      );
      await settleQueue(s.handler);
      await settle();
      expect(identical(s.player.audioSources[0], leader), isTrue);
      // The file is gone: the stale 1.0 the progress stream replays is not a
      // completion, so the writer stays registered and the buffer is not full.
      expect(
        identical(s.handler.debugRegisteredLockCacheSource('song-1'), leader),
        isTrue,
      );
      expect(
        s.handler.bufferState.bufferedPosition,
        lessThan(const Duration(minutes: 3)),
      );
    });

    test('a source retired by a player recovery no longer re-registers', () async {
      final s = await serveQueue(
        3,
        hold: {'song-1'},
        ids: ['song-0', 'song-1', 'song-1'],
        rebuiltPlayers: <_ControllableAudioPlayer>[],
        timeouts: const NavisPlaybackTimeouts(
          load: Duration(milliseconds: 150),
          reset: Duration(milliseconds: 150),
        ),
      );
      ticks(s.player);
      final leader = sourceAt(s.player, 1);
      expect(leader.onDownloadStart, isNotNull);
      s.player.hang.add('insertAudioSources');
      await expectLater(
        s.handler.playNext(['song-0'], expandMatchFlows: false),
        throwsA(isA<PlaybackLoadTimeoutException>()),
      );
      // Recovery unregistered the retired writer; a retry of its fetch must not
      // take the registry slot back from the rebuilt queue's source.
      expect(s.handler.debugRegisteredLockCacheSource('song-1'), isNot(leader));
      expect(leader.onDownloadStart, isNull);
      s.release.complete();
    });

    test('a repeat occurrence plays on after its leader is removed', () async {
      final s = await serveQueue(
        3,
        hold: {'song-1'},
        ids: ['song-0', 'song-1', 'song-1'],
      );
      ticks(s.player);
      final leader = sourceAt(s.player, 1);
      final first = leader.request();
      await until(() => s.requests.contains('song-1') && leader.isDownloading);
      await s.handler.removeQueueItemAt(1);
      await settleQueue(s.handler);
      expect(s.player.audioSources, hasLength(2));
      final reading = readOccurrence(s.player, 1);
      await pumpEventQueue();
      s.release.complete();
      expect(await reading, size);
      await drain(await first);
      await settle();
      expect(count(s.requests, 'song-1'), 1);
      expect(s.maxActive['song-1'], 1);
    });

    // The planner asks whether the origin serves ranges; a repeat occurrence
    // answers with its leader's origin, not with "a plain source: yes".
    for (final onRepeat in [false, true]) {
      test(
        'the seek planner uses the leader range support'
        ' (playing the ${onRepeat ? 'repeat' : 'first'} occurrence)',
        () async {
          final s = await serveQueue(
            3,
            hold: {'song-1'},
            ids: ['song-0', 'song-1', 'song-1'],
            supportsTranscodeOffset: true,
            wrap: (base) => _TranscodedLockResolver(base),
          );
          ticks(s.player);
          final leader = sourceAt(s.player, 1);
          final first = leader.request();
          await until(() => leader.originSupportsRangeRequests == false);
          s.player.moveTo(onRepeat ? 2 : 1);
          await pumpEventQueue();
          await s.handler.previewSeek(const Duration(seconds: 150));
          // The origin (no Accept-Ranges) cannot serve the native seek: the
          // planner opens a transcode at the offset instead.
          expect(
            s.handler.collectPlaybackDiagnostics()['seekPreview'],
            isNotNull,
          );
          s.handler.cancelSeekPreview();
          s.release.complete();
          await drain(await first);
          await settle();
        },
      );
    }

    // Per player index: 'reg' when the player holds the registered source of
    // that song, else 'DIFF'/'UNREG'; plus how many instances each song has.
    String audit(NavisAudioHandler handler, _ControllableAudioPlayer player) {
      final ids = [for (final m in handler.queue.value) m.id];
      final instances = <String, Set<int>>{};
      var bad = 0;
      // One source instance at two playlist positions merges their native ids
      // (any kind of source, so a follower is held to it as well).
      final positions = <int, List<int>>{};
      for (var i = 0; i < player.audioSources.length; i++) {
        final s = player.audioSources[i];
        (positions[identityHashCode(s)] ??= <int>[]).add(i);
        // ignore: experimental_member_use, reason: the lock-cache source.
        if (s is! LockCachingAudioSource) continue;
        final id = ids[i];
        if (!identical(s, handler.debugRegisteredLockCacheSource(id))) bad++;
        (instances[id] ??= <int>{}).add(identityHashCode(s));
      }
      final multi = [
        for (final e in instances.entries)
          if (e.value.length > 1) e.key,
      ];
      final shared = [
        for (final p in positions.values)
          if (p.length > 1) p,
      ];
      return 'bad=$bad multiInstance=$multi atTwoPositions=$shared';
    }

    const oneInstance = 'bad=0 multiInstance=[] atTwoPositions=[]';

    test(
      'addToQueue and playNext duplicates keep one registered source',
      () async {
        final s = await serveQueue(
          4,
          hold: {'song-1', 'song-3'},
          ids: ['song-0', 'song-1'],
        );
        ticks(s.player);
        await s.handler.addToQueue([
          'song-1',
          'song-3',
          'song-3',
        ], expandMatchFlows: false);
        await settleQueue(s.handler);
        expect(audit(s.handler, s.player), oneInstance);
        await s.handler.playNext(['song-3', 'song-1'], expandMatchFlows: false);
        await settleQueue(s.handler);
        expect(audit(s.handler, s.player), oneInstance);
        await settle();
      },
    );

    // Each occurrence of a song is its own source instance (the native id
    // derives from it), with one lock-cache writer per song.
    void expectOccurrences(
      NavisAudioHandler handler,
      _ControllableAudioPlayer player,
      List<String> ids,
    ) {
      expect([for (final m in handler.queue.value) m.id], ids);
      expect(player.audioSources, hasLength(ids.length));
      expect(player.audioSources.toSet(), hasLength(ids.length));
      expect(audit(handler, player), oneInstance);
      for (final id in ids.toSet()) {
        final writers = [
          for (var i = 0; i < ids.length; i++)
            // ignore: experimental_member_use, reason: the lock-cache source.
            if (ids[i] == id &&
                // ignore: experimental_member_use, reason: the lock-cache source.
                player.audioSources[i] is LockCachingAudioSource)
              i,
        ];
        expect(writers.length, lessThanOrEqualTo(1), reason: id);
      }
    }

    test('addToQueue of a queued song adds its own occurrence', () async {
      final s = await serveQueue(
        2,
        hold: {'song-1'},
        ids: ['song-0', 'song-1'],
      );
      ticks(s.player);
      await s.handler.addToQueue(['song-1', 'song-1'], expandMatchFlows: false);
      await settleQueue(s.handler);
      expectOccurrences(s.handler, s.player, [
        'song-0',
        'song-1',
        'song-1',
        'song-1',
      ]);
      await settle();
    });

    test(
      'playNext of the playing and a queued song adds occurrences',
      () async {
        final s = await serveQueue(
          2,
          hold: {'song-1'},
          ids: ['song-0', 'song-1'],
        );
        ticks(s.player);
        await s.handler.playNext(['song-0', 'song-1'], expandMatchFlows: false);
        await settleQueue(s.handler);
        expectOccurrences(s.handler, s.player, [
          'song-0',
          'song-0',
          'song-1',
          'song-1',
        ]);
        await settle();
      },
    );

    // A full queue rebuild while the registered source is held (the flag on
    // _prepareQueueItems/_reloadQueueAfterTimeout): the held source stays the
    // song's one writer at its first occurrence, the repeat is its own
    // instance, and nothing downloads twice.
    Future<void> expectHeldLeaderSurvives(
      ({
        NavisAudioHandler handler,
        _ControllableAudioPlayer player,
        int port,
        Map<String, int> maxActive,
        List<String> requests,
        Completer<void> release,
        List<bool> gate,
      })
      s,
      // ignore: experimental_member_use, reason: the lock-cache source.
      LockCachingAudioSource leader,
      List<String> ids, {
      // A jump away cancels the unfinished warm (a later request downloads
      // again), so only a rebuild that stays put downloads exactly once.
      bool downloadsOnce = true,
    }) async {
      await settleQueue(s.handler);
      expect(
        identical(s.handler.debugRegisteredLockCacheSource('song-1'), leader),
        isTrue,
      );
      expect(
        identical(s.player.audioSources[ids.indexOf('song-1')], leader),
        isTrue,
      );
      expectOccurrences(s.handler, s.player, ids);
      s.release.complete();
      await drain(await leader.request());
      await settle();
      if (downloadsOnce) {
        expect(count(s.requests, 'song-1'), 1);
        expect(s.maxActive['song-1'], 1);
      }
    }

    test(
      'a queue rebuilt while the registered source is held keeps it',
      () async {
        const ids = ['song-0', 'song-1', 'song-1'];
        final s = await serveQueue(3, hold: {'song-1'}, ids: ids);
        ticks(s.player);
        final leader = sourceAt(s.player, 1);
        await playCurrent(s.player);
        await until(
          () => s.requests.contains('song-1') && leader.isDownloading,
        );
        await s.handler.replaceQueue(ids, expandMatchFlows: false);
        await expectHeldLeaderSurvives(s, leader, ids);
      },
    );

    test('a rebuild prepared while the source is held keeps it', () async {
      const ids = ['song-0', 'song-1', 'song-1'];
      final s = await serveQueue(3, hold: {'song-1'}, ids: ids);
      ticks(s.player);
      final leader = sourceAt(s.player, 1);
      await playCurrent(s.player);
      await until(() => s.requests.contains('song-1') && leader.isDownloading);
      // The rebuild replaces the whole queue: the player's own copy of the
      // registered source is not a reason to demote its first occurrence.
      final sources = await s.handler.debugPrepareReplacementSources(ids);
      expect(identical(sources[1], leader), isTrue);
      // ignore: experimental_member_use, reason: the lock-cache source.
      expect(sources[2], isNot(isA<LockCachingAudioSource>()));
      expect(sources.toSet(), hasLength(ids.length));
      s.release.complete();
      await settle();
    });

    test(
      'a queue restored after a failed far jump keeps the held source',
      () async {
        final ids = [
          'song-0',
          'song-1',
          'song-1',
          for (var i = 3; i < 60; i++) 'song-$i',
        ];
        final s = await serveQueue(
          60,
          hold: {'song-1'},
          ids: ids,
          window: const NavisQueueWindow(
            deferThreshold: 16,
            ahead: 8,
            lowWater: 3,
            page: 8,
            nearJump: 16,
          ),
        );
        ticks(s.player);
        final leader = sourceAt(s.player, 1);
        await playCurrent(s.player);
        await until(
          () => s.requests.contains('song-1') && leader.isDownloading,
        );
        s.player.failLoadSongId = 'song-50';
        await s.handler.playFromIndex(50);
        await until(
          () =>
              s.handler.snapshot.lastFailedSongId == 'song-50' &&
              !s.handler.snapshot.isLoading,
        );
        s.player.failLoadSongId = null;
        await expectHeldLeaderSurvives(
          s,
          leader,
          ids.take(9).toList(),
          downloadsOnce: false,
        );
      },
    );

    test(
      'a released tail with duplicates keeps one registered source',
      () async {
        final s = await serveQueue(
          4,
          hold: {'song-2'},
          ids: ['song-0', 'song-1', 'song-2', 'song-2', 'song-3', 'song-2'],
          window: const NavisQueueWindow(
            deferThreshold: 3,
            ahead: 1,
            lowWater: 1,
            page: 4,
            nearJump: 5,
            behind: 1,
            trimSlack: 1,
          ),
        );
        ticks(s.player);
        await s.handler.skipToNext();
        await settleQueue(s.handler);
        await until(() => s.player.audioSources.length == 6);
        await settleQueue(s.handler);
        expect(audit(s.handler, s.player), oneInstance);
        await settle();
      },
    );

    test(
      'a released tail is registered while its deck mirror is blocked',
      () async {
        final s = await serveQueue(
          4,
          hold: {'song-2'},
          ids: ['song-0', 'song-1', 'song-2', 'song-2', 'song-3', 'song-2'],
          crossfade: true,
          timeouts: const NavisPlaybackTimeouts(reset: Duration(seconds: 3)),
          window: const NavisQueueWindow(
            deferThreshold: 3,
            ahead: 1,
            lowWater: 1,
            page: 4,
            nearJump: 5,
            behind: 1,
            trimSlack: 1,
          ),
        );
        ticks(s.player);
        await s.handler.debugStartCrossfade();
        final deck = s.handler.debugInactiveDeck! as _ControllableAudioPlayer;
        deck.hang.add('addAudioSources');
        unawaited(s.handler.skipToNext().catchError((Object _) {}));
        await until(() => s.player.audioSources.length == 6);
        // The native append is committed: the source the player holds must be
        // the registered one now, not once the (still blocked) mirror ends.
        await until(
          () => identical(
            s.handler.debugRegisteredLockCacheSource('song-2'),
            s.player.audioSources[2],
          ),
        );
        s.release.complete();
      },
    );

    test(
      'an inserted song is registered while its deck mirror is blocked',
      () async {
        final s = await serveQueue(
          3,
          hold: {'song-2'},
          ids: ['song-0', 'song-1'],
          crossfade: true,
          timeouts: const NavisPlaybackTimeouts(reset: Duration(seconds: 4)),
        );
        ticks(s.player);
        await s.handler.debugStartCrossfade();
        final deck = s.handler.debugInactiveDeck! as _ControllableAudioPlayer;
        deck.hang.add('addAudioSources');
        unawaited(
          s.handler
              .addToQueue(['song-2'], expandMatchFlows: false)
              .catchError((Object _) {}),
        );
        await until(() => s.player.audioSources.length == 3);
        await until(
          () => identical(
            s.handler.debugRegisteredLockCacheSource('song-2'),
            s.player.audioSources[2],
          ),
        );
        s.release.complete();
      },
    );

    test('addToQueue on an empty queue shares duplicates', () async {
      final s = await serveQueue(3, hold: {'song-1'}, build: false);
      ticks(s.player);
      await s.handler.addToQueue([
        'song-0',
        'song-1',
        'song-1',
      ], expandMatchFlows: false);
      await settleQueue(s.handler);
      expect(audit(s.handler, s.player), oneInstance);
      await settle();
    });

    test(
      'a fill superseded after its native append is still registered',
      () async {
        final s = await serveQueue(3, hold: {'song-1'}, build: false);
        final p = s.player;
        final afterGate = Completer<void>();
        final afterEntered = Completer<void>();
        p.afterAppendGate = afterGate;
        p.afterAppendEntered = afterEntered;
        final first = s.handler.replaceQueue([
          'song-0',
          'song-1',
          'song-2',
        ], expandMatchFlows: false);
        await afterEntered.future.timeout(const Duration(seconds: 5));
        // The batch is in the player; a newer queue load supersedes the fill
        // before its native call returns.
        final x1 = sourceAt(p, 1);
        final second = s.handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        await pumpEventQueue();
        afterGate.complete();
        await first.catchError((Object _) {});
        expect(
          identical(s.handler.debugRegisteredLockCacheSource('song-1'), x1),
          isTrue,
        );
        await second.catchError((Object _) {});
        await settleQueue(s.handler);
        expect(audit(s.handler, p), oneInstance);
        await settle();
      },
    );

    test(
      'duplicates resolved out of order keep one registered source',
      () async {
        final s = await serveQueue(
          3,
          hold: {'song-1'},
          ids: ['song-0', 'song-1', 'song-1'],
          wrap: (base) => _OutOfOrderResolver(base),
        );
        ticks(s.player);
        final player1 = sourceAt(s.player, 1);
        await playCurrent(s.player);
        await until(
          () => s.requests.contains('song-1') && player1.isDownloading,
        );
        s.player.moveTo(1);
        await pumpEventQueue();
        final asked = player1.request();
        s.release.complete();
        await drain(await asked);
        await settle();
        expect(count(s.requests, 'song-1'), 1);
        expect(s.maxActive['song-1'], 1);
      },
    );

    test('a superseded queue build does not poison the next one', () async {
      late _GatedSourceResolver gated;
      final s = await serveQueue(
        3,
        hold: {'song-1'},
        build: false,
        wrap: (base) => gated = _GatedSourceResolver(base),
      );
      gated
        ..blockedSongId = 'song-2'
        ..entered = Completer<void>()
        ..release = Completer<void>();
      final first = s.handler.replaceQueue([
        'song-0',
        'song-1',
        'song-2',
      ], expandMatchFlows: false);
      await gated.entered!.future;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final second = s.handler.replaceQueue([
        'song-0',
        'song-1',
      ], expandMatchFlows: false);
      gated.release!.complete();
      await Future.wait([
        first.catchError((Object _) {}),
        second.catchError((Object _) {}),
      ]);
      await settleQueue(s.handler);
      ticks(s.player);
      final player1 = sourceAt(s.player, 1);
      await playCurrent(s.player);
      await until(() => s.requests.contains('song-1') && player1.isDownloading);
      s.player.moveTo(1);
      await pumpEventQueue();
      final asked = player1.request();
      s.release.complete();
      await drain(await asked);
      await settle();
      expect(count(s.requests, 'song-1'), 1);
      expect(s.maxActive['song-1'], 1);
    });

    test('a queue reloaded after a player timeout is observed again', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final directory = await Directory.systemTemp.createTemp('navis-warm-n-');
      final rebuilt = <_ControllableAudioPlayer>[];
      final created = <_WarmRangeSource>[];
      final (handler, player, database) = await createHandler(
        directory,
        3,
        cacheSongs: false,
        positionStreams: true,
        rebuiltPlayers: rebuilt,
        desktopRuntimeOverride: false,
        timeouts: const NavisPlaybackTimeouts(
          load: Duration(milliseconds: 300),
          reset: Duration(milliseconds: 150),
          control: Duration(milliseconds: 300),
          progressIdle: Duration(milliseconds: 400),
          seekProgress: Duration(seconds: 3),
        ),
        wrapResolver: (base) => _FreshRangeResolver(base, directory, created),
      );
      addTearDown(() async {
        await handler.disposeHandler();
        for (final source in created) {
          await source.progress.close();
        }
        await database.close();
        await directory.delete(recursive: true);
        debugDefaultTargetPlatformOverride = null;
      });
      player.simulateProgress = true;
      await handler.replaceQueue([
        'song-0',
        'song-1',
        'song-2',
      ], expandMatchFlows: false);
      await pumpEventQueue();
      player.isPlaying = true;
      player.hang.add('removeAudioSourceAt');
      await handler
          .removeAt(2)
          .timeout(const Duration(seconds: 6))
          .catchError((Object _) {});
      await pumpEventQueue();
      expect(rebuilt, isNotEmpty);
      final held = rebuilt.first.audioSources.cast<_WarmRangeSource>();
      expect(held, isNotEmpty);
      expect(held.every((source) => source.progress.hasListener), isTrue);
    });

    test('a position tick while disposing does not restart the warm', () async {
      final gate = Completer<void>();
      final s = await serveQueue(
        3,
        hold: {'song-1'},
        downloader: _SlowDisposeDownloader(gate),
      );
      ticks(s.player);
      final warm = sourceAt(s.player, 1);
      await playCurrent(s.player);
      await until(() => s.requests.contains('song-1') && warm.isDownloading);
      final disposing = s.handler.disposeHandler();
      await until(() => !warm.isDownloading);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(warm.isDownloading, isFalse);
      expect(count(s.requests, 'song-1'), 1);
      gate.complete();
      await disposing;
    });

    test(
      'the warm stays paused while the finished song has a range fetch',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final directory = await Directory.systemTemp.createTemp(
          'navis-warm-k-',
        );
        final sources = {
          for (var i = 0; i < 3; i++)
            'song-$i': _WarmRangeSource(
              'song-$i',
              File('${directory.path}/$i.mp3'),
            ),
        };
        final (handler, player, database) = await createHandler(
          directory,
          3,
          cacheSongs: false,
          positionStreams: true,
          desktopRuntimeOverride: false,
          wrapResolver: (base) => _RangeCacheResolver(base, sources),
        );
        addTearDown(() async {
          await handler.disposeHandler();
          for (final source in sources.values) {
            await source.progress.close();
          }
          await database.close();
          await directory.delete(recursive: true);
          debugDefaultTargetPlatformOverride = null;
        });
        player.simulateProgress = true;
        await handler.replaceQueue([
          'song-0',
          'song-1',
          'song-2',
        ], expandMatchFlows: false);
        await pumpEventQueue();
        sources['song-0']!.activeRange = true;
        player.emitBuffered(const Duration(seconds: 2));
        await pumpEventQueue();
        // The main download of song-0 finishes (its file is published); its
        // range fetch stays open.
        File('${directory.path}/0.mp3').writeAsBytesSync([1]);
        sources['song-0']!.progress.add(1.0);
        await pumpEventQueue();
        player.emitBuffered(const Duration(seconds: 3));
        await pumpEventQueue();
        expect(sources['song-1']!.warmed, isTrue);
        expect(sources['song-1']!.paused, isTrue);
      },
    );
  });

  for (final fail in [false, true]) {
    test(
      'desktop cache activity clears after ${fail ? 'retry exhaustion' : 'cancellation'}',
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
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(
            handler.collectPlaybackDiagnostics()['sidecarCacheActiveSongId'],
            'song-0',
          );
          expect(
            handler.collectPlaybackDiagnostics()['cacheActivity'],
            isNotNull,
          );
          for (var attempt = 0; attempt < 2000; attempt++) {
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

  for (final abandon in [false, true]) {
    test(
      'desktop current-index events ${abandon ? 'restart a full GET only after resume is abandoned' : 'retain the sidecar through Range resume'}',
      () async {
        final previousHttp = HttpOverrides.current;
        HttpOverrides.global = null;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final releaseCut = Completer<void>();
        final continuation = Completer<HttpResponse>();
        final ranges = <String?>[];
        final bytes = List<int>.generate(100 * 1024, (i) => i % 251);
        const prefix = 40 * 1024;
        server.listen((request) async {
          ranges.add(request.headers.value(HttpHeaders.rangeHeader));
          if (ranges.length == 1) {
            request.response
              ..contentLength = bytes.length
              ..add(bytes.sublist(0, prefix));
            await request.response.flush();
            await releaseCut.future;
            request.response.deadline = Duration.zero;
          } else if (ranges.length == 2) {
            continuation.complete(request.response);
          } else {
            request.response
              ..contentLength = bytes.length
              ..add(bytes);
            await request.response.close();
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
          'navis-sidecar-restart-',
        );
        final downloader = RollingCacheSidecarDownloader();
        final (handler, player, database) = await createHandler(
          directory,
          1,
          sidecarStreams: true,
          sidecarDownloader: downloader,
          readApiClient: () => api,
        );
        addTearDown(() async {
          await handler.disposeHandler();
          if (!releaseCut.isCompleted) releaseCut.complete();
          await database.close();
          await server.close(force: true);
          await directory.delete(recursive: true);
          HttpOverrides.global = previousHttp;
        });
        Future<void> until(bool Function() condition) async {
          for (var i = 0; i < 600 && !condition(); i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          expect(condition(), isTrue);
        }

        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        await until(() => downloader.activeReceivedBytes == prefix);
        final partPath = downloader.activePartFilePath!;
        final cacheFile = File(
          handler.mediaItem.value!.extras!['sidecarCacheFilePath']! as String,
        );
        releaseCut.complete();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        player.moveTo(player.currentIndex!);
        await pumpEventQueue();
        expect(ranges, [null]);
        expect(downloader.activePartFilePath, partPath);
        expect(downloader.activeReceivedBytes, prefix);
        expect(
          handler.collectPlaybackDiagnostics()['cacheActivity'],
          isNotNull,
        );

        final response = await continuation.future.timeout(
          const Duration(seconds: 3),
        );
        expect(ranges, [null, 'bytes=$prefix-']);
        player.moveTo(player.currentIndex!);
        await pumpEventQueue();
        expect(ranges.length, 2);
        expect(File(partPath).readAsBytesSync(), bytes.sublist(0, prefix));
        response.statusCode = abandon
            ? HttpStatus.ok
            : HttpStatus.partialContent;
        response.contentLength = abandon ? bytes.length : bytes.length - prefix;
        if (!abandon) {
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $prefix-${bytes.length - 1}/${bytes.length}',
          );
        }
        response.add(abandon ? bytes : bytes.sublist(prefix));
        await response.close();
        await until(() => downloader.activeSongId == null);
        expect(handler.collectPlaybackDiagnostics()['cacheActivity'], isNull);
        expect(File(partPath).existsSync(), isFalse);
        expect(cacheFile.existsSync(), !abandon);
        expect(player.playing, isTrue);
        expect(handler.snapshot.currentSongId, 'song-0');

        // Native position events re-emit the current index after termination.
        player.moveTo(player.currentIndex!);
        if (abandon) await until(() => ranges.length == 3);
        await until(
          () => cacheFile.existsSync() && downloader.activeSongId == null,
        );
        expect(ranges, [null, 'bytes=$prefix-', if (abandon) null]);
        expect(cacheFile.readAsBytesSync(), bytes);
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
                throwsA(isA<RadioPlaybackUnavailableException>()),
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
            await expectLater(
              switching,
              throwsA(isA<RadioPlaybackUnavailableException>()),
            );
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
        final inputIds = suppliedRows
            ? ids
            : ['song-0', 'song-1', 'song-2', 'song-4', 'song-4'];
        // Entity Shuffle supplies the shuffled play order and its original.
        final expected = shuffledFromStart(inputIds, 2, Random(7));
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..loadGate = gate
          ..loadEntered = entered;
        final replacement = suppliedRows
            ? handler.replaceQueueWithData([
                for (final id in expected) rows.firstWhere((r) => r.id == id),
              ], originalOrder: inputIds)
            : handler.replaceQueue(
                expected,
                originalOrder: inputIds,
                expandMatchFlows: false,
              );
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

    test('an inactive deck insert that never returns frees the lane', () async {
      final directory = await Directory.systemTemp.createTemp('navis-deck-');
      final (handler, _, database) = await createHandler(
        directory,
        4,
        crossfade: true,
        timeouts: timeouts,
        rebuiltPlayers: <_ControllableAudioPlayer>[],
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      await handler.replaceQueue(ids(3), expandMatchFlows: false);
      // A prepared deck mirrors the queue edits.
      await handler.debugStartCrossfade();
      final deck = handler.debugInactiveDeck! as _ControllableAudioPlayer;
      expect(deck.sequence, hasLength(3));
      deck.hang.add('insertAudioSources');

      await handler
          .playNext(<String>['song-3'], expandMatchFlows: false)
          .timeout(const Duration(seconds: 3));
      await handler
          .playNext(<String>['song-3'], expandMatchFlows: false)
          .timeout(const Duration(seconds: 3));

      expect(
        handler.snapshot.queueSongIds.where((id) => id == 'song-3'),
        hasLength(2),
      );
    });

    test(
      'a removal before the current song that times out keeps the song',
      () async {
        final (handler, player, rebuilt) = await playingAt(3);
        player.hang.add('removeAudioSourceAt');

        await expectLater(
          handler.removeAt(1),
          throwsA(isA<PlaybackLoadTimeoutException>()),
        );

        final expected = ids(10)..removeAt(1);
        expect(rebuilt.first.sourceIds, expected);
        expect(rebuilt.first.index, 2);
        expect(handler.snapshot.currentSongId, 'song-3');
        expect(handler.snapshot.queueSongIds, expected);
      },
    );

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

  group('playback anomaly recorder', () {
    Future<(NavisAudioHandler, _ControllableAudioPlayer, List<String>)>
    anomalyHandler({int duration = 180}) async {
      final directory = await Directory.systemTemp.createTemp('navis-anomaly-');
      final (handler, player, database) = await createHandler(
        directory,
        3,
        positionStreams: true,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final warnings = <String>[];
      final printer = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null && message.contains('[PLAYBACK_ANOMALY]')) {
          warnings.add(message);
        }
      };
      addTearDown(() => debugPrint = printer);
      await database.libraryDao.upsertSongs([
        SongsTableCompanion.insert(
          id: 'song-1',
          title: 'Song 1',
          duration: Value(duration),
        ),
      ]);
      // The position stream only reports a moving position.
      player.simulateProgress = true;
      await handler.replaceQueue(
        ['song-0', 'song-1', 'song-2'],
        startIndex: 1,
        expandMatchFlows: false,
      );
      await settleQueue(handler);
      await handler.play();
      // Let the load's own position moves leave the recorder's grace window.
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      return (handler, player, warnings);
    }

    Future<void> pause(int ms) =>
        Future<void>.delayed(Duration(milliseconds: ms));

    // One printed line per record header; the rest are its events.
    List<String> headers(List<String> lines) =>
        lines.where((line) => line.contains('"kind":')).toList();

    List<Object?> anomalies(NavisAudioHandler handler) =>
        handler.collectPlaybackDiagnostics()['anomalies']! as List<Object?>;

    test(
      'a four-second natural advance survives the desktop index yield',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final (handler, player, warnings) = await anomalyHandler(duration: 4);
        player.simulatedPosition = const Duration(milliseconds: 3368);
        await pause(200);
        final loads = player.sourceLoads;

        player.finishCurrentTrack(endPosition: const Duration(seconds: 4));
        player.emitPlayerEvent();
        await pause(600);

        expect(handler.snapshot.currentSongId, 'song-2');
        expect(player.sourceLoads, loads);
        expect(anomalies(handler), isEmpty);
        expect(warnings, isEmpty);
      },
    );

    test(
      'a raw player step back is recorded once, with the log line',
      () async {
        final (handler, player, warnings) = await anomalyHandler();
        player.simulatedPosition = const Duration(seconds: 90);
        await pause(500);
        player.simulatedPosition = const Duration(seconds: 80);
        await pause(1200);

        expect(anomalies(handler), hasLength(1));
        expect(headers(warnings), hasLength(1));
        expect(warnings.join('\n'), contains('"kind":"backwardJump"'));
        expect(warnings.join('\n'), isNot(contains('song-1')));
      },
    );

    test('a swapped queue entry mid-song does not hide a rewind', () async {
      final (handler, player, warnings) = await anomalyHandler();
      player.simulatedPosition = const Duration(seconds: 90);
      await pause(500);
      // Likes, art caching and recovery rebuilds replace the entry object.
      await handler.syncSongLikedState('song-1', liked: true);
      await pause(500);
      player.simulatedPosition = const Duration(seconds: 85);
      await pause(1200);

      expect(anomalies(handler), hasLength(1));
      expect(headers(warnings), hasLength(1));
    });

    test('a recovery rebuild landing behind its target is recorded', () async {
      final directory = await Directory.systemTemp.createTemp('navis-anomaly-');
      final (handler, player, database) = await createHandler(
        directory,
        3,
        sidecarStreams: true,
        positionStreams: true,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final warnings = <String>[];
      final printer = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null && message.contains('[PLAYBACK_ANOMALY]')) {
          warnings.add(message);
        }
      };
      addTearDown(() => debugPrint = printer);
      player.simulateProgress = true;
      await handler.replaceQueue(
        ['song-0', 'song-1', 'song-2'],
        startIndex: 1,
        expandMatchFlows: false,
      );
      await settleQueue(handler);
      await handler.play();
      await pause(1700);
      player.simulatedPosition = const Duration(seconds: 70);
      await pause(500);

      // The reload ignores its start position and every correction seek.
      player
        ..ignoreInitialPosition = true
        ..ignoreSeeks = true
        ..simulatedPosition = const Duration(seconds: 70)
        ..state = ProcessingState.idle;
      player._events.addError(PlayerException(2002, 'Read timed out', 1));
      for (var i = 0; i < 300 && anomalies(handler).isEmpty; i++) {
        await pause(50);
      }

      expect(anomalies(handler), hasLength(1));
      expect(warnings.join('\n'), contains('"e":"recovery"'));
      // The automatic recovery ends with a seekDone row, like a user seek.
      expect(warnings.join('\n'), contains('"outcome":"recovery"'));
    });

    test('a skip whose song is published early is not a rewind', () async {
      final (handler, player, warnings) = await anomalyHandler();
      player.simulatedPosition = const Duration(seconds: 90);
      await pause(500);
      // The native seek to the next song hangs, as a slow load does: the
      // handler publishes song-2 while the player still plays song-1.
      final gate = Completer<void>();
      player.seekGate = gate;
      final skip = handler.skipToNext();
      await pause(300);
      expect(handler.currentMediaItem?.id, 'song-2');
      expect(player.index, 1);
      await pause(1900);
      gate.complete();
      await skip;
      await pause(1500);
      expect(anomalies(handler), isEmpty);
      expect(warnings, isEmpty);

      // A real rewind on the new song is still caught.
      player.simulatedPosition = const Duration(seconds: 40);
      await pause(500);
      player.simulatedPosition = const Duration(seconds: 30);
      await pause(1200);
      expect(anomalies(handler), hasLength(1));
    });

    test('a seek during an outage is explained', () async {
      final directory = await Directory.systemTemp.createTemp('navis-anomaly-');
      final (handler, player, database) = await createHandler(
        directory,
        3,
        sidecarStreams: true,
        positionStreams: true,
        reconcileNetwork: () async =>
            (connected: false, serverReachable: false),
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      player.simulateProgress = true;
      await handler.replaceQueue(
        ['song-0', 'song-1', 'song-2'],
        startIndex: 1,
        expandMatchFlows: false,
      );
      await settleQueue(handler);
      await handler.play();
      await pause(1700);
      player.simulatedPosition = const Duration(seconds: 60);
      await pause(500);

      // The stream drops; offline, the recovery is held, not run.
      player
        ..simulatedPosition = const Duration(seconds: 60)
        ..state = ProcessingState.idle;
      player._events.addError(PlayerException(2002, 'Read timed out', 1));
      await pause(500);
      await handler.seek(const Duration(seconds: 30));
      player
        ..simulatedPosition = const Duration(seconds: 30)
        ..state = ProcessingState.ready;
      await pause(1500);

      expect(anomalies(handler), isEmpty);
    });

    test('a handler seek back is not an anomaly', () async {
      final (handler, player, warnings) = await anomalyHandler();
      player.simulatedPosition = const Duration(seconds: 90);
      await pause(500);
      await handler.seek(const Duration(seconds: 30));
      await pause(1500);

      expect(player.position, lessThan(const Duration(seconds: 40)));
      expect(anomalies(handler), isEmpty);
      expect(warnings, isEmpty);
    });

    test('a skipToPrevious restart is not an anomaly', () async {
      final (handler, player, warnings) = await anomalyHandler();
      player.simulatedPosition = const Duration(seconds: 90);
      await pause(500);
      await handler.skipToPrevious();
      await settleQueue(handler);
      await pause(1500);

      expect(anomalies(handler), isEmpty);
      expect(warnings, isEmpty);
    });

    test('a Repeat One loop is not an anomaly', () async {
      final (handler, player, warnings) = await anomalyHandler();
      await handler.setRepeatMode(AudioServiceRepeatMode.one);
      player.simulatedPosition = const Duration(seconds: 170);
      await pause(500);
      player.finishCurrentTrack();
      await pause(1500);

      expect(anomalies(handler), isEmpty);
      expect(warnings, isEmpty);
    });
  });

  group('fast seeking bridge', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.linux);
    tearDown(() => debugDefaultTargetPlatformOverride = null);
    const target = Duration(seconds: 90);
    Future<
      (
        NavisAudioHandler,
        _ControllableAudioPlayer,
        NavisDatabase,
        _BridgeSidecar,
      )
    >
    bridgeHandler({
      bool enabled = true,
      bool capable = true,
      bool slow = true,
      bool lossy = false,
      bool transcode = false,
      bool external = false,
      bool crossfade = false,
      PlaybackSourceResolver Function(PlaybackSourceResolver)? wrap,
    }) async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-fast-seek-',
      );
      final downloader = _BridgeSidecar()..rate = slow ? 10000 : null;
      final (handler, player, db) = await createHandler(
        directory,
        3,
        sidecarStreams: true,
        cacheSongs: false,
        sidecarDownloader: downloader,
        // These cases watch the current song's single download.
        nextSongPrefetchAllowed: false,
        supportsTranscodeOffset: capable,
        fastSeeking: enabled,
        wrapResolver: wrap,
        crossfade: crossfade,
        streamingQuality: transcode
            ? const StreamingQuality(
                label: 'opus',
                format: 'opus',
                maxBitRate: 128,
              )
            : const StreamingQuality(label: 'original'),
        timeouts: const NavisPlaybackTimeouts(
          fastSeekGuard: Duration(milliseconds: 500),
          desktopSeekSettle: Duration(seconds: 1),
        ),
        seed: (db) => db.libraryDao.upsertSongs([
          for (var i = 0; i < 3; i++)
            SongsTableCompanion.insert(
              id: 'song-$i',
              title: 'Song $i',
              duration: const Value(180),
              suffix: Value(lossy ? 'mp3' : 'flac'),
              bitRate: const Value(1000),
              isExternal: Value(external),
            ),
        ]),
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await db.close();
        await directory.delete(recursive: true);
      });
      player.simulateProgress = true;
      await handler.replaceQueue(
        ['song-0', 'song-1', 'song-2'],
        startIndex: 1,
        expandMatchFlows: false,
      );
      await settleQueue(handler);
      await handler.play();
      return (handler, player, db, downloader);
    }

    UriAudioSource current(_ControllableAudioPlayer player) =>
        player.sequence[player.index!] as UriAudioSource;
    Future<void> seekTo(NavisAudioHandler handler, Duration position) async {
      await handler.seek(position);
      await settleQueue(handler);
    }

    Map<String, Object?> event(NavisAudioHandler handler) =>
        (handler.collectPlaybackDiagnostics()['seekEvents']! as List).last
            as Map<String, Object?>;
    bool bridging(NavisAudioHandler handler) =>
        handler.mediaItem.value?.extras?['bridgeFormat'] == 'opus';

    for (final slow in [false, true]) {
      test(
        'seek preview opens only the immediate bridge plan (slow=$slow)',
        () async {
          final (handler, player, _, _) = await bridgeHandler(slow: slow);
          final client = _SeekPreviewHttpClient()..respond();
          await HttpOverrides.runZoned(
            () => handler.previewSeek(target),
            createHttpClient: (_) => client,
          );
          await pumpEventQueue();
          expect(client.gets, slow ? 1 : 0);
          if (slow) {
            await handler.seek(target);
            // ignore: experimental_member_use, reason: Verify bridge preview adoption through the proxy.
            final source = player.sequence[player.index!] as StreamAudioSource;
            final response = await source.request();
            final sub = response.stream.listen((_) {});
            await sub.cancel();
            expect(client.gets, 1);
          }
          handler.cancelSeekPreview();
          unawaited(client.body.close());
        },
      );
    }

    test('slow link bridges immediately without restarting or caching the transcode', () async {
      final (handler, player, db, downloader) = await bridgeHandler();
      final starts = downloader.starts;
      await seekTo(handler, target);
      expect(bridging(handler), isTrue);
      expect(current(player).uri.queryParameters['format'], 'opus');
      expect(current(player).uri.queryParameters['maxBitRate'], '256');
      expect(current(player).positionOffset, target);
      expect(downloader.starts, starts);
      expect(event(handler)['path'], 'fastSeekBridge');
      expect(handler.collectPlaybackDiagnostics()['anomalies'], isEmpty);
      expect(downloader.downloadUri!.queryParameters['timeOffset'], isNull);
      downloader.bytes += 65536;
      downloader.progress!(.2);
      expect(handler.collectPlaybackDiagnostics()['partialCacheBytes'], 131072);
      await downloader.finish();
      final cached = (await db.cacheDao.getCachedTrack('song-1'))!;
      expect(cached.filePath, downloader.path);
      expect(cached.format, 'flac');
      expect(cached.bitRate, 1000);
      expect(cached.fileSize, 131072);
      expect(bridging(handler), isTrue);
      await seekTo(handler, const Duration(seconds: 110));
      expect(current(player).uri.scheme, 'file');
      expect(bridging(handler), isFalse);
      expect(handler.mediaItem.value!.extras, isNot(contains('bridgeBitRate')));
    });

    test(
      'bridge keeps playing when the original sidecar ends without a file',
      () async {
        final (handler, player, db, downloader) = await bridgeHandler();
        await seekTo(handler, target);
        final source = current(player);
        await downloader.cancel();
        expect(bridging(handler), isTrue);
        expect(player.playing, isTrue);
        expect(current(player), same(source));
        expect(handler.collectPlaybackDiagnostics()['cacheActivity'], isNull);
        expect(await db.cacheDao.getCachedTrack('song-1'), isNull);
        expect(File(downloader.path!).existsSync(), isFalse);
      },
    );

    test(
      'bridge started without an active sidecar downloads the original',
      () async {
        final (handler, player, db, downloader) = await bridgeHandler();
        await downloader.cancel();
        player.ignoredSeeks = 1;
        await seekTo(handler, target);
        expect(bridging(handler), isTrue);
        expect(
          downloader.downloadUri!.queryParameters['format'],
          isNot('opus'),
        );
        await downloader.finish();
        final cached = (await db.cacheDao.getCachedTrack('song-1'))!;
        expect(cached.format, 'flac');
        expect(cached.bitRate, 1000);
      },
    );

    test(
      'installed bridge load failure restores the native queue before fallback',
      () async {
        final (handler, player, _, downloader) = await bridgeHandler();
        final starts = downloader.starts;
        final notices = <PlaybackLoadFailure>[];
        final subscription = handler.loadFailureStream.listen(notices.add);
        addTearDown(subscription.cancel);
        player.rejectBridgeLoad = true;
        await seekTo(handler, target);
        expectNativeMirrorsQueue(handler, player);
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(current(player).positionOffset, Duration.zero);
        expect(current(player).uri.queryParameters['format'], isNot('opus'));
        expect(bridging(handler), isFalse);
        expect(event(handler)['outcome'], 'completed');
        expect(notices, isEmpty);
        expect(downloader.starts, starts);
      },
    );

    test('native guard exception still attempts the bridge', () async {
      final (handler, player, _, _) = await bridgeHandler(slow: false);
      player.rejectNextSeek = true;
      await seekTo(handler, target);
      expect(bridging(handler), isTrue);
      expect(event(handler)['path'], 'fastSeekBridge');
      expect(player.seekCalls, 1);
    });

    test(
      'paused buffering bridge resumes the original after seek settlement',
      () async {
        final (handler, player, _, downloader) = await bridgeHandler();
        await handler.pause();
        player.bufferAfterLoad = true;
        await seekTo(handler, target);
        expect(bridging(handler), isTrue);
        expect(event(handler)['outcome'], 'completed');
        expect(player.processingState, ProcessingState.buffering);
        expect(player.playing, isFalse);
        expect(downloader.isPaused, isFalse);
        player._events.add(player.playbackEvent);
        await pumpEventQueue(times: 20);
        expect(downloader.isPaused, isFalse);
      },
    );

    for (final milliseconds in [90750, 179750]) {
      test(
        'bridge reload starts at whole-second offset for $milliseconds ms',
        () async {
          final (handler, player, _, _) = await bridgeHandler();
          await seekTo(handler, Duration(milliseconds: milliseconds));
          expect(bridging(handler), isTrue);
          expect(
            player.bridgeInitialPositions.single,
            current(player).positionOffset,
          );
        },
      );
    }

    test('fast or unknown link settles natively without a bridge', () async {
      final (handler, player, _, _) = await bridgeHandler(slow: false);
      final loads = player.sourceLoads;
      await seekTo(handler, target);
      expect(bridging(handler), isFalse);
      expect(player.sourceLoads, loads);
    });

    test('measured fast link keeps a settled native seek', () async {
      final (handler, player, _, downloader) = await bridgeHandler();
      downloader.rate = 10000000;
      final loads = player.sourceLoads;
      await seekTo(handler, target);
      expect(player.sourceLoads, loads);
      expect(bridging(handler), isFalse);
    });

    test('failed bridge falls back silently to the native path', () async {
      late _GatedSourceResolver resolver;
      final (handler, _, _, _) = await bridgeHandler(
        wrap: (base) => resolver = _GatedSourceResolver(base),
      );
      final notices = <PlaybackLoadFailure>[];
      final subscription = handler.loadFailureStream.listen(notices.add);
      addTearDown(subscription.cancel);
      resolver.rejectBridge = true;
      await seekTo(handler, target);
      expect(bridging(handler), isFalse);
      expect(notices, isEmpty);
      expect(event(handler)['outcome'], 'completed');
    });

    test(
      'crossfade hands over from a bridge to a plain lossless song',
      () async {
        final (handler, player, _, downloader) = await bridgeHandler(
          crossfade: true,
        );
        await seekTo(handler, target);
        final incoming = handler.debugInactiveDeck! as _ControllableAudioPlayer;
        incoming.simulateProgress = true;
        player.simulatedPosition = const Duration(seconds: 175);
        await handler.debugStartCrossfade();
        await handler.debugCompleteCrossfade();
        await settleQueue(handler);
        expect(handler.snapshot.currentSongId, 'song-2');
        expect(bridging(handler), isFalse);
        expect(downloader.isPaused, isFalse);
        expect(current(incoming).positionOffset, Duration.zero);
      },
    );

    test('Android runtime keeps the original native seek', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final (handler, player, _, _) = await bridgeHandler();
      final loads = player.sourceLoads;
      await seekTo(handler, target);
      expect(bridging(handler), isFalse);
      expect(player.sourceLoads, loads);
    });

    test('radio keeps its existing non-seekable behavior', () async {
      final (handler, _, _, _) = await bridgeHandler();
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: 'https://radio.example.invalid/live',
      );
      await handler.seek(target);
      expect(bridging(handler), isFalse);
      expect(handler.snapshot.radioStation?.stationId, 'fixture');
    });

    test('fast link guard expires and opens a bridge', () async {
      final (handler, player, _, _) = await bridgeHandler(slow: false);
      player.ignoredSeeks = 1;
      await seekTo(handler, target);
      expect(bridging(handler), isTrue);
      final probe = (event(handler)['unsettled']! as List).first as Map;
      expect(probe['elapsedMs'], inInclusiveRange(500, 1000));
    });

    test('cache completion during guard uses the local original', () async {
      final (handler, player, _, downloader) = await bridgeHandler(slow: false);
      player.ignoredSeeks = 1;
      final seeking = handler.seek(target);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await downloader.finish();
      await seeking;
      await settleQueue(handler);
      expect(current(player).uri.scheme, 'file');
      expect(bridging(handler), isFalse);
    });

    test('bridge yields while loading and buffering and resumes on ready, upgrade, change and stop', () async {
      final (handler, player, _, downloader) = await bridgeHandler();
      await seekTo(handler, target);
      for (final state in [
        ProcessingState.loading,
        ProcessingState.buffering,
        ProcessingState.ready,
      ]) {
        player.state = state;
        player._events.add(player.playbackEvent);
        await pumpEventQueue(times: 20);
        expect(downloader.isPaused, state != ProcessingState.ready);
      }
      player.state = ProcessingState.buffering;
      player._events.add(player.playbackEvent);
      await pumpEventQueue(times: 20);
      await seekTo(handler, const Duration(seconds: 5));
      expect(bridging(handler), isFalse);
      expect(downloader.isPaused, isFalse);
      await seekTo(handler, target);
      player.state = ProcessingState.buffering;
      player._events.add(player.playbackEvent);
      await pumpEventQueue(times: 20);
      await handler.skipToNext();
      await settleQueue(handler);
      expect(downloader.isPaused, isFalse);
      await seekTo(handler, target);
      player.state = ProcessingState.buffering;
      player._events.add(player.playbackEvent);
      await pumpEventQueue(times: 20);
      await handler.stop();
      player._events.add(player.playbackEvent);
      await pumpEventQueue(times: 20);
      expect(downloader.isPaused, isFalse);
    });

    test(
      'pause resumes the original while a queue edit hides player events',
      () async {
        final (handler, player, _, downloader) = await bridgeHandler();
        await seekTo(handler, target);
        player.state = ProcessingState.buffering;
        player._events.add(player.playbackEvent);
        await pumpEventQueue(times: 20);
        expect(downloader.isPaused, isTrue);
        final gate = Completer<void>();
        player
          ..removeGate = gate
          ..removeEntered = Completer<void>();
        final removing = handler.removeQueueItemAt(2);
        try {
          await player.removeEntered!.future;
          expect(handler.debugQueueLaneIdle, isFalse);
          expect(
            handler.collectPlaybackDiagnostics()['playerMatchesQueue'],
            isFalse,
          );
          await handler.pause();
          player._events.add(player.playbackEvent);
          await pumpEventQueue(times: 20);
          expect(player.playing, isFalse);
          expect(downloader.isPaused, isFalse);
        } finally {
          gate.complete();
          await removing;
        }
        await settleQueue(handler);
      },
    );

    test(
      'seek into downloaded extent upgrades lossless and stays paused',
      () async {
        final (handler, player, _, _) = await bridgeHandler();
        await handler.pause();
        await seekTo(handler, target);
        expect(bridging(handler), isTrue);
        expect(player.playing, isFalse);
        await seekTo(handler, const Duration(seconds: 5));
        expect(bridging(handler), isFalse);
        expect(current(player).positionOffset, Duration.zero);
        expect(current(player).uri.queryParameters['format'], isNot('opus'));
        expect(player.playing, isFalse);
      },
    );

    for (final reject in [false, true]) {
      test(
        'premature transcode EOF recovers a bridge (rejected: $reject)',
        () async {
          late _GatedSourceResolver resolver;
          final (handler, player, _, _) = await bridgeHandler(
            wrap: (base) => resolver = _GatedSourceResolver(base),
          );
          if (reject) {
            await handler.replaceQueue(
              ['song-1', 'song-1', 'song-1'],
              startIndex: 1,
              expandMatchFlows: false,
            );
            await settleQueue(handler);
          }
          await seekTo(handler, target);
          resolver.rejectBridge = reject;
          final events =
              (handler.collectPlaybackDiagnostics()['seekEvents']! as List)
                  .length;
          player.simulatedDuration = const Duration(seconds: 110);

          player.finishCurrentTrack(endPosition: const Duration(seconds: 110));
          for (
            var i = 0;
            i < 300 &&
                (handler.collectPlaybackDiagnostics()['seekEvents']! as List)
                        .length ==
                    events;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await settleQueue(handler);

          expect(
            (handler.collectPlaybackDiagnostics()['seekEvents']! as List)
                .length,
            events + 1,
          );
          expect(handler.snapshot.currentSongId, 'song-1');
          expect(player.index, 1);
          expect(player.position.inSeconds, 110);
          expect(bridging(handler), !reject);
          expect(
            current(player).positionOffset,
            reject ? Duration.zero : const Duration(seconds: 110),
          );
          expect(player.playing, isTrue);
        },
      );
    }

    test('Repeat One returns to lossless', () async {
      final (handler, player, _, _) = await bridgeHandler();
      await seekTo(handler, target);
      await handler.setRepeatMode(AudioServiceRepeatMode.one);
      player.finishCurrentTrack(endPosition: const Duration(seconds: 180));
      for (var i = 0; i < 300 && bridging(handler); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await settleQueue(handler);
      expect(bridging(handler), isFalse);
      expect(current(player).positionOffset, Duration.zero);
    });

    test('advancing away and back clears bridge extras', () async {
      final (handler, player, _, _) = await bridgeHandler();
      await seekTo(handler, target);
      await handler.skipToNext();
      await settleQueue(handler);
      player.simulatedPosition = Duration.zero;
      await handler.skipToPrevious();
      await settleQueue(handler);
      expect(handler.snapshot.currentSongId, 'song-1');
      expect(bridging(handler), isFalse);
      expect(current(player).positionOffset, Duration.zero);
    });

    test('recovery preserves a bridge at the exact song position', () async {
      final (handler, player, _, _) = await bridgeHandler();
      await seekTo(handler, target);
      player.simulatedPosition = const Duration(milliseconds: 110750);
      player.state = ProcessingState.idle;
      player._events.addError(PlayerException(2002, 'Read timed out', 1));
      for (
        var i = 0;
        i < 300 && current(player).positionOffset.inSeconds != 110;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await settleQueue(handler);
      expect(bridging(handler), isTrue);
      expect(current(player).uri.queryParameters['timeOffset'], '110');
      expect(
        player.position,
        greaterThanOrEqualTo(const Duration(seconds: 110)),
      );
      expect(player.position, lessThan(const Duration(seconds: 112)));
    });

    for (final rejectBridge in [false, true]) {
      test(
        'completed original replaces the bridge during remote recovery, bridge fails=$rejectBridge',
        () async {
          late _GatedSourceResolver resolver;
          final (handler, player, _, downloader) = await bridgeHandler(
            wrap: (base) => resolver = _GatedSourceResolver(base),
          );
          await seekTo(handler, target);
          await downloader.finish();
          resolver.rejectBridge = rejectBridge;
          player.simulatedPosition = const Duration(milliseconds: 110750);
          player.state = ProcessingState.idle;
          final before =
              (handler.collectPlaybackDiagnostics()['seekEvents']! as List)
                  .length;
          player._events.addError(PlayerException(2002, 'Read timed out', 1));
          for (
            var i = 0;
            i < 300 &&
                (handler.collectPlaybackDiagnostics()['seekEvents']! as List)
                        .length ==
                    before;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await settleQueue(handler);
          expect(handler.snapshot.currentSongId, 'song-1');
          expect(bridging(handler), isFalse);
          expect(current(player).uri.scheme, 'file');
          expect(current(player).positionOffset, Duration.zero);
          expectNativeMirrorsQueue(handler, player);
          expect(
            player.position,
            greaterThanOrEqualTo(const Duration(milliseconds: 110750)),
          );
        },
      );
    }

    for (final completesDuringReopen in [true, false]) {
      test(
        'failed bridge recovery falls back without skipping, cache completes during reopen=$completesDuringReopen',
        () async {
          final (handler, player, _, downloader) = await bridgeHandler();
          await seekTo(handler, target);
          final starts = downloader.starts;
          final loads = player.sourceLoads;
          final notices = <PlaybackLoadFailure>[];
          final subscription = handler.loadFailureStream.listen(notices.add);
          addTearDown(subscription.cancel);
          final gate = Completer<void>();
          player
            ..rejectBridgeLoad = true
            ..loadGate = gate
            ..loadEntered = Completer<void>()
            ..simulatedPosition = const Duration(milliseconds: 110750)
            ..state = ProcessingState.idle;
          final before =
              (handler.collectPlaybackDiagnostics()['seekEvents']! as List)
                  .length;
          player._events.addError(PlayerException(2002, 'Read timed out', 1));
          try {
            await player.loadEntered!.future;
            if (completesDuringReopen) await downloader.finish();
          } finally {
            gate.complete();
          }
          for (
            var i = 0;
            i < 300 &&
                (handler.collectPlaybackDiagnostics()['seekEvents']! as List)
                        .length ==
                    before;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await settleQueue(handler);
          expect(handler.snapshot.currentSongId, 'song-1');
          expect(event(handler)['outcome'], 'reloaded');
          expect(
            player.sourceLoads,
            loads + 2,
            reason: 'row 03: one bridge and one original open',
          );
          expect(
            event(handler)['recoveryPath'],
            completesDuringReopen ? 'completedFile' : 'original',
            reason: 'row 04: attribute the selected fallback',
          );
          expect(bridging(handler), isFalse);
          expect(
            handler.mediaItem.value!.extras,
            isNot(contains('bridgeBitRate')),
          );
          expect(
            current(player).uri.scheme,
            completesDuringReopen ? 'file' : 'https',
          );
          expect(current(player).uri.queryParameters['format'], isNot('opus'));
          expect(current(player).uri.queryParameters['timeOffset'], isNull);
          expect(handler.mediaItem.value!.extras!['resolvedFormat'], 'flac');
          expect(current(player).positionOffset, Duration.zero);
          expectNativeMirrorsQueue(handler, player);
          expect(
            player.position,
            greaterThanOrEqualTo(const Duration(milliseconds: 110750)),
          );
          expect(player.position, lessThan(const Duration(seconds: 112)));
          expect(player.playing, isTrue);
          expect(notices, isEmpty);
          expect(downloader.starts, starts);
        },
      );
    }

    test(
      'row 04 rejected bridge resolver reports the original recovery path',
      () async {
        late _GatedSourceResolver resolver;
        final (handler, player, _, _) = await bridgeHandler(
          wrap: (base) => resolver = _GatedSourceResolver(base),
        );
        await seekTo(handler, target);
        resolver.rejectBridge = true;
        final before =
            (handler.collectPlaybackDiagnostics()['seekEvents']! as List)
                .length;
        player
          ..simulatedPosition = const Duration(seconds: 110)
          ..state = ProcessingState.idle;
        player._events.addError(PlayerException(2002, 'Read timed out', 1));
        for (
          var i = 0;
          i < 300 &&
              (handler.collectPlaybackDiagnostics()['seekEvents']! as List)
                      .length ==
                  before;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await settleQueue(handler);
        expect(event(handler)['recoveryPath'], 'original');
        expect(bridging(handler), isFalse);
      },
    );

    test(
      'row 17 newer Fast Seeking target wins while cut reopen resolves',
      () async {
        late _GatedSourceResolver resolver;
        final (handler, player, _, _) = await bridgeHandler(
          wrap: (base) => resolver = _GatedSourceResolver(base),
        );
        await seekTo(handler, target);
        resolver
          ..blockedSongId = 'song-1'
          ..entered = Completer<void>()
          ..release = Completer<void>();
        addTearDown(() {
          if (!resolver.release!.isCompleted) resolver.release!.complete();
        });
        player.finishCurrentTrack(endPosition: const Duration(seconds: 110));
        await resolver.entered!.future.timeout(const Duration(seconds: 3));
        final newer = handler.seek(const Duration(seconds: 140));
        resolver
          ..blockedSongId = null
          ..release!.complete();
        await newer;
        await settleQueue(handler);
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(player.index, 1);
        expect(bridging(handler), isTrue);
        expect(current(player).positionOffset, const Duration(seconds: 140));
        expect(player.playing, isTrue);
        expectNativeMirrorsQueue(handler, player);
      },
    );

    test('superseded bridge seek reloads only the newest target and clamps the tail', () async {
      late _GatedSourceResolver resolver;
      final (handler, player, _, _) = await bridgeHandler(
        wrap: (base) => resolver = _GatedSourceResolver(base),
      );
      resolver
        ..blockedSongId = 'song-1'
        ..entered = Completer<void>()
        ..release = Completer<void>();
      final loads = player.sourceLoads;
      final first = handler.seek(target);
      await resolver.entered!.future;
      final latest = handler.seek(const Duration(seconds: 180));
      resolver
        ..blockedSongId = null
        ..release!.complete();
      await Future.wait([first, latest]);
      await settleQueue(handler);
      expect(current(player).positionOffset, const Duration(seconds: 179));
      expect(player.sourceLoads, loads + 1);
    });

    for (final gate in [
      'off',
      'unsupported',
      'lossy',
      'transcode',
      'external',
    ]) {
      test('gate $gate keeps existing behavior', () async {
        final (handler, _, _, _) = await bridgeHandler(
          enabled: gate != 'off',
          capable: gate != 'unsupported',
          lossy: gate == 'lossy',
          transcode: gate == 'transcode',
          external: gate == 'external',
        );
        await seekTo(handler, target);
        expect(bridging(handler), isFalse);
      });
    }
  }, skip: !sqliteAvailable);

  group('transcode offset seek', () {
    const opus128 = StreamingQuality(
      label: 'opus',
      maxBitRate: 128,
      format: 'opus',
    );

    Future<(NavisAudioHandler, _ControllableAudioPlayer, NavisDatabase)>
    offsetHandler({
      bool capable = true,
      bool? desktopRuntimeOverride,
      StreamingQuality quality = opus128,
      int count = 3,
      NavisQueueWindow queueWindow = const NavisQueueWindow(),
      SubsonicApiClient? Function()? readApiClient,
      ScrobbleService? scrobbleService,
      bool positionStreams = false,
      NavisPlaybackTimeouts timeouts = const NavisPlaybackTimeouts(),
      List<_ControllableAudioPlayer>? rebuiltPlayers,
      PlaybackSourceResolver Function(PlaybackSourceResolver)? wrapResolver,
    }) async {
      final directory = await Directory.systemTemp.createTemp('navis-offset-');
      final created = await createHandler(
        directory,
        count,
        sidecarStreams: true,
        streamingQuality: quality,
        supportsTranscodeOffset: capable,
        desktopRuntimeOverride: desktopRuntimeOverride,
        readApiClient: readApiClient,
        scrobbleService: scrobbleService,
        positionStreams: positionStreams,
        timeouts: timeouts,
        rebuiltPlayers: rebuiltPlayers,
        wrapResolver: wrapResolver,
        queueWindow: queueWindow,
      );
      addTearDown(() async {
        await created.$1.disposeHandler();
        await created.$3.close();
        await directory.delete(recursive: true);
      });
      created.$2.simulateProgress = true;
      return created;
    }

    UriAudioSource current(_ControllableAudioPlayer player) =>
        player.sequence[player.index!] as UriAudioSource;

    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 300 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(condition(), isTrue);
    }

    Future<void> start(NavisAudioHandler handler) async {
      await handler.replaceQueue(
        ['song-0', 'song-1', 'song-2'],
        startIndex: 1,
        expandMatchFlows: false,
      );
      await settleQueue(handler);
      await handler.play();
    }

    Future<void> seekAndSettle(NavisAudioHandler handler, Duration to) async {
      await handler.seek(to);
      await until(() => !handler.snapshot.isLoading);
    }

    Map<String, Object?> lastSeekEvent(NavisAudioHandler handler) =>
        (handler.collectPlaybackDiagnostics()['seekEvents']! as List).last
            as Map<String, Object?>;

    Future<void> failAt(
      NavisAudioHandler handler,
      _ControllableAudioPlayer player,
      Duration position,
    ) async {
      final events =
          (handler.collectPlaybackDiagnostics()['seekEvents']! as List).length;
      player
        ..simulatedPosition = position
        ..state = ProcessingState.idle;
      // Duplicate native failures must not start two reloads.
      player._events.addError(PlayerException(2002, 'Read timed out', 1));
      player._events.addError(PlayerException(2002, 'Read timed out', 1));
      await until(
        () =>
            (handler.collectPlaybackDiagnostics()['seekEvents']! as List)
                .length >
            events,
      );
      await until(() => !handler.snapshot.isLoading);
    }

    group('seek preview', () {
      for (final platform in [TargetPlatform.linux, TargetPlatform.android]) {
        test('seek preview sends the native User-Agent ($platform)', () async {
          debugDefaultTargetPlatformOverride = platform;
          final (handler, _, _) = await offsetHandler(
            desktopRuntimeOverride: platform == TargetPlatform.linux,
          );
          await start(handler);
          if (platform == TargetPlatform.android) {
            handler.queue.value[1].extras!['positionOffsetMs'] = 40000;
          }
          final client = _SeekPreviewHttpClient()..respond();
          addTearDown(() {
            unawaited(client.body.close());
          });
          await HttpOverrides.runZoned(
            () => handler.previewSeek(const Duration(seconds: 90)),
            createHttpClient: (_) => client,
          );
          expect(
            client.userAgent,
            platform == TargetPlatform.linux
                ? 'Navis Desktop'
                : AppConstants.userAgent,
          );
          handler.cancelSeekPreview();
          debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        });
      }

      test(
        'seek preview adopts the desired occurrence while native index lags',
        () async {
          late _GatedSourceResolver resolver;
          final (handler, player, _) = await offsetHandler(
            wrapResolver: (delegate) =>
                resolver = _GatedSourceResolver(delegate),
          );
          await start(handler);
          final client = _SeekPreviewHttpClient()..respond();
          addTearDown(() {
            unawaited(client.body.close());
          });
          await HttpOverrides.runZoned(
            () => handler.previewSeek(const Duration(seconds: 90)),
            createHttpClient: (_) => client,
          );
          resolver
            ..blockedSongId = 'song-1'
            ..entered = Completer<void>()
            ..release = Completer<void>();
          final seek = handler.seek(const Duration(seconds: 90));
          await resolver.entered!.future;
          player.index = 0;
          resolver.release!.complete();
          await seek;
          expect(lastSeekEvent(handler)['previewAdopted'], isTrue);
        },
      );

      for (final action in ['loop', 'depart']) {
        test(
          'seek preview stream offset survives cleared entry metadata ($action)',
          () async {
            final (handler, player, _) = await offsetHandler();
            await start(handler);
            final client = _SeekPreviewHttpClient()..respond();
            addTearDown(() {
              unawaited(client.body.close());
            });
            await HttpOverrides.runZoned(
              () => handler.previewSeek(const Duration(seconds: 90)),
              createHttpClient: (_) => client,
            );
            await handler.seek(const Duration(seconds: 90));
            expect(
              player.sequence[1].positionOffset,
              const Duration(seconds: 90),
            );
            handler.queue.value[1].extras!['positionOffsetMs'] = 0;
            final seekCalls = player.seekCalls;
            if (action == 'loop') {
              await handler.setRepeatMode(AudioServiceRepeatMode.one);
              player.finishCurrentTrack(
                endPosition: const Duration(seconds: 180),
              );
            } else {
              await handler.skipToNext();
            }
            if (action == 'loop') {
              await until(
                () => lastSeekEvent(handler)['requestedPositionMs'] == 0,
              );
              expect(player.seekCalls, greaterThan(seekCalls));
            } else {
              await until(
                () => player.sequence[1].positionOffset == Duration.zero,
              );
            }
          },
        );
      }

      for (final delta in [0, 2, 3, -1]) {
        test(
          'adopts only release 0..2 seconds after preview (delta=$delta)',
          () async {
            final client = _SeekPreviewHttpClient()..respond();
            addTearDown(() {
              client.close(force: true);
              unawaited(client.body.close());
            });
            final (handler, player, _) = await offsetHandler();
            await start(handler);
            final before = handler.snapshot;
            await HttpOverrides.runZoned(
              () => handler.previewSeek(const Duration(seconds: 90)),
              createHttpClient: (_) => client,
            );
            await until(() => client.gets == 1);
            expect(handler.snapshot, before);
            expect(handler.snapshot.pendingSeekPosition, isNull);
            await handler.previewSeek(const Duration(seconds: 90));
            expect(client.gets, 1);
            await handler.seek(Duration(seconds: 90 + delta));
            final source = player.sequence[player.index!];
            if (delta >= 0 && delta <= 2) {
              // ignore: experimental_member_use, reason: Verify the adopted proxy source.
              expect(source, isA<StreamAudioSource>());
              // ignore: experimental_member_use, reason: Consume the adopted proxy response.
              final response = await (source as StreamAudioSource).request();
              final sub = response.stream.listen((_) {});
              await pumpEventQueue();
              expect(client.gets, 1);
              await sub.cancel();
            } else {
              expect(source, isA<UriAudioSource>());
            }
          },
        );
      }

      test('50 alternating handler previews cancel before opening, final release adopts', () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        final clients = <_SeekPreviewHttpClient>[];
        for (var i = 0; i < 50; i++) {
          final client = _SeekPreviewHttpClient();
          clients.add(client);
          await HttpOverrides.runZoned(
            () => handler.previewSeek(Duration(seconds: i.isEven ? 40 : 140)),
            createHttpClient: (_) {
              expect(
                clients.take(clients.length - 1).every((c) => c.closed),
                isTrue,
              );
              return client;
            },
          );
          if (i != 0) clients[i - 1].respond();
          await pumpEventQueue();
          expect(clients.where((c) => !c.closed).length, 1);
          expect(
            clients.where((c) => c.body.hasListener).length,
            lessThanOrEqualTo(1),
          );
        }
        clients.last.respond();
        clients.last.body.add([1, 2, 3]);
        await pumpEventQueue();
        await handler.seek(const Duration(seconds: 140));
        // ignore: experimental_member_use, reason: Verify final release consumes the last request.
        final source = player.sequence[player.index!] as StreamAudioSource;
        final response = await source.request();
        final result = response.stream.expand((b) => b).toList();
        await clients.last.body.close();
        expect(await result, [1, 2, 3]);
        for (final client in clients) {
          expect(client.closed, isTrue);
          expect(client.gets, 1);
          expect(client.body.hasListener, isFalse);
          if (!client.body.isClosed) unawaited(client.body.close());
        }
      });

      for (final intent in [
        'cancel',
        'pause',
        'play',
        'next',
        'stop',
        'repeat',
      ]) {
        test('$intent closes a pending preview socket', () async {
          final (handler, _, _) = await offsetHandler();
          await start(handler);
          final client = _SeekPreviewHttpClient();
          await HttpOverrides.runZoned(
            () => handler.previewSeek(const Duration(seconds: 90)),
            createHttpClient: (_) => client,
          );
          switch (intent) {
            case 'cancel':
              handler.cancelSeekPreview();
            case 'pause':
              await handler.pause();
            case 'play':
              await handler.play();
            case 'next':
              await handler.skipToNext();
            case 'stop':
              await handler.stop();
            case 'repeat':
              await handler.setRepeatMode(AudioServiceRepeatMode.one);
          }
          expect(client.closed, isTrue);
          client.respond();
          await pumpEventQueue();
          expect(client.body.hasListener, isFalse);
          unawaited(client.body.close());
        });
      }

      test(
        'superseding an adopted preview closes it while native load waits',
        () async {
          final (handler, player, _) = await offsetHandler();
          await start(handler);
          final client = _SeekPreviewHttpClient();
          await HttpOverrides.runZoned(
            () => handler.previewSeek(const Duration(seconds: 90)),
            createHttpClient: (_) => client,
          );
          player.loadEntered = Completer<void>();
          final loadGate = Completer<void>();
          player.loadGate = loadGate;
          final seek = handler.seek(const Duration(seconds: 90));
          await player.loadEntered!.future;
          final next = handler.skipToNext();
          expect(client.closed, isTrue);
          loadGate.complete();
          await seek;
          await next;
          client.respond();
          await pumpEventQueue();
          expect(client.body.hasListener, isFalse);
          unawaited(client.body.close());
        },
      );

      test('unused preview expires after ten seconds', () async {
        final (handler, _, _) = await offsetHandler();
        await start(handler);
        final client = _SeekPreviewHttpClient();
        fakeAsync((clock) {
          HttpOverrides.runZoned(() {
            unawaited(handler.previewSeek(const Duration(seconds: 90)));
          }, createHttpClient: (_) => client);
          clock.flushMicrotasks();
          expect(client.closed, isFalse);
          clock.elapse(const Duration(seconds: 10));
          expect(client.closed, isTrue);
          client.respond();
          clock.flushMicrotasks();
        });
        unawaited(client.body.close());
      });

      test('representation mismatch discards and keeps the ordinary release offset', () async {
        late _GatedSourceResolver resolver;
        final (handler, player, _) = await offsetHandler(
          wrapResolver: (delegate) => resolver = _GatedSourceResolver(delegate),
        );
        await start(handler);
        final client = _SeekPreviewHttpClient()..respond();
        await HttpOverrides.runZoned(
          () => handler.previewSeek(const Duration(seconds: 90)),
          createHttpClient: (_) => client,
        );
        resolver.previewRepresentation = Object();
        await handler.seek(const Duration(seconds: 92));
        expect(client.closed, isTrue);
        expect(current(player).positionOffset, const Duration(seconds: 92));
        expect(current(player).uri.queryParameters['timeOffset'], '92');
        expect(client.gets, 1);
        unawaited(client.body.close());
      });

      test(
        'discarding a preview after cache completion keeps the release target',
        () async {
          late _GatedSourceResolver resolver;
          final (handler, player, database) = await offsetHandler(
            wrapResolver: (delegate) =>
                resolver = _GatedSourceResolver(delegate),
          );
          await start(handler);
          final client = _SeekPreviewHttpClient()..respond();
          await HttpOverrides.runZoned(
            () => handler.previewSeek(const Duration(seconds: 90)),
            createHttpClient: (_) => client,
          );
          resolver.blockedSongId = 'song-1';
          resolver.entered = Completer<void>();
          resolver.release = Completer<void>();
          addTearDown(() {
            if (!resolver.release!.isCompleted) resolver.release!.complete();
          });
          final seek = handler.seek(const Duration(seconds: 92));
          await resolver.entered!.future;
          final directory = await Directory.systemTemp.createTemp(
            'navis-preview-completed-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final file = File(p.join(directory.path, 'completed.opus'));
          await file.writeAsBytes([1, 2, 3]);
          await database.cacheDao.upsertCachedTrack(
            CachedTracksTableCompanion.insert(
              songId: 'song-1',
              filePath: file.path,
              fileSize: 3,
              cacheType: CacheType.rolling,
              downloadStatus: DownloadStatus.complete,
              format: 'opus',
              lastAccessedAt: DateTime(2026),
              bitRate: const Value(128),
            ),
          );
          resolver.release!.complete();
          await seek;
          expect(client.closed, isTrue);
          expect(current(player).uri.scheme, 'file');
          expect(player.playedFrom.last, const Duration(seconds: 92));
          expect(client.gets, 1);
          unawaited(client.body.close());
        },
      );

      test('adoption retains metadata updated during the drag', () async {
        final (handler, _, database) = await offsetHandler();
        await start(handler);
        final client = _SeekPreviewHttpClient()..respond();
        await HttpOverrides.runZoned(
          () => handler.previewSeek(const Duration(seconds: 90)),
          createHttpClient: (_) => client,
        );
        await database.libraryDao.upsertSongs([
          const SongsTableCompanion(
            id: Value('song-1'),
            title: Value('Updated title'),
          ),
        ]);
        await handler.seek(const Duration(seconds: 90));
        expect(handler.currentMediaItem!.title, 'Updated title');
        expect(client.gets, 1);
        client.close(force: true);
        unawaited(client.body.close());
      });

      test('completed local source opens no preview request', () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-preview-local-',
        );
        final (handler, _, database) = await createHandler(
          directory,
          1,
          supportsTranscodeOffset: true,
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        await handler.replaceQueue(
          ['song-0'],
          autoPlay: false,
          expandMatchFlows: false,
        );
        await settleQueue(handler);
        final client = _SeekPreviewHttpClient();
        await HttpOverrides.runZoned(
          () => handler.previewSeek(const Duration(seconds: 90)),
          createHttpClient: (_) => client,
        );
        expect(client.gets, 0);
        expect(handler.collectPlaybackDiagnostics()['seekPreview'], isNull);
        unawaited(client.body.close());
      });

      test('native and local plans do not open preview requests', () async {
        final (handler, _, _) = await offsetHandler(capable: false);
        await start(handler);
        await handler.previewSeek(const Duration(seconds: 90));
        expect(handler.collectPlaybackDiagnostics()['seekPreview'], isNull);
      });
    });

    group('premature transcode EOF', () {
      Future<(NavisAudioHandler, _ControllableAudioPlayer)> setup({
        bool last = false,
        bool capable = true,
        bool original = false,
        int? duration = 300,
        ScrobbleService? scrobbleService,
        void Function(NavisDatabase)? onDatabase,
        PlaybackSourceResolver Function(PlaybackSourceResolver)? wrap,
      }) async {
        final (handler, player, database) = await offsetHandler(
          capable: capable,
          quality: original
              ? const StreamingQuality(label: 'original')
              : opus128,
          wrapResolver: wrap,
          scrobbleService: scrobbleService,
          positionStreams: scrobbleService != null,
        );
        onDatabase?.call(database);
        await database.libraryDao.upsertSongs([
          for (final id in ['song-0', 'song-1', 'song-2'])
            SongsTableCompanion.insert(
              id: id,
              title: id,
              duration: Value(duration),
            ),
        ]);
        await handler.replaceQueue(
          ['song-0', 'song-1', if (!last) 'song-2'],
          startIndex: 1,
          expandMatchFlows: false,
        );
        await settleQueue(handler);
        await handler.play();
        // Native duration can shrink to the truncated stream's length.
        player.simulatedDuration = const Duration(seconds: 47);
        return (handler, player);
      }

      Future<void> drain(NavisAudioHandler handler) async {
        await pumpEventQueue(times: 100);
        await settleQueue(handler);
      }

      test('row 15 queued append preserves the classified cut', () async {
        final (handler, player, database) = await offsetHandler();
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Song 1',
            duration: const Value(300),
          ),
        ]);
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..afterAppendGate = gate
          ..afterAppendEntered = entered;
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final loading = handler.replaceQueue(
          ['song-0', 'song-1', 'song-2'],
          startIndex: 1,
          expandMatchFlows: false,
        );
        await entered.future.timeout(const Duration(seconds: 3));
        final editing = handler.addToQueue(['song-0'], expandMatchFlows: false);
        await pumpEventQueue(times: 20);
        player.finishCurrentTrack(
          endPosition: const Duration(milliseconds: 47750),
        );
        await pumpEventQueue(times: 20);
        gate.complete();
        await Future.wait([loading, editing]);
        await drain(handler);
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(handler.snapshot.currentIndex, 1);
        expect(current(player).positionOffset, const Duration(seconds: 47));
        expect(player.playing, isTrue);
        expect(handler.snapshot.queueSongIds, [
          'song-0',
          'song-1',
          'song-2',
          'song-0',
        ]);
        expectNativeMirrorsQueue(handler, player);
      });

      for (final delayedPause in [false, true]) {
        for (final intent in ['none', 'Play', 'Pause']) {
          test('row 15 removed cut releases its pause with $intent '
              '(delayed acknowledgement: $delayedPause)', () async {
            final (handler, player, database) = await offsetHandler();
            await database.libraryDao.upsertSongs([
              SongsTableCompanion.insert(
                id: 'song-1',
                title: 'Song 1',
                duration: const Value(300),
              ),
            ]);
            final fill = Completer<void>();
            final entered = Completer<void>();
            final pause = Completer<void>();
            final paused = Completer<void>();
            addTearDown(() {
              if (!fill.isCompleted) fill.complete();
              if (!pause.isCompleted) pause.complete();
            });
            player
              ..afterAppendGate = fill
              ..afterAppendEntered = entered;
            final loading = handler.replaceQueue(
              ['song-0', 'song-1', 'song-2'],
              startIndex: 1,
              expandMatchFlows: false,
            );
            await entered.future.timeout(const Duration(seconds: 3));
            final editing = handler.removeAt(1);
            await pumpEventQueue(times: 20);
            final loads = player.sourceLoads;
            if (delayedPause) {
              player
                ..pauseGate = pause
                ..pauseEntered = paused;
            }
            player.finishCurrentTrack(
              endPosition: const Duration(milliseconds: 47750),
            );
            await pumpEventQueue(times: 20);
            if (delayedPause) await paused.future;
            if (intent == 'Play') await handler.play();
            if (intent == 'Pause') await handler.pause();
            fill.complete();
            await Future.wait([loading, editing]);
            await drain(handler);
            if (delayedPause) {
              expect(
                player.playing,
                isFalse,
                reason: 'wait for the owned pause acknowledgement',
              );
              pause.complete();
              await drain(handler);
            }
            expect(handler.snapshot.queueSongIds, ['song-0', 'song-2']);
            expect(handler.snapshot.currentSongId, 'song-2');
            expect(handler.snapshot.currentIndex, 1);
            expect(
              player.playing,
              intent != 'Pause',
              reason: 'release recovery pause with the latest intent',
            );
            expect(
              player.sourceLoads,
              loads,
              reason: 'never reopen the removed occurrence',
            );
            expectNativeMirrorsQueue(handler, player);
          });
        }
      }

      for (final late in ['Pause', 'Play']) {
        test('row 15 removed cut honours a late $late during the pause '
            'acknowledgement', () async {
          final (handler, player, database) = await offsetHandler();
          await database.libraryDao.upsertSongs([
            SongsTableCompanion.insert(
              id: 'song-1',
              title: 'Song 1',
              duration: const Value(300),
            ),
          ]);
          final fill = Completer<void>();
          final entered = Completer<void>();
          final pause = Completer<void>();
          final paused = Completer<void>();
          addTearDown(() {
            if (!fill.isCompleted) fill.complete();
            if (!pause.isCompleted) pause.complete();
          });
          player
            ..afterAppendGate = fill
            ..afterAppendEntered = entered;
          final loading = handler.replaceQueue(
            ['song-0', 'song-1', 'song-2'],
            startIndex: 1,
            expandMatchFlows: false,
          );
          await entered.future.timeout(const Duration(seconds: 3));
          final editing = handler.removeAt(1);
          await pumpEventQueue(times: 20);
          player
            ..pauseGate = pause
            ..pauseEntered = paused;
          player.finishCurrentTrack(
            endPosition: const Duration(milliseconds: 47750),
          );
          await pumpEventQueue(times: 20);
          await paused.future;
          if (late == 'Play') await handler.pause();
          fill.complete();
          await Future.wait([loading, editing]);
          await pumpEventQueue(times: 50);
          // The intent arrives while cleanup still awaits the pause ack.
          if (late == 'Pause') {
            await handler.pause();
          } else {
            await handler.play();
          }
          pause.complete();
          await drain(handler);

          expect(player.playing, late == 'Play');
        });
      }

      for (final intent in ['none', 'Play', 'Pause', 'skip']) {
        test('row 15 cut during native tail fill honors $intent', () async {
          final (handler, player, database) = await offsetHandler();
          await database.libraryDao.upsertSongs([
            SongsTableCompanion.insert(
              id: 'song-1',
              title: 'Song 1',
              duration: const Value(300),
            ),
          ]);
          final gate = Completer<void>();
          final entered = Completer<void>();
          player
            ..afterAppendGate = gate
            ..afterAppendEntered = entered;
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
          final loading = handler.replaceQueue(
            ['song-0', 'song-1', 'song-2'],
            startIndex: 1,
            expandMatchFlows: false,
          );
          await entered.future.timeout(const Duration(seconds: 3));
          expect(handler.debugQueueLaneIdle, isFalse);
          final published = <String?>[];
          final subscription = handler.mediaItem.listen(
            (item) => published.add(item?.id),
          );
          addTearDown(subscription.cancel);
          final loads = player.sourceLoads;
          player.finishCurrentTrack(
            endPosition: const Duration(milliseconds: 47750),
          );
          await pumpEventQueue(times: 20);
          expect(
            player.audibleSongId,
            isNull,
            reason: 'the successor must stay silent while the lane finishes',
          );
          if (intent == 'Play') await handler.play();
          if (intent == 'Pause') await handler.pause();
          final newer = intent == 'skip'
              ? handler.skipToNext()
              : Future<void>.value();
          gate.complete();
          await loading;
          await newer;
          await drain(handler);
          expect(
            handler.snapshot.currentSongId,
            intent == 'skip' ? 'song-2' : 'song-1',
            reason: 'row 15: retain the departed occurrence through fill',
          );
          if (intent == 'skip') {
            expect(player.sourceLoads, lessThanOrEqualTo(loads + 1));
          } else {
            expect(player.sourceLoads, loads + 1);
          }
          expect(
            current(player).positionOffset,
            intent == 'skip' ? Duration.zero : const Duration(seconds: 47),
          );
          expect(player.playing, intent != 'Pause');
          if (intent != 'skip') {
            expect(
              published,
              isNot(contains('song-2')),
              reason: 'the successor must never own metadata',
            );
          }
          if (intent != 'skip') {
            expect(
              (player.position - const Duration(milliseconds: 47750)).abs(),
              lessThan(const Duration(seconds: 1)),
            );
          }
          expect(handler.snapshot.queueSongIds, ['song-0', 'song-1', 'song-2']);
          expectNativeMirrorsQueue(handler, player);
        });
      }

      for (final work in ['release', 'trim', 'advance during release']) {
        test(
          'row 15 cut during deferred tail $work retains the source occurrence',
          () async {
            final (handler, player, database) = await offsetHandler(
              count: 12,
              queueWindow: const NavisQueueWindow(
                deferThreshold: 4,
                ahead: 1,
                lowWater: 1,
                page: 2,
                nearJump: 3,
                behind: 1,
                trimSlack: 0,
              ),
            );
            final ids = List.generate(12, (i) => 'song-$i');
            await database.libraryDao.upsertSongs([
              for (final id in ids)
                SongsTableCompanion.insert(
                  id: id,
                  title: id,
                  duration: const Value(300),
                ),
            ]);
            await handler.replaceQueue(
              ids,
              startIndex: work == 'trim' ? 10 : 0,
              expandMatchFlows: false,
            );
            await drain(handler);
            final release = Completer<void>();
            final entered = Completer<void>();
            addTearDown(() {
              if (!release.isCompleted) release.complete();
            });
            if (work == 'trim') {
              player
                ..removeGate = release
                ..removeEntered = entered;
            } else {
              player
                ..afterAppendGate = release
                ..afterAppendEntered = entered;
            }
            player.moveTo(work == 'trim' ? 2 : 1);
            await entered.future.timeout(const Duration(seconds: 3));
            expect(handler.debugQueueLaneIdle, isFalse);
            final loads = player.sourceLoads;
            if (work == 'advance during release') {
              player.finishCurrentTrack(
                endPosition: const Duration(seconds: 300),
              );
              await pumpEventQueue(times: 20);
            }
            player.finishCurrentTrack(
              endPosition: const Duration(milliseconds: 47750),
            );
            await pumpEventQueue(times: 20);
            release.complete();
            await drain(handler);
            expect(
              player.sourceLoads,
              loads + 1,
              reason: 'row 15: cut while $work owns the lane must reopen once',
            );
            expect(
              handler.snapshot.currentSongId,
              work == 'trim'
                  ? 'song-11'
                  : work == 'advance during release'
                  ? 'song-2'
                  : 'song-1',
            );
            expect(current(player).positionOffset, const Duration(seconds: 47));
            expect(
              (player.position - const Duration(milliseconds: 47750)).abs(),
              lessThan(const Duration(seconds: 1)),
            );
            expect(handler.snapshot.queueSongIds, ids);
            expect(player.playing, isTrue);
            expectNativeMirrorsQueue(handler, player);
          },
        );
      }

      for (final duplicate in [false, true]) {
        test(
          'cut after artwork refresh recovers the occurrence (duplicate: $duplicate)',
          () async {
            final directory = await Directory.systemTemp.createTemp(
              'navis-cut-art-',
            );
            const channel = MethodChannel('plugins.flutter.io/path_provider');
            final messenger = TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger;
            messenger.setMockMethodCallHandler(
              channel,
              (_) async => directory.path,
            );
            PlaybackArtCache.resetKeyForTesting();
            addTearDown(() async {
              messenger.setMockMethodCallHandler(channel, null);
              PlaybackArtCache.resetKeyForTesting();
              await directory.delete(recursive: true);
            });
            await PlaybackArtCache.initializeKey(supportDirectory: directory);
            await File(
              p.join(
                directory.path,
                'navis_art_v2_${PlaybackArtCache.fileKey('cut-cover')}.jpg',
              ),
            ).writeAsBytes([0xFF, 0xD8, 0xFF, 1]);
            late NavisDatabase database;
            final (handler, player) = await setup(
              onDatabase: (value) => database = value,
            );
            await database.libraryDao.upsertSongs([
              SongsTableCompanion.insert(
                id: 'song-1',
                title: 'Song 1',
                duration: const Value(300),
                coverArt: const Value('cut-cover'),
              ),
            ]);
            await handler.replaceQueue(
              [if (duplicate) 'song-1' else 'song-0', 'song-1', 'song-2'],
              startIndex: 1,
              expandMatchFlows: false,
            );
            await drain(handler);
            await handler.play();
            await until(
              () => handler.currentMediaItem?.extras?['artCacheFile'] != null,
            );
            expect(
              identical(handler.currentMediaItem, handler.queue.value[1]),
              isFalse,
            );
            final loads = player.sourceLoads;

            player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
            await until(() => player.sourceLoads > loads);
            await drain(handler);

            expect(player.index, 1);
            expect(handler.snapshot.currentSongId, 'song-1');
            expect(current(player).positionOffset, const Duration(seconds: 47));
          },
        );
      }

      test(
        'remove current with a discontinuity after lane release is not a cut',
        () async {
          final (handler, player) = await setup();
          player.simulatedPosition = const Duration(seconds: 47);
          final before = player.playbackEvent;
          final loads = player.sourceLoads;
          await handler.removeAt(1);
          await drain(handler);
          expect(handler.debugQueueLaneIdle, isTrue);

          player._discontinuities.add(
            PositionDiscontinuity(
              PositionDiscontinuityReason.autoAdvance,
              before,
              player.playbackEvent,
            ),
          );
          await drain(handler);

          expect(player.sourceLoads, loads);
          expect(handler.snapshot.currentSongId, 'song-2');
          expect(current(player).positionOffset, Duration.zero);
        },
      );

      for (final last in [false, true]) {
        for (final intent in ['none', 'Play', 'Pause']) {
          test(
            'native cut reopen failure preserves the queue after $intent (last: $last)',
            () async {
              late _GatedSourceResolver resolver;
              final (handler, player) = await setup(
                wrap: (base) => resolver = _GatedSourceResolver(base),
              );
              final failedIndex = last ? 2 : 1;
              final failedSong = 'song-$failedIndex';
              if (last) {
                await handler.playFromIndex(2);
                await drain(handler);
              }
              resolver
                ..blockedSongId = failedSong
                ..entered = Completer<void>()
                ..release = Completer<void>();
              addTearDown(() {
                if (!resolver.release!.isCompleted) {
                  resolver.release!.complete();
                }
              });
              player.loadErrorAfterApply = StateError('HTTP 500 after apply');
              player.finishCurrentTrack(
                endPosition: const Duration(seconds: 47),
              );
              await until(() => resolver.entered!.isCompleted);
              if (intent == 'Play') await handler.play();
              if (intent == 'Pause') await handler.pause();
              // Reject only the reopen; the next song remains available.
              resolver.blockedSongId = null;
              resolver.release!.complete();
              await drain(handler);

              expect(lastSeekEvent(handler)['outcome'], 'skipped');
              expect(handler.snapshot.queueSongIds, [
                'song-0',
                'song-1',
                'song-2',
              ]);
              expect(handler.snapshot.currentIndex, 2);
              expect(handler.snapshot.currentSongId, 'song-2');
              expect(player.playing, !last && intent != 'Pause');
              expectNativeMirrorsQueue(handler, player);
              if (last) {
                expect(player.position, const Duration(seconds: 47));
                final loads = player.sourceLoads;
                await handler.play();
                await until(() => player.sourceLoads > loads);
                await drain(handler);
                expect(handler.snapshot.currentSongId, failedSong);
                expect(player.audibleSongId, failedSong);
                expect(current(player).uri.queryParameters['id'], failedSong);
                expect(
                  current(player).positionOffset,
                  const Duration(seconds: 47),
                );
                expect(handler.snapshot.currentIndex, failedIndex);
                expectNativeMirrorsQueue(handler, player);
              }
            },
          );
        }
      }

      for (final last in [false, true]) {
        for (final pauseFirst in [false, true]) {
          test(
            'Play during cut resolution only records intent (last: $last, pause first: $pauseFirst)',
            () async {
              late _GatedSourceResolver resolver;
              final (handler, player) = await setup(
                last: last,
                wrap: (base) => resolver = _GatedSourceResolver(base),
              );
              resolver
                ..blockedSongId = 'song-1'
                ..entered = Completer<void>()
                ..release = Completer<void>();
              addTearDown(() {
                if (!resolver.release!.isCompleted) {
                  resolver.release!.complete();
                }
              });
              final loads = player.sourceLoads;
              player.finishCurrentTrack(
                endPosition: const Duration(seconds: 47),
              );
              await until(() => resolver.entered!.isCompleted);
              if (pauseFirst) {
                await handler.pause();
              }
              final plays = player.playedFrom.length;

              await handler.play();
              expect(player.playedFrom.length, plays);
              expect(player.audibleSongId, isNull);
              expect(player.index, last ? 1 : 2);
              expect(handler.snapshot.currentSongId, 'song-1');
              resolver
                ..blockedSongId = null
                ..release!.complete();
              await until(() => player.sourceLoads > loads);
              await drain(handler);
              await until(() => handler.snapshot.pendingSeekPosition == null);

              expect(player.index, 1);
              expect(handler.snapshot.currentSongId, 'song-1');
              expect(
                current(player).positionOffset,
                const Duration(seconds: 47),
              );
              expect(player.playing, isTrue);
            },
          );
        }
      }

      for (final last in [false, true]) {
        for (final play in [true, false]) {
          test(
            'failed cut resolution keeps failover after ${play ? 'Play' : 'Pause'} (last: $last)',
            () async {
              late _GatedSourceResolver resolver;
              final (handler, player) = await setup(
                last: last,
                wrap: (base) => resolver = _GatedSourceResolver(base),
              );
              resolver
                ..blockedSongId = 'song-1'
                ..entered = Completer<void>()
                ..release = Completer<void>()
                ..failure = StateError('source unavailable');
              addTearDown(() {
                if (!resolver.release!.isCompleted) {
                  resolver.release!.complete();
                }
              });
              player.finishCurrentTrack(
                endPosition: const Duration(seconds: 47),
              );
              await until(() => resolver.entered!.isCompleted);

              if (play) {
                await handler.play();
              } else {
                await handler.pause();
              }
              resolver.release!.complete();
              await drain(handler);

              expect(lastSeekEvent(handler)['outcome'], 'skipped');
              expect(
                handler.snapshot.currentSongId,
                last ? 'song-1' : 'song-2',
              );
              expect(player.playing, play && !last);
              if (last && play) {
                resolver.blockedSongId = null;
                await handler.play();
                await drain(handler);
                expect(player.playing, isTrue);
                expect(handler.snapshot.currentSongId, 'song-1');
              }
            },
          );

          test(
            'unbuilt cut recovery keeps failover after ${play ? 'Play' : 'Pause'} (last: $last)',
            () async {
              final (handler, player) = await setup(last: last);
              final entered = Completer<void>();
              final release = Completer<void>();
              player
                ..pauseGate = release
                ..pauseEntered = entered;
              addTearDown(() {
                if (!release.isCompleted) release.complete();
              });
              player.finishCurrentTrack(
                endPosition: const Duration(seconds: 47),
              );
              await until(() => entered.isCompleted);
              if (play) {
                await handler.play();
              } else {
                await handler.pause();
              }
              // Native lost the departed source before the rebuild could find it.
              player._sources.clear();
              release.complete();
              // Final-song failover stops quietly; only Play rebuilds lost sources.
              await pumpEventQueue(times: 100);
              if (!last) await settleQueue(handler);

              expect(lastSeekEvent(handler)['outcome'], 'skipped');
              expect(
                handler.snapshot.currentSongId,
                last ? 'song-1' : 'song-2',
              );
              expect(player.playing, play && !last);
              if (last && play) {
                await handler.play();
                await drain(handler);
                expect(player.playing, isTrue);
                expect(handler.snapshot.currentSongId, 'song-1');
              }
            },
          );
        }
      }

      test('audio-focus regain defers Play during cut resolution', () async {
        late _GatedSourceResolver resolver;
        final (handler, player) = await setup(
          wrap: (base) => resolver = _GatedSourceResolver(base),
        );
        final session = _TestAudioSession();
        handler.debugWireAudioSession(session);
        addTearDown(session.close);
        session.interruptions.add(
          AudioInterruptionEvent(true, AudioInterruptionType.pause),
        );
        await pumpEventQueue();
        resolver
          ..blockedSongId = 'song-1'
          ..entered = Completer<void>()
          ..release = Completer<void>();
        addTearDown(() {
          if (!resolver.release!.isCompleted) resolver.release!.complete();
        });
        final loads = player.sourceLoads;
        player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
        await until(() => resolver.entered!.isCompleted);
        final plays = player.playedFrom.length;

        session.interruptions.add(
          AudioInterruptionEvent(false, AudioInterruptionType.pause),
        );
        await pumpEventQueue();
        expect(player.playedFrom.length, plays);
        expect(player.audibleSongId, isNull);
        resolver
          ..blockedSongId = null
          ..release!.complete();
        await until(() => player.sourceLoads > loads);
        await drain(handler);
        await until(() => handler.snapshot.pendingSeekPosition == null);
        expect(player.audibleSongId, 'song-1');
      });

      test(
        'Play resumes a reopened source while settlement is pending',
        () async {
          final (handler, player) = await setup();
          final loads = player.sourceLoads;
          player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
          await until(() => player.sourceLoads > loads && player.playing);
          expect(handler.snapshot.pendingSeekPosition, isNotNull);
          await handler.pause();
          final plays = player.playedFrom.length;

          await handler.play();
          expect(player.playedFrom.length, plays + 1);
          expect(player.audibleSongId, 'song-1');
          await drain(handler);
          await until(() => handler.snapshot.pendingSeekPosition == null);
          expect(current(player).positionOffset, const Duration(seconds: 47));
        },
      );

      for (final edit in [
        'remove current',
        'remove earlier',
        'insert',
        'move',
      ]) {
        test('queue edit $edit is not a transcode cut', () async {
          final (handler, player) = await setup();
          final loads = player.sourceLoads;
          player
            ..simulatedPosition = const Duration(seconds: 47)
            ..emitQueueEditDiscontinuity = true;

          switch (edit) {
            case 'remove current':
              await handler.removeAt(1);
            case 'remove earlier':
              await handler.removeAt(0);
            case 'insert':
              await handler.insertQueueItem(
                0,
                const MediaItem(id: 'song-0', title: 'Song 0'),
              );
            case 'move':
              await handler.reorderQueue(0, 3);
          }
          await drain(handler);

          expect(player.sourceLoads, loads);
          expect(
            handler.snapshot.currentSongId,
            edit == 'remove current' ? 'song-2' : 'song-1',
          );
          expect(current(player).positionOffset, Duration.zero);
          expect(player.position.inSeconds, edit == 'remove current' ? 0 : 47);
        });
      }

      for (final discontinuityFirst in [false, true]) {
        for (final last in [false, true]) {
          test(
            'cut preserves scrobbles and history (last: $last, discontinuity first: $discontinuityFirst)',
            () async {
              final scrobbles = _NoopScrobbleService();
              late NavisDatabase database;
              final (handler, player) = await setup(
                last: last,
                scrobbleService: scrobbles,
                onDatabase: (value) => database = value,
              );
              await drain(handler);
              expect(scrobbles.nowPlaying, ['song-1']);
              final session = scrobbles.nowPlayingSessions.single;
              final completed = <PlaybackSnapshot>[];
              final subscription = handler.snapshotStream.listen((snapshot) {
                if (snapshot.processingState ==
                    AudioProcessingState.completed) {
                  completed.add(snapshot);
                }
              });
              addTearDown(subscription.cancel);
              final loads = player.sourceLoads;

              player.finishCurrentTrack(
                endPosition: const Duration(seconds: 47),
                discontinuityFirst: discontinuityFirst,
              );
              await until(() => player.sourceLoads > loads);
              await drain(handler);
              await until(() => handler.snapshot.pendingSeekPosition == null);

              expect(handler.snapshot.currentSongId, 'song-1');
              expect(
                current(player).positionOffset,
                const Duration(seconds: 47),
              );
              expect(scrobbles.nowPlaying, ['song-1']);
              expect(scrobbles.nowPlayingSessions, [session]);
              expect(scrobbles.submissions, isEmpty);
              expect(completed, isEmpty);
              final history = await database.historyDao
                  .watchPlayHistory()
                  .first;
              expect(history.map((entry) => entry.songId), ['song-1']);

              player.simulatedPosition = const Duration(seconds: 180);
              player.emitPlayerEvent();
              await drain(handler);
              expect(scrobbles.submissions, ['song-1']);
              expect(scrobbles.submissionSessions, [session]);
            },
          );
        }
      }

      test('cut pauses the successor before source resolution', () async {
        late _GatedSourceResolver resolver;
        final (handler, player) = await setup(
          wrap: (base) => resolver = _GatedSourceResolver(base),
        );
        resolver
          ..blockedSongId = 'song-1'
          ..entered = Completer<void>()
          ..release = Completer<void>();
        addTearDown(() {
          if (!resolver.release!.isCompleted) resolver.release!.complete();
        });
        final loads = player.sourceLoads;
        player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
        await until(() => resolver.entered!.isCompleted);
        expect(player.audibleSongId, isNull);
        expect(handler.snapshot.currentSongId, 'song-1');
        resolver
          ..blockedSongId = null
          ..release!.complete();
        await until(() => player.sourceLoads > loads);
        await drain(handler);
        expect(player.playing, isTrue);
      });

      test(
        'a newer Pause preserves recovery during native acknowledgement',
        () async {
          final (handler, player) = await setup();
          final release = Completer<void>();
          final entered = Completer<void>();
          player
            ..pauseGate = release
            ..pauseEntered = entered;
          addTearDown(() {
            if (!release.isCompleted) release.complete();
          });
          final loads = player.sourceLoads;

          player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
          await until(() => entered.isCompleted);
          await handler.pause();
          release.complete();
          await until(() => player.sourceLoads > loads);
          await drain(handler);
          await until(() => handler.snapshot.pendingSeekPosition == null);

          expect(handler.snapshot.currentSongId, 'song-1');
          expect(current(player).positionOffset, const Duration(seconds: 47));
          expect(player.playing, isFalse);
        },
      );

      for (final last in [false, true]) {
        test('reopens at 47 of 300 seconds (last: $last)', () async {
          final (handler, player) = await setup(last: last);
          final loads = player.sourceLoads;
          final failures = <PlaybackLoadFailure>[];
          final notices = handler.loadFailureStream.listen(failures.add);
          addTearDown(notices.cancel);

          player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
          await until(() => player.sourceLoads > loads);
          await drain(handler);

          expect(handler.snapshot.currentSongId, 'song-1');
          expect(player.index, 1);
          expect(current(player).uri.queryParameters['timeOffset'], '47');
          expect(current(player).positionOffset, const Duration(seconds: 47));
          expect(player.sourceLoads, loads + 1);
          expect(player.playing, isTrue);
          expect(handler.playbackState.value.playing, isTrue);
          expect(failures, isEmpty);
        });

        test('a second early end does not loop (last: $last)', () async {
          final (handler, player) = await setup(last: last);
          final loads = player.sourceLoads;
          player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
          await until(() => player.sourceLoads > loads);
          await drain(handler);
          final retriedLoads = player.sourceLoads;

          player.finishCurrentTrack(endPosition: const Duration(seconds: 50));
          await drain(handler);

          expect(player.sourceLoads, retriedLoads);
          expect(handler.snapshot.currentSongId, last ? 'song-1' : 'song-2');
          expect(
            player.processingState,
            last ? ProcessingState.completed : ProcessingState.ready,
          );
        });
      }

      for (final gate in [
        'near end',
        'unknown duration',
        'unsupported',
        'original',
        'completed file',
      ]) {
        test('$gate keeps normal advance', () async {
          final (handler, player) = await setup(
            capable: gate != 'unsupported',
            original: gate == 'original',
            duration: gate == 'unknown duration' ? null : 300,
          );
          if (gate == 'completed file') {
            final path =
                handler.currentMediaItem!.extras!['sidecarCacheFilePath']!
                    as String;
            await File(path).writeAsBytes([1, 2, 3]);
          }
          final loads = player.sourceLoads;
          player.finishCurrentTrack(
            endPosition: Duration(seconds: gate == 'near end' ? 290 : 47),
          );
          await drain(handler);

          expect(player.sourceLoads, loads);
          expect(handler.snapshot.currentSongId, 'song-2');
        });
      }

      test(
        'completion uses the backend position instead of its clock',
        () async {
          final (handler, player) = await setup(last: true);
          final loads = player.sourceLoads;
          player
            ..nativePositionFrozen = true
            ..simulatedPosition = const Duration(seconds: 47)
            .._positionUpdated = DateTime.now().subtract(
              const Duration(seconds: 240),
            )
            ..state = ProcessingState.completed;
          expect(player.position, greaterThan(const Duration(seconds: 280)));
          player._events.add(player.playbackEvent);
          await until(() => player.sourceLoads > loads);
          await drain(handler);

          expect(current(player).positionOffset, const Duration(seconds: 47));
        },
      );

      test(
        'an offset continuation also recovers at its last song position',
        () async {
          final (handler, player) = await setup();
          await seekAndSettle(handler, const Duration(seconds: 30));
          final loads = player.sourceLoads;

          player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
          await until(() => player.sourceLoads > loads);
          await drain(handler);

          expect(current(player).positionOffset, const Duration(seconds: 47));
          expect(handler.snapshot.currentSongId, 'song-1');
        },
      );

      test('healthy play does not excuse a truncated transcode', () async {
        final (handler, player, database) = await offsetHandler(
          positionStreams: true,
          timeouts: const NavisPlaybackTimeouts(
            healthyPlayback: Duration(milliseconds: 600),
          ),
        );
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Song 1',
            duration: const Value(300),
          ),
        ]);
        await start(handler);
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        final loads = player.sourceLoads;
        player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
        await until(() => player.sourceLoads > loads);
        await drain(handler);

        expect(current(player).positionOffset, const Duration(seconds: 47));
      });

      test('a user skip does not reopen the departed song', () async {
        final (handler, player) = await setup();
        player.simulatedPosition = const Duration(seconds: 47);
        final loads = player.sourceLoads;

        await handler.skipToNext();
        await drain(handler);

        expect(handler.snapshot.currentSongId, 'song-2');
        expect(player.sourceLoads, loads);
      });

      // P7: the departed song's end during a user navigation is superseded by
      // it, even though the navigate lane is busy and the load flag is set.
      for (final command in ['next', 'previous', 'select']) {
        {
          test('a $command skip held in the lane ignores the departed '
              "song's end", () async {
            final (handler, player) = await setup();
            player.simulatedPosition = const Duration(seconds: 2);
            final loads = player.sourceLoads;
            final target = command == 'next' ? 'song-2' : 'song-0';
            player
              ..seekGate = Completer<void>()
              ..seekEntered = Completer<void>();
            final gate = player.seekGate!;
            addTearDown(() {
              if (!gate.isCompleted) gate.complete();
            });
            final navigation = switch (command) {
              'next' => handler.skipToNext(),
              'previous' => handler.skipToPrevious(),
              _ => handler.playFromIndex(0),
            };
            await player.seekEntered!.future.timeout(
              const Duration(seconds: 3),
            );

            // Any event the departed player emits after the skip began
            // re-captures its occurrence; its end then looks like a cut.
            player._events.add(player.playbackEvent);
            await pumpEventQueue(times: 20);
            player.finishCurrentTrack(endPosition: const Duration(seconds: 2));
            await pumpEventQueue(times: 50);
            gate.complete();
            await navigation;
            await drain(handler);

            expect(
              player.sourceLoads,
              loads,
              reason: 'the departed song must not be reloaded',
            );
            expect(handler.snapshot.currentSongId, target);
            expect(current(player).positionOffset, Duration.zero);
          });
        }
      }

      test('a real cut on the skip target right after the skip still '
          'retries', () async {
        final (handler, player) = await setup();
        await handler.skipToNext();
        await drain(handler);
        expect(handler.snapshot.currentSongId, 'song-2');
        final loads = player.sourceLoads;

        player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
        await until(() => player.sourceLoads > loads);
        await drain(handler);

        expect(handler.snapshot.currentSongId, 'song-2');
        expect(current(player).positionOffset, const Duration(seconds: 47));
      });

      test('a skip cancelled before it ran does not disable cut recovery '
          'during later queue work', () async {
        final (handler, player) = await setup();
        final append = Completer<void>();
        final appendEntered = Completer<void>();
        player
          ..appendGate = append
          ..appendEntered = appendEntered;
        addTearDown(() {
          if (!append.isCompleted) append.complete();
        });
        // The replacement below retires this edit.
        final editing = handler
            .addToQueue(['song-0'], expandMatchFlows: false)
            .then<void>((_) {}, onError: (Object _) {});
        await appendEntered.future.timeout(const Duration(seconds: 3));
        // Queued behind the held edit, then cancelled before its callback ran.
        await handler.skipToNext();
        final replacing = handler.replaceQueue(
          ['song-0', 'song-1', 'song-2'],
          startIndex: 1,
          expandMatchFlows: false,
        );
        append.complete();
        await Future.wait([editing, replacing]);
        await drain(handler);
        await handler.play();
        player.simulatedDuration = const Duration(seconds: 47);

        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..afterAppendGate = gate
          ..afterAppendEntered = entered;
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final loading = handler.replaceQueue(
          ['song-0', 'song-1', 'song-2'],
          startIndex: 1,
          expandMatchFlows: false,
        );
        await entered.future.timeout(const Duration(seconds: 3));
        final more = handler.addToQueue(['song-0'], expandMatchFlows: false);
        await pumpEventQueue(times: 20);
        player.finishCurrentTrack(
          endPosition: const Duration(milliseconds: 47750),
        );
        await pumpEventQueue(times: 20);
        gate.complete();
        await Future.wait([loading, more]);
        await drain(handler);

        expect(handler.snapshot.currentSongId, 'song-1');
        expect(current(player).positionOffset, const Duration(seconds: 47));
      });

      test(
        'a lagging departed end during later queue work is ignored',
        () async {
          final (handler, player) = await setup();
          player.simulatedPosition = const Duration(seconds: 2);
          player
            ..seekGate = Completer<void>()
            ..seekEntered = Completer<void>();
          final seek = player.seekGate!;
          addTearDown(() {
            if (!seek.isCompleted) seek.complete();
          });
          final navigation = handler.skipToNext();
          await player.seekEntered!.future.timeout(const Duration(seconds: 3));
          player._events.add(player.playbackEvent);
          await pumpEventQueue(times: 20);
          final stale = player.playbackEvent;
          seek.complete();
          await navigation;
          await drain(handler);
          final loads = player.sourceLoads;

          final append = Completer<void>();
          final appendEntered = Completer<void>();
          player
            ..appendGate = append
            ..appendEntered = appendEntered;
          addTearDown(() {
            if (!append.isCompleted) append.complete();
          });
          final editing = handler.addToQueue([
            'song-0',
          ], expandMatchFlows: false);
          await appendEntered.future.timeout(const Duration(seconds: 3));
          player._discontinuities.add(
            PositionDiscontinuity(
              PositionDiscontinuityReason.autoAdvance,
              stale,
              player.playbackEvent,
            ),
          );
          await pumpEventQueue(times: 50);
          append.complete();
          await editing;
          await drain(handler);

          expect(player.sourceLoads, loads);
          expect(handler.snapshot.currentSongId, 'song-2');
        },
      );

      test('a stale departed end after the skip finished is ignored', () async {
        final (handler, player) = await setup();
        player.simulatedPosition = const Duration(seconds: 2);
        final stale = player.playbackEvent;
        await handler.skipToNext();
        await drain(handler);
        final loads = player.sourceLoads;

        player._discontinuities.add(
          PositionDiscontinuity(
            PositionDiscontinuityReason.autoAdvance,
            stale,
            player.playbackEvent,
          ),
        );
        await drain(handler);

        expect(player.sourceLoads, loads);
        expect(handler.snapshot.currentSongId, 'song-2');
      });

      test(
        'Repeat One resumes the cut rather than restarting at zero',
        () async {
          final (handler, player) = await setup();
          await handler.setRepeatMode(AudioServiceRepeatMode.one);
          final loads = player.sourceLoads;

          player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
          await until(() => player.sourceLoads > loads);
          await drain(handler);

          expect(handler.snapshot.currentSongId, 'song-1');
          expect(current(player).positionOffset, const Duration(seconds: 47));
          expect(player.loopMode, LoopMode.one);
          expect(player.playing, isTrue);
        },
      );

      test('recovers the departed duplicate occurrence', () async {
        final (handler, player) = await setup();
        await handler.replaceQueue(
          ['song-1', 'song-1', 'song-2'],
          startIndex: 1,
          expandMatchFlows: false,
        );
        await settleQueue(handler);
        await handler.play();
        final loads = player.sourceLoads;

        player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
        await until(() => player.sourceLoads > loads);
        await drain(handler);

        expect(player.index, 1);
        expect(handler.snapshot.queueSongIds, ['song-1', 'song-1', 'song-2']);
        expect(current(player).positionOffset, const Duration(seconds: 47));
      });

      for (final command in ['pause', 'seek', 'skip']) {
        test('a newer $command wins during reopen resolution', () async {
          late _GatedSourceResolver resolver;
          final (handler, player) = await setup(
            wrap: (base) => resolver = _GatedSourceResolver(base),
          );
          resolver
            ..blockedSongId = 'song-1'
            ..entered = Completer<void>()
            ..release = Completer<void>();
          addTearDown(() {
            if (!resolver.release!.isCompleted) resolver.release!.complete();
          });
          player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
          await until(() => resolver.entered!.isCompleted);
          final newer = switch (command) {
            'pause' => handler.pause(),
            'seek' => handler.seek(const Duration(seconds: 130)),
            _ => handler.skipToNext(),
          };
          if (command == 'pause') await newer;
          resolver
            ..blockedSongId = null
            ..release!.complete();
          await newer;
          await drain(handler);

          expect(
            handler.snapshot.currentSongId,
            command == 'skip' ? 'song-2' : 'song-1',
          );
          if (command != 'skip') {
            expect(
              current(player).positionOffset,
              Duration(seconds: command == 'seek' ? 130 : 47),
            );
          }
          expect(player.playing, command != 'pause');
        });
      }

      test('row 16 newer seek owns a failed cut reopen', () async {
        late _GatedSourceResolver resolver;
        final (handler, player) = await setup(
          wrap: (base) => resolver = _GatedSourceResolver(base),
        );
        resolver
          ..blockedSongId = 'song-1'
          ..entered = Completer<void>()
          ..release = Completer<void>()
          ..failure = StateError('reopen unavailable');
        addTearDown(() {
          if (!resolver.release!.isCompleted) resolver.release!.complete();
        });
        player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
        await resolver.entered!.future.timeout(const Duration(seconds: 3));
        final newer = handler.seek(const Duration(seconds: 130));
        resolver
          ..blockedSongId = null
          ..release!.complete();
        await newer;
        await drain(handler);
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(current(player).positionOffset, const Duration(seconds: 130));
        expect(player.playing, isTrue);
        expectNativeMirrorsQueue(handler, player);
      });

      for (final edit in ['append', 'insert']) {
        test(
          'row 18 $edit during completed cut resolution keeps the queue and Play intent',
          () async {
            late _GatedSourceResolver resolver;
            final (handler, player) = await setup(
              last: true,
              wrap: (base) => resolver = _GatedSourceResolver(base),
            );
            resolver
              ..blockedSongId = 'song-1'
              ..entered = Completer<void>()
              ..release = Completer<void>();
            addTearDown(() {
              if (!resolver.release!.isCompleted) resolver.release!.complete();
            });
            player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
            await resolver.entered!.future.timeout(const Duration(seconds: 3));
            final editing = edit == 'append'
                ? handler.addToQueue(['song-2'], expandMatchFlows: false)
                : handler.playNext(['song-2'], expandMatchFlows: false);
            await handler.pause();
            final plays = player.playedFrom.length;
            await handler.play();
            expect(
              player.playedFrom.length,
              plays,
              reason: 'source is not ready',
            );
            expect(player.audibleSongId, isNull);
            resolver
              ..blockedSongId = null
              ..release!.complete();
            await editing;
            await drain(handler);
            expect(handler.snapshot.currentSongId, 'song-1');
            expect(handler.snapshot.currentIndex, 1);
            expect(handler.snapshot.queueSongIds, [
              'song-0',
              'song-1',
              'song-2',
            ]);
            expect(current(player).positionOffset, const Duration(seconds: 47));
            expect(player.playing, isTrue);
            expectNativeMirrorsQueue(handler, player);
          },
        );
      }

      test('a failed reopen uses bounded silent failover', () async {
        late _GatedSourceResolver resolver;
        final (handler, player) = await setup(
          wrap: (base) => resolver = _GatedSourceResolver(base),
        );
        resolver
          ..blockedSongId = 'song-1'
          ..entered = Completer<void>()
          ..failure = StateError('source unavailable');
        final loads = player.sourceLoads;

        player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
        await until(() => resolver.entered!.isCompleted);
        await drain(handler);

        expect(handler.snapshot.currentSongId, 'song-2');
        expect(player.playing, isTrue);
        expect(player.sourceLoads, lessThanOrEqualTo(loads + 1));
      });
    });

    for (final playing in [true, false]) {
      test('stall recovery resumes a transcode at song time 70 (playing: '
          '$playing)', () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        if (!playing) await handler.pause();
        final loads = player.sourceLoads;
        final failures = <PlaybackLoadFailure>[];
        final notices = handler.loadFailureStream.listen(failures.add);
        addTearDown(notices.cancel);

        await failAt(handler, player, const Duration(seconds: 70));

        expect(current(player).uri.queryParameters['timeOffset'], '70');
        expect(current(player).positionOffset, const Duration(seconds: 70));
        expect(player.position.inSeconds, 70);
        expect(player.sourceLoads, loads + 1);
        expect(player.sourceIds, ['song-0', 'song-1', 'song-2']);
        expect(player.playing, playing);
        expect(lastSeekEvent(handler)['path'], 'remote_retry');
        expect(failures, isEmpty);
      });
    }

    test('stall recovery on an offset stream uses song time 130', () async {
      final (handler, player, _) = await offsetHandler();
      await start(handler);
      await seekAndSettle(handler, const Duration(seconds: 110));
      final loads = player.sourceLoads;

      await failAt(handler, player, const Duration(seconds: 130));

      expect(current(player).uri.queryParameters['timeOffset'], '130');
      expect(player.position.inSeconds, 130);
      expect(player.sourceLoads, loads + 1);
      expect(player.playing, isTrue);
    });

    test('stall recovery prefers a completed file at song time 70', () async {
      final (handler, player, _) = await offsetHandler();
      await start(handler);
      final sidecar =
          handler.queue.value[1].extras!['sidecarCacheFilePath'] as String;
      await File(sidecar).writeAsBytes(List<int>.filled(64, 1));
      final loads = player.sourceLoads;

      await failAt(handler, player, const Duration(seconds: 70));

      expect(current(player).uri, Uri.file(sidecar));
      expect(current(player).positionOffset, Duration.zero);
      expect(player.position.inSeconds, 70);
      expect(player.sourceLoads, loads + 1);
      expect(player.playing, isTrue);
    });

    test('row 01 newer seek waits for ordinary recovery final Stop', () async {
      final (handler, player, database) = await offsetHandler(
        capable: false,
        timeouts: const NavisPlaybackTimeouts(
          load: Duration(milliseconds: 300),
          reset: Duration(milliseconds: 300),
          seekProgress: Duration(milliseconds: 1200),
          desktopSeekSettle: Duration(milliseconds: 600),
        ),
      );
      await handler.replaceQueue(
        ['song-0', 'song-1'],
        startIndex: 1,
        expandMatchFlows: false,
      );
      await settleQueue(handler);
      await (database.delete(
        database.songsTable,
      )..where((row) => row.id.equals('song-0'))).go();
      final release = Completer<void>();
      final entered = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      player
        ..stopGate = release
        ..stopEntered = entered
        ..stopGateFrom = player.stopCalls + 1
        ..simulatedPosition = const Duration(seconds: 70)
        ..state = ProcessingState.idle;
      final recovery = handler.debugRecoverCurrentSong();
      await entered.future.timeout(const Duration(seconds: 3));
      await database.libraryDao.upsertSongs([
        SongsTableCompanion.insert(id: 'song-0', title: 'Song 0'),
      ]);
      final seeking = handler.seek(const Duration(seconds: 130));
      await pumpEventQueue(times: 30);
      release.complete();
      await Future.wait([recovery, seeking]);
      await settleQueue(handler);
      expect(
        (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
        'completed',
      );
      expect(handler.snapshot.currentSongId, 'song-1');
      expect(player.position.inSeconds, greaterThanOrEqualTo(130));
      expect(player.playing, isTrue);
      expectNativeMirrorsQueue(handler, player);
    });

    test(
      'row 05 unbuilt original recovery honors Pause during failover',
      () async {
        final (handler, player, database) = await offsetHandler(
          capable: false,
          count: 4,
        );
        await start(handler);
        final release = Completer<void>();
        final entered = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        player
          ..appendGate = release
          ..appendEntered = entered;
        final editing = handler.addToQueue(['song-3'], expandMatchFlows: false);
        await entered.future;
        player
          ..simulatedPosition = const Duration(seconds: 70)
          ..state = ProcessingState.idle;
        final recovery = handler.debugRecoverCurrentSong();
        await pumpEventQueue(times: 30);
        await (database.delete(
          database.songsTable,
        )..where((row) => row.id.equals('song-0'))).go();
        await handler.pause();
        release.complete();
        await Future.wait([editing, recovery]);
        await settleQueue(handler);
        expect(handler.snapshot.currentSongId, 'song-2');
        expect(player.playing, isFalse);
        expectNativeMirrorsQueue(handler, player);
      },
    );

    for (final superseded in [false, true]) {
      test(
        'row 05 unbuilt original recovery ${superseded ? 'yields to selection' : 'fails over once'}',
        () async {
          final (handler, player, database) = await offsetHandler(
            capable: false,
            count: 4,
          );
          await start(handler);
          final release = Completer<void>();
          final entered = Completer<void>();
          player
            ..appendGate = release
            ..appendEntered = entered;
          final editing = handler.addToQueue([
            'song-3',
          ], expandMatchFlows: false);
          await entered.future;
          player
            ..simulatedPosition = const Duration(seconds: 70)
            ..state = ProcessingState.idle;
          final recovery = handler.debugRecoverCurrentSong();
          await pumpEventQueue(times: 30);
          if (!superseded) {
            await (database.delete(
              database.songsTable,
            )..where((row) => row.id.equals('song-0'))).go();
          }
          final selection = superseded
              ? handler.playFromIndex(2)
              : Future<void>.value();
          release.complete();
          await Future.wait([editing, recovery, selection]);
          await settleQueue(handler);
          expect(
            handler.snapshot.currentSongId,
            'song-2',
            reason: 'row 05: only the owned failure may fail over',
          );
          expect(player.playing, isTrue);
          expectNativeMirrorsQueue(handler, player);
        },
      );
    }

    test(
      'row 05 removal before an original rebuild does not fail over again',
      () async {
        final (handler, player, _) = await offsetHandler(
          capable: false,
          count: 4,
        );
        await start(handler);
        final release = Completer<void>();
        final entered = Completer<void>();
        player
          ..appendGate = release
          ..appendEntered = entered;
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        final editing = handler.addToQueue(['song-3'], expandMatchFlows: false);
        await entered.future;
        final removing = handler.removeAt(1);
        player.state = ProcessingState.idle;
        final recovery = handler.debugRecoverCurrentSong();
        await pumpEventQueue(times: 30);
        release.complete();
        await Future.wait([editing, removing, recovery]);
        await settleQueue(handler);
        expect(handler.snapshot.queueSongIds, ['song-0', 'song-2', 'song-3']);
        expect(handler.snapshot.currentSongId, 'song-2');
        expect(player.playing, isTrue);
        expectNativeMirrorsQueue(handler, player);
      },
    );

    test(
      'row 02 failed seek suppression uses the configured healthy interval',
      () async {
        final (handler, player, _) = await offsetHandler(
          capable: false,
          desktopRuntimeOverride: false,
          timeouts: const NavisPlaybackTimeouts(
            seekProgress: Duration(milliseconds: 400),
            seekBufferingRecovery: Duration(milliseconds: 150),
            healthyPlayback: Duration(milliseconds: 600),
          ),
        );
        await start(handler);
        player
          ..ignoreSeeks = true
          ..nativePositionFrozen = true
          ..simulateProgress = false;
        await handler.seek(const Duration(seconds: 90));
        expect(
          (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
          'failed',
        );
        final failedAt = player.position;
        final loads = player.sourceLoads;
        player
          ..state = ProcessingState.ready
          ..simulatedPosition = failedAt + const Duration(milliseconds: 500);
        player._events.add(player.playbackEvent);
        await pumpEventQueue(times: 20);
        player.state = ProcessingState.idle;
        await handler.debugRecoverCurrentSong();
        expect(
          player.sourceLoads,
          loads,
          reason: 'no renewal below healthyPlayback',
        );
        player
          ..state = ProcessingState.ready
          ..simulatedPosition = failedAt + const Duration(milliseconds: 700);
        player._events.add(player.playbackEvent);
        await pumpEventQueue(times: 20);
        player
          ..state = ProcessingState.idle
          ..ignoreSeeks = false
          ..nativePositionFrozen = false
          ..simulateProgress = true;
        await handler.debugRecoverCurrentSong();
        await settleQueue(handler);
        expect(
          player.sourceLoads,
          loads + 1,
          reason: 'row 02: renew at healthyPlayback, before five seconds',
        );
      },
    );

    test(
      'stall recovery without the capability keeps the original path',
      () async {
        final (handler, player, _) = await offsetHandler(capable: false);
        await start(handler);
        final loads = player.sourceLoads;

        await failAt(handler, player, const Duration(seconds: 70));

        expect(
          current(player).uri.queryParameters,
          isNot(contains('timeOffset')),
        );
        expect(current(player).positionOffset, Duration.zero);
        expect(player.position.inSeconds, 70);
        expect(player.sourceLoads, loads + 1);
        expect(player.playing, isTrue);
      },
    );

    test(
      'stall recovery in the first second keeps the original path',
      () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        final loads = player.sourceLoads;

        await failAt(handler, player, const Duration(milliseconds: 400));

        expect(
          current(player).uri.queryParameters,
          isNot(contains('timeOffset')),
        );
        expect(current(player).positionOffset, Duration.zero);
        expect(player.position.inMilliseconds, greaterThanOrEqualTo(400));
        expect(player.sourceLoads, loads + 1);
        expect(player.playing, isTrue);
      },
    );

    test(
      'stall recovery keeps Play while a queue edit holds the reload',
      () async {
        final (handler, player, _) = await offsetHandler(count: 4);
        await start(handler);
        await handler.pause();
        final loads = player.sourceLoads;
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..appendGate = gate
          ..appendEntered = entered;
        final adding = handler.addToQueue(['song-3'], expandMatchFlows: false);
        await entered.future;
        player
          ..simulatedPosition = const Duration(seconds: 70)
          ..state = ProcessingState.idle;
        player._events.addError(PlayerException(2002, 'Read timed out', 1));
        await pumpEventQueue(times: 20);

        await handler.play();
        gate.complete();
        await adding;
        await until(
          () => !handler.snapshot.isLoading && player.sourceIds.length == 4,
        );
        await until(() => player.playing);

        expect(current(player).positionOffset, const Duration(seconds: 70));
        expect(player.position.inSeconds, 70);
        expect(player.sourceLoads, loads + 1);
        expect(player.sourceIds, ['song-0', 'song-1', 'song-2', 'song-3']);
      },
    );

    test('stall recovery at the song end advances without replaying', () async {
      final (handler, player, _) = await offsetHandler();
      await start(handler);

      await failAt(handler, player, const Duration(minutes: 3));

      expect(handler.snapshot.currentSongId, 'song-2');
      expect(player.playing, isTrue);
      expect(lastSeekEvent(handler)['outcome'], 'skipped');
    });

    for (final command in ['pause', 'seek']) {
      test(
        'stall recovery yields to a newer $command during resolution',
        () async {
          late _GatedSourceResolver resolver;
          final (handler, player, _) = await offsetHandler(
            wrapResolver: (base) => resolver = _GatedSourceResolver(base),
          );
          await start(handler);
          final loads = player.sourceLoads;
          resolver
            ..blockedSongId = 'song-1'
            ..entered = Completer<void>()
            ..release = Completer<void>();
          player
            ..simulatedPosition = const Duration(seconds: 70)
            ..state = ProcessingState.buffering;
          final recovery = handler.debugRecoverCurrentSong();
          await resolver.entered!.future;
          final newer = command == 'pause'
              ? handler.pause()
              : handler.seek(const Duration(seconds: 130));
          if (command == 'pause') await newer;
          resolver
            ..blockedSongId = null
            ..release!.complete();
          await Future.wait([recovery, newer]);
          await until(() => !handler.snapshot.isLoading);

          final expected = command == 'pause' ? 70 : 130;
          expect(current(player).positionOffset, Duration(seconds: expected));
          expect(player.position.inSeconds, expected);
          expect(player.sourceLoads, loads + 1);
          expect(player.sourceIds, ['song-0', 'song-1', 'song-2']);
          expect(player.playing, command != 'pause');
        },
      );
    }

    test(
      'stall recovery retries once then advances after another failure',
      () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        await failAt(handler, player, const Duration(seconds: 70));

        await failAt(handler, player, const Duration(seconds: 80));

        expect(handler.snapshot.currentSongId, 'song-2');
        expect(player.playing, isTrue);
        expect(lastSeekEvent(handler)['outcome'], 'skipped');
      },
    );

    group('the retry bound renews with sustained play', () {
      const quick = NavisPlaybackTimeouts(
        healthyPlayback: Duration(milliseconds: 600),
      );

      Future<(NavisAudioHandler, _ControllableAudioPlayer)> retried({
        bool frozen = false,
      }) async {
        final (handler, player, _) = await offsetHandler(
          positionStreams: true,
          timeouts: quick,
        );
        await start(handler);
        await failAt(handler, player, const Duration(seconds: 70));
        expect(lastSeekEvent(handler)['outcome'], 'reloaded');
        player.nativePositionFrozen = frozen;
        return (handler, player);
      }

      test('a cut after healthy play is retried again', () async {
        final (handler, player) = await retried();
        await Future<void>.delayed(const Duration(milliseconds: 1200));

        await failAt(handler, player, const Duration(seconds: 80));

        expect(handler.snapshot.currentSongId, 'song-1');
        expect(lastSeekEvent(handler)['outcome'], 'reloaded');
      });

      test('a second cut before healthy play skips the song', () async {
        final (handler, player) = await retried();

        await failAt(handler, player, const Duration(seconds: 80));

        expect(handler.snapshot.currentSongId, 'song-2');
        expect(lastSeekEvent(handler)['outcome'], 'skipped');
      });

      test('renewal is per song: the next song keeps its own bound', () async {
        final (handler, player) = await retried();
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        // A natural advance keeps the transport generation and its bounds.
        player.finishCurrentTrack();
        await until(() => handler.snapshot.currentSongId == 'song-2');

        await failAt(handler, player, const Duration(seconds: 30));
        expect(lastSeekEvent(handler)['outcome'], 'reloaded');
        await failAt(handler, player, const Duration(seconds: 40));

        expect(lastSeekEvent(handler)['outcome'], 'skipped');
      });

      Future<(NavisAudioHandler, _ControllableAudioPlayer)>
      repeatingOne() async {
        final (handler, player, _) = await offsetHandler(
          positionStreams: true,
          timeouts: quick,
        );
        await start(handler);
        await handler.setRepeatMode(AudioServiceRepeatMode.one);
        return (handler, player);
      }

      test('a Repeat One loop starts a new play-time occurrence', () async {
        final (handler, player) = await repeatingOne();
        await Future<void>.delayed(const Duration(milliseconds: 900));
        expect(
          handler.debugPlayedSinceFailover,
          greaterThan(quick.healthyPlayback),
        );

        player.finishCurrentTrack();
        await pumpEventQueue();

        expect(
          handler.debugPlayedSinceFailover,
          lessThan(quick.healthyPlayback),
        );
      });

      test(
        'play time before a Repeat One loop does not renew the retry',
        () async {
          final (handler, player) = await repeatingOne();
          await failAt(handler, player, const Duration(milliseconds: 500));
          expect(lastSeekEvent(handler)['outcome'], 'reloaded');
          // Neither half of the play reaches healthyPlayback on its own.
          await Future<void>.delayed(const Duration(milliseconds: 400));
          player.finishCurrentTrack();
          await Future<void>.delayed(const Duration(milliseconds: 400));

          await failAt(handler, player, const Duration(milliseconds: 900));

          expect(lastSeekEvent(handler)['outcome'], 'skipped');
        },
      );

      test('Repeat One retries again after healthy play', () async {
        final (handler, player, _) = await offsetHandler(
          positionStreams: true,
          timeouts: quick,
        );
        await start(handler);
        await handler.setRepeatMode(AudioServiceRepeatMode.one);
        await failAt(handler, player, const Duration(seconds: 70));
        expect(lastSeekEvent(handler)['outcome'], 'reloaded');
        await Future<void>.delayed(const Duration(milliseconds: 1200));

        await failAt(handler, player, const Duration(seconds: 80));

        expect(handler.snapshot.currentSongId, 'song-1');
        expect(lastSeekEvent(handler)['outcome'], 'reloaded');
      });

      test('a frozen native position never renews the bound', () async {
        final (handler, player) = await retried(frozen: true);
        await Future<void>.delayed(const Duration(milliseconds: 1200));

        await failAt(handler, player, const Duration(seconds: 80));

        expect(handler.snapshot.currentSongId, 'song-2');
        expect(lastSeekEvent(handler)['outcome'], 'skipped');
      });
    });

    test(
      'a far seek reopens the transcode at the whole-second offset',
      () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        final loadsBefore = player.sourceLoads;

        await seekAndSettle(
          handler,
          const Duration(seconds: 95, milliseconds: 700),
        );

        final source = current(player);
        expect(source.uri.queryParameters['timeOffset'], '95');
        expect(
          source.uri.queryParameters,
          isNot(contains('estimateContentLength')),
        );
        expect(source.positionOffset, const Duration(seconds: 95));
        expect(player.sourceLoads, loadsBefore + 1);
        expect(
          (player.position - const Duration(seconds: 95)).abs(),
          lessThan(const Duration(seconds: 1)),
        );
        expect(player.sourceIds, ['song-0', 'song-1', 'song-2']);
        expect(player.index, 1);
        final seek = lastSeekEvent(handler);
        expect(seek['path'], 'transcodeOffset');
        expect(seek['outcome'], 'completed');
        final diagnostics = handler.collectPlaybackDiagnostics();
        expect(diagnostics['positionOffsetMs'], 95000);
        expect(handler.queue.value[1].extras!['positionOffsetMs'], 95000);
      },
    );

    test(
      'going back to a song that played as an offset starts it at 0',
      () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        await seekAndSettle(handler, const Duration(seconds: 90));
        await handler.skipToNext();
        await until(() => handler.snapshot.currentSongId == 'song-2');
        player.simulatedPosition = const Duration(seconds: 1);
        await handler.skipToPrevious();
        await until(
          () =>
              handler.snapshot.currentSongId == 'song-1' &&
              !handler.snapshot.isLoading &&
              current(player).positionOffset == Duration.zero,
        );
        expect(handler.collectPlaybackDiagnostics()['positionOffsetMs'], 0);
        expect(handler.queue.value[1].extras!['positionOffsetMs'], 0);
        expect(
          current(player).uri.queryParameters,
          isNot(contains('timeOffset')),
        );
      },
    );

    group('departed offset entry repair', () {
      bool clean(NavisAudioHandler handler, _ControllableAudioPlayer player) =>
          handler.queue.value[1].extras!['positionOffsetMs'] == 0 &&
          (player.sequence[1] as UriAudioSource).positionOffset ==
              Duration.zero &&
          !handler.snapshot.isLoading;

      Future<(NavisAudioHandler, _ControllableAudioPlayer)> leftOffset({
        PlaybackSourceResolver Function(PlaybackSourceResolver)? wrap,
      }) async {
        final (handler, player, _) = await offsetHandler(wrapResolver: wrap);
        await start(handler);
        await seekAndSettle(handler, const Duration(seconds: 90));
        await handler.skipToNext();
        await until(() => handler.snapshot.currentSongId == 'song-2');
        return (handler, player);
      }

      test('leaving an offset song repairs its entry in place', () async {
        final (handler, player) = await leftOffset();
        final loads = player.sourceLoads;
        final seeks = player.seekCalls;

        await until(() => clean(handler, player));
        await settleQueue(handler);

        expect(player.sourceLoads, loads);
        expect(player.seekCalls, seeks);
        expect(player.index, 2);
        expect(player.sourceIds, ['song-0', 'song-1', 'song-2']);
        expect(handler.snapshot.queueSongIds, ['song-0', 'song-1', 'song-2']);
        expect(handler.snapshot.currentSongId, 'song-2');
      });

      test('Previous right after leaving never starts the offset', () async {
        final (handler, player) = await leftOffset();
        final loads = player.sourceLoads;
        player.simulatedPosition = const Duration(seconds: 1);

        await handler.skipToPrevious();
        await until(
          () =>
              handler.snapshot.currentSongId == 'song-1' &&
              !handler.snapshot.isLoading,
        );
        await settleQueue(handler);

        expect(current(player).positionOffset, Duration.zero);
        expect(player.sourceLoads, loads, reason: 'no reopen safety net');
        expect(handler.collectPlaybackDiagnostics()['positionOffsetMs'], 0);
      });

      test(
        'the repeat-all wrap lands on a repaired entry without a reopen',
        () async {
          final (handler, player, _) = await offsetHandler(count: 2);
          await handler.replaceQueue([
            'song-0',
            'song-1',
          ], expandMatchFlows: false);
          await settleQueue(handler);
          await handler.play();
          await handler.setRepeatMode(AudioServiceRepeatMode.all);
          await seekAndSettle(handler, const Duration(seconds: 90));
          player.finishCurrentTrack();
          await until(
            () =>
                handler.snapshot.currentSongId == 'song-1' &&
                handler.queue.value[0].extras!['positionOffsetMs'] == 0 &&
                (player.sequence[0] as UriAudioSource).positionOffset ==
                    Duration.zero,
          );
          await settleQueue(handler);
          final loads = player.sourceLoads;

          player.finishCurrentTrack();
          await until(() => handler.snapshot.currentSongId == 'song-0');
          await settleQueue(handler);

          expect(player.sourceLoads, loads);
          expect(handler.collectPlaybackDiagnostics()['positionOffsetMs'], 0);
        },
      );

      test('a repair never removes the song that became current', () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        await seekAndSettle(handler, const Duration(seconds: 90));
        final stale = player.sequence[1];
        // The player advances onto the stale entry while its twin is being
        // inserted, before the old source would be removed.
        player.afterInsertSources = () {
          player.afterInsertSources = null;
          player
            ..index = 1
            ..simulatedPosition = Duration.zero
            .._indices.add(1);
        };
        await handler.skipToNext();
        await until(() => player.index == 1);
        await settleQueue(handler);
        await pumpEventQueue(times: 50);

        expect(player.sequence[1], same(stale), reason: 'current kept');
        expect(player.sourceIds, ['song-0', 'song-1', 'song-2']);
        expect(handler.snapshot.queueSongIds, ['song-0', 'song-1', 'song-2']);
      });

      test('a skip chain enqueues one repair', () async {
        late _GatedSourceResolver resolver;
        final (handler, player, _) = await offsetHandler(
          count: 4,
          wrapResolver: (base) => resolver = _GatedSourceResolver(base),
        );
        await handler.replaceQueue([
          'song-0',
          'song-1',
          'song-2',
          'song-3',
        ], expandMatchFlows: false);
        await settleQueue(handler);
        await handler.play();
        await seekAndSettle(handler, const Duration(seconds: 90));
        resolver
          ..blockedSongId = 'song-0'
          ..entered = Completer<void>()
          ..release = Completer<void>();
        addTearDown(() {
          if (!resolver.release!.isCompleted) resolver.release!.complete();
        });
        final edits = handler.debugQueueEditCount;

        player.finishCurrentTrack();
        await resolver.entered!.future;
        player.finishCurrentTrack();
        await pumpEventQueue(times: 50);

        expect(handler.debugQueueEditCount, edits + 1);
        resolver.release!.complete();
        await until(
          () =>
              handler.queue.value[0].extras!['positionOffsetMs'] == 0 &&
              !handler.snapshot.isLoading,
        );
      });

      test('a repair removal that times out keeps the playing song', () async {
        final rebuilt = <_ControllableAudioPlayer>[];
        final (handler, player, _) = await offsetHandler(
          count: 4,
          rebuiltPlayers: rebuilt,
          timeouts: const NavisPlaybackTimeouts(
            load: Duration(milliseconds: 300),
            reset: Duration(milliseconds: 300),
          ),
        );
        await handler.replaceQueue(
          ['song-0', 'song-1', 'song-2', 'song-3'],
          startIndex: 1,
          expandMatchFlows: false,
        );
        await settleQueue(handler);
        await handler.play();
        await seekAndSettle(handler, const Duration(seconds: 90));
        player.hang.add('removeAudioSourceAt');

        await handler.skipToNext();
        await until(() => rebuilt.isNotEmpty);
        await settleQueue(handler);

        expect(rebuilt.first.sourceIds, [
          'song-0',
          'song-1',
          'song-2',
          'song-3',
        ]);
        expect(rebuilt.first.index, 2);
        expect(handler.snapshot.currentSongId, 'song-2');
      });

      for (final edit in ['remove', 'move']) {
        test(
          'a repair racing a queue $edit leaves the queue consistent',
          () async {
            late _GatedSourceResolver resolver;
            final (handler, player) = await leftOffset(
              wrap: (base) => resolver = _GatedSourceResolver(base),
            );
            // The next song is repaired only after its entry was already
            // left: hold that repair, then edit the queue under it.
            await until(() => clean(handler, player));
            await seekAndSettle(handler, const Duration(seconds: 100));
            resolver
              ..blockedSongId = 'song-2'
              ..entered = Completer<void>()
              ..release = Completer<void>();
            player.simulatedPosition = const Duration(seconds: 1);
            await handler.skipToPrevious();
            await until(() => handler.snapshot.currentSongId == 'song-1');
            await resolver.entered!.future;
            final editing = edit == 'remove'
                ? handler.removeAt(2)
                : handler.reorderQueue(2, 0);
            resolver
              ..blockedSongId = null
              ..release!.complete();
            await editing;
            await settleQueue(handler);

            final ids = handler.snapshot.queueSongIds;
            expect(
              ids.toSet(),
              edit == 'remove'
                  ? {'song-0', 'song-1'}
                  : {'song-0', 'song-1', 'song-2'},
            );
            expect(player.sourceIds, ids);
            expect(handler.snapshot.currentSongId, 'song-1');
            for (var i = 0; i < player.sequence.length; i++) {
              expect(
                (player.sequence[i] as UriAudioSource).positionOffset,
                player.index == i
                    ? greaterThanOrEqualTo(Duration.zero)
                    : Duration.zero,
              );
            }
          },
        );
      }
    });

    test('a seek on an offset source reopens it at the new offset', () async {
      final (handler, player, _) = await offsetHandler();
      await start(handler);
      await seekAndSettle(handler, const Duration(seconds: 90));
      await seekAndSettle(handler, const Duration(seconds: 40));
      expect(current(player).positionOffset, const Duration(seconds: 40));
      await seekAndSettle(handler, const Duration(seconds: 150));
      expect(current(player).positionOffset, const Duration(seconds: 150));
      expect(lastSeekEvent(handler)['path'], 'transcodeOffset');
    });

    test('the offset never passes the last second of the song', () async {
      final (handler, player, database) = await offsetHandler();
      await database.libraryDao.upsertSongs([
        SongsTableCompanion.insert(
          id: 'song-1',
          title: 'Song 1',
          duration: const Value(180),
        ),
      ]);
      await start(handler);
      await seekAndSettle(handler, const Duration(seconds: 180));
      expect(current(player).positionOffset, const Duration(seconds: 179));
    });

    test(
      'edge 1: a seek during an in-flight offset reload wins with one reload',
      () async {
        late _GatedSourceResolver resolver;
        final (handler, player, _) = await offsetHandler(
          wrapResolver: (base) => resolver = _GatedSourceResolver(base),
        );
        await start(handler);
        final loadsBefore = player.sourceLoads;
        resolver
          ..blockedSongId = 'song-1'
          ..entered = Completer<void>()
          ..release = Completer<void>();

        final first = handler.seek(const Duration(seconds: 60));
        await resolver.entered!.future;
        final latest = handler.seek(const Duration(seconds: 120));
        resolver
          ..blockedSongId = null
          ..release!.complete();
        await Future.wait([first, latest]);
        await until(() => !handler.snapshot.isLoading);

        expect(current(player).positionOffset, const Duration(seconds: 120));
        expect(player.sourceLoads, loadsBefore + 1);
        expect(player.sourceIds, ['song-0', 'song-1', 'song-2']);
      },
    );

    test(
      'edge 2: the natural end of an offset stream advances without a replay',
      () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        await seekAndSettle(handler, const Duration(seconds: 170));
        final loadsBefore = player.sourceLoads;

        player.finishCurrentTrack();
        await until(() => handler.snapshot.currentSongId == 'song-2');
        await settleQueue(handler);

        expect(player.index, 2);
        expect(player.sourceLoads, loadsBefore);
        expect(current(player).positionOffset, Duration.zero);
        expect(player.position, lessThan(const Duration(seconds: 2)));
      },
    );

    test('repeat all wrapping onto a song that played as an offset starts it '
        'at 0', () async {
      final (handler, player, _) = await offsetHandler(count: 2);
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      await settleQueue(handler);
      await handler.play();
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      await seekAndSettle(handler, const Duration(seconds: 90));
      expect(current(player).positionOffset, const Duration(seconds: 90));

      player.finishCurrentTrack();
      await until(() => handler.snapshot.currentSongId == 'song-1');
      player.finishCurrentTrack();
      await until(
        () =>
            handler.snapshot.currentSongId == 'song-0' &&
            !handler.snapshot.isLoading &&
            current(player).positionOffset == Duration.zero,
      );

      expect(handler.collectPlaybackDiagnostics()['positionOffsetMs'], 0);
      expect(handler.queue.value[0].extras!['positionOffsetMs'], 0);
      expect(
        current(player).uri.queryParameters,
        isNot(contains('timeOffset')),
      );
      expect(player.position, lessThan(const Duration(seconds: 2)));
    });

    test('an offset reload of the current song starts no extra seek', () async {
      final (handler, player, _) = await offsetHandler();
      await start(handler);
      final loads = player.sourceLoads;
      final events =
          (handler.collectPlaybackDiagnostics()['seekEvents']! as List).length;

      await seekAndSettle(handler, const Duration(seconds: 90));
      // The reload's own index change and playback events are not loops.
      player._events.add(player.playbackEvent);
      await pumpEventQueue(times: 50);
      await settleQueue(handler);

      expect(player.sourceLoads, loads + 1);
      expect(
        (handler.collectPlaybackDiagnostics()['seekEvents']! as List).length,
        events + 1,
      );
      expect(current(player).positionOffset, const Duration(seconds: 90));
    });

    test('an index change during an offset reload is not a wrap', () async {
      final (handler, player, _) = await offsetHandler();
      await start(handler);
      await seekAndSettle(handler, const Duration(seconds: 90));
      final loads = player.sourceLoads;
      final gate = Completer<void>();
      final entered = Completer<void>();
      player
        ..loadGate = gate
        ..loadEntered = entered;

      final seeking = handler.seek(const Duration(seconds: 120));
      await entered.future;
      // The reload reports an index change while the old offset source is
      // still in the sequence.
      player._discontinuities.add(
        PositionDiscontinuity(
          PositionDiscontinuityReason.autoAdvance,
          PlaybackEvent(
            processingState: ProcessingState.ready,
            updatePosition: const Duration(seconds: 3),
            currentIndex: 0,
          ),
          player.playbackEvent,
        ),
      );
      await pumpEventQueue(times: 50);
      gate.complete();
      await seeking;
      await until(() => !handler.snapshot.isLoading);
      await settleQueue(handler);

      expect(player.sourceLoads, loads + 1);
      expect(current(player).positionOffset, const Duration(seconds: 120));
    });

    for (final index in [1, 2]) {
      test('edge 3: repeat one reloads offset item $index exactly once', () async {
        final (handler, player, _) = await offsetHandler();
        await handler.replaceQueue(
          ['song-0', 'song-1', 'song-2'],
          startIndex: index,
          expandMatchFlows: false,
        );
        await settleQueue(handler);
        await handler.play();
        await handler.setRepeatMode(AudioServiceRepeatMode.one);
        await seekAndSettle(handler, const Duration(seconds: 170));
        expect(player.loopMode, LoopMode.one);
        final loadsBefore = player.sourceLoads;

        // The owned native seek reports the same tail-to-start event as a loop.
        player.finishCurrentTrack();
        // Further playback events following that seek are not more loops.
        player._events.add(player.playbackEvent);
        player._events.add(player.playbackEvent);
        await until(
          () =>
              player.sourceLoads == loadsBefore + 1 &&
              !handler.snapshot.isLoading,
        );
        await settleQueue(handler);

        expect(player.sourceLoads, loadsBefore + 1);
        expect(current(player).positionOffset, Duration.zero);
        expect(
          current(player).uri.queryParameters,
          isNot(contains('timeOffset')),
        );
        expect(player.position, lessThan(const Duration(seconds: 2)));
        expect(player.sourceIds, ['song-0', 'song-1', 'song-2']);
        expect(player.index, index);
        expect(player.playing, isTrue);
        expect(player.loopMode, LoopMode.one);
      });
    }

    test(
      'edge 3: repeat all auto-advance never restarts the next song while the '
      'current item lags',
      () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        await handler.setRepeatMode(AudioServiceRepeatMode.all);
        await seekAndSettle(handler, const Duration(seconds: 100));
        expect(player.loopMode, LoopMode.all);
        await settleQueue(handler);
        final loadsBefore = player.sourceLoads;
        final seeksBefore = player.seekCalls;
        player.simulatedPosition = const Duration(seconds: 179);
        player._events.add(player.playbackEvent);
        await pumpEventQueue();

        // The native advance event reaches the handler before the index
        // chain moves its current item off the offset song.
        player
          ..index = 2
          ..simulatedPosition = Duration.zero;
        player._events.add(player.playbackEvent);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        player._indices.add(2);
        player._discontinuities.add(
          PositionDiscontinuity(
            PositionDiscontinuityReason.autoAdvance,
            PlaybackEvent(
              processingState: ProcessingState.ready,
              updatePosition: const Duration(seconds: 179),
              currentIndex: 1,
            ),
            player.playbackEvent,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(player.sourceLoads, loadsBefore);
        expect(player.seekCalls, seeksBefore);
        expect(handler.snapshot.currentSongId, 'song-2');
        expect(lastSeekEvent(handler)['requestedPositionMs'], 100000);
      },
    );

    test(
      'edge 3: repeat all over a single offset song reloads it from zero',
      () async {
        final directory = await Directory.systemTemp.createTemp('navis-loop1-');
        final (handler, player, database) = await createHandler(
          directory,
          1,
          sidecarStreams: true,
          streamingQuality: opus128,
          supportsTranscodeOffset: true,
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        player.simulateProgress = true;
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        await settleQueue(handler);
        await handler.play();
        await handler.setRepeatMode(AudioServiceRepeatMode.all);
        await seekAndSettle(handler, const Duration(seconds: 170));
        final loadsBefore = player.sourceLoads;

        player.finishCurrentTrack();
        await until(
          () =>
              player.sourceLoads == loadsBefore + 1 &&
              !handler.snapshot.isLoading,
        );

        expect(current(player).positionOffset, Duration.zero);
        expect(player.position, lessThan(const Duration(seconds: 2)));
      },
    );

    test(
      'edge 3: a loop during the background queue fill still reloads from zero',
      () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        await handler.setRepeatMode(AudioServiceRepeatMode.one);
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..appendGate = gate
          ..appendEntered = entered;
        await handler.seek(const Duration(seconds: 100));
        await entered.future;
        // The fill that restores the rest of the queue is still running.
        expect(handler.snapshot.isLoading, isTrue);
        expect(current(player).positionOffset, const Duration(seconds: 100));
        final loadsBefore = player.sourceLoads;

        player.finishCurrentTrack();
        await pumpEventQueue();
        gate.complete();
        await until(
          () =>
              player.sourceLoads == loadsBefore + 1 &&
              !handler.snapshot.isLoading,
        );

        expect(current(player).positionOffset, Duration.zero);
        expect(player.position, lessThan(const Duration(seconds: 2)));
        expect(player.sourceIds, ['song-0', 'song-1', 'song-2']);
      },
    );

    test('edge 3: a loop during teardown starts no seek', () async {
      final (handler, player, _) = await offsetHandler();
      await start(handler);
      await handler.setRepeatMode(AudioServiceRepeatMode.one);
      await seekAndSettle(handler, const Duration(seconds: 100));
      await settleQueue(handler);
      final gate = Completer<void>();
      final entered = Completer<void>();
      player
        ..listenerCancelGate = gate
        ..listenerCancelEntered = entered;

      final disposal = handler.disposeHandler();
      await entered.future;
      // Disposal has started but the discontinuity listener is still wired.
      player.finishCurrentTrack();
      await pumpEventQueue();
      gate.complete();
      await disposal;

      expect(
        handler.collectPlaybackDiagnostics()['seek'],
        containsPair('requestedPositionMs', 100000),
      );
    });

    test('edge 4: Previous reloads an offset song from zero', () async {
      final (handler, player, _) = await offsetHandler();
      await start(handler);
      await seekAndSettle(handler, const Duration(seconds: 100));

      await handler.skipToPrevious();
      await until(
        () =>
            !handler.snapshot.isLoading &&
            player.position < const Duration(seconds: 2),
      );

      expect(handler.snapshot.currentSongId, 'song-1');
      expect(current(player).positionOffset, Duration.zero);
      expect(
        current(player).uri.queryParameters,
        isNot(contains('timeOffset')),
      );
    });

    test('edge 5: an offset reload keeps the scrobble session', () async {
      final scrobbles = _NoopScrobbleService();
      final (handler, player, _) = await offsetHandler(
        scrobbleService: scrobbles,
        positionStreams: true,
      );
      await start(handler);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final sessions = scrobbles.nowPlayingSessions.length;
      expect(sessions, 1);

      await seekAndSettle(handler, const Duration(seconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(current(player).positionOffset, const Duration(seconds: 100));
      expect(scrobbles.nowPlaying, ['song-1']);
      expect(scrobbles.nowPlayingSessions, hasLength(1));
    });

    test(
      'edge 6: the sidecar keeps downloading the full non-offset stream',
      () async {
        final previousHttp = HttpOverrides.current;
        HttpOverrides.global = null;
        final requests = <Map<String, String>>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final release = Completer<void>();
        server.listen((request) async {
          requests.add(request.uri.queryParameters);
          try {
            request.response
              ..bufferOutput = false
              ..contentLength = 100 * 1024
              ..add(List<int>.filled(10 * 1024, 1));
            await request.response.flush();
            await release.future;
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
        final (handler, player, _) = await offsetHandler(
          readApiClient: () => api,
        );
        addTearDown(() async {
          release.complete();
          await server.close(force: true);
          HttpOverrides.global = previousHttp;
        });
        await start(handler);
        await until(() => requests.isNotEmpty);
        expect(
          handler.collectPlaybackDiagnostics()['sidecarCacheActiveSongId'],
          'song-1',
        );

        await seekAndSettle(handler, const Duration(seconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(current(player).uri.queryParameters['timeOffset'], '100');
        expect(
          handler.collectPlaybackDiagnostics()['sidecarCacheActiveSongId'],
          'song-1',
        );
        expect(
          [for (final q in requests) '${q['id']}:${q['timeOffset']}'],
          ['song-1:null'],
        );
        expect(requests.single['id'], 'song-1');
        expect(requests.single, isNot(contains('timeOffset')));
      },
    );

    test(
      'edge 7: once the full download completes a seek uses the file',
      () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        final sidecar =
            handler.queue.value[1].extras!['sidecarCacheFilePath'] as String;
        await seekAndSettle(handler, const Duration(seconds: 60));
        expect(current(player).positionOffset, const Duration(seconds: 60));
        expect(handler.queue.value[1].extras!['sidecarCacheFilePath'], sidecar);
        await File(sidecar).writeAsBytes(List<int>.filled(64, 1));

        await seekAndSettle(handler, const Duration(seconds: 120));

        expect(handler.queue.value[1].extras!['sourceKind'], 'file');
        expect(handler.queue.value[1].extras!['positionOffsetMs'], 0);
        expect(current(player).positionOffset, Duration.zero);
        expect(current(player).uri.scheme, 'file');
        expect(lastSeekEvent(handler)['path'], isNot('transcodeOffset'));
      },
    );

    test('edge 7 (lock cache): the original download fills the file an offset '
        'stream leaves; a later seek reloads from it', () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-offset-lock-',
      );
      final api = SubsonicApiClient(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
        ),
        enableLogging: false,
      );
      final (handler, player, database) = await createHandler(
        directory,
        3,
        cacheSongs: false,
        readApiClient: () => api,
        streamingQuality: opus128,
        supportsTranscodeOffset: true,
        // The origin never answers, so the range probe gives up quickly.
        timeouts: const NavisPlaybackTimeouts(
          load: Duration(milliseconds: 300),
        ),
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      player.simulateProgress = true;
      await start(handler);
      final lockCached = handler.queue.value[1].extras!;
      expect(lockCached['sourceKind'], 'lockCachedStream');
      final cachePath = lockCached['cachedFilePath']! as String;

      await failAt(handler, player, const Duration(seconds: 70));
      expect(current(player).positionOffset, const Duration(seconds: 70));
      expect(current(player).uri.queryParameters['timeOffset'], '70');
      expect(player.position.inSeconds, 70);

      await seekAndSettle(handler, const Duration(seconds: 100));

      final offsetItem = handler.queue.value[1].extras!;
      expect(offsetItem['sourceKind'], 'directStream');
      expect(offsetItem['positionOffsetMs'], 100000);
      expect(offsetItem['cachedFilePath'], cachePath);
      expect(current(player).positionOffset, const Duration(seconds: 100));
      expect(lastSeekEvent(handler)['path'], 'transcodeOffset');

      // The lock-cache download finishes beside the offset stream.
      await File(cachePath).writeAsBytes(List<int>.filled(64, 1));
      await seekAndSettle(handler, const Duration(seconds: 150));

      expect(handler.queue.value[1].extras!['sourceKind'], 'file');
      expect(current(player).positionOffset, Duration.zero);
      expect(lastSeekEvent(handler)['path'], isNot('transcodeOffset'));
    });

    test('edge 8: no timeOffset without the capability', () async {
      final (handler, player, _) = await offsetHandler(capable: false);
      player.ignoreSeeks = true;
      await start(handler);

      await handler.seek(const Duration(seconds: 90));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      for (final source in player.sequence.whereType<UriAudioSource>()) {
        expect(source.uri.queryParameters, isNot(contains('timeOffset')));
        expect(source.positionOffset, Duration.zero);
      }
    });

    test('edge 8: no timeOffset for original quality', () async {
      final (handler, player, _) = await offsetHandler(
        quality: const StreamingQuality(label: 'original'),
      );
      player.ignoreSeeks = true;
      await start(handler);

      await handler.seek(const Duration(seconds: 90));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      for (final source in player.sequence.whereType<UriAudioSource>()) {
        expect(source.uri.queryParameters, isNot(contains('timeOffset')));
        expect(source.positionOffset, Duration.zero);
      }
    });

    test('a seek under a second stays a native seek', () async {
      final (handler, player, _) = await offsetHandler();
      await start(handler);
      final loadsBefore = player.sourceLoads;

      await handler.seek(const Duration(milliseconds: 400));

      expect(player.sourceLoads, loadsBefore);
      expect(player.seekCalls, greaterThan(0));
    });

    test(
      'a failed offset reload falls back to the existing seek path',
      () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        player.ignoreSeeks = true;
        // The offset load fails; the fallback may only reload without one.
        player.failLoadSongId = 'song-1';

        await handler.seek(const Duration(seconds: 90));
        await Future<void>.delayed(const Duration(milliseconds: 100));

        for (final source in player.sequence.whereType<UriAudioSource>()) {
          expect(source.positionOffset, Duration.zero);
        }
        expect(lastSeekEvent(handler)['path'], isNot('transcodeOffset'));
      },
    );
  });

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
      for (final (count, current) in [(12, 5), (60, 5), (100, 50)]) {
        test('turning shuffle on shuffles the whole queue without restarting '
            '($count songs at $current)', () async {
          final (handler, player, _) = await windowed(count);
          await handler.replaceQueue(
            ids(count),
            startIndex: current,
            expandMatchFlows: false,
          );
          await handler.play();
          player.simulatedPosition = const Duration(seconds: 42);
          final item = handler.mediaItem.value;
          final loads = player.sourceLoads;
          final seeks = player.seekCalls;
          final stops = player.stopCalls;
          final starts = player.playedFrom.length;
          final check = watchAudioMetadata(handler, [player]);
          if (current > window.behind) {
            expect(
              handler.collectPlaybackDiagnostics()['deferredHeadLength'],
              isPositive,
            );
          }

          await handler.setShuffleMode(AudioServiceShuffleMode.all);

          final queue = handler.snapshot.queueSongIds;
          expect(queue, shuffledFromStart(ids(count), current, Random(7)));
          expect(queue.first, 'song-$current');
          expect(queue, hasLength(count));
          expect(queue.toSet(), ids(count).toSet());
          expect(handler.snapshot.currentIndex, 0);
          expect(handler.snapshot.shuffleMode, AudioServiceShuffleMode.all);
          expect(handler.mediaItem.value, same(item));
          expect(player.index, 0);
          expect(player.position, const Duration(seconds: 42));
          expect(player.playing, isTrue);
          expect(player.sourceLoads, loads);
          expect(player.seekCalls, seeks);
          expect(player.stopCalls, stops);
          expect(player.playedFrom, hasLength(starts));
          expect(handler.playbackState.value.queueIndex, 0);
          expect(handler.queue.value.first, same(item));
          if (count > window.deferThreshold) {
            expect(
              handler.collectPlaybackDiagnostics()['deferredLength'],
              isPositive,
            );
            expect(player.sourceIds.length, lessThan(count));
          }
          expect(handler.collectPlaybackDiagnostics()['deferredHeadLength'], 0);
          await check();

          await handler.setShuffleMode(AudioServiceShuffleMode.none);

          expect(handler.snapshot.queueSongIds, ids(count));
          expect(handler.snapshot.currentIndex, current);
          expect(handler.snapshot.currentSongId, 'song-$current');
          expect(handler.mediaItem.value, same(item));
          expect(player.position, const Duration(seconds: 42));
          expect(player.playing, isTrue);
          expect(player.sourceLoads, loads);
          expect(player.seekCalls, seeks);
          expect(player.stopCalls, stops);
          expect(player.playedFrom, hasLength(starts));
          expectNativeMirrorsQueue(handler, player);
        });
      }

      for (final repeat in [
        AudioServiceRepeatMode.none,
        AudioServiceRepeatMode.all,
        AudioServiceRepeatMode.one,
      ]) {
        test('previous after shuffle behaves like the start of a queue '
            '($repeat)', () async {
          final (handler, player, _) = await windowed(60);
          await handler.replaceQueue(
            ids(60),
            startIndex: 5,
            expandMatchFlows: false,
          );
          await handler.setRepeatMode(repeat);
          player.simulatedPosition = const Duration(seconds: 42);
          await handler.setShuffleMode(AudioServiceShuffleMode.all);
          expect(handler.snapshot.currentIndex, 0);
          final order = List<String>.of(handler.snapshot.queueSongIds);
          expect(
            player.appliedLoopMode,
            repeat == AudioServiceRepeatMode.one ? LoopMode.one : LoopMode.off,
          );

          await handler.skipToPrevious();
          await settleQueue(handler);
          expect(handler.snapshot.currentIndex, 0);
          expect(handler.snapshot.currentSongId, 'song-5');
          expect(player.position, Duration.zero);

          await handler.skipToPrevious();
          await settleQueue(handler);
          final expected = repeat == AudioServiceRepeatMode.all ? 59 : 0;
          expect(handler.snapshot.currentIndex, expected);
          expect(handler.snapshot.currentSongId, order[expected]);
          expect(handler.snapshot.queueSongIds, order);
          expectNativeMirrorsQueue(handler, player);
        });
      }

      test('turning shuffle off restores the order, with songs added while '
          'shuffled', () async {
        final (handler, player, _) = await windowed(60);
        await handler.replaceQueue(ids(60), expandMatchFlows: false);
        player.moveTo(5);
        await handler.setShuffleMode(AudioServiceShuffleMode.all);
        await handler.playNext(<String>['song-0'], expandMatchFlows: false);
        await handler.addToQueue(<String>['song-1'], expandMatchFlows: false);
        // Later in the shuffled play order.
        player.moveTo(7);
        final playing = handler.snapshot.queueSongIds[7];

        await handler.setShuffleMode(AudioServiceShuffleMode.none);

        final expected = <String>[...ids(6), 'song-0', ...ids(60, 6), 'song-1'];
        expect(handler.snapshot.queueSongIds, expected);
        expect(handler.snapshot.shuffleMode, AudioServiceShuffleMode.none);
        expect(handler.snapshot.currentSongId, playing);
        expect(handler.snapshot.currentIndex, expected.indexOf(playing));
        expect(player.sourceIds[player.index!], playing);
        expectNativeMirrorsQueue(handler, player);
      });

      Future<void> expectMode(
        NavisAudioHandler handler,
        NavisDatabase database,
        AudioServiceShuffleMode mode,
      ) async {
        await handler.debugFlushQueuePersistence();
        expect(handler.snapshot.shuffleMode, mode);
        expect(handler.playbackState.value.shuffleMode, mode);
        expect(
          (await database.playQueueDao.getQueueState())!.shuffleMode,
          mode == AudioServiceShuffleMode.all
              ? ShuffleMode.all
              : ShuffleMode.off,
        );
      }

      for (final rows in [false, true]) {
        test('a plain replace after shuffle plays in order with shuffle off '
            '(rows=$rows)', () async {
          final (handler, player, database) = await windowed(60);
          await handler.replaceQueue(ids(60), expandMatchFlows: false);
          await handler.setShuffleMode(AudioServiceShuffleMode.all);
          await expectMode(handler, database, AudioServiceShuffleMode.all);
          expect(handler.snapshot.queueSongIds, isNot(ids(60)));

          if (rows) {
            await handler.replaceQueueWithData(
              await database.libraryDao.getSongsByIds(ids(60)),
              startIndex: 10,
              expandMatchFlows: false,
            );
          } else {
            await handler.replaceQueue(
              ids(60),
              startIndex: 10,
              expandMatchFlows: false,
            );
          }
          expect(handler.snapshot.queueSongIds, ids(60));
          expect(handler.snapshot.currentSongId, 'song-10');
          await expectMode(handler, database, AudioServiceShuffleMode.none);
          expectNativeMirrorsQueue(handler, player);

          // The toggle still shuffles and restores the new queue.
          await handler.setShuffleMode(AudioServiceShuffleMode.all);
          expect(handler.snapshot.currentSongId, 'song-10');
          expect(handler.snapshot.queueSongIds.first, 'song-10');
          expect(handler.snapshot.queueSongIds, isNot(ids(60)));
          await handler.setShuffleMode(AudioServiceShuffleMode.none);
          expect(handler.snapshot.queueSongIds, ids(60));
          expect(handler.snapshot.currentSongId, 'song-10');
        });
      }

      test(
        'entity Shuffle turns shuffle on and the next Play turns it off',
        () async {
          final (handler, player, database) = await windowed(60);
          final shuffled = (await database.libraryDao.getSongsByIds(ids(60)))
            ..shuffle(Random(5));
          await handler.replaceQueueWithData(
            shuffled,
            originalOrder: ids(60),
            expandMatchFlows: false,
          );
          expect(handler.snapshot.queueSongIds, [
            for (final r in shuffled) r.id,
          ]);
          await expectMode(handler, database, AudioServiceShuffleMode.all);

          await handler.replaceQueue(ids(60), expandMatchFlows: false);
          expect(handler.snapshot.queueSongIds, ids(60));
          await expectMode(handler, database, AudioServiceShuffleMode.none);
          expectNativeMirrorsQueue(handler, player);
        },
      );

      test(
        'Add to queue and Play next never change the shuffle mode',
        () async {
          final (handler, _, database) = await windowed(30);
          await handler.replaceQueue(ids(10), expandMatchFlows: false);
          await handler.setShuffleMode(AudioServiceShuffleMode.all);
          await handler.addToQueue(['song-20'], expandMatchFlows: false);
          await handler.playNext(['song-21'], expandMatchFlows: false);
          await expectMode(handler, database, AudioServiceShuffleMode.all);
          expect(handler.snapshot.queueSongIds, hasLength(12));

          await handler.setShuffleMode(AudioServiceShuffleMode.none);
          await handler.addToQueue(['song-22'], expandMatchFlows: false);
          await handler.playNext(['song-23'], expandMatchFlows: false);
          await expectMode(handler, database, AudioServiceShuffleMode.none);
        },
      );

      test('batched inserts into a shuffled queue keep it shuffled', () async {
        final (handler, _, database) = await windowed(30);
        await handler.replaceQueue(ids(10), expandMatchFlows: false);
        await handler.setShuffleMode(AudioServiceShuffleMode.all);
        final order = List.of(handler.snapshot.queueSongIds);
        await handler.mergeIntoUpcoming(
          await database.libraryDao.getSongsByIds(ids(30, 10)),
          notBefore: 1,
          random: Random(7),
        );
        await expectMode(handler, database, AudioServiceShuffleMode.all);
        expect(handler.snapshot.queueSongIds, hasLength(30));
        // The earlier songs keep their shuffled order.
        expect(
          handler.snapshot.queueSongIds.where(ids(10).contains).toList(),
          order,
        );
      });

      test('clearing the queue ends its shuffle mode', () async {
        final (handler, _, database) = await windowed(30);
        await handler.replaceQueue(ids(10), expandMatchFlows: false);
        await handler.setShuffleMode(AudioServiceShuffleMode.all);
        await handler.clearQueue();
        expect(handler.snapshot.shuffleMode, AudioServiceShuffleMode.none);
        await handler.addToQueue(ids(5), expandMatchFlows: false);
        expect(handler.snapshot.queueSongIds, ids(5));
        await expectMode(handler, database, AudioServiceShuffleMode.none);
      });

      test(
        'a mix started from a shuffled queue starts with shuffle off',
        () async {
          final (handler, _, database) = await windowed(30);
          await handler.replaceQueue(ids(10), expandMatchFlows: false);
          await handler.setShuffleMode(AudioServiceShuffleMode.all);
          final current = handler.snapshot.currentSongId!;
          await handler.retainCurrentSongAsQueue(current);
          await handler.addToQueue(ids(30, 20), expandMatchFlows: false);
          expect(handler.snapshot.queueSongIds, [current, ...ids(30, 20)]);
          await expectMode(handler, database, AudioServiceShuffleMode.none);

          // Toggling on and off again still restores the mix order.
          await handler.setShuffleMode(AudioServiceShuffleMode.all);
          await handler.setShuffleMode(AudioServiceShuffleMode.none);
          expect(handler.snapshot.queueSongIds, [current, ...ids(30, 20)]);
        },
      );

      test(
        'no emission pairs the old queue with the new mode or the reverse',
        () async {
          final (handler, _, _) = await windowed(30);
          await handler.replaceQueue(ids(10), expandMatchFlows: false);
          await handler.setShuffleMode(AudioServiceShuffleMode.all);
          final shuffled = List.of(handler.snapshot.queueSongIds);
          expect(shuffled, isNot(ids(10)));
          final seen = <PlaybackSnapshot>[];
          final sub = handler.snapshotStream.listen(seen.add);
          await handler.replaceQueue(
            ids(10),
            startIndex: 3,
            expandMatchFlows: false,
          );
          await settleQueue(handler);
          await sub.cancel();
          expect(seen, isNotEmpty);
          for (final snapshot in seen) {
            final oldQueue = listEquals(snapshot.queueSongIds, shuffled);
            final newQueue = listEquals(snapshot.queueSongIds, ids(10));
            expect(oldQueue || newQueue, isTrue);
            expect(
              snapshot.shuffleMode,
              oldQueue
                  ? AudioServiceShuffleMode.all
                  : AudioServiceShuffleMode.none,
              reason: 'queue ${snapshot.queueSongIds}',
            );
          }
        },
      );

      test('repeat all never reshuffles an in-order queue', () async {
        final (handler, player, _) = await windowed(12);
        await handler.replaceQueue(ids(12), expandMatchFlows: false);
        await handler.setShuffleMode(AudioServiceShuffleMode.all);
        await handler.replaceQueue(ids(12), expandMatchFlows: false);
        await handler.setRepeatMode(AudioServiceRepeatMode.all);
        player.moveTo(11);
        await handler.skipToNext();
        await until(() => handler.snapshot.currentSongId == 'song-0');
        expect(handler.snapshot.queueSongIds, ids(12));
        expect(handler.snapshot.shuffleMode, AudioServiceShuffleMode.none);
      });

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
        final directory = await Directory.systemTemp.createTemp('navis-shuf-');
        final (handler, player, database) = await createHandler(
          directory,
          60,
          queueWindow: window,
        );
        var closed = false;
        Future<void> close() async {
          if (closed) return;
          await handler.disposeHandler();
          await database.close();
          closed = true;
        }

        addTearDown(() async {
          await close();
          await directory.delete(recursive: true);
        });
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
        final state = (await database.playQueueDao.getQueueState())!;
        expect(state.currentIndex, 0);
        expect(state.shuffleMode, ShuffleMode.all);
        final playOrder = List.of(handler.snapshot.queueSongIds);
        await close();
        final (restored, restoredPlayer) = await restoring(
          playOrder: saved.map((entry) => entry.song.id).toList(),
          currentIndex: state.currentIndex!,
          originalOrder: saved.map((entry) => entry.originalOrder!).toList(),
        );
        expect(restored.snapshot.queueSongIds, playOrder);
        expect(restored.snapshot.currentSongId, 'song-3');
        expect(restored.snapshot.currentIndex, 0);
        expect(restored.snapshot.shuffleMode, AudioServiceShuffleMode.all);
        await restored.setShuffleMode(AudioServiceShuffleMode.none);
        expect(restored.snapshot.queueSongIds, ids(60));
        expect(restored.snapshot.currentSongId, 'song-3');
        expect(restored.snapshot.currentIndex, 3);
        expectNativeMirrorsQueue(restored, restoredPlayer);
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
      bool transcodeOffset = false,
      NavisPlaybackTimeouts timeouts = const NavisPlaybackTimeouts(),
      PlaybackSourceResolver Function(PlaybackSourceResolver)? wrapResolver,
    }) async {
      final directory = await Directory.systemTemp.createTemp('navis-fade-');
      final created = await createHandler(
        directory,
        count,
        crossfade: true,
        sidecarStreams: sidecarStreams || transcodeOffset,
        streamingQuality: transcodeOffset
            ? const StreamingQuality(
                label: 'opus',
                maxBitRate: 128,
                format: 'opus',
              )
            : const StreamingQuality(label: 'original'),
        supportsTranscodeOffset: transcodeOffset,
        timeouts: timeouts,
        wrapResolver: wrapResolver,
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

    group('after a swap off an offset stream', () {
      // Song 0 plays as a transcode opened at 90 s, then crossfades into
      // song 1, which starts at its own beginning.
      Future<(NavisAudioHandler, _ControllableAudioPlayer)> swapped() async {
        final (handler, outgoing, _) = await crossfading(
          3,
          transcodeOffset: true,
        );
        outgoing.simulateProgress = true;
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        await handler.seek(const Duration(seconds: 90));
        await waitForFade(() => !handler.snapshot.isLoading);
        expect(handler.collectPlaybackDiagnostics()['positionOffsetMs'], 90000);
        final incoming = handler.debugInactiveDeck! as _ControllableAudioPlayer;
        incoming.simulateProgress = true;
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        await waitForFade(() => incoming.playing && incoming.volume > 0);
        await handler.debugCompleteCrossfade();
        expect(handler.debugActivePlayer, same(incoming));
        return (handler, incoming);
      }

      test('the current item and its offset belong to the new song', () async {
        final (handler, _) = await swapped();
        await waitForFade(() => handler.snapshot.currentSongId == 'song-1');
        expect(handler.mediaItem.valueOrNull?.id, 'song-1');
        expect(handler.collectPlaybackDiagnostics()['positionOffsetMs'], 0);
      });

      test('a seek on the new song is not an offset reopen', () async {
        final (handler, incoming) = await swapped();
        final loads = incoming.sourceLoads;
        // Under a second a fresh stream seeks natively; an offset one reopens.
        await handler.seek(const Duration(milliseconds: 500));
        await waitForFade(() => !handler.snapshot.isLoading);
        final events =
            handler.collectPlaybackDiagnostics()['seekEvents']! as List;
        expect((events.last as Map)['path'], isNot('transcodeOffset'));
        expect(incoming.sourceLoads, loads);
        expect(handler.collectPlaybackDiagnostics()['positionOffsetMs'], 0);
      });

      test('restart on the new song does not reopen an offset', () async {
        final (handler, incoming) = await swapped();
        incoming.simulatedPosition = const Duration(seconds: 10);
        final loads = incoming.sourceLoads;
        await handler.skipToPrevious();
        await waitForFade(() => !handler.snapshot.isLoading);
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(incoming.sourceLoads, loads);
        expect(handler.collectPlaybackDiagnostics()['positionOffsetMs'], 0);
      });

      test(
        'no crossfade into an unrepaired offset song: the wrap starts it at 0',
        () async {
          late _GatedSourceResolver resolver;
          final (handler, outgoing, _) = await crossfading(
            2,
            transcodeOffset: true,
            wrapResolver: (base) => resolver = _GatedSourceResolver(base),
          );
          outgoing.simulateProgress = true;
          await handler.replaceQueue(ids(2), expandMatchFlows: false);
          await handler.setRepeatMode(AudioServiceRepeatMode.all);
          await handler.seek(const Duration(seconds: 90));
          await waitForFade(() => !handler.snapshot.isLoading);
          final first = handler.debugInactiveDeck! as _ControllableAudioPlayer;
          first.simulateProgress = true;
          handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
          await waitForFade(() => first.playing && first.volume > 0);
          // Hold the repair of song 0 once it is left.
          resolver
            ..blockedSongId = 'song-0'
            ..release = Completer<void>();
          addTearDown(() {
            if (!resolver.release!.isCompleted) resolver.release!.complete();
          });
          await handler.debugCompleteCrossfade();
          await waitForFade(() => handler.snapshot.currentSongId == 'song-1');

          // Song 0 still carries its offset: its end is a plain advance.
          final deck = handler.debugInactiveDeck as _ControllableAudioPlayer?;
          handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
          await pumpEventQueue(times: 50);
          expect(fade(handler)['active'], isFalse);
          expect(deck?.playing ?? false, isFalse);
          final active = handler.debugActivePlayer as _ControllableAudioPlayer;
          active.finishCurrentTrack();
          await pumpEventQueue(times: 20);
          resolver.release!.complete();
          await waitForFade(
            () =>
                handler.snapshot.currentSongId == 'song-0' &&
                !handler.snapshot.isLoading &&
                handler.collectPlaybackDiagnostics()['positionOffsetMs'] == 0,
          );
          final source = active.sequence[0] as UriAudioSource;
          expect(source.positionOffset, Duration.zero);
        },
      );

      test('a crossfade into the repaired entry needs no reopen', () async {
        final (handler, outgoing, _) = await crossfading(
          2,
          transcodeOffset: true,
        );
        outgoing.simulateProgress = true;
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        await handler.setRepeatMode(AudioServiceRepeatMode.all);
        await handler.seek(const Duration(seconds: 90));
        await waitForFade(() => !handler.snapshot.isLoading);
        final first = handler.debugInactiveDeck! as _ControllableAudioPlayer;
        first.simulateProgress = true;
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        await waitForFade(() => first.playing && first.volume > 0);
        await handler.debugCompleteCrossfade();
        await waitForFade(
          () =>
              handler.snapshot.currentSongId == 'song-1' &&
              handler.queue.value[0].extras!['positionOffsetMs'] == 0 &&
              !handler.snapshot.isLoading,
        );
        await settleQueue(handler);
        final deck = handler.debugInactiveDeck! as _ControllableAudioPlayer;
        final loads = deck.sourceLoads;
        deck.simulateProgress = true;
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        await waitForFade(() => deck.playing && deck.volume > 0);
        await handler.debugCompleteCrossfade();
        await waitForFade(() => handler.snapshot.currentSongId == 'song-0');
        await settleQueue(handler);

        expect(handler.collectPlaybackDiagnostics()['positionOffsetMs'], 0);
        expect(handler.debugActivePlayer, same(deck));
        expect(deck.sourceLoads, loads);
      });

      test(
        'a tap during the repair resolves against the shown queue',
        () async {
          final (handler, outgoing, _) = await crossfading(
            4,
            transcodeOffset: true,
            timeouts: const NavisPlaybackTimeouts(
              load: Duration(seconds: 2),
              reset: Duration(seconds: 2),
            ),
          );
          outgoing.simulateProgress = true;
          await handler.replaceQueue(ids(4), expandMatchFlows: false);
          await handler.seek(const Duration(seconds: 90));
          await waitForFade(() => !handler.snapshot.isLoading);
          final incoming =
              handler.debugInactiveDeck! as _ControllableAudioPlayer;
          incoming.simulateProgress = true;
          handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
          await waitForFade(() => incoming.playing && incoming.volume > 0);
          // The old player becomes the deck: its mirror of the repair waits.
          final gate = Completer<void>();
          outgoing
            ..insertGate = gate
            ..insertEntered = Completer<void>();
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
          await handler.debugCompleteCrossfade();
          await waitForFade(() => handler.snapshot.currentSongId == 'song-1');
          // The repair is inserting its twin and waits on the deck mirror.
          await outgoing.insertEntered!.future;
          expect(handler.queue.value.map((item) => item.id), ids(4));

          final tap = handler.skipToQueueItem(2);
          await pumpEventQueue(times: 20);
          gate.complete();
          await tap;
          await waitForFade(
            () =>
                handler.snapshot.currentSongId == 'song-2' &&
                !handler.snapshot.isLoading,
          );

          expect(handler.snapshot.currentSongId, 'song-2');
        },
      );

      test('Previous loads the offset song from its start', () async {
        final (handler, incoming) = await swapped();
        incoming.simulatedPosition = const Duration(seconds: 1);
        await handler.skipToPrevious();
        await waitForFade(
          () =>
              !handler.snapshot.isLoading &&
              handler.snapshot.currentSongId == 'song-0' &&
              handler.collectPlaybackDiagnostics()['positionOffsetMs'] == 0,
        );
        expect(handler.queue.value[0].extras!['positionOffsetMs'], 0);
        final source = incoming.sequence[0] as UriAudioSource;
        expect(source.positionOffset, Duration.zero);
        expect(source.uri.queryParameters, isNot(contains('timeOffset')));
        expect(incoming.position, lessThan(const Duration(seconds: 5)));
      });
    });

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

    test('a slow prewarm shortens the ramp to end by the song end', () async {
      final (handler, player, _) = await crossfading(2);
      await handler.replaceQueue(ids(2), expandMatchFlows: false);
      final incoming = handler.debugInactiveDeck! as _ControllableAudioPlayer;
      final entered = Completer<void>();
      final release = Completer<void>();
      incoming
        ..loadGate = release
        ..loadEntered = entered;
      // 2 s before the end of a 3 min song: the 5 s fade cannot fit.
      player
        ..simulateProgress = true
        ..simulatedPosition =
            const Duration(minutes: 3) - const Duration(seconds: 2);
      handler.debugCheckCrossfadeTrigger(player.position);
      await entered.future.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      release.complete();
      await waitForFade(
        () =>
            identical(handler.debugActivePlayer, incoming) &&
            fade(handler)['active'] == false,
      );
      expect(
        player.position,
        lessThanOrEqualTo(const Duration(minutes: 3)),
        reason: 'the ramp must end before the outgoing song does',
      );
      expect(incoming.playing, isTrue);
    });

    test('with under half a second left the song advances gaplessly', () async {
      final (handler, player, _) = await crossfading(2);
      await handler.replaceQueue(ids(2), expandMatchFlows: false);
      final incoming = handler.debugInactiveDeck! as _ControllableAudioPlayer;
      player.simulatedPosition =
          const Duration(minutes: 3) - const Duration(milliseconds: 300);
      handler.debugCheckCrossfadeTrigger(player.position);
      await waitForFade(() => fade(handler)['active'] == false);
      expect(handler.debugActivePlayer, same(player));
      expect(incoming.playing, isFalse);
      expect(fade(handler)['phases'], containsPair('too_late', 1));
      // No retry loop for this occurrence.
      handler.debugCheckCrossfadeTrigger(player.position);
      expect(fade(handler)['active'], isFalse);
    });

    test(
      'the outgoing deck advancing mid-fade does not drive the display',
      () async {
        final (handler, player, _) = await crossfading(3);
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        final incoming = handler.debugInactiveDeck! as _ControllableAudioPlayer;
        final shown = <(String?, bool)>[];
        final sub = handler.snapshotStream.listen(
          (s) => shown.add((
            s.currentSongId,
            identical(handler.debugActivePlayer, player),
          )),
        );
        addTearDown(sub.cancel);
        player.simulatedPosition =
            const Duration(minutes: 3) - const Duration(seconds: 6);
        handler.debugCheckCrossfadeTrigger(player.position);
        await waitForFade(() => incoming.playing && incoming.volume > 0);
        expect(handler.currentMediaItem?.id, 'song-0');
        // The outgoing deck runs out and gapless-advances into song 1.
        player.finishCurrentTrack();
        await pumpEventQueue();
        expect(
          shown,
          isNot(contains(('song-1', true))),
          reason: 'the outgoing deck must not publish the next song',
        );
        await waitForFade(
          () =>
              identical(handler.debugActivePlayer, incoming) &&
              fade(handler)['active'] == false,
        );
        expect(handler.currentMediaItem?.id, 'song-1');
        expect(handler.snapshot.currentIndex, 1);
        expect(player.playing, isFalse, reason: 'no second copy of song 1');
        expect(incoming.playing, isTrue);
      },
    );

    group('an incoming song too short for the ramp', () {
      // The outgoing song has 6 s left, so the ramp is the full 5 s.
      Future<
        (NavisAudioHandler, _ControllableAudioPlayer, _ControllableAudioPlayer)
      >
      shortIncoming(Duration duration) async {
        final (handler, player, _) = await crossfading(3);
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        final incoming = handler.debugInactiveDeck! as _ControllableAudioPlayer;
        incoming.simulatedDuration = duration;
        player.simulatedPosition =
            const Duration(minutes: 3) - const Duration(seconds: 6);
        handler.debugCheckCrossfadeTrigger(player.position);
        return (handler, player, incoming);
      }

      test('below ramp plus margin advances gaplessly', () async {
        final (handler, player, incoming) = await shortIncoming(
          const Duration(milliseconds: 5099),
        );
        await waitForFade(() => fade(handler)['active'] == false);
        expect(handler.debugActivePlayer, same(player));
        expect(incoming.playing, isFalse);
        expect(fade(handler)['phases'], containsPair('too_late', 1));
      });

      test('exactly ramp plus margin still crossfades', () async {
        final (handler, player, incoming) = await shortIncoming(
          const Duration(milliseconds: 5100),
        );
        await waitForFade(() => incoming.playing && incoming.volume > 0);
        expect(fade(handler)['active'], isTrue);
        expect(fade(handler)['phases'], isNot(contains('too_late')));
        await handler.debugCompleteCrossfade();
        expect(handler.debugActivePlayer, same(incoming));
        expect(player.playing, isFalse);
      });

      test('an unknown incoming duration keeps the full ramp', () async {
        final (handler, _, incoming) = await shortIncoming(Duration.zero);
        await waitForFade(() => incoming.playing && incoming.volume > 0);
        expect(fade(handler)['phases'], isNot(contains('too_late')));
        await handler.debugCompleteCrossfade();
        expect(handler.debugActivePlayer, same(incoming));
      });
    });

    group('the outgoing deck advancing mid-fade', () {
      final nearEnd = const Duration(minutes: 3) - const Duration(seconds: 6);

      Future<
        (
          NavisAudioHandler,
          _ControllableAudioPlayer,
          _ControllableAudioPlayer,
          NavisDatabase,
        )
      >
      midFade({bool positionStreams = false, int startIndex = 0}) async {
        final (handler, player, database) = await crossfading(
          3,
          positionStreams: positionStreams,
        );
        await handler.replaceQueue(
          ids(3),
          startIndex: startIndex,
          expandMatchFlows: false,
        );
        final incoming = handler.debugInactiveDeck! as _ControllableAudioPlayer;
        player.simulatedPosition = nearEnd;
        handler.debugCheckCrossfadeTrigger(player.position);
        await waitForFade(() => incoming.playing && incoming.volume > 0.2);
        return (handler, player, incoming, database);
      }

      test('keeps the saved and shown position on the outgoing song', () async {
        final (handler, player, incoming, database) = await midFade();
        final hold = Completer<void>();
        // A slow native write keeps the hand-over open: the widest window.
        incoming.volumeHold = hold;
        player.finishCurrentTrack();
        await pumpEventQueue();
        expect(identical(handler.debugActivePlayer, player), isTrue);
        expect(handler.snapshot.currentSongId, 'song-0');
        expect(
          handler.snapshot.position,
          greaterThan(const Duration(minutes: 2)),
          reason: 'song-0 must not be shown at the next song\'s ~0',
        );
        await handler.debugFlushQueuePersistence();
        final saved = (await database.playQueueDao.getQueueState())!;
        expect(saved.currentIndex, 0);
        expect(saved.positionMs, greaterThan(120000));
        hold.complete();
        await waitForFade(
          () =>
              identical(handler.debugActivePlayer, incoming) &&
              fade(handler)['active'] == false,
        );
      });

      test('mutes the outgoing deck before any hand-over await', () async {
        final (handler, player, incoming, _) = await midFade();
        final hold = Completer<void>();
        incoming.volumeHold = hold;
        player.finishCurrentTrack();
        await pumpEventQueue();
        expect(player.volume, 0, reason: 'no second copy of song-1');
        hold.complete();
        await waitForFade(
          () =>
              identical(handler.debugActivePlayer, incoming) &&
              fade(handler)['active'] == false,
        );
      });

      test('the position stream never shows the next song at 0', () async {
        final (handler, player, incoming, _) = await midFade(
          positionStreams: true,
        );
        final seen = <Duration>[];
        final sub = handler.positionStream.listen(seen.add);
        addTearDown(sub.cancel);
        final hold = Completer<void>();
        incoming.volumeHold = hold;
        player.finishCurrentTrack();
        await pumpEventQueue();
        seen.clear();
        for (var i = 0; i < 3; i++) {
          player.emitPlayerEvent();
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        expect(identical(handler.debugActivePlayer, player), isTrue);
        expect(seen, isNotEmpty);
        expect(
          seen.every((p) => p > const Duration(minutes: 2)),
          isTrue,
          reason: 'saw $seen',
        );
        hold.complete();
        await waitForFade(
          () =>
              identical(handler.debugActivePlayer, incoming) &&
              fade(handler)['active'] == false,
        );
      });

      test(
        'a volume change inside the hand-over keeps the outgoing mute',
        () async {
          final (handler, player, incoming, _) = await midFade();
          final hold = Completer<void>();
          incoming.volumeHold = hold;
          player.finishCurrentTrack();
          await pumpEventQueue();
          unawaited(handler.setVolume(0.8));
          await pumpEventQueue();
          expect(player.volume, 0, reason: 'song-1 must not come back');
          hold.complete();
          await waitForFade(
            () =>
                identical(handler.debugActivePlayer, incoming) &&
                fade(handler)['active'] == false,
          );
          expect(incoming.volume, closeTo(0.8, 0.001));
        },
      );

      test(
        'previous inside the hand-over restarts the outgoing song',
        () async {
          final (handler, player, incoming, _) = await midFade(startIndex: 1);
          final hold = Completer<void>();
          incoming.volumeHold = hold;
          player.finishCurrentTrack();
          await pumpEventQueue();
          await handler.skipToPrevious();
          await pumpEventQueue();
          expect(handler.snapshot.currentSongId, 'song-1');
          expect(player.index, 1, reason: 'a restart, not the previous song');
          hold.complete();
          await pumpEventQueue();
        },
      );

      test('a volume change follows the shortened ramp', () async {
        final (handler, player, _) = await crossfading(2);
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        final incoming = handler.debugInactiveDeck! as _ControllableAudioPlayer;
        // 2 s left: the 5 s fade shortens to about 1.9 s.
        player
          ..simulateProgress = true
          ..simulatedPosition =
              const Duration(minutes: 3) - const Duration(seconds: 2);
        handler.debugCheckCrossfadeTrigger(player.position);
        await waitForFade(() => incoming.playing && incoming.volume > 0.5);
        await handler.setVolume(1);
        expect(player.volume, lessThan(0.55));
        expect(incoming.volume, greaterThan(0.45));
      });
    });

    test(
      'an outgoing advance with the incoming deck unready falls back',
      () async {
        final (handler, player, _) = await crossfading(3);
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        final incoming = handler.debugInactiveDeck! as _ControllableAudioPlayer;
        incoming.ignorePlay = true;
        player.simulatedPosition =
            const Duration(minutes: 3) - const Duration(seconds: 6);
        handler.debugCheckCrossfadeTrigger(player.position);
        await waitForFade(() => incoming.playRequested);
        player.finishCurrentTrack();
        await waitForFade(() => fade(handler)['active'] == false);
        await pumpEventQueue();
        // The suppressed index event is replayed when the fade is abandoned.
        expect(handler.debugActivePlayer, same(player));
        expect(handler.currentMediaItem?.id, 'song-1');
        expect(handler.snapshot.currentIndex, 1);
        expect(player.playing, isTrue);
      },
    );

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

  group('progress-aware playback deadlines', () {
    // Scaled load, fixed desktop settlement and mobile/load progress budgets.
    const deadlines = NavisPlaybackTimeouts(
      load: Duration(milliseconds: 300),
      seekBufferingRecovery: Duration(milliseconds: 150),
      seekProgress: Duration(milliseconds: 1200),
      desktopSeekSettle: Duration(milliseconds: 600),
      // Keep the scaled idle window above the 250 ms load-check cadence.
      progressIdle: Duration(milliseconds: 300),
    );

    Future<
      (
        NavisAudioHandler,
        _ControllableAudioPlayer,
        void Function({required bool growing, bool bufferProgress}),
      )
    >
    fixture({
      NavisPlaybackTimeouts timeouts = deadlines,
      List<_ControllableAudioPlayer>? rebuiltPlayers,
      Set<String>? hungLoadSongs,
      bool transcode = false,
      bool positionStreams = false,
      int count = 2,
      NavisQueueWindow queueWindow = const NavisQueueWindow(),
    }) async {
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final release = Completer<void>();
      var receiving = false;
      final transfers = <Future<void>>[];
      server.listen((request) {
        transfers.add(() async {
          Timer? fill;
          try {
            request.response
              ..bufferOutput = false
              ..headers.contentType = ContentType('audio', 'flac')
              ..contentLength = 1000000;
            fill = Timer.periodic(const Duration(milliseconds: 40), (_) {
              if (receiving) request.response.add(List<int>.filled(100, 1));
            });
            await release.future;
          } on HttpException {
            // Teardown cancels the incomplete sidecar.
          } finally {
            fill?.cancel();
          }
        }());
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
        'navis-progress-',
      );
      final (handler, player, database) = await createHandler(
        directory,
        count,
        positionStreams: positionStreams,
        queueWindow: queueWindow,
        sidecarStreams: true,
        streamingQuality: transcode
            ? const StreamingQuality(
                label: 'opus',
                format: 'opus',
                maxBitRate: 128,
              )
            : const StreamingQuality(label: 'original'),
        supportsTranscodeOffset: transcode,
        readApiClient: () => api,
        rebuiltPlayers: rebuiltPlayers ?? <_ControllableAudioPlayer>[],
        hungLoadSongs: hungLoadSongs,
        timeouts: timeouts,
      );
      addTearDown(() async {
        release.complete();
        await handler.disposeHandler();
        await server.close(force: true);
        await Future.wait(transfers);
        await database.close();
        await directory.delete(recursive: true);
        HttpOverrides.global = previousHttp;
      });
      player.simulateProgress = true;
      var bufferGrowing = false;
      final buffer = Timer.periodic(const Duration(milliseconds: 40), (_) {
        if (bufferGrowing) {
          player.simulatedBuffered += const Duration(milliseconds: 100);
        }
      });
      addTearDown(buffer.cancel);
      return (
        handler,
        player,
        ({required bool growing, bool bufferProgress = false}) {
          receiving = growing;
          bufferGrowing = growing && bufferProgress;
        },
      );
    }

    test(
      'desktop buffering probes both obey the fixed settlement deadline',
      () async {
        final (handler, player, grow) = await fixture();
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        grow(growing: true);
        player
          ..state = ProcessingState.buffering
          ..ignoreSeeks = true
          ..ignoreInitialPosition = true
          ..bufferAfterLoad = true
          ..nativePositionFrozen = true;
        final seeking = handler.seek(const Duration(seconds: 90));
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(
          (handler.collectPlaybackDiagnostics()['seek']!
              as Map)['recoveryAttempts'],
          0,
        );
        await seeking;
        await settleQueue(handler);
        await pumpEventQueue();
        final seek = handler.collectPlaybackDiagnostics()['seek']! as Map;
        expect(seek['recoveryAttempts'], 1);
        expect(seek['outcome'], 'failed');
        final event =
            (handler.collectPlaybackDiagnostics()['seekEvents']! as List).last
                as Map;
        final probes = event['unsettled']! as List;
        expect(probes, hasLength(2));
        for (final entry in probes) {
          final probe = entry as Map;
          expect(probe['reason'], 'deadline');
          expect(probe['elapsedMs'], inInclusiveRange(600, 1000));
          expect(probe['processingState'], 'buffering');
          expect(probe['positionMs'], isA<int>());
          expect(probe['bufferedMs'], isA<int>());
          expect(probe['playing'], isTrue);
          expect(probe.containsKey('inputBytesPerSecond'), isFalse);
          expect(probe.containsKey('inputExtensionActive'), isFalse);
        }
      },
    );

    for (final flapping in [false, true]) {
      test('buffering seek with frozen decoded buffer '
          'can settle after the load deadline (flapping $flapping)', () async {
        final (handler, player, grow) = await fixture();
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        grow(growing: true);
        player
          ..state = ProcessingState.buffering
          ..ignoreSeeks = true
          ..nativePositionFrozen = true;
        final elapsed = Stopwatch()..start();
        final flap = Timer.periodic(const Duration(milliseconds: 40), (_) {
          if (flapping && elapsed.elapsedMilliseconds >= 200) {
            player.state = player.state == ProcessingState.ready
                ? ProcessingState.buffering
                : ProcessingState.ready;
          }
        });
        addTearDown(flap.cancel);
        final landed = Timer(const Duration(milliseconds: 325), () {
          flap.cancel();
          player
            ..simulatedPosition = const Duration(seconds: 90)
            ..nativePositionFrozen = false
            ..state = ProcessingState.ready;
        });
        addTearDown(landed.cancel);
        final loads = player.sourceLoads;
        final seeking = handler.seek(const Duration(seconds: 90));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(player.sourceLoads, loads);
        expect(player.bufferedPosition, Duration.zero);
        expect(player.playbackEvent.updatePosition, Duration.zero);
        await seeking;
        final seek = handler.collectPlaybackDiagnostics()['seek']! as Map;
        expect(seek['recoveryAttempts'], 0);
        expect(seek['outcome'], 'completed');
        expect(player.sourceLoads, loads);
        expect(
          handler.collectPlaybackDiagnostics()['partialCacheBytes'],
          greaterThan(0),
        );
      });
    }

    for (final near in [true, false]) {
      test('ready frozen seek retains short stall checks after buffering '
          '(near target $near)', () async {
        final (handler, player, grow) = await fixture();
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        grow(growing: true);
        player
          ..state = ProcessingState.buffering
          ..ignoreSeeks = true
          ..nativePositionFrozen = true;
        final ready = Timer(Duration(milliseconds: near ? 350 : 100), () {
          player
            ..state = ProcessingState.ready
            ..simulatedPosition = near
                ? const Duration(seconds: 90)
                : Duration.zero;
        });
        addTearDown(ready.cancel);
        await handler.seek(const Duration(seconds: 90));
        await settleQueue(handler);
        await pumpEventQueue();
        final events =
            handler.collectPlaybackDiagnostics()['seekEvents']! as List;
        final probe = ((events.last as Map)['unsettled']! as List).first as Map;
        expect(
          probe['reason'],
          near ? equals('no progress') : anyOf('no progress', 'missed target'),
        );
        expect(probe['elapsedMs'], lessThan(near ? 1100 : 600));
        expect(probe['processingState'], 'ready');
        expect(probe['playing'], isTrue);
      });
    }

    test(
      'a frozen landed seek finishes recovery before a later seek',
      () async {
        final (handler, player, grow) = await fixture();
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        grow(growing: true);
        player.nativePositionFrozen = true;
        final first = handler.seek(const Duration(seconds: 90));
        // Landing alone is not settlement; frozen ready must recover promptly.
        await Future<void>.delayed(const Duration(milliseconds: 600));
        player.nativePositionFrozen = false;
        final second = handler.seek(const Duration(seconds: 30));
        await Future.wait([first, second]);
        final events =
            handler.collectPlaybackDiagnostics()['seekEvents']! as List;
        expect((events[events.length - 2] as Map)['outcome'], 'failed');
        expect((events.last as Map)['outcome'], 'completed');
      },
    );

    test('desktop sidecar growth does not hide a ready frozen seek', () async {
      final (handler, player, grow) = await fixture();
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      grow(growing: true);
      player
        ..state = ProcessingState.ready
        ..ignoreSeeks = true
        ..nativePositionFrozen = true;
      final seeking = handler.seek(const Duration(seconds: 90));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final bytes = handler.collectPlaybackDiagnostics()['partialCacheBytes'];
      await seeking;
      await settleQueue(handler);
      await pumpEventQueue();
      final event =
          (handler.collectPlaybackDiagnostics()['seekEvents']! as List).last
              as Map;
      final probe = (event['unsettled']! as List).first as Map;
      expect(probe['reason'], 'missed target');
      expect(probe['elapsedMs'], lessThan(600));
      expect(bytes, greaterThan(0));
    });

    for (final rapid in [false, true]) {
      test(
        '${rapid ? 'rapid' : 'single'} same-song seek preserves a progressing cold start',
        () async {
          final (handler, player, grow) = await fixture();
          final gate = Completer<void>();
          final entered = Completer<void>();
          player
            ..loadGate = gate
            ..loadEntered = entered
            ..gateNonEmptyLoadsOnly = true;
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
          final failures = <PlaybackLoadFailure>[];
          final subscription = handler.loadFailureStream.listen(failures.add);
          addTearDown(subscription.cancel);
          grow(growing: true);
          final loading = handler.replaceQueue([
            'song-0',
            'song-1',
          ], expandMatchFlows: false);
          await entered.future;
          await Future<void>.delayed(const Duration(milliseconds: 400));
          final olderSeek = rapid
              ? handler.seek(const Duration(seconds: 30))
              : Future<void>.value();
          await Future<void>.delayed(const Duration(milliseconds: 30));
          final seeking = handler.seek(const Duration(seconds: 90));
          await Future<void>.delayed(const Duration(milliseconds: 350));
          final wasDisposed = player.disposed;
          gate.complete();
          await Future.wait([loading, olderSeek, seeking]);
          expect(wasDisposed, isFalse);
          expect(failures, isEmpty);
          final seek = handler.collectPlaybackDiagnostics()['seek']! as Map;
          expect(seek['outcome'], 'completed');
          expect(seek['recoveryAttempts'], 0);
          expect(handler.snapshot.currentSongId, 'song-0');
          expect(
            (player.position - const Duration(seconds: 90)).abs(),
            lessThan(const Duration(seconds: 1)),
          );
        },
      );
    }

    for (final holdMs in [1000, 2000]) {
      for (final transcode in [false, true]) {
        test(
          'cold seek hold $holdMs transcode $transcode retires sources and keeps the target alive',
          () async {
            final rebuilt = <_ControllableAudioPlayer>[];
            final (handler, player, _) = await fixture(
              rebuiltPlayers: rebuilt,
              transcode: transcode,
              timeouts: const NavisPlaybackTimeouts(
                load: Duration(milliseconds: 600),
                seekProgress: Duration(milliseconds: 2400),
              ),
            );
            final gate = Completer<void>();
            final entered = Completer<void>();
            player
              ..claimedSources = <AudioSource>{}
              ..replacementLoadGate = gate
              ..loadGate = gate
              ..loadEntered = entered
              ..gateNonEmptyLoadsOnly = true;
            addTearDown(() {
              if (!gate.isCompleted) gate.complete();
            });
            final failures = <PlaybackLoadFailure>[];
            final notices = handler.loadFailureStream.listen(failures.add);
            addTearDown(notices.cancel);
            final loading = handler.replaceQueue([
              'song-0',
            ], expandMatchFlows: false);
            await entered.future;
            await Future<void>.delayed(const Duration(milliseconds: 250));
            final seeking = handler.seek(const Duration(seconds: 60));
            // The new player must keep waiting for this same body hold too.
            for (var i = 0; i < 200 && rebuilt.isEmpty; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
            expect(rebuilt, isNotEmpty);
            await Future<void>.delayed(Duration(milliseconds: holdMs - 750));
            final before = handler.collectPlaybackDiagnostics()['seek']! as Map;
            expect(before['outcome'], isNull);
            gate.complete();
            await Future.wait([loading, seeking]);
            final seek = handler.collectPlaybackDiagnostics()['seek']! as Map;
            expect(seek['outcome'], 'completed');
            expect(handler.snapshot.queueSongIds, ['song-0']);
            expect(handler.snapshot.currentSongId, 'song-0');
            expect(handler.snapshot.playing, isTrue);
            expect(
              handler.snapshot.processingState,
              AudioProcessingState.ready,
            );
            expect(rebuilt.last.playedFrom.first.inSeconds, 60);
            expect(failures, isEmpty);
            expect(rebuilt.single.sourceLoads, 1);
            if (transcode) {
              final event =
                  (handler.collectPlaybackDiagnostics()['seekEvents']! as List)
                          .last
                      as Map;
              expect(event['path'], 'transcodeOffset');
              expect(
                (rebuilt.single.sequence.single as UriAudioSource)
                    .positionOffset,
                const Duration(seconds: 60),
              );
            }
          },
        );
      }
    }

    for (final retryFails in [false, true]) {
      for (final onlySong in [false, true]) {
        test(
          'failed cold load onlySong $onlySong ${retryFails ? 'exhausts retry' : 'retries at the target'}',
          () async {
            final rebuilt = <_ControllableAudioPlayer>[];
            final hungSongs = <String>{};
            final (handler, player, _) = await fixture(
              rebuiltPlayers: rebuilt,
              hungLoadSongs: hungSongs,
            );
            final gate = Completer<void>();
            final entered = Completer<void>();
            player
              ..loadGate = gate
              ..loadEntered = entered
              ..gateNonEmptyLoadsOnly = true;
            addTearDown(() {
              if (!gate.isCompleted) gate.complete();
            });
            final loading = handler.replaceQueue([
              'song-0',
              if (!onlySong) 'song-1',
            ], expandMatchFlows: false);
            await entered.future;
            if (retryFails) hungSongs.add('song-0');
            final seeking = handler.seek(const Duration(seconds: 90));
            await Future.wait([loading, seeking]);
            if (retryFails && onlySong) {
              await pumpEventQueue();
              expect(handler.debugQueueLaneIdle, isTrue);
              expect(handler.snapshot.isLoading, isFalse);
            } else {
              await settleQueue(handler);
            }
            expect(player.disposed, isTrue);
            expect(rebuilt, hasLength(retryFails ? 2 : 1));
            expect(
              handler.snapshot.currentSongId,
              retryFails && !onlySong ? 'song-1' : 'song-0',
            );
            expect(handler.snapshot.queueSongIds, [
              'song-0',
              if (!onlySong) 'song-1',
            ]);
            expect(rebuilt.last.playing, !(retryFails && onlySong));
            expect(
              rebuilt.last.processingState,
              retryFails && onlySong
                  ? ProcessingState.idle
                  : ProcessingState.ready,
            );
            if (retryFails && onlySong) {
              hungSongs.clear();
              await handler.play();
              await settleQueue(handler);
              expect(handler.snapshot.currentSongId, 'song-0');
              expect(rebuilt.last.playing, isTrue);
              expect(rebuilt.last.processingState, ProcessingState.ready);
            }
            if (!retryFails) {
              expect(rebuilt.last.playedFrom, isNotEmpty);
              expect(
                (rebuilt.last.playedFrom.first - const Duration(seconds: 90))
                    .abs(),
                lessThan(const Duration(seconds: 1)),
              );
              final seek = handler.collectPlaybackDiagnostics()['seek']! as Map;
              expect(seek['outcome'], 'completed');
              expect(seek['recoveryAttempts'], 1);
            }
          },
        );
      }
    }

    for (final processing in [
      ProcessingState.ready,
      ProcessingState.buffering,
    ]) {
      test(
        'exhausted ${processing.name} seek stops quietly and Play reloads the only song',
        () async {
          final (handler, player, _) = await fixture();
          await handler.replaceQueue(['song-0'], expandMatchFlows: false);
          final failures = <PlaybackLoadFailure>[];
          final notices = handler.loadFailureStream.listen(failures.add);
          addTearDown(notices.cancel);
          player
            ..state = processing
            ..bufferAfterLoad = processing == ProcessingState.buffering
            ..nativePositionFrozen = true;
          await handler.seek(const Duration(seconds: 60));
          expect(
            (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
            'failed',
          );
          expect(handler.snapshot.queueSongIds, ['song-0']);
          expect(handler.snapshot.playing, isFalse);
          expect(player.processingState, ProcessingState.idle);
          expect(failures, isEmpty);
          player
            ..bufferAfterLoad = false
            ..nativePositionFrozen = false;
          final loads = player.sourceLoads;
          await handler.play();
          await settleQueue(handler);
          expect(player.sourceLoads, greaterThan(loads));
          expect(handler.snapshot.currentSongId, 'song-0');
          expect(handler.snapshot.playing, isTrue);
          expect(player.processingState, ProcessingState.ready);
        },
      );
    }

    // Round 10: bounded failover. Scaled deadlines; a short reset window and
    // healthy-play window keep the cascades quick.
    const quick = NavisPlaybackTimeouts(
      load: Duration(milliseconds: 300),
      seekBufferingRecovery: Duration(milliseconds: 400),
      seekProgress: Duration(milliseconds: 1200),
      desktopSeekSettle: Duration(milliseconds: 600),
      progressIdle: Duration(milliseconds: 300),
      reset: Duration(milliseconds: 300),
      healthyPlayback: Duration(milliseconds: 400),
    );

    Future<void> idle(NavisAudioHandler handler) async {
      var quiet = 0;
      for (var i = 0; i < 600 && quiet < 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        quiet = !handler.snapshot.isLoading && handler.debugQueueLaneIdle
            ? quiet + 1
            : 0;
      }
      expect(quiet, 4, reason: 'handler did not go idle');
    }

    List<String> songIds(int count) =>
        List<String>.generate(count, (i) => 'song-$i');

    for (final halt in ['pause', 'stop', 'timed-out stop']) {
      for (final pauseAgain in [false, true]) {
        test(
          'row 01 Play during final $halt honors latest intent (later Pause: $pauseAgain)',
          () async {
            final rebuilt = <_ControllableAudioPlayer>[];
            final (handler, player, _) = await fixture(
              timeouts: quick,
              rebuiltPlayers: rebuilt,
            );
            await handler.replaceQueue(['song-0'], expandMatchFlows: false);
            final release = Completer<void>();
            final entered = Completer<void>();
            addTearDown(() {
              if (!release.isCompleted) release.complete();
            });
            player.nativePositionFrozen = true;
            if (halt == 'pause') {
              player
                ..pauseGate = release
                ..pauseEntered = entered
                ..pauseGateWhen = () =>
                    (handler.collectPlaybackDiagnostics()['seek']!
                        as Map)['outcome'] ==
                    'failed';
            } else {
              player
                ..stopGate = release
                ..stopEntered = entered
                ..stopGateFrom = player.stopCalls + 2;
            }
            final seeking = handler.seek(const Duration(seconds: 60));
            await entered.future.timeout(const Duration(seconds: 6));
            player
              ..nativePositionFrozen = false
              ..ignoreSeeks = false;
            await handler.play();
            if (pauseAgain) await handler.pause();
            if (halt != 'timed-out stop') release.complete();
            await seeking.timeout(const Duration(seconds: 8));
            await idle(handler);
            if (!release.isCompleted) release.complete();
            await pumpEventQueue(times: 30);
            await idle(handler);
            final active =
                handler.debugActivePlayer as _ControllableAudioPlayer;
            expect(handler.snapshot.currentSongId, 'song-0');
            expect(
              handler.snapshot.playing,
              !pauseAgain,
              reason: 'row 01: final halt must honor the latest intent',
            );
            if (!pauseAgain) {
              expect(active.processingState, ProcessingState.ready);
              final position = active.position;
              await Future<void>.delayed(const Duration(milliseconds: 80));
              expect(active.position, greaterThan(position));
            }
            if (halt == 'timed-out stop') {
              expect(active, isNot(same(player)));
            }
          },
        );
      }
    }

    test(
      'row 01 a newer queue plays while an older final Pause settles',
      () async {
        final (handler, player, _) = await fixture(timeouts: quick);
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        final release = Completer<void>();
        final entered = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        player
          ..nativePositionFrozen = true
          ..pauseGate = release
          ..pauseEntered = entered
          ..pauseGateWhen = () =>
              (handler.collectPlaybackDiagnostics()['seek']!
                  as Map)['outcome'] ==
              'failed';
        final seeking = handler.seek(const Duration(seconds: 60));
        await entered.future.timeout(const Duration(seconds: 6));
        player.nativePositionFrozen = false;
        await handler.replaceQueue(['song-1'], expandMatchFlows: false);
        release.complete();
        await seeking;
        await idle(handler);
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(
          player.playing,
          isTrue,
          reason: 'an older halt must not hold a newer source paused',
        );
        expect(player.processingState, ProcessingState.ready);
      },
    );

    for (final intent in ['seek', 'Play', 'Pause']) {
      test('row 01 newer seek during final Stop honors $intent', () async {
        final (handler, player, _) = await fixture(timeouts: quick);
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        final release = Completer<void>();
        final entered = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        player
          ..nativePositionFrozen = true
          ..stopGate = release
          ..stopEntered = entered
          ..stopGateFrom = player.stopCalls + 2;
        final older = handler.seek(const Duration(seconds: 60));
        await entered.future.timeout(const Duration(seconds: 6));
        player
          ..nativePositionFrozen = false
          ..ignoreSeeks = false;
        final newer = handler.seek(const Duration(seconds: 130));
        if (intent == 'Play') await handler.play();
        if (intent == 'Pause') await handler.pause();
        release.complete();
        await Future.wait([older, newer]).timeout(const Duration(seconds: 8));
        await idle(handler);
        final active = handler.debugActivePlayer as _ControllableAudioPlayer;
        expect(
          (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
          'completed',
        );
        expect(active.position.inSeconds, greaterThanOrEqualTo(130));
        expect(active.playing, intent != 'Pause');
        expectNativeMirrorsQueue(handler, active);
      });
    }

    test('a hung final stop never parks the seek lane', () async {
      final (handler, player, _) = await fixture(timeouts: quick);
      await handler.replaceQueue(['song-0'], expandMatchFlows: false);
      player
        ..state = ProcessingState.ready
        ..nativePositionFrozen = true
        // Seek recovery stops twice; the third stop is the final quiet one.
        ..hangStopsFrom = 3;
      await handler
          .seek(const Duration(seconds: 60))
          .timeout(const Duration(seconds: 8));
      expect(
        (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
        'failed',
      );
      await handler
          .seek(const Duration(seconds: 30))
          .timeout(const Duration(seconds: 8));
      expect(handler.snapshot.currentSongId, 'song-0');
    });

    test(
      'a failed seek on a song that keeps playing does not skip it',
      () async {
        final (handler, player, _) = await fixture(
          timeouts: quick,
          positionStreams: true,
        );
        await handler.replaceQueue(songIds(2), expandMatchFlows: false);
        final failures = <PlaybackLoadFailure>[];
        final notices = handler.loadFailureStream.listen(failures.add);
        addTearDown(notices.cancel);
        // Seeks never land and reloads restart the song, which plays on.
        player
          ..ignoreSeeks = true
          ..ignoreInitialPosition = true;
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await handler.seek(const Duration(seconds: 90));
        await idle(handler);
        expect(
          (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
          'failed',
        );
        expect(handler.snapshot.currentSongId, 'song-0');
        expect(handler.snapshot.playing, isTrue);
        expect(failures, isEmpty);
      },
    );

    test('a dead source still fails over after a failed seek', () async {
      final (handler, player, _) = await fixture(
        timeouts: quick,
        positionStreams: true,
      );
      await handler.replaceQueue(songIds(2), expandMatchFlows: false);
      player
        ..ignoreSeeks = true
        ..simulateProgress = false
        ..nativePositionFrozen = true;
      // Long enough for the last advance to age out.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await handler.seek(const Duration(seconds: 90));
      await idle(handler);
      expect(handler.snapshot.currentSongId, 'song-1');
    });

    test('automatic failover stops quietly after two skipped songs', () async {
      final rebuilt = <_ControllableAudioPlayer>[];
      final hung = <String>{for (var i = 0; i < 5; i++) 'song-$i'};
      final (handler, _, _) = await fixture(
        timeouts: quick,
        count: 6,
        rebuiltPlayers: rebuilt,
        hungLoadSongs: hung,
      );
      final failures = <PlaybackLoadFailure>[];
      final notices = handler.loadFailureStream.listen(failures.add);
      addTearDown(notices.cancel);
      await handler.replaceQueue(songIds(6), expandMatchFlows: false);
      await idle(handler);
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(handler.snapshot.queueSongIds, songIds(6));
      expect(handler.snapshot.playing, isFalse);
      expect(failures, isEmpty);
      hung.clear();
      await handler.play();
      await idle(handler);
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(handler.snapshot.playing, isTrue);
      expect(rebuilt.last.processingState, ProcessingState.ready);
    });

    for (final command in ['playFromIndex', 'skipToNext', 'replaceQueue']) {
      test('$command after a cap stop gets automatic failover again', () async {
        final rebuilt = <_ControllableAudioPlayer>[];
        // Songs 0-2 hit the cap; the user's pick then fails and is skipped.
        final hung = <String>{
          for (final i in [0, 1, 2, if (command == 'skipToNext') 3 else 4])
            'song-$i',
        };
        final (handler, _, _) = await fixture(
          timeouts: quick,
          count: 8,
          rebuiltPlayers: rebuilt,
          hungLoadSongs: hung,
        );
        await handler.replaceQueue(songIds(8), expandMatchFlows: false);
        await idle(handler);
        expect(handler.snapshot.currentSongId, 'song-2');
        switch (command) {
          case 'playFromIndex':
            await handler.playFromIndex(4);
          case 'skipToNext':
            await handler.skipToNext();
          default:
            await handler.replaceQueue(
              songIds(8),
              startIndex: 4,
              expandMatchFlows: false,
            );
        }
        await idle(handler);
        expect(
          handler.snapshot.currentSongId,
          command == 'skipToNext' ? 'song-4' : 'song-5',
        );
        expect(handler.snapshot.playing, isTrue);
      });
    }

    test('a cap stop in a windowed queue releases no tail into it', () async {
      final rebuilt = <_ControllableAudioPlayer>[];
      final hung = <String>{'song-0', 'song-1', 'song-2'};
      final (handler, _, _) = await fixture(
        timeouts: quick,
        count: 14,
        rebuiltPlayers: rebuilt,
        hungLoadSongs: hung,
        queueWindow: const NavisQueueWindow(
          deferThreshold: 12,
          ahead: 3,
          lowWater: 2,
          page: 3,
          nearJump: 5,
          behind: 3,
          trimSlack: 1,
        ),
      );
      await handler.replaceQueue(songIds(14), expandMatchFlows: false);
      await idle(handler);
      // Let a background tail release run if one is going to.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await idle(handler);
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(handler.snapshot.currentIndex, 2);
      expect(handler.snapshot.queueSongIds, songIds(14));
      expect(rebuilt.last.sourceIds, isEmpty);
      hung.clear();
      await handler.play();
      await idle(handler);
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(handler.snapshot.currentIndex, 2);
      expect(handler.snapshot.playing, isTrue);
    });

    test(
      'a song that played healthily and ends early is not a failure',
      () async {
        final (handler, _, _) = await fixture(
          timeouts: quick,
          count: 8,
          positionStreams: true,
        );
        await handler.replaceQueue(songIds(8), expandMatchFlows: false);
        Future<void> complete(Duration at) async {
          final active = handler.debugActivePlayer as _ControllableAudioPlayer;
          active
            ..state = ProcessingState.completed
            ..simulatedPosition = at
            .._events.add(active.playbackEvent);
          await idle(handler);
        }

        // Song 0 plays past healthyPlayback, then ends 30 s short of its
        // (overstated) duration: a normal completion, not counted.
        await Future<void>.delayed(const Duration(milliseconds: 900));
        await complete(const Duration(minutes: 2, seconds: 30));
        expect(handler.snapshot.currentSongId, 'song-1');
        // Songs 1 and 2 never play: two counted failures, then the cap on 3.
        await complete(Duration.zero);
        expect(handler.snapshot.currentSongId, 'song-2');
        await complete(Duration.zero);
        expect(handler.snapshot.currentSongId, 'song-3');
        expect(handler.snapshot.playing, isTrue);
        await complete(Duration.zero);
        expect(handler.snapshot.currentSongId, 'song-3');
        expect(handler.snapshot.playing, isFalse);
      },
    );

    for (final command in ['skipToNext', 'playFromIndex', 'replaceQueue']) {
      test(
        '$command from a healthy song starts the next one unplayed',
        () async {
          final (handler, _, _) = await fixture(
            timeouts: quick,
            count: 8,
            positionStreams: true,
          );
          await handler.replaceQueue(songIds(8), expandMatchFlows: false);
          await Future<void>.delayed(const Duration(milliseconds: 900));
          expect(
            handler.debugPlayedSinceFailover,
            greaterThan(quick.healthyPlayback),
          );
          // At once, before any position tick of the new song can reset it.
          final selecting = switch (command) {
            'skipToNext' => handler.skipToNext(),
            'playFromIndex' => handler.playFromIndex(3),
            _ => handler.replaceQueue(songIds(8), expandMatchFlows: false),
          };
          expect(handler.debugPlayedSinceFailover, Duration.zero);
          await selecting;
        },
      );
    }

    test('the same song twice in a row is a new occurrence', () async {
      final (handler, player, _) = await fixture(
        timeouts: quick,
        count: 8,
        positionStreams: true,
      );
      await handler.replaceQueue([
        'song-0',
        'song-0',
        'song-1',
      ], expandMatchFlows: false);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(
        handler.debugPlayedSinceFailover,
        greaterThan(quick.healthyPlayback),
      );
      player.finishCurrentTrack();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(handler.snapshot.currentIndex, 1);
      expect(handler.debugPlayedSinceFailover, lessThan(quick.healthyPlayback));
    });

    test('a ready backend with a frozen native position stays dead', () async {
      final (handler, player, _) = await fixture(
        timeouts: quick,
        positionStreams: true,
      );
      await handler.replaceQueue(songIds(2), expandMatchFlows: false);
      // The interpolated clock moves; the backend reports no position.
      player
        ..ignoreSeeks = true
        ..nativePositionFrozen = true;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await handler.seek(const Duration(seconds: 90));
      await idle(handler);
      expect(handler.snapshot.currentSongId, 'song-1');
    });

    test('a frozen native position never clears the failover count', () async {
      final (handler, player, _) = await fixture(
        timeouts: const NavisPlaybackTimeouts(
          load: Duration(milliseconds: 300),
          seekBufferingRecovery: Duration(milliseconds: 400),
          seekProgress: Duration(milliseconds: 1200),
          desktopSeekSettle: Duration(milliseconds: 600),
          progressIdle: Duration(milliseconds: 300),
          reset: Duration(milliseconds: 300),
          healthyPlayback: Duration(milliseconds: 800),
        ),
        count: 6,
        positionStreams: true,
      );
      await handler.replaceQueue(songIds(6), expandMatchFlows: false);
      Future<void> fail(String id) async {
        player
          ..failLoadSongId = id
          ..state = ProcessingState.buffering;
        await handler.debugRecoverCurrentSong();
        await idle(handler);
      }

      player.nativePositionFrozen = true;
      await fail('song-0');
      player
        ..failLoadSongId = null
        ..state = ProcessingState.ready;
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await fail('song-1');
      await fail('song-2');
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(handler.snapshot.playing, isFalse);
    });

    test('a hung final stop retires the player so Play reloads', () async {
      final rebuilt = <_ControllableAudioPlayer>[];
      final (handler, player, _) = await fixture(
        timeouts: quick,
        rebuiltPlayers: rebuilt,
      );
      await handler.replaceQueue(['song-0'], expandMatchFlows: false);
      player
        ..state = ProcessingState.ready
        ..nativePositionFrozen = true
        ..hangStopsFrom = 3;
      await handler
          .seek(const Duration(seconds: 60))
          .timeout(const Duration(seconds: 8));
      await idle(handler);
      expect(rebuilt, hasLength(1));
      await handler.play();
      await idle(handler);
      expect(handler.debugActivePlayer, same(rebuilt.last));
      expect(handler.snapshot.currentSongId, 'song-0');
      expect(handler.snapshot.playing, isTrue);
      expect(rebuilt.last.sourceIds, contains('song-0'));
      expect(rebuilt.last.processingState, ProcessingState.ready);
    });

    test('sources that complete at once advance at most twice', () async {
      final (handler, _, _) = await fixture(timeouts: quick, count: 8);
      await handler.replaceQueue(songIds(8), expandMatchFlows: false);
      final visited = <String?>[handler.snapshot.currentSongId];
      for (var i = 0; i < 6; i++) {
        // A server that sends headers and closes: the song ends at position 0.
        final active = handler.debugActivePlayer as _ControllableAudioPlayer;
        active
          ..state = ProcessingState.completed
          ..simulatedPosition = Duration.zero
          .._events.add(active.playbackEvent);
        await idle(handler);
        visited.add(handler.snapshot.currentSongId);
      }
      expect(visited.toSet(), {'song-0', 'song-1', 'song-2'});
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(handler.snapshot.playing, isFalse);
      expect(handler.snapshot.queueSongIds, songIds(8));
    });

    test('seek and stall failovers share one cap', () async {
      final (handler, player, _) = await fixture(timeouts: quick, count: 6);
      await handler.replaceQueue(songIds(6), expandMatchFlows: false);
      player
        ..ignoreSeeks = true
        ..simulateProgress = false
        ..nativePositionFrozen = true;
      await handler.seek(const Duration(seconds: 90));
      await idle(handler);
      expect(handler.snapshot.currentSongId, 'song-1');
      for (final id in ['song-1', 'song-2']) {
        // Each song fails again when reloaded, as a dead stream would.
        player
          ..failLoadSongId = id
          ..state = ProcessingState.buffering;
        await handler.debugRecoverCurrentSong();
        await idle(handler);
      }
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(handler.snapshot.queueSongIds, songIds(6));
      expect(handler.snapshot.playing, isFalse);
      player.failLoadSongId = null;
      await handler.play();
      await idle(handler);
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(handler.snapshot.playing, isTrue);
    });

    test('healthy playback restarts the failover count', () async {
      final rebuilt = <_ControllableAudioPlayer>[];
      final (handler, player, _) = await fixture(
        timeouts: const NavisPlaybackTimeouts(
          load: Duration(milliseconds: 300),
          seekBufferingRecovery: Duration(milliseconds: 400),
          seekProgress: Duration(milliseconds: 1200),
          desktopSeekSettle: Duration(milliseconds: 600),
          progressIdle: Duration(milliseconds: 300),
          reset: Duration(milliseconds: 300),
          healthyPlayback: Duration(milliseconds: 800),
        ),
        count: 6,
        rebuiltPlayers: rebuilt,
        positionStreams: true,
      );
      await handler.replaceQueue(songIds(6), expandMatchFlows: false);
      var current = player;
      Future<void> fail(String id) async {
        current
          ..failLoadSongId = id
          ..state = ProcessingState.buffering;
        await handler.debugRecoverCurrentSong();
        await idle(handler);
      }

      await fail('song-0');
      expect(handler.snapshot.currentSongId, 'song-1');
      // Song 1 plays long enough to count as healthy, which clears the count.
      current
        ..failLoadSongId = null
        ..state = ProcessingState.ready;
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await fail('song-1');
      expect(handler.snapshot.currentSongId, 'song-2');
      await fail('song-2');
      expect(handler.snapshot.currentSongId, 'song-3');
    });

    test(
      'a seek waiting on a load that ends in a quiet stop fails at once',
      () async {
        final hung = <String>{};
        final (handler, player, _) = await fixture(
          hungLoadSongs: hung,
          timeouts: const NavisPlaybackTimeouts(
            load: Duration(seconds: 2),
            seekBufferingRecovery: Duration(milliseconds: 150),
            seekProgress: Duration(seconds: 10),
            desktopSeekSettle: Duration(milliseconds: 600),
            progressIdle: Duration(milliseconds: 300),
            reset: Duration(milliseconds: 300),
          ),
        );
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..loadGate = gate
          ..loadEntered = entered
          ..gateNonEmptyLoadsOnly = true;
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final loading = handler.replaceQueue([
          'song-0',
        ], expandMatchFlows: false);
        await entered.future;
        hung.add('song-0');
        final seeking = handler.seek(const Duration(seconds: 90));
        await loading;
        final stopped = Stopwatch()..start();
        await seeking;
        expect(stopped.elapsedMilliseconds, lessThan(1000));
        expect(
          (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
          'failed',
        );
      },
    );

    test('a cold load cannot hold a seek past the seek progress cap', () async {
      final rebuilt = <_ControllableAudioPlayer>[];
      final (handler, player, _) = await fixture(
        rebuiltPlayers: rebuilt,
        timeouts: const NavisPlaybackTimeouts(
          load: Duration(milliseconds: 600),
          seekProgress: Duration(milliseconds: 1000),
          reset: Duration(milliseconds: 300),
        ),
      );
      final gate = Completer<void>();
      final entered = Completer<void>();
      player
        ..claimedSources = <AudioSource>{}
        ..replacementLoadGate = gate
        ..loadGate = gate
        ..loadEntered = entered
        ..gateNonEmptyLoadsOnly = true;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final loading = handler.replaceQueue(['song-0'], expandMatchFlows: false);
      await entered.future;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final seeking = handler.seek(const Duration(seconds: 60));
      await Future<void>.delayed(const Duration(milliseconds: 1800));
      expect(
        (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
        'failed',
      );
      gate.complete();
      await Future.wait([loading, seeking]);
    });

    test('a failover that already moved the queue is not repeated', () async {
      final rebuilt = <_ControllableAudioPlayer>[];
      final hungSongs = <String>{};
      final (handler, player, _) = await fixture(
        timeouts: quick,
        count: 3,
        rebuiltPlayers: rebuilt,
        hungLoadSongs: hungSongs,
      );
      final gate = Completer<void>();
      final entered = Completer<void>();
      player
        ..loadGate = gate
        ..loadEntered = entered
        ..gateNonEmptyLoadsOnly = true;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final loading = handler.replaceQueue(songIds(3), expandMatchFlows: false);
      await entered.future;
      hungSongs.add('song-0');
      final seeking = handler.seek(const Duration(seconds: 90));
      await Future.wait([loading, seeking]);
      await idle(handler);
      expect(handler.snapshot.currentSongId, 'song-1');
      expect(handler.snapshot.playing, isTrue);
    });

    test('sidecar bytes cannot extend a seek recovery load deadline', () async {
      final (handler, player, grow) = await fixture(
        timeouts: const NavisPlaybackTimeouts(
          load: Duration(milliseconds: 600),
          seekBufferingRecovery: Duration(milliseconds: 150),
          seekProgress: Duration(seconds: 3),
        ),
      );
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      final gate = Completer<void>();
      final entered = Completer<void>();
      player
        ..ignoreSeeks = true
        ..loadGate = gate
        ..loadEntered = entered
        ..gateNonEmptyLoadsOnly = true;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      grow(growing: true);
      final seeking = handler.seek(const Duration(seconds: 90));
      await entered.future;
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      final retiredAtDeadline = player.disposed;
      gate.complete();
      await seeking;
      await settleQueue(handler);
      expect(retiredAtDeadline, isTrue);
      expect(handler.snapshot.currentSongId, 'song-1');
      expect(handler.snapshot.queueSongIds, ['song-0', 'song-1']);
      expect(handler.snapshot.playing, isTrue);
      expect(handler.snapshot.processingState, AudioProcessingState.ready);
      expect(
        (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
        'failed',
      );
    });

    for (final command in ['next', 'stop']) {
      test(
        '$command aborts a seek recovery load within one check interval',
        () async {
          final (handler, player, grow) = await fixture(
            timeouts: const NavisPlaybackTimeouts(
              load: Duration(seconds: 2),
              seekBufferingRecovery: Duration(milliseconds: 150),
              desktopSeekSettle: Duration(milliseconds: 600),
            ),
          );
          await handler.replaceQueue([
            'song-0',
            'song-1',
          ], expandMatchFlows: false);
          final gate = Completer<void>();
          final entered = Completer<void>();
          player
            ..ignoreSeeks = true
            ..loadGate = gate
            ..loadEntered = entered
            ..gateNonEmptyLoadsOnly = true;
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
          grow(growing: true);
          final seeking = handler.seek(const Duration(seconds: 90));
          await entered.future;
          final control = command == 'next'
              ? handler.skipToNext()
              : handler.stop();
          await Future<void>.delayed(const Duration(milliseconds: 350));
          final retiredAtCheck = player.disposed;
          gate.complete();
          await Future.wait([seeking, control]);
          expect(retiredAtCheck, isTrue);
          expect(
            (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
            'superseded',
          );
          if (command == 'next') {
            expect(handler.snapshot.currentSongId, 'song-1');
          }
          if (command == 'stop') {
            expect(handler.snapshot.playing, isFalse);
          }
        },
      );
    }

    for (final command in ['next', 'stop']) {
      for (final extended in [false, true]) {
        test('$command aborts a ${extended ? 'extended' : 'new'} load '
            'within one check interval', () async {
          final (handler, player, grow) = await fixture();
          final gate = Completer<void>();
          final entered = Completer<void>();
          player
            ..loadGate = gate
            ..loadEntered = entered
            ..gateNonEmptyLoadsOnly = true;
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
          grow(growing: true, bufferProgress: true);
          final loading = handler.replaceQueue([
            'song-0',
            'song-1',
          ], expandMatchFlows: false);
          await entered.future;
          await Future<void>.delayed(
            Duration(milliseconds: extended ? 600 : 100),
          );
          expect(player.disposed, isFalse);
          final control = command == 'next'
              ? handler.skipToNext()
              : handler.stop();
          // One 250 ms check plus scheduling/rebuild slack; below the old
          // 500 ms check that first notices the scaled 300 ms deadline.
          await Future<void>.delayed(const Duration(milliseconds: 300));
          expect(player.disposed, isTrue);
          await Future.wait([loading, control]);
          if (command == 'stop') expect(handler.snapshot.playing, isFalse);
        });
      }
    }

    for (final growing in [true, false]) {
      test('start ${growing ? 'keeps downloading past' : 'still fails at'} '
          'the old load deadline', () async {
        final (handler, player, grow) = await fixture();
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..loadGate = gate
          ..loadEntered = entered
          ..gateNonEmptyLoadsOnly = true;
        grow(growing: growing);
        final failures = <Object>[];
        final loading = handler
            .replaceQueue(['song-0', 'song-1'], expandMatchFlows: false)
            .catchError(failures.add);
        await entered.future;
        final finish = Timer(const Duration(milliseconds: 700), gate.complete);
        addTearDown(() {
          finish.cancel();
          if (!gate.isCompleted) gate.complete();
        });
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(player.disposed, !growing);
        if (growing) expect(handler.snapshot.loadingSongId, 'song-0');
        await loading;
        if (growing) {
          expect(failures, isEmpty);
          expect(handler.snapshot.currentSongId, 'song-0');
          expect(handler.snapshot.playing, isTrue);
        } else {
          expect(handler.snapshot.currentSongId, 'song-1');
        }
      });
    }
    for (final idle in [true, false]) {
      test(
        'start remains bounded by ${idle ? 'download idle' : 'hard cap'}',
        () async {
          final (handler, player, grow) = await fixture(
            timeouts: idle
                ? const NavisPlaybackTimeouts(
                    load: Duration(milliseconds: 300),
                    seekProgress: Duration(milliseconds: 2400),
                    progressIdle: Duration(milliseconds: 300),
                  )
                : deadlines,
          );
          final gate = Completer<void>();
          final entered = Completer<void>();
          player
            ..loadGate = gate
            ..loadEntered = entered
            ..gateNonEmptyLoadsOnly = true;
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
          final failures = <PlaybackLoadFailure>[];
          final subscription = handler.loadFailureStream.listen(failures.add);
          addTearDown(subscription.cancel);
          grow(growing: true);
          final elapsed = Stopwatch()..start();
          final loading = handler.replaceQueue([
            'song-0',
            'song-1',
          ], expandMatchFlows: false);
          await entered.future;
          await Future<void>.delayed(const Duration(milliseconds: 400));
          expect(player.disposed, isFalse);
          if (idle) grow(growing: false);
          await loading;
          expect(player.disposed, isTrue);
          if (handler.snapshot.currentSongId != 'song-1' ||
              handler.snapshot.isLoading) {
            await handler.snapshotStream
                .firstWhere(
                  (snapshot) =>
                      snapshot.currentSongId == 'song-1' && !snapshot.isLoading,
                )
                .timeout(const Duration(seconds: 2));
          }
          expect(handler.snapshot.currentSongId, 'song-1');
          expect(failures, isEmpty);
          expect(elapsed.elapsedMilliseconds, greaterThan(idle ? 500 : 1100));
          if (idle) expect(elapsed.elapsedMilliseconds, lessThan(2000));
        },
      );
    }
  });

  group('Android range bandwidth', () {
    Future<
      (
        NavisAudioHandler,
        _ControllableAudioPlayer,
        Map<String, _RangeCacheSource>,
      )
    >
    rangeHandler({
      List<_ControllableAudioPlayer>? rebuilt,
      TargetPlatform platform = TargetPlatform.android,
    }) async {
      debugDefaultTargetPlatformOverride = platform;
      final directory = await Directory.systemTemp.createTemp(
        'navis-range-priority-',
      );
      final sources = {
        for (var i = 0; i < 3; i++)
          'song-$i': _RangeCacheSource(
            'song-$i',
            File(p.join(directory.path, '$i.mp3')),
          ),
      };
      final (handler, player, database) = await createHandler(
        directory,
        3,
        cacheSongs: false,
        positionStreams: true,
        rebuiltPlayers: rebuilt,
        desktopRuntimeOverride: platform == TargetPlatform.linux,
        timeouts: const NavisPlaybackTimeouts(
          control: Duration(milliseconds: 300),
          progressIdle: Duration(milliseconds: 400),
          seekProgress: Duration(seconds: 3),
        ),
        wrapResolver: (base) => _RangeCacheResolver(base, sources),
      );
      addTearDown(() async {
        await handler.disposeHandler();
        for (final source in sources.values) {
          await source.progress.close();
        }
        await database.close();
        await directory.delete(recursive: true);
        debugDefaultTargetPlatformOverride = null;
      });
      player.simulateProgress = true;
      await handler.replaceQueue([
        'song-0',
        'song-1',
        'song-2',
      ], expandMatchFlows: false);
      await pumpEventQueue();
      return (handler, player, sources);
    }

    for (final exit in [
      'Pause',
      'seek back',
      'skip',
      'Stop',
      'replace',
      'dispose',
      'buffer full',
      'range failed',
    ]) {
      test(
        'range priority pauses current and next and resumes on $exit',
        () async {
          final (handler, player, sources) = await rangeHandler();
          sources['song-0']!.activeRange = true;
          player.emitBuffered(const Duration(seconds: 2));
          await pumpEventQueue();
          expect(sources['song-0']!.paused, isTrue);
          expect(sources['song-1']!.paused, isTrue);
          expect(sources['song-2']!.paused, isFalse);
          switch (exit) {
            case 'Pause':
              await handler.pause();
            case 'seek back':
              sources['song-0']!.activeRange = false;
              await handler.seek(Duration.zero);
            case 'skip':
              await handler.skipToNext();
            case 'Stop':
              await handler.stop();
            case 'replace':
              await handler.replaceQueue(['song-2'], expandMatchFlows: false);
            case 'dispose':
              await handler.disposeHandler();
            case 'buffer full':
              player.emitBuffered(const Duration(seconds: 60));
            case 'range failed':
              sources['song-0']!.activeRange = false;
              sources['song-0']!.progress.add(0);
          }
          await pumpEventQueue();
          expect(sources['song-0']!.paused, isFalse);
          expect(sources['song-1']!.paused, isFalse);
        },
      );
    }

    for (final progress in ['range', 'buffer', 'none']) {
      test(
        'mobile native seek ${progress == 'none' ? 'retires' : 'keeps'} its engine with $progress progress',
        () async {
          final rebuilt = <_ControllableAudioPlayer>[];
          final (handler, player, sources) = await rangeHandler(
            rebuilt: rebuilt,
          );
          final gate = Completer<void>();
          final entered = Completer<void>();
          player
            ..seekGate = gate
            ..seekEntered = entered;
          final seek = handler.seek(const Duration(seconds: 30));
          await entered.future.timeout(const Duration(seconds: 2));
          player.state = ProcessingState.buffering;
          sources['song-0']!.activeRange = true;
          player.emitBuffered(const Duration(seconds: 2));
          final ticker = Timer.periodic(const Duration(milliseconds: 50), (_) {
            if (progress == 'range') {
              sources['song-0']!.receivedRangeBytes += 1024;
            }
            if (progress == 'buffer') {
              player.emitBuffered(
                player.bufferedPosition + const Duration(seconds: 1),
              );
            }
          });
          try {
            await Future<void>.delayed(const Duration(milliseconds: 900));
            expect(rebuilt, progress == 'none' ? hasLength(1) : isEmpty);
            gate.complete();
            if (progress != 'none') player.state = ProcessingState.ready;
            await seek;
            expect(rebuilt, progress == 'none' ? hasLength(1) : isEmpty);
            if (progress == 'none') {
              expect(sources['song-0']!.paused, isFalse);
              expect(sources['song-1']!.paused, isFalse);
            }
          } finally {
            ticker.cancel();
            if (!gate.isCompleted) gate.complete();
            await seek;
          }
        },
      );
    }

    test('Pause during progressing native seek releases downloads and stays paused', () async {
      final rebuilt = <_ControllableAudioPlayer>[];
      final (handler, player, sources) = await rangeHandler(rebuilt: rebuilt);
      sources['song-0']!.activeRange = true;
      final gate = Completer<void>();
      final entered = Completer<void>();
      player
        ..seekGate = gate
        ..seekEntered = entered;
      final seek = handler.seek(const Duration(seconds: 30));
      await entered.future;
      player.state = ProcessingState.buffering;
      await handler.pause();
      expect(sources['song-0']!.paused, isFalse);
      gate.complete();
      await seek;
      expect(player.playing, isFalse);
      expect(rebuilt, isEmpty);
    });

    test('desktop native seek retains its fixed control deadline', () async {
      final rebuilt = <_ControllableAudioPlayer>[];
      final (handler, player, sources) = await rangeHandler(
        rebuilt: rebuilt,
        platform: TargetPlatform.linux,
      );
      player.hang.add('seek');
      final ticker = Timer.periodic(
        const Duration(milliseconds: 50),
        (_) => sources['song-0']!.receivedRangeBytes += 1024,
      );
      try {
        await handler.seek(const Duration(seconds: 30));
        expect(rebuilt, hasLength(1));
      } finally {
        ticker.cancel();
      }
    });

    test(
      'new seek cancels a progressing native wait and keeps lock caching',
      () async {
        final rebuilt = <_ControllableAudioPlayer>[];
        final (handler, player, sources) = await rangeHandler(rebuilt: rebuilt);
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..seekGate = gate
          ..seekEntered = entered;
        final old = handler.seek(const Duration(seconds: 30));
        await entered.future.timeout(const Duration(seconds: 2));
        sources['song-0']!.activeRange = true;
        player.state = ProcessingState.buffering;
        final ticker = Timer.periodic(
          const Duration(milliseconds: 50),
          (_) => sources['song-0']!.receivedRangeBytes += 1024,
        );
        final latest = handler.seek(const Duration(seconds: 60));
        try {
          await Future<void>.delayed(const Duration(milliseconds: 900));
          expect(rebuilt, isEmpty);
          expect(player.seekCalls, 2);
          expect(player.sourceLoads, 1);
          expect(
            handler.queue.value.first.extras!['sourceKind'],
            PlaybackSourceKind.lockCachedStream.name,
          );
          expect(sources['song-0']!.activeRange, isTrue);
          expect(handler.debugQueueLaneIdle, isTrue);
          expect(
            handler.collectPlaybackDiagnostics()['lockCachingBypassed'],
            isFalse,
          );
          expect(handler.collectPlaybackDiagnostics()['anomalies'], isEmpty);
        } finally {
          ticker.cancel();
          gate.complete();
          await Future.wait([old, latest]);
          await pumpEventQueue();
        }
        expect(handler.snapshot.currentSongId, 'song-0');
        expect(handler.snapshot.pendingSeekPosition, isNull);
      },
    );

    test(
      'dead native seek cancels retired ranges before stop returns',
      () async {
        final rebuilt = <_ControllableAudioPlayer>[];
        final (handler, player, sources) = await rangeHandler(rebuilt: rebuilt);
        final seekGate = Completer<void>();
        final stopGate = Completer<void>();
        final entered = Completer<void>();
        player
          ..seekGate = seekGate
          ..seekEntered = entered
          ..stopGate = stopGate;
        final seek = handler.seek(const Duration(seconds: 30));
        await entered.future.timeout(const Duration(seconds: 2));
        sources['song-0']!.activeRange = true;
        player.state = ProcessingState.buffering;
        player.emitBuffered(const Duration(seconds: 2));
        try {
          await Future<void>.delayed(const Duration(milliseconds: 900));
          expect(rebuilt, hasLength(1));
          expect(stopGate.isCompleted, isFalse);
          expect(sources['song-0']!.activeRange, isFalse);
          expect(sources['song-0']!.paused, isFalse);
          expect(sources['song-1']!.paused, isFalse);
        } finally {
          stopGate.complete();
          seekGate.complete();
          await seek;
        }
      },
    );

    test(
      'dead native seek clears retired cache activity and tracking',
      () async {
        final rebuilt = <_ControllableAudioPlayer>[];
        final (handler, player, sources) = await rangeHandler(rebuilt: rebuilt);
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        await pumpEventQueue();
        final source = sources['song-0']!;
        source.progress.add(0.4);
        await pumpEventQueue();
        expect(
          handler.collectPlaybackDiagnostics()['cacheActivity'],
          containsPair('songId', 'song-0'),
        );
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..seekGate = gate
          ..seekEntered = entered;
        final seek = handler.seek(const Duration(seconds: 30));
        try {
          await entered.future.timeout(const Duration(seconds: 2));
          player.state = ProcessingState.buffering;
          await Future<void>.delayed(const Duration(milliseconds: 900));
          expect(rebuilt, hasLength(1));
          expect(handler.snapshot.currentSongId, 'song-0');
          expect(handler.collectPlaybackDiagnostics()['cacheActivity'], isNull);
          expect(source.progress.hasListener, isFalse);
        } finally {
          gate.complete();
          await seek;
        }
      },
    );

    test(
      'range priority ignores a next song from a mismatched queue index',
      () async {
        final (handler, player, sources) = await rangeHandler();
        sources['song-0']!.activeRange = true;
        player.emitBuffered(const Duration(seconds: 2));
        await pumpEventQueue();
        expect(sources['song-1']!.paused, isTrue);
        // Native index can move before the current media item is published.
        player.index = 1;
        sources['song-0']!.progress.add(0);
        await pumpEventQueue();
        expect(handler.mediaItem.value!.id, 'song-0');
        expect(sources['song-0']!.paused, isTrue);
        expect(sources['song-1']!.paused, isFalse);
        expect(sources['song-2']!.paused, isFalse);
      },
    );

    test(
      'desktop lock-cache probes do not pause whole-file downloads',
      () async {
        final (_, player, sources) = await rangeHandler(
          platform: TargetPlatform.linux,
        );
        sources['song-0']!.activeRange = true;
        player.emitBuffered(const Duration(seconds: 2));
        await pumpEventQueue();
        expect(sources.values.every((source) => !source.paused), isTrue);
      },
    );

    test('Android load reserve keeps native playback thresholds', () {
      final control =
          NavisAudioHandler.androidLoadConfiguration.androidLoadControl!;
      expect(control.minBufferDuration, const Duration(seconds: 180));
      expect(control.maxBufferDuration, const Duration(seconds: 180));
      expect(control.targetBufferBytes, 32 * 1024 * 1024);
      expect(control.prioritizeTimeOverSizeThresholds, isFalse);
      expect(
        control.bufferForPlaybackDuration,
        const Duration(milliseconds: 2500),
      );
      expect(
        control.bufferForPlaybackAfterRebufferDuration,
        const Duration(seconds: 5),
      );
    });
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

    test('desktop buffering seek outlasts the load deadline without a download signal', () async {
      final directory = await Directory.systemTemp.createTemp('navis-seek-');
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
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      player
        ..state = ProcessingState.buffering
        ..nativePositionFrozen = true;
      final landed = Timer(const Duration(milliseconds: 900), () {
        player
          ..state = ProcessingState.ready
          ..simulatedPosition = player.simulatedPosition
          ..nativePositionFrozen = false;
      });
      addTearDown(landed.cancel);
      await handler.seek(const Duration(seconds: 90));
      final outcome = handler.collectPlaybackDiagnostics()['seek']! as Map;
      expect(outcome['recoveryAttempts'], 0);
      expect(outcome['outcome'], 'completed');
    });

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
      test('failed remote recovery honors a newer $command', () async {
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
          command == 'pause' ? 'song-2' : 'song-4',
        );
        expect(player.playing, command != 'pause');
        expectNativeMirrorsQueue(handler, player);
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
                    handler.snapshot.currentIndex,
                    0,
                    reason: 'seed $seed: ${log.join(', ')}',
                  );
                  expect(
                    reordered.first,
                    playing,
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

  group('seek bar buffered line', () {
    late HttpServer server;
    late Completer<void> release;
    late Completer<void> more;
    late Directory directory;
    var requests = 0;

    // The server sends [first] bytes, waits for [release], then ends or, for
    // an unknown length, waits for [more] and sends [second] further bytes.
    Future<(NavisAudioHandler, _ControllableAudioPlayer)> serve({
      int? length = 100 * 1024,
      int first = 40 * 1024,
      int second = 0,
      bool fail = false,
      bool sidecar = true,
      bool cacheSongs = false,
      int count = 2,
      StreamingQuality quality = const StreamingQuality(label: 'original'),
      Uint8List? payload,
      bool supportsTranscodeOffset = false,
      NavisPlaybackTimeouts timeouts = const NavisPlaybackTimeouts(),
    }) async {
      List<int> chunk(int from, int to) => payload == null
          ? List<int>.filled(to - from, 1)
          : payload.sublist(from, to);
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      requests = 0;
      release = Completer<void>();
      more = Completer<void>();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final nth = requests++;
        try {
          final response = request.response..bufferOutput = false;
          if (length != null) response.contentLength = length;
          if (nth == 0) response.add(chunk(0, first));
          await response.flush();
          if (nth != 0) return;
          if (length != null || fail) await release.future;
          if (fail) {
            await server.close(force: true);
            return;
          }
          if (length != null) {
            response.add(chunk(first, length));
          } else if (second > 0) {
            await more.future;
            response.add(chunk(first, first + second));
          }
          if (length != null) await response.close();
        } on HttpException {
          // The handler cancels the unfinished transfer.
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
      directory = await Directory.systemTemp.createTemp('navis-buffered-');
      final (handler, player, database) = await createHandler(
        directory,
        count,
        sidecarStreams: sidecar,
        cacheSongs: cacheSongs,
        readApiClient: () => api,
        streamingQuality: quality,
        supportsTranscodeOffset: supportsTranscodeOffset,
        timeouts: timeouts,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        if (!release.isCompleted) release.complete();
        if (!more.isCompleted) more.complete();
        await database.close();
        await server.close(force: true);
        await directory.delete(recursive: true);
        HttpOverrides.global = previousHttp;
      });
      return (handler, player);
    }

    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 400 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    Duration line(NavisAudioHandler handler) =>
        handler.bufferState.bufferedPosition;

    Duration fraction(NavisAudioHandler handler, double value) => Duration(
      seconds: (handler.snapshot.duration.inSeconds * value).floor(),
    );

    Future<void> startSong(NavisAudioHandler handler) async {
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      await settleQueue(handler);
    }

    test('after a seek the line follows the known-length download', () async {
      final (handler, player) = await serve();
      await startSong(handler);
      player.emitBuffered(const Duration(seconds: 5));
      await until(() => line(handler) >= fraction(handler, 0.4));
      expect(handler.snapshot.duration, greaterThan(Duration.zero));
      expect(line(handler), fraction(handler, 0.4));
      expect(handler.bufferState.songId, 'song-0');
      final diagnostics = handler.collectPlaybackDiagnostics();
      expect(
        diagnostics['cachedPlayablePositionMs'],
        line(handler).inMilliseconds,
      );
      expect(diagnostics['playerBufferedPositionMs'], 5000);
    });

    test('a player buffered ahead of the download sets the line', () async {
      final (handler, player) = await serve();
      await startSong(handler);
      await until(
        () => handler.collectPlaybackDiagnostics()['cacheActivity'] != null,
      );
      player.emitBuffered(fraction(handler, 0.9));
      await pumpEventQueue();
      expect(line(handler), fraction(handler, 0.9));
    });

    test('an unknown-length transcode counts bytes at the bitrate', () async {
      final (handler, player) = await serve(
        length: null,
        first: 160000,
        second: 3000000,
        quality: const StreamingQuality(
          label: 'opus',
          maxBitRate: 128,
          format: 'opus',
        ),
      );
      await startSong(handler);
      player.emitBuffered(const Duration(seconds: 2));
      await until(() => line(handler) >= const Duration(seconds: 10));
      expect(line(handler), const Duration(seconds: 10));
      more.complete();
      await until(() => line(handler) >= handler.snapshot.duration);
      // 3 MB at 128 kbit/s is longer than the song: clamped to its duration.
      expect(line(handler), handler.snapshot.duration);
    });

    test('a file source draws the full duration', () async {
      final (handler, player) = await serve(sidecar: false, cacheSongs: true);
      await startSong(handler);
      expect(handler.queue.value[0].extras!['sourceKind'], 'file');
      player.emitBuffered(const Duration(seconds: 3));
      await pumpEventQueue();
      expect(line(handler), handler.snapshot.duration);
    });

    test('a completed sidecar download draws the full duration', () async {
      final (handler, player) = await serve();
      await startSong(handler);
      player.emitBuffered(const Duration(seconds: 3));
      release.complete();
      await until(() => line(handler) >= handler.snapshot.duration);
      expect(line(handler), handler.snapshot.duration);
    });

    test('a sidecar completed before the song became current draws the full '
        'duration', () async {
      final (handler, player) = await serve();
      await startSong(handler);
      player.emitBuffered(const Duration(seconds: 3));
      release.complete();
      await until(() => line(handler) >= handler.snapshot.duration);
      // The finished download must unregister its activity first.
      await until(
        () => handler.collectPlaybackDiagnostics()['cacheActivity'] == null,
      );
      await handler.skipToNext();
      await settleQueue(handler);
      expect(handler.bufferState.songId, 'song-1');
      await handler.skipToPrevious();
      await settleQueue(handler);
      player.emitBuffered(const Duration(seconds: 1));
      await until(() => line(handler) >= handler.snapshot.duration);
      expect(line(handler), handler.snapshot.duration);
    });

    test('a completed lock-cache download draws the full duration', () async {
      final (handler, player) = await serve(sidecar: false);
      await startSong(handler);
      final extras = handler.queue.value[0].extras!;
      expect(extras['sourceKind'], 'lockCachedStream');
      // ignore: experimental_member_use, reason: drives the lock-cache download the player would.
      final source = player.audioSources[0] as LockCachingAudioSource;
      final drained = (await source.request()).stream.drain<void>();
      await until(() => line(handler) >= fraction(handler, 0.4));
      expect(line(handler), fraction(handler, 0.4));
      release.complete();
      await drained;
      await until(() => line(handler) >= handler.snapshot.duration);
      expect(line(handler), handler.snapshot.duration);
      // The finished song's activity is gone; the line stays full.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      player.emitBuffered(const Duration(seconds: 3));
      await pumpEventQueue();
      expect(line(handler), handler.snapshot.duration);
    });

    test(
      'an exhausted sidecar download does not draw the full duration',
      () async {
        final (handler, player) = await serve(fail: true);
        await startSong(handler);
        player.emitBuffered(const Duration(seconds: 5));
        await until(() => line(handler) >= fraction(handler, 0.4));
        release.complete();
        await Future.doWhile(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return handler.collectPlaybackDiagnostics()['cacheActivity'] != null;
        }).timeout(const Duration(seconds: 10));
        player.emitBuffered(const Duration(seconds: 6));
        await pumpEventQueue();
        expect(line(handler), const Duration(seconds: 6));
      },
    );

    test('the previous song cache does not reach the next song', () async {
      final (handler, player) = await serve();
      await startSong(handler);
      await until(() => line(handler) >= fraction(handler, 0.4));
      await handler.skipToNext();
      await pumpEventQueue();
      expect(handler.bufferState.songId, 'song-1');
      expect(line(handler), Duration.zero);
      player.emitBuffered(const Duration(seconds: 4));
      await pumpEventQueue();
      expect(line(handler), const Duration(seconds: 4));
    });

    const opus = StreamingQuality(
      label: 'opus',
      maxBitRate: 128,
      format: 'opus',
    );

    // 20 Opus pages of about 8 kB (161 kB: 10 s at 128 kbit/s) whose last
    // granule says 90 s.
    Uint8List opusBytes() => concat([
      opusHeadPage(),
      for (var i = 0; i < 20; i++)
        oggAudioPage(48000 * 90 * (i + 1) ~/ 20 + 312, size: 8000),
    ]);

    bool partHolds(int bytes) => directory
        .listSync(recursive: true)
        .whereType<File>()
        .any((f) => f.path.contains('.part') && f.lengthSync() >= bytes);

    // The cache refreshes per chunk and per player event; keep emitting the
    // player's own value until the line shows [done].
    Future<void> drawUntil(
      _ControllableAudioPlayer player,
      bool Function() done,
    ) async {
      for (var i = 0; i < 80 && !done(); i++) {
        player.emitBuffered(player.simulatedBuffered);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    int probes(NavisAudioHandler handler) =>
        handler.collectPlaybackDiagnostics()['cachedExtentProbes']! as int;

    test('an Ogg part file draws its exact time, not the estimate', () async {
      final bytes = opusBytes();
      final (handler, player) = await serve(
        length: null,
        first: bytes.length,
        payload: bytes,
        quality: opus,
      );
      await startSong(handler);
      await until(() => partHolds(bytes.length));
      await drawUntil(
        player,
        () => line(handler) >= const Duration(seconds: 90),
      );
      expect(line(handler), const Duration(seconds: 90));
      final diagnostics = handler.collectPlaybackDiagnostics();
      expect(diagnostics['cachedPlayableSource'], 'exact');
      expect(diagnostics['cachedPlayablePositionMs'], 90000);
    });

    test('a FLAC part file draws the last verified frame time', () async {
      final bytes = concat([
        flacHead(),
        for (var n = 1000; n < 1250; n++) flacFrame(n),
      ]);
      final (handler, player) = await serve(
        length: bytes.length,
        first: 40 * 1024,
        payload: bytes,
      );
      await startSong(handler);
      await until(() => partHolds(40 * 1024));
      // 1100 frames of 4096 samples at 44.1 kHz; the progress fraction
      // (40%) would say 72 s.
      await drawUntil(
        player,
        () => line(handler) >= const Duration(seconds: 100),
      );
      expect(line(handler), const Duration(seconds: 102));
      expect(
        handler.collectPlaybackDiagnostics()['cachedPlayableSource'],
        'exact',
      );
    });

    test('an unparseable part file falls back to the estimate', () async {
      final (handler, player) = await serve(
        length: null,
        first: 160000,
        quality: opus,
      );
      await startSong(handler);
      await until(() => probes(handler) >= 1);
      await drawUntil(
        player,
        () => line(handler) >= const Duration(seconds: 10),
      );
      expect(line(handler), const Duration(seconds: 10));
      expect(
        handler.collectPlaybackDiagnostics()['cachedPlayableSource'],
        'bitrate',
      );
    });

    test('chunk updates within a second start one probe', () async {
      final bytes = opusBytes();
      final (handler, player) = await serve(
        length: null,
        first: bytes.length,
        second: 1000,
        payload: concat([bytes, Uint8List(1000)]),
        quality: opus,
      );
      await startSong(handler);
      await until(() => probes(handler) >= 1);
      more.complete();
      for (var i = 0; i < 20; i++) {
        player.emitBuffered(Duration(seconds: i));
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(probes(handler), 1);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      player.emitBuffered(const Duration(seconds: 30));
      await until(() => probes(handler) >= 2);
      expect(probes(handler), 2);
    });

    test('a late probe for the previous song is ignored', () async {
      final (handler, player) = await serve(length: null, first: 160000);
      final gate = Completer<Duration?>();
      var reads = 0;
      handler.cachedExtentReader = (_) async =>
          reads++ == 0 ? gate.future : null;
      await startSong(handler);
      await until(() => probes(handler) >= 1);
      await handler.skipToNext();
      await settleQueue(handler);
      expect(handler.bufferState.songId, 'song-1');
      gate.complete(const Duration(seconds: 90));
      await pumpEventQueue();
      player.emitBuffered(const Duration(seconds: 4));
      await pumpEventQueue();
      expect(line(handler), const Duration(seconds: 4));
    });

    Future<void> seekPast(NavisAudioHandler handler, Duration to) async {
      await handler.seek(to);
      await until(() => !handler.snapshot.isLoading);
    }

    test('an offset stream draws the cached range and its own ahead', () async {
      final bytes = opusBytes();
      final (handler, player) = await serve(
        length: null,
        first: bytes.length,
        payload: bytes,
        quality: opus,
        supportsTranscodeOffset: true,
      );
      player.simulateProgress = true;
      await startSong(handler);
      await handler.play();
      await until(() => partHolds(bytes.length));
      await drawUntil(
        player,
        () => line(handler) >= const Duration(seconds: 90),
      );
      await seekPast(handler, const Duration(seconds: 120));
      expect(handler.collectPlaybackDiagnostics()['positionOffsetMs'], 120000);
      player.emitBuffered(const Duration(seconds: 150));
      await drawUntil(player, () => handler.bufferState.aheadStart != null);
      expect(line(handler), const Duration(seconds: 90));
      expect(handler.bufferState.aheadStart, const Duration(seconds: 120));
      expect(handler.bufferState.aheadEnd, const Duration(seconds: 150));
      final diagnostics = handler.collectPlaybackDiagnostics();
      expect(diagnostics['drawnAheadStartMs'], 120000);
      expect(diagnostics['drawnAheadEndMs'], 150000);
      expect(diagnostics['playerBufferedPositionMs'], 150000);
    });

    test(
      'a seek past the download starts the ahead range at its target',
      () async {
        final (handler, player) = await serve();
        player.simulateProgress = true;
        await startSong(handler);
        await handler.play();
        await until(() => line(handler) >= fraction(handler, 0.4));
        await seekPast(handler, const Duration(seconds: 150));
        player.emitBuffered(const Duration(seconds: 170));
        await pumpEventQueue();
        expect(line(handler), fraction(handler, 0.4));
        expect(handler.bufferState.aheadStart, const Duration(seconds: 150));
        expect(handler.bufferState.aheadEnd, const Duration(seconds: 170));
      },
    );

    test('a seek inside the download or no seek draws one range', () async {
      final (handler, player) = await serve();
      player.simulateProgress = true;
      await startSong(handler);
      await handler.play();
      await until(() => line(handler) >= fraction(handler, 0.4));
      player.emitBuffered(const Duration(seconds: 100));
      await pumpEventQueue();
      expect(line(handler), const Duration(seconds: 100));
      expect(handler.bufferState.aheadStart, isNull);
      await seekPast(handler, const Duration(seconds: 30));
      player.emitBuffered(const Duration(seconds: 120));
      await pumpEventQueue();
      expect(line(handler), const Duration(seconds: 120));
      expect(handler.bufferState.aheadStart, isNull);
      expect(handler.bufferState.aheadEnd, isNull);
    });

    test('a page-less Opus start still shows the estimate', () async {
      // Early in a download the last complete page is OpusTags (granule 0):
      // that is not an exact time, so the bitrate estimate stays.
      final bytes = concat([
        opusHeadPage(),
        oggPage('OpusTags'.codeUnits, granule: 0),
        oggAudioPage(-1, size: 3000),
      ]);
      final (handler, player) = await serve(
        length: null,
        first: bytes.length,
        payload: bytes,
        quality: const StreamingQuality(
          label: 'opus',
          maxBitRate: 8,
          format: 'opus',
        ),
      );
      await startSong(handler);
      await until(() => partHolds(bytes.length));
      // A probe after the whole file is on disk has run.
      await drawUntil(player, () => probes(handler) >= 2);
      await pumpEventQueue();
      expect(line(handler), const Duration(seconds: 3));
      expect(
        handler.collectPlaybackDiagnostics()['cachedPlayableSource'],
        'bitrate',
      );
    });

    test('a failed seek past the download draws no ahead range', () async {
      final (handler, player) = await serve(
        timeouts: const NavisPlaybackTimeouts(
          seekProgress: Duration(seconds: 1),
          progressIdle: Duration(milliseconds: 300),
          desktopSeekSettle: Duration(seconds: 1),
        ),
      );
      final states = <PlaybackBufferState>[];
      final subscription = handler.bufferStateStream.listen(states.add);
      addTearDown(subscription.cancel);
      await startSong(handler);
      // The seek never settles and recovery cannot reload the stream.
      player
        ..ignoreSeeks = true
        ..failLoadSongId = 'song-0';
      final seeking = handler.seek(const Duration(seconds: 150));
      player.emitBuffered(const Duration(seconds: 170));
      await pumpEventQueue();
      expect(handler.bufferState.aheadStart, const Duration(seconds: 150));
      await seeking;
      await until(
        () =>
            (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'] ==
            'failed',
      );
      // Failover may then move to the next song; before it, the failed
      // seek's target is forgotten and the line is the player's range.
      final ahead = states.indexWhere((state) => state.aheadStart != null);
      expect(ahead, isNonNegative);
      expect(
        states
            .skip(ahead + 1)
            .any(
              (state) =>
                  state.songId == 'song-0' &&
                  state.aheadStart == null &&
                  state.bufferedPosition == const Duration(seconds: 170),
            ),
        isTrue,
      );
    });

    test(
      'a late probe for a restarted download of the same song is ignored',
      () async {
        final (handler, player) = await serve(length: null, first: 160000);
        final gate = Completer<Duration?>();
        final paths = <String>[];
        handler.cachedExtentReader = (path) async {
          paths.add(path);
          return paths.length == 1 ? gate.future : null;
        };
        await startSong(handler);
        await until(() => paths.isNotEmpty);
        // Away and back: the song's download restarts into a new part file.
        await handler.skipToNext();
        await settleQueue(handler);
        await handler.skipToPrevious();
        await settleQueue(handler);
        expect(handler.bufferState.songId, 'song-0');
        await drawUntil(player, () => paths.length >= 2);
        expect(paths.first, isNot(paths.last), reason: 'a new part file');
        gate.complete(const Duration(seconds: 90));
        await pumpEventQueue();
        player.emitBuffered(const Duration(seconds: 4));
        await pumpEventQueue();
        expect(line(handler), const Duration(seconds: 4));
        expect(
          handler.collectPlaybackDiagnostics()['cachedPlayableSource'],
          isNot('exact'),
        );
      },
    );

    // A held or slow download sends no buffer events, so the probe re-arms
    // itself while the part file grows (a shortened interval keeps these fast).
    group('trailing probe', () {
      const interval = Duration(milliseconds: 100);

      test('re-probes a growing part file without buffer events', () async {
        final (handler, _) = await serve(length: null, first: 160000);
        var reads = 0;
        handler
          ..cachedExtentInterval = interval
          ..cachedExtentReader = (_) async => Duration(seconds: 30 + reads++);
        await startSong(handler);
        await until(() => line(handler) >= const Duration(seconds: 34));
        expect(
          line(handler),
          greaterThanOrEqualTo(const Duration(seconds: 34)),
        );
        expect(probes(handler), greaterThanOrEqualTo(5));
        expect(
          handler.collectPlaybackDiagnostics()['cachedPlayableSource'],
          'exact',
        );
      });

      test(
        'stops after an unchanged streak and restarts on an event',
        () async {
          final (handler, player) = await serve(length: null, first: 160000);
          handler
            ..cachedExtentInterval = interval
            ..cachedExtentReader = (_) async => const Duration(seconds: 30);
          await startSong(handler);
          await Future<void>.delayed(const Duration(milliseconds: 900));
          final settled = probes(handler);
          expect(settled, inInclusiveRange(6, 8));
          await Future<void>.delayed(const Duration(milliseconds: 400));
          expect(probes(handler), settled);
          expect(handler.cachedExtentTimerActive, isFalse);
          player.emitBuffered(const Duration(seconds: 3));
          await until(() => probes(handler) > settled);
          expect(probes(handler), settled + 1);
        },
      );

      // A long interval keeps an armed timer visibly pending.
      Future<NavisAudioHandler> armed({
        int? length,
        int first = 160000,
        FutureOr<Duration?> Function(String path)? after,
      }) async {
        final (handler, _) = await serve(length: length, first: first);
        var reads = 0;
        handler
          ..cachedExtentInterval = const Duration(seconds: 5)
          ..cachedExtentReader = (path) => reads++ == 0
              ? Future.value(const Duration(seconds: 10))
              : Future.value(after?.call(path));
        await startSong(handler);
        await until(() => handler.cachedExtentTimerActive);
        expect(handler.cachedExtentTimerActive, isTrue);
        return handler;
      }

      test('a song change cancels the timer', () async {
        final handler = await armed(
          after: (_) => Completer<Duration?>().future,
        );
        await handler.skipToNext();
        await settleQueue(handler);
        expect(handler.bufferState.songId, 'song-1');
        // The next song's probe never returns, so only a leftover timer of
        // the previous song could still be pending.
        await until(() => probes(handler) >= 2);
        expect(handler.cachedExtentTimerActive, isFalse);
      });

      test('cache completion cancels the timer', () async {
        final handler = await armed(length: 100 * 1024, first: 40 * 1024);
        release.complete();
        await until(() => !handler.cachedExtentTimerActive);
        expect(handler.cachedExtentTimerActive, isFalse);
        expect(line(handler), handler.snapshot.duration);
      });

      test('dispose cancels the timer', () async {
        final handler = await armed();
        await handler.disposeHandler();
        expect(handler.cachedExtentTimerActive, isFalse);
      });
    });

    test('a Repeat One loop clears the ahead range start', () async {
      final (handler, player) = await serve();
      player.simulateProgress = true;
      await startSong(handler);
      await handler.play();
      await until(() => line(handler) >= fraction(handler, 0.4));
      await seekPast(handler, const Duration(seconds: 150));
      player.emitBuffered(const Duration(seconds: 170));
      await pumpEventQueue();
      expect(handler.bufferState.aheadStart, const Duration(seconds: 150));
      player._discontinuities.add(
        PositionDiscontinuity(
          PositionDiscontinuityReason.autoAdvance,
          PlaybackEvent(
            processingState: ProcessingState.ready,
            updatePosition: const Duration(seconds: 175),
            currentIndex: 0,
          ),
          player.playbackEvent,
        ),
      );
      await pumpEventQueue();
      expect(handler.bufferState.aheadStart, isNull);
      expect(line(handler), const Duration(seconds: 170));
    });

    test('the download catching up to the ahead range merges them', () async {
      final (handler, player) = await serve();
      player.simulateProgress = true;
      await startSong(handler);
      await handler.play();
      await until(() => line(handler) >= fraction(handler, 0.4));
      await seekPast(handler, const Duration(seconds: 150));
      player.emitBuffered(const Duration(seconds: 170));
      await pumpEventQueue();
      expect(handler.bufferState.aheadStart, const Duration(seconds: 150));
      release.complete();
      await until(() => line(handler) >= handler.snapshot.duration);
      expect(line(handler), handler.snapshot.duration);
      expect(handler.bufferState.aheadStart, isNull);
    });

    test('radio draws no line', () async {
      final (handler, player) = await serve(cacheSongs: true, sidecar: false);
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: 'https://radio.example.invalid/live',
      );
      player.emitBuffered(const Duration(seconds: 10));
      await pumpEventQueue();
      expect(handler.bufferState.songId, isNull);
      expect(line(handler), Duration.zero);
    });
  });
}
