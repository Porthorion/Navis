part of 'navis_audio_handler.dart';

_NavisAudioHandlerInitCacheEntry? _audioHandlerInitCache;
Future<SwitchAudioHandler>? _audioServiceInitialization;
SwitchAudioHandler? _audioServiceHandler;

class _NavisAudioHandlerInitCacheEntry {
  new(this.future);

  final Future<NavisPlaybackHandler> future;
  NavisPlaybackHandler? handler;
  bool invalidated = false;
}

Future<void> disposeNavisPlaybackHandler(NavisPlaybackHandler handler) async {
  _invalidateNavisAudioHandlerCache(handler);
  if (handler is _DelegatingNavisPlaybackHandler) {
    await handler.dispose();
    return;
  }
  if (handler is NavisAudioHandler) {
    await handler.disposeHandler();
  }
}

/// Retires session ownership during explicit teardown or completed failure.
/// A presentation timeout must keep this future: it does not stop construction.
void invalidateNavisPlaybackHandlerInitialization() {
  final cache = _audioHandlerInitCache;
  if (cache == null) {
    return;
  }
  cache.invalidated = true;
  if (identical(_audioHandlerInitCache, cache)) {
    _audioHandlerInitCache = null;
  }
}

void beginNavisPlaybackHandlerTeardown(NavisPlaybackHandler handler) {
  _invalidateNavisAudioHandlerCache(handler);
  if (handler is _DelegatingNavisPlaybackHandler) {
    handler.beginTeardown();
    return;
  }
  if (handler is NavisAudioHandler) {
    handler.beginTeardown();
  }
}

void _invalidateNavisAudioHandlerCache(NavisPlaybackHandler handler) {
  final cache = _audioHandlerInitCache;
  if (cache == null) {
    return;
  }
  if (cache.handler == null || identical(cache.handler, handler)) {
    cache.invalidated = true;
    if (identical(_audioHandlerInitCache, cache)) {
      _audioHandlerInitCache = null;
    }
  }
}

/// File service for the art AudioService downloads itself (notification, lock
/// screen, Bluetooth). AudioService fetches whatever `artUri` it is handed, so
/// every fetch goes through [allowUri]: it is rechecked after a download slot
/// is granted, on every redirect hop and immediately before dispatch.
/// [isServerUri] excludes own-server art from [recorder]. Missing-cover
/// recovery has no callback here, so an external id never requests repair.
CoverArtHttpFileService createSystemArtworkFileService({
  required bool Function(Uri uri) allowUri,
  NetworkUsageReporter? reportNetworkUsage,
  CoverArtLoadCoordinator? loadCoordinator,
  IntegrationCallRecorder? recorder,
  bool Function(Uri)? isServerUri,
  Uri Function(Uri)? authenticateUri,
}) => CoverArtHttpFileService(
  loadCoordinator: loadCoordinator,
  recorder: recorder,
  isServerUri: isServerUri,
  authenticateUri: authenticateUri,
  reportNetworkUsage: reportNetworkUsage,
  allowUri: allowUri,
);

