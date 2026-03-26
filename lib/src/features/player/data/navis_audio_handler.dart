import 'dart:async';
import 'dart:math' as math;
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_mpris/audio_service_mpris.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/database/daos/history_dao.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/daos/play_queue_dao.dart';
import 'package:navis/src/database/daos/star_sync_dao.dart';
import 'package:navis/src/database/tables/schema_enums.dart' as schema;
import 'package:navis/src/features/cache/data/rolling_cache_manager.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/data/radio_metadata_service.dart';
import 'package:navis/src/features/player/data/scrobble_service.dart';
import 'package:navis/src/features/player/data/windows_smtc_bridge.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/utils/app_logger.dart';

abstract class NavisPlaybackHandler {
  PlaybackSnapshot get snapshot;
  Stream<PlaybackSnapshot> get snapshotStream;
  Stream<ManualTrackChangeCue> get manualTrackChangeCueStream;
  Stream<Duration> get positionStream;
  MediaItem? get currentMediaItem;
  Stream<MediaItem?> get mediaItemStream;

  /// Emits when a radio stream encounters a mid-playback error (e.g. HTTP 503,
  /// connection reset). The UI should show a dismissible error notification.
  Stream<void> get radioStreamErrorStream;

  Future<void> waitUntilReady();

  Future<void> replaceQueue(
    List<String> songIds, {
    int startIndex,
    bool autoPlay,
  });

  Future<void> addToQueue(List<String> songIds);
  Future<void> playNext(List<String> songIds);
  Future<void> playFromIndex(int index);
  Future<void> removeAt(int index);
  Future<void> reorderQueue(int oldIndex, int newIndex);
  Future<void> clearQueue();
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> skipToNext();
  Future<void> skipToPrevious();
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode);
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode);
  Future<void> setPlaybackSpeed(double speed);
  Future<void> setVolume(double volume);
  Future<void> applyRuntimeSettings();
  Future<void> toggleLike();

  /// Synchronise the liked state of every queue item whose id matches
  /// [songId].  Call this after an external star/unstar (e.g. from a context
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
  void updateRadioMetadata({
    String? title,
    String? artist,
    String? artUrl,
  });
}

class PlaybackRuntimeSettings {
  const PlaybackRuntimeSettings({
    required this.gaplessEnabled,
    required this.equalizerEnabled,
    required this.equalizerBandGains,
    required this.loudnessEnabled,
    required this.loudnessTargetGainDb,
    required this.crossfadeEnabled,
    required this.crossfadeDurationSeconds,
    required this.crossfadeType,
    required this.replayGainMode,
    required this.replayGainPreamp,
    required this.playbackSpeed,
  });

  const PlaybackRuntimeSettings.defaults()
    : gaplessEnabled = true,
      equalizerEnabled = false,
      equalizerBandGains = const <double>[],
      loudnessEnabled = false,
      loudnessTargetGainDb = 0,
      crossfadeEnabled = false,
      crossfadeDurationSeconds = 5,
      crossfadeType = 'normal',
      replayGainMode = 'off',
      replayGainPreamp = 0.0,
      playbackSpeed = 1.0;

  final bool gaplessEnabled;
  final bool equalizerEnabled;
  final List<double> equalizerBandGains;
  final bool loudnessEnabled;
  final double loudnessTargetGainDb;
  final bool crossfadeEnabled;
  final int crossfadeDurationSeconds;
  final String crossfadeType;

  /// ReplayGain mode: 'off', 'track', or 'album'.
  final String replayGainMode;

  /// ReplayGain pre-amp adjustment in dB (-6 to +6).
  final double replayGainPreamp;

  /// Playback speed multiplier (0.5–2.0).
  final double playbackSpeed;
}

@visibleForTesting
bool navisShouldPreloadQueue({
  required bool autoPlay,
  required bool preloadWhenPaused,
  required bool gaplessEnabled,
}) {
  return autoPlay || (preloadWhenPaused && gaplessEnabled);
}

@visibleForTesting
bool navisEffectiveGaplessEnabled({
  required bool gaplessEnabled,
  required bool crossfadeEnabled,
}) {
  return gaplessEnabled || crossfadeEnabled;
}

@visibleForTesting
bool navisIsAndroidDspInitializationFailure(
  Object error, {
  required bool isAndroidRuntime,
}) {
  if (!isAndroidRuntime) {
    return false;
  }
  final details = error is PlatformException
      ? '${error.code} ${error.message ?? ''} ${error.details ?? ''}'
      : error.toString();
  final normalized = details.toLowerCase();
  return normalized.contains('cannot initialize effect engine') ||
      (normalized.contains('audioeffect') &&
          normalized.contains('equalizer')) ||
      normalized.contains('0bed4300-ddd6-11db-8f34-0002a5d5c51b');
}

@visibleForTesting
bool navisShouldRetryQueueApplyWithDirectSources({
  required List<PlaybackSourceKind> sourceKinds,
  required Object error,
  required bool isAndroidRuntime,
}) {
  final usedLockCaching = sourceKinds.contains(
    PlaybackSourceKind.lockCachedStream,
  );
  final isDspFailure = navisIsAndroidDspInitializationFailure(
    error,
    isAndroidRuntime: isAndroidRuntime,
  );
  return usedLockCaching || isDspFailure;
}

@visibleForTesting
const List<int> navisNotificationCompactActionIndices = <int>[0, 1, 2];

@visibleForTesting
List<MediaControl> navisNotificationControls({required bool isPlaying}) {
  return <MediaControl>[
    MediaControl.skipToPrevious,
    if (isPlaying) MediaControl.pause else MediaControl.play,
    MediaControl.skipToNext,
  ];
}

@visibleForTesting
Duration navisSanitizeSeekPosition(Duration position) {
  if (position < Duration.zero) {
    return Duration.zero;
  }
  return position;
}

@visibleForTesting
double navisNormalizePlaybackSpeed(double speed) {
  return speed.clamp(0.5, 2.0);
}

@visibleForTesting
bool navisShouldRecoverSeekToDirectStream({
  required String? sourceKind,
  required Duration requestedPosition,
  required Duration actualPosition,
}) {
  if (sourceKind != PlaybackSourceKind.lockCachedStream.name) {
    return false;
  }
  if (requestedPosition <= const Duration(seconds: 2)) {
    return false;
  }
  final delta = (requestedPosition - actualPosition).abs();
  return actualPosition <= const Duration(seconds: 1) &&
      delta >= const Duration(seconds: 2);
}

@visibleForTesting
bool navisShouldSeekCrossfadeHandoff({
  required int? handoffTargetIndex,
  required int? currentIndex,
  required Duration jumpDelta,
  required Duration seekCorrectionThreshold,
}) {
  if (handoffTargetIndex != null && currentIndex != handoffTargetIndex) {
    return true;
  }
  return jumpDelta > seekCorrectionThreshold;
}

@visibleForTesting
bool navisShouldUseAndroidSequentialCrossfadeFallback({
  required bool isAndroidRuntime,
  required String? format,
  required int? sampleRate,
}) {
  if (!isAndroidRuntime) {
    return false;
  }

  final normalizedFormat = format?.trim().toLowerCase();
  final formatSubtype =
      normalizedFormat != null && normalizedFormat.contains('/')
      ? normalizedFormat.split('/').last
      : normalizedFormat;
  final canonicalFormat = switch (formatSubtype) {
    'x-flac' => 'flac',
    'x-wav' || 'wave' => 'wav',
    _ => formatSubtype,
  };
  final isLikelyLossless = switch (canonicalFormat) {
    'flac' || 'alac' || 'wav' || 'aiff' || 'ape' || 'dsf' || 'dff' => true,
    _ => false,
  };
  final resolvedSampleRate = sampleRate ?? 0;
  final isHighSampleRate = resolvedSampleRate >= 96000;
  final isHighRateLossless = isLikelyLossless && resolvedSampleRate >= 88200;
  return isHighSampleRate || isHighRateLossless;
}

typedef NavisPersistSafely =
    Future<void> Function(
      Future<void> Function() persistOperation, {
      required String context,
    });

@visibleForTesting
Future<void> navisPersistSafely(
  Future<void> Function() persistOperation, {
  required String context,
  required void Function(String message) logWarning,
}) async {
  try {
    await persistOperation();
  } on Object catch (error, stackTrace) {
    logWarning(
      'Playback state persistence failed during $context. '
      '$error\n$stackTrace',
    );
  }
}

@visibleForTesting
Future<void> navisRunTransportWithPersistence({
  required Future<void> Function() transportOperation,
  required Future<void> Function() persistOperation,
  required NavisPersistSafely persistSafely,
  required String persistenceContext,
}) async {
  await transportOperation();
  await persistSafely(persistOperation, context: persistenceContext);
}

@visibleForTesting
bool navisCanSkipQueueItem({
  required int queueLength,
  required int? currentIndex,
  required bool forward,
}) {
  if (queueLength <= 0 || currentIndex == null) {
    return false;
  }
  if (currentIndex < 0 || currentIndex >= queueLength) {
    return false;
  }
  if (forward) {
    return currentIndex < queueLength - 1;
  }
  return currentIndex > 0;
}

@visibleForTesting
Map<String, Object?> navisResolvedPlaybackExtras({
  required SongsTableData song,
  required ResolvedPlaybackSource source,
}) {
  return <String, Object?>{
    'albumId': song.albumId,
    'artistId': song.artistId,
    'sourceKind': source.kind.name,
    'localSource': source.isLocal,
    'cachedFilePath': source.cachedFilePath,
    'resolvedFormat': source.metadata.format,
    'resolvedBitRate': source.metadata.bitRate,
    'resolvedSampleRate': source.metadata.sampleRate,
    'transcodingApplied': source.metadata.isTranscoded,
    'liked': song.starred != null,
    'replayGainTrackGain': song.replayGainTrackGain,
    'replayGainAlbumGain': song.replayGainAlbumGain,
    'replayGainTrackPeak': song.replayGainTrackPeak,
    'replayGainAlbumPeak': song.replayGainAlbumPeak,
  };
}

Future<NavisPlaybackHandler>? _audioHandlerInitFuture;
bool _linuxMprisRegistered = false;

typedef NavisRegisterLinuxMpris = void Function();

@visibleForTesting
bool navisRegisterLinuxMprisIfSupported({
  required bool isLinuxRuntime,
  required NavisRegisterLinuxMpris registerMpris,
  required void Function(String message) logInfo,
  required void Function(String message) logWarning,
}) {
  if (!isLinuxRuntime) {
    return false;
  }
  try {
    registerMpris();
    logInfo('Linux MPRIS integration registered via audio_service_mpris.');
    return true;
  } on Object catch (error, stackTrace) {
    logWarning(
      'Linux MPRIS registration failed. '
      'Playback will continue without desktop media controls. '
      '$error\n$stackTrace',
    );
    return false;
  }
}

Future<void> disposeNavisPlaybackHandler(NavisPlaybackHandler handler) async {
  if (handler is WindowsNavisPlaybackHandler) {
    await handler.dispose();
    return;
  }
  if (handler is NavisAudioHandler) {
    await handler.disposeHandler();
  }
}

void beginNavisPlaybackHandlerTeardown(NavisPlaybackHandler handler) {
  if (handler is WindowsNavisPlaybackHandler) {
    handler.beginTeardown();
    return;
  }
  if (handler is NavisAudioHandler) {
    handler.beginTeardown();
  }
}

Future<NavisPlaybackHandler> initNavisAudioHandler({
  required LibraryDao libraryDao,
  required PlayQueueDao playQueueDao,
  required HistoryDao historyDao,
  required PlaybackSourceResolver sourceResolver,
  required SubsonicApiClient? Function() readApiClient,
  required RollingCacheManager rollingCacheManager,
  required int rollingCacheBudgetBytes,
  required ScrobbleService scrobbleService,
  required PlaybackRuntimeSettings Function() readRuntimeSettings,
  required StarSyncDao starSyncDao,
}) {
  final cachedFuture = _audioHandlerInitFuture;
  if (cachedFuture != null) {
    return cachedFuture;
  }

  NavisAudioHandler createBaseHandler() {
    return NavisAudioHandler(
      libraryDao: libraryDao,
      playQueueDao: playQueueDao,
      historyDao: historyDao,
      sourceResolver: sourceResolver,
      readApiClient: readApiClient,
      rollingCacheManager: rollingCacheManager,
      rollingCacheBudgetBytes: rollingCacheBudgetBytes,
      scrobbleService: scrobbleService,
      readRuntimeSettings: readRuntimeSettings,
      starSyncDao: starSyncDao,
    );
  }

  late final Future<NavisPlaybackHandler> initFuture;
  if (_isWindowsRuntime) {
    // Windows currently bypasses audio_service runtime integration.
    initFuture = Future<NavisPlaybackHandler>.value(
      WindowsNavisPlaybackHandler(createBaseHandler()),
    );
  } else {
    if (!_linuxMprisRegistered) {
      final registered = navisRegisterLinuxMprisIfSupported(
        isLinuxRuntime: _isLinuxRuntime,
        registerMpris: AudioServiceMpris.registerWith,
        logInfo: AppLogger.info,
        logWarning: AppLogger.warning,
      );
      if (registered) {
        _linuxMprisRegistered = true;
      }
    }
    initFuture = AudioService.init(
      builder: createBaseHandler,
      config: AudioServiceConfig(
        androidNotificationChannelId: 'playback',
        androidNotificationChannelName: 'Playback',
        androidNotificationIcon: 'drawable/ic_stat_navis_light',
        androidNotificationOngoing: false,
        androidStopForegroundOnPause: false,
      ),
    ).then<NavisPlaybackHandler>((handler) => handler);
  }

  _audioHandlerInitFuture = initFuture;
  unawaited(
    initFuture.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_audioHandlerInitFuture, initFuture)) {
          _audioHandlerInitFuture = null;
        }
      },
    ),
  );
  return initFuture;
}

