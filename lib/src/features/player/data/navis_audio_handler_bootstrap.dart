part of 'navis_audio_handler.dart';

Future<NavisPlaybackHandler>? _audioHandlerInitFuture;

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
  if (handler is LinuxNavisPlaybackHandler) {
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
  if (handler is LinuxNavisPlaybackHandler) {
    handler.beginTeardown();
    return;
  }
  if (handler is NavisAudioHandler) {
    handler.beginTeardown();
  }
}

Future<NavisPlaybackHandler> initNavisAudioHandler({
  required LibraryDao libraryDao,
  required PlaylistDao playlistDao,
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
      playlistDao: playlistDao,
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
    // Windows: bypass audio_service, bridge to SMTC directly.
    initFuture = Future<NavisPlaybackHandler>.value(
      WindowsNavisPlaybackHandler(createBaseHandler()),
    );
  } else if (_isLinuxRuntime) {
    // Linux: bypass audio_service, bridge to MPRIS D-Bus directly.
    // This replaces the incomplete audio_service_mpris integration which
    // did not implement Seek, SetPosition, Shuffle, or LoopStatus.
    initFuture = Future<NavisPlaybackHandler>.value(
      LinuxNavisPlaybackHandler(createBaseHandler()),
    );
  } else {
    initFuture = AudioService.init(
      builder: createBaseHandler,
      config: AudioServiceConfig(
        androidNotificationChannelId: 'playback',
        androidNotificationChannelName: 'Playback',
        androidNotificationIcon: 'drawable/ic_stat_navis_light',
        androidNotificationOngoing: false,
        androidStopForegroundOnPause: false,
        androidBrowsableRootExtras: const <String, dynamic>{
          AndroidAutoConstants.contentStyleSupportedKey: true,
          AndroidAutoConstants.contentStyleBrowsableHintKey:
              AndroidAutoConstants.contentStyleGrid,
          AndroidAutoConstants.contentStylePlayableHintKey:
              AndroidAutoConstants.contentStyleList,
          AndroidAutoConstants.searchSupportedKey: true,
        },
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
  Stream<PlaybackLoadFailure> get loadFailureStream =>
      _delegate.loadFailureStream;

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
  Future<void> replaceQueueWithData(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
  }) => _delegate.replaceQueueWithData(
    songs,
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

  @override
  void registerPreferredMixCallback(
    Future<void> Function(String seedSongId) callback,
  ) => _delegate.registerPreferredMixCallback(callback);

  @override
  void registerPreferredMixToggleCallback(
    Future<void> Function(String seedSongId) callback,
  ) => _delegate.registerPreferredMixToggleCallback(callback);
}

class LinuxNavisPlaybackHandler implements NavisPlaybackHandler {
  LinuxNavisPlaybackHandler(this._delegate) {
    _mprisBridge = LinuxMprisBridge(handler: this);
  }

  final NavisAudioHandler _delegate;
  late final LinuxMprisBridge _mprisBridge;

  void beginTeardown() {
    _delegate.beginTeardown();
    unawaited(_mprisBridge.dispose());
  }

  Future<void> dispose() async {
    await _mprisBridge.dispose();
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
  Stream<PlaybackLoadFailure> get loadFailureStream =>
      _delegate.loadFailureStream;

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
  Future<void> replaceQueueWithData(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
  }) => _delegate.replaceQueueWithData(
    songs,
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

  @override
  void registerPreferredMixCallback(
    Future<void> Function(String seedSongId) callback,
  ) => _delegate.registerPreferredMixCallback(callback);

  @override
  void registerPreferredMixToggleCallback(
    Future<void> Function(String seedSongId) callback,
  ) => _delegate.registerPreferredMixToggleCallback(callback);
}

/// Lightweight cancellation flag threaded through long-running queue
/// operations.  Call [checkCancelled] at async checkpoints to bail out
/// early when a newer command has superseded this one.
