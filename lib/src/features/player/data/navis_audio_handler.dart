import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/daos/history_dao.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/daos/match_flow_dao.dart';
import 'package:navis/src/database/daos/playlist_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/daos/play_queue_dao.dart';
import 'package:navis/src/database/daos/star_sync_dao.dart';
import 'package:navis/src/database/tables/schema_enums.dart' as schema;
import 'package:navis/src/features/auto/data/auto_media_id.dart';
import 'package:navis/src/features/auto/data/android_auto_browse_notifier.dart';
import 'package:navis/src/features/auto/data/auto_media_tree_service.dart';
import 'package:navis/src/features/auto/domain/android_auto_constants.dart';
import 'package:navis/src/features/cache/data/rolling_cache_manager.dart';
import 'package:navis/src/features/cache/data/rolling_cache_sidecar_downloader.dart';
import 'package:navis/src/features/player/data/real_time_projection_audio_handler.dart';
import 'package:navis/src/features/player/data/playback_art_cache.dart';
import 'package:navis/src/features/player/data/playback_navigation_intent.dart';
import 'package:navis/src/features/player/data/playback_startup_trace.dart';
import 'package:navis/src/features/player/data/listenbrainz_feedback_service.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/data/radio_metadata_service.dart';
import 'package:navis/src/features/player/data/scrobble_service.dart';
import 'package:navis/src/features/player/data/linux_mpris_bridge.dart';
import 'package:navis/src/features/player/data/windows_smtc_bridge.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/catalog_source.dart';
import 'package:navis/src/utils/network_usage_meter.dart';
import 'package:rxdart/rxdart.dart';

part 'navis_playback_handler_contract.dart';
part 'navis_playback_rules.dart';
part 'navis_audio_handler_bootstrap.dart';
part 'navis_playback_lanes.dart';
part 'navis_audio_handler_support.dart';
part 'navis_queue_window.dart';

/// Produces queue identities without replacing an explicitly supplied remote
/// source with a locally reconciled match.
@visibleForTesting
List<String> navisQueueSourceIds(
  Iterable<SongsTableData> songs, {
  required String Function(String songId) canonicalize,
}) {
  return <String>[
    for (final song in songs) song.isExternal ? song.id : canonicalize(song.id),
  ];
}

class NavisAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler
    implements NavisPlaybackHandler, PlaybackStartupObserver, QueueBatchEditor {
  NavisAudioHandler({
    required LibraryDao libraryDao,
    required PlaylistDao playlistDao,
    required PlayQueueDao playQueueDao,
    required MatchFlowDao matchFlowDao,
    required HistoryDao historyDao,
    required PlaybackSourceResolver sourceResolver,
    required SubsonicApiClient? Function() readApiClient,
    required RollingCacheManager rollingCacheManager,
    required int Function() readRollingCacheBudgetBytes,
    required ScrobbleService scrobbleService,
    required ListenBrainzFeedbackService listenBrainzFeedbackService,
    required PlaybackRuntimeSettings Function() readRuntimeSettings,
    required StarSyncDao starSyncDao,
    double initialVolume = 1.0,
    NetworkUsageReporter? reportNetworkUsage,
    void Function(RollingCacheActivity activity)? reportRollingCacheActivity,
    Future<bool> Function(bool autoPlay)? startPersonalRadio,
    Future<void> Function(String)? startPreferredMix,
    Future<void> Function(String)? togglePreferredMix,
    AudioPlayer? player,
    PlaybackAdjustmentCapabilities? adjustmentCapabilities,
    EqCapabilities? equalizerCapabilities,
    AudioPlayer Function()? crossfadePlayerFactory,
    AudioPlayer Function()? playerFactory,
    NavisQueueWindow queueWindow = const NavisQueueWindow(),
    NavisPlaybackTimeouts timeouts = const NavisPlaybackTimeouts(),
  }) : _queueWindow = queueWindow,
       _timeouts = timeouts,
       _playerFactory = playerFactory,
       _adjustmentCapabilities = adjustmentCapabilities,
       _injectedEqualizerCapabilities = equalizerCapabilities,
       _crossfadePlayerFactory = crossfadePlayerFactory,
       _libraryDao = libraryDao,
       _playlistDao = playlistDao,
       _playQueueDao = playQueueDao,
       _matchFlowDao = matchFlowDao,
       _historyDao = historyDao,
       _sourceResolver = sourceResolver,
       _readApiClient = readApiClient,
       _rollingCacheManager = rollingCacheManager,
       _readRollingCacheBudgetBytes = readRollingCacheBudgetBytes,
       _scrobbleService = scrobbleService,
       _listenBrainzFeedbackService = listenBrainzFeedbackService,
       _readRuntimeSettings = readRuntimeSettings,
       _starSyncDao = starSyncDao,
       _userVolume = initialVolume.isFinite
           ? initialVolume.clamp(0.0, 1.0)
           : 1.0,
       _reportNetworkUsage = reportNetworkUsage,
       _reportRollingCacheActivity = reportRollingCacheActivity,
       _startPersonalRadio = startPersonalRadio,
       _preferredMixCallback = startPreferredMix,
       _preferredMixToggleCallback = togglePreferredMix,
       _artCache = _isAndroidRuntime
           ? PlaybackArtCache(reportNetworkUsage: reportNetworkUsage)
           : null {
    final runtime = _readRuntimeSettings();
    _desiredEqualizer = runtime.equalizer ?? EqConfiguration.flat();
    if (player != null) {
      _equalizerPipelineEnabled = equalizerCapabilities?.supported ?? false;
      _player = player;
    } else {
      _equalizerPipelineEnabled =
          _isAndroidRuntime ||
          (Platform.isLinux && JustAudioMediaKit.isRegistered);
      _player = _buildAudioPlayer(enableEqualizer: _equalizerPipelineEnabled);
    }
    _crossfadeEnabled = runtime.crossfadeEnabled;
    _crossfadePlayer = runtime.crossfadeEnabled ? _newCrossfadePlayer() : null;
    _radioMetadataService = RadioMetadataService(
      handler: this,
      player: _player,
    );
    _wirePlayerListeners();
    _queueLane.onDrained = _maybeReleaseTail;
    _queueEmissionCounter = queue.listen((items) {
      _queueEmissionCount++;
      _queueEmittedItemCount += items.length;
    });
    _positionPersistTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(
        _persistSafely(_persistPosition, context: 'periodic position timer'),
      ),
    );
    _ready = _initialize();
    _autoMediaTreeService = AutoMediaTreeService(
      libraryDao: _libraryDao,
      playlistDao: _playlistDao,
      playQueueDao: _playQueueDao,
      historyDao: _historyDao,
      readApiClient: _readApiClient,
      readDownloadedSongIds: _rollingCacheManager.getPermanentlyCachedSongIds,
    );
  }

  final PlaybackAdjustmentCapabilities? _adjustmentCapabilities;
  final EqCapabilities? _injectedEqualizerCapabilities;
  final AudioPlayer Function()? _crossfadePlayerFactory;

  /// Builds the main player instead of the platform player (tests).
  final AudioPlayer Function()? _playerFactory;
  final NavisPlaybackTimeouts _timeouts;

  AudioPlayer _newCrossfadePlayer() =>
      _crossfadePlayerFactory?.call() ?? _buildBaseAudioPlayer();

  final LibraryDao _libraryDao;
  final PlaylistDao _playlistDao;
  final PlayQueueDao _playQueueDao;
  final MatchFlowDao _matchFlowDao;
  final HistoryDao _historyDao;
  final PlaybackSourceResolver _sourceResolver;
  final SubsonicApiClient? Function() _readApiClient;
  final RollingCacheManager _rollingCacheManager;
  final int Function() _readRollingCacheBudgetBytes;
  final ScrobbleService _scrobbleService;
  final ListenBrainzFeedbackService _listenBrainzFeedbackService;
  final PlaybackRuntimeSettings Function() _readRuntimeSettings;
  final StarSyncDao _starSyncDao;
  final NetworkUsageReporter? _reportNetworkUsage;
  final void Function(RollingCacheActivity activity)?
  _reportRollingCacheActivity;
  final Future<bool> Function(bool autoPlay)? _startPersonalRadio;
  late final AutoMediaTreeService _autoMediaTreeService;
  final AndroidAutoBrowseNotifier _androidAutoBrowseNotifier =
      AndroidAutoBrowseNotifier();
  // Only instantiated on Android: downloads cover art to local files so that
  // audio_service can populate METADATA_KEY_ALBUM_ART on the MediaSession,
  // which AAOS uses for the background art behind playback controls.
  final PlaybackArtCache? _artCache;
  late AudioPlayer _player;
  // Diagnostics-only counters; cheap monotonic integers reported through
  // collectPlaybackDiagnostics().
  int _snapshotBroadcastCount = 0;
  int _queueEmissionCount = 0;
  int _queueEmittedItemCount = 0;
  int _timedPlayerOperationCount = 0;
  int _nativeMoveCount = 0;
  StreamSubscription<List<MediaItem>>? _queueEmissionCounter;

  /// Stage timings (ms since phase 2 start) of the latest background queue
  /// fill, exposed through diagnostics. Counts only; no song identities.
  Map<String, Object?>? _lastQueueFill;
  int _queueFillResolveMs = 0;
  int _queueFillNativeMs = 0;
  int _queueFillBatches = 0;

  /// Persistence-lane operations that ran for at least 500 ms (diagnostics).
  final List<Map<String, Object?>> _slowPersistence = <Map<String, Object?>>[];
  int _persistOperationCount = 0;
  int _persistRunMs = 0;
  final Map<String, int> _persistContextCounts = <String, int>{};
  bool _equalizerPipelineEnabled = false;

  final StreamController<PlaybackSnapshot> _snapshotController =
      StreamController<PlaybackSnapshot>.broadcast();
  final StreamController<TransportVisualCue> _transportVisualCueController =
      StreamController<TransportVisualCue>.broadcast();

  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<PlaybackBufferState> _bufferStateController =
      StreamController<PlaybackBufferState>.broadcast();

  final StreamController<void> _radioStreamErrorController =
      StreamController<void>.broadcast();
  final StreamController<QueueSongsDropped> _droppedSongsController =
      StreamController<QueueSongsDropped>.broadcast();
  final StreamController<PlaybackLoadFailure> _loadFailureController =
      StreamController<PlaybackLoadFailure>.broadcast();

  /// Materialised queue: mirrors the native player's playlist one to one.
  final _RevisionedList<MediaItem> _queueItems = _RevisionedList<MediaItem>();

  /// Songs queued after [_queueItems] that the native player does not hold
  /// yet; released in pages as playback approaches them.
  final _RevisionedList<_DeferredQueueEntry> _deferredTail =
      _RevisionedList<_DeferredQueueEntry>();

  /// The caller's rows for remote songs that are, or were, materialised,
  /// so a remote song moved back into [_deferredTail] keeps its own row
  /// instead of being re-read by id (which misses it, or finds the local
  /// song it was matched to). Pruned to the materialised queue as it grows.
  final Map<String, SongsTableData> _remoteRows = <String, SongsTableData>{};
  final NavisQueueWindow _queueWindow;
  List<String>? _logicalIdsCache;
  int _logicalIdsQueueRevision = -1;
  int _logicalIdsTailRevision = -1;

  /// The user's repeat mode. The native player loops only once nothing is
  /// deferred; wrapping earlier would skip the deferred songs.
  LoopMode _desiredLoopMode = LoopMode.off;
  int _tailReleaseCount = 0;
  int _tailReleasedSongCount = 0;
  int _tailDroppedSongCount = 0;
  int _tailReleaseFailures = 0;
  DateTime? _tailReleaseRetryAt;
  List<String>? _pendingLogicalQueueSongIds;
  List<SongsTableData>? _pendingLogicalQueueSongs;
  MediaItem? _currentMediaItem;
  NavisQueueReplacementMetadataAnchor? _queueReplacementMetadataAnchor;

  PlaybackSnapshot _snapshot = const PlaybackSnapshot.idle();
  PlaybackBufferState _bufferState = const PlaybackBufferState.idle();
  Timer? _positionPersistTimer;
  late final Future<void> _ready;
  Future<bool>? _prepareQueueForUserPlayInFlight;
  final NavisSupersedingLane _queueLane = NavisSupersedingLane();
  final _seekLane = NavisSupersedingLane();
  final _playbackLane = _SerializationLane();
  final PlaybackNavigationIntent _navigationIntent = PlaybackNavigationIntent();
  DateTime? _navigationIssuedAt;
  int _navigationSupersededCount = 0;
  int _navigationCompletedCount = 0;
  int _navigationTimeoutCount = 0;
  int? _navigationInFlightRevision;
  String _queueRestoreOutcome = 'not_attempted';
  int _transportGeneration = 0;
  bool? _latestExplicitTransportPlaying;
  Timer? _transportPersistTimer;
  Timer? _queueItemsPersistTimer;
  String? _queueItemsPersistContext;
  DateTime? _queueItemsPersistFirstScheduledAt;
  Future<void> _persistTail = Future<void>.value();
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _becomingNoisySubscription;
  StreamSubscription<PlaybackEvent>? _playbackEventSubscription;
  StreamSubscription<int?>? _currentIndexSubscription;
  StreamSubscription<bool>? _shuffleModeSubscription;
  StreamSubscription<LoopMode>? _loopModeSubscription;
  StreamSubscription<Duration>? _activePositionSubscription;
  StreamSubscription<Duration>? _bufferedPositionSubscription;
  final Map<String, StreamSubscription<double>> _cacheProgressSubscriptions =
      <String, StreamSubscription<double>>{};
  final Map<String, RollingCacheActivity> _rollingCacheActivities =
      <String, RollingCacheActivity>{};
  final Set<String> _lockCachingBypassedSongIds = <String>{};
  final List<Map<String, Object?>> _seekDiagnosticsEvents =
      <Map<String, Object?>>[];
  static const int _maxSeekDiagnosticsEvents = 32;
  final RollingCacheSidecarDownloader _sidecarDownloader =
      RollingCacheSidecarDownloader();
  final Map<String, SongsTableData> _sidecarSongsById =
      <String, SongsTableData>{};
  final Map<String, String> _songIdentityAliases = <String, String>{};
  Timer? _remotePlaybackStallTimer;
  Timer? _seekBufferingRecoveryTimer;
  String? _remotePlaybackStallSongId;
  Duration? _remotePlaybackStallPosition;
  Duration? _remotePlaybackStallBufferedPosition;
  bool _remotePlaybackRecoveryInProgress = false;
  final Set<String> _remotePlaybackRecoveryAttempts = <String>{};
  bool _isDucked = false;
  // The most-recently requested user volume (0–1). Used as the reference level
  // for ducking and crossfade restoration so track changes never override the
  // user's chosen volume.
  double _userVolume;
  bool _resumeAfterInterruption = false;
  bool _gaplessEnabled = true;
  MediaItem? _activeScrobbleItem;
  int? _activeScrobbleIndex;
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
  int _transportVisualCueToken = 0;

  /// The queue index of the track loaded on `_crossfadePlayer`.
  int? _crossfadeTargetIndex;

  /// Non-null while a radio stream is active.
  RadioStationMetadata? _radioStation;

  /// Manages ICY / Azuracast metadata polling for radio streams.
  late RadioMetadataService _radioMetadataService;
  Future<void>? _playerDisposalFuture;
  bool _disposeHandlerStarted = false;
  bool _disposeHandlerCompleted = false;
  Duration get _playerLoadTimeout => _timeouts.load;
  Duration get _remotePlaybackStallTimeout => _timeouts.remoteStall;
  Duration get _seekBufferingRecoveryTimeout => _timeouts.seekBufferingRecovery;
  Duration get _playerResetTimeout => _timeouts.reset;
  Duration get _playerControlTimeout => _timeouts.control;
  int _loadGeneration = 0;
  int _activeLoadGeneration = 0;
  String? _loadingSongId;
  String? _lastFailedSongId;
  bool _isLoading = false;
  final List<PlaybackStartupTrace> _startupTraces = <PlaybackStartupTrace>[];
  PlaybackStartupTrace? _activeStartupTrace;
  int _nextStartupAttempt = 0;

  /// Called before provisional remote-song persistence begins.
  @override
  int beginPlaybackSelection(String songId, {required bool isExternal}) {
    _activeStartupTrace?.mark('superseded');
    final trace = PlaybackStartupTrace(
      attempt: ++_nextStartupAttempt,
      songId: songId,
      isExternal: isExternal,
      awaitingHandler: true,
    );
    _activeStartupTrace = trace;
    _startupTraces.add(trace);
    if (_startupTraces.length > 16) {
      _startupTraces.removeAt(0);
    }
    return trace.attempt;
  }

  /// Records a safe stage name; no media identity is exposed in diagnostics.
  @override
  void notePlaybackSelectionStage(int attempt, String stage) {
    final trace = _activeStartupTrace;
    if (trace?.attempt == attempt) {
      trace?.mark(stage);
    }
  }

  @override
  bool isPlaybackSelectionCurrent(int attempt) =>
      _activeStartupTrace?.attempt == attempt &&
      _activeStartupTrace?.awaitingHandler == true;

  void _invalidatePendingStartupSelection() {
    _activeStartupTrace?.mark('superseded');
    _activeStartupTrace = null;
  }

  void _acceptStartupSelection(String songId, {required bool isExternal}) {
    final trace = _activeStartupTrace;
    if (trace == null || !trace.awaitingHandler || trace.songId != songId) {
      beginPlaybackSelection(songId, isExternal: isExternal);
    }
    _activeStartupTrace?.awaitingHandler = false;
    _activeStartupTrace?.mark('handlerAccepted');
  }

  @override
  PlaybackSnapshot get snapshot => _snapshot;

  @override
  Stream<PlaybackSnapshot> get snapshotStream => _snapshotController.stream;

  @override
  Stream<TransportVisualCue> get transportVisualCueStream =>
      _transportVisualCueController.stream;

  @override
  Stream<void> get radioStreamErrorStream => _radioStreamErrorController.stream;

  @override
  Stream<PlaybackLoadFailure> get loadFailureStream =>
      _loadFailureController.stream;

  @override
  Stream<QueueSongsDropped> get droppedSongsStream =>
      _droppedSongsController.stream;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  PlaybackBufferState get bufferState => _bufferState;

  @override
  Stream<PlaybackBufferState> get bufferStateStream =>
      _bufferStateController.stream;

  @override
  MediaItem? get currentMediaItem => _currentMediaItem;

  @override
  Stream<MediaItem?> get mediaItemStream => mediaItem;

  @override
  Future<void> waitUntilReady() => _ready;

  // ── Android Auto browse tree ────────────────────────────────────────────

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) => _autoMediaTreeService.getChildren(parentMediaId, options);

  @override
  ValueStream<Map<String, dynamic>> subscribeToChildren(
    String parentMediaId,
  ) =>
      _androidAutoBrowseNotifier.streamFor(parentMediaId) ??
      super.subscribeToChildren(parentMediaId);

  @override
  Future<MediaItem?> getMediaItem(String mediaId) =>
      _autoMediaTreeService.getMediaItem(mediaId);

  @override
  Future<List<MediaItem>> search(
    String query, [
    Map<String, dynamic>? extras,
  ]) => _autoMediaTreeService.search(query, extras);

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    AppLogger.info('Android Auto playFromMediaId mediaId=$mediaId');
    await _runAndroidAutoLoad(
      () => _loadFromMediaId(mediaId, autoPlay: true),
      failureMessage: 'Unable to play this item.',
    );
  }

  @override
  Future<void> prepare() async {
    AppLogger.info('Android Auto prepare requested.');
    await _ready;
    await _restorePersistedQueueForPrepareIfEmpty();
    _broadcastPlaybackState();
    _emitSnapshot();
  }

  @override
  Future<void> prepareFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    AppLogger.info('Android Auto prepareFromMediaId mediaId=$mediaId');
    await _runAndroidAutoLoad(
      () => _loadFromMediaId(mediaId, autoPlay: false),
      failureMessage: 'Unable to prepare this item.',
    );
  }

  @override
  Future<void> prepareFromSearch(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    AppLogger.info('Android Auto prepareFromSearch query="$query"');
    await _runAndroidAutoLoad(
      () => _loadFromSearch(query, extras, autoPlay: false),
      failureMessage: 'No matching music was found.',
    );
  }

  Future<bool> _loadFromMediaId(
    String mediaId, {
    required bool autoPlay,
  }) async {
    // Handle special root-level playable/browsable nodes by raw ID.
    switch (mediaId) {
      case AutoMediaRoot.shuffleLiked:
        final songs = await _libraryDao.watchAllStarredSongs().first;
        if (songs.isEmpty) return false;
        final shuffled = List<SongsTableData>.of(songs)..shuffle();
        await replaceQueueWithData(
          shuffled,
          autoPlay: autoPlay,
          expandMatchFlows: false,
        );
        return _queueItems.isNotEmpty;
      case AutoMediaRoot.instantMix:
        if (autoPlay) {
          return _playInstantMixFromCurrentSong();
        }
        return _queueInstantRadioFallback(autoPlay: false);
      case AutoMediaRoot.instantRadio:
        if (autoPlay) {
          return _playInstantRadio();
        }
        return _queueInstantRadioFallback(autoPlay: false);
      case AutoMediaRoot.likedSongs:
        final songs = await _libraryDao.watchAllStarredSongs().first;
        if (songs.isEmpty) return false;
        await replaceQueueWithData(
          songs,
          autoPlay: autoPlay,
          expandMatchFlows: false,
        );
        return _queueItems.isNotEmpty;
      case AutoMediaRoot.likedAlbums:
        final albums = await _libraryDao.watchLikedAlbums().first;
        final allSongs = <SongsTableData>[];
        for (final album in albums) {
          allSongs.addAll(
            await _libraryDao.watchSongsByAlbum(album.id).first,
          );
        }
        if (allSongs.isEmpty) return false;
        await replaceQueueWithData(allSongs, autoPlay: autoPlay);
        return _queueItems.isNotEmpty;
      case AutoMediaRoot.resumeQueue:
        await _restoreQueueFromDisk();
        if (_queueItems.isEmpty) return false;
        if (autoPlay) {
          await play();
        }
        return true;
      case AutoMediaRoot.downloads:
        final downloadedSongIds = await _rollingCacheManager
            .getPermanentlyCachedSongIds();
        if (downloadedSongIds.isEmpty) return false;
        final songs = await _libraryDao.getSongsSorted(
          SongSortOrder.newest,
          onlyIds: downloadedSongIds,
        );
        if (songs.isEmpty) return false;
        await replaceQueueWithData(
          songs,
          autoPlay: autoPlay,
          expandMatchFlows: false,
        );
        return _queueItems.isNotEmpty;
      case AutoMediaRoot.recent:
        final songs = await _historyDao
            .watchRecentlyPlayedSongs(limit: 50)
            .first;
        if (songs.isEmpty) return false;
        await replaceQueueWithData(
          songs,
          autoPlay: autoPlay,
          expandMatchFlows: false,
        );
        return _queueItems.isNotEmpty;
    }

    // Handle entity media IDs (artist/album/playlist/song).
    final parsed = AutoMediaId.parse(mediaId);
    if (parsed == null) {
      final rawSongId = AutoMediaId.songIdFrom(mediaId);
      if (rawSongId == null) {
        AppLogger.debug('Android Auto mediaId ignored: $mediaId');
        return false;
      }
      final songs = await _libraryDao.getSongsByIds([rawSongId]);
      if (songs.isEmpty) {
        AppLogger.debug('Android Auto raw song mediaId not found: $mediaId');
        return false;
      }
      await replaceQueueWithData(songs, autoPlay: autoPlay);
      return _queueItems.isNotEmpty;
    }
    if (parsed.entityId == null) return false;

    switch (parsed.type) {
      case AutoMediaIdType.song:
        final songs = await _libraryDao.getSongsByIds([parsed.entityId!]);
        if (songs.isEmpty) return false;
        final song = songs.first;
        final contextualSongs = await switch (parsed.contextType) {
          AutoMediaContextType.downloads => () async {
            final downloadedSongIds = await _rollingCacheManager
                .getPermanentlyCachedSongIds();
            return _libraryDao.getSongsSorted(
              SongSortOrder.newest,
              onlyIds: downloadedSongIds,
            );
          }(),
          AutoMediaContextType.liked =>
            _libraryDao.watchAllStarredSongs().first,
          AutoMediaContextType.recent =>
            _historyDao.watchRecentlyPlayedSongs(limit: 50).first,
          _ => Future<List<SongsTableData>>.value(
            const <SongsTableData>[],
          ),
        };
        if (contextualSongs.isNotEmpty) {
          final startIndex = contextualSongs.indexWhere(
            (item) => item.id == parsed.entityId,
          );
          if (startIndex >= 0) {
            await replaceQueueWithData(
              contextualSongs,
              startIndex: startIndex,
              autoPlay: autoPlay,
              expandMatchFlows: false,
            );
            return _queueItems.isNotEmpty;
          }
        }
        if (parsed.contextType == AutoMediaContextType.playlist &&
            parsed.contextId != null) {
          final playlistSongs = await _playlistDao
              .watchPlaylistSongs(parsed.contextId!)
              .first;
          final startIndex = playlistSongs.indexWhere(
            (item) => item.id == parsed.entityId,
          );
          if (startIndex >= 0) {
            await replaceQueueWithData(
              playlistSongs,
              startIndex: startIndex,
              autoPlay: autoPlay,
            );
            return _queueItems.isNotEmpty;
          }
        }

        // Album browse context is explicit when available. The phone setting
        // still decides whether an album leaf builds the album queue.
        final albumId = parsed.contextType == AutoMediaContextType.album
            ? parsed.contextId
            : song.albumId;
        if (albumId != null && _readRuntimeSettings().albumQueueEnabled) {
          final albumSongs = await _libraryDao.watchSongsByAlbum(albumId).first;
          if (albumSongs.isNotEmpty) {
            final startIndex = albumSongs.indexWhere(
              (s) => s.id == parsed.entityId,
            );
            await replaceQueueWithData(
              albumSongs,
              startIndex: startIndex < 0 ? 0 : startIndex,
              autoPlay: autoPlay,
            );
            return _queueItems.isNotEmpty;
          }
        }
        await replaceQueue([parsed.entityId!], autoPlay: autoPlay);
        return _queueItems.isNotEmpty;
      case AutoMediaIdType.album:
        final songs = await _libraryDao
            .watchSongsByAlbum(parsed.entityId!)
            .first;
        if (songs.isEmpty) return false;
        await replaceQueueWithData(songs, autoPlay: autoPlay);
        return _queueItems.isNotEmpty;
      case AutoMediaIdType.playlist:
        final songs = await _playlistDao
            .watchPlaylistSongs(parsed.entityId!)
            .first;
        if (songs.isEmpty) return false;
        await replaceQueueWithData(songs, autoPlay: autoPlay);
        return _queueItems.isNotEmpty;
      case AutoMediaIdType.artist:
        final albums = await _libraryDao
            .watchAlbumsByArtist(parsed.entityId!)
            .first;
        final allSongs = <SongsTableData>[];
        for (final album in albums) {
          allSongs.addAll(
            await _libraryDao.watchSongsByAlbum(album.id).first,
          );
        }
        if (allSongs.isEmpty) return false;
        await replaceQueueWithData(allSongs, autoPlay: autoPlay);
        return _queueItems.isNotEmpty;
      case AutoMediaIdType.root:
      case AutoMediaIdType.rootCategory:
      case AutoMediaIdType.likedSubcategory:
        return false;
    }
  }

  @override
  Future<void> playFromSearch(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    AppLogger.info('Android Auto playFromSearch query="$query"');
    await _runAndroidAutoLoad(
      () => _loadFromSearch(query, extras, autoPlay: true),
      failureMessage: 'No matching music was found.',
    );
  }

  Future<bool> _loadFromSearch(
    String query,
    Map<String, dynamic>? extras, {
    required bool autoPlay,
  }) async {
    final request = navisAndroidAutoSearchRequest(query, extras);
    if (request.type == NavisAndroidAutoSearchType.empty) {
      if (autoPlay) {
        return _playInstantRadio();
      }
      return _queueInstantRadioFallback(autoPlay: false);
    }

    switch (request.type) {
      case NavisAndroidAutoSearchType.artist:
        final artists = await _libraryDao.searchArtistsLocal(
          request.term,
          limit: 1,
        );
        if (artists.isNotEmpty) {
          return _loadFromMediaId(
            AutoMediaId.artist(artists.first.id),
            autoPlay: autoPlay,
          );
        }
      case NavisAndroidAutoSearchType.album:
        final albums = await _libraryDao.searchAlbumsLocal(
          request.term,
          limit: 1,
        );
        if (albums.isNotEmpty) {
          return _loadFromMediaId(
            AutoMediaId.album(albums.first.id),
            autoPlay: autoPlay,
          );
        }
      case NavisAndroidAutoSearchType.playlist:
        final playlists = await _playlistDao.watchPlaylists().first;
        final matches = playlists.where(
          (playlist) => _containsIgnoreCase(playlist.name, request.term),
        );
        if (matches.isNotEmpty) {
          final exactMatches = matches.where(
            (playlist) => _equalsIgnoreCase(playlist.name, request.term),
          );
          return _loadFromMediaId(
            AutoMediaId.playlist(
              exactMatches.isNotEmpty
                  ? exactMatches.first.id
                  : matches.first.id,
            ),
            autoPlay: autoPlay,
          );
        }
      case NavisAndroidAutoSearchType.title:
        final songs = await _libraryDao.searchSongsLocal(
          request.term,
          limit: 1,
        );
        if (songs.isNotEmpty) {
          return _loadFromMediaId(
            AutoMediaId.song(songs.first.id),
            autoPlay: autoPlay,
          );
        }
      case NavisAndroidAutoSearchType.general:
        final songs = await _libraryDao.searchSongsLocal(
          request.term,
          limit: 20,
        );
        final exactSongs = songs.where(
          (song) => _equalsIgnoreCase(song.title, request.term),
        );
        if (exactSongs.isNotEmpty) {
          return _loadFromMediaId(
            AutoMediaId.song(exactSongs.first.id),
            autoPlay: autoPlay,
          );
        }
        final playlists = await _playlistDao.watchPlaylists().first;
        final exactPlaylists = playlists.where(
          (playlist) => _equalsIgnoreCase(playlist.name, request.term),
        );
        if (exactPlaylists.isNotEmpty) {
          return _loadFromMediaId(
            AutoMediaId.playlist(exactPlaylists.first.id),
            autoPlay: autoPlay,
          );
        }
      case NavisAndroidAutoSearchType.empty:
        break;
    }

    final results = await search(request.term, extras);
    final playable = results.where((item) => item.playable == true);
    final browsable = results.where(
      (item) => item.extras?[AndroidAutoConstants.isBrowsableKey] == true,
    );
    if (playable.isEmpty && browsable.isEmpty) return false;

    final target = playable.isNotEmpty ? playable.first : browsable.first;
    return _loadFromMediaId(target.id, autoPlay: autoPlay);
  }

  void _broadcastAndroidAutoPlaybackError(String message) {
    AppLogger.warning('Android Auto playback request failed: $message');
    playbackState.add(
      navisAndroidAutoPlaybackErrorState(playbackState.value, message),
    );
  }

  Future<void> _runAndroidAutoLoad(
    Future<bool> Function() load, {
    required String failureMessage,
  }) async {
    try {
      if (await load()) {
        return;
      }
    } on Object catch (error) {
      AppLogger.warning(
        'Android Auto playback request raised ${error.runtimeType}.',
      );
    }
    _broadcastAndroidAutoPlaybackError(failureMessage);
  }

  void _setCurrentMediaItem(MediaItem? item) {
    _currentMediaItem = item;
    final nextSongId = _radioStation == null ? item?.id : null;
    if (_bufferState.songId != nextSongId) {
      _emitBufferState(
        songId: nextSongId,
        bufferedPosition: Duration.zero,
        force: true,
      );
    }
    mediaItem.add(item);
    if (item != null && _artCache != null) {
      unawaited(_updateArtCacheFile(item));
    }
    _syncSidecarRollingCache(item);
  }

  void _rememberSidecarSong(SongsTableData song) {
    _sidecarSongsById[song.id] = song;
  }

  void _syncSidecarRollingCache(MediaItem? item) {
    if (!_isDesktopRuntime || _radioStation != null) {
      unawaited(_sidecarDownloader.cancel());
      return;
    }
    if (item == null) {
      unawaited(_sidecarDownloader.cancel());
      return;
    }
    final sidecarPath = item.extras?['sidecarCacheFilePath'] as String?;
    final streamUriRaw = item.extras?['streamUri'] as String?;
    if (sidecarPath == null ||
        sidecarPath.isEmpty ||
        streamUriRaw == null ||
        streamUriRaw.isEmpty) {
      unawaited(_sidecarDownloader.cancel());
      return;
    }
    final song = _sidecarSongsById[item.id];
    if (song == null) {
      unawaited(_sidecarDownloader.cancel());
      return;
    }
    final streamUri = Uri.tryParse(streamUriRaw);
    if (streamUri == null) {
      unawaited(_sidecarDownloader.cancel());
      return;
    }
    unawaited(
      _sidecarDownloader.start(
        songId: song.id,
        uri: streamUri,
        cacheFilePath: sidecarPath,
        onProgress: (progress) {
          _updateRollingCacheActivity(
            sidecarPath,
            RollingCacheActivity(
              status: RollingCacheActivityStatus.caching,
              songId: song.id,
              progress: progress.clamp(0, 1),
            ),
          );
        },
        onComplete: (cacheFile) async {
          await _registerRollingCacheTrack(
            song: song,
            resolvedSource: ResolvedPlaybackSource.directStream(
              songId: song.id,
              uri: streamUri,
              metadata: ResolvedPlaybackMetadata(
                format: item.extras?['resolvedFormat'] as String?,
                bitRate: item.extras?['resolvedBitRate'] as int?,
                sampleRate: item.extras?['resolvedSampleRate'] as int?,
                isTranscoded:
                    item.extras?['transcodingApplied'] as bool? ?? false,
              ),
              sidecarCacheFilePath: sidecarPath,
            ),
            cacheFilePath: cacheFile.path,
          );
          _completeRollingCacheActivity(sidecarPath);
        },
      ),
    );
  }

  /// Downloads the cover art for [trigger] to a local file and re-emits the
  /// current [MediaItem] with `artCacheFile` injected into
  /// [MediaItem.extras].
  ///
  /// ## Why extras, not artUri
  ///
  /// A previous approach replaced [MediaItem.artUri] with a `file://` URI.
  /// That caused Java's `createMediaMetadata` to write the raw file path into
  /// `METADATA_KEY_DISPLAY_ICON_URI`.  Android Auto runs in a *separate OS
  /// process* and cannot read another app's internal cache directory via a
  /// plain `file://` URI, so it silently dropped the art.
  ///
  /// By keeping the original HTTP artUri (which AAOS can fetch cross-process)
  /// and injecting `artCacheFile` into [MediaItem.extras], we get the best of
  /// both worlds:
  ///
  /// * `METADATA_KEY_DISPLAY_ICON_URI` stays as the HTTP URL → AAOS can load
  ///   art from the network whenever it wants.
  /// * Java's `AudioService.setMetadata` reads `extras["artCacheFile"]`,
  ///   decodes the local JPEG with `BitmapFactory.decodeFile`, and stores the
  ///   result in `METADATA_KEY_ALBUM_ART` + `METADATA_KEY_DISPLAY_ICON` →
  ///   immediate bitmap display without a network round-trip.
  ///
  /// ## Cancellation safety
  ///
  /// `audio_service`'s `artFetchOperationId` mechanism cancels the previous
  /// HTTP-download listener when a new [MediaItem] is emitted.  Because we
  /// emit the updated item (with `artCacheFile` already in extras) *after* the
  /// download completes, the new listener sees the complete extras map and
  /// passes it straight to `_platform.setMediaItem` — the "show without art"
  /// intermediate call in audio_service's HTTP path still includes
  /// `artCacheFile`, so Java always has the bitmap.
  ///
  /// ## Queue persistence
  ///
  /// This method also updates [_queueItems] so that future `currentIndexStream`
  /// events (e.g. from Phase-2 insertions) deliver the art-cached version to
  /// `_setCurrentMediaItem`, preventing the art from reverting to blank.
  Future<void> _updateArtCacheFile(MediaItem trigger) async {
    final coverArtId = trigger.extras?['coverArtId'] as String?;
    final artUri = trigger.artUri;
    // Nothing to do if essential fields are missing.
    if (coverArtId == null || artUri == null) return;
    // Skip non-HTTP schemes (file://, content://, etc. — already handled).
    if (artUri.scheme != 'http' && artUri.scheme != 'https') return;
    // artCacheFile is already injected — no need to download again.
    if ((trigger.extras?['artCacheFile'] as String?) != null) return;

    AppLogger.debug(
      '_updateArtCacheFile: requesting art cache for '
      'coverArtId=$coverArtId uri=${artUri.scheme}://${artUri.host}${artUri.path}',
    );
    final localPath = await _artCache!.getOrFetch(coverArtId, artUri);
    AppLogger.debug(
      '_updateArtCacheFile: result for $coverArtId → $localPath',
    );
    if (localPath == null) return;

    // Inject artCacheFile into a copy of [item]'s extras, preserving all
    // existing extras (coverArtId, albumId, replay-gain values, etc.).
    MediaItem withArtCache(MediaItem item) => item.copyWith(
      extras: <String, Object?>{...?item.extras, 'artCacheFile': localPath},
    );

    // Update every occurrence of this song in the queue so that future
    // currentIndexStream events deliver the art-cached version.
    for (var i = 0; i < _queueItems.length; i++) {
      if (_queueItems[i].id == trigger.id &&
          (_queueItems[i].extras?['artCacheFile'] as String?) == null) {
        _queueItems[i] = withArtCache(_queueItems[i]);
      }
    }

    // Guard: only re-emit if we are still on the same track.
    final current = _currentMediaItem;
    if (current == null || current.id != trigger.id) return;
    // Guard: skip if a concurrent call already injected artCacheFile.
    if ((current.extras?['artCacheFile'] as String?) != null) return;

    // Re-emit the current item with artCacheFile in extras.
    // audio_service's HTTP-path listener will call
    // `_platform.setMediaItem(item._toMessage())` which serialises the full
    // extras map — Java's AudioService.setMetadata reads artCacheFile from
    // there, decodes the bitmap, and populates METADATA_KEY_ALBUM_ART so
    // that AAOS displays the art on the now-playing screen.
    final updated = withArtCache(current);
    _currentMediaItem = updated;
    mediaItem.add(updated);
  }

  AudioPlayer _buildAudioPlayer({required bool enableEqualizer}) {
    _equalizerPipelineEnabled = enableEqualizer;
    return _playerFactory?.call() ?? _buildBaseAudioPlayer();
  }

  AudioPlayer _buildBaseAudioPlayer({AudioPipeline? audioPipeline}) {
    // Pass URLs directly to libmpv so lavf's cache:// protocol gets the
    // original HTTPS stream rather than a local proxy, eliminating the
    // "[error] lavf: Failed to create file cache" log noise. Subsonic auth
    // is embedded in URL query params so no custom headers are needed.
    return AudioPlayer(
      audioPipeline: audioPipeline,
      equalizerConfiguration: _equalizerPipelineEnabled
          ? _equalizerMessage(_desiredEqualizer)
          : null,
      userAgent: _isDesktopRuntime ? 'Navis Desktop' : null,
      useProxyForRequestHeaders: !_isDesktopRuntime,
    );
  }

  Future<void> _initialize() async {
    AppLogger.info('Audio handler init: start.');
    await _player.setVolume(_userVolume);
    AppLogger.info(
      'Audio handler init: user volume applied '
      '(${_userVolume.toStringAsFixed(2)}).',
    );
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
    try {
      // Finish stale partial-file cleanup before queue restoration or an
      // external media-session Play request can start lock-cache downloads.
      await _rollingCacheManager.pruneMissingFiles();
      await _rollingCacheManager.pruneMissingPermanentFiles();
      await _rollingCacheManager.cleanupOrphanedRollingFiles();
      await _rollingCacheManager.enforceBudget(
        maxBytes: _readRollingCacheBudgetBytes(),
      );
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Cache maintenance failed during startup: $error\n$stackTrace',
      );
    }
    unawaited(
      _scrobbleService.flushDue().catchError((Object error, StackTrace stack) {
        AppLogger.warning(
          'Scrobble flush failed during startup: $error\n$stack',
        );
      }),
    );

    await _restoreQueueAfterStartup();
    _emitSnapshot();
    await _notifyAndroidAutoBrowseRefresh();
    AppLogger.info('Audio handler init: ready.');
  }

  Future<void> _restoreQueueAfterStartup() async {
    await _queueLane.run((_) async {
      try {
        _queueRestoreOutcome = 'loading';
        await _restoreQueueFromDisk().timeout(const Duration(seconds: 10));
      } on TimeoutException catch (error, stackTrace) {
        _queueRestoreOutcome = 'timeout';
        // Keep the saved queue: large queues restore their current item
        // first, so a timeout is transient and must not lose the user's queue.
        AppLogger.warning(
          'Queue restore timed out during startup; keeping the saved queue. '
          '$error\n$stackTrace',
        );
      } on Object catch (error, stackTrace) {
        _queueRestoreOutcome = 'failed';
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

  int _supersedeQueueWork({
    bool isLoading = false,
    String? loadingSongId,
    List<String>? pendingLogicalQueueSongIds,
    bool navigation = false,
  }) {
    _clearQueueReplacementMetadataAnchor();
    // Navigation keeps the queue, so a coalesced save of an earlier edit
    // must still land; any other supersession persists its own queue.
    if (!navigation) {
      _queueItemsPersistTimer?.cancel();
      _queueItemsPersistTimer = null;
      _queueItemsPersistContext = null;
      _queueItemsPersistFirstScheduledAt = null;
    }
    _pendingLogicalQueueSongIds = pendingLogicalQueueSongIds == null
        ? null
        : List<String>.unmodifiable(pendingLogicalQueueSongIds);
    if (navigation) {
      _queueLane.cancelForNavigation();
    } else {
      _queueLane.cancelCurrent();
    }
    final generation = ++_loadGeneration;
    _activeLoadGeneration = generation;
    _isLoading = isLoading;
    _loadingSongId = isLoading ? loadingSongId : null;
    _emitSnapshot();
    return generation;
  }

  bool _isActiveLoadGeneration(int generation) =>
      generation == _activeLoadGeneration;

  int _supersedeTransportIntent({bool? shouldPlay}) {
    _seekLane.cancelCurrent();
    _cancelSeekBufferingRecovery();
    _remotePlaybackRecoveryAttempts.clear();
    _latestExplicitTransportPlaying = shouldPlay;
    return ++_transportGeneration;
  }

  bool _isCurrentTransportIntent(int generation) =>
      generation == _transportGeneration;

  void _clearQueueReplacementMetadataAnchor() {
    _queueReplacementMetadataAnchor = null;
  }

  void _clearPendingLogicalQueue() {
    _pendingLogicalQueueSongIds = null;
  }

  /// Every queued song id in play order: the materialised queue followed by
  /// the deferred tail, or the requested order while a replacement loads.
  /// Cached per revision so playback events do not rebuild it.
  List<String> get _logicalQueueIds {
    final pending = _pendingLogicalQueueSongIds;
    if (pending != null) return pending;
    final cached = _logicalIdsCache;
    if (cached != null &&
        _logicalIdsQueueRevision == _queueItems.revision &&
        _logicalIdsTailRevision == _deferredTail.revision) {
      return cached;
    }
    final ids = List<String>.unmodifiable(<String>[
      for (final item in _queueItems) item.id,
      for (final entry in _deferredTail) entry.id,
    ]);
    _logicalIdsCache = ids;
    _logicalIdsQueueRevision = _queueItems.revision;
    _logicalIdsTailRevision = _deferredTail.revision;
    return ids;
  }

  /// Drops every deferred song, for a queue that is being replaced or
  /// cleared, and restores the user's repeat mode and release backoff.
  Future<void> _clearDeferredTail() async {
    _deferredTail.clear();
    _tailReleaseFailures = 0;
    _tailReleaseRetryAt = null;
    await _syncNativeLoopMode();
  }

  _DeferredQueueEntry _deferredEntryFor(SongsTableData song) =>
      _DeferredQueueEntry(song.id, song.isExternal ? song : null);

  /// The deferred form of a materialised item, keeping a remote row.
  _DeferredQueueEntry _deferredEntryForItem(MediaItem item) =>
      _DeferredQueueEntry(item.id, _remoteRows[item.id]);

  /// Every queued song in logical order, as deferred entries.
  List<_DeferredQueueEntry> _logicalQueueEntries() => <_DeferredQueueEntry>[
    for (final item in _queueItems) _deferredEntryForItem(item),
    ..._deferredTail,
  ];

  void _rememberRemoteRow(SongsTableData song) {
    if (!song.isExternal) return;
    _remoteRows[song.id] = song;
    if (_remoteRows.length > 2 * _queueItems.length + 64) {
      final materialised = <String>{for (final item in _queueItems) item.id};
      _remoteRows.removeWhere(
        (id, _) => id != song.id && !materialised.contains(id),
      );
    }
  }

  bool _shouldDeferTail(int queueLength) =>
      !_player.shuffleModeEnabled && queueLength > _queueWindow.deferThreshold;

  /// Applies the user's repeat mode to the native player, except that "all"
  /// waits until nothing is deferred: the player would otherwise wrap to the
  /// first song before reaching the deferred ones.
  Future<void> _syncNativeLoopMode() async {
    final native = _desiredLoopMode == LoopMode.all && _deferredTail.isNotEmpty
        ? LoopMode.off
        : _desiredLoopMode;
    if (_player.loopMode != native) {
      await _player.setLoopMode(native);
    }
    final inactiveDeck = _crossfadePlayer;
    if (inactiveDeck != null && inactiveDeck.loopMode != native) {
      await inactiveDeck.setLoopMode(native);
    }
  }

  bool _shouldReleaseTail() {
    if (_deferredTail.isEmpty ||
        _radioStation != null ||
        _pendingLogicalQueueSongIds != null ||
        _isLoading ||
        _isCrossfading ||
        _crossfadeHandoffInProgress) {
      return false;
    }
    final retryAt = _tailReleaseRetryAt;
    if (retryAt != null && DateTime.now().isBefore(retryAt)) return false;
    final current = _player.currentIndex ?? 0;
    return _queueItems.length - 1 - current < _queueWindow.lowWater;
  }

  bool _continuingIntoDeferredTail = false;

  /// The player reached the end of the materialised queue while songs are
  /// still deferred (a release could not keep ahead, for example after a
  /// failed release). Continue with the first deferred song.
  void _continueIntoDeferredTail() {
    if (_continuingIntoDeferredTail ||
        _deferredTail.isEmpty ||
        _radioStation != null ||
        _pendingLogicalQueueSongIds != null ||
        _isLoading) {
      return;
    }
    _continuingIntoDeferredTail = true;
    unawaited(
      playFromIndex(_queueItems.length).whenComplete(
        () => _continuingIntoDeferredTail = false,
      ),
    );
  }

  /// Offers a background release when playback nears the end of the
  /// materialised queue. It runs only while the queue lane is idle and yields
  /// to every user command.
  void _maybeReleaseTail() {
    if (_disposeHandlerStarted || !_shouldReleaseTail()) return;
    final started = _queueLane.tryRunIdle((token) async {
      if (!_shouldReleaseTail()) return;
      try {
        await _releaseTail(count: _queueWindow.page, token: token);
      } on OperationCancelledException {
        rethrow;
      } on Object catch (error, stackTrace) {
        _tailReleaseFailures++;
        final delay = Duration(
          seconds: math.min(60, 1 << math.min(6, _tailReleaseFailures)),
        );
        _tailReleaseRetryAt = DateTime.now().add(delay);
        Timer(delay, _maybeReleaseTail);
        AppLogger.warning(
          'Deferred queue release failed; retrying in ${delay.inSeconds}s. '
          '$error\n$stackTrace',
        );
      }
    });
    if (started == null) return;
    unawaited(started);
  }

  Future<List<SongsTableData?>> _rowsForDeferredEntries(
    List<_DeferredQueueEntry> entries,
  ) async {
    final missing = <String>[
      for (final entry in entries)
        if (entry.song == null) entry.id,
    ];
    final byId = <String, SongsTableData>{
      if (missing.isNotEmpty)
        for (final song in await _libraryDao.getSongsByIds(missing))
          song.id: song,
    };
    return <SongsTableData?>[
      for (final entry in entries) entry.song ?? byId[entry.id],
    ];
  }

  /// Moves up to [count] songs from the front of the deferred tail into the
  /// native player with a single append; songs that cannot be resolved are
  /// dropped. A song that is only unavailable for now (offline, or no
  /// session) stays deferred with every song after it, and when nothing can
  /// be released this throws [PlaybackSourceTemporarilyUnavailableException]
  /// so callers retry later. [token] is honoured only before the native
  /// call: an append that succeeded is always committed, so the Dart queue
  /// never diverges from the player. Returns, per released tail entry, its offset from the old end
  /// of the materialised queue, or null when it was dropped.
  Future<List<int?>> _releaseTail({
    required int count,
    OperationToken? token,
  }) async {
    if (_deferredTail.isEmpty || count <= 0) return const <int?>[];
    var take = math.min(count, _deferredTail.length);
    final entries = _deferredTail.sublist(0, take);
    final queueRevision = _queueItems.revision;
    final tailRevision = _deferredTail.revision;
    final rows = await _rowsForDeferredEntries(entries);
    token?.checkCancelled();
    final resolved = <_PreparedQueueItem?>[];
    var retryFrom = rows.length;
    for (
      var start = 0;
      start < rows.length && retryFrom == rows.length;
      start += _queueFillBatchSizeLimit
    ) {
      final end = math.min(start + _queueFillBatchSizeLimit, rows.length);
      resolved.addAll(
        await Future.wait([
          for (var i = start; i < end; i++)
            if (rows[i] case final row?)
              _prepareSingleItemForQueueFill(
                row,
                onRetryLater: () => retryFrom = math.min(retryFrom, i),
              )
            else
              Future<_PreparedQueueItem?>.value(),
        ]),
      );
      token?.checkCancelled();
    }
    take = math.min(take, retryFrom);
    if (take == 0) {
      throw const PlaybackSourceTemporarilyUnavailableException(
        'Deferred songs are not playable right now.',
      );
    }
    final prepared = <_PreparedQueueItem>[];
    final offsets = <int?>[];
    for (final item in resolved.take(take)) {
      offsets.add(item == null ? null : prepared.length);
      if (item != null) prepared.add(item);
    }
    // The lane serialises queue work, but a restore outside it (Android Auto
    // resume) can replace the queue meanwhile; release nothing then.
    if (_queueItems.revision != queueRevision ||
        _deferredTail.revision != tailRevision) {
      throw OperationCancelledException();
    }
    if (prepared.isEmpty) {
      _deferredTail.removeRange(0, take);
    } else {
      final inactiveDeck = _crossfadePlayer;
      final deckInSync =
          inactiveDeck != null &&
          inactiveDeck.sequence.length == _queueItems.length;
      await _runTimedPlayerOperation(
        generation: _activeLoadGeneration,
        operation: 'release deferred queue',
        reloadQueueOnTimeout: true,
        action: () => _player.addAudioSources(
          prepared.map((item) => item.audioSource).toList(growable: false),
        ),
        songId: prepared.first.song.id,
        cancelAfterSuccess: false,
      );
      // Move the page from the tail to the materialised queue in one step,
      // so no snapshot sees it in both.
      _queueItems.addAll(prepared.map((item) => item.mediaItem));
      _deferredTail.removeRange(0, take);
      if (deckInSync) {
        try {
          await inactiveDeck.addAudioSources(
            prepared
                .map(
                  (item) =>
                      item.source.asClonedAudioSource(tag: item.mediaItem),
                )
                .toList(growable: false),
          );
        } on Object catch (error) {
          AppLogger.debug('Deferred queue deck mirror failed: $error');
        }
      }
      _observeLockCacheForPrepared(prepared);
    }
    final dropped = take - prepared.length;
    _reportDroppedSongs(<String>[
      for (var i = 0; i < take; i++)
        if (offsets[i] == null) entries[i].id,
    ], QueueDropReason.release);
    _tailReleaseCount++;
    _tailReleasedSongCount += prepared.length;
    _tailDroppedSongCount += dropped;
    _tailReleaseFailures = 0;
    _tailReleaseRetryAt = null;
    if (_deferredTail.isEmpty) {
      await _syncNativeLoopMode();
    }
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _broadcastPlaybackState();
    _emitSnapshot();
    if (dropped > 0) {
      _scheduleQueueItemsPersistence(context: 'deferred queue drop');
    }
    return offsets;
  }

  /// Finds [songId] in the logical queue, preferring [expected] and then the
  /// nearest other occurrence. Returns -1 when the song is no longer queued.
  int _locateQueueTarget(String songId, int expected) {
    final ids = _logicalQueueIds;
    if (expected >= 0 && expected < ids.length && ids[expected] == songId) {
      return expected;
    }
    for (var distance = 1; distance < ids.length; distance++) {
      final before = expected - distance;
      final after = expected + distance;
      if (before < 0 && after >= ids.length) break;
      if (before >= 0 && before < ids.length && ids[before] == songId) {
        return before;
      }
      if (after >= 0 && after < ids.length && ids[after] == songId) {
        return after;
      }
    }
    return -1;
  }

  void _setQueueReplacementMetadataAnchor({
    required int expectedIndex,
    required MediaItem mediaItem,
  }) {
    _queueReplacementMetadataAnchor = NavisQueueReplacementMetadataAnchor(
      expectedIndex: expectedIndex,
      mediaItem: mediaItem,
    );
  }

  NavisResolvedQueueMetadata _resolveCurrentQueueMetadata() {
    final backendCurrentIndex = _player.currentIndex;
    if (navisIsQueueReplacementMetadataAnchorConfirmed(
      queueItems: _queueItems,
      backendCurrentIndex: backendCurrentIndex,
      anchor: _queueReplacementMetadataAnchor,
    )) {
      _clearQueueReplacementMetadataAnchor();
    }
    return navisResolveQueueMetadata(
      queueItems: _queueItems,
      logicalQueueSongIds: _pendingLogicalQueueSongIds,
      backendCurrentIndex: backendCurrentIndex,
      fallbackMediaItem: _currentMediaItem,
      anchor: _queueReplacementMetadataAnchor,
    );
  }

  void _checkQueueWorkCurrent(OperationToken token, int generation) {
    token.checkCancelled();
    if (!_isActiveLoadGeneration(generation)) {
      throw OperationCancelledException();
    }
  }

  void _completeQueueLoad(
    int generation, {
    String? loadingSongId,
    bool failed = false,
  }) {
    if (!_isActiveLoadGeneration(generation)) {
      return;
    }
    _activeStartupTrace?.mark(failed ? 'queueLoadFailed' : 'queueLoadComplete');
    _isLoading = false;
    _loadingSongId = null;
    _clearPendingLogicalQueue();
    _pendingLogicalQueueSongs = null;
    if (_navigationIntent.isPending &&
        _navigationIntent.desiredIndex ==
            _resolveCurrentQueueMetadata().currentIndex) {
      _navigationIntent.confirm(_navigationIntent.revision);
    }
    if (loadingSongId != null && failed) {
      _lastFailedSongId = loadingSongId;
    }
    _emitSnapshot();
  }

  void _reportDroppedSongs(List<String> songIds, QueueDropReason reason) {
    if (songIds.isEmpty || _droppedSongsController.isClosed) return;
    _droppedSongsController.add(
      QueueSongsDropped(
        songIds: List<String>.unmodifiable(songIds),
        reason: reason,
      ),
    );
  }

  void _emitLoadFailure({
    required String operation,
    required String message,
    String? songId,
    bool isTimeout = false,
  }) {
    if (_loadFailureController.isClosed) {
      return;
    }
    _loadFailureController.add(
      PlaybackLoadFailure(
        operation: operation,
        message: message,
        songId: songId,
        isTimeout: isTimeout,
      ),
    );
  }

  Future<void> _disposeAbandonedPlayer(AudioPlayer player) async {
    try {
      await player.stop().timeout(_playerResetTimeout);
    } on Object {
      // Best-effort cleanup only.
    }
    try {
      await player.dispose().timeout(_playerResetTimeout);
    } on Object {
      // Best-effort cleanup only.
    }
  }

  int? _nextPlayableIndexAfterFailure(int failedIndex, int totalCount) {
    final nextIndex = failedIndex + 1;
    if (nextIndex >= 0 && nextIndex < totalCount) {
      return nextIndex;
    }
    return null;
  }

  Future<void> _recoverPlayersFromTimeout({
    required int generation,
    required String operation,
    String? songId,
  }) async {
    AppLogger.warning(
      'Recovering audio players after timeout in $operation '
      '(song=${songId ?? 'n/a'} generation=$generation).',
    );
    _cancelCrossfade();
    await _disposePlayerListeners();

    final previousPlayer = _player;
    final previousInactiveDeck = _crossfadePlayer;
    final previousLoopMode = previousPlayer.loopMode;
    final previousShuffleModeEnabled = previousPlayer.shuffleModeEnabled;

    _player = _buildAudioPlayer(enableEqualizer: _equalizerPipelineEnabled);
    _wirePlayerListeners();
    _rebindRadioMetadataServiceToActivePlayer();

    try {
      await _restoreActivePlayerVolume().timeout(_playerResetTimeout);
      await _applyAdjustmentsToPlayer(
        _player,
        _appliedAdjustments,
      ).timeout(_playerResetTimeout);
      await _player.setLoopMode(previousLoopMode).timeout(_playerResetTimeout);
      await _player
          .setShuffleModeEnabled(previousShuffleModeEnabled)
          .timeout(_playerResetTimeout);
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Failed to restore active player state after timeout recovery: '
        '$error\n$stackTrace',
      );
    }

    _crossfadePlayer = _crossfadeEnabled ? _newCrossfadePlayer() : null;
    final inactiveDeck = _crossfadePlayer;
    if (inactiveDeck != null) {
      try {
        await inactiveDeck
            .setShuffleModeEnabled(previousShuffleModeEnabled)
            .timeout(_playerResetTimeout);
        await inactiveDeck
            .setLoopMode(previousLoopMode)
            .timeout(
              _playerResetTimeout,
            );
        await _applyAdjustmentsToPlayer(
          inactiveDeck,
          _appliedAdjustments,
        ).timeout(_playerResetTimeout);
        await _setVolumeIfChanged(inactiveDeck, 0);
      } on Object catch (error, stackTrace) {
        AppLogger.warning(
          'Failed to restore inactive deck state after timeout recovery: '
          '$error\n$stackTrace',
        );
      }
    }

    unawaited(_disposeAbandonedPlayer(previousPlayer));
    if (previousInactiveDeck != null) {
      unawaited(_disposeAbandonedPlayer(previousInactiveDeck));
    }
  }

  Future<T> _runTimedPlayerOperation<T>({
    required int generation,
    required String operation,
    required Future<T> Function() action,
    String? songId,
    Duration? timeout,
    // Queue edits must commit a native change that succeeded, even if a newer
    // command superseded the generation meanwhile; dropping it would leave
    // the Dart queue and the player out of step.
    bool cancelAfterSuccess = true,
    // For edits of a loaded queue: the player rebuilt after a timeout starts
    // empty, so the materialised queue is loaded into it again.
    bool reloadQueueOnTimeout = false,
  }) async {
    timeout ??= _playerLoadTimeout;
    _lastFailedSongId = null;
    _timedPlayerOperationCount++;
    final startupTrace = _activeStartupTrace;
    startupTrace?.mark('player:$operation:start');
    var timedOut = false;
    try {
      final operationFuture = action();
      unawaited(
        operationFuture.then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {
            if (!timedOut && _isActiveLoadGeneration(generation)) {
              return;
            }
            AppLogger.debug(
              'Ignoring late player operation failure for "$operation" '
              '(song=${songId ?? 'n/a'} generation=$generation): '
              '$error\n$stackTrace',
            );
          },
        ),
      );
      final result = await operationFuture.timeout(timeout);
      startupTrace?.mark('player:$operation:complete');
      if (cancelAfterSuccess && !_isActiveLoadGeneration(generation)) {
        throw OperationCancelledException();
      }
      return result;
    } on TimeoutException {
      startupTrace?.mark('player:$operation:timeout');
      timedOut = true;
      final isCurrent = _isActiveLoadGeneration(generation);
      if (isCurrent) _lastFailedSongId = songId;
      if (isCurrent && songId != null) {
        _markSongLockCachingBypassed(
          songId,
          reason: 'player operation "$operation" timed out',
        );
      }
      if (isCurrent) {
        _emitLoadFailure(
          operation: operation,
          message: 'Playback operation timed out after ${timeout.inSeconds}s.',
          songId: songId,
          isTimeout: true,
        );
      }
      final capture = (
        index: _player.currentIndex,
        position: _player.position,
        playing: _player.playing,
      );
      await _recoverPlayersFromTimeout(
        generation: generation,
        operation: operation,
        songId: songId,
      );
      if (reloadQueueOnTimeout && isCurrent) {
        await _reloadQueueAfterTimeout(capture);
      }
      if (!isCurrent) throw OperationCancelledException();
      throw PlaybackLoadTimeoutException(
        operation: operation,
        songId: songId,
        timeoutDuration: timeout,
      );
    }
  }

  /// Loads the materialised queue into a player rebuilt after a queue edit
  /// timed out, at the same song and position. Without it the Dart queue
  /// would list songs the empty player does not hold. Runs inside the lane
  /// work that timed out, so waiting edits see matching queues. Songs past
  /// the release window go back to the deferred tail; songs that can no
  /// longer be prepared are dropped.
  Future<void> _reloadQueueAfterTimeout(
    ({int? index, Duration position, bool playing}) capture,
  ) async {
    if (_queueItems.isEmpty) return;
    final current = (capture.index ?? 0).clamp(0, _queueItems.length - 1);
    final end = _player.shuffleModeEnabled
        ? _queueItems.length
        : math.min(_queueItems.length, current + _queueWindow.ahead + 1);
    final items = _queueItems.sublist(0, end);
    final beyond = _queueItems.sublist(end);
    try {
      final rows = await _rowsForDeferredEntries(
        items.map(_deferredEntryForItem).toList(growable: false),
      );
      final (:prepared, :offsets) = await _prepareRowsConcurrently(rows);
      if (prepared.isEmpty) {
        throw StateError('No queued song can be prepared.');
      }
      // The current song, or the next one that is still available.
      final landed =
          offsets.skip(current).nonNulls.firstOrNull ?? prepared.length - 1;
      final dropped = <String>[
        for (var i = 0; i < items.length; i++)
          if (offsets[i] == null) items[i].id,
      ];
      _queueItems
        ..clear()
        ..addAll(prepared.map((item) => item.mediaItem));
      _deferredTail.insertAll(0, beyond.map(_deferredEntryForItem));
      await _player
          .setAudioSources(
            prepared.map((item) => item.audioSource).toList(growable: false),
            initialIndex: landed,
            initialPosition: offsets[current] == null
                ? Duration.zero
                : capture.position,
          )
          .timeout(_playerLoadTimeout);
      _setCurrentMediaItem(_queueItems[landed]);
      _reportDroppedSongs(dropped, QueueDropReason.rebuild);
      if (dropped.isNotEmpty) {
        AppLogger.warning(
          'Queue reload after a timeout dropped ${dropped.length} songs '
          'that could not be prepared: ${dropped.take(8).join(', ')}',
        );
      }
      if (capture.playing) unawaited(_player.play());
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Could not reload the queue after a player timeout. '
        '$error\n$stackTrace',
      );
    }
    _afterQueueEdit(context: 'reload queue after timeout');
  }

  void _markSongLockCachingBypassed(String songId, {required String reason}) {
    if (!_lockCachingBypassedSongIds.add(songId)) {
      return;
    }
    AppLogger.debug(
      'Bypassing lock-cached playback for song=$songId for the rest of this '
      'session: $reason.',
    );
  }

  void _markPreparedLockCachingBypassed(
    Iterable<_PreparedQueueItem> prepared, {
    required String reason,
  }) {
    for (final entry in prepared) {
      if (entry.source.kind != PlaybackSourceKind.lockCachedStream) {
        continue;
      }
      _markSongLockCachingBypassed(entry.song.id, reason: reason);
    }
  }

  bool _shouldPreferLockCachingForSong(
    String songId, {
    required bool preferLockCaching,
  }) {
    return navisShouldUseLockCachingForSong(
      preferLockCaching: preferLockCaching,
      isBypassedForSong: _lockCachingBypassedSongIds.contains(songId),
    );
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

  ProcessingState? _eqObservedProcessingState;
  int? _eqObservedIndex;
  bool _eqRefreshInFlight = false;

  void _wirePlayerListeners() {
    _emitBufferState(
      songId: _radioStation == null ? _currentMediaItem?.id : null,
      bufferedPosition: Duration.zero,
      force: true,
    );
    _playbackEventSubscription = _player.playbackEventStream.listen(
      (_) {
        final processing = _player.processingState;
        final index = _player.currentIndex;
        if (processing == ProcessingState.completed) {
          _continueIntoDeferredTail();
        }
        if (processing != _eqObservedProcessingState ||
            index != _eqObservedIndex) {
          _eqObservedProcessingState = processing;
          _eqObservedIndex = index;
          if (processing == ProcessingState.ready &&
              equalizerCapabilities.supported) {
            unawaited(
              refreshEqualizerState().catchError((
                Object error,
                StackTrace trace,
              ) {
                AppLogger.warning('EQ status refresh failed: $error\n$trace');
              }),
            );
          }
        }
        _handleScrobbleSignals();
        _broadcastPlaybackState();
        _emitSnapshot();
        _syncRemotePlaybackStallWatchdog();
      },
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.error('Playback event stream error.', error, stackTrace);
        // If a radio stream is active, stop it and notify the UI.
        if (_radioStation != null) {
          // Tear down radio state synchronously so that no further metadata
          // callbacks (Azuracast polling / ICY subscription) fire while the
          // lane is busy cleaning up the player. This also lets the UI reflect
          // the stopped state immediately rather than waiting for lane turn.
          _radioStation = null;
          _radioMetadataService.stop();
          _broadcastPlaybackState();
          _emitSnapshot();
          _radioStreamErrorController.add(null);
          // Schedule player cleanup and queue restore on the lane.
          unawaited(
            _queueLane.run((_) async {
              await _player.stop();
              await _player.setAudioSources(const <AudioSource>[]);
              queue.add(const <MediaItem>[]);
              _setCurrentMediaItem(null);
              _broadcastPlaybackState();
              _emitSnapshot();
            }),
          );
          unawaited(
            _queueLane.run((_) async {
              if (_queueItems.isNotEmpty || _radioStation != null) return;
              try {
                await _restoreQueueFromDisk().timeout(
                  const Duration(seconds: 10),
                );
              } on TimeoutException catch (e, st) {
                AppLogger.warning(
                  'Queue restore after radio stream error timed out. '
                  'Clearing persisted queue. $e\n$st',
                );
                await _clearPersistedQueueBestEffort();
              } on Object catch (e, st) {
                AppLogger.warning(
                  'Queue restore after radio stream error failed: $e\n$st',
                );
              }
            }),
          );
        } else {
          unawaited(
            _recoverCurrentSongFromRemotePlaybackFailure(
              reason: 'playback event stream error',
              error: error,
              stackTrace: stackTrace,
            ),
          );
        }
      },
    );

    _currentIndexSubscription = _player.currentIndexStream.listen((index) {
      if (navisIsQueueReplacementMetadataAnchorConfirmed(
        queueItems: _queueItems,
        backendCurrentIndex: index,
        anchor: _queueReplacementMetadataAnchor,
      )) {
        _clearQueueReplacementMetadataAnchor();
      }
      final resolved = navisResolveQueueMetadata(
        queueItems: _queueItems,
        backendCurrentIndex: index,
        fallbackMediaItem: _currentMediaItem,
        anchor: _queueReplacementMetadataAnchor,
      );
      final item = resolved.mediaItem;
      if (item != null) {
        _setCurrentMediaItem(item);
      } else if (_queueItems.isEmpty ||
          _player.processingState == ProcessingState.idle) {
        // Clear only when playback has no active queue/source. Keep the last
        // known item during transient index gaps so UI metadata stays stable.
        _setCurrentMediaItem(null);
      }
      _updateScrobbleSession(item, currentIndex: resolved.currentIndex);
      _applyReplayGainVolume();
      _broadcastPlaybackState();
      _emitSnapshot();
      _scheduleTransportPersistence(context: 'current index update');
      _maybeReleaseTail();
    });

    // just_audio derives these from sequenceStateStream without distinct(),
    // so every queue insert re-emits them. Without distinct() a large queue
    // fill queued two full queue-state writes per batch and delayed the final
    // queue persistence by tens of seconds.
    _shuffleModeSubscription = _player.shuffleModeEnabledStream
        .distinct()
        .listen((_) {
          _broadcastPlaybackState();
          unawaited(
            _persistSafely(
              () => _persistQueueState(includePosition: false),
              context: 'shuffle mode stream update',
            ),
          );
        });

    _loopModeSubscription = _player.loopModeStream.distinct().listen((_) {
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
          // Paused edits may wait longer than the controller's bounded refresh
          // window. Observe their first processed block when playback resumes.
          if (equalizerCapabilities.supported &&
              equalizerState.pending &&
              _player.playing &&
              !_eqRefreshInFlight) {
            _eqRefreshInFlight = true;
            unawaited(
              refreshEqualizerState()
                  .catchError((Object error) {
                    _emitEqualizerState(
                      const EqualizerStateMessage(
                        enabled: false,
                        reason: 'EQ status could not be verified. Review playback settings.',
                      ),
                    );
                  })
                  .whenComplete(() => _eqRefreshInFlight = false),
            );
          }
          final startupTrace = _activeStartupTrace;
          if (startupTrace != null &&
              startupTrace.sourceApplied &&
              _player.playing &&
              _player.processingState == ProcessingState.ready &&
              _resolveCurrentQueueMetadata().mediaItem?.id ==
                  startupTrace.songId) {
            startupTrace.observePosition(position);
          }
        });

    _bufferedPositionSubscription = _player.bufferedPositionStream.listen((
      bufferedPosition,
    ) {
      final songId = _radioStation == null
          ? _resolveCurrentQueueMetadata().mediaItem?.id
          : null;
      _emitBufferState(
        songId: songId,
        bufferedPosition: songId == null ? Duration.zero : bufferedPosition,
      );
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
    await _bufferedPositionSubscription?.cancel();
    await _crossfadePositionSub?.cancel();
    _playbackEventSubscription = null;
    _currentIndexSubscription = null;
    _shuffleModeSubscription = null;
    _loopModeSubscription = null;
    _activePositionSubscription = null;
    _bufferedPositionSubscription = null;
    _crossfadePositionSub = null;
  }

  void _emitBufferState({
    required String? songId,
    required Duration bufferedPosition,
    bool force = false,
  }) {
    final safeBufferedPosition = bufferedPosition < Duration.zero
        ? Duration.zero
        : bufferedPosition;
    final next = PlaybackBufferState(
      songId: songId,
      bufferedPosition: safeBufferedPosition,
    );
    if (!force &&
        _bufferState.songId == next.songId &&
        _bufferState.bufferedPosition == next.bufferedPosition) {
      return;
    }
    _bufferState = next;
    if (!_bufferStateController.isClosed) {
      _bufferStateController.add(next);
    }
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

    final duration = _effectivePlaybackDuration(
      _resolveCurrentQueueMetadata().mediaItem,
    );
    if (duration == Duration.zero) {
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
      final shouldKeepPlaying =
          outgoingPlayer.playing || incomingPlayer.playing;
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
      if (shouldKeepPlaying && !_player.playing) {
        unawaited(_player.play());
      }
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
      // A release skipped during the fade can run now.
      scheduleMicrotask(_maybeReleaseTail);
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
    scheduleMicrotask(_maybeReleaseTail);
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
    await _syncInactiveDeckQueueFromActive(player, initialIndex: nextIndex);
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
    await _applyAdjustmentsToPlayer(player, _appliedAdjustments);
    await player.seek(Duration.zero, index: nextIndex);
  }

  Future<void> _syncInactiveDeckQueueFromActive(
    AudioPlayer player, {
    bool force = false,
    int generation = 0,
    int? initialIndex,
  }) async {
    if (!force && player.sequence.length == _player.sequence.length) {
      return;
    }
    if (_queueItems.isEmpty) {
      if (generation > 0) {
        await _runTimedPlayerOperation(
          generation: generation,
          operation: 'inactive deck clear',
          action: () => player.setAudioSources(const <AudioSource>[]),
        );
      } else {
        await player.setAudioSources(const <AudioSource>[]);
      }
      return;
    }
    final orderedSongs = (await _rowsForDeferredEntries(
      _queueItems.map(_deferredEntryForItem).toList(growable: false),
    )).nonNulls.toList(growable: false);
    if (orderedSongs.length != _queueItems.length) {
      throw StateError(
        'Inactive deck queue sync failed due to missing song metadata.',
      );
    }
    final prepared = await _prepareQueueItems(
      orderedSongs,
      preferLockCaching: true,
    );
    final resolvedInitialIndex = (initialIndex ?? _player.currentIndex ?? 0)
        .clamp(0, math.max(0, prepared.length - 1))
        .toInt();
    final inactiveSources = prepared
        .map((entry) => entry.source.asClonedAudioSource(tag: entry.mediaItem))
        .toList(growable: false);
    try {
      if (generation > 0) {
        await _runTimedPlayerOperation(
          generation: generation,
          operation: 'inactive deck sync',
          action: () => player.setAudioSources(
            inactiveSources,
            preload: true,
            initialIndex: resolvedInitialIndex,
          ),
        );
      } else {
        await player.setAudioSources(
          inactiveSources,
          preload: true,
          initialIndex: resolvedInitialIndex,
        );
      }
    } on Object catch (error, stackTrace) {
      _markPreparedLockCachingBypassed(
        prepared,
        reason: 'inactive deck sync failed',
      );
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
      if (generation > 0) {
        await _runTimedPlayerOperation(
          generation: generation,
          operation: 'inactive deck direct sync',
          action: () => player.setAudioSources(
            directSources,
            preload: true,
            initialIndex: resolvedInitialIndex,
          ),
        );
      } else {
        await player.setAudioSources(
          directSources,
          preload: true,
          initialIndex: resolvedInitialIndex,
        );
      }
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

  Future<void> _restoreQueueFromDisk() async {
    final queueState = await _playQueueDao.getQueueState();
    final queuedSongs = await _playQueueDao.getQueueItems();
    if (queuedSongs.isEmpty) {
      _queueRestoreOutcome = 'empty';
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

    // A large saved queue is restored like a queue replacement: the current
    // item first, so startup and media-session Play are not blocked by
    // resolving every song, then the rest in the queue lane.
    final restoreInTwoPhases = queuedSongs.length > _eagerQueueRestoreLimit;
    int? fillGeneration;
    _PreparedQueueItem? restoredStartItem;
    try {
      if (restoreInTwoPhases) {
        final generation = ++_loadGeneration;
        fillGeneration = generation;
        _activeLoadGeneration = generation;
        _pendingLogicalQueueSongIds = List<String>.unmodifiable(
          queuedSongs.map((song) => song.id),
        );
        restoredStartItem = await _replaceQueuePhase1(
          songs: queuedSongs,
          startIndex: startIndex,
          autoPlay: false,
          persist: false,
          generation: generation,
          token: OperationToken(),
          initialPosition: restorePosition,
        );
      } else {
        await _setQueueFromSongs(
          queuedSongs,
          startIndex: startIndex,
          autoPlay: false,
          initialPosition: restorePosition,
          persist: false,
          preloadWhenPaused: false,
          forcePreloadWhenPaused: true,
        );
      }
    } on PlaybackSourceUnavailableException {
      _clearPendingLogicalQueue();
      _queueRestoreOutcome = 'deferred_auth';
      AppLogger.warning(
        'Playback queue restore skipped because auth/session was unavailable.',
      );
      return;
    } on Object catch (error, stackTrace) {
      _queueRestoreOutcome = 'failed';
      AppLogger.warning(
        'Queue restore failed with an unrecoverable source/setup error. '
        'Clearing persisted queue. '
        '$error\n$stackTrace',
      );
      _clearPendingLogicalQueue();
      await _playQueueDao.clearQueue();
      await _clearQueueInternal(persist: false);
      return;
    }

    if (queueState != null) {
      _desiredLoopMode = switch (queueState.repeatMode) {
        schema.RepeatMode.one => LoopMode.one,
        schema.RepeatMode.all => LoopMode.all,
        schema.RepeatMode.off => LoopMode.off,
      };
      await _syncNativeLoopMode();
      final inactiveDeck = _crossfadePlayer;

      final shuffle = queueState.shuffleMode == schema.ShuffleMode.all;
      await _player.setShuffleModeEnabled(shuffle);
      if (inactiveDeck != null) {
        await inactiveDeck.setShuffleModeEnabled(shuffle);
      }
    }

    await _player.pause();
    _queueRestoreOutcome = 'restored';
    _broadcastPlaybackState();
    _emitSnapshot();

    final generation = fillGeneration;
    final startItem = restoredStartItem;
    if (generation == null) return;
    if (startItem == null) {
      _clearPendingLogicalQueue();
      return;
    }
    unawaited(
      _queueLane.run((token) async {
        try {
          _checkQueueWorkCurrent(token, generation);
          await _replaceQueuePhase2(
            songs: queuedSongs,
            startIndex: startIndex,
            startItem: startItem,
            persist: false,
            token: token,
            generation: generation,
            deferTail: _shouldDeferTail(queuedSongs.length),
          );
          _completeQueueLoad(generation);
        } on OperationCancelledException {
          AppLogger.debug('Queue restore fill superseded by a newer command.');
        } on Object catch (error, stackTrace) {
          AppLogger.warning(
            'Queue restore fill failed; the current item stays playable. '
            '$error\n$stackTrace',
          );
          _completeQueueLoad(generation);
        }
      }),
    );
  }

  /// Saved queues up to this size are restored in one step; larger ones
  /// restore the current item first and fill the rest in the background.
  static const int _eagerQueueRestoreLimit = 64;

  Future<void> _restorePersistedQueueForPrepareIfEmpty() async {
    if (_radioStation != null || _queueItems.isNotEmpty) {
      AppLogger.debug(
        'Android Auto prepare: active queue already available '
        '(queue=${_queueItems.length} radio=${_radioStation != null}).',
      );
      return;
    }

    final queuedSongs = await _playQueueDao.getQueueItems();
    if (queuedSongs.isEmpty) {
      AppLogger.debug('Android Auto prepare: no persisted queue to restore.');
      return;
    }

    AppLogger.info(
      'Android Auto prepare: restoring persisted queue without autoplay '
      '(count=${queuedSongs.length}).',
    );
    await _restoreQueueFromDisk();
  }

  Future<bool> _prepareBestAvailableQueueForUserPlay() async {
    final inFlight = _prepareQueueForUserPlayInFlight;
    if (inFlight != null) {
      return inFlight;
    }

    final preparation = _prepareBestAvailableQueueForUserPlayOnce();
    _prepareQueueForUserPlayInFlight = preparation;
    try {
      return await preparation;
    } finally {
      if (identical(_prepareQueueForUserPlayInFlight, preparation)) {
        _prepareQueueForUserPlayInFlight = null;
      }
    }
  }

  Future<bool> _prepareBestAvailableQueueForUserPlayOnce() async {
    final activeSource = navisChooseAutoResumeSource(
      hasActiveQueue: _radioStation != null || _queueItems.isNotEmpty,
      hasPersistedQueue: false,
      hasRecentSongs: false,
      hasLikedSongs: false,
      canUseRandomFallback: false,
    );
    if (activeSource == NavisAutoResumeSource.activeQueue) {
      AppLogger.debug(
        'Android Auto resume: using active queue '
        '(queue=${_queueItems.length} radio=${_radioStation != null}).',
      );
      return true;
    }

    final persistedSongs = await _playQueueDao.getQueueItems();
    var source = navisChooseAutoResumeSource(
      hasActiveQueue: false,
      hasPersistedQueue: persistedSongs.isNotEmpty,
      hasRecentSongs: false,
      hasLikedSongs: false,
      canUseRandomFallback: false,
    );
    if (source == NavisAutoResumeSource.persistedQueue) {
      AppLogger.info(
        'Android Auto resume: restoring persisted queue '
        '(count=${persistedSongs.length}).',
      );
      await _restoreQueueFromDisk();
      if (_queueItems.isNotEmpty) {
        return true;
      }
      AppLogger.info(
        'Android Auto resume: persisted queue could not be restored; '
        'trying recent and fallback sources.',
      );
    }

    final recentSongs = await _historyDao
        .watchRecentlyPlayedSongs(
          limit: 50,
        )
        .first;
    source = navisChooseAutoResumeSource(
      hasActiveQueue: false,
      hasPersistedQueue: false,
      hasRecentSongs: recentSongs.isNotEmpty,
      hasLikedSongs: false,
      canUseRandomFallback: false,
    );
    if (source == NavisAutoResumeSource.recentSong) {
      AppLogger.info(
        'Android Auto resume: queueing recently played songs '
        '(count=${recentSongs.length}).',
      );
      await replaceQueueWithData(
        recentSongs,
        autoPlay: false,
        expandMatchFlows: false,
      );
      return _queueItems.isNotEmpty;
    }

    final likedSongs = await _libraryDao.watchAllStarredSongs().first;
    source = navisChooseAutoResumeSource(
      hasActiveQueue: false,
      hasPersistedQueue: false,
      hasRecentSongs: false,
      hasLikedSongs: likedSongs.isNotEmpty,
      canUseRandomFallback: false,
    );
    if (source == NavisAutoResumeSource.likedSong) {
      AppLogger.info(
        'Android Auto resume: queueing liked songs '
        '(count=${likedSongs.length}).',
      );
      await replaceQueueWithData(
        likedSongs,
        autoPlay: false,
        expandMatchFlows: false,
      );
      return _queueItems.isNotEmpty;
    }

    source = navisChooseAutoResumeSource(
      hasActiveQueue: false,
      hasPersistedQueue: false,
      hasRecentSongs: false,
      hasLikedSongs: false,
      canUseRandomFallback: true,
    );
    if (source == NavisAutoResumeSource.randomFallback) {
      AppLogger.info('Android Auto resume: trying random song fallback.');
      return _queueInstantRadioFallback(autoPlay: false);
    }

    AppLogger.info('Android Auto resume: no playable source available.');
    return false;
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
        _updateRollingCacheActivity(
          cacheFilePath,
          RollingCacheActivity(
            status: RollingCacheActivityStatus.caching,
            songId: song.id,
            progress: progress.clamp(0, 1),
          ),
        );
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
          ).whenComplete(
            () => _completeRollingCacheActivity(cacheFilePath),
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
        _completeRollingCacheActivity(cacheFilePath);
      },
      onDone: () {
        if (_cacheProgressSubscriptions.remove(cacheFilePath) != null) {
          _completeRollingCacheActivity(cacheFilePath);
        }
      },
    );

    _cacheProgressSubscriptions[cacheFilePath] = subscription;
  }

  void _updateRollingCacheActivity(
    String cacheFilePath,
    RollingCacheActivity activity,
  ) {
    _rollingCacheActivities[cacheFilePath] = activity;
    _reportRollingCacheActivity?.call(activity);
  }

  void _completeRollingCacheActivity(String cacheFilePath) {
    _rollingCacheActivities.remove(cacheFilePath);
    _reportRollingCacheActivity?.call(
      _rollingCacheActivities.values.lastOrNull ??
          const RollingCacheActivity.idle(),
    );
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
      final bytes = await file.length();
      if (bytes > 0) {
        _reportNetworkUsage?.call(
          category: NetworkUsageCategory.audioStream,
          bytes: bytes,
        );
      }
      await _rollingCacheManager.registerTrack(
        songId: _canonicalSongId(song.id),
        filePath: cacheFilePath,
        format:
            resolvedSource.metadata.format ??
            (resolvedSource.metadata.isTranscoded ? 'transcoded' : null),
        bitRate: resolvedSource.metadata.bitRate,
      );
      await _rollingCacheManager.enforceBudget(
        maxBytes: _readRollingCacheBudgetBytes(),
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
    bool forcePreloadWhenPaused = false,
    int generation = 0,
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
        forcePreloadWhenPaused: forcePreloadWhenPaused,
        generation: generation,
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
        await _rebuildPlayerWithoutEqualizer(force: true);
      } else {
        _markPreparedLockCachingBypassed(
          prepared,
          reason: 'queue apply failed during fallback to direct stream',
        );
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
          forcePreloadWhenPaused: forcePreloadWhenPaused,
          generation: generation,
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
        await _rebuildPlayerWithoutEqualizer(force: true);
        await _applyPreparedQueue(
          prepared,
          startIndex: clampedIndex,
          autoPlay: autoPlay,
          initialPosition: initialPosition,
          preloadWhenPaused: preloadWhenPaused,
          forcePreloadWhenPaused: forcePreloadWhenPaused,
          generation: generation,
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
    // Resolutions are independent; run a bounded chunk at a time. Order is
    // preserved and the first failure still propagates to the caller.
    const chunkSize = 64;
    final prepared = <_PreparedQueueItem>[];
    for (var offset = 0; offset < songs.length; offset += chunkSize) {
      prepared.addAll(
        await Future.wait(
          songs
              .skip(offset)
              .take(chunkSize)
              .map(
                (song) => _prepareSingleItem(
                  song,
                  preferLockCaching: preferLockCaching,
                ),
              ),
        ),
      );
    }
    return prepared;
  }

  /// Resolve a single song's playback source with the standard fallback chain
  /// (lock-caching → direct stream).
  Future<_PreparedQueueItem> _prepareSingleItem(
    SongsTableData song, {
    required bool preferLockCaching,
  }) async {
    final startupTrace = _activeStartupTrace;
    if (startupTrace?.songId == song.id) {
      startupTrace?.markOnce('sourceResolutionStart');
    }
    final effectivePreferLockCaching = _shouldPreferLockCachingForSong(
      song.id,
      preferLockCaching: preferLockCaching,
    );
    ResolvedPlaybackSource source;
    try {
      source = await _sourceResolver.resolveForSong(
        song,
        preferLockCaching: effectivePreferLockCaching,
      );
    } on PlaybackSourceUnavailableException {
      rethrow;
    } on Object catch (error, stackTrace) {
      if (!effectivePreferLockCaching) rethrow;
      _markSongLockCachingBypassed(
        song.id,
        reason: 'source resolution failed',
      );
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
    if (startupTrace?.songId == song.id) {
      startupTrace?.sourceKind = source.kind.name;
      startupTrace?.markOnce('sourceResolutionComplete');
    }
    if (source.sidecarCacheFilePath != null) {
      _rememberSidecarSong(song);
    }
    _rememberRemoteRow(song);
    return _PreparedQueueItem(
      song: song,
      source: source,
      mediaItem: item,
      audioSource: source.asAudioSource(tag: item),
    );
  }

  /// [onRetryLater] is called instead of logging a skip when the song may
  /// become playable again (offline, or no session yet).
  Future<_PreparedQueueItem?> _prepareSingleItemForQueueFill(
    SongsTableData song, {
    void Function()? onRetryLater,
  }) async {
    try {
      return await _prepareSingleItem(song, preferLockCaching: true);
    } on OperationCancelledException {
      rethrow;
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Queue fill lock-cached source failed for song=${song.id}. '
        'Retrying with direct stream. $error\n$stackTrace',
      );
    }

    try {
      return await _prepareSingleItem(song, preferLockCaching: false);
    } on OperationCancelledException {
      rethrow;
    } on PlaybackSourceTemporarilyUnavailableException catch (error) {
      if (onRetryLater == null) {
        AppLogger.warning(
          'Queue fill source unavailable for song=${song.id}; skipping. '
          '$error',
        );
      }
      onRetryLater?.call();
      return null;
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Queue fill source unavailable for song=${song.id}; skipping. '
        '$error\n$stackTrace',
      );
      return null;
    }
  }

  /// Phase 1 of two-phase queue replacement: resolve *only* the target song,
  /// set a single audio source on the player, and start playback immediately.
  /// Returns the list of all songs (for Phase 2) and the prepared start item.
  ///
  /// While phase 1 prepares the transport queue with only the start item, the
  /// pending logical queue lets snapshots expose the full requested order.
  Future<_PreparedQueueItem?> _replaceQueuePhase1({
    required List<SongsTableData> songs,
    required int startIndex,
    required bool autoPlay,
    required bool persist,
    required int generation,
    required OperationToken token,
    Duration initialPosition = Duration.zero,
    bool preferLockCaching = true,
    // A start source the caller already has (a completed sidecar file).
    _PreparedQueueItem? preparedStart,
  }) async {
    if (songs.isEmpty) {
      await _clearQueueInternal(persist: persist);
      return null;
    }

    final clampedIndex = startIndex.clamp(0, songs.length - 1);
    final startSong = songs[clampedIndex];
    final startupTrace = _activeStartupTrace;
    startupTrace?.markOnce('selectedSourcePreparationStart');

    // Resolve the target song's playback source.
    _PreparedQueueItem startItem;
    if (preparedStart != null) {
      startItem = preparedStart;
    } else {
      try {
        startItem = await _prepareSingleItem(
          startSong,
          preferLockCaching: preferLockCaching,
        );
      } on PlaybackSourceUnavailableException {
        rethrow;
      } on Object catch (error, stackTrace) {
        if (!preferLockCaching) {
          rethrow;
        }
        AppLogger.warning(
          'Phase 1 lock-cached source failed for song=${startSong.id}. '
          'Retrying with direct stream. $error\n$stackTrace',
        );
        startItem = await _prepareSingleItem(
          startSong,
          preferLockCaching: false,
        );
      }
    }

    // Phase 1 loads only the start song's audio source into the player at
    // index 0.  _queueItems must contain only that one item so that the
    // currentIndexStream listener (which fires at index 0 immediately after
    // setAudioSource) maps index 0 → startItem.mediaItem, not the first
    // album track.  Phase 2 will insert/append the remaining items.
    _queueItems.clear();
    await _clearDeferredTail();
    _queueItems.add(startItem.mediaItem);
    if (songs.length > 1) {
      _setQueueReplacementMetadataAnchor(
        expectedIndex: clampedIndex,
        mediaItem: startItem.mediaItem,
      );
    }

    // Set a single audio source on the player and start playback.
    _checkQueueWorkCurrent(token, generation);
    startupTrace?.mark('selectedSourceApplyStart');
    await _runTimedPlayerOperation(
      generation: generation,
      operation: 'replace queue phase 1 stop',
      action: _player.stop,
      songId: startSong.id,
      timeout: _playerResetTimeout,
    );
    try {
      await _setAudioSourcesWithFallback(
        audioSources: <AudioSource>[startItem.audioSource],
        preload: true,
        initialIndex: 0,
        initialPosition: initialPosition,
        generation: generation,
        songId: startSong.id,
      );
    } on OperationCancelledException {
      rethrow;
    } on Object catch (error, stackTrace) {
      if (startItem.source.kind != PlaybackSourceKind.lockCachedStream) {
        rethrow;
      }
      _markSongLockCachingBypassed(
        startSong.id,
        reason: 'phase 1 queue apply failed',
      );
      AppLogger.warning(
        'Phase 1 lock-cached queue apply failed for song=${startSong.id}. '
        'Retrying with direct stream. $error\n$stackTrace',
      );
      startItem = await _prepareSingleItem(
        startSong,
        preferLockCaching: false,
      );
      _queueItems
        ..clear()
        ..add(startItem.mediaItem);
      if (songs.length > 1) {
        _setQueueReplacementMetadataAnchor(
          expectedIndex: clampedIndex,
          mediaItem: startItem.mediaItem,
        );
      }
      await _setAudioSourcesWithFallback(
        audioSources: <AudioSource>[startItem.audioSource],
        preload: true,
        initialIndex: 0,
        initialPosition: initialPosition,
        generation: generation,
        songId: startSong.id,
      );
    }
    _checkQueueWorkCurrent(token, generation);
    startupTrace?.mark('selectedSourceApplyComplete');

    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _setCurrentMediaItem(startItem.mediaItem);

    if (_latestExplicitTransportPlaying == true ||
        (autoPlay && _latestExplicitTransportPlaying != false)) {
      unawaited(_player.play());
    } else {
      await _player.pause();
    }

    if (startItem.source.kind == PlaybackSourceKind.lockCachedStream &&
        startItem.source.lockCachingAudioSource != null &&
        startItem.source.cachedFilePath != null) {
      _observeLockCachingSource(
        song: startItem.song,
        resolvedSource: startItem.source,
        source: startItem.source.lockCachingAudioSource!,
        cacheFilePath: startItem.source.cachedFilePath!,
      );
    }

    _broadcastPlaybackState();
    _emitSnapshot();

    return startItem;
  }

  /// Phase 2 of two-phase queue replacement: resolve the remaining songs
  /// in batches and incrementally insert them into the player.
  ///
  /// Runs inside `_queueLane.run` entries so it serialises with other queue
  /// mutations.  Checks [token] between batches to bail out early when a
  /// newer command supersedes this one.
  Future<void> _replaceQueuePhase2({
    required List<SongsTableData> songs,
    required int startIndex,
    required _PreparedQueueItem startItem,
    required bool persist,
    required OperationToken token,
    required int generation,
    bool deferTail = false,
  }) async {
    final clampedIndex = startIndex.clamp(0, songs.length - 1);

    // Collect songs that still need resolution (everything except startIndex).
    final beforeStart = songs.sublist(0, clampedIndex);
    final allAfterStart = clampedIndex + 1 < songs.length
        ? songs.sublist(clampedIndex + 1)
        : <SongsTableData>[];
    // A long queue hands only a window after the start song to the native
    // player; the rest waits in the deferred tail and is released in pages as
    // playback approaches it.
    final afterStart = deferTail && allAfterStart.length > _queueWindow.ahead
        ? allAfterStart.sublist(0, _queueWindow.ahead)
        : allAfterStart;
    final deferredSongs = allAfterStart.sublist(afterStart.length);

    // We need to rebuild the player's audio source list to include all songs
    // in the correct order.  First, resolve sources for the remaining songs.
    final fillWatch = Stopwatch()..start();
    final fillTimings = <String, Object?>{'requested': songs.length};
    _lastQueueFill = fillTimings;
    _queueFillResolveMs = 0;
    _queueFillNativeMs = 0;
    _queueFillBatches = 0;
    final preparedByIndex = <int, _PreparedQueueItem>{
      clampedIndex: startItem,
    };
    final skippedSongIds = <String>[];

    AppLogger.debug(
      'Queue replacement phase 2 start: requested=${songs.length} '
      'startIndex=$clampedIndex song=${startItem.song.id}',
    );

    // Each native insert re-sends the complete shuffle order to the platform
    // and rebuilds the player's sequence, so per-song inserts are O(n²) for a
    // large queue. Resolve a batch, then insert it with a single call. The
    // first batch is small so the upcoming track is available for gapless
    // playback almost immediately.
    //
    // _queueItems is intentionally NOT updated during these inserts: the
    // playbackEventStream fires position ticks on every event loop turn, and
    // any _emitSnapshot() call between _queueItems.insert() and the player
    // acknowledging the new currentIndex would produce a stale snapshot.
    // Keeping _queueItems=[startSong] throughout Phase 2 lets the metadata
    // anchor keep the display on the tapped song until _queueItems is rebuilt
    // atomically from allPrepared at the very end.
    //
    // Songs after the start are appended first so the next track is queued
    // before the (possibly long) prefix is inserted behind the current item.
    var appended = 0;
    while (appended < afterStart.length) {
      final batchEnd = math.min(
        appended + _queueFillBatchSize(appended),
        afterStart.length,
      );
      await _fillQueueBatch(
        batch: afterStart.sublist(appended, batchEnd),
        firstOriginalIndex: clampedIndex + 1 + appended,
        preparedByIndex: preparedByIndex,
        skippedSongIds: skippedSongIds,
        generation: generation,
        token: token,
        operation: 'replace queue append after',
        apply: _player.addAudioSources,
      );
      appended = batchEnd;
    }

    var insertedBeforeCount = 0;
    var resolvedBefore = 0;
    while (resolvedBefore < beforeStart.length) {
      final batchEnd = math.min(
        resolvedBefore + _queueFillBatchSize(resolvedBefore),
        beforeStart.length,
      );
      final insertAt = insertedBeforeCount;
      insertedBeforeCount += await _fillQueueBatch(
        batch: beforeStart.sublist(resolvedBefore, batchEnd),
        firstOriginalIndex: resolvedBefore,
        preparedByIndex: preparedByIndex,
        skippedSongIds: skippedSongIds,
        generation: generation,
        token: token,
        operation: 'replace queue insert before',
        apply: (sources) => _player.insertAudioSources(insertAt, sources),
      );
      resolvedBefore = batchEnd;
    }

    fillTimings['applyMs'] = fillWatch.elapsedMilliseconds;
    fillTimings['resolveTotalMs'] = _queueFillResolveMs;
    fillTimings['nativeTotalMs'] = _queueFillNativeMs;
    fillTimings['nativeBatches'] = _queueFillBatches;
    // Build the prepared list in album order for two purposes:
    // (a) syncing the crossfade inactive deck, and
    // (b) atomically rebuilding _queueItems now that all inserts are done.
    final allPrepared = <_PreparedQueueItem>[];
    for (var i = 0; i < songs.length; i++) {
      final prepared = preparedByIndex[i];
      if (prepared != null) allPrepared.add(prepared);
    }
    final preparedStartIndex = allPrepared.indexWhere(
      (item) => identical(item, startItem),
    );
    final finalStartIndex = preparedStartIndex < 0 ? 0 : preparedStartIndex;

    _checkQueueWorkCurrent(token, generation);
    await _clearInactiveDeckForQueueChange(
      generation: generation,
      songId: startItem.song.id,
    );

    // Atomically update _queueItems from the fully resolved list.  This is
    // the first point at which _queueItems reflects the complete queue, so the
    // metadata anchor can resolve the tapped song at its final queue index
    // even if the backend still reports the old temporary index.
    _queueItems
      ..clear()
      ..addAll(allPrepared.map((p) => p.mediaItem));
    _deferredTail
      ..clear()
      ..addAll(deferredSongs.map(_deferredEntryFor));
    _clearPendingLogicalQueue();
    if (_queueItems.length > 1 &&
        finalStartIndex >= 0 &&
        finalStartIndex < _queueItems.length) {
      _setQueueReplacementMetadataAnchor(
        expectedIndex: finalStartIndex,
        mediaItem: startItem.mediaItem,
      );
    } else {
      _clearQueueReplacementMetadataAnchor();
    }

    fillTimings['deckClearMs'] = fillWatch.elapsedMilliseconds;
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    fillTimings['queuePublishMs'] = fillWatch.elapsedMilliseconds;
    _broadcastPlaybackState();
    _emitSnapshot();
    fillTimings['snapshotMs'] = fillWatch.elapsedMilliseconds;
    fillTimings['prepared'] = allPrepared.length;
    fillTimings['skipped'] = skippedSongIds.length;
    fillTimings['deferred'] = deferredSongs.length;
    await _syncNativeLoopMode();

    AppLogger.debug(
      'Queue replacement phase 2 complete: requested=${songs.length} '
      'prepared=${allPrepared.length} skipped=${skippedSongIds.length} '
      'skippedIds=${skippedSongIds.join(',')}',
    );

    if (persist) {
      await _persistSafely(
        () {
          fillTimings['persistStartMs'] = fillWatch.elapsedMilliseconds;
          return _persistQueueState(includeQueueItems: true);
        },
        context: 'queue replacement (phase 2)',
      );
    }
    fillTimings['persistMs'] = fillWatch.elapsedMilliseconds;
  }

  static const int _queueFillFirstBatchSize = 8;
  static const int _queueFillBatchSizeLimit = 64;

  static int _queueFillBatchSize(int alreadyProcessed) => alreadyProcessed == 0
      ? _queueFillFirstBatchSize
      : _queueFillBatchSizeLimit;

  /// Resolves [batch] and applies every playable source with one [apply]
  /// call. Returns the number of sources applied to the player.
  ///
  /// A timeout leaves the player in an uncertain state and is rethrown, as is
  /// cancellation. Any other failure skips the whole batch, matching the
  /// previous per-song skip semantics at batch granularity.
  Future<int> _fillQueueBatch({
    required List<SongsTableData> batch,
    required int firstOriginalIndex,
    required Map<int, _PreparedQueueItem> preparedByIndex,
    required List<String> skippedSongIds,
    required int generation,
    required OperationToken token,
    required String operation,
    required Future<void> Function(List<AudioSource> sources) apply,
  }) async {
    _checkQueueWorkCurrent(token, generation);
    // Each resolution is independent and mostly waits on a database or file
    // check, so resolve the batch concurrently. Results keep queue order.
    final resolveWatch = Stopwatch()..start();
    final resolved = await Future.wait(
      batch.map(_prepareSingleItemForQueueFill),
    );
    _queueFillResolveMs += resolveWatch.elapsedMilliseconds;
    final prepared = <_PreparedQueueItem>[];
    final preparedIndexes = <int>[];
    for (var j = 0; j < batch.length; j++) {
      final item = resolved[j];
      if (item == null) {
        skippedSongIds.add(batch[j].id);
        continue;
      }
      prepared.add(item);
      preparedIndexes.add(firstOriginalIndex + j);
    }
    _checkQueueWorkCurrent(token, generation);
    if (prepared.isEmpty) {
      return 0;
    }
    final applyWatch = Stopwatch()..start();
    try {
      _queueFillBatches++;
      await _runTimedPlayerOperation(
        generation: generation,
        operation: operation,
        action: () => apply(
          prepared.map((item) => item.audioSource).toList(growable: false),
        ),
        songId: prepared.first.song.id,
        reloadQueueOnTimeout: true,
      );
    } on PlaybackLoadTimeoutException catch (error) {
      _lastFailedSongId = error.songId ?? prepared.first.song.id;
      AppLogger.warning(
        'Queue fill "$operation" timed out for ${prepared.length} songs; '
        'aborting the uncertain player state.',
      );
      rethrow;
    } on OperationCancelledException {
      rethrow;
    } on Object catch (error, stackTrace) {
      for (final item in prepared) {
        skippedSongIds.add(item.song.id);
        _markSongLockCachingBypassed(
          item.song.id,
          reason: 'queue fill batch failed',
        );
      }
      AppLogger.warning(
        'Queue fill "$operation" failed for ${prepared.length} songs; '
        'skipping the batch. $error\n$stackTrace',
      );
      return 0;
    }
    _queueFillNativeMs += applyWatch.elapsedMilliseconds;
    for (var j = 0; j < prepared.length; j++) {
      preparedByIndex[preparedIndexes[j]] = prepared[j];
    }
    _checkQueueWorkCurrent(token, generation);
    _observeLockCacheForPrepared(prepared);
    return prepared.length;
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
    bool forcePreloadWhenPaused = false,
    int generation = 0,
  }) async {
    _queueItems
      ..clear()
      ..addAll(prepared.map((entry) => entry.mediaItem));
    await _clearDeferredTail();

    final audioSources = prepared
        .map((entry) => entry.audioSource)
        .toList(growable: false);

    await _setAudioSourcesWithFallback(
      audioSources: audioSources,
      preload: navisShouldPreloadQueue(
        autoPlay: autoPlay,
        preloadWhenPaused: preloadWhenPaused,
        gaplessEnabled: _gaplessEnabled,
        forcePreloadWhenPaused: forcePreloadWhenPaused,
      ),
      initialIndex: startIndex,
      initialPosition: initialPosition,
      generation: generation,
      songId: prepared[startIndex].song.id,
    );
    await _clearInactiveDeckForQueueChange(
      generation: generation,
      songId: prepared[startIndex].song.id,
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

  Future<void> _clearInactiveDeckForQueueChange({
    int generation = 0,
    String? songId,
  }) async {
    final inactiveDeck = _crossfadePlayer;
    if (inactiveDeck == null) {
      return;
    }
    // Do not mirror the active queue at its current index. Two
    // LockCachingAudioSource instances would then own the same `.part` file.
    // The inactive deck is populated lazily at the next-track index when a
    // crossfade approaches.
    if (generation > 0) {
      await _runTimedPlayerOperation(
        generation: generation,
        operation: 'inactive deck clear',
        action: () => inactiveDeck.setAudioSources(const <AudioSource>[]),
        songId: songId,
      );
    } else {
      await inactiveDeck.setAudioSources(const <AudioSource>[]);
    }
    await inactiveDeck.setShuffleModeEnabled(_player.shuffleModeEnabled);
    await inactiveDeck.setLoopMode(_player.loopMode);
    await _applyAdjustmentsToPlayer(inactiveDeck, _appliedAdjustments);
    await _setVolumeIfChanged(inactiveDeck, 0);
    await inactiveDeck.pause();
  }

  Future<void> _setAudioSourcesWithFallback({
    required List<AudioSource> audioSources,
    required bool preload,
    required int initialIndex,
    required Duration initialPosition,
    int generation = 0,
    String? songId,
  }) async {
    try {
      if (generation > 0) {
        await _runTimedPlayerOperation(
          generation: generation,
          operation: 'active queue apply',
          action: () => _player.setAudioSources(
            audioSources,
            preload: preload,
            initialIndex: initialIndex,
            initialPosition: initialPosition,
          ),
          songId: songId,
        );
      } else {
        await _player.setAudioSources(
          audioSources,
          preload: preload,
          initialIndex: initialIndex,
          initialPosition: initialPosition,
        );
      }
    } on Object catch (error, stackTrace) {
      if (!_isAndroidDspInitializationFailure(error)) {
        rethrow;
      }
      AppLogger.warning(
        'Android DSP initialization failed during queue apply. '
        'Disabling DSP pipeline for this session and retrying. '
        '$error\n$stackTrace',
      );
      await _rebuildPlayerWithoutEqualizer(force: true);
      try {
        if (generation > 0) {
          await _runTimedPlayerOperation(
            generation: generation,
            operation: 'active queue apply retry',
            action: () => _player.setAudioSources(
              audioSources,
              preload: preload,
              initialIndex: initialIndex,
              initialPosition: initialPosition,
            ),
            songId: songId,
          );
        } else {
          await _player.setAudioSources(
            audioSources,
            preload: preload,
            initialIndex: initialIndex,
            initialPosition: initialPosition,
          );
        }
      } on Object catch (retryError, retryStackTrace) {
        if (!_isAndroidDspInitializationFailure(retryError)) {
          rethrow;
        }
        AppLogger.warning(
          'Android DSP fallback retry failed again. Rebuilding a plain player '
          'instance and retrying one final time. '
          '$retryError\n$retryStackTrace',
        );
        await _rebuildPlayerWithoutEqualizer(force: true);
        if (generation > 0) {
          await _runTimedPlayerOperation(
            generation: generation,
            operation: 'active queue apply final retry',
            action: () => _player.setAudioSources(
              audioSources,
              preload: preload,
              initialIndex: initialIndex,
              initialPosition: initialPosition,
            ),
            songId: songId,
          );
        } else {
          await _player.setAudioSources(
            audioSources,
            preload: preload,
            initialIndex: initialIndex,
            initialPosition: initialPosition,
          );
        }
      }
    }
    await _restoreActivePlayerVolume();
  }

  Future<void> _restoreActivePlayerVolume() {
    final target = _isDucked ? _userVolume * 2 / 5 : _userVolume;
    return _player.setVolume(target.clamp(0.0, 1.0));
  }

  bool _isAndroidDspInitializationFailure(Object error) {
    return navisIsAndroidDspInitializationFailure(
      error,
      isAndroidRuntime: _isAndroidRuntime,
    );
  }

  Future<void> _rebuildPlayerWithoutEqualizer({bool force = false}) async {
    if (!_equalizerPipelineEnabled && !force) {
      return;
    }

    final previousPlayer = _player;
    final previousLoopMode = previousPlayer.loopMode;
    final previousShuffleModeEnabled = previousPlayer.shuffleModeEnabled;

    _equalizerPipelineEnabled = false;
    _emitEqualizerState(
      const EqualizerStateMessage(
        enabled: false,
        reason:
            'EQ was bypassed because the audio engine could not initialize it.',
      ),
    );
    await _disposePlayerListeners();
    _player = _buildAudioPlayer(enableEqualizer: false);
    _wirePlayerListeners();
    _rebindRadioMetadataServiceToActivePlayer();

    await _restoreActivePlayerVolume();
    await _applyAdjustmentsToPlayer(_player, _appliedAdjustments);
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
    _crossfadePlayer = _crossfadeEnabled ? _newCrossfadePlayer() : null;
  }

  @override
  Future<void> replaceQueue(
    List<String> songIds, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
  }) async {
    _navigationIntent.reset();
    _pendingLogicalQueueSongs = null;
    _supersedeTransportIntent(shouldPlay: autoPlay);
    songIds = songIds.map(_canonicalSongId).toList(growable: false);
    final requestedStartIndex = songIds.isEmpty
        ? 0
        : startIndex.clamp(0, songIds.length - 1);
    if (songIds.isNotEmpty) _navigationIntent.select(requestedStartIndex);
    if (songIds.isNotEmpty) {
      _acceptStartupSelection(
        songIds[requestedStartIndex],
        isExternal: isExternalCatalogSource(id: songIds[requestedStartIndex]),
      );
    }
    final admittedGeneration = _supersedeQueueWork(
      isLoading: songIds.isNotEmpty,
      loadingSongId: songIds.isEmpty ? null : songIds[requestedStartIndex],
      pendingLogicalQueueSongIds: songIds.length > 1 ? songIds : null,
    );
    final expansion = await _expandMatchFlowIds(
      songIds,
      startIndex: startIndex,
      expandMatchFlows: expandMatchFlows,
    );
    if (!_isActiveLoadGeneration(admittedGeneration)) return;
    songIds = expansion.songIds;
    startIndex = expansion.startIndex;
    final normalizedStartIndex = songIds.isEmpty
        ? 0
        : startIndex.clamp(0, songIds.length - 1);
    if (songIds.isNotEmpty) _navigationIntent.select(normalizedStartIndex);
    final loadingSongId = songIds.isEmpty
        ? null
        : songIds[normalizedStartIndex];
    final generation = _supersedeQueueWork(
      isLoading: songIds.isNotEmpty,
      loadingSongId: loadingSongId,
      pendingLogicalQueueSongIds: songIds.length > 1 ? songIds : null,
    );
    return _queueLane.run((token) async {
      try {
        await _ready;
        _checkQueueWorkCurrent(token, generation);
        _cancelCrossfade();
        _radioMetadataService.stop();
        _radioStation = null;

        final songs = await _libraryDao.getSongsByIds(songIds);
        if (songs.isEmpty) {
          _clearPendingLogicalQueue();
          await _clearQueueInternal(persist: true);
          _completeQueueLoad(generation);
          return;
        }

        _checkQueueWorkCurrent(token, generation);
        _pendingLogicalQueueSongs = songs;

        final startItem = await _replaceQueuePhase1(
          songs: songs,
          startIndex: normalizedStartIndex,
          autoPlay: autoPlay,
          persist: false,
          generation: generation,
          token: token,
        );
        if (startItem != null) {
          await _persistLogicalQueue(
            songs.map((song) => song.id).toList(growable: false),
            normalizedStartIndex,
            generation: generation,
          );
        }

        if (startItem == null || songs.length <= 1) {
          _completeQueueLoad(generation);
          return;
        }

        await _replaceQueuePhase2(
          songs: songs,
          startIndex: normalizedStartIndex,
          startItem: startItem,
          persist: true,
          token: token,
          generation: generation,
          deferTail: _shouldDeferTail(songs.length),
        );
        _completeQueueLoad(generation);
      } on OperationCancelledException {
        AppLogger.debug(
          'replaceQueue cancelled — superseded by newer command.',
        );
      } on PlaybackLoadTimeoutException catch (error) {
        if (!_isActiveLoadGeneration(generation)) return;
        _completeQueueLoad(
          generation,
          loadingSongId: error.songId ?? loadingSongId,
          failed: true,
        );
        final nextIndex = _nextPlayableIndexAfterFailure(
          normalizedStartIndex,
          songIds.length,
        );
        if (nextIndex != null) {
          unawaited(
            replaceQueue(
              songIds,
              startIndex: nextIndex,
              autoPlay: _latestExplicitTransportPlaying ?? autoPlay,
              expandMatchFlows: false,
            ),
          );
        }
      } on Object {
        _completeQueueLoad(
          generation,
          loadingSongId: loadingSongId,
          failed: false,
        );
        rethrow;
      }
    });
  }

  /// Like [replaceQueue] but accepts pre-fetched [SongsTableData] rows,
  /// bypassing the library DAO read.  Used by UI screens that already hold the
  /// song data in memory (album detail, liked songs) so the song list does not
  /// need to be re-fetched from the database.
  ///
  /// Uses the same two-phase/lazy source-resolution path as [replaceQueue]:
  /// load the requested start item first, then resolve the rest in small
  /// batches. This keeps queue replacement from eagerly preparing hundreds of
  /// remote stream URLs on mobile data.
  @override
  Future<void> replaceQueueWithData(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
  }) async {
    _navigationIntent.reset();
    _pendingLogicalQueueSongs = songs;
    _supersedeTransportIntent(shouldPlay: autoPlay);
    // A remote row can be identity-matched to a local catalog row after it
    // was rendered in a playlist/artist/album list.  Whole-entity playback
    // must retain that supplied remote source rather than canonicalizing it
    // away and re-reading only the local row.
    final canonicalIds = navisQueueSourceIds(
      songs,
      canonicalize: _canonicalSongId,
    );
    final requestedStartIndex = canonicalIds.isEmpty
        ? 0
        : startIndex.clamp(0, canonicalIds.length - 1);
    if (canonicalIds.isNotEmpty) _navigationIntent.select(requestedStartIndex);
    if (canonicalIds.isNotEmpty) {
      _acceptStartupSelection(
        canonicalIds[requestedStartIndex],
        isExternal: isExternalCatalogSource(
          id: canonicalIds[requestedStartIndex],
          apiIsExternal: songs[requestedStartIndex].isExternal,
        ),
      );
    }
    final admittedGeneration = _supersedeQueueWork(
      isLoading: canonicalIds.isNotEmpty,
      loadingSongId: canonicalIds.isEmpty
          ? null
          : canonicalIds[requestedStartIndex],
      pendingLogicalQueueSongIds: canonicalIds.length > 1 ? canonicalIds : null,
    );
    // In a mixed-source entity queue, preserve every supplied row as-is.  In
    // particular, an external row may be matched to a local identity and its
    // ID therefore cannot safely be used to re-read the queue from the local
    // catalog.  This also keeps the order and source choice intact when a
    // separate local row happens to have a retired identity.
    final hasExternalSource = songs.any((song) => song.isExternal);
    final hasRetiredIdentity =
        !hasExternalSource &&
        Iterable<int>.generate(
          songs.length,
        ).any((index) => canonicalIds[index] != songs[index].id);
    if (hasRetiredIdentity) {
      final canonicalSongs = await _libraryDao.getSongsByIds(canonicalIds);
      if (!_isActiveLoadGeneration(admittedGeneration)) return;
      return replaceQueueWithData(
        canonicalSongs,
        startIndex: startIndex,
        autoPlay: autoPlay,
        expandMatchFlows: expandMatchFlows,
      );
    }
    // Match Flow expansion is ID based and would likewise re-fetch a matched
    // remote row. Preserve the caller's exact mixed-source entity queue.
    if (expandMatchFlows && songs.isNotEmpty && !hasExternalSource) {
      final expansion = await _expandMatchFlowIds(
        songs.map((song) => song.id).toList(growable: false),
        startIndex: startIndex,
        expandMatchFlows: true,
      );
      final expandedSongs = await _libraryDao.getSongsByIds(expansion.songIds);
      if (!_isActiveLoadGeneration(admittedGeneration)) return;
      return replaceQueueWithData(
        expandedSongs,
        startIndex: expansion.startIndex,
        autoPlay: autoPlay,
        expandMatchFlows: false,
      );
    }
    if (!_isActiveLoadGeneration(admittedGeneration)) return;
    final normalizedStartIndex = songs.isEmpty
        ? 0
        : startIndex.clamp(0, songs.length - 1);
    if (songs.isNotEmpty) _navigationIntent.select(normalizedStartIndex);
    final loadingSongId = songs.isEmpty ? null : songs[normalizedStartIndex].id;
    final generation = _supersedeQueueWork(
      isLoading: songs.isNotEmpty,
      loadingSongId: loadingSongId,
      pendingLogicalQueueSongIds: songs.length > 1
          ? songs.map((song) => song.id).toList(growable: false)
          : null,
    );
    if (songs.isEmpty) {
      return _queueLane.run((token) async {
        await _ready;
        _checkQueueWorkCurrent(token, generation);
        await _clearQueueInternal(persist: true);
        _completeQueueLoad(generation);
      });
    }
    return _queueLane.run((token) async {
      try {
        await _ready;
        _checkQueueWorkCurrent(token, generation);
        _pendingLogicalQueueSongs = songs;
        _cancelCrossfade();
        _radioMetadataService.stop();
        _radioStation = null;

        final startItem = await _replaceQueuePhase1(
          songs: songs,
          startIndex: normalizedStartIndex,
          autoPlay: autoPlay,
          persist: false,
          generation: generation,
          token: token,
        );
        if (startItem != null) {
          await _persistLogicalQueue(
            songs.map((song) => song.id).toList(growable: false),
            normalizedStartIndex,
            generation: generation,
          );
        }

        if (startItem == null || songs.length <= 1) {
          _completeQueueLoad(generation);
          return;
        }

        await _replaceQueuePhase2(
          songs: songs,
          startIndex: normalizedStartIndex,
          startItem: startItem,
          persist: true,
          token: token,
          generation: generation,
          deferTail: _shouldDeferTail(songs.length),
        );
        _completeQueueLoad(generation);
      } on OperationCancelledException {
        AppLogger.debug(
          'replaceQueueWithData cancelled — superseded by newer command.',
        );
      } on PlaybackLoadTimeoutException catch (error) {
        if (!_isActiveLoadGeneration(generation)) return;
        _completeQueueLoad(
          generation,
          loadingSongId: error.songId ?? loadingSongId,
          failed: true,
        );
        final nextIndex = _nextPlayableIndexAfterFailure(
          normalizedStartIndex,
          songs.length,
        );
        if (nextIndex != null) {
          unawaited(
            replaceQueueWithData(
              songs,
              startIndex: nextIndex,
              autoPlay: _latestExplicitTransportPlaying ?? autoPlay,
              expandMatchFlows: false,
            ),
          );
        }
      } on Object {
        _completeQueueLoad(
          generation,
          loadingSongId: loadingSongId,
          failed: false,
        );
        rethrow;
      }
    });
  }

  @override
  Future<void> addToQueue(
    List<String> songIds, {
    bool expandMatchFlows = true,
  }) {
    return _enqueueQueueEdit((token) async {
      songIds = (await _expandMatchFlowIds(
        songIds,
        startIndex: 0,
        expandMatchFlows: expandMatchFlows,
      )).songIds;
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
          expandMatchFlows: false,
        );
        return;
      }

      await _appendToQueue(
        songIds.map(_DeferredQueueEntry.new).toList(growable: false),
        token: token,
        context: 'add to queue',
      );
    });
  }

  /// Appends [entries] to the end of the logical queue without interrupting
  /// playback. Behind a deferred tail they simply join it; otherwise up to one
  /// page is materialised with a single native append and the rest deferred.
  /// Returns the ids that were dropped as unplayable.
  Future<List<String>> _appendToQueue(
    List<_DeferredQueueEntry> entries, {
    required OperationToken token,
    required String context,
  }) async {
    if (entries.isEmpty) return const <String>[];
    final canDefer = !_player.shuffleModeEnabled;
    if (canDefer && _deferredTail.isNotEmpty) {
      _deferredTail.addAll(entries);
      _afterQueueEdit(context: context);
      return const <String>[];
    }
    final materialize = canDefer && entries.length > _queueWindow.page
        ? entries.sublist(0, _queueWindow.page)
        : entries;
    final rows = await _rowsForDeferredEntries(materialize);
    final (:prepared, :offsets) = await _prepareRowsConcurrently(
      rows,
      token: token,
    );
    final skipped = <String>[
      for (var i = 0; i < materialize.length; i++)
        if (offsets[i] == null) materialize[i].id,
    ];
    var inserted = const <_PreparedQueueItem>[];
    if (prepared.isNotEmpty) {
      final wasPlayingBeforeMutation = _player.playing;
      final firstInsertedIndex = _queueItems.length;
      final queueWasCompletedBeforeInsertion =
          _player.processingState == ProcessingState.completed;
      inserted = await _applyMaterialisedInsert(
        prepared,
        at: _queueItems.length,
        operation: '$context append',
      );
      skipped.addAll(
        prepared
            .where((item) => !inserted.contains(item))
            .map((item) => item.song.id),
      );
      await _resumeInsertedItemIfCompleted(
        wasPlayingBeforeMutation: wasPlayingBeforeMutation,
        queueWasCompletedBeforeInsertion: queueWasCompletedBeforeInsertion,
        firstInsertedIndex: firstInsertedIndex,
      );
    }
    if (materialize.length < entries.length) {
      _deferredTail.addAll(entries.sublist(materialize.length));
      await _syncNativeLoopMode();
    }
    if (inserted.isEmpty && materialize.length == entries.length) {
      return skipped;
    }
    _afterQueueEdit(context: context);
    return skipped;
  }

  /// Inserts prepared songs at materialised index [at] with one native call
  /// (and one mirror call on an in-sync crossfade deck). A successful native
  /// call is always committed. When the batch fails, songs are inserted one by
  /// one and the failing ones skipped. Returns the songs that were inserted.
  Future<List<_PreparedQueueItem>> _applyMaterialisedInsert(
    List<_PreparedQueueItem> prepared, {
    required int at,
    required String operation,
  }) async {
    final inactiveDeck = _crossfadePlayer;
    final deckInSync =
        inactiveDeck != null &&
        inactiveDeck.sequence.length == _queueItems.length;
    Future<void> apply(int index, List<_PreparedQueueItem> items) {
      final sources = items
          .map((item) => item.audioSource)
          .toList(growable: false);
      return _runTimedPlayerOperation(
        generation: _activeLoadGeneration,
        operation: operation,
        action: () => index >= _queueItems.length
            ? _player.addAudioSources(sources)
            : _player.insertAudioSources(index, sources),
        songId: items.first.song.id,
        cancelAfterSuccess: false,
        reloadQueueOnTimeout: true,
      );
    }

    final inserted = <_PreparedQueueItem>[];
    try {
      await apply(at, prepared);
      _queueItems.insertAll(at, prepared.map((item) => item.mediaItem));
      inserted.addAll(prepared);
    } on PlaybackLoadTimeoutException {
      rethrow;
    } on OperationCancelledException {
      rethrow;
    } on Object catch (error) {
      AppLogger.warning(
        '$operation failed for ${prepared.length} songs; inserting them one '
        'by one. $error',
      );
      var index = at;
      for (final item in prepared) {
        try {
          await apply(index, <_PreparedQueueItem>[item]);
        } on PlaybackLoadTimeoutException {
          rethrow;
        } on Object {
          _lastFailedSongId = item.song.id;
          continue;
        }
        _queueItems.insert(index, item.mediaItem);
        inserted.add(item);
        index++;
      }
    }
    if (deckInSync && inserted.isNotEmpty) {
      final clones = inserted
          .map((item) => item.source.asClonedAudioSource(tag: item.mediaItem))
          .toList(growable: false);
      try {
        if (at >= inactiveDeck.sequence.length) {
          await inactiveDeck.addAudioSources(clones);
        } else {
          await inactiveDeck.insertAudioSources(at, clones);
        }
      } on Object catch (error) {
        AppLogger.debug('$operation inactive deck mirror failed: $error');
      }
    }
    _observeLockCacheForPrepared(inserted);
    return inserted;
  }

  /// Publishes a queue edit: one queue emission, one coalesced save, one
  /// snapshot.
  void _afterQueueEdit({required String context}) {
    // An edit may have emptied the deferred tail, which re-enables repeat-all.
    unawaited(
      _syncNativeLoopMode().catchError((Object error) {
        AppLogger.debug('Repeat mode sync after "$context" failed: $error');
      }),
    );
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _scheduleQueueItemsPersistence(context: context);
    _broadcastPlaybackState();
    _emitSnapshot();
  }

  /// Resolves [rows] concurrently in chunks, keeping queue order. `offsets`
  /// gives each row's index in `prepared`, or null when it was dropped.
  Future<({List<_PreparedQueueItem> prepared, List<int?> offsets})>
  _prepareRowsConcurrently(
    List<SongsTableData?> rows, {
    OperationToken? token,
  }) async {
    final prepared = <_PreparedQueueItem>[];
    final offsets = <int?>[];
    for (
      var start = 0;
      start < rows.length;
      start += _queueFillBatchSizeLimit
    ) {
      final chunk = rows.sublist(
        start,
        math.min(start + _queueFillBatchSizeLimit, rows.length),
      );
      final resolved = await Future.wait(
        chunk.map(
          (row) => row == null
              ? Future<_PreparedQueueItem?>.value()
              : _prepareSingleItemForQueueFill(row),
        ),
      );
      for (final item in resolved) {
        offsets.add(item == null ? null : prepared.length);
        if (item != null) prepared.add(item);
      }
      token?.checkCancelled();
    }
    return (prepared: prepared, offsets: offsets);
  }

  /// Runs a queue edit in order behind other queue work. An edit that finds
  /// a replacement still loading (its owner was superseded by a navigation
  /// queued after this edit) waits for that once, so it applies to the
  /// finished queue rather than the half-built one.
  Future<void> _enqueueQueueEdit(
    Future<void> Function(OperationToken token) edit,
  ) {
    final done = Completer<void>();
    var waitedForLoad = false;
    Future<void> attempt() async {
      var requeue = false;
      try {
        await _queueLane.enqueue((token) async {
          await _ready;
          if (!waitedForLoad && _pendingLogicalQueueSongIds != null) {
            waitedForLoad = true;
            requeue = true;
            return;
          }
          await edit(token);
        });
      } on Object catch (error, stackTrace) {
        if (!done.isCompleted) done.completeError(error, stackTrace);
        return;
      }
      if (requeue) {
        unawaited(attempt());
        return;
      }
      if (!done.isCompleted) done.complete();
    }

    unawaited(attempt());
    return done.future;
  }

  @override
  Future<QueueBatchEditResult> mergeIntoUpcoming(
    List<SongsTableData> songs, {
    required int notBefore,
    math.Random? random,
  }) async {
    var result = const QueueBatchEditResult();
    if (songs.isEmpty) return result;
    await _enqueueQueueEdit((token) async {
      if (_queueItems.isEmpty) return;
      final entries = songs.map(_deferredEntryFor).toList(growable: false);
      if (_player.shuffleModeEnabled) {
        // Native shuffle places new songs itself.
        result = QueueBatchEditResult(
          skippedSongIds: await _appendToQueue(
            entries,
            token: token,
            context: 'merge upcoming',
          ),
        );
        return;
      }
      // The current song and the next two stay in the player (gapless, and
      // a stable "up next"); everything after them is merged in Dart. Songs
      // the player already holds past that point go back to the deferred
      // tail with one native call, so a merge costs O(1) native operations
      // however many songs arrive, and refills release them again.
      final current = _player.currentIndex ?? 0;
      final mergeFrom = math.max(notBefore, current + 3);
      if (mergeFrom < _queueItems.length) {
        await _deferMaterialisedFrom(mergeFrom);
      }
      final tailStart = math.max(0, mergeFrom - _queueItems.length);
      final region = _deferredTail.sublist(
        math.min(tailStart, _deferredTail.length),
      );
      final merged = _interleaveRandomly(
        region,
        entries,
        random ?? math.Random(),
      );
      _deferredTail
        ..removeRange(
          math.min(tailStart, _deferredTail.length),
          _deferredTail.length,
        )
        ..addAll(merged);
      await _syncNativeLoopMode();
      _afterQueueEdit(context: 'merge upcoming');
    });
    return result;
  }

  /// Moves the materialised songs from [from] onward back to the front of
  /// the deferred tail with one native range removal.
  Future<void> _deferMaterialisedFrom(int from) async {
    final end = _queueItems.length;
    if (from >= end) return;
    final inactiveDeck = _crossfadePlayer;
    final deckInSync =
        inactiveDeck != null && inactiveDeck.sequence.length == end;
    await _runTimedPlayerOperation(
      generation: _activeLoadGeneration,
      operation: 'defer materialised queue',
      reloadQueueOnTimeout: true,
      action: () => _player.removeAudioSourceRange(from, end),
      songId: _queueItems[from].id,
      timeout: _playerResetTimeout,
      cancelAfterSuccess: false,
    );
    final moved = _queueItems.sublist(from);
    _queueItems.removeRange(from, end);
    _deferredTail.insertAll(
      0,
      moved.map(_deferredEntryForItem),
    );
    if (deckInSync) {
      try {
        await inactiveDeck.removeAudioSourceRange(from, end);
      } on Object catch (error) {
        AppLogger.debug('Deferred range deck mirror failed: $error');
      }
    }
  }

  /// Uniform random interleave of [incoming] into [existing], keeping the
  /// relative order of [existing]; O(n + m).
  static List<T> _interleaveRandomly<T>(
    List<T> existing,
    List<T> incoming,
    math.Random random,
  ) {
    final shuffled = List<T>.of(incoming)..shuffle(random);
    final result = <T>[];
    var a = 0;
    var b = 0;
    while (a < existing.length || b < shuffled.length) {
      final remainingA = existing.length - a;
      final remainingB = shuffled.length - b;
      if (remainingB > 0 &&
          (remainingA == 0 ||
              random.nextInt(remainingA + remainingB) < remainingB)) {
        result.add(shuffled[b++]);
      } else {
        result.add(existing[a++]);
      }
    }
    return result;
  }

  @override
  Future<QueueBatchEditResult> insertQueueRuns(
    List<QueueInsertRun> runs,
  ) async {
    final skipped = <String>[];
    if (runs.every((run) => run.songs.isEmpty)) {
      return const QueueBatchEditResult();
    }
    await _enqueueQueueEdit((token) async {
      if (_queueItems.isEmpty) return;
      final ordered = List<QueueInsertRun>.of(runs)
        ..sort((a, b) => b.index.compareTo(a.index));
      var changed = false;
      for (final run in ordered) {
        if (run.songs.isEmpty) continue;
        final total = _queueItems.length + _deferredTail.length;
        final index = run.index.clamp(0, total);
        final entries = run.songs
            .map(_deferredEntryFor)
            .toList(growable: false);
        if (index >= _queueItems.length &&
            !_player.shuffleModeEnabled &&
            (_deferredTail.isNotEmpty || entries.length > _queueWindow.page)) {
          _deferredTail.insertAll(index - _queueItems.length, entries);
          changed = true;
          continue;
        }
        final rows = await _rowsForDeferredEntries(entries);
        final (:prepared, :offsets) = await _prepareRowsConcurrently(
          rows,
          token: token,
        );
        for (var i = 0; i < entries.length; i++) {
          if (offsets[i] == null) skipped.add(entries[i].id);
        }
        if (prepared.isEmpty) continue;
        final inserted = await _applyMaterialisedInsert(
          prepared,
          at: math.min(index, _queueItems.length),
          operation: 'insert queue run',
        );
        skipped.addAll(
          prepared
              .where((item) => !inserted.contains(item))
              .map((item) => item.song.id),
        );
        changed = changed || inserted.isNotEmpty;
      }
      if (changed) {
        await _syncNativeLoopMode();
        _afterQueueEdit(context: 'insert queue runs');
      }
    });
    return QueueBatchEditResult(skippedSongIds: skipped);
  }

  @override
  Future<void> playNext(
    List<String> songIds, {
    bool expandMatchFlows = true,
  }) {
    return _enqueueQueueEdit((token) async {
      final expanded = (await _expandMatchFlowIds(
        songIds,
        startIndex: 0,
        expandMatchFlows: expandMatchFlows,
      )).songIds;
      final incoming = expanded
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
          expandMatchFlows: false,
        );
        return;
      }

      // Resolve the new songs and insert them right after the current item
      // with one native call; this does not interrupt playback.
      final rows = await _rowsForDeferredEntries(
        incoming.map(_DeferredQueueEntry.new).toList(growable: false),
      );
      final (:prepared, offsets: _) = await _prepareRowsConcurrently(
        rows,
        token: token,
      );
      if (prepared.isEmpty) return;
      token.checkCancelled();

      final wasPlayingBeforeMutation = _player.playing;
      final currentIndex = (_player.currentIndex ?? 0).clamp(
        0,
        _queueItems.length - 1,
      );
      final insertAt = (currentIndex + 1).clamp(0, _queueItems.length);
      final queueWasCompletedBeforeInsertion =
          _player.processingState == ProcessingState.completed;
      final inserted = await _applyMaterialisedInsert(
        prepared,
        at: insertAt,
        operation: 'play next insert',
      );
      if (inserted.isEmpty) return;

      await _resumeInsertedItemIfCompleted(
        wasPlayingBeforeMutation: wasPlayingBeforeMutation,
        queueWasCompletedBeforeInsertion: queueWasCompletedBeforeInsertion,
        firstInsertedIndex: insertAt,
      );
      _afterQueueEdit(context: 'play next');
    });
  }

  @override
  Future<void> retainCurrentSongAsQueue(String songId) {
    return _queueLane.run((token) async {
      await _ready;
      final normalizedSongId = songId.trim();
      if (normalizedSongId.isEmpty) {
        return;
      }

      if (_queueItems.isEmpty) {
        await _replaceQueueFromIds(
          <String>[normalizedSongId],
          startIndex: 0,
          autoPlay: true,
          persist: true,
          expandMatchFlows: false,
        );
        return;
      }

      token.checkCancelled();
      await _playbackLane.run(() async {
        _cancelCrossfade();
        var currentIndex = _resolveCurrentQueueMetadata().currentIndex;
        currentIndex ??= _player.currentIndex;
        if (currentIndex == null ||
            currentIndex < 0 ||
            currentIndex >= _queueItems.length ||
            _queueItems[currentIndex].id != normalizedSongId) {
          final fallbackIndex = _queueItems.indexWhere(
            (item) => item.id == normalizedSongId,
          );
          if (fallbackIndex < 0) {
            await _replaceQueueFromIds(
              <String>[normalizedSongId],
              startIndex: 0,
              autoPlay: true,
              persist: true,
              expandMatchFlows: false,
            );
            return;
          }
          currentIndex = fallbackIndex;
        }

        if (_queueItems.length == 1 &&
            currentIndex == 0 &&
            _deferredTail.isEmpty) {
          return;
        }

        final generation = _activeLoadGeneration;
        final wasPlayingBeforeMutation = _player.playing;
        final originalLength = _queueItems.length;
        final removeAfterStart = currentIndex + 1;
        if (removeAfterStart < originalLength) {
          await _removeQueueSourceRange(
            removeAfterStart,
            originalLength,
            generation: generation,
            operation: 'retain current remove after',
          );
          _queueItems.removeRange(removeAfterStart, originalLength);
          token.checkCancelled();
        }

        if (currentIndex > 0) {
          await _removeQueueSourceRange(
            0,
            currentIndex,
            generation: generation,
            operation: 'retain current remove before',
          );
          _queueItems.removeRange(0, currentIndex);
          token.checkCancelled();
        }

        await _clearDeferredTail();
        _clearQueueReplacementMetadataAnchor();
        _clearPendingLogicalQueue();
        if (_queueItems.isNotEmpty) {
          _setCurrentMediaItem(_queueItems.first);
        }
        if (wasPlayingBeforeMutation && !_player.playing) {
          unawaited(_player.play());
        }
      });
      queue.add(List<MediaItem>.unmodifiable(_queueItems));
      await _persistSafely(
        () => _persistQueueState(includeQueueItems: true),
        context: 'retain current queue item',
      );
      _broadcastPlaybackState();
      _emitSnapshot();
    });
  }

  /// Applies a queue edit the Dart queue already reflects to the active
  /// player, and then to the inactive crossfade deck when [mirror] says it
  /// is in step. A stuck native call times out and reloads the queue into
  /// rebuilt players instead of holding the queue lane forever.
  Future<void> _timedQueueEdit(
    String operation,
    Future<void> Function(AudioPlayer player) action, {
    required String songId,
    bool Function(AudioPlayer deck)? mirror,
  }) async {
    await _runTimedPlayerOperation(
      generation: _activeLoadGeneration,
      operation: operation,
      action: () => action(_player),
      songId: songId,
      timeout: _playerResetTimeout,
      cancelAfterSuccess: false,
      reloadQueueOnTimeout: true,
    );
    final deck = _crossfadePlayer;
    if (deck == null || !(mirror?.call(deck) ?? false)) return;
    try {
      await _runTimedPlayerOperation(
        generation: _activeLoadGeneration,
        operation: '$operation inactive',
        action: () => action(deck),
        songId: songId,
        timeout: _playerResetTimeout,
        cancelAfterSuccess: false,
        reloadQueueOnTimeout: true,
      );
    } on Object catch (error) {
      AppLogger.debug('$operation inactive deck mirror failed: $error');
    }
  }

  Future<void> _removeQueueSourceRange(
    int start,
    int end, {
    required int generation,
    required String operation,
  }) async {
    await _runTimedPlayerOperation(
      generation: generation,
      operation: operation,
      action: () => _player.removeAudioSourceRange(start, end),
      songId: '$start-$end',
      timeout: _playerResetTimeout,
      reloadQueueOnTimeout: true,
    );
    final inactiveDeck = _crossfadePlayer;
    if (inactiveDeck == null) {
      return;
    }
    try {
      await _runTimedPlayerOperation(
        generation: generation,
        operation: '$operation inactive',
        action: () => inactiveDeck.removeAudioSourceRange(start, end),
        songId: '$start-$end',
        timeout: _playerResetTimeout,
        // Recovery rebuilds both decks, emptying the active one too.
        reloadQueueOnTimeout: true,
      );
    } on Object catch (error) {
      AppLogger.debug(
        '$operation inactive deck range removal failed '
        'for $start-$end: $error',
      );
    }
  }

  Future<void> _resumeInsertedItemIfCompleted({
    required bool wasPlayingBeforeMutation,
    required bool queueWasCompletedBeforeInsertion,
    required int firstInsertedIndex,
  }) async {
    final resumeIndex = navisResumeIndexAfterQueueInsertion(
      wasPlayingBeforeMutation: wasPlayingBeforeMutation,
      queueWasCompletedBeforeMutation: queueWasCompletedBeforeInsertion,
      processingStateAfterMutation: _player.processingState,
      firstInsertedIndex: firstInsertedIndex,
      queueLength: _queueItems.length,
    );
    if (resumeIndex == null) {
      return;
    }

    _clearQueueReplacementMetadataAnchor();
    await _player.seek(Duration.zero, index: resumeIndex);
    final inactiveDeck = _crossfadePlayer;
    if (inactiveDeck != null) {
      try {
        await inactiveDeck.seek(Duration.zero, index: resumeIndex);
      } on Object catch (error) {
        AppLogger.debug(
          'inactive deck seek after completed queue insertion failed: $error',
        );
      }
    }
    if (resumeIndex >= 0 && resumeIndex < _queueItems.length) {
      _setCurrentMediaItem(_queueItems[resumeIndex]);
    }
    unawaited(_player.play());
  }

  @override
  Future<void> playFromIndex(int index) {
    final logicalIds = _logicalQueueIds;
    if (index < 0 || index >= logicalIds.length) return Future<void>.value();
    _invalidatePendingStartupSelection();
    return _applyNavigationDecision(
      _navigationIntent.select(index),
      logicalIds: logicalIds,
      shouldPlay: true,
      context: 'play from index',
    );
  }

  @override
  Future<void> removeAt(int index) {
    return _enqueueQueueEdit((_) async {
      final total = _queueItems.length + _deferredTail.length;
      if (index < 0 || index >= total) {
        return;
      }

      if (total == 1) {
        await _clearQueueInternal(persist: true);
        return;
      }

      if (index >= _queueItems.length) {
        _deferredTail.removeAt(index - _queueItems.length);
        if (_deferredTail.isEmpty) await _syncNativeLoopMode();
        _scheduleQueueItemsPersistence(context: 'remove at');
        _broadcastPlaybackState();
        _emitSnapshot();
        return;
      }

      // The player needs a following song before its last materialised one
      // goes; otherwise removing the current song would end playback.
      if (index == _queueItems.length - 1 && _deferredTail.isNotEmpty) {
        try {
          await _releaseTail(count: _queueWindow.page);
        } on PlaybackSourceTemporarilyUnavailableException {
          // Nothing playable follows yet; the removal still applies.
        }
      }

      // Remove the audio source and queue item incrementally — this does NOT
      // interrupt playback of other items.  If the currently playing item is
      // removed, just_audio automatically advances to the next item.
      final removed = _queueItems.removeAt(index);
      await _timedQueueEdit(
        'remove queue item',
        (player) => player.removeAudioSourceAt(index),
        songId: removed.id,
        mirror: (deck) => deck.sequence.length > index,
      );

      queue.add(List<MediaItem>.unmodifiable(_queueItems));
      // Update the mediaItem stream to match whatever is now current.
      final nowIndex = _player.currentIndex;
      if (nowIndex != null && nowIndex >= 0 && nowIndex < _queueItems.length) {
        _setCurrentMediaItem(_queueItems[nowIndex]);
      }

      _scheduleQueueItemsPersistence(context: 'remove at');
      _broadcastPlaybackState();
      _emitSnapshot();
    });
  }

  @override
  Future<void> reorderQueue(int oldIndex, int newIndex) {
    return _enqueueQueueEdit((token) async {
      final total = _queueItems.length + _deferredTail.length;
      if (total == 0) {
        return;
      }
      if (oldIndex < 0 || oldIndex >= total) {
        return;
      }
      // ReorderableListView can report newIndex == length when dragging to
      // the end; treat that as a valid destination.
      if (newIndex < 0 || newIndex > total) {
        return;
      }

      final adjustedIndex = oldIndex < newIndex
          ? newIndex - 1
          : newIndex.clamp(0, total - 1);
      if (oldIndex == adjustedIndex) {
        return;
      }

      var materialized = _queueItems.length;
      if (oldIndex >= materialized && adjustedIndex >= materialized) {
        // Both ends deferred: a Dart-only move.
        final entry = _deferredTail.removeAt(oldIndex - materialized);
        _deferredTail.insert(adjustedIndex - materialized, entry);
      } else if (oldIndex >= materialized) {
        // Deferred song moved into the player's window: resolve it and insert
        // it with one native call.
        final entry = _deferredTail.removeAt(oldIndex - materialized);
        final List<_PreparedQueueItem> inserted;
        try {
          final rows = await _rowsForDeferredEntries(<_DeferredQueueEntry>[
            entry,
          ]);
          final (:prepared, offsets: _) = await _prepareRowsConcurrently(rows);
          inserted = prepared.isEmpty
              ? const <_PreparedQueueItem>[]
              : await _applyMaterialisedInsert(
                  prepared,
                  at: adjustedIndex,
                  operation: 'reorder into window',
                );
        } on Object {
          // Keep the song queued where it was.
          _deferredTail.insert(oldIndex - materialized, entry);
          rethrow;
        }
        if (inserted.isEmpty) {
          _tailDroppedSongCount++;
          _reportDroppedSongs(<String>[entry.id], QueueDropReason.insert);
        }
      } else {
        if (adjustedIndex >= materialized &&
            oldIndex == (_player.currentIndex ?? -1)) {
          // Keep the playing song in the player: release through the target
          // so the move stays inside the window.
          try {
            await _releaseTail(count: adjustedIndex - materialized + 1);
          } on PlaybackSourceTemporarilyUnavailableException {
            // The target stays deferred; the move below handles that.
          }
          materialized = _queueItems.length;
        }
        if (adjustedIndex < materialized) {
          // Reorder the in-memory queue items to match the new order.
          final movedItem = _queueItems.removeAt(oldIndex);
          _queueItems.insert(adjustedIndex, movedItem);

          // Move the audio source in the player's playlist — this does NOT
          // interrupt playback; just_audio tracks the current item internally.
          _nativeMoveCount++;
          await _timedQueueEdit(
            'reorder queue',
            (player) => player.moveAudioSource(oldIndex, adjustedIndex),
            songId: movedItem.id,
            mirror: (deck) =>
                deck.sequence.length > oldIndex &&
                deck.sequence.length > adjustedIndex,
          );
        } else {
          // Materialised song moved behind the window: take it out of the
          // player and defer it at its new logical position.
          // Deferred before the native call, so a timeout cannot lose it.
          final movedItem = _queueItems.removeAt(oldIndex);
          _deferredTail.insert(
            adjustedIndex - _queueItems.length,
            _deferredEntryForItem(movedItem),
          );
          await _timedQueueEdit(
            'reorder behind window',
            (player) => player.removeAudioSourceAt(oldIndex),
            songId: movedItem.id,
            mirror: (deck) => deck.sequence.length > oldIndex,
          );
        }
      }

      // Reorders arrive in bursts (drag sequences), and each full-queue write
      // rewrites every row. Persist once the burst settles.
      _afterQueueEdit(context: 'reorder queue');
    });
  }

  @override
  Future<void> clearQueue() {
    _invalidatePendingStartupSelection();
    _navigationIntent.reset();
    _pendingLogicalQueueSongs = null;
    _supersedeTransportIntent();
    _cancelCrossfade();
    _cancelRemotePlaybackStallWatchdog();
    _radioMetadataService.stop();
    _radioStation = null;
    final generation = _supersedeQueueWork();
    return _queueLane.run((token) async {
      await _ready;
      _checkQueueWorkCurrent(token, generation);
      await _sidecarDownloader.cancel();
      _sidecarSongsById.clear();
      _rollingCacheActivities.clear();
      _reportRollingCacheActivity?.call(const RollingCacheActivity.idle());
      await _clearQueueInternal(persist: true, generation: generation);
      _completeQueueLoad(generation);
    });
  }

  @override
  Future<void> resetSession() => clearQueue();

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
    final transportGeneration = _supersedeTransportIntent(shouldPlay: true);
    await _ready;
    if (!_isCurrentTransportIntent(transportGeneration)) return;

    // A selected source has not reached phase one yet. The current play
    // intent will start it there; an empty-queue fallback here could replace
    // the user's newer selection with an older persisted queue.
    if (_radioStation == null &&
        _queueItems.isEmpty &&
        _isLoading &&
        _loadingSongId != null) {
      return;
    }

    if (_radioStation == null && _queueItems.isEmpty) {
      final prepared = await _prepareBestAvailableQueueForUserPlay();
      if (!_isCurrentTransportIntent(transportGeneration)) return;
      if (!prepared || (_radioStation == null && _queueItems.isEmpty)) {
        AppLogger.info('Android Auto resume: play ignored; queue is empty.');
        _broadcastAndroidAutoPlaybackError(
          'No music is available. Open Navis on your phone when safe.',
        );
        return;
      }
    }

    // Edge case: when the queue has played to completion (processingState ==
    // completed) and the user presses play, just_audio stays stuck at the end
    // rather than restarting.  Seek back to the beginning of the queue first
    // so playback actually resumes from the start.
    if (_player.processingState == ProcessingState.completed &&
        _radioStation == null &&
        _deferredTail.isNotEmpty) {
      await playFromIndex(_queueItems.length);
      return;
    }
    if (_player.processingState == ProcessingState.completed &&
        navisShouldRestartCompletedQueue(
          queueLength: _queueItems.length,
          currentIndex: _resolveCurrentQueueMetadata().currentIndex,
          hasPendingLogicalQueue: _pendingLogicalQueueSongIds != null,
        )) {
      await _player.seek(Duration.zero, index: 0);
      if (!_isCurrentTransportIntent(transportGeneration)) return;
      final inactiveDeck = _crossfadePlayer;
      if (inactiveDeck != null) {
        await inactiveDeck.seek(Duration.zero, index: 0);
        if (!_isCurrentTransportIntent(transportGeneration)) return;
      }
    }

    // play() must NOT go through _runSerialized — _player.play() returns a
    // Future that blocks until playback finishes/pauses.  Serializing it would
    // deadlock all subsequent operations (pause, seek, skip, queue changes).
    unawaited(_player.play());
    _scheduleTransportPersistence(context: 'play');
  }

  @override
  Future<void> pause() async {
    _invalidatePendingStartupSelection();
    final transportGeneration = _supersedeTransportIntent(shouldPlay: false);
    await _ready;
    if (!_isCurrentTransportIntent(transportGeneration)) return;
    _cancelCrossfade();
    await _player.pause();
    _broadcastPlaybackState();
    _emitSnapshot();
    _scheduleTransportPersistence(context: 'pause');
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    switch (button) {
      case MediaButton.media:
        if (_player.playing) {
          await pause();
        } else {
          await play();
        }
        return;
      case MediaButton.next:
        await skipToNext();
        return;
      case MediaButton.previous:
        await skipToPrevious();
        return;
    }
  }

  @override
  Future<void> applyRuntimeSettings() async {
    final runtime = _readRuntimeSettings();
    final wasCrossfadeEnabled = _crossfadeEnabled;
    _gaplessEnabled = navisEffectiveGaplessEnabled(
      gaplessEnabled: runtime.gaplessEnabled,
      crossfadeEnabled: runtime.crossfadeEnabled,
    );
    _crossfadeEnabled = runtime.crossfadeEnabled;
    _crossfadeDurationSeconds = runtime.crossfadeDurationSeconds;
    _crossfadeType = runtime.crossfadeType;

    if (!_crossfadeEnabled) {
      _cancelCrossfade();
      if (wasCrossfadeEnabled || _crossfadePlayer != null) {
        await _disposeInactiveCrossfadeDeck();
      }
    } else if (_crossfadePlayer == null) {
      final inactiveDeck = _newCrossfadePlayer();
      _crossfadePlayer = inactiveDeck;
    }

    var desired = PlaybackAdjustments(
      speed: runtime.playbackSpeed,
      lockPitchToSpeed:
          playbackAdjustmentCapabilities.pitchSupported &&
          runtime.lockPitchToSpeed,
      pitchSemitones: playbackAdjustmentCapabilities.pitchSupported
          ? runtime.playbackPitchSemitones
          : 0,
    );
    if (!playbackAdjustmentCapabilities.supports(desired) &&
        desired.lockPitchToSpeed) {
      desired = desired.copyWith(pitchSemitones: 0, lockPitchToSpeed: false);
    }
    await _setPlaybackAdjustments(desired);

    // Apply ReplayGain volume normalization for current track.
    _applyReplayGainVolume();

    if (equalizerCapabilities.supported) {
      await _setEqualizer(runtime.equalizer ?? _desiredEqualizer);
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

    final resolved = _resolveCurrentQueueMetadata();
    final index = resolved.currentIndex;
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
    final linear = (math.pow(10, (gainDb + preamp) / 20).toDouble() * base)
        .clamp(0.0, 1.0);
    unawaited(_player.setVolume(linear));
  }

  @override
  Future<void> seek(Duration position) {
    final generation = _supersedeTransportIntent();
    return _seekLane.run((token) async {
      await _ready;
      token.checkCancelled();
      if (!_isCurrentTransportIntent(generation)) {
        return;
      }
      _cancelCrossfade();
      final sanitizedPosition = navisSanitizeSeekPosition(position);
      await _seekWithRecovery(
        sanitizedPosition,
        token: token,
        transportGeneration: generation,
      );
      token.checkCancelled();
      if (_isCurrentTransportIntent(generation)) {
        _scheduleSeekBufferingRecovery(
          requestedPosition: sanitizedPosition,
          transportGeneration: generation,
        );
        _scheduleTransportPersistence(context: 'seek');
      }
    });
  }

  /// Reduces a media URI to a song reference that carries no credentials:
  /// the stream `id` parameter, or the file name for local sources.
  static String? _diagnosticMediaReference(String? uri) {
    if (uri == null) return null;
    final parsed = Uri.tryParse(uri);
    if (parsed == null) return null;
    if (parsed.scheme == 'http' || parsed.scheme == 'https') {
      return parsed.queryParameters['id'];
    }
    return parsed.pathSegments.isEmpty ? null : parsed.pathSegments.last;
  }

  @override
  Map<String, Object?> collectPlaybackDiagnostics() {
    final snapshot = _snapshot;
    final songId = snapshot.currentSongId;
    final cacheActivity = _rollingCacheActivities.values.lastOrNull;
    final partialCacheBytes = _partialCacheBytesForSong(songId);
    return <String, Object?>{
      'songId': songId,
      'queueLength': snapshot.queueSongIds.length,
      'playerSequenceLength': _player.sequence.length,
      'materializedLength': _queueItems.length,
      'deferredLength': _deferredTail.length,
      // Native order as the player holds it, for parity checks against the
      // logical queue (limited so large queues stay cheap to report).
      'native': <String, Object?>{
        'index': _player.currentIndex,
        'shuffleEnabled': _player.shuffleModeEnabled,
        'sequenceIds': <String?>[
          for (final source in _player.sequence.take(64))
            source.tag is MediaItem ? (source.tag as MediaItem).id : null,
        ],
        'effectiveIndices': _player.effectiveIndices.take(64).toList(),
        // What mpv itself is playing, reduced to the stream `id` parameter or
        // the cache file name so no credential-bearing URI is reported.
        'mediaKitCurrent': JustAudioMediaKit.debugCurrentMediaUris()
            ?.map(_diagnosticMediaReference)
            .toList(),
      },
      'queueFill': _lastQueueFill,
      'counters': <String, Object?>{
        'tailReleases': _tailReleaseCount,
        'tailReleasedSongs': _tailReleasedSongCount,
        'tailDroppedSongs': _tailDroppedSongCount,
        'snapshotBroadcasts': _snapshotBroadcastCount,
        'queueEmissions': _queueEmissionCount,
        'queueEmittedItems': _queueEmittedItemCount,
        'timedPlayerOperations': _timedPlayerOperationCount,
        'nativeMoves': _nativeMoveCount,
      },
      'slowPersistence': List<Map<String, Object?>>.of(_slowPersistence),
      'persistence': <String, Object?>{
        'operations': _persistOperationCount,
        'runMs': _persistRunMs,
        'byContext': Map<String, int>.of(_persistContextCounts),
      },
      'playing': snapshot.playing,
      'processingState': snapshot.processingState.name,
      'isLoading': snapshot.isLoading,
      'loadingSongId': snapshot.loadingSongId,
      'positionMs': snapshot.position.inMilliseconds,
      'bufferedPositionMs': snapshot.bufferedPosition.inMilliseconds,
      'durationMs': snapshot.duration.inMilliseconds,
      'shuffleMode': snapshot.shuffleMode.name,
      'repeatMode': snapshot.repeatMode.name,
      'sourceKind': _currentSourceKind,
      'lockCachingBypassed': songId != null
          ? _lockCachingBypassedSongIds.contains(songId)
          : false,
      'lockCachingBypassedSongIds': _lockCachingBypassedSongIds.toList(
        growable: false,
      ),
      'cacheActivity': cacheActivity == null
          ? null
          : <String, Object?>{
              'status': cacheActivity.status.name,
              'songId': cacheActivity.songId,
              'progress': cacheActivity.progress,
            },
      'partialCacheBytes': partialCacheBytes,
      'sidecarCacheActiveSongId': _sidecarDownloader.activeSongId,
      'playerPositionMs': _player.position.inMilliseconds,
      'playerBufferedPositionMs': _player.bufferedPosition.inMilliseconds,
      'userVolume': _userVolume,
      'effectivePlayerVolume': _player.volume,
      'playbackSpeed': _appliedAdjustments.speed,
      'playbackPitchSemitones': _appliedAdjustments.pitchSemitones,
      'lockPitchToSpeed': _appliedAdjustments.lockPitchToSpeed,
      'playerSpeed': _player.speed,
      'playerPitchFactor': playbackAdjustmentCapabilities.pitchSupported
          ? _player.pitch
          : 1,
      'crossfadeSpeed': _crossfadePlayer?.speed,
      'crossfadePitchFactor': playbackAdjustmentCapabilities.pitchSupported
          ? _crossfadePlayer?.pitch
          : null,
      'seekEvents': List<Map<String, Object?>>.from(_seekDiagnosticsEvents),
      'navigation': <String, Object?>{
        'revision': _navigationIntent.revision,
        'desiredIndex': _navigationIntent.desiredIndex,
        'confirmedIndex': snapshot.currentIndex,
        'pending': _navigationIntent.isPending,
        'pendingAgeMs':
            _navigationIntent.isPending && _navigationIssuedAt != null
            ? DateTime.now().difference(_navigationIssuedAt!).inMilliseconds
            : null,
        'supersededCount': _navigationSupersededCount,
        'completedCount': _navigationCompletedCount,
        'timeoutCount': _navigationTimeoutCount,
        'pendingQueueMutations': _queueLane.pendingCount,
      },
      'queueRestoreOutcome': _queueRestoreOutcome,
      'startupAttempts': <Map<String, Object?>>[
        for (final trace in _startupTraces) trace.toDiagnostics(),
      ],
    };
  }

  int? _partialCacheBytesForSong(String? songId) {
    if (songId == null) {
      return null;
    }
    for (final entry in _rollingCacheActivities.entries) {
      if (entry.value.songId != songId) {
        continue;
      }
      final partFile = File('${entry.key}.part');
      if (partFile.existsSync()) {
        return partFile.lengthSync();
      }
      final completed = File(entry.key);
      if (completed.existsSync()) {
        return completed.lengthSync();
      }
    }
    String? cachedPath;
    for (final item in _queueItems) {
      if (item.id != songId) {
        continue;
      }
      cachedPath = item.extras?['cachedFilePath'] as String?;
      break;
    }
    if (cachedPath == null || cachedPath.isEmpty) {
      return null;
    }
    final partFile = File('$cachedPath.part');
    if (partFile.existsSync()) {
      return partFile.lengthSync();
    }
    final completed = File(cachedPath);
    if (completed.existsSync()) {
      return completed.lengthSync();
    }
    return null;
  }

  void _recordSeekDiagnosticsEvent(Map<String, Object?> event) {
    _seekDiagnosticsEvents.add(event);
    if (_seekDiagnosticsEvents.length > _maxSeekDiagnosticsEvents) {
      _seekDiagnosticsEvents.removeRange(
        0,
        _seekDiagnosticsEvents.length - _maxSeekDiagnosticsEvents,
      );
    }
  }

  @override
  Future<void> skipToNext() => _navigateRelative(forward: true);

  @override
  Future<void> skipToPrevious() => _navigateRelative(forward: false);

  Future<void> _navigateRelative({required bool forward}) {
    final logicalIds = _logicalQueueIds;
    final confirmedIndex =
        _resolveCurrentQueueMetadata().currentIndex ?? _player.currentIndex;
    final effectiveOrder =
        _pendingLogicalQueueSongIds == null &&
            _player.effectiveIndices.length == logicalIds.length
        ? _player.effectiveIndices
        : List<int>.generate(logicalIds.length, (index) => index);
    final decision = _navigationIntent.relative(
      forward: forward,
      confirmedIndex: confirmedIndex,
      confirmedPosition: _player.position,
      effectiveOrder: effectiveOrder,
      // The user's mode: the native loop is off while songs are deferred.
      loopAll: _desiredLoopMode == LoopMode.all,
    );
    final cue = switch (decision.outcome) {
      PlaybackNavigationOutcome.next => TransportVisualIntent.next,
      PlaybackNavigationOutcome.previous => TransportVisualIntent.previous,
      PlaybackNavigationOutcome.restart => TransportVisualIntent.restartCurrent,
      PlaybackNavigationOutcome.unavailableNext =>
        TransportVisualIntent.unavailableNext,
      PlaybackNavigationOutcome.unavailablePrevious =>
        TransportVisualIntent.unavailablePrevious,
    };
    _emitTransportVisualCue(cue, fromSongId: _snapshot.currentSongId);
    if (!decision.canApply) return Future<void>.value();
    _invalidatePendingStartupSelection();
    return _applyNavigationDecision(
      decision,
      logicalIds: logicalIds,
      shouldPlay: _latestExplicitTransportPlaying ?? _player.playing,
      context: forward ? 'skip next' : 'skip previous',
    );
  }

  Future<void> _applyNavigationDecision(
    PlaybackNavigationDecision decision, {
    required List<String> logicalIds,
    required bool shouldPlay,
    required String context,
  }) {
    final requestedIndex = decision.index!;
    final targetId = logicalIds[requestedIndex];
    if (_navigationInFlightRevision != null) {
      _navigationSupersededCount++;
    }
    _navigationInFlightRevision = decision.revision;
    _navigationIssuedAt = DateTime.now();
    final transportGeneration = _supersedeTransportIntent(
      shouldPlay: shouldPlay,
    );
    final generation = _supersedeQueueWork(
      isLoading: true,
      loadingSongId: targetId,
      pendingLogicalQueueSongIds: _pendingLogicalQueueSongIds,
      navigation: true,
    );
    final pendingSongs = _pendingLogicalQueueSongs;
    final work = _queueLane.navigate((token) async {
      var index = requestedIndex;
      var selectionConfirmed = false;
      var rebuiltPendingQueue = false;
      int? preparedTargetIndex;
      void confirmSelection() {
        if (selectionConfirmed ||
            !_isActiveLoadGeneration(generation) ||
            !_navigationIntent.isCurrent(decision.revision)) {
          return;
        }
        selectionConfirmed = true;
        _navigationIntent.confirm(decision.revision);
        _navigationCompletedCount++;
        _scheduleTransportPersistence(context: context);
        _emitSnapshot();
      }

      try {
        await _ready;
        _checkQueueWorkCurrent(token, generation);
        _cancelCrossfade();
        _clearQueueReplacementMetadataAnchor();

        List<SongsTableData>? rebuildSongs;
        if (_pendingLogicalQueueSongIds != null) {
          rebuildSongs =
              pendingSongs ?? await _libraryDao.getSongsByIds(logicalIds);
          _checkQueueWorkCurrent(token, generation);
          if (rebuildSongs.length != logicalIds.length) {
            throw StateError('A queued song is no longer available.');
          }
        } else {
          // Queue edits that ran after this decision may have moved the song.
          index = _locateQueueTarget(targetId, requestedIndex);
          if (index < 0) {
            throw StateError('The selected song is no longer queued.');
          }
          if (index >= _queueItems.length) {
            final offset = index - _queueItems.length;
            if (offset < _queueWindow.nearJump) {
              // Near the materialised end: release through the target and
              // seek, as for any queued song.
              final before = _queueItems.length;
              final released = await _releaseTail(
                count: offset + 1 + _queueWindow.ahead,
              );
              _checkQueueWorkCurrent(token, generation);
              final landed = released.skip(offset).nonNulls.firstOrNull;
              if (landed == null) {
                throw StateError('The selected song is no longer available.');
              }
              index = before + landed;
            } else {
              // Far into the tail: rebuild the player around the target.
              final entries = _logicalQueueEntries();
              final rows = await _rowsForDeferredEntries(entries);
              _checkQueueWorkCurrent(token, generation);
              final songs = <SongsTableData>[];
              final missing = <String>[];
              var jumpIndex = -1;
              for (var i = 0; i < rows.length; i++) {
                final row = rows[i];
                if (row == null) {
                  missing.add(entries[i].id);
                  continue;
                }
                if (i == index) jumpIndex = songs.length;
                songs.add(row);
              }
              if (jumpIndex < 0) {
                throw StateError('The selected song is no longer available.');
              }
              _reportDroppedSongs(missing, QueueDropReason.rebuild);
              rebuildSongs = songs;
              index = jumpIndex;
              _pendingLogicalQueueSongIds = List<String>.unmodifiable(
                songs.map((song) => song.id),
              );
              _emitSnapshot();
            }
          }
        }

        if (rebuildSongs != null) {
          rebuiltPendingQueue = true;
          final songs = rebuildSongs;
          final rebuildIds = songs
              .map((song) => song.id)
              .toList(growable: false);
          final startItem = await _replaceQueuePhase1(
            songs: songs,
            startIndex: index,
            autoPlay: false,
            persist: false,
            generation: generation,
            token: token,
          );
          _checkQueueWorkCurrent(token, generation);
          if (shouldPlay && _isCurrentTransportIntent(transportGeneration)) {
            unawaited(_player.play());
          }
          final preparedMetadata = _resolveCurrentQueueMetadata();
          if (preparedMetadata.currentIndex == index &&
              preparedMetadata.mediaItem?.id == rebuildIds[index]) {
            confirmSelection();
          }
          await _persistLogicalQueue(
            rebuildIds,
            index,
            generation: generation,
          );
          if (startItem != null && songs.length > 1) {
            await _replaceQueuePhase2(
              songs: songs,
              startIndex: index,
              startItem: startItem,
              persist: true,
              token: token,
              generation: generation,
              deferTail: _shouldDeferTail(songs.length),
            );
          }
          preparedTargetIndex = _queueItems.indexWhere(
            (item) => identical(item, startItem?.mediaItem),
          );
        } else {
          if (_player.processingState != ProcessingState.loading) {
            await _runTimedPlayerOperation(
              generation: generation,
              operation: 'manual queue navigation',
              action: () => _player.seek(Duration.zero, index: index),
              songId: targetId,
              timeout: _playerControlTimeout,
            );
          }
          _checkQueueWorkCurrent(token, generation);
          // just_audio ignores seek while loading. Reload the complete source
          // list at the desired index rather than accepting that no-op as
          // success; `audioSource` alone is only the first playlist child.
          if (_player.processingState == ProcessingState.loading ||
              _player.currentIndex != index) {
            final sources = List<AudioSource>.of(_player.audioSources);
            if (sources.isEmpty || index >= sources.length) {
              throw StateError(
                'Playback source is unavailable for navigation.',
              );
            }
            await _runTimedPlayerOperation(
              generation: generation,
              operation: 'manual navigation stop loading',
              action: _player.stop,
              songId: targetId,
              timeout: _playerResetTimeout,
            );
            _checkQueueWorkCurrent(token, generation);
            await _runTimedPlayerOperation(
              generation: generation,
              operation: 'manual navigation reload',
              action: () => _player.setAudioSources(
                sources,
                preload: true,
                initialIndex: index,
                initialPosition: Duration.zero,
              ),
              songId: targetId,
            );
          }
        }

        _checkQueueWorkCurrent(token, generation);
        final confirmedMetadata = _resolveCurrentQueueMetadata();
        if (rebuiltPendingQueue
            ? preparedTargetIndex == null ||
                  preparedTargetIndex < 0 ||
                  confirmedMetadata.currentIndex != preparedTargetIndex ||
                  confirmedMetadata.mediaItem?.id !=
                      rebuildSongs?.elementAtOrNull(index)?.id
            : _player.currentIndex != index) {
          throw StateError('Player did not confirm the requested queue entry.');
        }
        if (!_navigationIntent.isCurrent(decision.revision)) {
          return;
        }
        if (shouldPlay &&
            _isCurrentTransportIntent(transportGeneration) &&
            !_player.playing) {
          unawaited(_player.play());
        }
        confirmSelection();
        _completeQueueLoad(generation);
      } on OperationCancelledException {
        // A later command already owns the desired target.
      } on PlaybackLoadTimeoutException {
        if (!_isActiveLoadGeneration(generation)) return;
        _navigationTimeoutCount++;
        _navigationIntent.confirm(decision.revision);
        _completeQueueLoad(
          generation,
          loadingSongId: targetId,
          failed: true,
        );
        // The timed-out player was retired, so it cannot keep playing the
        // selected song. Rebuild the logical queue at the next playable entry
        // instead of leaving a full-looking queue backed by an idle player.
        final nextIndex = _nextPlayableIndexAfterFailure(
          requestedIndex,
          logicalIds.length,
        );
        if (nextIndex != null) {
          final resumePlaying = _latestExplicitTransportPlaying ?? shouldPlay;
          final recovery = pendingSongs == null
              ? replaceQueue(
                  logicalIds,
                  startIndex: nextIndex,
                  autoPlay: resumePlaying,
                  expandMatchFlows: false,
                )
              : replaceQueueWithData(
                  pendingSongs,
                  startIndex: nextIndex,
                  autoPlay: resumePlaying,
                  expandMatchFlows: false,
                );
          unawaited(
            recovery.catchError((Object error, StackTrace stack) {
              AppLogger.warning('Navigation fallback failed: $error');
            }),
          );
        }
      } on Object catch (error, stackTrace) {
        if (!_isActiveLoadGeneration(generation)) return;
        _navigationIntent.confirm(decision.revision);
        _completeQueueLoad(
          generation,
          loadingSongId: targetId,
          failed: true,
        );
        _emitLoadFailure(
          operation: context,
          message: 'Could not change to the selected track.',
          songId: targetId,
        );
        AppLogger.warning('Manual navigation failed: $error\n$stackTrace');
      } finally {
        if (_navigationInFlightRevision == decision.revision) {
          _navigationInFlightRevision = null;
        }
      }
    });
    // Intent was admitted synchronously above. Awaiting queue fill here would
    // make every button press wait for unrelated playlist insertion work.
    unawaited(work);
    return Future<void>.value();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    await _ready;
    final enabled = shuffleMode == AudioServiceShuffleMode.all;
    await _enqueueQueueEdit((_) async {
      // Native shuffle orders only what the player holds, so a deferred tail
      // is released first; shuffled queues then stay fully materialised.
      if (enabled) {
        try {
          while (_deferredTail.isNotEmpty) {
            await _releaseTail(count: _queueFillBatchSizeLimit);
          }
        } on PlaybackSourceTemporarilyUnavailableException {
          // Unplayable-for-now songs stay deferred and join the shuffled
          // player once a later release can resolve them.
        }
      }
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
    });
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
    _desiredLoopMode = loopMode;
    await _syncNativeLoopMode();
    await _persistSafely(
      () => _persistQueueState(includePosition: false),
      context: 'set repeat mode',
    );
    _broadcastPlaybackState();
    _emitSnapshot();
  }

  PlaybackAdjustments _appliedAdjustments = const PlaybackAdjustments();
  EqConfiguration _desiredEqualizer = EqConfiguration.flat();
  Future<void> _equalizerLane = Future<void>.value();
  final _equalizerController = BehaviorSubject<EqApplicationState>.seeded(
    EqApplicationState(
      desired: EqConfiguration.flat(),
      applied: EqConfiguration.flat(),
    ),
  );

  @override
  EqCapabilities get equalizerCapabilities {
    if (!_equalizerPipelineEnabled) return EqCapabilities.unavailable;
    return _injectedEqualizerCapabilities ??
        ((_isAndroidRuntime ||
                (Platform.isLinux && JustAudioMediaKit.isRegistered))
            ? EqCapabilities.available
            : EqCapabilities.unavailable);
  }

  @override
  EqApplicationState get equalizerState => _equalizerController.value;

  @override
  Stream<EqApplicationState> get equalizerStateStream =>
      _equalizerController.stream;

  EqualizerConfigurationMessage _equalizerMessage(EqConfiguration values) =>
      EqualizerConfigurationMessage(
        enabled: values.enabled,
        preampDb: values.preampDb,
        autoHeadroom: values.autoHeadroom,
        filters: values.filters
            .map(
              (filter) => EqualizerFilterMessage(
                type: filter.type.name,
                frequencyHz: filter.frequencyHz,
                gainDb: filter.gainDb,
                q: filter.q,
                enabled: filter.enabled,
              ),
            )
            .toList(),
      );

  void _emitEqualizerState(EqualizerStateMessage native) {
    if (_equalizerController.isClosed) return;
    _equalizerController.add(
      EqApplicationState(
        desired: _desiredEqualizer,
        applied: _desiredEqualizer.copyWith(enabled: native.enabled),
        sampleRate: native.sampleRate,
        responseSampleRate: native.responseSampleRate ?? native.sampleRate,
        headroomDb: native.headroomDb,
        reason: native.reason,
        pending: native.pending,
      ),
    );
  }

  Future<void> _setEqualizer(EqConfiguration values) {
    final work = _equalizerLane.then((_) async {
      if (!values.isValid || !equalizerCapabilities.supported) {
        throw ArgumentError('Unsupported equalizer configuration');
      }
      final previous = _desiredEqualizer;
      final message = _equalizerMessage(values);
      try {
        AudioPlayer active;
        AudioPlayer? inactive;
        EqualizerStateMessage native;
        do {
          active = _player;
          inactive = _crossfadePlayer;
          native = await active.setEqualizer(message);
          if (inactive != null) await inactive.setEqualizer(message);
        } while (!identical(active, _player) ||
            !identical(inactive, _crossfadePlayer));
        _desiredEqualizer = values;
        _emitEqualizerState(native);
      } on Object {
        try {
          await _player.setEqualizer(_equalizerMessage(previous));
          await _crossfadePlayer?.setEqualizer(_equalizerMessage(previous));
        } on Object catch (rollbackError, stackTrace) {
          AppLogger.warning('EQ rollback failed: $rollbackError\n$stackTrace');
          _emitEqualizerState(
            const EqualizerStateMessage(
              enabled: false,
              reason: 'EQ could not be restored after an audio-engine error. Review playback settings.',
            ),
          );
        }
        rethrow;
      }
    });
    _equalizerLane = work.catchError((Object _) {});
    return work;
  }

  @override
  Future<void> setEqualizer(EqConfiguration values) async {
    await _ready;
    await _setEqualizer(values);
  }

  @override
  Future<void> refreshEqualizerState() async {
    if (!equalizerCapabilities.supported) return;
    await _equalizerLane;
    _emitEqualizerState(await _player.getEqualizerState());
  }

  Future<void> _adjustmentLane = Future<void>.value();
  final _adjustmentController = BehaviorSubject<PlaybackAdjustments>.seeded(
    const PlaybackAdjustments(),
  );

  @override
  Stream<PlaybackAdjustments> get playbackAdjustmentsStream =>
      _adjustmentController.stream;

  @override
  PlaybackAdjustments get playbackAdjustments => _appliedAdjustments;

  @override
  PlaybackAdjustmentCapabilities get playbackAdjustmentCapabilities {
    if (_adjustmentCapabilities != null) return _adjustmentCapabilities;
    if (JustAudioMediaKit.isRegistered && JustAudioMediaKit.pitch) {
      return PlaybackAdjustmentCapabilities.mediaKit;
    }
    if (_isAndroidRuntime) return PlaybackAdjustmentCapabilities.android;
    return const PlaybackAdjustmentCapabilities();
  }

  Future<void> _applyAdjustmentsToPlayer(
    AudioPlayer player,
    PlaybackAdjustments values,
  ) async {
    // Issued together so the desktop backend can apply both with one audio
    // filter rebuild; every failure is still observed.
    await Future.wait(<Future<void>>[
      player.setSpeed(values.speed),
      if (playbackAdjustmentCapabilities.pitchSupported)
        player.setPitch(values.pitchFactor),
    ]);
  }

  Future<void> _setPlaybackAdjustments(
    PlaybackAdjustments requested, {
    double? speed,
  }) {
    final operation = _adjustmentLane.then((_) async {
      final values = speed == null
          ? requested
          : _appliedAdjustments.copyWith(speed: speed);
      if (!playbackAdjustmentCapabilities.supports(values)) {
        throw ArgumentError('Unsupported speed/pitch adjustment');
      }
      final previous = _appliedAdjustments;
      try {
        AudioPlayer active;
        AudioPlayer? inactive;
        do {
          active = _player;
          inactive = _crossfadePlayer;
          await _applyAdjustmentsToPlayer(active, values);
          if (inactive != null)
            await _applyAdjustmentsToPlayer(inactive, values);
        } while (!identical(active, _player) ||
            !identical(inactive, _crossfadePlayer));
        _appliedAdjustments = values;
        if (!_adjustmentController.isClosed) _adjustmentController.add(values);
        _broadcastPlaybackState();
      } on Object {
        // A pair may fail halfway through, so restore both decks before
        // reporting failure to the shared controls.
        try {
          await _applyAdjustmentsToPlayer(_player, previous);
          final inactive = _crossfadePlayer;
          if (inactive != null)
            await _applyAdjustmentsToPlayer(inactive, previous);
        } on Object catch (error, stackTrace) {
          AppLogger.warning(
            'Playback adjustment rollback failed: $error\n$stackTrace',
          );
        }
        rethrow;
      }
    });
    _adjustmentLane = operation.catchError((Object _) {});
    return operation;
  }

  @override
  Future<void> setPlaybackAdjustments(PlaybackAdjustments values) async {
    await _ready;
    await _setPlaybackAdjustments(values);
  }

  @override
  Future<void> setSpeed(double speed) => setPlaybackSpeed(speed);

  @override
  Future<void> setPlaybackSpeed(double speed) async {
    await _ready;
    await _setPlaybackAdjustments(_appliedAdjustments, speed: speed);
  }

  @override
  Future<void> setVolume(double volume) async {
    await _ready;
    _userVolume = volume.clamp(0.0, 1.0);
    await _player.setVolume(_userVolume);
  }

  @override
  Future<void> stop() async {
    _invalidatePendingStartupSelection();
    final transportGeneration = _supersedeTransportIntent(shouldPlay: false);
    await _ready;
    if (!_isCurrentTransportIntent(transportGeneration)) return;
    _cancelCrossfade();
    await _player.pause();
    final inactiveDeck = _crossfadePlayer;
    if (inactiveDeck != null) {
      await inactiveDeck.pause();
      await _setVolumeIfChanged(inactiveDeck, 0);
    }
    _broadcastPlaybackState();
    _emitSnapshot();
    _scheduleTransportPersistence(context: 'stop');
  }

  Future<void> _persistSafely(
    Future<void> Function() persistOperation, {
    required String context,
  }) {
    // Queue replacement and delayed position saves may be issued from
    // different lanes. Commit them in issue order so an older asynchronous
    // write cannot land after a newer queue/current-index snapshot.
    final queued = Stopwatch()..start();
    final write = _persistTail.then((_) async {
      final waitedMs = queued.elapsedMilliseconds;
      final running = Stopwatch()..start();
      await navisPersistSafely(
        persistOperation,
        context: context,
        logWarning: AppLogger.warning,
      );
      final ranMs = running.elapsedMilliseconds;
      _persistOperationCount++;
      _persistRunMs += ranMs;
      _persistContextCounts[context] =
          (_persistContextCounts[context] ?? 0) + 1;
      if (ranMs >= 500) {
        _slowPersistence.add(<String, Object?>{
          'context': context,
          'waitedMs': waitedMs,
          'ranMs': ranMs,
        });
        if (_slowPersistence.length > 8) _slowPersistence.removeAt(0);
      }
    });
    _persistTail = write.catchError((Object error, StackTrace stackTrace) {
      AppLogger.warning('Playback persistence lane failed: $error');
    });
    return write;
  }

  Future<void> _persistPosition() {
    return _persistQueueState();
  }

  Future<void> _persistLogicalQueue(
    List<String> songIds,
    int index, {
    required int generation,
  }) {
    final immutableIds = List<String>.unmodifiable(songIds);
    final repeatMode = switch (_desiredLoopMode) {
      LoopMode.one => schema.RepeatMode.one,
      LoopMode.all => schema.RepeatMode.all,
      LoopMode.off => schema.RepeatMode.off,
    };
    final shuffleMode = _player.shuffleModeEnabled
        ? schema.ShuffleMode.all
        : schema.ShuffleMode.off;
    final positionMs = _player.position.inMilliseconds;
    return _persistSafely(() async {
      if (!_isActiveLoadGeneration(generation)) return;
      await _playQueueDao.saveQueue(
        currentIndex: index,
        songIds: immutableIds,
        shuffleMode: shuffleMode,
        repeatMode: repeatMode,
        positionMs: positionMs,
      );
    }, context: 'logical queue selection');
  }

  void _scheduleQueueItemsPersistence({required String context}) {
    _queueItemsPersistTimer?.cancel();
    _queueItemsPersistContext = context;
    // Coalesce bursts, but never postpone a save by more than two seconds.
    final firstPending = _queueItemsPersistFirstScheduledAt ??= DateTime.now();
    final waited = DateTime.now().difference(firstPending);
    const settle = Duration(milliseconds: 300);
    const maxWait = Duration(seconds: 2);
    _queueItemsPersistTimer = Timer(
      waited + settle > maxWait
          ? (maxWait - waited).isNegative
                ? Duration.zero
                : maxWait - waited
          : settle,
      () => unawaited(_flushQueueItemsPersistence()),
    );
  }

  /// Writes any coalesced queue save now and waits for the persistence lane.
  @visibleForTesting
  Future<void> debugFlushQueuePersistence() async {
    await _flushQueueItemsPersistence();
    await _persistTail;
  }

  /// Writes a scheduled full-queue persistence now, if one is pending.
  Future<void> _flushQueueItemsPersistence() async {
    final context = _queueItemsPersistContext;
    _queueItemsPersistTimer?.cancel();
    _queueItemsPersistTimer = null;
    _queueItemsPersistContext = null;
    _queueItemsPersistFirstScheduledAt = null;
    if (context == null) return;
    await _persistSafely(
      () => _persistQueueState(includeQueueItems: true),
      context: context,
    );
  }

  void _scheduleTransportPersistence({required String context}) {
    _transportPersistTimer?.cancel();
    _transportPersistTimer = Timer(const Duration(milliseconds: 250), () {
      _transportPersistTimer = null;
      unawaited(_persistSafely(_persistPosition, context: context));
    });
  }

  @override
  Future<void> applySongIdentityAliases(Map<String, String> aliases) {
    final normalized = <String, String>{
      for (final entry in aliases.entries)
        if (entry.key.trim().isNotEmpty &&
            entry.value.trim().isNotEmpty &&
            entry.key != entry.value)
          entry.key: entry.value,
    };
    if (normalized.isEmpty) {
      return Future<void>.value();
    }
    return _enqueueQueueEdit((_) async {
      for (final entry in normalized.entries) {
        _songIdentityAliases[entry.key] = _canonicalSongId(entry.value);
      }
      for (final key in _songIdentityAliases.keys.toList(growable: false)) {
        _songIdentityAliases[key] = _canonicalSongId(
          _songIdentityAliases[key]!,
        );
      }

      MediaItem remap(MediaItem item) {
        final canonicalId = _canonicalSongId(item.id);
        return canonicalId == item.id ? item : item.copyWith(id: canonicalId);
      }

      for (var index = 0; index < _queueItems.length; index++) {
        _queueItems[index] = remap(_queueItems[index]);
      }
      for (var index = 0; index < _deferredTail.length; index++) {
        final entry = _deferredTail[index];
        // A remote row keeps its own id and source.
        if (entry.song != null) continue;
        final canonicalId = _canonicalSongId(entry.id);
        if (canonicalId != entry.id) {
          _deferredTail[index] = _DeferredQueueEntry(canonicalId);
        }
      }
      final pending = _pendingLogicalQueueSongIds;
      if (pending != null) {
        _pendingLogicalQueueSongIds = List<String>.unmodifiable(
          pending.map(_canonicalSongId),
        );
      }
      if (_currentMediaItem != null) {
        _setCurrentMediaItem(remap(_currentMediaItem!));
      }
      queue.add(List<MediaItem>.unmodifiable(_queueItems));
      _emitSnapshot();
      await _persistSafely(
        () => _persistQueueState(includeQueueItems: true),
        context: 'song identity alias update',
      );
    });
  }

  String _canonicalSongId(String songId) {
    var current = songId;
    final visited = <String>{};
    while (visited.add(current)) {
      final next = _songIdentityAliases[current];
      if (next == null || next == current) {
        return current;
      }
      current = next;
    }
    return current;
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

    final repeatMode = switch (_desiredLoopMode) {
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
    final resolvedCurrentIndex = _radioStation == null
        ? _resolveCurrentQueueMetadata().currentIndex
        : null;

    if (includeQueueItems) {
      await _playQueueDao.saveQueue(
        currentIndex: resolvedCurrentIndex,
        songIds: _logicalQueueIds,
        shuffleMode: shuffleMode,
        repeatMode: repeatMode,
        positionMs: positionMs,
      );
      return;
    }

    await _playQueueDao.savePlaybackState(
      currentIndex: resolvedCurrentIndex,
      shuffleMode: shuffleMode,
      repeatMode: repeatMode,
      positionMs: positionMs,
    );
  }

  void _broadcastPlaybackState() {
    final processingState = _mapProcessingState(_player.processingState);
    final resolved = _resolveCurrentQueueMetadata();
    final currentItem = resolved.mediaItem;
    final currentIndex = resolved.currentIndex;
    final effectiveDuration = _effectivePlaybackDuration(currentItem);
    final capabilities = navisOsControlCapabilities(
      queueLength: _radioStation == null ? _logicalQueueIds.length : 0,
      currentIndex: _radioStation == null ? currentIndex : null,
      isRadioMode: _radioStation != null,
      duration: effectiveDuration,
      processingState: processingState,
      playing: _player.playing,
    );
    final controls = navisNotificationControls(
      isPlaying: _player.playing,
      capabilities: capabilities,
    );
    final state = playbackState.value.copyWith(
      controls: controls,
      systemActions: navisSystemActionsForCapabilities(capabilities),
      androidCompactActionIndices:
          navisNotificationCompactActionIndicesForControls(controls),
      processingState: processingState,
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _radioStation == null ? currentIndex : null,
      repeatMode: _mapRepeatMode(_desiredLoopMode),
      shuffleMode: _player.shuffleModeEnabled
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
    );
    playbackState.add(state);
  }

  Future<void> _notifyAndroidAutoBrowseRefresh() async {
    _androidAutoBrowseNotifier.notifyParentsChanged();
    AppLogger.info('Android Auto browse roots refresh requested.');
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

    final resolved = _resolveCurrentQueueMetadata();
    final currentItem = resolved.mediaItem;
    _updateScrobbleSession(currentItem, currentIndex: resolved.currentIndex);

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
          track: _scrobblePayloadFor(currentItem),
        ),
      );

      // Record in local play history as soon as the track starts playing
      // so it appears in "Recently Played" without waiting for the full
      // scrobble submission threshold.
      unawaited(_recordPlayHistory(songId));
    }

    if (_sentSubmissionScrobble) {
      return;
    }

    final duration = _effectivePlaybackDuration(currentItem);
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
        track: _scrobblePayloadFor(currentItem),
      ),
    );
  }

  ScrobbleTrackPayload? _scrobblePayloadFor(MediaItem? item) {
    if (item == null) {
      return null;
    }
    return ScrobbleTrackPayload(
      songId: item.id,
      title: item.title,
      artist: item.artist,
      album: item.album,
      duration: item.duration,
    );
  }

  Future<void> _recordPlayHistory(String songId) async {
    try {
      await _historyDao.addPlayHistory(songId);
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Failed to record play history',
        error,
        stackTrace,
      );
    }
  }

  void _updateScrobbleSession(MediaItem? currentItem, {int? currentIndex}) {
    final songId = currentItem?.id;
    // The same play continues when only the queue around it changed (songs
    // inserted, released or moved before it shift its index; the queue entry
    // is the same object) or when its metadata was refreshed in place (for
    // example its liked state; the index is unchanged). Keying the session
    // on the index alone restarted it on every shift, recording duplicate
    // play history and scrobbles.
    if (songId != null &&
        songId == _activeScrobbleSongId &&
        (identical(currentItem, _activeScrobbleItem) ||
            currentIndex == _activeScrobbleIndex)) {
      _activeScrobbleItem = currentItem;
      _activeScrobbleIndex = currentIndex;
      return;
    }

    if (songId == null) {
      _activeScrobbleItem = null;
      _activeScrobbleIndex = null;
      _activeScrobbleSongId = null;
      _activeScrobbleSessionKey = null;
      _sentNowPlayingScrobble = false;
      _sentSubmissionScrobble = false;
      return;
    }

    _activeScrobbleItem = currentItem;
    _activeScrobbleIndex = currentIndex;
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
    final resolved = _resolveCurrentQueueMetadata();
    final currentItem = resolved.mediaItem;
    final isLiked = currentItem?.extras?['liked'] as bool? ?? false;
    final nextSnapshot = PlaybackSnapshot(
      queueSongIds: _radioStation != null ? const <String>[] : _logicalQueueIds,
      currentSongId: _radioStation != null ? null : currentItem?.id,
      currentIndex: _radioStation != null ? null : resolved.currentIndex,
      playing: _player.playing,
      processingState: _mapProcessingState(_player.processingState),
      position: _player.position,
      duration: _effectivePlaybackDuration(currentItem),
      bufferedPosition: _player.bufferedPosition,
      shuffleMode: _player.shuffleModeEnabled
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
      repeatMode: _mapRepeatMode(_desiredLoopMode),
      isCurrentSongLiked: _radioStation == null && isLiked,
      radioStation: _radioStation,
      isLoading: _isLoading,
      hasPendingLogicalQueue:
          _radioStation == null && _pendingLogicalQueueSongIds != null,
      pendingQueueIndex: _navigationIntent.isPending
          ? _navigationIntent.desiredIndex
          : null,
      loadingSongId: _loadingSongId,
      lastFailedSongId: _lastFailedSongId,
    );
    final shouldBroadcast = !navisPlaybackSnapshotsStructurallyEqual(
      _snapshot,
      nextSnapshot,
    );
    _snapshot = nextSnapshot;
    final startupTrace = _activeStartupTrace;
    if (startupTrace != null &&
        startupTrace.sourceApplied &&
        currentItem?.id == startupTrace.songId &&
        nextSnapshot.processingState == AudioProcessingState.ready) {
      startupTrace.markOnce('playerReady');
    }
    if (!shouldBroadcast) {
      return;
    }
    if (!_snapshotController.isClosed) {
      _snapshotBroadcastCount++;
      _snapshotController.add(_snapshot);
    }
  }

  Duration _effectivePlaybackDuration(MediaItem? currentItem) {
    return resolveEffectivePlaybackDuration(
      isRadioMode: _radioStation != null,
      mediaDuration: currentItem?.duration,
      playerDuration: _player.duration,
    );
  }

  void _emitTransportVisualCue(
    TransportVisualIntent intent, {
    required String? fromSongId,
  }) {
    if (_transportVisualCueController.isClosed) {
      return;
    }
    _transportVisualCueController.add(
      TransportVisualCue(
        token: ++_transportVisualCueToken,
        intent: intent,
        fromSongId: fromSongId,
      ),
    );
  }

  Future<void> _seekWithRecovery(
    Duration position, {
    required OperationToken token,
    required int transportGeneration,
  }) async {
    final autoPlayAfterRecovery = _player.playing;
    final startedAt = DateTime.now().toUtc();
    final beforeBuffered = _player.bufferedPosition;
    final beforePosition = _player.position;
    final beforeSourceKind = _currentSourceKind;
    var path = 'direct';
    // Proactive path: if the seek target clearly exceeds the buffered range on
    // a lock-cached stream, skip the doomed seek and rebuild immediately.
    // This avoids the 200 ms stutter from the reactive path below.
    // Guard: only fire when we have a measured buffer (bufferedPosition > 0)
    // and the target overshoots it by at least 1 s.
    if (_currentSourceKind == PlaybackSourceKind.lockCachedStream.name) {
      final buffered = _player.bufferedPosition;
      if (buffered > Duration.zero &&
          position > buffered + const Duration(seconds: 1)) {
        path = 'proactive_rebuild';
        AppLogger.warning(
          'Seek target $position exceeds buffered position $buffered on a '
          'lock-cached source. Proactively rebuilding with direct streams.',
        );
        await _rebuildQueueForSeekRecovery(
          position,
          autoPlay: autoPlayAfterRecovery,
          token: token,
          transportGeneration: transportGeneration,
        );
        _recordSeekDiagnosticsEvent(<String, Object?>{
          'at': startedAt.toIso8601String(),
          'path': path,
          'requestedPositionMs': position.inMilliseconds,
          'beforePositionMs': beforePosition.inMilliseconds,
          'beforeBufferedMs': beforeBuffered.inMilliseconds,
          'beforeSourceKind': beforeSourceKind,
          'afterPositionMs': _player.position.inMilliseconds,
          'afterBufferedMs': _player.bufferedPosition.inMilliseconds,
          'afterSourceKind': _currentSourceKind,
          'elapsedMs': DateTime.now()
              .toUtc()
              .difference(startedAt)
              .inMilliseconds,
          'lockCachingBypassed': _snapshot.currentSongId == null
              ? false
              : _lockCachingBypassedSongIds.contains(_snapshot.currentSongId!),
        });
        return;
      }
    }

    await _player.seek(position);
    token.checkCancelled();
    if (!_isCurrentTransportIntent(transportGeneration)) {
      return;
    }
    // Local files seek reliably. Remote Subsonic streams (direct or
    // lock-cached) can no-op under libmpv; briefly probe then reload at the
    // requested position when the seek undershoots.
    final sourceKind = _currentSourceKind;
    final isRemoteSource =
        sourceKind == PlaybackSourceKind.lockCachedStream.name ||
        sourceKind == PlaybackSourceKind.directStream.name;
    if (!isRemoteSource) {
      _recordSeekDiagnosticsEvent(<String, Object?>{
        'at': startedAt.toIso8601String(),
        'path': path,
        'requestedPositionMs': position.inMilliseconds,
        'beforePositionMs': beforePosition.inMilliseconds,
        'beforeBufferedMs': beforeBuffered.inMilliseconds,
        'beforeSourceKind': beforeSourceKind,
        'afterPositionMs': _player.position.inMilliseconds,
        'afterBufferedMs': _player.bufferedPosition.inMilliseconds,
        'afterSourceKind': _currentSourceKind,
        'elapsedMs': DateTime.now()
            .toUtc()
            .difference(startedAt)
            .inMilliseconds,
        'lockCachingBypassed': _snapshot.currentSongId == null
            ? false
            : _lockCachingBypassedSongIds.contains(_snapshot.currentSongId!),
      });
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
    token.checkCancelled();
    if (!_isCurrentTransportIntent(transportGeneration)) {
      return;
    }
    final actualPosition = _player.position;
    if (!navisShouldRecoverSeekToDirectStream(
      sourceKind: sourceKind,
      requestedPosition: position,
      actualPosition: actualPosition,
    )) {
      _recordSeekDiagnosticsEvent(<String, Object?>{
        'at': startedAt.toIso8601String(),
        'path': path,
        'requestedPositionMs': position.inMilliseconds,
        'beforePositionMs': beforePosition.inMilliseconds,
        'beforeBufferedMs': beforeBuffered.inMilliseconds,
        'beforeSourceKind': beforeSourceKind,
        'afterPositionMs': actualPosition.inMilliseconds,
        'afterBufferedMs': _player.bufferedPosition.inMilliseconds,
        'afterSourceKind': _currentSourceKind,
        'elapsedMs': DateTime.now()
            .toUtc()
            .difference(startedAt)
            .inMilliseconds,
        'lockCachingBypassed': _snapshot.currentSongId == null
            ? false
            : _lockCachingBypassedSongIds.contains(_snapshot.currentSongId!),
      });
      return;
    }

    // Prefer a completed sidecar/local cache file — those seek without a
    // network round-trip and avoid progressive-stream seek failures.
    if (await _trySeekViaCompletedSidecarFile(
      position,
      autoPlay: autoPlayAfterRecovery,
      token: token,
      transportGeneration: transportGeneration,
    )) {
      path = 'sidecar_file';
      _recordSeekDiagnosticsEvent(<String, Object?>{
        'at': startedAt.toIso8601String(),
        'path': path,
        'requestedPositionMs': position.inMilliseconds,
        'beforePositionMs': beforePosition.inMilliseconds,
        'beforeBufferedMs': beforeBuffered.inMilliseconds,
        'beforeSourceKind': beforeSourceKind,
        'landedPositionMs': actualPosition.inMilliseconds,
        'afterPositionMs': _player.position.inMilliseconds,
        'afterBufferedMs': _player.bufferedPosition.inMilliseconds,
        'afterSourceKind': _currentSourceKind,
        'elapsedMs': DateTime.now()
            .toUtc()
            .difference(startedAt)
            .inMilliseconds,
        'lockCachingBypassed': false,
      });
      return;
    }

    path = 'reactive_rebuild';
    AppLogger.warning(
      'Seek landed at $actualPosition instead of $position on a remote '
      'source. Reloading the active item at the requested position.',
    );
    await _rebuildQueueForSeekRecovery(
      position,
      autoPlay: autoPlayAfterRecovery,
      token: token,
      transportGeneration: transportGeneration,
    );
    _recordSeekDiagnosticsEvent(<String, Object?>{
      'at': startedAt.toIso8601String(),
      'path': path,
      'requestedPositionMs': position.inMilliseconds,
      'beforePositionMs': beforePosition.inMilliseconds,
      'beforeBufferedMs': beforeBuffered.inMilliseconds,
      'beforeSourceKind': beforeSourceKind,
      'landedPositionMs': actualPosition.inMilliseconds,
      'afterPositionMs': _player.position.inMilliseconds,
      'afterBufferedMs': _player.bufferedPosition.inMilliseconds,
      'afterSourceKind': _currentSourceKind,
      'elapsedMs': DateTime.now().toUtc().difference(startedAt).inMilliseconds,
      'lockCachingBypassed': _snapshot.currentSongId == null
          ? false
          : _lockCachingBypassedSongIds.contains(_snapshot.currentSongId!),
    });
  }

  /// Reloads the queue with the current song played from its completed
  /// sidecar file, which seeks without a network round-trip. The whole
  /// logical queue is kept.
  Future<bool> _trySeekViaCompletedSidecarFile(
    Duration position, {
    required bool autoPlay,
    required OperationToken token,
    required int transportGeneration,
  }) async {
    final item = _currentMediaItem;
    if (item == null) {
      return false;
    }
    final sidecarPath = item.extras?['sidecarCacheFilePath'] as String?;
    if (sidecarPath == null || sidecarPath.isEmpty) {
      return false;
    }
    final cacheFile = File(sidecarPath);
    if (!cacheFile.existsSync() || cacheFile.lengthSync() <= 0) {
      return false;
    }
    final song = _sidecarSongsById[item.id];
    if (song == null) {
      return false;
    }
    final extras = item.extras ?? const <String, Object?>{};
    final source = ResolvedPlaybackSource.file(
      songId: song.id,
      uri: Uri.file(cacheFile.path),
      cachedFilePath: cacheFile.path,
      metadata: ResolvedPlaybackMetadata(
        format: extras['resolvedFormat'] as String?,
        bitRate: extras['resolvedBitRate'] as int?,
        sampleRate: extras['resolvedSampleRate'] as int?,
        isTranscoded: extras['transcodingApplied'] as bool? ?? false,
      ),
    );
    final mediaItem = item.copyWith(
      extras: <String, Object?>{
        ...extras,
        'sourceKind': PlaybackSourceKind.file.name,
        'localSource': true,
        'cachedFilePath': cacheFile.path,
      },
    );
    try {
      return await _rebuildQueueForSeekRecovery(
        position,
        autoPlay: autoPlay,
        token: token,
        transportGeneration: transportGeneration,
        preparedStart: _PreparedQueueItem(
          song: song,
          source: source,
          mediaItem: mediaItem,
          audioSource: source.asAudioSource(tag: mediaItem),
        ),
      );
    } on OperationCancelledException {
      rethrow;
    } on Object catch (error, stackTrace) {
      AppLogger.debug(
        'Sidecar file seek fallback failed for ${song.id}: '
        '$error\n$stackTrace',
      );
      return false;
    }
  }

  /// Reloads the whole logical queue at the current song and [position],
  /// with the current song from [preparedStart] when given. Returns whether
  /// the player was rebuilt.
  Future<bool> _rebuildQueueForSeekRecovery(
    Duration position, {
    required bool autoPlay,
    required OperationToken token,
    required int transportGeneration,
    String reason = 'seek recovery — switched to direct stream',
    _PreparedQueueItem? preparedStart,
  }) async {
    final currentIndex = _resolveCurrentQueueMetadata().currentIndex;
    if (currentIndex == null ||
        currentIndex < 0 ||
        currentIndex >= _queueItems.length) {
      return false;
    }

    // The logical queue, so a deferred tail survives the rebuild.
    final queueSongIds = _logicalQueueIds;
    if (queueSongIds.isEmpty) {
      return false;
    }

    final orderedSongs = (await _rowsForDeferredEntries(
      _logicalQueueEntries(),
    )).nonNulls.toList(growable: false);
    if (orderedSongs.length != queueSongIds.length) {
      AppLogger.warning(
        'Seek recovery could not rebuild the full queue from the local songs '
        'table. Skipping direct-stream fallback.',
      );
      return false;
    }

    final previousShuffleModeEnabled = _player.shuffleModeEnabled;

    // Prefer a one-shot direct-stream rebuild for this seek. Do not permanently
    // bypass lock-caching for the song: desktop now uses sidecar caching with
    // native HTTPS seeks, and mobile lock-cache can still serve later plays.
    final currentSongId = _queueItems[currentIndex].id;

    token.checkCancelled();
    if (!_isCurrentTransportIntent(transportGeneration)) {
      return false;
    }
    final queueGeneration = _supersedeQueueWork(
      isLoading: true,
      loadingSongId: currentSongId,
      pendingLogicalQueueSongIds: queueSongIds.length > 1 ? queueSongIds : null,
    );
    _PreparedQueueItem? startItem;
    try {
      await _queueLane.run((queueToken) async {
        _checkQueueWorkCurrent(queueToken, queueGeneration);
        startItem = await _replaceQueuePhase1(
          songs: orderedSongs,
          startIndex: currentIndex,
          autoPlay: false,
          persist: false,
          generation: queueGeneration,
          token: queueToken,
          initialPosition: position,
          preferLockCaching: false,
          preparedStart: preparedStart,
        );
      });
    } on Object {
      _completeQueueLoad(
        queueGeneration,
        loadingSongId: currentSongId,
        failed: true,
      );
      rethrow;
    }
    token.checkCancelled();
    if (!_isCurrentTransportIntent(transportGeneration)) {
      return true;
    }
    await _syncNativeLoopMode();
    await _player.setShuffleModeEnabled(previousShuffleModeEnabled);
    // media_kit can drop initialPosition; correct before resuming playback.
    final landed = _player.position;
    if ((position - landed).abs() >= const Duration(seconds: 2)) {
      await _player.seek(position);
      token.checkCancelled();
      if (!_isCurrentTransportIntent(transportGeneration)) {
        return true;
      }
    }
    if (autoPlay) {
      unawaited(_player.play());
    }
    final recoveredStartItem = startItem;
    if (recoveredStartItem == null || orderedSongs.length <= 1) {
      _completeQueueLoad(queueGeneration);
      return true;
    }
    unawaited(
      _queueLane.run((queueToken) async {
        try {
          _checkQueueWorkCurrent(queueToken, queueGeneration);
          await _replaceQueuePhase2(
            songs: orderedSongs,
            startIndex: currentIndex,
            startItem: recoveredStartItem,
            persist: true,
            token: queueToken,
            generation: queueGeneration,
            deferTail: _shouldDeferTail(orderedSongs.length),
          );
          _completeQueueLoad(queueGeneration);
        } on OperationCancelledException {
          AppLogger.debug(
            'Seek recovery queue fill cancelled by a newer command.',
          );
        } on Object catch (error, stackTrace) {
          _completeQueueLoad(
            queueGeneration,
            loadingSongId: currentSongId,
            failed: true,
          );
          AppLogger.warning(
            'Seek recovery queue fill failed for song=$currentSongId. '
            '$error\n$stackTrace',
          );
        }
      }),
    );
    return true;
  }

  void _syncRemotePlaybackStallWatchdog() {
    if (_radioStation != null || _queueItems.isEmpty) {
      _cancelRemotePlaybackStallWatchdog();
      return;
    }

    final currentSongId = _resolveCurrentQueueMetadata().mediaItem?.id;
    final shouldWatch = navisShouldWatchRemotePlaybackForStall(
      sourceKind: _currentSourceKind,
      processingState: _mapProcessingState(_player.processingState),
    );
    if (!shouldWatch || currentSongId == null) {
      _cancelRemotePlaybackStallWatchdog();
      return;
    }

    final position = _player.position;
    final bufferedPosition = _player.bufferedPosition;
    final hasProgressed =
        _remotePlaybackStallSongId != currentSongId ||
        _remotePlaybackStallPosition != position ||
        _remotePlaybackStallBufferedPosition != bufferedPosition;
    if (!hasProgressed && _remotePlaybackStallTimer != null) {
      return;
    }

    _cancelRemotePlaybackStallWatchdog();
    _remotePlaybackStallSongId = currentSongId;
    _remotePlaybackStallPosition = position;
    _remotePlaybackStallBufferedPosition = bufferedPosition;
    _remotePlaybackStallTimer = Timer(_remotePlaybackStallTimeout, () {
      unawaited(
        _recoverCurrentSongFromRemotePlaybackFailure(
          reason: 'remote playback stalled',
        ),
      );
    });
  }

  void _cancelRemotePlaybackStallWatchdog() {
    _remotePlaybackStallTimer?.cancel();
    _remotePlaybackStallTimer = null;
    _remotePlaybackStallSongId = null;
    _remotePlaybackStallPosition = null;
    _remotePlaybackStallBufferedPosition = null;
  }

  void _scheduleSeekBufferingRecovery({
    required Duration requestedPosition,
    required int transportGeneration,
  }) {
    _cancelSeekBufferingRecovery();
    final songId = _resolveCurrentQueueMetadata().mediaItem?.id;
    if (songId == null ||
        !navisShouldWatchRemotePlaybackForStall(
          sourceKind: _currentSourceKind,
          processingState: _mapProcessingState(_player.processingState),
        )) {
      return;
    }
    _seekBufferingRecoveryTimer = Timer(_seekBufferingRecoveryTimeout, () {
      if (!navisShouldRecoverBufferedSeek(
        sourceKind: _currentSourceKind,
        processingState: _mapProcessingState(_player.processingState),
        requestedPosition: requestedPosition,
        actualPosition: _player.position,
        isCurrentTransportIntent: _isCurrentTransportIntent(
          transportGeneration,
        ),
        isCurrentSong: _resolveCurrentQueueMetadata().mediaItem?.id == songId,
      )) {
        return;
      }
      unawaited(
        _recoverCurrentSongFromRemotePlaybackFailure(
          reason: 'seek remained buffering',
          intendedPosition: requestedPosition,
          expectedSongId: songId,
          expectedTransportGeneration: transportGeneration,
        ),
      );
    });
  }

  void _cancelSeekBufferingRecovery() {
    _seekBufferingRecoveryTimer?.cancel();
    _seekBufferingRecoveryTimer = null;
  }

  Future<void> _recoverCurrentSongFromRemotePlaybackFailure({
    required String reason,
    Object? error,
    StackTrace? stackTrace,
    Duration? intendedPosition,
    String? expectedSongId,
    int? expectedTransportGeneration,
  }) async {
    if (_remotePlaybackRecoveryInProgress || _radioStation != null) {
      return;
    }
    final sourceKind = _currentSourceKind;
    final currentIndex = _resolveCurrentQueueMetadata().currentIndex;
    if (currentIndex == null ||
        currentIndex < 0 ||
        currentIndex >= _queueItems.length ||
        (sourceKind != PlaybackSourceKind.lockCachedStream.name &&
            sourceKind != PlaybackSourceKind.directStream.name)) {
      return;
    }

    if (expectedTransportGeneration != null &&
        !_isCurrentTransportIntent(expectedTransportGeneration)) {
      return;
    }

    _remotePlaybackRecoveryInProgress = true;
    _cancelRemotePlaybackStallWatchdog();
    _cancelSeekBufferingRecovery();
    final songId = _queueItems[currentIndex].id;
    if (expectedSongId != null && songId != expectedSongId) {
      _remotePlaybackRecoveryInProgress = false;
      return;
    }
    final autoPlay = _player.playing;
    final position = intendedPosition ?? _player.position;
    final transportGeneration = _transportGeneration;
    final attemptKey = '$transportGeneration:$songId';
    final isRetry = navisShouldRetryRemotePlayback(
      alreadyRetried: _remotePlaybackRecoveryAttempts.contains(attemptKey),
    );
    if (isRetry) {
      _remotePlaybackRecoveryAttempts.add(attemptKey);
    }
    _lastFailedSongId = songId;
    _emitLoadFailure(
      operation: reason,
      message: 'Remote playback failed.',
      songId: songId,
      isTimeout: reason == 'remote playback stalled',
    );
    if (error != null) {
      AppLogger.warning(
        'Remote playback recovery for song=$songId sourceKind=$sourceKind '
        'reason=$reason: $error\n${stackTrace ?? StackTrace.current}',
      );
    } else {
      AppLogger.warning(
        'Remote playback recovery for song=$songId sourceKind=$sourceKind '
        'reason=$reason.',
      );
    }

    try {
      if (isRetry) {
        try {
          final recoveryToken = OperationToken();
          await _rebuildQueueForSeekRecovery(
            position,
            autoPlay: autoPlay,
            token: recoveryToken,
            transportGeneration: transportGeneration,
            reason: '$reason — switched to direct stream',
          );
          _recordSeekDiagnosticsEvent(<String, Object?>{
            'at': DateTime.now().toUtc().toIso8601String(),
            'path': 'remote_retry',
            'requestedPositionMs': position.inMilliseconds,
            'songId': songId,
            'reason': reason,
            'outcome': 'reloaded',
          });
          return;
        } on Object catch (rebuildError, rebuildStackTrace) {
          AppLogger.warning(
            'Remote playback retry failed for song=$songId. '
            '$rebuildError\n$rebuildStackTrace',
          );
        }
      }

      await _skipPastFailedRemoteSong(currentIndex, autoPlay: autoPlay);
      _recordSeekDiagnosticsEvent(<String, Object?>{
        'at': DateTime.now().toUtc().toIso8601String(),
        'path': 'remote_retry',
        'requestedPositionMs': position.inMilliseconds,
        'songId': songId,
        'reason': reason,
        'outcome': 'skipped',
      });
    } finally {
      _remotePlaybackRecoveryInProgress = false;
      _emitSnapshot();
    }
  }

  Future<void> _skipPastFailedRemoteSong(
    int failedIndex, {
    required bool autoPlay,
  }) async {
    // The next song may still be deferred; playFromIndex releases it.
    final nextIndex = _nextPlayableIndexAfterFailure(
      failedIndex,
      _logicalQueueIds.length,
    );
    if (nextIndex != null) {
      await playFromIndex(nextIndex);
      return;
    }

    await _player.pause();
    if (_player.processingState == ProcessingState.loading ||
        _player.processingState == ProcessingState.buffering) {
      await _player.stop();
    }
    if (autoPlay) {
      _broadcastPlaybackState();
    }
  }

  String? get _currentSourceKind {
    final index = _resolveCurrentQueueMetadata().currentIndex;
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

  /// Starts an Instant Mix seeded from the currently playing song.
  ///
  /// Uses [_preferredMixToggleCallback] (toggles on/off) when registered,
  /// falling back to [_preferredMixCallback] (activate-only), and finally
  /// to a direct `getSimilarSongs` API call.
  ///
  /// Note: the current media item's `id` is a raw Subsonic song ID, not the
  /// `song/{id}` format used in the browse tree.
  Future<bool> _playInstantMixFromCurrentSong() async {
    final current = _currentMediaItem;
    // Android Auto may start its service before there is a media item or a
    // Flutter shell. Choose a local library seed and still honor the saved
    // song-mix mode through the bootstrap callback.
    final seedId = current?.id ?? await _coldStartMixSeed();
    if (seedId == null) return false;

    final toggleCb = current == null ? null : _preferredMixToggleCallback;
    if (toggleCb != null) {
      try {
        await toggleCb(seedId);
        return true;
      } on Object catch (e, st) {
        AppLogger.warning('Instant Mix (toggle) failed for $seedId: $e\n$st');
      }
    }

    // Fallback to activate-only callback if toggle not yet wired.
    if (_preferredMixCallback != null) {
      try {
        await _preferredMixCallback!(seedId);
        return true;
      } on Object catch (e, st) {
        AppLogger.warning(
          'Instant Mix (preferred mode) failed for $seedId: $e\n$st',
        );
      }
    }

    if (toggleCb != null || _preferredMixCallback != null) return false;

    // Last resort: direct API call.
    final api = _readApiClient();
    if (api != null) {
      try {
        final songs = await api.getSimilarSongs(seedId, count: 50);
        final songIds = songs.map((s) => s.id).toList(growable: false);
        if (songIds.isNotEmpty) {
          await replaceQueue(songIds, expandMatchFlows: false);
          if (_queueItems.isNotEmpty) {
            return true;
          }
        }
      } on Object catch (e, st) {
        AppLogger.warning(
          'Instant Mix (fallback) failed for song $seedId: $e\n$st',
        );
      }
    }
    return _playInstantRadio();
  }

  Future<String?> _coldStartMixSeed() async {
    final liked = await _libraryDao.watchAllStarredSongs().first;
    if (liked.isNotEmpty) return liked.first.id;
    final first = await _libraryDao.getSongsSorted(
      SongSortOrder.newest,
      limit: 1,
    );
    return first.isEmpty ? null : first.first.id;
  }

  /// Starts an Instant Radio seeded from a random liked song.
  ///
  /// Matches the behaviour of the home screen Instant Radio button: picks a
  /// random liked (starred) song as the seed and delegates to
  /// [_preferredMixCallback].  Falls back to `getRandomSongs()` when no liked
  /// songs exist or no API client is available.
  Future<bool> _playInstantRadio() async {
    final startPersonalRadio = _startPersonalRadio;
    if (startPersonalRadio != null) {
      return startPersonalRadio(true);
    }
    final liked = await _libraryDao.watchAllStarredSongs().first;
    if (liked.isNotEmpty) {
      final seed = (List.of(liked)..shuffle()).first;
      if (_preferredMixCallback != null) {
        try {
          await _preferredMixCallback!(seed.id);
          return true;
        } on Object catch (e, st) {
          AppLogger.warning(
            'Instant Radio (preferred mode) failed for ${seed.id}: $e\n$st',
          );
        }
      }
    }

    // Fallback: random songs from the API or local library.
    final api = _readApiClient();
    if (api != null) {
      try {
        final songs = await api.getRandomSongs(size: 50);
        final songIds = songs.map((s) => s.id).toList(growable: false);
        if (songIds.isNotEmpty) {
          await replaceQueue(songIds, expandMatchFlows: false);
          if (_queueItems.isNotEmpty) {
            return true;
          }
        }
      } on Object catch (e, st) {
        AppLogger.warning('Instant Radio API fallback failed: $e\n$st');
      }
    }
    final shuffled = await _libraryDao.getRandomSongs(50);
    if (shuffled.isEmpty) return false;
    await replaceQueueWithData(shuffled, expandMatchFlows: false);
    return _queueItems.isNotEmpty;
  }

  Future<bool> _queueInstantRadioFallback({required bool autoPlay}) async {
    final startPersonalRadio = _startPersonalRadio;
    if (startPersonalRadio != null) {
      return startPersonalRadio(autoPlay);
    }
    final liked = await _libraryDao.watchAllStarredSongs().first;
    if (liked.isNotEmpty) {
      AppLogger.debug(
        'Android Auto fallback: queueing liked songs '
        '(count=${liked.length}, autoPlay=$autoPlay).',
      );
      await replaceQueueWithData(
        liked,
        autoPlay: autoPlay,
        expandMatchFlows: false,
      );
      return _queueItems.isNotEmpty;
    }

    final api = _readApiClient();
    if (api != null) {
      try {
        final songs = await api.getRandomSongs(size: 50);
        final songIds = songs.map((s) => s.id).toList(growable: false);
        if (songIds.isNotEmpty) {
          AppLogger.debug(
            'Android Auto fallback: queueing API random songs '
            '(count=${songIds.length}, autoPlay=$autoPlay).',
          );
          await replaceQueue(
            songIds,
            autoPlay: autoPlay,
            expandMatchFlows: false,
          );
          if (_queueItems.isNotEmpty) {
            return true;
          }
        }
      } on Object catch (e, st) {
        AppLogger.warning('Android Auto random API fallback failed: $e\n$st');
      }
    }

    final shuffled = await _libraryDao.getRandomSongs(50);
    if (shuffled.isEmpty) {
      AppLogger.debug('Android Auto fallback: local library is empty.');
      return false;
    }

    AppLogger.debug(
      'Android Auto fallback: queueing local random songs '
      '(count=${shuffled.length}, autoPlay=$autoPlay).',
    );
    await replaceQueueWithData(
      shuffled,
      autoPlay: autoPlay,
      expandMatchFlows: false,
    );
    return _queueItems.isNotEmpty;
  }

  Future<void> Function(String)? _preferredMixCallback;
  Future<void> Function(String)? _preferredMixToggleCallback;

  @override
  void registerPreferredMixCallback(
    Future<void> Function(String seedSongId) callback,
  ) {
    _preferredMixCallback = callback;
  }

  @override
  void registerPreferredMixToggleCallback(
    Future<void> Function(String seedSongId) callback,
  ) {
    _preferredMixToggleCallback = callback;
  }

  @override
  Future<void> toggleLike() => _toggleCurrentSongLike();

  @override
  Future<void> syncSongLikedState(String songId, {required bool liked}) =>
      _syncSongLikedState(songId, liked: liked);

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
    final remote = _remoteRows[songId];
    if (remote != null) {
      _remoteRows[songId] = remote.copyWith(
        starred: Value(liked ? DateTime.now() : null),
      );
    }
    // Remote rows kept in the deferred tail carry their own liked state.
    for (var i = 0; i < _deferredTail.length; i++) {
      final entry = _deferredTail[i];
      final song = entry.song;
      if (entry.id == songId && song != null) {
        _deferredTail[i] = _DeferredQueueEntry(
          entry.id,
          song.copyWith(starred: Value(liked ? DateTime.now() : null)),
        );
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
    final index = _resolveCurrentQueueMetadata().currentIndex;
    if (index == null || index < 0 || index >= _queueItems.length) return;
    final current = _queueItems[index];
    final liked = await _starSyncDao.toggleSongStarred(current.id);
    await _syncSongLikedState(current.id, liked: liked);
    final currentIndex = _resolveCurrentQueueMetadata().currentIndex;
    if (currentIndex != null &&
        currentIndex < _queueItems.length &&
        _queueItems[currentIndex].id == current.id) {
      _setCurrentMediaItem(_queueItems[currentIndex]);
    }
    unawaited(
      _listenBrainzFeedbackService.enqueueSongFeedback(
        current.id,
        liked: liked,
      ),
    );
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
    _artCache?.dispose();
    _cancelCrossfade();
    _cancelRemotePlaybackStallWatchdog();
    _cancelSeekBufferingRecovery();
    await _disposeInactiveCrossfadeDeck();
    _positionPersistTimer?.cancel();
    _transportPersistTimer?.cancel();
    await _flushQueueItemsPersistence();
    _radioStation = null;
    _radioMetadataService.dispose();
    await _sidecarDownloader.dispose();
    _sidecarSongsById.clear();
    await _interruptionSubscription?.cancel();
    await _becomingNoisySubscription?.cancel();
    await _queueEmissionCounter?.cancel();
    await _disposePlayerListeners();
    for (final subscription in _cacheProgressSubscriptions.values) {
      await subscription.cancel();
    }
    _cacheProgressSubscriptions.clear();
    _rollingCacheActivities.clear();
    _reportRollingCacheActivity?.call(const RollingCacheActivity.idle());
    if (_playerDisposalFuture == null) {
      await _persistSafely(_persistPosition, context: 'dispose handler');
    }
    await _ensurePlayerDisposalStarted();
    await _androidAutoBrowseNotifier.dispose();
    await _snapshotController.close();
    await _adjustmentController.close();
    await _equalizerController.close();
    await _transportVisualCueController.close();
    await _positionController.close();
    await _bufferStateController.close();
    await _radioStreamErrorController.close();
    await _loadFailureController.close();
    await _droppedSongsController.close();
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
    _cancelRemotePlaybackStallWatchdog();
    _cancelSeekBufferingRecovery();
    unawaited(_disposeInactiveCrossfadeDeck());
    _positionPersistTimer?.cancel();
    _transportPersistTimer?.cancel();
    unawaited(_flushQueueItemsPersistence());
    _radioStation = null;
    _radioMetadataService.dispose();
    unawaited(_disposePlayerListeners());
    for (final subscription in _cacheProgressSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    _cacheProgressSubscriptions.clear();
    _rollingCacheActivities.clear();
    _reportRollingCacheActivity?.call(const RollingCacheActivity.idle());
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
    _crossfadePlayer = null;
    try {
      await inactiveDeck.pause();
    } on Object {
      // Best-effort shutdown only.
    }
    await _setVolumeIfChanged(inactiveDeck, 0);
    try {
      await inactiveDeck.dispose();
    } on Object {
      // Best-effort shutdown only.
    }
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
    _supersedeTransportIntent();
    final generation = _supersedeQueueWork(isLoading: true);
    return _queueLane.run((token) async {
      try {
        await _ready;
        _checkQueueWorkCurrent(token, generation);

        // If a stream is already active, stop the current player cleanly
        // before loading the new source.
        if (_radioStation != null) {
          await _runTimedPlayerOperation(
            generation: generation,
            operation: 'radio stop before switch',
            action: _player.stop,
            timeout: _playerResetTimeout,
          );
        }

        _radioStation = RadioStationMetadata(
          stationId: stationId,
          stationName: stationName,
          streamUrl: streamUrl,
          homePageUrl: homePageUrl,
        );

        _queueItems.clear();
        await _clearDeferredTail();
        _updateScrobbleSession(null);

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
          await _runTimedPlayerOperation(
            generation: generation,
            operation: 'radio source apply',
            action: () => _player.setAudioSource(
              AudioSource.uri(
                Uri.parse(streamUrl),
                tag: radioMediaItem,
              ),
            ),
            timeout: _playerLoadTimeout,
          );
        } on Object catch (error, stackTrace) {
          AppLogger.error(
            'Failed to start radio stream: $streamUrl',
            error,
            stackTrace,
          );
          _radioStation = null;
          _completeQueueLoad(
            generation,
            failed: error is PlaybackLoadTimeoutException,
          );
          rethrow;
        }

        _checkQueueWorkCurrent(token, generation);
        queue.add(<MediaItem>[radioMediaItem]);
        _setCurrentMediaItem(radioMediaItem);

        final azuraInfo = _tryExtractAzuracast(streamUrl, homePageUrl);
        _radioMetadataService.startListening(
          stationId: stationId,
          azuracastApiUrl: azuraInfo?.$1,
          stationShortName: azuraInfo?.$2,
        );

        unawaited(_player.play());
        _broadcastPlaybackState();
        _completeQueueLoad(generation);
      } on OperationCancelledException {
        AppLogger.debug(
          'playRadioStream cancelled — superseded by newer command.',
        );
      } on Object {
        _completeQueueLoad(generation);
        rethrow;
      }
    });
  }

  @override
  Future<void> stopRadio() {
    final generation = _supersedeQueueWork();
    // Phase 1: Stop radio and update the UI immediately. stopRadio() returns
    // when this phase completes so the caller (and the player bar) are
    // responsive without waiting for disk I/O.
    final stopPhase = _queueLane.run((token) async {
      await _ready;
      _checkQueueWorkCurrent(token, generation);

      if (_radioStation == null) {
        _completeQueueLoad(generation);
        return;
      }

      _radioStation = null;
      _radioMetadataService.stop();

      await _runTimedPlayerOperation(
        generation: generation,
        operation: 'stop radio stop',
        action: _player.stop,
        timeout: _playerResetTimeout,
      );
      await _runTimedPlayerOperation(
        generation: generation,
        operation: 'stop radio reset',
        action: () => _player.setAudioSources(const <AudioSource>[]),
        timeout: _playerResetTimeout,
      );
      queue.add(const <MediaItem>[]);
      _setCurrentMediaItem(null);

      _broadcastPlaybackState();
      _completeQueueLoad(generation);
    });

    // Phase 2: Restore the previous song queue asynchronously so stopRadio()
    // returns as soon as the player is stopped. The guard condition at the
    // start prevents the restore from clobbering a queue that the user has
    // already started (e.g. tapping a song immediately after stopping radio).
    unawaited(
      stopPhase
          .then(
            (_) => _queueLane.run((token) async {
              _checkQueueWorkCurrent(token, generation);
              if (_queueItems.isNotEmpty || _radioStation != null) return;
              try {
                await _restoreQueueFromDisk().timeout(
                  const Duration(seconds: 10),
                );
              } on TimeoutException catch (error, stackTrace) {
                AppLogger.warning(
                  'Queue restore after radio stop timed out. '
                  'Clearing persisted queue to unblock playback. '
                  '$error\n$stackTrace',
                );
                await _clearPersistedQueueBestEffort();
              } on Object catch (error, stackTrace) {
                AppLogger.warning(
                  'Queue restore after radio stop failed: $error\n$stackTrace',
                );
              }
            }),
          )
          .catchError((_) {}),
    );

    return stopPhase;
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

    // Compute what the new RadioStationMetadata fields would be.
    final nextTitle = title ?? current.nowPlayingTitle;
    final nextArtist = artist ?? current.nowPlayingArtist;
    final nextArtUrl = artUrl ?? current.nowPlayingArtUrl;

    // Skip the broadcast when nothing actually changed — this prevents
    // unnecessary UI rebuilds during the Azuracast polling cycle when the
    // track hasn't changed between polls.
    if (nextTitle == current.nowPlayingTitle &&
        nextArtist == current.nowPlayingArtist &&
        nextArtUrl == current.nowPlayingArtUrl) {
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
    bool expandMatchFlows = true,
  }) async {
    final expansion = await _expandMatchFlowIds(
      songIds,
      startIndex: startIndex,
      expandMatchFlows: expandMatchFlows,
    );
    songIds = expansion.songIds;
    startIndex = expansion.startIndex;
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

  Future<MatchFlowExpansionResult> _expandMatchFlowIds(
    List<String> songIds, {
    required int startIndex,
    required bool expandMatchFlows,
  }) {
    return _matchFlowDao.expandQueueSongIds(
      songIds,
      startIndex: startIndex,
      enabled: expandMatchFlows && _readRuntimeSettings().matchFlowEnabled,
    );
  }

  Future<void> _clearQueueInternal({
    required bool persist,
    int generation = 0,
  }) async {
    _clearQueueReplacementMetadataAnchor();
    _queueItems.clear();
    await _clearDeferredTail();
    if (generation > 0) {
      await _runTimedPlayerOperation(
        generation: generation,
        operation: 'clear queue stop',
        action: _player.stop,
        timeout: _playerResetTimeout,
      );
      await _runTimedPlayerOperation(
        generation: generation,
        operation: 'clear queue sources reset',
        action: () => _player.setAudioSources(const <AudioSource>[]),
        timeout: _playerResetTimeout,
      );
    } else {
      await _player.stop();
      await _player.setAudioSources(const <AudioSource>[]);
    }
    final inactiveDeck = _crossfadePlayer;
    if (inactiveDeck != null) {
      if (generation > 0) {
        await _runTimedPlayerOperation(
          generation: generation,
          operation: 'clear queue inactive stop',
          action: inactiveDeck.stop,
          timeout: _playerResetTimeout,
        );
        await _runTimedPlayerOperation(
          generation: generation,
          operation: 'clear queue inactive reset',
          action: () => inactiveDeck.setAudioSources(const <AudioSource>[]),
          timeout: _playerResetTimeout,
        );
      } else {
        await inactiveDeck.stop();
        await inactiveDeck.setAudioSources(const <AudioSource>[]);
      }
      await _applyAdjustmentsToPlayer(inactiveDeck, _appliedAdjustments);
      await _setVolumeIfChanged(inactiveDeck, 0);
    }
    await _applyAdjustmentsToPlayer(_player, _appliedAdjustments);
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