class WindowsNavisPlaybackHandler implements NavisPlaybackHandler {
  WindowsNavisPlaybackHandler(this._delegate) {
    _smtcBridge = WindowsSmtcBridge(handler: this);
  }

  final NavisAudioHandler _delegate;
  late final WindowsSmtcBridge _smtcBridge;

  void beginTeardown() {
    _delegate.beginTeardown();
    unawaited(_smtcBridge.dispose());
  }

  Future<void> dispose() async {
    await _smtcBridge.dispose();
    await _delegate.disposeHandler();
  }

  @override
  PlaybackSnapshot get snapshot => _delegate.snapshot;

  @override
  Stream<PlaybackSnapshot> get snapshotStream => _delegate.snapshotStream;

  @override
  Stream<ManualTrackChangeCue> get manualTrackChangeCueStream =>
      _delegate.manualTrackChangeCueStream;

  @override
  Stream<Duration> get positionStream => _delegate.positionStream;

  @override
  MediaItem? get currentMediaItem => _delegate.currentMediaItem;

  @override
  Stream<MediaItem?> get mediaItemStream => _delegate.mediaItemStream;

  @override
  Stream<void> get radioStreamErrorStream => _delegate.radioStreamErrorStream;

  @override
  Future<void> waitUntilReady() => _delegate.waitUntilReady();

  @override
  Future<void> replaceQueue(
    List<String> songIds, {
    int startIndex = 0,
    bool autoPlay = true,
  }) => _delegate.replaceQueue(
    songIds,
    startIndex: startIndex,
    autoPlay: autoPlay,
  );

  @override
  Future<void> addToQueue(List<String> songIds) =>
      _delegate.addToQueue(songIds);

  @override
  Future<void> playNext(List<String> songIds) => _delegate.playNext(songIds);

  @override
  Future<void> playFromIndex(int index) => _delegate.playFromIndex(index);

  @override
  Future<void> removeAt(int index) => _delegate.removeAt(index);

  @override
  Future<void> reorderQueue(int oldIndex, int newIndex) =>
      _delegate.reorderQueue(oldIndex, newIndex);

  @override
  Future<void> clearQueue() => _delegate.clearQueue();

  @override
  Future<void> play() => _delegate.play();

  @override
  Future<void> pause() => _delegate.pause();

  @override
  Future<void> seek(Duration position) => _delegate.seek(position);

  @override
  Future<void> skipToNext() => _delegate.skipToNext();

  @override
  Future<void> skipToPrevious() => _delegate.skipToPrevious();

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) =>
      _delegate.setShuffleMode(shuffleMode);

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) =>
      _delegate.setRepeatMode(repeatMode);

  @override
  Future<void> setPlaybackSpeed(double speed) =>
      _delegate.setPlaybackSpeed(speed);

  @override
  Future<void> setVolume(double volume) => _delegate.setVolume(volume);

  @override
  Future<void> applyRuntimeSettings() => _delegate.applyRuntimeSettings();

  @override
  Future<void> toggleLike() => _delegate.toggleLike();

  @override
  Future<void> syncSongLikedState(String songId, {required bool liked}) =>
      _delegate.syncSongLikedState(songId, liked: liked);

  @override
  Future<void> playRadioStream({
    required String stationId,
    required String stationName,
    required String streamUrl,
    String? homePageUrl,
  }) => _delegate.playRadioStream(
    stationId: stationId,
    stationName: stationName,
    streamUrl: streamUrl,
    homePageUrl: homePageUrl,
  );

  @override
  Future<void> stopRadio() => _delegate.stopRadio();

  @override
  void updateRadioMetadata({
    String? title,
    String? artist,
    String? artUrl,
  }) => _delegate.updateRadioMetadata(
    title: title,
    artist: artist,
    artUrl: artUrl,
  );
}

class NavisAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler
    implements NavisPlaybackHandler {
  NavisAudioHandler({
    required LibraryDao libraryDao,
    required PlayQueueDao playQueueDao,
    required HistoryDao historyDao,
    required PlaybackSourceResolver sourceResolver,
    required SubsonicApiClient? Function() readApiClient,
    required RollingCacheManager rollingCacheManager,
    required int rollingCacheBudgetBytes,
    required ScrobbleService scrobbleService,
    required PlaybackRuntimeSettings Function() readRuntimeSettings,
    required StarSyncDao starSyncDao,
    AudioPlayer? player,
  }) : _libraryDao = libraryDao,
       _playQueueDao = playQueueDao,
       _historyDao = historyDao,
       _sourceResolver = sourceResolver,
       _readApiClient = readApiClient,
       _rollingCacheManager = rollingCacheManager,
       _rollingCacheBudgetBytes = rollingCacheBudgetBytes,
       _scrobbleService = scrobbleService,
       _readRuntimeSettings = readRuntimeSettings,
       _starSyncDao = starSyncDao {
    final runtime = _readRuntimeSettings();
    if (player != null) {
      _androidDspPipelineEnabled = false;
      _androidEqualizer = null;
      _androidLoudnessEnhancer = null;
      _player = player;
    } else {
      _androidDspPipelineEnabled =
          _isAndroidRuntime &&
          (runtime.equalizerEnabled || runtime.loudnessEnabled);
      _player = _buildAudioPlayer(enableAndroidDsp: _androidDspPipelineEnabled);
    }
    _crossfadePlayer = _buildBaseAudioPlayer();
    _radioMetadataService = RadioMetadataService(
      handler: this,
      player: _player,
    );
    _wirePlayerListeners();
    _positionPersistTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(
        _persistSafely(_persistPosition, context: 'periodic position timer'),
      ),
    );
    _ready = _initialize();
  }

  final LibraryDao _libraryDao;
  final PlayQueueDao _playQueueDao;
  final HistoryDao _historyDao;
  final PlaybackSourceResolver _sourceResolver;
  final SubsonicApiClient? Function() _readApiClient;
  final RollingCacheManager _rollingCacheManager;
  final int _rollingCacheBudgetBytes;
  final ScrobbleService _scrobbleService;
  final PlaybackRuntimeSettings Function() _readRuntimeSettings;
  final StarSyncDao _starSyncDao;
  late AudioPlayer _player;
  AndroidEqualizer? _androidEqualizer;
  AndroidLoudnessEnhancer? _androidLoudnessEnhancer;
  bool _androidDspPipelineEnabled = false;

  final StreamController<PlaybackSnapshot> _snapshotController =
      StreamController<PlaybackSnapshot>.broadcast();
  final StreamController<ManualTrackChangeCue> _manualTrackChangeCueController =
      StreamController<ManualTrackChangeCue>.broadcast();

  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();

  final StreamController<void> _radioStreamErrorController =
      StreamController<void>.broadcast();

  final List<MediaItem> _queueItems = <MediaItem>[];
  MediaItem? _currentMediaItem;

  PlaybackSnapshot _snapshot = const PlaybackSnapshot.idle();
  Timer? _positionPersistTimer;
  late final Future<void> _ready;
  Future<void> _inFlight = Future<void>.value();
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _becomingNoisySubscription;
  StreamSubscription<PlaybackEvent>? _playbackEventSubscription;
  StreamSubscription<int?>? _currentIndexSubscription;
  StreamSubscription<bool>? _shuffleModeSubscription;
  StreamSubscription<LoopMode>? _loopModeSubscription;
  StreamSubscription<Duration>? _activePositionSubscription;
  final Map<String, StreamSubscription<double>> _cacheProgressSubscriptions =
      <String, StreamSubscription<double>>{};
  bool _isDucked = false;
  // The most-recently requested user volume (0–1). Used as the reference level
  // for ducking and crossfade restoration so track changes never override the
  // user's chosen volume.
  double _userVolume = 1.0;
  bool _resumeAfterInterruption = false;
  bool _gaplessEnabled = true;
  String? _activeScrobbleQueueToken;
  String? _activeScrobbleSongId;
  String? _activeScrobbleSessionKey;
  bool _sentNowPlayingScrobble = false;
  bool _sentSubmissionScrobble = false;

  // ── Cross-fade state ──────────────────────────────────────────────────────
  bool _crossfadeEnabled = false;
  int _crossfadeDurationSeconds = 5;
  String _crossfadeType = 'normal';
  static const Duration _crossfadePrepareLeadTime = Duration(
    milliseconds: 1800,
  );
  static const double _volumeNoopEpsilon = 0.01;
  AudioPlayer? _crossfadePlayer;
  Timer? _crossfadeFadeTimer;
  Timer? _crossfadeFallbackTimer;
  bool _isCrossfading = false;
  bool _crossfadeHandoffInProgress = false;
  Future<void>? _crossfadeCompletionFuture;
  StreamSubscription<Duration>? _crossfadePositionSub;
  int _crossfadeSessionToken = 0;
  int? _crossfadeActiveTransitionId;
  int? _crossfadePrewarmLatencyMs;
  DateTime? _crossfadeFadeStartedAt;
  int _manualTrackChangeCueToken = 0;

  /// The queue index of the track loaded on `_crossfadePlayer`.
  int? _crossfadeTargetIndex;

  /// Non-null while a radio stream is active.
  RadioStationMetadata? _radioStation;

  /// Manages ICY / Azuracast metadata polling for radio streams.
  late RadioMetadataService _radioMetadataService;
  Future<void>? _playerDisposalFuture;
  bool _disposeHandlerStarted = false;
  bool _disposeHandlerCompleted = false;

  @override
  PlaybackSnapshot get snapshot => _snapshot;

  @override
  Stream<PlaybackSnapshot> get snapshotStream => _snapshotController.stream;

  @override
  Stream<ManualTrackChangeCue> get manualTrackChangeCueStream =>
      _manualTrackChangeCueController.stream;

  @override
  Stream<void> get radioStreamErrorStream => _radioStreamErrorController.stream;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  MediaItem? get currentMediaItem => _currentMediaItem;

  @override
  Stream<MediaItem?> get mediaItemStream => mediaItem;

  @override
  Future<void> waitUntilReady() => _ready;

  void _setCurrentMediaItem(MediaItem? item) {
    _currentMediaItem = item;
    mediaItem.add(item);
  }

  AudioPlayer _buildAudioPlayer({required bool enableAndroidDsp}) {
    if (_isAndroidRuntime && enableAndroidDsp) {
      _androidEqualizer = AndroidEqualizer();
      _androidLoudnessEnhancer = AndroidLoudnessEnhancer();
      return _buildBaseAudioPlayer(
        audioPipeline: AudioPipeline(
          androidAudioEffects: [
            _androidEqualizer!,
            _androidLoudnessEnhancer!,
          ],
        ),
      );
    }

    _androidEqualizer = null;
    _androidLoudnessEnhancer = null;
    return _buildBaseAudioPlayer();
  }

  AudioPlayer _buildBaseAudioPlayer({AudioPipeline? audioPipeline}) {
    // On desktop media_kit/mpv, prefer proxy-based requests so libmpv consumes
    // local HTTP and avoids remote TLS/cache edge cases from some servers.
    final desktopProxy = _isDesktopRuntime;
    return AudioPlayer(
      audioPipeline: audioPipeline,
      userAgent: desktopProxy ? 'Navis Desktop' : null,
      useProxyForRequestHeaders: desktopProxy,
    );
  }

  Future<void> _initialize() async {
    AppLogger.info('Audio handler init: start.');
    if (_supportsAudioSessionRuntime) {
      final session = await AudioSession.instance;
      AppLogger.info('Audio handler init: audio session acquired.');
      await session.configure(const AudioSessionConfiguration.music());
      AppLogger.info('Audio handler init: audio session configured.');
      _wireAudioSession(session);
    } else {
      AppLogger.info(
        'Audio handler init: audio_session integration skipped on this platform.',
      );
    }
    try {
      // Keep startup readiness strict: runtime settings should be applied before
      // exposing the handler as fully ready.
      await applyRuntimeSettings();
      AppLogger.info('Audio handler init: runtime settings applied.');
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Runtime playback settings apply failed during startup: '
        '$error\n$stackTrace',
      );
    }
    unawaited(
      () async {
        try {
          await _rollingCacheManager.pruneMissingFiles();
          await _rollingCacheManager.pruneMissingPermanentFiles();
          await _rollingCacheManager.cleanupOrphanedRollingFiles();
          await _rollingCacheManager.enforceBudget(
            maxBytes: _rollingCacheBudgetBytes,
          );
        } on Object catch (error, stackTrace) {
          AppLogger.warning(
            'Cache maintenance failed during startup: '
            '$error\n$stackTrace',
          );
        }
      }(),
    );
    unawaited(
      _scrobbleService.flushDue().catchError((Object error, StackTrace stack) {
        AppLogger.warning(
          'Scrobble flush failed during startup: $error\n$stack',
        );
      }),
    );

    await _restoreQueueAfterStartup();
    _emitSnapshot();
    AppLogger.info('Audio handler init: ready.');
  }

  Future<void> _restoreQueueAfterStartup() async {
    await _runSerialized(() async {
      try {
        await _restoreQueueFromDisk().timeout(const Duration(seconds: 10));
      } on TimeoutException catch (error, stackTrace) {
        AppLogger.warning(
          'Queue restore timed out during startup. '
          'Clearing persisted queue to unblock playback startup. '
          '$error\n$stackTrace',
        );
        await _clearPersistedQueueBestEffort();
      } on Object catch (error, stackTrace) {
        AppLogger.error(
          'Queue restore failed. Clearing persisted queue to keep playback functional.',
          error,
          stackTrace,
        );
        await _clearPersistedQueueBestEffort();
      }
    });
  }

  Future<void> _clearPersistedQueueBestEffort() async {
    try {
      await _playQueueDao.clearQueue();
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Persisted queue clear failed during startup fallback: '
        '$error\n$stackTrace',
      );
    }
  }

  void _wireAudioSession(AudioSession session) {
    _interruptionSubscription = session.interruptionEventStream.listen((event) {
      if (event.begin) {
        if (event.type == AudioInterruptionType.duck) {
          if (!_isDucked) {
            _isDucked = true;
            unawaited(
              _player.setVolume((_userVolume * 2 / 5).clamp(0, 1)),
            );
          }
          return;
        }
        _resumeAfterInterruption = _player.playing;
        unawaited(_player.pause());
        return;
      }

      if (event.type == AudioInterruptionType.duck) {
        if (_isDucked) {
          _isDucked = false;
          unawaited(_player.setVolume(_userVolume));
        }
        return;
      }

      final shouldResume = _resumeAfterInterruption && !_player.playing;
      _resumeAfterInterruption = false;
      if (shouldResume) {
        unawaited(_player.play());
      }
    });

    _becomingNoisySubscription = session.becomingNoisyEventStream.listen((_) {
      if (_player.playing) {
        unawaited(_player.pause());
      }
    });
  }

  void _wirePlayerListeners() {
    _playbackEventSubscription = _player.playbackEventStream.listen(
      (_) {
        _handleScrobbleSignals();
        _broadcastPlaybackState();
        _emitSnapshot();
      },
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.error('Playback event stream error.', error, stackTrace);
        // If a radio stream is active, stop it and notify the UI.
        if (_radioStation != null) {
          _radioStreamErrorController.add(null);
          unawaited(stopRadio());
        }
      },
    );

    _currentIndexSubscription = _player.currentIndexStream.listen((index) {
      final item = _mediaItemForIndex(index);
      if (item != null) {
        _setCurrentMediaItem(item);
      } else if (_queueItems.isEmpty ||
          _player.processingState == ProcessingState.idle) {
        // Clear only when playback has no active queue/source. Keep the last
        // known item during transient index gaps so UI metadata stays stable.
        _setCurrentMediaItem(null);
      }
      _updateScrobbleSession(item);
      _applyReplayGainVolume();
      _emitSnapshot();
      unawaited(
        _persistSafely(
          () => _persistQueueState(includePosition: false),
          context: 'current index update',
        ),
      );
    });

    _shuffleModeSubscription = _player.shuffleModeEnabledStream.listen((_) {
      _broadcastPlaybackState();
      unawaited(
        _persistSafely(
          () => _persistQueueState(includePosition: false),
          context: 'shuffle mode stream update',
        ),
      );
    });

    _loopModeSubscription = _player.loopModeStream.listen((_) {
      _broadcastPlaybackState();
      unawaited(
        _persistSafely(
          () => _persistQueueState(includePosition: false),
          context: 'loop mode stream update',
        ),
      );
    });

    _activePositionSubscription = _player
        .createPositionStream(
          minPeriod: const Duration(milliseconds: 100),
          maxPeriod: const Duration(milliseconds: 200),
        )
        .listen((position) {
          if (!_positionController.isClosed) {
            _positionController.add(position);
          }
        });

    // Position monitoring for cross-fade triggering.
    _crossfadePositionSub = _player
        .createPositionStream(
          minPeriod: const Duration(milliseconds: 250),
          maxPeriod: const Duration(milliseconds: 500),
        )
        .listen(_checkCrossfadeTrigger);
  }

  Future<void> _disposePlayerListeners() async {
    await _playbackEventSubscription?.cancel();
    await _currentIndexSubscription?.cancel();
    await _shuffleModeSubscription?.cancel();
    await _loopModeSubscription?.cancel();
    await _activePositionSubscription?.cancel();
    await _crossfadePositionSub?.cancel();
    _playbackEventSubscription = null;
    _currentIndexSubscription = null;
    _shuffleModeSubscription = null;
    _loopModeSubscription = null;
    _activePositionSubscription = null;
    _crossfadePositionSub = null;
  }

  // ── Cross-fade logic ────────────────────────────────────────────────────

  /// Called on every position tick to decide whether to begin cross-fading.
  void _checkCrossfadeTrigger(Duration position) {
    if (!_crossfadeEnabled ||
        _isCrossfading ||
        _radioStation != null ||
        !_player.playing) {
      return;
    }

    final duration = _player.duration;
    if (duration == null || duration == Duration.zero) {
      return;
    }

    final fadeDuration = Duration(seconds: _crossfadeDurationSeconds);
    // Don't cross-fade if the track is shorter than 2× the fade duration.
    if (duration < fadeDuration * 2) {
      return;
    }

    final remaining = duration - position;
    if (remaining > fadeDuration + _crossfadePrepareLeadTime) {
      return;
    }
    final delayBeforeFade = remaining > fadeDuration
        ? remaining - fadeDuration
        : Duration.zero;

    // Don't cross-fade when repeating one track.
    if (_player.loopMode == LoopMode.one) {
      return;
    }

    final nextIndex = _getNextEffectiveIndex();
    if (nextIndex == null) {
      return;
    }

    // Smart mode: only cross-fade between tracks from different albums.
    if (_crossfadeType == 'smart') {
      final currentAlbumId =
          _queueItems[_player.currentIndex ?? 0].extras?['albumId'] as String?;
      final nextAlbumId = _queueItems[nextIndex].extras?['albumId'] as String?;
      if (currentAlbumId != null &&
          nextAlbumId != null &&
          currentAlbumId == nextAlbumId) {
        return;
      }
    }

    unawaited(_startCrossfade(nextIndex, delayBeforeFade: delayBeforeFade));
  }

  /// Returns the effective queue index of the next track, accounting for
  /// shuffle and loop modes. Returns `null` when there is no next track.
  int? _getNextEffectiveIndex() {
    final currentIndex = _player.currentIndex;
    if (currentIndex == null || _queueItems.isEmpty) {
      return null;
    }

    final effectiveIndices = _player.effectiveIndices;
    if (effectiveIndices.isEmpty) {
      return null;
    }

    final positionInOrder = effectiveIndices.indexOf(currentIndex);
    if (positionInOrder < 0) {
      return null;
    }

    if (positionInOrder < effectiveIndices.length - 1) {
      return effectiveIndices[positionInOrder + 1];
    }

    // At the end of the queue – only wrap if looping all.
    if (_player.loopMode == LoopMode.all && effectiveIndices.isNotEmpty) {
      return effectiveIndices.first;
    }
    return null;
  }

  /// Start a cross-fade transition to the track at [nextIndex].
  Future<void> _startCrossfade(
    int nextIndex, {
    required Duration delayBeforeFade,
  }) async {
    final cfPlayer = _crossfadePlayer;
    if (_isCrossfading || cfPlayer == null) {
      return;
    }
    _isCrossfading = true;
    _crossfadeHandoffInProgress = false;
    _crossfadeTargetIndex = nextIndex;
    final sessionToken = ++_crossfadeSessionToken;
    _crossfadeActiveTransitionId = sessionToken;
    _crossfadePrewarmLatencyMs = null;
    _crossfadeFadeStartedAt = null;
    final prewarmStopwatch = Stopwatch()..start();
    AppLogger.debug(
      'Cross-fade start: from=${_player.currentIndex} to=$nextIndex '
      'duration=${_crossfadeDurationSeconds}s token=$sessionToken',
    );

    try {
      await _prepareInactiveDeckForCrossfade(
        player: cfPlayer,
        nextIndex: nextIndex,
      );
      prewarmStopwatch.stop();
      _crossfadePrewarmLatencyMs = prewarmStopwatch.elapsedMilliseconds;
      if (!_isCrossfadeSessionActive(sessionToken, nextIndex)) {
        return;
      }
      if (delayBeforeFade > Duration.zero) {
        AppLogger.debug(
          'Cross-fade prewarm ready: delaying fade start by '
          '${delayBeforeFade.inMilliseconds}ms '
          '(target=$nextIndex token=$sessionToken).',
        );
        await Future<void>.delayed(delayBeforeFade);
      }
      if (!_isCrossfadeSessionActive(sessionToken, nextIndex)) {
        return;
      }
      _armCrossfadeFallbackTimeout(
        nextIndex: nextIndex,
        sessionToken: sessionToken,
      );
      _crossfadeFadeStartedAt = DateTime.now();
      unawaited(cfPlayer.play());
      AppLogger.debug(
        'Cross-fade secondary player started: '
        'target=$nextIndex sourceKind=deckMirror token=$sessionToken',
      );
      _startCrossfadeFadeLoop(
        cfPlayer: cfPlayer,
        nextIndex: nextIndex,
        sessionToken: sessionToken,
      );
    } on Object catch (error, stackTrace) {
      if (_isCrossfadeSessionActive(sessionToken, nextIndex)) {
        AppLogger.warning(
          'Cross-fade start failed. Degrading to gapless transition. '
          '$error\n$stackTrace',
        );
        _emitCrossfadeMetric(
          transitionId: sessionToken,
          targetIndex: nextIndex,
          phase: 'prewarm_failed',
          fallbackReason: 'prewarm_failed',
          canceledReason: error.runtimeType.toString(),
        );
        _cancelCrossfade();
      }
    }
  }

  bool _isCrossfadeSessionActive(int sessionToken, int nextIndex) {
    return _isCrossfading &&
        _crossfadeSessionToken == sessionToken &&
        _crossfadeTargetIndex == nextIndex;
  }

  void _armCrossfadeFallbackTimeout({
    required int nextIndex,
    required int sessionToken,
  }) {
    _crossfadeFallbackTimer?.cancel();
    final fadeDuration = Duration(seconds: _crossfadeDurationSeconds);
    final timeout = fadeDuration + const Duration(milliseconds: 2000);
    _crossfadeFallbackTimer = Timer(timeout, () {
      if (!_isCrossfadeSessionActive(sessionToken, nextIndex)) {
        return;
      }
      AppLogger.warning(
        'Cross-fade fallback timed out waiting for finalize completion '
        '(target=$nextIndex token=$sessionToken timeout=${timeout.inMilliseconds}ms). '
        'Degrading to gapless.',
      );
      _emitCrossfadeMetric(
        transitionId: sessionToken,
        targetIndex: nextIndex,
        phase: 'timeout',
        fallbackReason: 'finalize_timeout',
      );
      _cancelCrossfade();
    });
  }

  void _startCrossfadeFadeLoop({
    required AudioPlayer cfPlayer,
    required int nextIndex,
    required int sessionToken,
  }) {
    // Start a periodic fade timer.
    final fadeDurationMs = _crossfadeDurationSeconds * 1000;
    final finalizeAtMs = fadeDurationMs;
    final startTime = DateTime.now();
    _crossfadeFadeTimer?.cancel();
    _crossfadeFadeTimer = Timer.periodic(
      const Duration(milliseconds: 50),
      (timer) {
        if (!_isCrossfadeSessionActive(sessionToken, nextIndex) ||
            !identical(_crossfadePlayer, cfPlayer)) {
          timer.cancel();
          return;
        }
        if (_crossfadeHandoffInProgress) {
          timer.cancel();
          return;
        }

        final elapsed = DateTime.now().difference(startTime).inMilliseconds;
        final progress = (elapsed / fadeDurationMs).clamp(0.0, 1.0);

        // If the main player is ducked, respect that by scaling the
        // outgoing volume relative to the duck level.
        final outgoingBase = _isDucked ? _userVolume * 2 / 5 : _userVolume;
        final incomingBase = _isDucked ? _userVolume * 2 / 5 : _userVolume;
        unawaited(
          _player.setVolume(
            (outgoingBase * (1.0 - progress)).clamp(0.0, 1.0),
          ),
        );
        unawaited(
          cfPlayer.setVolume((incomingBase * progress).clamp(0.0, 1.0)),
        );

        if (elapsed >= finalizeAtMs || progress >= 1.0) {
          timer.cancel();
          AppLogger.debug(
            'Cross-fade fade loop reached finalize point: '
            'elapsed=${elapsed}ms finalizeAt=${finalizeAtMs}ms '
            '(target=$nextIndex token=$sessionToken).',
          );
          unawaited(
            _finalizeCrossfadeAfterFade(
              nextIndex: nextIndex,
              sessionToken: sessionToken,
              cfPlayer: cfPlayer,
            ),
          );
        }
      },
    );
  }

  Future<void> _finalizeCrossfadeAfterFade({
    required int nextIndex,
    required int sessionToken,
    required AudioPlayer cfPlayer,
  }) async {
    if (!_isCrossfadeSessionActive(sessionToken, nextIndex) ||
        !identical(_crossfadePlayer, cfPlayer)) {
      return;
    }
    AppLogger.debug(
      'Cross-fade finalize: deck swap completion '
      '(current=${_player.currentIndex} target=$nextIndex token=$sessionToken).',
    );
    if (!_isCrossfadeSessionActive(sessionToken, nextIndex) ||
        !identical(_crossfadePlayer, cfPlayer)) {
      return;
    }
    await _completeCrossfade();
  }

  Future<void> _completeCrossfade() async {
    final inFlight = _crossfadeCompletionFuture;
    if (inFlight != null) {
      return inFlight;
    }
    final future = _completeCrossfadeInternal();
    _crossfadeCompletionFuture = future;
    try {
      await future;
    } finally {
      if (identical(_crossfadeCompletionFuture, future)) {
        _crossfadeCompletionFuture = null;
      }
    }
  }

  Future<void> _completeCrossfadeInternal() async {
    final cfPlayer = _crossfadePlayer;
    final handoffTargetIndex = _crossfadeTargetIndex;
    final transitionId = _crossfadeActiveTransitionId ?? _crossfadeSessionToken;
    final fadeElapsedMs = _crossfadeFadeStartedAt == null
        ? null
        : DateTime.now().difference(_crossfadeFadeStartedAt!).inMilliseconds;
    _crossfadeHandoffInProgress = true;
    _crossfadeFadeTimer?.cancel();
    _crossfadeFadeTimer = null;
    _crossfadeFallbackTimer?.cancel();
    _crossfadeFallbackTimer = null;
    _crossfadeSessionToken += 1;

    if (cfPlayer == null) {
      AppLogger.debug(
        'Cross-fade completion skipped: secondary player absent.',
      );
      _emitCrossfadeMetric(
        transitionId: transitionId,
        targetIndex: handoffTargetIndex,
        phase: 'missing_incoming_player',
        fallbackReason: 'incoming_absent',
        fadeElapsedMs: fadeElapsedMs,
      );
      AppLogger.debug(
        'Cross-fade complete: degraded to gapless on main player '
        '(index=${_player.currentIndex}).',
      );
      _isCrossfading = false;
      _crossfadeTargetIndex = null;
      _crossfadeActiveTransitionId = null;
      _crossfadePrewarmLatencyMs = null;
      _crossfadeFadeStartedAt = null;
      _applyReplayGainVolume(forceDuringCrossfade: true);
      return;
    }

    final sw = Stopwatch()..start();
    try {
      final outgoingPlayer = _player;
      final incomingPlayer = cfPlayer;
      final mainTargetVolume = _isDucked
          ? (_userVolume * 2 / 5).clamp(0.0, 1.0)
          : _userVolume;
      await _setVolumeIfChanged(incomingPlayer, mainTargetVolume);
      await _setVolumeIfChanged(outgoingPlayer, 0);

      await _disposePlayerListeners();
      _player = incomingPlayer;
      _crossfadePlayer = outgoingPlayer;
      _wirePlayerListeners();
      _rebindRadioMetadataServiceToActivePlayer();

      try {
        await _crossfadePlayer?.pause();
      } on Object {
        // Best-effort reset only.
      }
      await _setVolumeIfChanged(_crossfadePlayer!, 0);
      sw.stop();

      AppLogger.debug(
        'Cross-fade complete: deck swap at ${_player.position.inMilliseconds}ms '
        '(swap=${sw.elapsedMilliseconds}ms '
        'currentIndex=${_player.currentIndex} targetIndex=$handoffTargetIndex).',
      );
      _emitCrossfadeMetric(
        transitionId: transitionId,
        targetIndex: handoffTargetIndex,
        phase: 'completed',
        swapLatencyMs: sw.elapsedMilliseconds,
        fadeElapsedMs: fadeElapsedMs,
      );
      _applyReplayGainVolume(forceDuringCrossfade: true);
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Cross-fade completion failed: $error\n$stackTrace',
      );
      _emitCrossfadeMetric(
        transitionId: transitionId,
        targetIndex: handoffTargetIndex,
        phase: 'completion_failed',
        fallbackReason: 'completion_failed',
        canceledReason: error.runtimeType.toString(),
        fadeElapsedMs: fadeElapsedMs,
      );
    } finally {
      _isCrossfading = false;
      _crossfadeHandoffInProgress = false;
      _crossfadeTargetIndex = null;
      _crossfadeActiveTransitionId = null;
      _crossfadePrewarmLatencyMs = null;
      _crossfadeFadeStartedAt = null;
      _applyReplayGainVolume(forceDuringCrossfade: true);
    }
  }

  Future<void> _setVolumeIfChanged(AudioPlayer player, double target) async {
    if ((player.volume - target).abs() <= _volumeNoopEpsilon) {
      return;
    }
    await player.setVolume(target);
  }

  /// Abort an in-progress cross-fade without completing the hand-off.
  void _cancelCrossfade() {
    final hasActiveCrossfade =
        _isCrossfading ||
        _crossfadeFadeTimer != null ||
        _crossfadeFallbackTimer != null ||
        _crossfadeTargetIndex != null;
    if (!hasActiveCrossfade) {
      return;
    }
    _crossfadeFadeTimer?.cancel();
    _crossfadeFadeTimer = null;
    _crossfadeFallbackTimer?.cancel();
    _crossfadeFallbackTimer = null;
    final transitionId = _crossfadeActiveTransitionId ?? _crossfadeSessionToken;
    _crossfadeSessionToken += 1;
    _isCrossfading = false;
    _crossfadeHandoffInProgress = false;
    _emitCrossfadeMetric(
      transitionId: transitionId,
      targetIndex: _crossfadeTargetIndex,
      phase: 'canceled',
      canceledReason: 'explicit_cancel',
      fadeElapsedMs: _crossfadeFadeStartedAt == null
          ? null
          : DateTime.now().difference(_crossfadeFadeStartedAt!).inMilliseconds,
    );
    _crossfadeTargetIndex = null;
    _crossfadeActiveTransitionId = null;
    _crossfadePrewarmLatencyMs = null;
    _crossfadeFadeStartedAt = null;
    AppLogger.debug('Cross-fade canceled.');

    final cfPlayer = _crossfadePlayer;
    if (cfPlayer != null) {
      unawaited(_setVolumeIfChanged(cfPlayer, 0));
      unawaited(cfPlayer.pause());
    }

    // Restore the main player's volume to the user-requested level.
    unawaited(_player.setVolume(_isDucked ? _userVolume * 2 / 5 : _userVolume));
  }

  Future<void> _prepareInactiveDeckForCrossfade({
    required AudioPlayer player,
    required int nextIndex,
  }) async {
    if (nextIndex < 0 || nextIndex >= _queueItems.length) {
      throw StateError('Next index $nextIndex is out of queue range.');
    }
    await _syncInactiveDeckQueueFromActive(player);
    try {
      await player.pause();
    } on Object {
      // Best-effort reset only.
    }
    await _setVolumeIfChanged(player, 0);
    if (player.shuffleModeEnabled != _player.shuffleModeEnabled) {
      await player.setShuffleModeEnabled(_player.shuffleModeEnabled);
    }
    if (player.loopMode != _player.loopMode) {
      await player.setLoopMode(_player.loopMode);
    }
    await player.setSpeed(_player.speed);
    await player.seek(Duration.zero, index: nextIndex);
  }

  Future<void> _syncInactiveDeckQueueFromActive(
    AudioPlayer player, {
    bool force = false,
  }) async {
    if (!force && player.sequence.length == _player.sequence.length) {
      return;
    }
    if (_queueItems.isEmpty) {
      await player.setAudioSources(const <AudioSource>[]);
      return;
    }
    final songIds = _queueItems.map((item) => item.id).toList(growable: false);
    final songs = await _libraryDao.getSongsByIds(songIds);
    final songsById = <String, SongsTableData>{
      for (final song in songs) song.id: song,
    };
    final orderedSongs = songIds
        .map((songId) => songsById[songId])
        .whereType<SongsTableData>()
        .toList(growable: false);
    if (orderedSongs.length != songIds.length) {
      throw StateError(
        'Inactive deck queue sync failed due to missing song metadata.',
      );
    }
    final prepared = await _prepareQueueItems(
      orderedSongs,
      preferLockCaching: true,
    );
    final inactiveSources = prepared
        .map((entry) => entry.source.asClonedAudioSource(tag: entry.mediaItem))
        .toList(growable: false);
    try {
      await player.setAudioSources(
        inactiveSources,
        preload: true,
        initialIndex: (_player.currentIndex ?? 0).clamp(
          0,
          math.max(0, inactiveSources.length - 1),
        ),
      );
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Inactive deck sync failed with lock-cached sources. '
        'Retrying with direct streams only. $error\n$stackTrace',
      );
      final directPrepared = await _prepareQueueItems(
        orderedSongs,
        preferLockCaching: false,
      );
      final directSources = directPrepared
          .map(
            (entry) => entry.source.asClonedAudioSource(tag: entry.mediaItem),
          )
          .toList(growable: false);
      await player.setAudioSources(
        directSources,
        preload: true,
        initialIndex: (_player.currentIndex ?? 0).clamp(
          0,
          math.max(0, directSources.length - 1),
        ),
      );
    }
    await _setVolumeIfChanged(player, 0);
    await player.pause();
  }

  void _rebindRadioMetadataServiceToActivePlayer() {
    _radioMetadataService.dispose();
    _radioMetadataService = RadioMetadataService(
      handler: this,
      player: _player,
    );
    if (_radioStation != null) {
      final azuraInfo = _tryExtractAzuracast(
        _radioStation!.streamUrl,
        _radioStation!.homePageUrl,
      );
      _radioMetadataService.startListening(
        stationId: _radioStation!.stationId,
        azuracastApiUrl: azuraInfo?.$1,
        stationShortName: azuraInfo?.$2,
      );
    }
  }

  void _emitCrossfadeMetric({
    required int transitionId,
    required int? targetIndex,
    required String phase,
    int? swapLatencyMs,
    int? fadeElapsedMs,
    String? fallbackReason,
    String? canceledReason,
  }) {
    final metric = CrossfadeTransitionMetric(
      transitionId: transitionId,
      targetIndex: targetIndex,
      phase: phase,
      platform: defaultTargetPlatform.name,
      backend: _isDesktopRuntime ? 'just_audio_media_kit' : 'just_audio_native',
      sourceKind:
          (targetIndex != null &&
              targetIndex >= 0 &&
              targetIndex < _queueItems.length)
          ? (_queueItems[targetIndex].extras?['sourceKind'] as String?)
          : null,
      format:
          (targetIndex != null &&
              targetIndex >= 0 &&
              targetIndex < _queueItems.length)
          ? (_queueItems[targetIndex].extras?['resolvedFormat'] as String?)
          : null,
      sampleRate:
          (targetIndex != null &&
              targetIndex >= 0 &&
              targetIndex < _queueItems.length)
          ? (_queueItems[targetIndex].extras?['sampleRate'] as int?)
          : null,
      prewarmLatencyMs: _crossfadePrewarmLatencyMs,
      fadeDurationMs: _crossfadeDurationSeconds * 1000,
      fadeElapsedMs: fadeElapsedMs,
      swapLatencyMs: swapLatencyMs,
      fallbackReason: fallbackReason,
      canceledReason: canceledReason,
    );
    AppLogger.debug('Cross-fade metric: ${metric.toDebugString()}');
  }

  MediaItem? _mediaItemForIndex(int? index) {
    if (index == null || index < 0 || index >= _queueItems.length) {
      return null;
    }
    return _queueItems[index];
  }

  Future<void> _restoreQueueFromDisk() async {
    final queueState = await _playQueueDao.getQueueState();
    final queuedSongs = await _playQueueDao.getQueueItems();
    if (queuedSongs.isEmpty) {
      return;
    }

    final startIndex = (queueState?.currentIndex ?? 0)
        .clamp(
          0,
          math.max(0, queuedSongs.length - 1),
        )
        .toInt();
    final restorePosition = Duration(
      milliseconds: math.max(0, queueState?.positionMs ?? 0),
    );

    try {
      await _setQueueFromSongs(
        queuedSongs,
        startIndex: startIndex,
        autoPlay: false,
        initialPosition: restorePosition,
        persist: false,
        preloadWhenPaused: false,
      );
    } on PlaybackSourceUnavailableException {
      AppLogger.warning(
        'Playback queue restore skipped because auth/session was unavailable.',
      );
      return;
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Queue restore failed with an unrecoverable source/setup error. '
        'Clearing persisted queue. '
        '$error\n$stackTrace',
      );
      await _playQueueDao.clearQueue();
      await _clearQueueInternal(persist: false);
      return;
    }

    if (queueState != null) {
      final loopMode = switch (queueState.repeatMode) {
        schema.RepeatMode.one => LoopMode.one,
        schema.RepeatMode.all => LoopMode.all,
        schema.RepeatMode.off => LoopMode.off,
      };
      await _player.setLoopMode(loopMode);
      final inactiveDeck = _crossfadePlayer;
      if (inactiveDeck != null) {
        await inactiveDeck.setLoopMode(loopMode);
      }

      final shuffle = queueState.shuffleMode == schema.ShuffleMode.all;
      await _player.setShuffleModeEnabled(shuffle);
      if (inactiveDeck != null) {
        await inactiveDeck.setShuffleModeEnabled(shuffle);
      }
    }

    await _player.pause();
    _broadcastPlaybackState();
    _emitSnapshot();
  }

  void _observeLockCachingSource({
    required SongsTableData song,
    required ResolvedPlaybackSource resolvedSource,
    // ignore: experimental_member_use, reason: LockCachingAudioSource is the intended just_audio cache primitive for rolling cache playback.
    required LockCachingAudioSource source,
    required String cacheFilePath,
  }) {
    if (_cacheProgressSubscriptions.containsKey(cacheFilePath)) {
      return;
    }

    late final StreamSubscription<double> subscription;
    subscription = source.downloadProgressStream.listen(
      (progress) {
        if (progress < 0.999) {
          return;
        }
        _cacheProgressSubscriptions.remove(cacheFilePath);
        unawaited(subscription.cancel());
        unawaited(
          _registerRollingCacheTrack(
            song: song,
            resolvedSource: resolvedSource,
            cacheFilePath: cacheFilePath,
          ),
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.debug(
          'Lock-cached source progress listener failed for ${song.id}: '
          '$error\n$stackTrace',
        );
        _cacheProgressSubscriptions.remove(cacheFilePath);
        unawaited(subscription.cancel());
      },
    );

    _cacheProgressSubscriptions[cacheFilePath] = subscription;
  }

  Future<void> _registerRollingCacheTrack({
    required SongsTableData song,
    required ResolvedPlaybackSource resolvedSource,
    required String cacheFilePath,
  }) async {
    final file = File(cacheFilePath);
    if (!file.existsSync()) {
      return;
    }

    try {
      await _rollingCacheManager.registerTrack(
        songId: song.id,
        filePath: cacheFilePath,
        format:
            resolvedSource.metadata.format ??
            (resolvedSource.metadata.isTranscoded ? 'transcoded' : null),
        bitRate: resolvedSource.metadata.bitRate,
      );
      await _rollingCacheManager.enforceBudget(
        maxBytes: _rollingCacheBudgetBytes,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Failed to register rolling cache entry for ${song.id}: '
        '$error\n$stackTrace',
      );
    }
  }

  Future<void> _setQueueFromSongs(
    List<SongsTableData> songs, {
    required int startIndex,
    required bool autoPlay,
    Duration initialPosition = Duration.zero,
    required bool persist,
    bool preloadWhenPaused = true,
  }) async {
    List<_PreparedQueueItem> prepared;
    try {
      prepared = await _prepareQueueItems(
        songs,
        preferLockCaching: true,
      );
    } on PlaybackSourceUnavailableException {
      rethrow;
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Queue preparation failed while lock-cached sources were enabled. '
        'Retrying with direct-stream sources. '
        '$error\n$stackTrace',
      );
      prepared = await _prepareQueueItems(
        songs,
        preferLockCaching: false,
      );
    }

    if (prepared.isEmpty) {
      await _clearQueueInternal(persist: persist);
      return;
    }

    final clampedIndex = startIndex.clamp(0, prepared.length - 1);
    try {
      await _applyPreparedQueue(
        prepared,
        startIndex: clampedIndex,
        autoPlay: autoPlay,
        initialPosition: initialPosition,
        preloadWhenPaused: preloadWhenPaused,
      );
    } on Object catch (error, stackTrace) {
      final sourceKinds = prepared
          .map((item) => item.source.kind)
          .toList(growable: false);
      final shouldRetry = navisShouldRetryQueueApplyWithDirectSources(
        sourceKinds: sourceKinds,
        error: error,
        isAndroidRuntime: _isAndroidRuntime,
      );
      final isDspFailure = _isAndroidDspInitializationFailure(error);
      if (!shouldRetry) {
        rethrow;
      }
      if (isDspFailure) {
        AppLogger.warning(
          'Queue apply failed due to Android DSP initialization. '
          'Disabling DSP for this session and rebuilding queue with direct '
          'stream sources. $error\n$stackTrace',
        );
        await _rebuildPlayerWithoutAndroidDsp(force: true);
      } else {
        AppLogger.warning(
          'Lock-cached playback source setup failed. '
          'Retrying queue build with direct stream sources. '
          'sources=${prepared.map((entry) => entry.source.kind.name).toList()} '
          '$error\n$stackTrace',
        );
      }
      prepared = await _prepareQueueItems(
        songs,
        preferLockCaching: false,
      );
      try {
        await _applyPreparedQueue(
          prepared,
          startIndex: clampedIndex,
          autoPlay: autoPlay,
          initialPosition: initialPosition,
          preloadWhenPaused: preloadWhenPaused,
        );
      } on Object catch (retryError, retryStackTrace) {
        if (!_isAndroidDspInitializationFailure(retryError)) {
          rethrow;
        }
        AppLogger.warning(
          'Direct-stream queue apply still hit Android DSP initialization '
          'failure. Forcing plain player rebind and retrying once more. '
          '$retryError\n$retryStackTrace',
        );
        await _rebuildPlayerWithoutAndroidDsp(force: true);
        await _applyPreparedQueue(
          prepared,
          startIndex: clampedIndex,
          autoPlay: autoPlay,
          initialPosition: initialPosition,
          preloadWhenPaused: preloadWhenPaused,
        );
      }
    }

    for (final entry in prepared) {
      if (entry.source.kind == PlaybackSourceKind.lockCachedStream &&
          entry.source.lockCachingAudioSource != null &&
          entry.source.cachedFilePath != null) {
        _observeLockCachingSource(
          song: entry.song,
          resolvedSource: entry.source,
          source: entry.source.lockCachingAudioSource!,
          cacheFilePath: entry.source.cachedFilePath!,
        );
      }
    }

    if (persist) {
      await _persistSafely(
        () => _persistQueueState(includeQueueItems: true),
        context: 'queue replacement',
      );
    }

    _broadcastPlaybackState();
    _emitSnapshot();
  }

  Future<List<_PreparedQueueItem>> _prepareQueueItems(
    List<SongsTableData> songs, {
    required bool preferLockCaching,
  }) async {
    final prepared = <_PreparedQueueItem>[];
    for (final song in songs) {
      ResolvedPlaybackSource source;
      try {
        source = await _sourceResolver.resolveForSong(
          song,
          preferLockCaching: preferLockCaching,
        );
      } on PlaybackSourceUnavailableException {
        rethrow;
      } on Object catch (error, stackTrace) {
        if (!preferLockCaching) {
          rethrow;
        }
        AppLogger.warning(
          'Source resolution failed for song=${song.id} '
          'with lock-cached preference. Falling back to direct stream. '
          '$error\n$stackTrace',
        );
        source = await _sourceResolver.resolveForSong(
          song,
          preferLockCaching: false,
        );
      }
      final item = MediaItem(
        id: song.id,
        title: song.title,
        artist: song.artistName,
        album: song.albumName,
        duration: song.duration == null
            ? null
            : Duration(seconds: math.max(0, song.duration!)),
        artUri: _sourceResolver.resolveArtUri(song),
        extras: navisResolvedPlaybackExtras(song: song, source: source),
      );
      prepared.add(
        _PreparedQueueItem(
          song: song,
          source: source,
          mediaItem: item,
          audioSource: source.asAudioSource(tag: item),
        ),
      );
    }
    return prepared;
  }

  /// Convenience wrapper: resolve song IDs from the library, then prepare
  /// [_PreparedQueueItem]s with lock-caching fallback.  Used by the
  /// incremental queue operations ([addToQueue], [playNext]).
  Future<List<_PreparedQueueItem>> _prepareQueueItemsFromIds(
    List<String> songIds,
  ) async {
    final songs = await _libraryDao.getSongsByIds(songIds);
    if (songs.isEmpty) return const <_PreparedQueueItem>[];
    try {
      return await _prepareQueueItems(songs, preferLockCaching: true);
    } on PlaybackSourceUnavailableException {
      rethrow;
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Incremental queue preparation failed with lock-cached sources. '
        'Retrying with direct-stream sources. '
        '$error\n$stackTrace',
      );
      return _prepareQueueItems(songs, preferLockCaching: false);
    }
  }

  /// Register rolling-cache progress listeners for any lock-cached entries
  /// in [prepared].
  void _observeLockCacheForPrepared(List<_PreparedQueueItem> prepared) {
    for (final entry in prepared) {
      if (entry.source.kind == PlaybackSourceKind.lockCachedStream &&
          entry.source.lockCachingAudioSource != null &&
          entry.source.cachedFilePath != null) {
        _observeLockCachingSource(
          song: entry.song,
          resolvedSource: entry.source,
          source: entry.source.lockCachingAudioSource!,
          cacheFilePath: entry.source.cachedFilePath!,
        );
      }
    }
  }

  Future<void> _applyPreparedQueue(
    List<_PreparedQueueItem> prepared, {
    required int startIndex,
    required bool autoPlay,
    required Duration initialPosition,
    required bool preloadWhenPaused,
  }) async {
    _queueItems
      ..clear()
      ..addAll(prepared.map((entry) => entry.mediaItem));

    final audioSources = prepared
        .map((entry) => entry.audioSource)
        .toList(growable: false);

    await _setAudioSourcesWithFallback(
      audioSources: audioSources,
      preload: navisShouldPreloadQueue(
        autoPlay: autoPlay,
        preloadWhenPaused: preloadWhenPaused,
        gaplessEnabled: _gaplessEnabled,
      ),
      initialIndex: startIndex,
      initialPosition: initialPosition,
    );
    await _setInactiveDeckAudioSources(
      prepared: prepared,
      initialIndex: startIndex,
      initialPosition: initialPosition,
    );

    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _setCurrentMediaItem(_queueItems[startIndex]);

    // IMPORTANT: Do NOT await _player.play() here.  play() returns a Future
    // that only completes when playback finishes or is interrupted.  Awaiting
    // it inside a _runSerialized block would deadlock all subsequent serialized
    // operations (pause, seek, skip, queue mutations) until the track ends.
    if (autoPlay) {
      unawaited(_player.play());
    } else {
      await _player.pause();
    }
  }

  Future<void> _setInactiveDeckAudioSources({
    required List<_PreparedQueueItem> prepared,
    required int initialIndex,
    required Duration initialPosition,
  }) async {
    final inactiveDeck = _crossfadePlayer;
    if (inactiveDeck == null) {
      return;
    }
    final inactiveSources = prepared
        .map((entry) => entry.source.asClonedAudioSource(tag: entry.mediaItem))
        .toList(growable: false);
    if (inactiveSources.isEmpty) {
      await inactiveDeck.setAudioSources(const <AudioSource>[]);
      return;
    }
    final clampedInitialIndex = initialIndex
        .clamp(
          0,
          math.max(0, inactiveSources.length - 1),
        )
        .toInt();
    await inactiveDeck.setAudioSources(
      inactiveSources,
      preload: true,
      initialIndex: clampedInitialIndex,
      initialPosition: initialPosition,
    );
    await inactiveDeck.setShuffleModeEnabled(_player.shuffleModeEnabled);
    await inactiveDeck.setLoopMode(_player.loopMode);
    await inactiveDeck.setSpeed(_player.speed);
    await _setVolumeIfChanged(inactiveDeck, 0);
    await inactiveDeck.pause();
  }

  Future<void> _setAudioSourcesWithFallback({
    required List<AudioSource> audioSources,
    required bool preload,
    required int initialIndex,
    required Duration initialPosition,
  }) async {
    try {
      await _player.setAudioSources(
        audioSources,
        preload: preload,
        initialIndex: initialIndex,
        initialPosition: initialPosition,
      );
    } on Object catch (error, stackTrace) {
      if (!_isAndroidDspInitializationFailure(error)) {
        rethrow;
      }
      AppLogger.warning(
        'Android DSP initialization failed during queue apply. '
        'Disabling DSP pipeline for this session and retrying. '
        '$error\n$stackTrace',
      );
      await _rebuildPlayerWithoutAndroidDsp(force: true);
      try {
        await _player.setAudioSources(
          audioSources,
          preload: preload,
          initialIndex: initialIndex,
          initialPosition: initialPosition,
        );
      } on Object catch (retryError, retryStackTrace) {
        if (!_isAndroidDspInitializationFailure(retryError)) {
          rethrow;
        }
        AppLogger.warning(
          'Android DSP fallback retry failed again. Rebuilding a plain player '
          'instance and retrying one final time. '
          '$retryError\n$retryStackTrace',
        );
        await _rebuildPlayerWithoutAndroidDsp(force: true);
        await _player.setAudioSources(
          audioSources,
          preload: preload,
          initialIndex: initialIndex,
          initialPosition: initialPosition,
        );
      }
    }
  }

  bool _isAndroidDspInitializationFailure(Object error) {
    return navisIsAndroidDspInitializationFailure(
      error,
      isAndroidRuntime: _isAndroidRuntime,
    );
  }

  Future<void> _rebuildPlayerWithoutAndroidDsp({bool force = false}) async {
    if (!_androidDspPipelineEnabled && !force) {
      return;
    }

    final previousPlayer = _player;
    final previousVolume = previousPlayer.volume;
    final previousSpeed = previousPlayer.speed;
    final previousLoopMode = previousPlayer.loopMode;
    final previousShuffleModeEnabled = previousPlayer.shuffleModeEnabled;

    _androidDspPipelineEnabled = false;
    await _disposePlayerListeners();
    _player = _buildAudioPlayer(enableAndroidDsp: false);
    _wirePlayerListeners();
    _rebindRadioMetadataServiceToActivePlayer();

    await _player.setVolume(previousVolume);
    await _player.setSpeed(previousSpeed);
    await _player.setLoopMode(previousLoopMode);
    await _player.setShuffleModeEnabled(previousShuffleModeEnabled);

    await previousPlayer.dispose();
    final inactiveDeck = _crossfadePlayer;
    if (inactiveDeck != null) {
      try {
        await inactiveDeck.dispose();
      } on Object {
        // Best-effort reset only.
      }
    }
    _crossfadePlayer = _buildBaseAudioPlayer();
    await _syncInactiveDeckQueueFromActive(_crossfadePlayer!, force: true);
  }

  Future<T> _runSerialized<T>(Future<T> Function() operation) {
    final completer = Completer<T>();

    _inFlight = _inFlight.then((_) async {
      if (completer.isCompleted) {
        return;
      }
      try {
        final value = await operation();
        completer.complete(value);
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });

    _inFlight = _inFlight.catchError((_) {});

    return completer.future;
  }

  @override
  Future<void> replaceQueue(
    List<String> songIds, {
    int startIndex = 0,
    bool autoPlay = true,
  }) {
    return _runSerialized(() async {
      await _ready;
      _cancelCrossfade();
      // Exit radio mode when the user starts playing songs from the library.
      _radioStation = null;
      await _replaceQueueFromIds(
        songIds,
        startIndex: startIndex,
        autoPlay: autoPlay,
        persist: true,
      );
    });
  }

  @override
  Future<void> addToQueue(List<String> songIds) {
    return _runSerialized(() async {
      await _ready;
      if (songIds.isEmpty) {
        return;
      }

      // When the queue is empty, fall back to a full queue setup so the player
      // initialises properly with the first item.
      if (_queueItems.isEmpty) {
        await _replaceQueueFromIds(
          songIds,
          startIndex: 0,
          autoPlay: true,
          persist: true,
        );
        return;
      }

      // Prepare only the new songs and append their audio sources
      // incrementally – this does NOT interrupt current playback.
      final prepared = await _prepareQueueItemsFromIds(songIds);
      if (prepared.isEmpty) return;

      for (final entry in prepared) {
        _queueItems.add(entry.mediaItem);
        await _player.addAudioSource(entry.audioSource);
        final inactiveDeck = _crossfadePlayer;
        if (inactiveDeck != null) {
          await inactiveDeck.addAudioSource(
            entry.source.asClonedAudioSource(tag: entry.mediaItem),
          );
        }
      }

      _observeLockCacheForPrepared(prepared);
      queue.add(List<MediaItem>.unmodifiable(_queueItems));
      await _persistSafely(
        () => _persistQueueState(includeQueueItems: true),
        context: 'add to queue',
      );
      _broadcastPlaybackState();
      _emitSnapshot();
    });
  }

  @override
  Future<void> playNext(List<String> songIds) {
    return _runSerialized(() async {
      await _ready;
      final incoming = songIds
          .map((id) => id.trim())
          .where((id) => id.isNotEmpty)
          .toList(growable: false);
      if (incoming.isEmpty) {
        return;
      }

      if (_queueItems.isEmpty) {
        await _replaceQueueFromIds(
          incoming,
          startIndex: 0,
          autoPlay: true,
          persist: true,
        );
        return;
      }

      final currentIndex = (_player.currentIndex ?? 0).clamp(
        0,
        _queueItems.length - 1,
      );
      final insertAt = (currentIndex + 1).clamp(0, _queueItems.length);

      // Prepare only the new songs and insert their audio sources
      // incrementally at the position right after the currently playing item.
      final prepared = await _prepareQueueItemsFromIds(incoming);
      if (prepared.isEmpty) return;

      // Insert in reverse order at the same position so relative order is
      // preserved (first incoming song ends up right after current).
      for (var i = prepared.length - 1; i >= 0; i--) {
        _queueItems.insert(insertAt, prepared[i].mediaItem);
        await _player.insertAudioSource(insertAt, prepared[i].audioSource);
        final inactiveDeck = _crossfadePlayer;
        if (inactiveDeck != null) {
          await inactiveDeck.insertAudioSource(
            insertAt,
            prepared[i].source.asClonedAudioSource(tag: prepared[i].mediaItem),
          );
        }
      }

      _observeLockCacheForPrepared(prepared);
      queue.add(List<MediaItem>.unmodifiable(_queueItems));
      await _persistSafely(
        () => _persistQueueState(includeQueueItems: true),
        context: 'play next',
      );
      _broadcastPlaybackState();
      _emitSnapshot();
    });
  }

  @override
  Future<void> playFromIndex(int index) {
    return _runSerialized(() async {
      await _ready;
      if (index < 0 || index >= _queueItems.length) {
        return;
      }
      await _player.seek(Duration.zero, index: index);
      final inactiveDeck = _crossfadePlayer;
      if (inactiveDeck != null && inactiveDeck.sequence.length > index) {
        await inactiveDeck.seek(Duration.zero, index: index);
      }
      await _player.play();
      await _persistSafely(_persistQueueState, context: 'play from index');
    });
  }

  @override
  Future<void> removeAt(int index) {
    return _runSerialized(() async {
      await _ready;
      if (index < 0 || index >= _queueItems.length) {
        return;
      }

      if (_queueItems.length == 1) {
        await _clearQueueInternal(persist: true);
        return;
      }

      // Remove the audio source and queue item incrementally — this does NOT
      // interrupt playback of other items.  If the currently playing item is
      // removed, just_audio automatically advances to the next item.
      _queueItems.removeAt(index);
      await _player.removeAudioSourceAt(index);
      final inactiveDeck = _crossfadePlayer;
      if (inactiveDeck != null && inactiveDeck.sequence.length > index) {
        await inactiveDeck.removeAudioSourceAt(index);
      }

      queue.add(List<MediaItem>.unmodifiable(_queueItems));
      // Update the mediaItem stream to match whatever is now current.
      final nowIndex = _player.currentIndex;
      if (nowIndex != null && nowIndex >= 0 && nowIndex < _queueItems.length) {
        _setCurrentMediaItem(_queueItems[nowIndex]);
      }

      await _persistSafely(
        () => _persistQueueState(includeQueueItems: true),
        context: 'remove at',
      );
      _broadcastPlaybackState();
      _emitSnapshot();
    });
  }

  @override
  Future<void> reorderQueue(int oldIndex, int newIndex) {
    return _runSerialized(() async {
      await _ready;
      if (_queueItems.isEmpty) {
        return;
      }
      if (oldIndex < 0 || oldIndex >= _queueItems.length) {
        return;
      }
      // ReorderableListView can report newIndex == length when dragging to
      // the end; treat that as a valid destination.
      if (newIndex < 0 || newIndex > _queueItems.length) {
        return;
      }

      final adjustedIndex = oldIndex < newIndex
          ? newIndex - 1
          : newIndex.clamp(0, _queueItems.length - 1);
      if (oldIndex == adjustedIndex) {
        return;
      }

      // Reorder the in-memory queue items to match the new order.
      final movedItem = _queueItems.removeAt(oldIndex);
      _queueItems.insert(adjustedIndex, movedItem);

      // Move the audio source in the player's playlist — this does NOT
      // interrupt playback; just_audio tracks the current item internally.
      await _player.moveAudioSource(oldIndex, adjustedIndex);
      final inactiveDeck = _crossfadePlayer;
      if (inactiveDeck != null &&
          inactiveDeck.sequence.length > oldIndex &&
          inactiveDeck.sequence.length > adjustedIndex) {
        await inactiveDeck.moveAudioSource(oldIndex, adjustedIndex);
      }

      queue.add(List<MediaItem>.unmodifiable(_queueItems));
      await _persistSafely(
        () => _persistQueueState(includeQueueItems: true),
        context: 'reorder queue',
      );
      _broadcastPlaybackState();
      _emitSnapshot();
    });
  }

  @override
  Future<void> clearQueue() {
    _cancelCrossfade();
    return _runSerialized(() => _clearQueueInternal(persist: true));
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) {
    return addToQueue(<String>[mediaItem.id]);
  }

  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) {
    return addToQueue(mediaItems.map((item) => item.id).toList());
  }

  @override
  Future<void> removeQueueItem(MediaItem mediaItem) async {
    final index = _queueItems.indexWhere((item) => item.id == mediaItem.id);
    await removeAt(index);
  }

  @override
  Future<void> skipToQueueItem(int index) => playFromIndex(index);

  Future<void> moveQueueItem(int currentIndex, int newIndex) {
    return reorderQueue(currentIndex, newIndex);
  }

  @override
  Future<void> play() async {
    await _ready;
    // play() must NOT go through _runSerialized — _player.play() returns a
    // Future that blocks until playback finishes/pauses.  Serializing it would
    // deadlock all subsequent operations (pause, seek, skip, queue changes).
    unawaited(_player.play());
    await _persistSafely(
      () => _persistQueueState(includePosition: false),
      context: 'play',
    );
  }

  @override
  Future<void> pause() {
    return _runSerialized(() async {
      await _ready;
      _cancelCrossfade();
      await navisRunTransportWithPersistence(
        transportOperation: _player.pause,
        persistOperation: _persistPosition,
        persistSafely: _persistSafely,
        persistenceContext: 'pause',
      );
    });
  }

  @override
  Future<void> applyRuntimeSettings() async {
    final runtime = _readRuntimeSettings();
    _gaplessEnabled = navisEffectiveGaplessEnabled(
      gaplessEnabled: runtime.gaplessEnabled,
      crossfadeEnabled: runtime.crossfadeEnabled,
    );
    _crossfadeEnabled = runtime.crossfadeEnabled;
    _crossfadeDurationSeconds = runtime.crossfadeDurationSeconds;
    _crossfadeType = runtime.crossfadeType;

    // If cross-fade was disabled while one is in progress, cancel it.
    if (!_crossfadeEnabled && _isCrossfading) {
      _cancelCrossfade();
    }

    // Apply playback speed.
    try {
      await _player.setSpeed(
        navisNormalizePlaybackSpeed(runtime.playbackSpeed),
      );
      final inactiveDeck = _crossfadePlayer;
      if (inactiveDeck != null) {
        await inactiveDeck.setSpeed(
          navisNormalizePlaybackSpeed(runtime.playbackSpeed),
        );
      }
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Failed to apply playback speed: $error\n$stackTrace',
      );
    }

    // Apply ReplayGain volume normalization for current track.
    _applyReplayGainVolume();

    if (!_isAndroidRuntime) {
      return;
    }

    if (!_androidDspPipelineEnabled &&
        (runtime.equalizerEnabled || runtime.loudnessEnabled)) {
      AppLogger.warning(
        'Android DSP settings are enabled, but DSP effects are unavailable '
        'for this session. Playback continues without DSP effects.',
      );
      return;
    }

    final equalizer = _androidEqualizer;
    final loudnessEnhancer = _androidLoudnessEnhancer;
    if (equalizer == null || loudnessEnhancer == null) {
      return;
    }

    try {
      final parameters = await equalizer.parameters;
      final gains = runtime.equalizerBandGains;
      for (var i = 0; i < parameters.bands.length; i++) {
        final requestedGain = i < gains.length ? gains[i] : 0;
        final clampedGain = requestedGain.clamp(
          parameters.minDecibels,
          parameters.maxDecibels,
        );
        await parameters.bands[i].setGain(clampedGain.toDouble());
      }
      await equalizer.setEnabled(runtime.equalizerEnabled);
      await loudnessEnhancer.setTargetGain(runtime.loudnessTargetGainDb);
      await loudnessEnhancer.setEnabled(runtime.loudnessEnabled);
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Failed to apply Android DSP runtime settings: '
        '$error\n$stackTrace',
      );
    }
  }

  // ── ReplayGain ──────────────────────────────────────────────────────────

  /// Apply ReplayGain volume normalization for the current track.
  ///
  /// Converts the ReplayGain dB value to a linear volume multiplier and
  /// sets it on the player, scaled by the current user volume.
  /// When the mode is 'off' (or metadata is missing), restores to _userVolume.
  void _applyReplayGainVolume({bool forceDuringCrossfade = false}) {
    if (_isCrossfading && !forceDuringCrossfade) {
      return;
    }
    final base = _isDucked ? _userVolume * 2 / 5 : _userVolume;
    final runtime = _readRuntimeSettings();
    final mode = runtime.replayGainMode;
    if (mode == 'off') {
      unawaited(_player.setVolume(base));
      return;
    }

    final index = _player.currentIndex;
    if (index == null || index < 0 || index >= _queueItems.length) {
      unawaited(_player.setVolume(base));
      return;
    }

    final extras = _queueItems[index].extras;
    if (extras == null) {
      unawaited(_player.setVolume(base));
      return;
    }

    final gainDb = mode == 'album'
        ? (extras['replayGainAlbumGain'] as double?) ??
              (extras['replayGainTrackGain'] as double?)
        : (extras['replayGainTrackGain'] as double?) ??
              (extras['replayGainAlbumGain'] as double?);

    if (gainDb == null) {
      unawaited(_player.setVolume(base));
      return;
    }

    final preamp = runtime.replayGainPreamp.clamp(-6, 6);
    // dB to linear: 10^((gain + preamp) / 20), scaled by user volume, clamped to [0, 1].
    final linear = (math
            .pow(10, (gainDb + preamp) / 20)
            .toDouble() *
        base)
        .clamp(0.0, 1.0);
    unawaited(_player.setVolume(linear));
  }

  @override
  Future<void> seek(Duration position) {
    return _runSerialized(() async {
      await _ready;
      _cancelCrossfade();
      final sanitizedPosition = navisSanitizeSeekPosition(position);
      await _seekWithRecovery(sanitizedPosition);
      await _persistSafely(_persistPosition, context: 'seek');
    });
  }

  @override
  Future<void> skipToNext() {
    return _runSerialized(() async {
      await _ready;
      _cancelCrossfade();
      if (!navisCanSkipQueueItem(
        queueLength: _queueItems.length,
        currentIndex: _player.currentIndex,
        forward: true,
      )) {
        return;
      }
      _emitManualTrackChangeCue(
        ManualTrackChangeDirection.next,
        fromSongId: _snapshot.currentSongId,
      );
      await navisRunTransportWithPersistence(
        transportOperation: _player.seekToNext,
        persistOperation: _persistQueueState,
        persistSafely: _persistSafely,
        persistenceContext: 'skip next',
      );
    });
  }

  @override
  Future<void> skipToPrevious() {
    return _runSerialized(() async {
      await _ready;
      _cancelCrossfade();
      if (!navisCanSkipQueueItem(
        queueLength: _queueItems.length,
        currentIndex: _player.currentIndex,
        forward: false,
      )) {
        return;
      }
      if (_player.position <= const Duration(seconds: 3)) {
        _emitManualTrackChangeCue(
          ManualTrackChangeDirection.previous,
          fromSongId: _snapshot.currentSongId,
        );
      }
      await navisRunTransportWithPersistence(
        transportOperation: _player.seekToPrevious,
        persistOperation: _persistQueueState,
        persistSafely: _persistSafely,
        persistenceContext: 'skip previous',
      );
    });
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    await _ready;
    final enabled = shuffleMode == AudioServiceShuffleMode.all;
    await _player.setShuffleModeEnabled(enabled);
    if (enabled) {
      await _player.shuffle();
    }
    final inactiveDeck = _crossfadePlayer;
    if (inactiveDeck != null) {
      await inactiveDeck.setShuffleModeEnabled(enabled);
      if (enabled) {
        await inactiveDeck.shuffle();
      }
    }
    await _persistSafely(
      () => _persistQueueState(includePosition: false),
      context: 'set shuffle mode',
    );
    _broadcastPlaybackState();
    _emitSnapshot();
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    await _ready;
    final loopMode = switch (repeatMode) {
      AudioServiceRepeatMode.one => LoopMode.one,
      AudioServiceRepeatMode.all ||
      AudioServiceRepeatMode.group => LoopMode.all,
      AudioServiceRepeatMode.none => LoopMode.off,
    };
    await _player.setLoopMode(loopMode);
    final inactiveDeck = _crossfadePlayer;
    if (inactiveDeck != null) {
      await inactiveDeck.setLoopMode(loopMode);
    }
    await _persistSafely(
      () => _persistQueueState(includePosition: false),
      context: 'set repeat mode',
    );
    _broadcastPlaybackState();
    _emitSnapshot();
  }

  @override
  Future<void> setPlaybackSpeed(double speed) async {
    await _ready;
    final normalizedSpeed = navisNormalizePlaybackSpeed(speed);
    try {
      await _player.setSpeed(normalizedSpeed);
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Failed to set playback speed directly: $error\n$stackTrace',
      );
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    await _ready;
    _userVolume = volume.clamp(0.0, 1.0);
    await _player.setVolume(_userVolume);
  }

  @override
  Future<void> stop() async {
    _cancelCrossfade();
    await _persistSafely(_persistPosition, context: 'stop');
    await _player.stop();
    final inactiveDeck = _crossfadePlayer;
    if (inactiveDeck != null) {
      await inactiveDeck.pause();
      await _setVolumeIfChanged(inactiveDeck, 0);
    }
    await super.stop();
  }

  Future<void> _persistSafely(
    Future<void> Function() persistOperation, {
    required String context,
  }) async {
    await navisPersistSafely(
      persistOperation,
      context: context,
      logWarning: AppLogger.warning,
    );
  }

  Future<void> _persistPosition() {
    return _persistQueueState();
  }

  Future<void> _persistQueueState({
    bool includePosition = true,
    bool includeQueueItems = false,
  }) async {
    // Don't persist radio state into the song queue table.
    if (_radioStation != null) {
      return;
    }
    if (_queueItems.isEmpty) {
      return;
    }

    final repeatMode = switch (_player.loopMode) {
      LoopMode.one => schema.RepeatMode.one,
      LoopMode.all => schema.RepeatMode.all,
      LoopMode.off => schema.RepeatMode.off,
    };

    final shuffleMode = _player.shuffleModeEnabled
        ? schema.ShuffleMode.all
        : schema.ShuffleMode.off;

    final positionMs = includePosition
        ? _player.position.inMilliseconds
        : _snapshot.position.inMilliseconds;

    if (includeQueueItems) {
      await _playQueueDao.saveQueue(
        currentIndex: _player.currentIndex,
        songIds: _queueItems.map((item) => item.id).toList(growable: false),
        shuffleMode: shuffleMode,
        repeatMode: repeatMode,
        positionMs: positionMs,
      );
      return;
    }

    await _playQueueDao.savePlaybackState(
      currentIndex: _player.currentIndex,
      shuffleMode: shuffleMode,
      repeatMode: repeatMode,
      positionMs: positionMs,
    );
  }

  void _broadcastPlaybackState() {
    final state = playbackState.value.copyWith(
      controls: navisNotificationControls(isPlaying: _player.playing),
      systemActions: const <MediaAction>{
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: navisNotificationCompactActionIndices,
      processingState: _mapProcessingState(_player.processingState),
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      queueIndex: _player.currentIndex,
      repeatMode: _mapRepeatMode(_player.loopMode),
      shuffleMode: _player.shuffleModeEnabled
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
    );
    playbackState.add(state);
  }

  AudioProcessingState _mapProcessingState(ProcessingState state) {
    return switch (state) {
      ProcessingState.idle => AudioProcessingState.idle,
      ProcessingState.loading => AudioProcessingState.loading,
      ProcessingState.buffering => AudioProcessingState.buffering,
      ProcessingState.ready => AudioProcessingState.ready,
      ProcessingState.completed => AudioProcessingState.completed,
    };
  }

  AudioServiceRepeatMode _mapRepeatMode(LoopMode mode) {
    return switch (mode) {
      LoopMode.off => AudioServiceRepeatMode.none,
      LoopMode.one => AudioServiceRepeatMode.one,
      LoopMode.all => AudioServiceRepeatMode.all,
    };
  }

  void _handleScrobbleSignals() {
    // Suppress scrobbling during radio playback.
    if (_radioStation != null) {
      return;
    }

    final currentItem = _mediaItemForIndex(_player.currentIndex);
    _updateScrobbleSession(currentItem);

    if (!_player.playing) {
      return;
    }

    final songId = _activeScrobbleSongId;
    final sessionKey = _activeScrobbleSessionKey;
    if (songId == null || sessionKey == null) {
      return;
    }

    if (!_sentNowPlayingScrobble) {
      _sentNowPlayingScrobble = true;
      unawaited(
        _scrobbleService.enqueueNowPlaying(
          songId: songId,
          sessionKey: sessionKey,
        ),
      );

      // Record in local play history as soon as the track starts playing
      // so it appears in "Recently Played" without waiting for the full
      // scrobble submission threshold.
      unawaited(
        _historyDao.addPlayHistory(songId).catchError((Object error) {
          AppLogger.error('Failed to record play history', error);
        }),
      );
    }

    if (_sentSubmissionScrobble) {
      return;
    }

    final duration = _player.duration ?? currentItem?.duration;
    final position = _player.position;
    final thresholdReached =
        _player.processingState == ProcessingState.completed ||
        _hasReachedSubmissionThreshold(duration: duration, position: position);

    if (!thresholdReached) {
      return;
    }

    _sentSubmissionScrobble = true;
    unawaited(
      _scrobbleService.enqueueSubmission(
        songId: songId,
        sessionKey: sessionKey,
      ),
    );
  }

  void _updateScrobbleSession(MediaItem? currentItem) {
    final songId = currentItem?.id;
    final queueToken = songId == null
        ? null
        : '${_player.currentIndex ?? -1}:$songId';

    if (queueToken == _activeScrobbleQueueToken) {
      return;
    }

    if (queueToken == null) {
      _activeScrobbleQueueToken = null;
      _activeScrobbleSongId = null;
      _activeScrobbleSessionKey = null;
      _sentNowPlayingScrobble = false;
      _sentSubmissionScrobble = false;
      return;
    }

    _activeScrobbleQueueToken = queueToken;
    _activeScrobbleSongId = songId;
    _activeScrobbleSessionKey =
        '${songId}_${DateTime.now().microsecondsSinceEpoch}';
    _sentNowPlayingScrobble = false;
    _sentSubmissionScrobble = false;
  }

  bool _hasReachedSubmissionThreshold({
    required Duration? duration,
    required Duration position,
  }) {
    if (duration == null || duration <= Duration.zero) {
      return false;
    }
    final halfDurationMs = duration.inMilliseconds ~/ 2;
    final thresholdMs = math.min(
      halfDurationMs,
      const Duration(minutes: 4).inMilliseconds,
    );
    return position.inMilliseconds >= thresholdMs;
  }

  void _emitSnapshot() {
    final currentItem =
        _mediaItemForIndex(_player.currentIndex) ?? _currentMediaItem;
    final isLiked = currentItem?.extras?['liked'] as bool? ?? false;
    _snapshot = PlaybackSnapshot(
      queueSongIds: _radioStation != null
          ? const <String>[]
          : _queueItems.map((item) => item.id).toList(growable: false),
      currentSongId: _radioStation != null ? null : currentItem?.id,
      currentIndex: _radioStation != null ? null : _player.currentIndex,
      playing: _player.playing,
      processingState: _mapProcessingState(_player.processingState),
      position: _player.position,
      duration: _player.duration ?? currentItem?.duration ?? Duration.zero,
      bufferedPosition: _player.bufferedPosition,
      shuffleMode: _player.shuffleModeEnabled
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
      repeatMode: _mapRepeatMode(_player.loopMode),
      isCurrentSongLiked: _radioStation == null && isLiked,
      radioStation: _radioStation,
    );
    if (!_snapshotController.isClosed) {
      _snapshotController.add(_snapshot);
    }
  }

  void _emitManualTrackChangeCue(
    ManualTrackChangeDirection direction, {
    required String? fromSongId,
  }) {
    if (_manualTrackChangeCueController.isClosed) {
      return;
    }
    _manualTrackChangeCueController.add(
      ManualTrackChangeCue(
        token: ++_manualTrackChangeCueToken,
        direction: direction,
        fromSongId: fromSongId,
      ),
    );
  }

  Future<void> _seekWithRecovery(Duration position) async {
    await _player.seek(position);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final actualPosition = _player.position;
    if (!navisShouldRecoverSeekToDirectStream(
      sourceKind: _currentSourceKind,
      requestedPosition: position,
      actualPosition: actualPosition,
    )) {
      return;
    }

    AppLogger.warning(
      'Seek landed at $actualPosition instead of $position on a lock-cached '
      'source. Rebuilding the active queue with direct streams and retrying.',
    );
    await _rebuildQueueForSeekRecovery(position);
  }

  Future<void> _rebuildQueueForSeekRecovery(Duration position) async {
    final currentIndex = _player.currentIndex;
    if (currentIndex == null ||
        currentIndex < 0 ||
        currentIndex >= _queueItems.length) {
      return;
    }

    final queueSongIds = _queueItems
        .map((item) => item.id)
        .toList(growable: false);
    if (queueSongIds.isEmpty) {
      return;
    }

    final songs = await _libraryDao.getSongsByIds(queueSongIds);
    final songsById = <String, SongsTableData>{
      for (final song in songs) song.id: song,
    };
    final orderedSongs = queueSongIds
        .map((songId) => songsById[songId])
        .whereType<SongsTableData>()
        .toList(growable: false);
    if (orderedSongs.length != queueSongIds.length) {
      AppLogger.warning(
        'Seek recovery could not rebuild the full queue from the local songs '
        'table. Skipping direct-stream fallback.',
      );
      return;
    }

    final wasPlaying = _player.playing;
    final previousLoopMode = _player.loopMode;
    final previousShuffleModeEnabled = _player.shuffleModeEnabled;
    final prepared = await _prepareQueueItems(
      orderedSongs,
      preferLockCaching: false,
    );
    await _applyPreparedQueue(
      prepared,
      startIndex: currentIndex,
      autoPlay: wasPlaying,
      initialPosition: position,
      preloadWhenPaused: false,
    );
    await _player.setLoopMode(previousLoopMode);
    await _player.setShuffleModeEnabled(previousShuffleModeEnabled);
  }

  String? get _currentSourceKind {
    final index = _player.currentIndex;
    if (index == null || index < 0 || index >= _queueItems.length) {
      return null;
    }
    return _queueItems[index].extras?['sourceKind'] as String?;
  }

  @override
  Future<void> onTaskRemoved() async {
    await _persistSafely(_persistPosition, context: 'task removed');
    await super.onTaskRemoved();
  }

  @override
  Future<void> onNotificationDeleted() {
    return pause();
  }

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) {
    if (name == 'clearQueue') {
      return clearQueue();
    }
    if (name == 'toggleShuffle') {
      final targetMode = _player.shuffleModeEnabled
          ? AudioServiceShuffleMode.none
          : AudioServiceShuffleMode.all;
      return setShuffleMode(targetMode);
    }
    if (name == 'toggleLike') {
      return toggleLike();
    }
    return super.customAction(name, extras);
  }

  @override
  Future<void> toggleLike() => _runSerialized(_toggleCurrentSongLike);

  @override
  Future<void> syncSongLikedState(String songId, {required bool liked}) =>
      _runSerialized(() => _syncSongLikedState(songId, liked: liked));

  Future<void> _syncSongLikedState(
    String songId, {
    required bool liked,
  }) async {
    await _ready;
    var updated = false;
    for (var i = 0; i < _queueItems.length; i++) {
      final item = _queueItems[i];
      if (item.id == songId) {
        final extras = <String, Object?>{...?item.extras};
        extras['liked'] = liked;
        _queueItems[i] = item.copyWith(extras: extras);
        updated = true;
      }
    }
    if (updated) {
      queue.add(List<MediaItem>.unmodifiable(_queueItems));
      _broadcastPlaybackState();
      _emitSnapshot();
    }
  }

  Future<void> _toggleCurrentSongLike() async {
    await _ready;
    final index = _player.currentIndex;
    if (index == null || index < 0 || index >= _queueItems.length) {
      return;
    }

    final api = _readApiClient();
    if (api == null) {
      return;
    }

    final current = _queueItems[index];
    final extras = <String, Object?>{...?current.extras};
    final isLiked = extras['liked'] as bool? ?? false;

    // Optimistic update — update DB and UI immediately before the API call.
    extras['liked'] = !isLiked;
    final updated = current.copyWith(extras: extras);
    _queueItems[index] = updated;
    await _libraryDao.updateSongStarred(
      current.id,
      !isLiked ? DateTime.now() : null,
    );
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _setCurrentMediaItem(updated);
    _broadcastPlaybackState();
    _emitSnapshot();

    try {
      if (isLiked) {
        await api.unstar(current.id);
      } else {
        await api.star(current.id);
      }
    } on SubsonicConnectionException {
      // Offline — queue for retry and keep the optimistic UI (DB already updated).
      await _starSyncDao.queueStarAction(
        itemId: current.id,
        itemType: 'song',
        action: isLiked ? 'unstar' : 'star',
      );
    } on Object {
      // API error — rollback the optimistic update.
      extras['liked'] = isLiked;
      final rolledBack = current.copyWith(extras: extras);
      _queueItems[index] = rolledBack;
      await _libraryDao.updateSongStarred(
        current.id,
        isLiked ? DateTime.now() : null,
      );
      queue.add(List<MediaItem>.unmodifiable(_queueItems));
      _setCurrentMediaItem(rolledBack);
      _broadcastPlaybackState();
      _emitSnapshot();
    }
  }

  Future<void> disposeHandler() async {
    if (_disposeHandlerCompleted) {
      return;
    }
    if (_disposeHandlerStarted) {
      await _ensurePlayerDisposalStarted();
      return;
    }
    _disposeHandlerStarted = true;
    _cancelCrossfade();
    await _disposeInactiveCrossfadeDeck();
    _positionPersistTimer?.cancel();
    _radioStation = null;
    _radioMetadataService.dispose();
    await _interruptionSubscription?.cancel();
    await _becomingNoisySubscription?.cancel();
    await _disposePlayerListeners();
    for (final subscription in _cacheProgressSubscriptions.values) {
      await subscription.cancel();
    }
    _cacheProgressSubscriptions.clear();
    if (_playerDisposalFuture == null) {
      await _persistSafely(_persistPosition, context: 'dispose handler');
    }
    await _ensurePlayerDisposalStarted();
    await _snapshotController.close();
    await _manualTrackChangeCueController.close();
    await _positionController.close();
    await _radioStreamErrorController.close();
    _disposeHandlerCompleted = true;
  }

  void beginTeardown() {
    if (_disposeHandlerCompleted) {
      return;
    }
    if (_disposeHandlerStarted) {
      unawaited(_ensurePlayerDisposalStarted());
      return;
    }
    _disposeHandlerStarted = true;
    _cancelCrossfade();
    unawaited(_disposeInactiveCrossfadeDeck());
    _positionPersistTimer?.cancel();
    _radioStation = null;
    _radioMetadataService.dispose();
    unawaited(_disposePlayerListeners());
    for (final subscription in _cacheProgressSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    _cacheProgressSubscriptions.clear();
    unawaited(_ensurePlayerDisposalStarted());
  }

  Future<void> _ensurePlayerDisposalStarted() {
    return _playerDisposalFuture ??= () async {
      try {
        await _player.stop();
      } on Object {
        // Ignore stop failures during teardown.
      }
      try {
        await _player.dispose();
      } on Object {
        // Ignore disposal failures during teardown.
      }
      final inactiveDeck = _crossfadePlayer;
      if (inactiveDeck != null) {
        try {
          await inactiveDeck.stop();
        } on Object {
          // Ignore stop failures during teardown.
        }
        try {
          await inactiveDeck.dispose();
        } on Object {
          // Ignore disposal failures during teardown.
        }
        _crossfadePlayer = null;
      }
    }();
  }

  Future<void> _disposeInactiveCrossfadeDeck() async {
    final inactiveDeck = _crossfadePlayer;
    if (inactiveDeck == null) {
      return;
    }
    try {
      await inactiveDeck.pause();
    } on Object {
      // Best-effort shutdown only.
    }
    await _setVolumeIfChanged(inactiveDeck, 0);
  }

  // ---------------------------------------------------------------------------
  // Radio stream playback
  // ---------------------------------------------------------------------------

  @override
  Future<void> playRadioStream({
    required String stationId,
    required String stationName,
    required String streamUrl,
    String? homePageUrl,
  }) {
    return _runSerialized(() async {
      await _ready;

      _radioStation = RadioStationMetadata(
        stationId: stationId,
        stationName: stationName,
        streamUrl: streamUrl,
        homePageUrl: homePageUrl,
      );

      // Clear the queue items (in memory) so the player doesn't show stale
      // song-queue data, but do NOT clear the persisted queue — we want to be
      // able to resume the song queue when the user stops radio.
      _queueItems.clear();
      _updateScrobbleSession(null);

      // Set the radio stream as the audio source.
      final radioMediaItem = MediaItem(
        id: 'radio:$stationId',
        title: stationName,
        artist: stationName,
        extras: <String, Object?>{
          'isRadio': true,
          'streamUrl': streamUrl,
        },
      );

      try {
        await _player.setAudioSource(
          AudioSource.uri(
            Uri.parse(streamUrl),
            tag: radioMediaItem,
          ),
        );
      } on Object catch (error, stackTrace) {
        AppLogger.error(
          'Failed to start radio stream: $streamUrl',
          error,
          stackTrace,
        );
        _radioStation = null;
        _emitSnapshot();
        rethrow;
      }

      queue.add(<MediaItem>[radioMediaItem]);
      _setCurrentMediaItem(radioMediaItem);

      // Start metadata listening BEFORE play() so Azuracast polling and ICY
      // stream subscription are active from the very beginning.  play() on a
      // live stream returns a Future that completes only when playback is
      // interrupted — awaiting it would block metadata setup indefinitely.
      final azuraInfo = _tryExtractAzuracast(streamUrl, homePageUrl);
      _radioMetadataService.startListening(
        stationId: stationId,
        azuracastApiUrl: azuraInfo?.$1,
        stationShortName: azuraInfo?.$2,
      );

      unawaited(_player.play());
      _broadcastPlaybackState();
      _emitSnapshot();
    });
  }

  @override
  Future<void> stopRadio() {
    return _runSerialized(() async {
      await _ready;

      if (_radioStation == null) {
        return;
      }

      _radioStation = null;
      _radioMetadataService.stop();

      await _player.stop();
      await _player.setAudioSources(const <AudioSource>[]);
      queue.add(const <MediaItem>[]);
      _setCurrentMediaItem(null);

      // Attempt to restore the previous song queue so the user can resume
      // library playback without manual intervention.
      try {
        await _restoreQueueFromDisk();
      } on Object catch (error, stackTrace) {
        AppLogger.warning(
          'Queue restore after radio stop failed: $error\n$stackTrace',
        );
      }

      _broadcastPlaybackState();
      _emitSnapshot();
    });
  }

  @override
  void updateRadioMetadata({
    String? title,
    String? artist,
    String? artUrl,
  }) {
    final current = _radioStation;
    if (current == null) {
      return;
    }

    _radioStation = RadioStationMetadata(
      stationId: current.stationId,
      stationName: current.stationName,
      streamUrl: current.streamUrl,
      homePageUrl: current.homePageUrl,
      nowPlayingTitle: title ?? current.nowPlayingTitle,
      nowPlayingArtist: artist ?? current.nowPlayingArtist,
      nowPlayingArtUrl: artUrl ?? current.nowPlayingArtUrl,
    );

    // Update the MediaItem for lock-screen / notification display.
    final updatedItem = MediaItem(
      id: 'radio:${current.stationId}',
      title: title ?? current.stationName,
      artist: artist ?? current.stationName,
      artUri: artUrl != null ? Uri.tryParse(artUrl) : null,
      extras: <String, Object?>{
        'isRadio': true,
        'streamUrl': current.streamUrl,
      },
    );
    _setCurrentMediaItem(updatedItem);
    _broadcastPlaybackState();
    _emitSnapshot();
  }

  Future<void> _replaceQueueFromIds(
    List<String> songIds, {
    required int startIndex,
    required bool autoPlay,
    required bool persist,
  }) async {
    final songs = await _libraryDao.getSongsByIds(songIds);
    if (songs.isEmpty) {
      await _clearQueueInternal(persist: persist);
      return;
    }
    await _setQueueFromSongs(
      songs,
      startIndex: startIndex,
      autoPlay: autoPlay,
      persist: persist,
    );
  }

  Future<void> _clearQueueInternal({required bool persist}) async {
    _queueItems.clear();
    await _player.stop();
    await _player.setAudioSources(const <AudioSource>[]);
    final inactiveDeck = _crossfadePlayer;
    if (inactiveDeck != null) {
      await inactiveDeck.stop();
      await inactiveDeck.setAudioSources(const <AudioSource>[]);
      await inactiveDeck.setSpeed(1);
      await _setVolumeIfChanged(inactiveDeck, 0);
    }
    await _player.setSpeed(1);
    _updateScrobbleSession(null);
    queue.add(const <MediaItem>[]);
    _setCurrentMediaItem(null);
    if (persist) {
      await _playQueueDao.clearQueue();
    }
    _broadcastPlaybackState();
    _emitSnapshot();
  }

  /// Attempt to extract an Azuracast base URL and station short name from the
  /// stream URL or the homePageUrl.
  ///
  /// Azuracast stream URLs follow the pattern:
  ///   `https://<host>/listen/<station_short_name>/<format>`
  ///
  /// Returns `(baseUrl, stationShortName)` or `null` if detection fails.
  static (String, String)? _tryExtractAzuracast(
    String streamUrl,
    String? homePageUrl,
  ) {
    // Try parsing the stream URL for /listen/{station}/ or /hls/{station}/
    // pattern (both are valid Azuracast stream URL formats).
    final uri = Uri.tryParse(streamUrl);
    if (uri != null && uri.pathSegments.length >= 2) {
      for (final prefix in <String>['listen', 'hls']) {
        final prefixIndex = uri.pathSegments.indexOf(prefix);
        if (prefixIndex >= 0 && prefixIndex + 1 < uri.pathSegments.length) {
          final stationName = uri.pathSegments[prefixIndex + 1];
          final baseUrl =
              '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
          return (baseUrl, stationName);
        }
      }
    }

    // Fall back to homePageUrl as Azuracast base + station name heuristic.
    if (homePageUrl != null && homePageUrl.isNotEmpty) {
      final homeUri = Uri.tryParse(homePageUrl);
      if (homeUri != null) {
        // If the homePageUrl has a path like /public/station_name
        final segments = homeUri.pathSegments
            .where((s) => s.isNotEmpty)
            .toList();
        final baseUrl =
            '${homeUri.scheme}://${homeUri.host}${homeUri.hasPort ? ':${homeUri.port}' : ''}';
        if (segments.length >= 2 && segments.first == 'public') {
          return (baseUrl, segments[1]);
        }
        // Try last non-empty segment as station name.
        if (segments.isNotEmpty) {
          return (baseUrl, segments.last);
        }
        // Use the base URL with a generic station name.
        return (baseUrl, '1');
      }
    }

    return null;
  }
}

