import 'dart:async';
import 'dart:math' as math;
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
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
  Future<void> applyRuntimeSettings();
}

class PlaybackRuntimeSettings {
  const PlaybackRuntimeSettings({
    required this.gaplessEnabled,
  });

  const PlaybackRuntimeSettings.defaults() : gaplessEnabled = true;

  final bool gaplessEnabled;
}

Future<NavisAudioHandler> initNavisAudioHandler({
  required LibraryDao libraryDao,
  required PlayQueueDao playQueueDao,
  required PlaybackSourceResolver sourceResolver,
  required RollingCacheManager rollingCacheManager,
  required int rollingCacheBudgetBytes,
  required ScrobbleService scrobbleService,
  required PlaybackRuntimeSettings Function() readRuntimeSettings,
}) {
  return AudioService.init(
    builder: () => NavisAudioHandler(
      libraryDao: libraryDao,
      playQueueDao: playQueueDao,
      sourceResolver: sourceResolver,
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
}

class NavisAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler
    implements NavisPlaybackHandler {
  NavisAudioHandler({
    required LibraryDao libraryDao,
    required PlayQueueDao playQueueDao,
    required PlaybackSourceResolver sourceResolver,
    required RollingCacheManager rollingCacheManager,
    required int rollingCacheBudgetBytes,
    required ScrobbleService scrobbleService,
    required PlaybackRuntimeSettings Function() readRuntimeSettings,
    AudioPlayer? player,
  }) : _libraryDao = libraryDao,
       _playQueueDao = playQueueDao,
       _sourceResolver = sourceResolver,
       _rollingCacheManager = rollingCacheManager,
       _rollingCacheBudgetBytes = rollingCacheBudgetBytes,
       _scrobbleService = scrobbleService,
       _readRuntimeSettings = readRuntimeSettings,
       _player = player ?? AudioPlayer() {
    _wirePlayerListeners();
    _positionPersistTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_persistPosition()),
    );
    _ready = _initialize();
  }

  final LibraryDao _libraryDao;
  final PlayQueueDao _playQueueDao;
  final PlaybackSourceResolver _sourceResolver;
  final RollingCacheManager _rollingCacheManager;
  final int _rollingCacheBudgetBytes;
  final ScrobbleService _scrobbleService;
  final PlaybackRuntimeSettings Function() _readRuntimeSettings;
  final AudioPlayer _player;

  final StreamController<PlaybackSnapshot> _snapshotController =
      StreamController<PlaybackSnapshot>.broadcast();

  final List<MediaItem> _queueItems = <MediaItem>[];

  PlaybackSnapshot _snapshot = const PlaybackSnapshot.idle();
  Timer? _positionPersistTimer;
  late final Future<void> _ready;
  Future<void> _inFlight = Future<void>.value();
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _becomingNoisySubscription;
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
  Future<void> waitUntilReady() => _ready;

  Future<void> _initialize() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    _wireAudioSession(session);
    await applyRuntimeSettings();
    await _rollingCacheManager.pruneMissingFiles();
    await _rollingCacheManager.enforceBudget(
      maxBytes: _rollingCacheBudgetBytes,
    );
    await _scrobbleService.flushDue();
    try {
      await _restoreQueueFromDisk();
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Queue restore failed. Clearing persisted queue to keep playback functional.',
        error,
        stackTrace,
      );
      await _playQueueDao.clearQueue();
      await _clearQueueInternal(persist: false);
    }
    _emitSnapshot();
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
    _player.playbackEventStream.listen(
      (_) {
        _handleScrobbleSignals();
        _broadcastPlaybackState();
        _emitSnapshot();
      },
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.error('Playback event stream error.', error, stackTrace);
      },
    );

    _player.currentIndexStream.listen((index) {
      final item = _mediaItemForIndex(index);
      mediaItem.add(item);
      _updateScrobbleSession(item);
      _emitSnapshot();
      unawaited(_persistQueueState(includePosition: false));
    });

    _player.shuffleModeEnabledStream.listen((_) {
      _broadcastPlaybackState();
      unawaited(_persistQueueState(includePosition: false));
    });

    _player.loopModeStream.listen((_) {
      _broadcastPlaybackState();
      unawaited(_persistQueueState(includePosition: false));
    });
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

    var restored = false;
    Object? terminalRestoreError;
    StackTrace? terminalRestoreStackTrace;
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        await _setQueueFromSongs(
          queuedSongs,
          startIndex: startIndex,
          autoPlay: false,
          initialPosition: restorePosition,
          persist: false,
        );
        restored = true;
        break;
      } on PlaybackSourceUnavailableException {
        if (attempt == 5) {
          AppLogger.warning(
            'Playback queue restore skipped because auth/session was unavailable.',
          );
          break;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      } on Object catch (error, stackTrace) {
        terminalRestoreError = error;
        terminalRestoreStackTrace = stackTrace;
        break;
      }
    }

    if (!restored) {
      if (terminalRestoreError != null) {
        AppLogger.warning(
          'Queue restore failed with an unrecoverable source/setup error. '
          'Clearing persisted queue. '
          '$terminalRestoreError\n$terminalRestoreStackTrace',
        );
        await _playQueueDao.clearQueue();
        await _clearQueueInternal(persist: false);
      }
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
          _registerRollingCacheTrack(song: song, cacheFilePath: cacheFilePath),
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
        format: song.suffix ?? song.contentType,
        bitRate: song.bitRate,
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
      );
    } on Object catch (error, stackTrace) {
      final usedLockCaching = prepared.any(
        (item) => item.source.kind == PlaybackSourceKind.lockCachedStream,
      );
      if (!usedLockCaching) {
        rethrow;
      }
      AppLogger.warning(
        'Lock-cached playback source setup failed. '
        'Retrying queue build with direct stream sources. '
        'sources=${prepared.map((entry) => entry.source.kind.name).toList()} '
        '$error\n$stackTrace',
      );
      prepared = await _prepareQueueItems(
        songs,
        preferLockCaching: false,
      );
      await _applyPreparedQueue(
        prepared,
        startIndex: clampedIndex,
        autoPlay: autoPlay,
        initialPosition: initialPosition,
      );
    }

    for (final entry in prepared) {
      if (entry.source.kind == PlaybackSourceKind.lockCachedStream &&
          entry.source.lockCachingAudioSource != null &&
          entry.source.cachedFilePath != null) {
        _observeLockCachingSource(
          song: entry.song,
          source: entry.source.lockCachingAudioSource!,
          cacheFilePath: entry.source.cachedFilePath!,
        );
      }
    }

    if (persist) {
      await _persistQueueState(includeQueueItems: true);
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
  }) async {
    _queueItems
      ..clear()
      ..addAll(prepared.map((entry) => entry.mediaItem));

    final audioSources = prepared
        .map((entry) => entry.audioSource)
        .toList(growable: false);

    await _player.setAudioSources(
      audioSources,
      preload: _gaplessEnabled || autoPlay,
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
      await _persistQueueState();
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
    await _player.play();
    await _persistQueueState(includePosition: false);
  }

  @override
  Future<void> pause() async {
    await _ready;
    await _player.pause();
    await _persistPosition();
  }

  @override
  Future<void> applyRuntimeSettings() async {
    final runtime = _readRuntimeSettings();
    _gaplessEnabled = runtime.gaplessEnabled;
  }

  @override
  Future<void> seek(Duration position) async {
    await _ready;
    await _player.seek(position);
    await _persistPosition();
  }

  @override
  Future<void> skipToNext() async {
    await _ready;
    await _player.seekToNext();
    await _persistQueueState();
  }

  @override
  Future<void> skipToPrevious() async {
    await _ready;
    await _player.seekToPrevious();
    await _persistQueueState();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    await _ready;
    final enabled = shuffleMode == AudioServiceShuffleMode.all;
    await _player.setShuffleModeEnabled(enabled);
    if (enabled) {
      await _player.shuffle();
    }
    await _persistQueueState(includePosition: false);
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
    await _persistQueueState(includePosition: false);
    _broadcastPlaybackState();
    _emitSnapshot();
  }

  @override
  Future<void> stop() async {
    await _persistPosition();
    await _player.stop();
    await super.stop();
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
      controls: <MediaControl>[
        MediaControl.skipToPrevious,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const <MediaAction>{
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const <int>[0, 1, 3],
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
    await _persistPosition();
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
    return super.customAction(name, extras);
  }

  Future<void> disposeHandler() async {
    _positionPersistTimer?.cancel();
    await _interruptionSubscription?.cancel();
    await _becomingNoisySubscription?.cancel();
    for (final subscription in _cacheProgressSubscriptions.values) {
      await subscription.cancel();
    }
    _cacheProgressSubscriptions.clear();
    await _persistPosition();
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