Future<NavisPlaybackHandler> initNavisAudioHandler({
  required LibraryDao libraryDao,
  required PlaylistDao playlistDao,
  required PlayQueueDao playQueueDao,
  required MatchFlowDao matchFlowDao,
  required HistoryDao historyDao,
  required PlaybackSourceResolver sourceResolver,
  required SubsonicApiClient? Function() readApiClient,
  required CacheManager Function() readSystemArtworkCacheManager,
  required RollingCacheManager rollingCacheManager,
  required int Function() readRollingCacheBudgetBytes,
  required ScrobbleService scrobbleService,
  required ListenBrainzFeedbackService listenBrainzFeedbackService,
  required PlaybackRuntimeSettings Function() readRuntimeSettings,
  required StarSyncDao starSyncDao,
  Future<NetworkReconciliation> Function()? reconcileNetwork,
  Future<bool> Function()? checkDeviceConnected,
  Stream<void>? recoveredNetwork,
  double initialVolume = 1.0,
  NetworkUsageReporter? reportNetworkUsage,
  Future<File?> Function(String coverArtId)? readPermanentArtwork,
  void Function(RollingCacheActivity activity)? reportRollingCacheActivity,
  // Keep autoplay positional; the optional guard follows fallback ownership.
  // ignore: avoid_positional_boolean_parameters
  required Future<bool> Function(bool autoPlay, {bool Function()? isCurrent})
  startPersonalRadio,
  void Function(({int index, String songId})? queueEndSkip)?
  onPersonalRadioQueueEnd,
  required Future<void> Function(String) startPreferredMix,
  required Future<void> Function(String) togglePreferredMix,
  bool Function()? readRadioMetadataAllowed,
  bool Function(Uri stream)? readRadioPlaybackAllowed,
  bool Function(Uri uri)? readRadioArtworkAllowed,
  Dio Function()? createRadioMetadataDio,
  Future<String?> Function(MediaItem)? fetchWindowsArtwork,
  bool Function(MediaItem)? readWindowsArtworkAllowed,
  CoverArtHttpFileService? playbackArtworkFileService,
}) {
  final cached = _audioHandlerInitCache;
  if (cached != null && !cached.invalidated) {
    return cached.future;
  }

  NavisAudioHandler createBaseHandler() {
    return NavisAudioHandler(
      reconcileNetwork: reconcileNetwork,
      checkDeviceConnected: checkDeviceConnected,
      recoveredNetwork: recoveredNetwork,
      libraryDao: libraryDao,
      playlistDao: playlistDao,
      playQueueDao: playQueueDao,
      matchFlowDao: matchFlowDao,
      historyDao: historyDao,
      sourceResolver: sourceResolver,
      readApiClient: readApiClient,
      rollingCacheManager: rollingCacheManager,
      readRollingCacheBudgetBytes: readRollingCacheBudgetBytes,
      scrobbleService: scrobbleService,
      listenBrainzFeedbackService: listenBrainzFeedbackService,
      readRuntimeSettings: readRuntimeSettings,
      starSyncDao: starSyncDao,
      initialVolume: initialVolume,
      reportNetworkUsage: reportNetworkUsage,
      readPermanentArtwork: readPermanentArtwork,
      artworkFileService: playbackArtworkFileService,
      reportRollingCacheActivity: reportRollingCacheActivity,
      startPersonalRadio: startPersonalRadio,
      onPersonalRadioQueueEnd: onPersonalRadioQueueEnd,
      startPreferredMix: startPreferredMix,
      togglePreferredMix: togglePreferredMix,
      readRadioMetadataAllowed: readRadioMetadataAllowed,
      readRadioPlaybackAllowed: readRadioPlaybackAllowed,
      readRadioArtworkAllowed: readRadioArtworkAllowed,
      createRadioMetadataDio: createRadioMetadataDio,
    );
  }

  late final Future<NavisPlaybackHandler> initFuture;
  if (_isWindowsRuntime) {
    // Windows: bypass audio_service, bridge to SMTC directly.
    initFuture = Future<NavisPlaybackHandler>.value(
      WindowsNavisPlaybackHandler(
        createBaseHandler(),
        fetchArtwork: fetchWindowsArtwork,
        readArtworkAllowed: readWindowsArtworkAllowed,
      ),
    );
  } else if (_isLinuxRuntime) {
    // Linux: bypass audio_service, bridge to MPRIS D-Bus directly.
    // This replaces the incomplete audio_service_mpris integration which
    // did not implement Seek, SetPosition, Shuffle, or LoopStatus.
    initFuture = Future<NavisPlaybackHandler>.value(
      LinuxNavisPlaybackHandler(createBaseHandler()),
    );
  } else {
    // The system (notification, lock screen, Bluetooth, Android Auto,
    // CarPlay) sees real listening time; the app keeps the track-time handler.
    initFuture =
        (_isAndroidRuntime
                ? PackageInfo.fromPlatform().then((info) => info.packageName)
                : Future<String?>.value())
            .then((packageName) async {
              await PlaybackArtCache.initializeKey();
              return initNavisAudioServiceHandler(
                // Never AudioService's default cache, which would fetch any
                // published URL, a refused redirect target included.
                cacheManager: readSystemArtworkCacheManager(),
                builder: () {
                  final base = createBaseHandler();
                  return RealTimeProjectionAudioHandler(
                    base,
                    // The manifest's NavisArtworkProvider authority.
                    systemArt: packageName == null
                        ? null
                        : AndroidSystemArt(
                            authority: '$packageName.artwork',
                            fetch: base.cacheSystemArtwork,
                            cachedPath: base.cachedSystemArtwork,
                          ),
                  );
                },
              );
            })
            .then<NavisPlaybackHandler>((initialized) => initialized.handler);
  }

  final cache = _NavisAudioHandlerInitCacheEntry(initFuture);
  _audioHandlerInitCache = cache;
  unawaited(
    initFuture.then<void>(
      (handler) {
        if (identical(_audioHandlerInitCache, cache) && !cache.invalidated) {
          cache.handler = handler;
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_audioHandlerInitCache, cache)) {
          _audioHandlerInitCache = null;
        }
      },
    ),
  );
  return initFuture;
}

