import 'dart:async';
import 'dart:math' as math;
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/daos/play_queue_dao.dart';
import 'package:navis/src/database/tables/schema_enums.dart' as schema;
import 'package:navis/src/features/cache/data/rolling_cache_manager.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/data/scrobble_service.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/utils/app_logger.dart';

abstract class NavisPlaybackHandler {
  PlaybackSnapshot get snapshot;
  Stream<PlaybackSnapshot> get snapshotStream;
  Stream<Duration> get positionStream;
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
  Future<void> setVolume(double volume);
  Future<void> applyRuntimeSettings();
}

class PlaybackRuntimeSettings {
  const PlaybackRuntimeSettings({
    required this.gaplessEnabled,
    required this.equalizerEnabled,
    required this.equalizerBandGains,
    required this.loudnessEnabled,
    required this.loudnessTargetGainDb,
  });

  const PlaybackRuntimeSettings.defaults()
    : gaplessEnabled = true,
      equalizerEnabled = false,
      equalizerBandGains = const <double>[],
      loudnessEnabled = false,
      loudnessTargetGainDb = 0;

  final bool gaplessEnabled;
  final bool equalizerEnabled;
  final List<double> equalizerBandGains;
  final bool loudnessEnabled;
  final double loudnessTargetGainDb;
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

Future<NavisAudioHandler>? _audioServiceInitFuture;

Future<NavisAudioHandler> initNavisAudioHandler({
  required LibraryDao libraryDao,
  required PlayQueueDao playQueueDao,
  required PlaybackSourceResolver sourceResolver,
  required SubsonicApiClient? Function() readApiClient,
  required RollingCacheManager rollingCacheManager,
  required int rollingCacheBudgetBytes,
  required ScrobbleService scrobbleService,
  required PlaybackRuntimeSettings Function() readRuntimeSettings,
}) {
  final cachedFuture = _audioServiceInitFuture;
  if (cachedFuture != null) {
    return cachedFuture;
  }

  final initFuture = AudioService.init(
    builder: () => NavisAudioHandler(
      libraryDao: libraryDao,
      playQueueDao: playQueueDao,
      sourceResolver: sourceResolver,
      readApiClient: readApiClient,
      rollingCacheManager: rollingCacheManager,
      rollingCacheBudgetBytes: rollingCacheBudgetBytes,
      scrobbleService: scrobbleService,
      readRuntimeSettings: readRuntimeSettings,
    ),
    config: AudioServiceConfig(
      androidNotificationChannelId: 'playback',
      androidNotificationChannelName: 'Playback',
      androidNotificationOngoing: false,
      androidStopForegroundOnPause: false,
    ),
  );

  _audioServiceInitFuture = initFuture;
  unawaited(
    initFuture.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_audioServiceInitFuture, initFuture)) {
          _audioServiceInitFuture = null;
        }
      },
    ),
  );
  return initFuture;
}

class NavisAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler
    implements NavisPlaybackHandler {
  NavisAudioHandler({
    required LibraryDao libraryDao,
    required PlayQueueDao playQueueDao,
    required PlaybackSourceResolver sourceResolver,
    required SubsonicApiClient? Function() readApiClient,
    required RollingCacheManager rollingCacheManager,
    required int rollingCacheBudgetBytes,
    required ScrobbleService scrobbleService,
    required PlaybackRuntimeSettings Function() readRuntimeSettings,
    AudioPlayer? player,
  }) : _libraryDao = libraryDao,
       _playQueueDao = playQueueDao,
       _sourceResolver = sourceResolver,
       _readApiClient = readApiClient,
       _rollingCacheManager = rollingCacheManager,
       _rollingCacheBudgetBytes = rollingCacheBudgetBytes,
       _scrobbleService = scrobbleService,
       _readRuntimeSettings = readRuntimeSettings {
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
  final PlaybackSourceResolver _sourceResolver;
  final SubsonicApiClient? Function() _readApiClient;
  final RollingCacheManager _rollingCacheManager;
  final int _rollingCacheBudgetBytes;
  final ScrobbleService _scrobbleService;
  final PlaybackRuntimeSettings Function() _readRuntimeSettings;
  late AudioPlayer _player;
  AndroidEqualizer? _androidEqualizer;
  AndroidLoudnessEnhancer? _androidLoudnessEnhancer;
  bool _androidDspPipelineEnabled = false;

  final StreamController<PlaybackSnapshot> _snapshotController =
      StreamController<PlaybackSnapshot>.broadcast();

  final List<MediaItem> _queueItems = <MediaItem>[];

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
  final Map<String, StreamSubscription<double>> _cacheProgressSubscriptions =
      <String, StreamSubscription<double>>{};
  bool _isDucked = false;
  double _volumeBeforeDuck = 1;
  bool _resumeAfterInterruption = false;
  bool _gaplessEnabled = true;
  String? _activeScrobbleQueueToken;
  String? _activeScrobbleSongId;
  String? _activeScrobbleSessionKey;
  bool _sentNowPlayingScrobble = false;
  bool _sentSubmissionScrobble = false;

  @override
  PlaybackSnapshot get snapshot => _snapshot;

  @override
  Stream<PlaybackSnapshot> get snapshotStream => _snapshotController.stream;

  @override
  Stream<Duration> get positionStream => _player.createPositionStream(
    minPeriod: const Duration(milliseconds: 100),
    maxPeriod: const Duration(milliseconds: 200),
  );

  @override
  Future<void> waitUntilReady() => _ready;

  AudioPlayer _buildAudioPlayer({required bool enableAndroidDsp}) {
    if (_isAndroidRuntime && enableAndroidDsp) {
      _androidEqualizer = AndroidEqualizer();
      _androidLoudnessEnhancer = AndroidLoudnessEnhancer();
      return AudioPlayer(
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
    return AudioPlayer();
  }

  Future<void> _initialize() async {
    AppLogger.info('Audio handler init: start.');
    final session = await AudioSession.instance;
    AppLogger.info('Audio handler init: audio session acquired.');
    await session.configure(const AudioSessionConfiguration.music());
    AppLogger.info('Audio handler init: audio session configured.');
    _wireAudioSession(session);
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
          await _rollingCacheManager.enforceBudget(
            maxBytes: _rollingCacheBudgetBytes,
          );
        } on Object catch (error, stackTrace) {
          AppLogger.warning(
            'Rolling cache maintenance failed during startup: '
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
        await _restoreQueueFromDisk().timeout(const Duration(seconds: 3));
      } on TimeoutException catch (error, stackTrace) {
        AppLogger.warning(
          'Queue restore timed out during startup. '
          'Clearing persisted queue to unblock playback startup. '
          '$error\n$stackTrace',
        );
        await _playQueueDao.clearQueue();
      } on Object catch (error, stackTrace) {
        AppLogger.error(
          'Queue restore failed. Clearing persisted queue to keep playback functional.',
          error,
          stackTrace,
        );
        await _playQueueDao.clearQueue();
      }
    });
  }

  void _wireAudioSession(AudioSession session) {
    _interruptionSubscription = session.interruptionEventStream.listen((event) {
      if (event.begin) {
        if (event.type == AudioInterruptionType.duck) {
          if (!_isDucked) {
            _volumeBeforeDuck = _player.volume;
            _isDucked = true;
            unawaited(
              _player.setVolume((_volumeBeforeDuck * 2 / 5).clamp(0, 1)),
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
          unawaited(_player.setVolume(_volumeBeforeDuck));
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
      },
    );

    _currentIndexSubscription = _player.currentIndexStream.listen((index) {
      final item = _mediaItemForIndex(index);
      mediaItem.add(item);
      _updateScrobbleSession(item);
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
  }

  Future<void> _disposePlayerListeners() async {
    await _playbackEventSubscription?.cancel();
    await _currentIndexSubscription?.cancel();
    await _shuffleModeSubscription?.cancel();
    await _loopModeSubscription?.cancel();
    _playbackEventSubscription = null;
    _currentIndexSubscription = null;
    _shuffleModeSubscription = null;
    _loopModeSubscription = null;
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

      final shuffle = queueState.shuffleMode == schema.ShuffleMode.all;
      await _player.setShuffleModeEnabled(shuffle);
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

    final resolvedFormat = resolvedSource.uri?.queryParameters['format']
        ?.trim()
        .toLowerCase();
    final fallbackFormat =
        song.suffix?.trim().toLowerCase() ??
        song.contentType?.split('/').last.trim().toLowerCase();
    final resolvedBitRate = int.tryParse(
      resolvedSource.uri?.queryParameters['maxBitRate'] ?? '',
    );

    try {
      await _rollingCacheManager.registerTrack(
        songId: song.id,
        filePath: cacheFilePath,
        format: (resolvedFormat?.isNotEmpty ?? false)
            ? resolvedFormat
            : fallbackFormat,
        bitRate: resolvedBitRate,
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
        extras: <String, Object?>{
          'albumId': song.albumId,
          'artistId': song.artistId,
          'sourceKind': source.kind.name,
          'localSource': source.isLocal,
          'cachedFilePath': source.cachedFilePath,
          'liked': song.starred != null,
        },
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

    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    mediaItem.add(_queueItems[startIndex]);

    if (autoPlay) {
      await _player.play();
    } else {
      await _player.pause();
    }
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

    await _player.setVolume(previousVolume);
    await _player.setSpeed(previousSpeed);
    await _player.setLoopMode(previousLoopMode);
    await _player.setShuffleModeEnabled(previousShuffleModeEnabled);

    await previousPlayer.dispose();
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

      final existingIds = _queueItems.map((item) => item.id).toList();
      final merged = <String>[...existingIds, ...songIds];
      await _replaceQueueFromIds(
        merged,
        startIndex: _player.currentIndex ?? 0,
        autoPlay: _player.playing,
        persist: true,
      );
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

      final existing = _queueItems
          .map((item) => item.id)
          .toList(growable: true);
      final currentIndex = (_player.currentIndex ?? 0).clamp(
        0,
        existing.length - 1,
      );
      final insertAt = (currentIndex + 1).clamp(0, existing.length);
      existing.insertAll(insertAt, incoming);

      await _replaceQueueFromIds(
        existing,
        startIndex: currentIndex,
        autoPlay: _player.playing,
        persist: true,
      );
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

      final remainingIds = <String>[];
      for (var i = 0; i < _queueItems.length; i++) {
        if (i != index) {
          remainingIds.add(_queueItems[i].id);
        }
      }

      if (remainingIds.isEmpty) {
        await _clearQueueInternal(persist: true);
        return;
      }

      final currentIndex = _player.currentIndex ?? 0;
      final nextIndex = math.max(
        0,
        math.min(currentIndex, remainingIds.length - 1),
      );
      await _replaceQueueFromIds(
        remainingIds,
        startIndex: nextIndex,
        autoPlay: _player.playing,
        persist: true,
      );
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
      if (newIndex < 0 || newIndex >= _queueItems.length) {
        return;
      }
      if (oldIndex == newIndex) {
        return;
      }

      final ids = _queueItems.map((item) => item.id).toList(growable: true);
      final movedId = ids.removeAt(oldIndex);
      final adjustedIndex = oldIndex < newIndex ? newIndex - 1 : newIndex;
      ids.insert(adjustedIndex, movedId);

      final currentSongId = _mediaItemForIndex(_player.currentIndex)?.id;
      final nextIndex = currentSongId == null ? 0 : ids.indexOf(currentSongId);
      await _replaceQueueFromIds(
        ids,
        startIndex: nextIndex < 0 ? 0 : nextIndex,
        autoPlay: _player.playing,
        persist: true,
      );
    });
  }

  @override
  Future<void> clearQueue() {
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
    await navisRunTransportWithPersistence(
      transportOperation: _player.play,
      persistOperation: () => _persistQueueState(includePosition: false),
      persistSafely: _persistSafely,
      persistenceContext: 'play',
    );
  }

  @override
  Future<void> pause() async {
    await _ready;
    await navisRunTransportWithPersistence(
      transportOperation: _player.pause,
      persistOperation: _persistPosition,
      persistSafely: _persistSafely,
      persistenceContext: 'pause',
    );
  }

  @override
  Future<void> applyRuntimeSettings() async {
    final runtime = _readRuntimeSettings();
    _gaplessEnabled = runtime.gaplessEnabled;
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

  @override
  Future<void> seek(Duration position) async {
    await _ready;
    final sanitizedPosition = navisSanitizeSeekPosition(position);
    await navisRunTransportWithPersistence(
      transportOperation: () => _player.seek(sanitizedPosition),
      persistOperation: _persistPosition,
      persistSafely: _persistSafely,
      persistenceContext: 'seek',
    );
  }

  @override
  Future<void> skipToNext() async {
    await _ready;
    if (!navisCanSkipQueueItem(
      queueLength: _queueItems.length,
      currentIndex: _player.currentIndex,
      forward: true,
    )) {
      return;
    }
    await navisRunTransportWithPersistence(
      transportOperation: _player.seekToNext,
      persistOperation: _persistQueueState,
      persistSafely: _persistSafely,
      persistenceContext: 'skip next',
    );
  }

  @override
  Future<void> skipToPrevious() async {
    await _ready;
    if (!navisCanSkipQueueItem(
      queueLength: _queueItems.length,
      currentIndex: _player.currentIndex,
      forward: false,
    )) {
      return;
    }
    await navisRunTransportWithPersistence(
      transportOperation: _player.seekToPrevious,
      persistOperation: _persistQueueState,
      persistSafely: _persistSafely,
      persistenceContext: 'skip previous',
    );
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    await _ready;
    final enabled = shuffleMode == AudioServiceShuffleMode.all;
    await _player.setShuffleModeEnabled(enabled);
    if (enabled) {
      await _player.shuffle();
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
    await _persistSafely(
      () => _persistQueueState(includePosition: false),
      context: 'set repeat mode',
    );
    _broadcastPlaybackState();
    _emitSnapshot();
  }

  @override
  Future<void> setVolume(double volume) async {
    await _ready;
    await _player.setVolume(volume.clamp(0.0, 1.0));
  }

  @override
  Future<void> stop() async {
    await _persistSafely(_persistPosition, context: 'stop');
    await _player.stop();
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
    final currentItem = _mediaItemForIndex(_player.currentIndex);
    _snapshot = PlaybackSnapshot(
      queueSongIds: _queueItems.map((item) => item.id).toList(growable: false),
      currentSongId: currentItem?.id,
      currentIndex: _player.currentIndex,
      playing: _player.playing,
      processingState: _mapProcessingState(_player.processingState),
      position: _player.position,
      duration: _player.duration ?? currentItem?.duration ?? Duration.zero,
      bufferedPosition: _player.bufferedPosition,
      shuffleMode: _player.shuffleModeEnabled
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
      repeatMode: _mapRepeatMode(_player.loopMode),
    );
    if (!_snapshotController.isClosed) {
      _snapshotController.add(_snapshot);
    }
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
      return _runSerialized(_toggleCurrentSongLike);
    }
    return super.customAction(name, extras);
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

    if (isLiked) {
      await api.unstar(current.id);
    } else {
      await api.star(current.id);
    }

    extras['liked'] = !isLiked;
    final updated = current.copyWith(extras: extras);
    _queueItems[index] = updated;
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    mediaItem.add(updated);
    _broadcastPlaybackState();
    _emitSnapshot();
  }

  Future<void> disposeHandler() async {
    _positionPersistTimer?.cancel();
    await _interruptionSubscription?.cancel();
    await _becomingNoisySubscription?.cancel();
    await _disposePlayerListeners();
    for (final subscription in _cacheProgressSubscriptions.values) {
      await subscription.cancel();
    }
    _cacheProgressSubscriptions.clear();
    await _persistSafely(_persistPosition, context: 'dispose handler');
    await _player.dispose();
    await _snapshotController.close();
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
    _updateScrobbleSession(null);
    queue.add(const <MediaItem>[]);
    mediaItem.add(null);
    if (persist) {
      await _playQueueDao.clearQueue();
    }
    _broadcastPlaybackState();
    _emitSnapshot();
  }
}

bool get _isAndroidRuntime => !kIsWeb && Platform.isAndroid;

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