bool get _isAndroidRuntime => !kIsWeb && Platform.isAndroid;

bool get _isWindowsRuntime => !kIsWeb && Platform.isWindows;

bool get _isLinuxRuntime => !kIsWeb && Platform.isLinux;

bool get _isDesktopRuntime =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

bool get _supportsAudioSessionRuntime =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

class _PreparedQueueItem {
  const _PreparedQueueItem({
    required this.song,
    required this.source,
    required this.mediaItem,
    required this.audioSource,
  });

  final SongsTableData song;
  final ResolvedPlaybackSource source;
  final MediaItem mediaItem;
  final AudioSource audioSource;
}

class CrossfadeTransitionMetric {
  const CrossfadeTransitionMetric({
    required this.transitionId,
    required this.targetIndex,
    required this.phase,
    required this.platform,
    required this.backend,
    required this.fadeDurationMs,
    this.sourceKind,
    this.format,
    this.sampleRate,
    this.prewarmLatencyMs,
    this.fadeElapsedMs,
    this.swapLatencyMs,
    this.fallbackReason,
    this.canceledReason,
  });

  final int transitionId;
  final int? targetIndex;
  final String phase;
  final String platform;
  final String backend;
  final String? sourceKind;
  final String? format;
  final int? sampleRate;
  final int? prewarmLatencyMs;
  final int fadeDurationMs;
  final int? fadeElapsedMs;
  final int? swapLatencyMs;
  final String? fallbackReason;
  final String? canceledReason;

  String toDebugString() {
    final fields = <String, Object?>{
      'transitionId': transitionId,
      'targetIndex': targetIndex,
      'phase': phase,
      'platform': platform,
      'backend': backend,
      'sourceKind': sourceKind,
      'format': format,
      'sampleRate': sampleRate,
      'prewarmLatencyMs': prewarmLatencyMs,
      'fadeDurationMs': fadeDurationMs,
      'fadeElapsedMs': fadeElapsedMs,
      'swapLatencyMs': swapLatencyMs,
      'fallbackReason': fallbackReason,
      'canceledReason': canceledReason,
    };
    return fields.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join(' ');
  }
}
