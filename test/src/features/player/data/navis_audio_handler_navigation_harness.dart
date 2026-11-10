import 'package:navis/src/features/cache/data/rolling_cache_sidecar_downloader.dart';

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
import 'package:navis/src/utils/connectivity.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/daos/history_dao.dart';
import 'package:navis/src/database/daos/play_queue_dao.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/cache/data/rolling_cache_manager.dart';
import 'package:navis/src/features/player/data/listenbrainz_feedback_service.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/recommendation_service.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/data/playback_transport_trace.dart';
import 'package:navis/src/features/player/data/scrobble_service.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/domain/streaming_quality.dart';

import '../../../../helpers/test_database.dart';

class MockRecommendationService extends Mock implements RecommendationService;

class MockRadioDio extends Mock implements Dio;

class MockSystemArtCache extends Mock implements BaseCacheManager;

class GatedLibraryDao extends LibraryDao {
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

class GatedHistoryDao extends HistoryDao {
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

class GatedPlayQueueDao extends PlayQueueDao {
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

class GatedQueueEntriesDao extends PlayQueueDao {
  new(super.attachedDatabase, this.release);
  final Future<void> release;

  @override
  Future<List<({SongsTableData song, int? originalOrder})>>
  getQueueEntries() async {
    await release;
    return super.getQueueEntries();
  }
}

class GatedSourceResolver extends Fake implements PlaybackSourceResolver {
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
class RangeCacheSource extends LockCachingAudioSource {
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
class WarmRangeSource extends RangeCacheSource {
  new(super.id, super.file);
  bool warmed = false;
  @override
  Future<void> prefetch() async => warmed = true;
}

// ignore: experimental_member_use, reason: as above.
class OutOfOrderResolver extends GatedSourceResolver {
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

class FreshRangeResolver extends GatedSourceResolver {
  new(super.delegate, this.directory, this.created);
  final Directory directory;
  final List<WarmRangeSource> created;
  @override
  Future<ResolvedPlaybackSource> resolveForSong(
    SongsTableData song, {
    bool preferLockCaching = true,
    bool allowStreaming = true,
    Duration? transcodeOffset,
    bool fastSeekBridge = false,
  }) async {
    final source = WarmRangeSource(
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

class SlowDisposeDownloader extends RollingCacheSidecarDownloader {
  SlowDisposeDownloader(this.gate);
  final Completer<void> gate;
  @override
  Future<void> dispose() async {
    await gate.future;
    await super.dispose();
  }
}

class RangeCacheResolver extends GatedSourceResolver {
  new(super.delegate, this.sources);
  final Map<String, RangeCacheSource> sources;
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
class TranscodedLockResolver extends GatedSourceResolver {
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

class NoopScrobbleService extends Fake implements ScrobbleService {
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

class JpegResponse implements FileServiceResponse {
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

class JpegArtworkService extends Fake implements CoverArtHttpFileService {
  int gets = 0;
  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    gets++;
    return JpegResponse();
  }

  @override
  void close({bool force = false}) {}
}

class TeardownArtworkService extends Fake implements CoverArtHttpFileService {
  bool closed = false;

  @override
  void close({bool force = false}) {
    closed = true;
  }
}

class SeekPreviewHttpClient extends Fake implements HttpClient {
  final body = StreamController<List<int>>();
  final headers = Completer<HttpClientResponse>();
  bool closed = false;
  int gets = 0;
  @override
  String? userAgent;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    gets++;
    return SeekPreviewHttpRequest(headers.future);
  }

  void respond() {
    if (!headers.isCompleted) {
      headers.complete(SeekPreviewHttpResponse(body.stream));
    }
  }

  @override
  void close({bool force = false}) {
    closed = force;
  }
}

class SeekPreviewHttpRequest extends Fake implements HttpClientRequest {
  new(this.response);
  final Future<HttpClientResponse> response;
  @override
  Future<HttpClientResponse> close() => response;
}

class SeekPreviewHttpResponse extends Fake implements HttpClientResponse {
  new(this.body);
  final Stream<List<int>> body;
  @override
  int get statusCode => 200;
  @override
  int get contentLength => -1;
  @override
  HttpHeaders get headers => SeekPreviewHttpHeaders();
  @override
  Stream<E> asyncExpand<E>(Stream<E>? Function(List<int>) convert) =>
      body.asyncExpand(convert);
}

class SeekPreviewHttpHeaders extends Fake implements HttpHeaders {
  @override
  ContentType? get contentType => ContentType('audio', 'ogg');
}

class TeardownHttpClient extends Fake implements HttpClient {
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

class ProbeHeaders extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
}

class ProbeResponse extends Fake implements HttpClientResponse {
  @override
  Future<List<int>> firstWhere(
    bool Function(List<int>) test, {
    List<int> Function()? orElse,
  }) async => <int>[1, 2];
}

class ProbeRequest extends Fake implements HttpClientRequest {
  @override
  HttpHeaders get headers => ProbeHeaders();
  @override
  Future<HttpClientResponse> close() async => ProbeResponse();
}

class ProbeClient extends Fake implements HttpClient {
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async => ProbeRequest();
  @override
  void close({bool force = false}) {}
}

class TestAudioSession extends Fake implements AudioSession {
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

class BridgeSidecar extends RollingCacheSidecarDownloader {
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

class ControllableAudioPlayer extends Fake implements AudioPlayer {
  final StreamController<int?> indexEvents = StreamController<int?>.broadcast();
  final playbackEvents = StreamController<PlaybackEvent>.broadcast();
  final discontinuityEvents =
      StreamController<PositionDiscontinuity>.broadcast();
  List<AudioSource> queuedSources = <AudioSource>[];
  ProcessingState state = ProcessingState.idle;
  bool isPlaying = false;
  bool disposed = false;

  String? get audibleSongId =>
      isPlaying && !disposed && state != ProcessingState.idle && index != null
      ? sourceIds.elementAtOrNull(index!)
      : null;
  Duration _simulatedPosition = Duration.zero;
  DateTime positionUpdatedAt = DateTime.now();
  bool simulateProgress = false;
  HandlerPositionPlayer? positionPlayer;

  void emitPlayerEvent() {
    if (positionPlayer == null) return;
    positionPlayer!.events.add(
      PlayerEvent(playing: playing, playbackEvent: playbackEvent),
    );
    playbackEvents.add(playbackEvent);
  }

  Duration get simulatedPosition => _simulatedPosition;
  set simulatedPosition(Duration value) {
    _simulatedPosition = value;
    positionUpdatedAt = DateTime.now();
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

  /// A seek with an index out of `completed` first emits `completed` at the
  /// new index, as ExoPlayer does on Android.
  bool exoEndedSeek = false;

  /// Like [exoEndedSeek], but `seek` has already returned when the stale
  /// `completed` arrives; ExoPlayer leaves ENDED a moment later.
  bool exoEndedSeekLate = false;

  /// A seek out of `completed` keeps reporting `completed`, as media_kit does
  /// while the restarted song plays (mediakit_player.dart `_processingState`).
  bool completedStaysOnSeek = false;

  /// A seek's new index is reported this long after `seek` returned, as
  /// media_kit does (its index follows a later mpv property event, #509).
  /// A microtask is not enough: the handler must wait on a real timer.
  Duration? seekIndexLag;

  /// With [seekIndexLag] set, the seek's index never lands (an ignored seek).
  bool seekIndexNeverLands = false;
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
  final List<int> setAudioSourcesCounts = <int>[];
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

  /// The load is reported ready, and the native failure arrives only once
  /// Play has been issued (libmpv opens a file after `open` returns, so a
  /// 404 can land after the adapter's first ready). Only the first Play
  /// fails that way; later loads of the song throw, as with a warm libmpv.
  bool failOnPlay = false;

  /// How many more Plays fail that way after the current one; the song's
  /// loads keep succeeding until the last.
  int failOnPlayRepeats = 0;
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
      playbackEvents.stream.doOnCancel(() async {
        final gate = listenerCancelGate;
        if (gate == null) return;
        listenerCancelGate = null;
        listenerCancelEntered?.complete();
        await gate.future;
      });

  @override
  Stream<int?> get currentIndexStream => indexEvents.stream;

  @override
  Stream<PositionDiscontinuity> get positionDiscontinuityStream =>
      discontinuityEvents.stream;

  final _shuffleModes = StreamController<bool>.broadcast();
  final _loopModes = StreamController<LoopMode>.broadcast();

  /// Announces a loop or shuffle change, as the player does after the native
  /// call completes.
  void emitLoopMode(LoopMode mode) => _loopModes.add(mode);

  /// just_audio re-emits the unchanged index on a seek's player event.
  void emitIndexAgain() => indexEvents.add(index);

  /// just_audio's auto-advance between two events with different indices, as
  /// a queue edit above the playing song produces it (old index, new index).
  void emitAutoAdvance({required int from, required int to}) =>
      discontinuityEvents.add(
        PositionDiscontinuity(
          PositionDiscontinuityReason.autoAdvance,
          playbackEvent.copyWith(currentIndex: from),
          playbackEvent.copyWith(currentIndex: to),
        ),
      );

  void emitDiscontinuity(PositionDiscontinuityReason reason) =>
      discontinuityEvents.add(
        PositionDiscontinuity(reason, playbackEvent, playbackEvent),
      );
  void emitShuffleMode(bool enabled) => _shuffleModes.add(enabled);

  @override
  Stream<bool> get shuffleModeEnabledStream => _shuffleModes.stream;

  @override
  Stream<LoopMode> get loopModeStream => _loopModes.stream;

  /// What the native processor reports back (Android EQ state and boost).
  EqualizerStateMessage nativeEqualizerState = const EqualizerStateMessage(
    enabled: false,
  );

  @override
  Future<EqualizerStateMessage> getEqualizerState() async =>
      nativeEqualizerState;

  @override
  Future<EqualizerStateMessage> setEqualizer(
    EqualizerConfigurationMessage configuration,
  ) async => nativeEqualizerState;

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
          ? DateTime.now().difference(positionUpdatedAt)
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
      List<int>.generate(queuedSources.length, (value) => value);

  @override
  List<AudioSource> get audioSources =>
      List<AudioSource>.unmodifiable(queuedSources);

  @override
  List<IndexedAudioSource> get sequence => <IndexedAudioSource>[
    for (final source in queuedSources) ...source.sequence,
  ];

  /// The ReplayGain each source carried into a load, add or insert, oldest
  /// first: what the source message would hold at that call.
  final sourceGains = <({String op, String? songId, double? db})>[];

  void _logGains(String op, List<AudioSource> sources) {
    for (final source in sources) {
      for (final indexed in source.sequence) {
        sourceGains.add((
          op: op,
          songId: navisNativeSourceSongId(indexed),
          db: indexed.replayGainDb,
        ));
      }
    }
  }

  /// Every in-pipeline ReplayGain update this deck received, oldest first.
  final levelMessages =
      <
        ({
          Map<String?, double> bySongId,
          List<({String? songId, double db})> entries,
          bool live,
        })
      >[];

  @override
  Future<void> setReplayGainLevels({
    required Map<IndexedAudioSource, double> bySource,
    bool live = false,
  }) async {
    // Like just_audio, an unloaded player has nothing to update.
    if (queuedSources.isEmpty) return;
    levelMessages.add((
      bySongId: {
        for (final entry in bySource.entries)
          navisNativeSourceSongId(entry.key): entry.value,
      },
      // In sequence order, so a song queued twice shows both entries.
      entries: [
        for (final entry in bySource.entries)
          (songId: navisNativeSourceSongId(entry.key), db: entry.value),
      ],
      live: live,
    ));
  }

  /// Every ReplayGain boost message this deck received, oldest first.
  final boostMessages =
      <({double currentDb, bool playing, Map<String?, double> bySongId})>[];

  @override
  Future<void> setReplayGainBoost({
    required double currentDb,
    Map<IndexedAudioSource, double> bySource = const {},
  }) async {
    boostMessages.add((
      currentDb: currentDb,
      playing: isPlaying,
      bySongId: {
        for (final entry in bySource.entries)
          navisNativeSourceSongId(entry.key): entry.value,
      },
    ));
  }

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

  /// One-shot: the next [setSpeed] parks here before it writes.
  Completer<void>? speedGate;
  Completer<void>? speedEntered;

  @override
  Future<void> setSpeed(double value) async {
    final gate = speedGate;
    if (gate != null) {
      speedGate = null;
      speedEntered?.complete();
      await gate.future;
    }
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
    discontinuityEvents.add(
      PositionDiscontinuity(
        PositionDiscontinuityReason.autoAdvance,
        before,
        playbackEvent,
      ),
    );
    indexEvents.add(index);
    playbackEvents.add(playbackEvent);
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
    queuedSources.removeAt(index);
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
    queuedSources.removeRange(start, end);
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

  List<String> get sourceIds => queuedSources.map(_sourceId).toList();

  void moveTo(int value) {
    index = value;
    indexEvents.add(value);
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
      final current = queuedSources[index!];
      simulatedPosition = current is IndexedAudioSource
          ? current.positionOffset
          : Duration.zero;
    } else if (next < queuedSources.length || appliedLoopMode == LoopMode.all) {
      if (discontinuityFirst) {
        index = next % queuedSources.length;
      } else {
        moveTo(next % queuedSources.length);
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
      discontinuityEvents.add(
        PositionDiscontinuity(
          PositionDiscontinuityReason.autoAdvance,
          before,
          playbackEvent,
        ),
      );
    }
    playbackEvents.add(playbackEvent);
    if (discontinuityFirst) {
      scheduleMicrotask(() {
        scheduleMicrotask(() {
          scheduleMicrotask(() => indexEvents.add(index));
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
    playCompleter?.complete();
    playCompleter = null;
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
  Completer<void>? playCompleter;

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
    positionUpdatedAt = DateTime.now();
    isPlaying = true;
    emitPlayerEvent();
    if (failOnPlay) {
      failOnPlay = failOnPlayRepeats > 0;
      if (failOnPlay) {
        failOnPlayRepeats--;
      } else {
        failLoadSongId = attemptedSongId;
      }
      // The player keeps `playing`; only the processing state fails.
      state = ProcessingState.idle;
      errorCode = 0;
      playbackEvents.add(playbackEvent);
    }
    if (playCompletesOnPause) {
      playbackEvents.add(playbackEvent);
      await (playCompleter = Completer<void>()).future;
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
    _logGains('load', sources);
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
    final clearedError = errorCode != null;
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
    queuedSources = List<AudioSource>.of(sources);
    lastSetAudioSourcesCount = sources.length;
    setAudioSourcesCounts.add(sources.length);
    index = sources.isEmpty ? null : initialIndex ?? 0;
    state = sources.isEmpty || !preload
        ? ProcessingState.idle
        : bufferAfterLoad
        ? ProcessingState.buffering
        : ProcessingState.ready;
    if (failAfterLoad) {
      // Like a native load: a loading event, then the error.
      playbackEvents.add(
        PlaybackEvent(
          processingState: ProcessingState.loading,
          currentIndex: index,
        ),
      );
      state = ProcessingState.idle;
      errorCode = 0;
      playbackEvents.add(playbackEvent);
    }
    if (source is IndexedAudioSource &&
        (source.tag as MediaItem?)?.extras?['bridgeFormat'] != null) {
      bridgeInitialPositions.add(initialPosition);
      if (rejectBridgeLoad) throw StateError('bridge load failed');
    }
    indexEvents.add(index);
    // A reload after a failure reports its error-free state, as native does.
    if (clearedError && errorCode == null) playbackEvents.add(playbackEvent);
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
    queuedSources.add(source);
  });

  @override
  Future<void> insertAudioSource(int at, AudioSource source) =>
      _mutate(() async {
        queuedSources.insert(at, source);
        if (index != null && at <= index!) index = index! + 1;
        indexEvents.add(index);
      });

  int batchMutationCount = 0;

  @override
  Future<void> moveAudioSource(int currentIndex, int newIndex) =>
      _mutate(() async {
        final before = playbackEvent;
        queuedSources.insert(newIndex, queuedSources.removeAt(currentIndex));
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
    _logGains('add', sources);
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
    queuedSources.addAll(sources);
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
        _logGains('insert', sources);
        await _hangIf('insertAudioSources');
        final gate = insertGate;
        insertGate = null;
        if (gate != null) {
          insertEntered?.complete();
          await gate.future;
        }
        final before = playbackEvent;
        batchMutationCount++;
        queuedSources.insertAll(at, sources);
        if (index != null && at <= index!) index = index! + sources.length;
        indexEvents.add(index);
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
    if (exoEndedSeek && state == ProcessingState.completed && index != null) {
      // ExoPlayer reports the new window while still STATE_ENDED, then
      // leaves ENDED (#374; a2-r4b transport trace seq 525 and 529).
      this.index = index;
      simulatedPosition = position ?? Duration.zero;
      playbackEvents.add(playbackEvent);
      indexEvents.add(index);
      await Future<void>.delayed(Duration.zero);
    }
    if ((exoEndedSeekLate || completedStaysOnSeek) &&
        state == ProcessingState.completed &&
        index != null) {
      this.index = index;
      simulatedPosition = position ?? Duration.zero;
      indexEvents.add(index);
      if (completedStaysOnSeek) {
        playbackEvents.add(playbackEvent);
        return;
      }
      Timer(
        const Duration(milliseconds: 20),
        () => playbackEvents.add(playbackEvent),
      );
      Timer(const Duration(milliseconds: 40), () {
        state = ProcessingState.ready;
        emitPlayerEvent();
        playbackEvents.add(playbackEvent);
      });
      return;
    }
    final ignored = ignoreSeeks || ignoredSeeks > 0;
    if (ignoredSeeks > 0) ignoredSeeks--;
    if (position != null && !ignored) {
      simulatedPosition = position;
      if (state == ProcessingState.completed && position < simulatedDuration) {
        state = ProcessingState.ready;
      }
    }
    final lag = seekIndexLag;
    if (index != null && lag != null) {
      if (!seekIndexNeverLands) {
        Timer(lag, () {
          if (disposed) return;
          this.index = index;
          indexEvents.add(index);
          emitPlayerEvent();
        });
      }
      emitPlayerEvent();
      return;
    }
    if (index != null) this.index = index;
    indexEvents.add(this.index);
    emitPlayerEvent();
  });

  @override
  Future<void> dispose() async {
    disposed = true;
    isPlaying = false;
    await positionPlayer?.dispose();
    await icyEvents?.close();
    if (!keepStreamsAfterDispose) {
      await indexEvents.close();
      await playbackEvents.close();
      await discontinuityEvents.close();
    }
  }
}

// Exercise the vendored timer, rather than inventing a fake position pipeline.
class HandlerPositionPlayer extends AudioPlayer {
  new(this.native)
    : super(handleInterruptions: false, handleAudioSessionActivation: false);

  final ControllableAudioPlayer native;
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
  final player = audioPlayer as ControllableAudioPlayer;
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
  final players = audioPlayers.cast<ControllableAudioPlayer>();
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
      handler.debugActivePlayer as ControllableAudioPlayer,
    );
  }
}

/// Collect listener failures so they cannot escape unnoticed as stream errors.
@visibleForTesting
Future<void> Function() watchAudioMetadata(
  NavisAudioHandler handler,
  List<AudioPlayer> audioPlayers,
) {
  final players = audioPlayers.cast<ControllableAudioPlayer>();
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

/// Waits until [cond] holds, polling every 5 ms, and fails with [reason] after
/// [cap]. The cap is generous because it costs nothing when [cond] holds.
/// Never use it on a baseline or unchanged value: that passes at once and
/// proves nothing. Keep a fixed window for "nothing more happened" checks.
@visibleForTesting
Future<void> until(
  bool Function() cond, {
  Duration cap = const Duration(seconds: 10),
  String? reason,
}) async {
  final elapsed = Stopwatch()..start();
  while (!cond() && elapsed.elapsed < cap) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(cond(), isTrue, reason: 'until timed out after $cap: $reason');
}

Future<(NavisAudioHandler, ControllableAudioPlayer, NavisDatabase)>
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
  List<ControllableAudioPlayer>? rebuiltPlayers,
  List<ControllableAudioPlayer>? players,
  FakeAsync? clock,
  Set<String>? hungLoadSongs,
  ScrobbleService? scrobbleService,
  String replayGainMode = 'off',
  String Function()? readReplayGainMode,
  double replayGainUntaggedDb = replayGainFallbackUntaggedDb,
  double Function()? readReplayGainUntaggedDb,
  bool? replayGainInPipeline,
  PlaybackAdjustmentCapabilities adjustmentCapabilities =
      PlaybackAdjustmentCapabilities.android,
  EqCapabilities? equalizerCapabilities,
  ControllableAudioPlayer? initialPlayer,
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
  StreamingQuality streamingQuality = const StreamingQuality(label: 'original'),
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
  final player = initialPlayer ?? ControllableAudioPlayer();
  if (positionStreams) player.positionPlayer = HandlerPositionPlayer(player);
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
    scrobbleService: scrobbleService ?? NoopScrobbleService(),
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
      replayGainMode: readReplayGainMode?.call() ?? replayGainMode,
      replayGainPreamp: 0,
      replayGainUntaggedDb:
          readReplayGainUntaggedDb?.call() ?? replayGainUntaggedDb,
      playbackSpeed: 1,
      albumQueueEnabled: false,
      matchFlowEnabled: matchFlow,
    ),
    adjustmentCapabilities: adjustmentCapabilities,
    replayGainInPipelineOverride: replayGainInPipeline,
    equalizerCapabilities: equalizerCapabilities,
    crossfadePlayerFactory: () {
      final deck = ControllableAudioPlayer();
      if (positionStreams) deck.positionPlayer = HandlerPositionPlayer(deck);
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
            final rebuilt = ControllableAudioPlayer()..simulateProgress = true;
            if (positionStreams) {
              rebuilt.positionPlayer = HandlerPositionPlayer(rebuilt);
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
          createHttpClient: (_) => ProbeClient(),
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

Map<String, Object?> fade(NavisAudioHandler handler) =>
    handler.collectPlaybackDiagnostics()['crossfade']! as Map<String, Object?>;