/// Initializes the mobile media-service path independently of the host platform.
@visibleForTesting
Future<({SwitchAudioHandler service, NavisPlaybackHandler handler})>
initNavisAudioServiceHandler({
  required RealTimeProjectionAudioHandler Function() builder,
  required BaseCacheManager cacheManager,
  Duration configureTimeout = const Duration(seconds: 5),
}) async {
  // audio_service owns process-wide callbacks and may only be initialized once.
  final handler = await (_audioServiceInitialization ??= AudioService.init(
    builder: SwitchAudioHandler.new,
    cacheManager: cacheManager,
    config: AudioServiceConfig(
      androidNotificationChannelId: 'playback',
      androidNotificationChannelName: 'Playback',
      androidNotificationIcon: 'drawable/ic_stat_navis_light',
      androidNotificationOngoing: false,
      androidStopForegroundOnPause: false,
      // Keeps the ALBUM_ART bitmap small for AVRCP and binder limits.
      androidArtDownscaleSize: const Size(512, 512),
      androidBrowsableRootExtras: const <String, dynamic>{
        AndroidAutoConstants.contentStyleSupportedKey: true,
        AndroidAutoConstants.contentStyleBrowsableHintKey:
            AndroidAutoConstants.contentStyleGrid,
        AndroidAutoConstants.contentStylePlayableHintKey:
            AndroidAutoConstants.contentStyleList,
        AndroidAutoConstants.searchSupportedKey: true,
      },
    ),
  )).timeout(configureTimeout);
  _audioServiceHandler = handler;
  final projection = builder();
  final base = projection.inner as NavisAudioHandler;
  base._systemProjection = projection;
  handler.inner = projection;
  return (service: handler, handler: base);
}

Future<void> _detachNavisAudioServiceHandler(NavisAudioHandler handler) {
  final projection = handler._systemProjection;
  if (projection == null) return Future<void>.value();
  final service = _audioServiceHandler;
  if (service != null && identical(service.inner, projection)) {
    service.inner = BaseAudioHandler();
  }
  return projection.dispose();
}

abstract class _DelegatingNavisPlaybackHandler
    implements NavisPlaybackHandler, PlaybackStartupObserver, QueueBatchEditor {
  new(this._delegate);

  final NavisAudioHandler _delegate;

  Future<void> _disposeBridge();

  void beginTeardown() {
    _delegate.beginTeardown();
    unawaited(_disposeBridge());
  }

  Future<void> dispose() async {
    await _disposeBridge();
    await _delegate.disposeHandler();
  }

  @override
  int beginPlaybackSelection(
    String songId, {
    required bool isExternal,
    SongsTableData? song,
  }) => _delegate.beginPlaybackSelection(
    songId,
    isExternal: isExternal,
    song: song,
  );

  @override
  void notePlaybackSelectionStage(int attempt, String stage) =>
      _delegate.notePlaybackSelectionStage(attempt, stage);

  @override
  bool isPlaybackSelectionCurrent(int attempt) =>
      _delegate.isPlaybackSelectionCurrent(attempt);

  @override
  Future<QueueBatchEditResult> mergeIntoUpcoming(
    List<SongsTableData> songs, {
    required int notBefore,
    math.Random? random,
  }) =>
      _delegate.mergeIntoUpcoming(songs, notBefore: notBefore, random: random);

  @override
  Future<QueueBatchEditResult> insertQueueRuns(List<QueueInsertRun> runs) =>
      _delegate.insertQueueRuns(runs);

  @override
  PlaybackSnapshot get snapshot => _delegate.snapshot;

  @override
  Stream<PlaybackSnapshot> get snapshotStream => _delegate.snapshotStream;

  @override
  Stream<TransportVisualCue> get transportVisualCueStream =>
      _delegate.transportVisualCueStream;

  @override
  Stream<Duration> get positionStream => _delegate.positionStream;

  @override
  PlaybackBufferState get bufferState => _delegate.bufferState;

  @override
  Stream<PlaybackBufferState> get bufferStateStream =>
      _delegate.bufferStateStream;

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
  Stream<QueueSongsDropped> get droppedSongsStream =>
      _delegate.droppedSongsStream;

  @override
  Future<void> waitUntilReady() => _delegate.waitUntilReady();

  @override
  Future<void> replaceQueue(
    List<String> songIds, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    List<String>? originalOrder,
  }) => _delegate.replaceQueue(
    songIds,
    startIndex: startIndex,
    autoPlay: autoPlay,
    expandMatchFlows: expandMatchFlows,
    originalOrder: originalOrder,
  );

  @override
  Future<void> replaceQueueWithData(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    List<String>? originalOrder,
  }) => _delegate.replaceQueueWithData(
    songs,
    startIndex: startIndex,
    autoPlay: autoPlay,
    expandMatchFlows: expandMatchFlows,
    originalOrder: originalOrder,
  );

  @override
  Future<void> addToQueue(
    List<String> songIds, {
    bool expandMatchFlows = true,
  }) => _delegate.addToQueue(songIds, expandMatchFlows: expandMatchFlows);

  @override
  Future<void> playNext(List<String> songIds, {bool expandMatchFlows = true}) =>
      _delegate.playNext(songIds, expandMatchFlows: expandMatchFlows);

  @override
  Future<void> retainCurrentSongAsQueue(String songId) =>
      _delegate.retainCurrentSongAsQueue(songId);

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
  Future<void> resetSession() => _delegate.resetSession();

  @override
  Future<void> play() => _delegate.play();

  @override
  Future<void> pause() => _delegate.pause();

  @override
  Future<void> stop() => _delegate.stop();

  @override
  Future<void> seek(Duration position) => _delegate.seek(position);

  @override
  Future<void> previewSeek(Duration position) =>
      _delegate.previewSeek(position);

  @override
  void cancelSeekPreview() => _delegate.cancelSeekPreview();

  @override
  Map<String, Object?> collectPlaybackDiagnostics() =>
      _delegate.collectPlaybackDiagnostics();

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
  PlaybackAdjustments get playbackAdjustments => _delegate.playbackAdjustments;

  @override
  Stream<PlaybackAdjustments> get playbackAdjustmentsStream =>
      _delegate.playbackAdjustmentsStream;

  @override
  PlaybackAdjustmentCapabilities get playbackAdjustmentCapabilities =>
      _delegate.playbackAdjustmentCapabilities;

  @override
  Future<void> setPlaybackAdjustments(PlaybackAdjustments values) =>
      _delegate.setPlaybackAdjustments(values);

  @override
  EqCapabilities get equalizerCapabilities => _delegate.equalizerCapabilities;

  @override
  EqApplicationState get equalizerState => _delegate.equalizerState;

  @override
  Stream<EqApplicationState> get equalizerStateStream =>
      _delegate.equalizerStateStream;

  @override
  Future<void> setEqualizer(EqConfiguration values) =>
      _delegate.setEqualizer(values);

  @override
  Future<void> refreshEqualizerState() => _delegate.refreshEqualizerState();

  @override
  Future<void> setVolume(double volume) => _delegate.setVolume(volume);

  @override
  Future<void> applyRuntimeSettings() => _delegate.applyRuntimeSettings();

  @override
  Future<void> retryDeferredQueueRestore() =>
      _delegate.retryDeferredQueueRestore();

  @override
  Future<void> applySongIdentityAliases(Map<String, String> aliases) =>
      _delegate.applySongIdentityAliases(aliases);

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
    bool replaceMetadata = false,
  }) => _delegate.updateRadioMetadata(
    title: title,
    artist: artist,
    artUrl: artUrl,
    replaceMetadata: replaceMetadata,
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

class WindowsNavisPlaybackHandler extends _DelegatingNavisPlaybackHandler {
  new(
    super._delegate, {
    Future<String?> Function(MediaItem)? fetchArtwork,
    bool Function(MediaItem)? readArtworkAllowed,
  }) {
    _smtcBridge = WindowsSmtcBridge(
      handler: this,
      fetchArtwork: fetchArtwork,
      readArtworkAllowed: readArtworkAllowed,
    );
  }

  @visibleForTesting
  new forTesting(super._delegate, {required WindowsSmtcBridge bridge})
    : _smtcBridge = bridge;

  late final WindowsSmtcBridge _smtcBridge;

  @override
  Future<void> _disposeBridge() => _smtcBridge.dispose();
}

class LinuxNavisPlaybackHandler extends _DelegatingNavisPlaybackHandler {
  new(super._delegate) {
    _mprisBridge = LinuxMprisBridge(handler: this);
  }

  @visibleForTesting
  new forTesting(super._delegate, {required LinuxMprisBridge bridge})
    : _mprisBridge = bridge;

  late final LinuxMprisBridge _mprisBridge;

  @override
  Future<void> _disposeBridge() => _mprisBridge.dispose();
}

/// Lightweight cancellation flag threaded through long-running queue
/// operations.  Call [checkCancelled] at async checkpoints to bail out
/// early when a newer command has superseded this one.

/// Harness only (clone-mode diagnostics): see `navisDiagnosticsRawSeekBack`.
Future<bool> navisDiagnosticsRawSeekBack(NavisPlaybackHandler handler) async {
  final inner = handler is NavisAudioHandler
      ? handler
      : handler is _DelegatingNavisPlaybackHandler
      ? handler._delegate
      : null;
  if (inner == null) return false;
  await inner.customAction('navisDiagnosticsRawSeekBack');
  return true;
}
