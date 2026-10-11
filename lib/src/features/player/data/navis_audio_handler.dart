import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:crypto/crypto.dart';
import 'package:audio_session/audio_session.dart';
import 'package:dio/dio.dart' show Dio;
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
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
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/features/auto/data/android_auto_browse_notifier.dart';
import 'package:navis/src/features/auto/data/auto_media_tree_service.dart';
import 'package:navis/src/features/auto/domain/android_auto_constants.dart';
import 'package:navis/src/features/cache/data/rolling_cache_manager.dart';
import 'package:navis/src/features/cache/data/rolling_cache_sidecar_downloader.dart';
import 'package:navis/src/features/integrations/domain/integration_artwork.dart';
import 'package:navis/src/features/integrations/data/integration_call_recorder.dart';
import 'package:navis/src/features/player/data/real_time_projection_audio_handler.dart';
import 'package:navis/src/features/player/data/playback_art_cache.dart';
import 'package:navis/src/features/player/data/android_system_art.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:navis/src/features/player/data/playback_navigation_intent.dart';
import 'package:navis/src/features/player/data/playback_startup_trace.dart';
import 'package:navis/src/features/player/data/listenbrainz_feedback_service.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/data/radio_metadata_service.dart';
import 'package:navis/src/features/player/data/scrobble_service.dart';
import 'package:navis/src/features/player/data/linux_mpris_bridge.dart';
import 'package:navis/src/features/player/data/navis_shuffle_order.dart';
import 'package:navis/src/features/equalizer/data/eq_platform_support.dart';
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
part 'navis_audio_handler_media_session.dart';
part 'navis_audio_handler_diagnostics.dart';
part 'navis_audio_handler_radio.dart';
part 'navis_audio_handler_cache.dart';
part 'navis_audio_handler_recovery.dart';
part 'navis_audio_handler_navigation.dart';
part 'navis_audio_handler_queue_editing.dart';
part 'navis_audio_handler_queue_loading.dart';
part 'navis_audio_handler_queue_window.dart';
part 'navis_audio_handler_persistence.dart';
part 'navis_audio_handler_android_auto.dart';
part 'navis_audio_handler_crossfade.dart';

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
  new({
    required this._libraryDao,
    required this._playlistDao,
    required this._playQueueDao,
    required this._matchFlowDao,
    required this._historyDao,
    required this._sourceResolver,
    required this._readApiClient,
    required this._rollingCacheManager,
    required this._readRollingCacheBudgetBytes,
    required this._scrobbleService,
    required this._listenBrainzFeedbackService,
    required this._readRuntimeSettings,
    required this._starSyncDao,
    double initialVolume = 1.0,
    NetworkUsageReporter? reportNetworkUsage,
    Future<File?> Function(String coverArtId)? readPermanentArtwork,
    CoverArtHttpFileService? artworkFileService,
    this._reportRollingCacheActivity,
    required this._startPersonalRadio,
    required Future<void> Function(String) startPreferredMix,
    required Future<void> Function(String) togglePreferredMix,
    this._readRadioMetadataAllowed,
    this._readRadioPlaybackAllowed,
    this._readRadioArtworkAllowed,
    this._createRadioMetadataDio,
    AudioPlayer? player,
    this._adjustmentCapabilities,
    EqCapabilities? equalizerCapabilities,
    this._crossfadePlayerFactory,
    this._playerFactory,
    this._queueWindow = const NavisQueueWindow(),
    this._timeouts = const NavisPlaybackTimeouts(),
    math.Random? shuffleRandom,
  }) : _shuffleRandom = shuffleRandom ?? math.Random(),
       _injectedEqualizerCapabilities = equalizerCapabilities,
       _userVolume = initialVolume.isFinite
           ? initialVolume.clamp(0.0, 1.0)
           : 1.0,
       _reportNetworkUsage = reportNetworkUsage,
       _preferredMixCallback = startPreferredMix,
       _preferredMixToggleCallback = togglePreferredMix,
       // A local cover file for the system media controls: Android's
       // bitmap, and MPRIS and SMTC art without the credential-bearing URL.
       _artCache = _isAndroidRuntime || _isLinuxRuntime || _isWindowsRuntime
           ? PlaybackArtCache(
               reportNetworkUsage: reportNetworkUsage,
               readPermanentArtwork: readPermanentArtwork,
               fileService: artworkFileService,
             )
           : null {
    final runtime = _readRuntimeSettings();
    _desiredEqualizer = runtime.equalizer ?? EqConfiguration.flat();
    if (player != null) {
      _equalizerPipelineEnabled = equalizerCapabilities?.supported ?? false;
      _player = player;
    } else {
      _equalizerPipelineEnabled = navisEqualizerSupported(
        android: _isAndroidRuntime,
      );
      _player = _buildAudioPlayer(enableEqualizer: _equalizerPipelineEnabled);
    }
    _crossfadeEnabled = runtime.crossfadeEnabled;
    _crossfadePlayer = runtime.crossfadeEnabled ? _newCrossfadePlayer() : null;
    _radioMetadataService = _newRadioMetadataService();
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
  final Future<bool> Function(bool autoPlay) _startPersonalRadio;
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

  /// Played songs before [_queueItems] that the native player no longer
  /// holds (released from it to keep it small). The logical queue is
  /// head + materialised + tail, so a logical index is the native index plus
  /// the head's length; a queue replacement always starts with no head.
  final _RevisionedList<_DeferredQueueEntry> _deferredHead =
      _RevisionedList<_DeferredQueueEntry>();

  /// The caller's rows for remote songs that are, or were, materialised,
  /// so a remote song moved back into [_deferredTail] keeps its own row
  /// instead of being re-read by id (which misses it, or finds the local
  /// song it was matched to). Pruned to the materialised queue as it grows.
  final Map<String, SongsTableData> _remoteRows = <String, SongsTableData>{};

  /// The user's shuffle. Navis owns the order: the logical queue is always
  /// the play order and native shuffle is never enabled, because native
  /// shuffle orders only what the player holds (so it cannot shuffle a
  /// deferred tail), and media_kit reorders mpv's playlist behind just_audio.
  bool _shuffleEnabled = false;

  /// While [_shuffleEnabled], the queue's unshuffled order as last recorded;
  /// reconciled with later edits by [reconcileOriginalRanks] when it is
  /// needed (turning shuffle off, saving the queue).
  List<String>? _originalOrder;
  final math.Random _shuffleRandom;
  final NavisQueueWindow _queueWindow;
  List<String>? _logicalIdsCache;
  int _logicalIdsQueueRevision = -1;
  int _logicalIdsTailRevision = -1;
  int _logicalIdsHeadRevision = -1;

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
  Future<void>? _deferredQueueRestoreRetry;
  final NavisSupersedingLane _queueLane = NavisSupersedingLane();
  int _queueEditSequence = 0;

  /// Edits waiting at the back of the queue lane for a load to finish.
  final Set<int> _requeuedQueueEdits = <int>{};
  final _seekLane = NavisSupersedingLane();
  final _playbackLane = _SerializationLane();
  final PlaybackNavigationIntent _navigationIntent = PlaybackNavigationIntent();
  DateTime? _navigationIssuedAt;
  int _navigationSupersededCount = 0;
  int _navigationCompletedCount = 0;
  int _navigationTimeoutCount = 0;
  int? _navigationInFlightRevision;
  String _queueRestoreOutcome = 'not_attempted';

  /// Why the latest restore was deferred, and how many deferred restores
  /// were retried (diagnostics only; resolver messages carry no identities).
  String? _queueRestoreDeferredReason;
  int _queueRestoreRetryCount = 0;
  int _transportGeneration = 0;
  bool? _latestExplicitTransportPlaying;
  _PendingSeek? _pendingSeek;
  DateTime? _lastPositionEmitAt;
  _PendingSeek? _lastSeek;
  int _seekRevision = 0;
  bool _seekFailureBlocksRecovery = false;
  // Where the failed seek left playback; normal progress past it lifts the
  // block above.
  Duration? _seekFailurePosition;
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
  // When each song's cache download last received bytes.
  final Map<String, DateTime> _cacheProgressAt = <String, DateTime>{};
  // Observed lock-cache sources by cache path, so a download the player has
  // moved on from can be stopped.
  // ignore: experimental_member_use, reason: LockCachingAudioSource is the intended just_audio cache primitive for rolling cache playback.
  final Map<String, ({String songId, LockCachingAudioSource source})>
  _lockCacheSources =
      // ignore: experimental_member_use, reason: as above.
      <String, ({String songId, LockCachingAudioSource source})>{};
  final Set<String> _lockCachingBypassedSongIds = <String>{};
  final List<Map<String, Object?>> _seekDiagnosticsEvents =
      <Map<String, Object?>>[];
  static const int _maxSeekDiagnosticsEvents = 32;
  final RollingCacheSidecarDownloader _sidecarDownloader =
      RollingCacheSidecarDownloader();
  final Map<String, SongsTableData> _sidecarSongsById =
      <String, SongsTableData>{};

  /// The credential-bearing stream URL of each song in [_sidecarSongsById].
  /// Kept here, not in [MediaItem.extras], which audio_service publishes to
  /// the platform media session.
  final Map<String, Uri> _sidecarStreamUris = <String, Uri>{};
  final Map<String, String> _songIdentityAliases = <String, String>{};
  Timer? _remotePlaybackStallTimer;
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
  int? _interruptedTransportGeneration;
  RealTimeProjectionAudioHandler? _systemProjection;
  bool _gaplessEnabled = true;
  MediaItem? _activeScrobbleItem;
  int? _activeScrobbleIndex;
  String? _activeScrobbleSongId;
  String? _activeScrobbleSessionKey;
  bool _sentNowPlayingScrobble = false;
  bool _sentSubmissionScrobble = false;

  // ── Cross-fade state ──────────────────────────────────────────────────────
  bool _crossfadeEnabled = false;
  bool _crossfadeLocalOnlyDeck = false;
  String? _crossfadeLastFailure;
  String? _crossfadeDisabledReason;
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

  /// Cross-fade outcomes by metric phase, for diagnostics.
  final Map<String, int> _crossfadePhaseCounts = <String, int>{};

  /// Where the latest seek or stall recovery is, for diagnostics.
  String? _recoveryStage;

  /// The playing entry whose transition could not be prepared: it ends
  /// gaplessly rather than reloading the deck on every position tick.
  ({int index, String songId})? _crossfadeFailedFrom;
  int _transportVisualCueToken = 0;

  /// The queue index of the track loaded on `_crossfadePlayer`.
  int? _crossfadeTargetIndex;

  /// Non-null while a radio stream is active.
  RadioStationMetadata? _radioStation;

  /// Manages ICY / Azuracast metadata polling for radio streams.
  late RadioMetadataService _radioMetadataService;

  /// Whether a station's now-playing artwork may be shown and published to
  /// the OS media session now: the user's own server always, an external host
  /// only while radio metadata and the host's service are allowed. Null
  /// refuses all. AudioService fetches whatever `artUri` it is given with its
  /// own unguarded cache, so only URLs this accepts are ever published.
  final bool Function(Uri uri)? _readRadioArtworkAllowed;

  /// Missing callbacks allow playback for standalone handlers.
  final bool Function(Uri stream)? _readRadioPlaybackAllowed;

  final bool Function()? _readRadioMetadataAllowed;
  final Dio Function()? _createRadioMetadataDio;

  Future<void>? _playerDisposalFuture;
  bool _disposeHandlerStarted = false;
  Future<void>? _disposeHandlerFuture;
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
  int beginPlaybackSelection(
    String songId, {
    required bool isExternal,
    SongsTableData? song,
  }) {
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
    if (song != null) {
      // Keep radio alive until persistence hands the replacement to the queue
      // loader. A failed provisional write has not changed the playing source.
      _pendingLogicalQueueSongs = [song];
      _navigationIntent.reset();
      _supersedeTransportIntent(shouldPlay: true);
      _cancelCrossfade();
      _supersedeQueueWork(isLoading: true, loadingSongId: songId);
      _setQueueReplacementMetadataAnchor(
        expectedIndex: 0,
        mediaItem: _mediaItemForSong(song),
      );
      _setCurrentMediaItem(_queueReplacementMetadataAnchor!.mediaItem);
      _emitSnapshot();
    }
    return trace.attempt;
  }

  /// Records a safe stage name; no media identity is exposed in diagnostics.
  @override
  void notePlaybackSelectionStage(int attempt, String stage) {
    final trace = _activeStartupTrace;
    if (trace?.attempt == attempt) {
      trace?.mark(stage);
      if (stage == 'provisionalPersistenceFailed' &&
          trace?.awaitingHandler == true &&
          _loadingSongId == trace?.songId) {
        _completeQueueLoad(
          _activeLoadGeneration,
          loadingSongId: trace?.songId,
          failed: true,
        );
      }
    }
  }

  @override
  bool isPlaybackSelectionCurrent(int attempt) =>
      _activeStartupTrace?.attempt == attempt &&
      _activeStartupTrace?.awaitingHandler == true;

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
  ValueStream<Map<String, dynamic>> subscribeToChildren(String parentMediaId) =>
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

  /// Caches [coverArtId]'s cover from [artUri] for the system media
  /// controls and returns the local file, or `null` when there is no cache
  /// on this platform or the download fails.
  Future<String?> cacheSystemArtwork(String coverArtId, Uri artUri) =>
      _artCache?.getOrFetch(coverArtId, artUri) ?? Future<String?>.value();

  /// The local file of [coverArtId]'s cover if it is already cached for the
  /// system media controls, without downloading.
  String? cachedSystemArtwork(String coverArtId) =>
      _artCache?.cachedPath(coverArtId);

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
      handleInterruptions: false,
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

  /// Retries a startup restore that was deferred because no playback source
  /// was available (no session yet, or offline without a cached copy). The
  /// queue is restored paused, and only while the user has not started other
  /// playback.
  @override
  Future<void> retryDeferredQueueRestore() {
    return _deferredQueueRestoreRetry ??= _retryDeferredQueueRestoreOnce()
        .whenComplete(() => _deferredQueueRestoreRetry = null);
  }

  bool _continuingIntoDeferredTail = false;

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
    // Structure only: songs refreshed in place outside the lane (art, liked
    // state, canonical ids) do not invalidate this page.
    final queueRevision = _queueItems.structureRevision;
    final tailRevision = _deferredTail.structureRevision;
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
    if (_queueItems.structureRevision != queueRevision ||
        _deferredTail.structureRevision != tailRevision) {
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

  ProcessingState? _eqObservedProcessingState;
  int? _eqObservedIndex;
  bool _eqRefreshInFlight = false;

  /// The last song of the queue has ended; [_visiblePlaying] reads paused
  /// until playback is started or moved again.
  bool _queueFinished = false;
  ProcessingState? _finishObservedProcessingState;

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

  // ── Cross-fade logic ────────────────────────────────────────────────────

  /// Called on every position tick to decide whether to begin cross-fading.
  void _checkCrossfadeTrigger(Duration position) {
    if (!_crossfadeEnabled ||
        _isCrossfading ||
        _radioStation != null ||
        !_player.playing ||
        // Do not hand a pending selection or seek to another player.
        _isLoading ||
        _pendingSeek != null ||
        _pendingLogicalQueueSongIds != null) {
      return;
    }

    final current = _resolveCurrentQueueMetadata();
    if (_crossfadeDisabledReason == 'cellular' &&
        _readRuntimeSettings().crossfadeAllowStreaming) {
      _crossfadeFailedFrom = null;
      _crossfadeDisabledReason = null;
    }
    final failed = _crossfadeFailedFrom;
    if (failed != null &&
        failed.index == current.currentIndex &&
        failed.songId == current.mediaItem?.id) {
      return;
    }
    final duration = _effectivePlaybackDuration(current.mediaItem);
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

    // A song is its own album even when album metadata is unavailable.
    // Only Normal mode overlaps the end with a fresh start of that song.
    if (_player.loopMode == LoopMode.one && _crossfadeType != 'normal') {
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

  Future<void> _setVolumeIfChanged(AudioPlayer player, double target) async {
    if ((player.volume - target).abs() <= _volumeNoopEpsilon) {
      return;
    }
    await player.setVolume(target);
  }

  void _rebindRadioMetadataServiceToActivePlayer() {
    final metadataSource = _radioMetadataService.metadataSource;
    _radioMetadataService.dispose();
    _radioMetadataService = _newRadioMetadataService();
    if (_radioStation != null) {
      final azuraInfo = _tryExtractAzuracast(_radioStation!.streamUrl);
      _radioMetadataService.startListening(
        stationId: _radioStation!.stationId,
        initialMetadataSource: metadataSource,
        azuracastApiUrl: azuraInfo?.$1,
        stationShortName: azuraInfo?.$2,
      );
    }
  }

  /// Restores the saved queue paused. With a lane [token], the restore yields
  /// to a queue command issued while reading, resolving, or loading it.
  Future<void> _restoreQueueFromDisk({
    OperationToken? token,
    int? ownershipGeneration,
  }) async {
    final queueState = await _playQueueDao.getQueueState();
    final entries = await _playQueueDao.getQueueEntries();
    var queuedSongs = <SongsTableData>[for (final entry in entries) entry.song];
    if (token?.isCancelled ?? false) {
      if (_queueRestoreOutcome != 'timeout') {
        _queueRestoreOutcome = 'superseded';
      }
      return;
    }
    if (queuedSongs.isEmpty) {
      _queueRestoreOutcome = 'empty';
      return;
    }

    final startIndex = (queueState?.currentIndex ?? 0)
        .clamp(0, math.max(0, queuedSongs.length - 1))
        .toInt();
    _shuffleEnabled = queueState?.shuffleMode == schema.ShuffleMode.all;
    _originalOrder = null;
    if (_shuffleEnabled) {
      final ranks = <int?>[for (final entry in entries) entry.originalOrder];
      if (ranks.every((rank) => rank != null)) {
        // Saved in play order with each song's unshuffled position.
        _originalOrder = <String>[
          for (final i in unshuffledIndices(ranks.cast<int>()))
            queuedSongs[i].id,
        ];
      } else {
        // Saved before Navis owned shuffle: the list is the unshuffled
        // order and the player shuffled natively. Shuffle what is left.
        _originalOrder = queuedSongs
            .map((song) => song.id)
            .toList(growable: false);
        queuedSongs = shuffledAfter(queuedSongs, startIndex, _shuffleRandom);
      }
    }
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
        final generation = ownershipGeneration ?? ++_loadGeneration;
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
          token: token ?? OperationToken(),
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
          token: token,
        );
      }
    } on PlaybackSourceUnavailableException catch (error) {
      token?.checkCancelled();
      _clearPendingLogicalQueue();
      _queueRestoreOutcome = 'deferred_auth';
      _queueRestoreDeferredReason = error.message;
      AppLogger.warning(
        'Playback queue restore deferred until a playback source is '
        'available: ${error.message}',
      );
      return;
    } on OperationCancelledException {
      // A newer queue command owns the player, the pending logical queue and
      // the saved queue; leave all of them intact.
      if (_queueRestoreOutcome != 'timeout') {
        _queueRestoreOutcome = 'superseded';
      }
      AppLogger.debug('Queue restore superseded by a newer queue command.');
      return;
    } on Object catch (error, stackTrace) {
      token?.checkCancelled();
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

    token?.checkCancelled();
    if (queueState != null) {
      _desiredLoopMode = switch (queueState.repeatMode) {
        schema.RepeatMode.one => LoopMode.one,
        schema.RepeatMode.all => LoopMode.all,
        schema.RepeatMode.off => LoopMode.off,
      };
      await _syncNativeLoopMode();
    }

    token?.checkCancelled();
    await _player.pause();
    token?.checkCancelled();
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
      _queueLane.fill((token) async {
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
    // A long queue started deep inside materialises only [behind] songs
    // before the start one; earlier songs wait in the deferred head.
    final allBeforeStart = songs.sublist(0, clampedIndex);
    final headSongs = deferTail && allBeforeStart.length > _queueWindow.behind
        ? allBeforeStart.sublist(0, allBeforeStart.length - _queueWindow.behind)
        : const <SongsTableData>[];
    final beforeStart = allBeforeStart.sublist(headSongs.length);
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
    final preparedByIndex = <int, _PreparedQueueItem>{clampedIndex: startItem};
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
        firstOriginalIndex: headSongs.length + resolvedBefore,
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
    _deferredHead
      ..clear()
      ..addAll(headSongs.map(_deferredEntryFor));
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
      await _persistSafely(() {
        fillTimings['persistStartMs'] = fillWatch.elapsedMilliseconds;
        return _persistQueueState(includeQueueItems: true);
      }, context: 'queue replacement (phase 2)');
    }
    fillTimings['persistMs'] = fillWatch.elapsedMilliseconds;
  }

  static const int _queueFillFirstBatchSize = 8;
  static const int _queueFillBatchSizeLimit = 64;

  static int _queueFillBatchSize(int alreadyProcessed) => alreadyProcessed == 0
      ? _queueFillFirstBatchSize
      : _queueFillBatchSizeLimit;

  @override
  Future<void> replaceQueue(
    List<String> songIds, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    List<String>? originalOrder,
  }) => _replaceQueueIds(
    songIds,
    startIndex: startIndex,
    autoPlay: autoPlay,
    expandMatchFlows: expandMatchFlows,
    originalOrder: originalOrder,
    inPlayOrder: false,
  );

  @override
  Future<void> replaceQueueWithData(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    List<String>? originalOrder,
  }) => _replaceQueueRows(
    songs,
    startIndex: startIndex,
    autoPlay: autoPlay,
    expandMatchFlows: expandMatchFlows,
    originalOrder: originalOrder,
    inPlayOrder: false,
  );

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

  /// Resolves [rows] concurrently in chunks, keeping queue order. `offsets`
  /// gives each row's index in `prepared`, or null when it was dropped.
  Future<({List<_PreparedQueueItem> prepared, List<int?> offsets})>
  _prepareRowsConcurrently(
    List<SongsTableData?> rows, {
    OperationToken? token,
    void Function(int index)? onRetryLater,
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
      final resolved = await Future.wait([
        for (var i = 0; i < chunk.length; i++)
          if (chunk[i] case final row?)
            _prepareSingleItemForQueueFill(
              row,
              onRetryLater: onRetryLater == null
                  ? null
                  : () => onRetryLater(start + i),
            )
          else
            Future<_PreparedQueueItem?>.value(),
      ]);
      for (final item in resolved) {
        offsets.add(item == null ? null : prepared.length);
        if (item != null) prepared.add(item);
      }
      token?.checkCancelled();
    }
    return (prepared: prepared, offsets: offsets);
  }

  @override
  Future<QueueBatchEditResult> mergeIntoUpcoming(
    List<SongsTableData> songs, {
    required int notBefore,
    math.Random? random,
  }) async {
    const result = QueueBatchEditResult();
    if (songs.isEmpty) return result;
    await _enqueueQueueEdit((token) async {
      if (_queueItems.isEmpty) return;
      final entries = songs.map(_deferredEntryFor).toList(growable: false);
      // The current song and the next two stay in the player (gapless, and
      // a stable "up next"); everything after them is merged in Dart. Once
      // songs are deferred, the songs the player holds stay too, so a merge
      // (one per batch of an artist's releases) makes no native call and
      // never races a cross-fade deck; the new songs still spread over every
      // later position. Before that, songs the player holds past the next
      // two go back to the deferred tail with one native call, and refills
      // release them again.
      final current = _player.currentIndex ?? 0;
      var mergeFrom = math.max(notBefore - _deferredHead.length, current + 3);
      if (_deferredTail.isNotEmpty) {
        mergeFrom = math.max(mergeFrom, _queueItems.length);
      }
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
        final head = _deferredHead.length;
        final total = head + _queueItems.length + _deferredTail.length;
        final logical = run.index.clamp(0, total);
        final entries = run.songs
            .map(_deferredEntryFor)
            .toList(growable: false);
        if (logical < head) {
          // Among played songs the player no longer holds.
          _deferredHead.insertAll(logical, entries);
          changed = true;
          continue;
        }
        final index = logical - head;
        if (index >= _queueItems.length &&
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
  Future<void> playNext(List<String> songIds, {bool expandMatchFlows = true}) {
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
            _deferredHead.isEmpty &&
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
      final head = _deferredHead.length;
      if (index >= 0 &&
          index < head &&
          head + _queueItems.length + _deferredTail.length > 1) {
        // A played song the player no longer holds.
        _deferredHead.removeAt(index);
        _afterQueueEdit(context: 'remove at');
        return;
      }
      await _removeAtLocked(index - head);
    });
  }

  @override
  Future<void> reorderQueue(int oldIndex, int newIndex) {
    return _enqueueQueueEdit((token) async {
      final head = _deferredHead.length;
      final total = head + _queueItems.length + _deferredTail.length;
      if (total == 0 ||
          oldIndex < 0 ||
          oldIndex >= total ||
          newIndex < 0 ||
          newIndex > total) {
        return;
      }
      final adjusted = oldIndex < newIndex
          ? newIndex - 1
          : newIndex.clamp(0, total - 1);
      if (oldIndex == adjusted) return;
      if (oldIndex < head && adjusted < head) {
        // Both ends among played songs the player no longer holds.
        _deferredHead.insert(adjusted, _deferredHead.removeAt(oldIndex));
        _afterQueueEdit(context: 'reorder queue');
        return;
      }
      final lowest = math.min(oldIndex, adjusted);
      if (lowest < head) {
        // Bring the played songs involved back into the player first.
        await _releaseHead(count: head - lowest, token: token);
        if (_deferredHead.length + _queueItems.length + _deferredTail.length !=
            total) {
          // A released song could not be prepared; the indices moved.
          return;
        }
      }
      final shift = _deferredHead.length;
      await _reorderLocked(oldIndex - shift, newIndex - shift);
    });
  }

  @override
  Future<void> clearQueue() {
    _invalidatePendingStartupSelection();
    _navigationIntent.reset();
    _pendingLogicalQueueSongs = null;
    _supersedeTransportIntent(shouldPlay: false);
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
      _sidecarStreamUris.clear();
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
    if (index < 0) return;
    await removeAt(index + _deferredHead.length);
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    if (index < 0 || index >= _queueItems.length) return;
    await removeAt(index + _deferredHead.length);
  }

  @override
  Future<void> insertQueueItem(int index, MediaItem mediaItem) async {
    if (index < 0 || index > _queueItems.length) return;
    if (_queueItems.isEmpty) {
      await addToQueue(<String>[mediaItem.id]);
      return;
    }
    final logicalIndex = index + _deferredHead.length;
    final songs = await _libraryDao.getSongsByIds(<String>[
      _canonicalSongId(mediaItem.id),
    ]);
    await insertQueueRuns(<QueueInsertRun>[
      QueueInsertRun(logicalIndex, songs),
    ]);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _queueItems.length) return;
    await playFromIndex(index + _deferredHead.length);
  }

  @override
  Future<void> play() async {
    _queueFinished = false;
    final transportGeneration = _supersedeTransportIntent(
      shouldPlay: true,
      preserveSeek: true,
    );
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
      await playFromIndex(_deferredHead.length + _queueItems.length);
      return;
    }
    if (_player.processingState == ProcessingState.completed &&
        navisShouldRestartCompletedQueue(
          queueLength: _queueItems.length,
          currentIndex: _resolveCurrentQueueMetadata().currentIndex,
          hasPendingLogicalQueue: _pendingLogicalQueueSongIds != null,
        )) {
      if (_radioStation == null && _deferredHead.isNotEmpty) {
        // The first songs were released from the player.
        await playFromIndex(0);
        return;
      }
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
    final transportGeneration = _supersedeTransportIntent(
      shouldPlay: false,
      preserveSeek: true,
    );
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
        // Android maps media-key Pause to a toggle even during focus loss.
        if (_visiblePlaying ||
            _interruptedTransportGeneration == _transportGeneration) {
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
      crossfadeEnabled:
          runtime.crossfadeEnabled && runtime.crossfadeAllowStreaming,
    );
    _crossfadeEnabled = runtime.crossfadeEnabled;
    _crossfadeDurationSeconds = runtime.crossfadeDurationSeconds;
    _crossfadeType = runtime.crossfadeType;
    if (_isRepeatOneCrossfade && _crossfadeType != 'normal') {
      _cancelCrossfade();
    }

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

  @override
  Future<void> seek(Duration position) {
    if (_radioStation != null) return Future<void>.value();
    final songId =
        _loadingSongId ?? _resolveCurrentQueueMetadata().mediaItem?.id;
    if (songId == null) return Future<void>.value();
    _queueFinished = false;
    final generation = _supersedeTransportIntent(preserveSeek: true);
    _cancelPendingSeek();
    final request = _PendingSeek(
      generation: ++_seekRevision,
      songId: songId,
      queueIndex: _navigationIntent.desiredIndex ?? _logicalCurrentIndex,
      position: navisSanitizeSeekPosition(position),
    );
    _seekFailureBlocksRecovery = false;
    _pendingSeek = _lastSeek = request;
    _broadcastPlaybackState();
    _emitSnapshot();
    return _seekLane.run((token) async {
      final started = Stopwatch()..start();
      final beforePosition = _player.position;
      final beforeBuffered = _player.bufferedPosition;
      final beforeSourceKind = _currentSourceKind;
      try {
        await _ready;
        await _waitForSeekSource(request, token);
        _cancelCrossfade();
        await _seekWithRecovery(
          request.position,
          token: token,
          transportGeneration: generation,
          seekRequest: request,
        );
        _checkSeekCurrent(request, token);
        request.outcome = 'completed';
        request.stage = 'done';
        _scheduleTransportPersistence(context: 'seek');
      } on OperationCancelledException {
        request.outcome = 'superseded';
        request.stage = 'done';
      } on Object catch (error, stackTrace) {
        request.outcome = 'failed';
        request.stage = 'done';
        if (identical(_pendingSeek, request)) {
          _seekFailureBlocksRecovery = true;
          _seekFailurePosition = _player.position;
          _emitLoadFailure(
            operation: 'seek',
            message: 'The requested playback position could not be reached.',
            songId: request.songId,
            isTimeout: error is TimeoutException,
          );
          AppLogger.warning('Seek failed: ${error.runtimeType}\n$stackTrace');
        }
      } finally {
        _recordSeekDiagnosticsEvent(<String, Object?>{
          'at': DateTime.now().toUtc().toIso8601String(),
          'generation': request.generation,
          'path': request.recoveryAttempts == 0 ? 'direct' : 'recovery',
          'requestedPositionMs': request.position.inMilliseconds,
          'beforePositionMs': beforePosition.inMilliseconds,
          'beforeBufferedMs': beforeBuffered.inMilliseconds,
          'beforeSourceKind': beforeSourceKind,
          'afterPositionMs': _player.position.inMilliseconds,
          'afterSourceKind': _currentSourceKind,
          'elapsedMs': started.elapsedMilliseconds,
          'outcome': request.outcome,
          'recoveryAttempts': request.recoveryAttempts,
          if (request.unsettled.isNotEmpty) 'unsettled': request.unsettled,
        });
        if (identical(_pendingSeek, request)) {
          _pendingSeek = null;
          _broadcastPlaybackState();
          _emitSnapshot();
        }
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

  /// Stable opaque artwork identity for comparisons without exposing URL parts.
  static String? _diagnosticArtworkHash(String? url) => url == null
      ? null
      : sha256.convert(utf8.encode(url)).toString().substring(0, 16);

  @override
  Map<String, Object?> collectPlaybackDiagnostics() {
    final snapshot = _snapshot;
    final inactiveDeck = _crossfadePlayer;
    final songId = snapshot.currentSongId;
    final cacheActivity = _rollingCacheActivities.values.lastOrNull;
    final partialCacheBytes = _partialCacheBytesForSong(songId);
    final radio = _radioStation;
    final publishedArt =
        radio != null && mediaItem.value?.id == 'radio:${radio.stationId}'
        ? mediaItem.value?.artUri?.toString()
        : null;
    return <String, Object?>{
      'songId': songId,
      'radio': radio == null
          ? null
          : <String, Object?>{
              'stationId': radio.stationId,
              'stationName': radio.stationName,
              'streamHost': Uri.tryParse(radio.streamUrl)?.host,
              'metadataSource': _radioMetadataService.metadataSource.name,
              'nowPlayingTitle': radio.nowPlayingTitle,
              'nowPlayingArtist': radio.nowPlayingArtist,
              'nowPlayingArtHost': radio.nowPlayingArtUrl == null
                  ? null
                  : Uri.tryParse(radio.nowPlayingArtUrl!)?.host,
              'nowPlayingArtHash': _diagnosticArtworkHash(
                radio.nowPlayingArtUrl,
              ),
              'publishedArtHost': publishedArt == null
                  ? null
                  : Uri.tryParse(publishedArt)?.host,
              'publishedArtHash': _diagnosticArtworkHash(publishedArt),
            },
      'currentIndex': snapshot.currentIndex,
      'queueLength': snapshot.queueSongIds.length,
      'playerSequenceLength': _player.sequence.length,
      'materializedLength': _queueItems.length,
      'deferredLength': _deferredTail.length,
      'deferredHeadLength': _deferredHead.length,
      // False while a replacement is still filling the player, by design;
      // otherwise the player and the Dart queue must agree.
      'queueSettled': !_isLoading && _pendingLogicalQueueSongIds == null,
      'playerMatchesQueue': _sequenceMatchesQueue(_player),
      'crossfade': <String, Object?>{
        'enabled': _crossfadeEnabled,
        'active': _isCrossfading,
        'disabledReason': !_crossfadeEnabled
            ? 'setting'
            : _crossfadeDisabledReason,
        'lastFailure': _crossfadeLastFailure,
        'outgoing': _isCrossfading
            ? <String, Object?>{
                'playing': _player.playing,
                'volume': _player.volume,
                'positionMs': _player.position.inMilliseconds,
              }
            : null,
        'incoming': _isCrossfading
            ? <String, Object?>{
                'playing': inactiveDeck?.playing,
                'volume': inactiveDeck?.volume,
                'positionMs': inactiveDeck?.position.inMilliseconds,
              }
            : null,
        'inactiveDeckSequenceLength': inactiveDeck?.sequence.length,
        'inactiveDeckMatchesQueue': inactiveDeck == null
            ? null
            : _sequenceMatchesQueue(inactiveDeck),
        'phases': Map<String, int>.of(_crossfadePhaseCounts),
      },
      'shuffleEnabled': _shuffleEnabled,
      // Native order as the player holds it, for parity checks against the
      // logical queue (limited so large queues stay cheap to report).
      'native': <String, Object?>{
        'index': _player.currentIndex,
        // Always false: Navis owns shuffle.
        'shuffleEnabled': _player.shuffleModeEnabled,
        'sequenceIds': <String?>[
          for (final source in _player.sequence.take(64))
            navisNativeSourceSongId(source),
        ],
        'effectiveIndices': _player.effectiveIndices.take(64).toList(),
        // What mpv itself is playing, reduced to the stream `id` parameter or
        // the cache file name so no credential-bearing URI is reported.
        'mediaKitTransport': JustAudioMediaKit.debugTransportStates(),
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
      'lockCachingBypassed':
          songId != null && _lockCachingBypassedSongIds.contains(songId),
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
      'positionStreamLastEmitAgoMs': _lastPositionEmitAt == null
          ? null
          : DateTime.now().difference(_lastPositionEmitAt!).inMilliseconds,
      'seek': <String, Object?>{
        'generation': _lastSeek?.generation,
        'requestedPositionMs': _lastSeek?.position.inMilliseconds,
        'pending': _pendingSeek != null,
        'stage': _lastSeek?.stage,
        'outcome': _lastSeek?.outcome,
        'recoveryAttempts': _lastSeek?.recoveryAttempts,
      },
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
      'queueLane': _queueLane.diagnostics,
      'recovery': <String, Object?>{
        'stage': _recoveryStage,
        'inProgress': _remotePlaybackRecoveryInProgress,
      },
      'queueRestoreOutcome': _queueRestoreOutcome,
      'queueRestoreDeferredReason': _queueRestoreDeferredReason,
      'queueRestoreRetries': _queueRestoreRetryCount,
      'startupAttempts': <Map<String, Object?>>[
        for (final trace in _startupTraces) trace.toDiagnostics(),
      ],
    };
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

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    await _ready;
    final enabled = shuffleMode == AudioServiceShuffleMode.all;
    await _enqueueQueueEdit((token) async {
      if (enabled == _shuffleEnabled) return;
      _cancelCrossfade();
      final entries = _logicalQueueEntries();
      final current = _logicalCurrentIndex;
      if (entries.isEmpty || current == null) {
        // Nothing to reorder yet; the next queue starts shuffled.
        _shuffleEnabled = enabled;
        _originalOrder = enabled
            ? entries.map((entry) => entry.id).toList(growable: false)
            : null;
        return;
      }
      final ids = entries.map((entry) => entry.id).toList(growable: false);
      final previousEnabled = _shuffleEnabled;
      final previousOriginalOrder = _originalOrder;
      bool rearranged;
      if (enabled) {
        // History and the current song stay; the rest is shuffled.
        _originalOrder = ids;
        _shuffleEnabled = true;
        rearranged = await _rearrangeQueue(
          shuffledAfter(entries, current, _shuffleRandom),
          current: current,
          newCurrent: current,
          token: token,
        );
      } else {
        // The whole queue returns to its unshuffled order, including songs
        // added while shuffled, around the current song.
        final ranks = reconcileOriginalRanks(ids, _originalOrder ?? ids);
        final order = unshuffledIndices(ranks);
        _shuffleEnabled = false;
        _originalOrder = null;
        rearranged = await _rearrangeQueue(
          <_DeferredQueueEntry>[for (final i in order) entries[i]],
          current: current,
          newCurrent: order.indexOf(current),
          token: token,
        );
      }
      if (!rearranged) {
        _shuffleEnabled = previousEnabled;
        _originalOrder = previousOriginalOrder;
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
    if (_isRepeatOneCrossfade && loopMode != LoopMode.one) {
      _cancelCrossfade();
    }
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
        (navisEqualizerSupported(android: _isAndroidRuntime)
            ? EqCapabilities.available
            : EqCapabilities.unavailable);
  }

  @override
  EqApplicationState get equalizerState => _equalizerController.value;

  @override
  Stream<EqApplicationState> get equalizerStateStream =>
      _equalizerController.stream;

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
    if (_isCrossfading) {
      final progress = _crossfadeFadeStartedAt == null
          ? 0.0
          : (DateTime.now()
                        .difference(_crossfadeFadeStartedAt!)
                        .inMilliseconds /
                    (_crossfadeDurationSeconds * 1000))
                .clamp(0.0, 1.0);
      await _player.setVolume(
        _replayGainVolumeFor(_resolveCurrentQueueMetadata().mediaItem) *
            (1 - progress),
      );
      final deck = _crossfadePlayer;
      if (deck != null) {
        await deck.setVolume(
          _replayGainVolumeFor(
                _queueItems.elementAtOrNull(
                  _crossfadeTargetIndex ?? _queueItems.length,
                ),
              ) *
              progress,
        );
      }
    } else {
      await _player.setVolume(
        _replayGainVolumeFor(_resolveCurrentQueueMetadata().mediaItem),
      );
    }
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

  @visibleForTesting
  void debugWireAudioSession(AudioSession session) =>
      _wireAudioSession(session);

  /// The observer of structural state before asynchronous delivery.
  ///
  /// Tests compare it with the native players at the instant of publication.
  @visibleForTesting
  void Function(PlaybackSnapshot)? debugSnapshotObserver;

  /// Whether no queue work, including idle releases and trims, is running
  /// or waiting.
  @visibleForTesting
  bool get debugQueueLaneIdle => _queueLane.isIdle;

  /// The player whose output is heard.
  @visibleForTesting
  AudioPlayer get debugActivePlayer => _player;

  /// The cross-fade deck, when cross-fade is on.
  @visibleForTesting
  AudioPlayer? get debugInactiveDeck => _crossfadePlayer;

  /// Prepares the cross-fade deck for the next song and starts it, as the
  /// position trigger would; [debugCompleteCrossfade] then hands over.
  @visibleForTesting
  Future<void> debugStartCrossfade() async {
    final next = _getNextEffectiveIndex();
    if (next == null) throw StateError('Nothing follows the current song.');
    await _startCrossfade(next, delayBeforeFade: Duration.zero);
  }

  /// Ends a started cross-fade now, as the end of the fade would.
  @visibleForTesting
  Future<void> debugCompleteCrossfade() => _completeCrossfade();

  /// Offers a cross-fade as a position tick at [position] would.
  @visibleForTesting
  void debugCheckCrossfadeTrigger(Duration position) =>
      _checkCrossfadeTrigger(position);

  /// Recovers the current remote song as the stall watchdog would.
  @visibleForTesting
  Future<void> debugRecoverCurrentSong() =>
      _recoverCurrentSongFromRemotePlaybackFailure(
        reason: 'remote playback stalled',
      );

  /// Writes coalesced queue and transport saves and waits for persistence.
  @visibleForTesting
  Future<void> debugFlushQueuePersistence() async {
    await _flushQueueItemsPersistence();
    if (_transportPersistTimer != null) {
      _transportPersistTimer?.cancel();
      _transportPersistTimer = null;
      await _persistSafely(
        _persistPosition,
        context: 'flush transport persistence',
      );
    }
    await _persistTail;
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
    // The aliases apply at once; the queue catches up as a queue edit nobody
    // waits for. Sync calls this from inside a database transaction (before
    // it remaps the rows, which also rewrites the saved queue), so waiting
    // for queue work there deadlocked: the edit queued behind work that read
    // the database, or saved the queue itself, while the transaction held it.
    for (final entry in normalized.entries) {
      _songIdentityAliases[entry.key] = _canonicalSongId(entry.value);
    }
    for (final key in _songIdentityAliases.keys.toList(growable: false)) {
      _songIdentityAliases[key] = _canonicalSongId(_songIdentityAliases[key]!);
    }
    unawaited(
      _enqueueQueueEdit((_) async {
        _remapQueueToCanonicalIds();
      }).catchError((Object error) {
        // A replacement discarded it; the new queue uses canonical rows.
        AppLogger.debug('Song identity queue remap skipped: $error');
      }),
    );
    return Future<void>.value();
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
      final targetMode = _shuffleEnabled
          ? AudioServiceShuffleMode.none
          : AudioServiceShuffleMode.all;
      return setShuffleMode(targetMode);
    }
    if (name == 'toggleLike') {
      return toggleLike();
    }
    return super.customAction(name, extras);
  }

  Future<void> Function(String) _preferredMixCallback;
  Future<void> Function(String) _preferredMixToggleCallback;

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

  Future<void> disposeHandler() => _disposeHandlerFuture ??= _disposeHandler();

  Future<void> _disposeHandler() async {
    _disposeHandlerStarted = true;
    final projectionDisposal = _detachNavisAudioServiceHandler(this);
    _artCache?.dispose();
    _cancelCrossfade();
    _cancelRemotePlaybackStallWatchdog();
    _positionPersistTimer?.cancel();
    _transportPersistTimer?.cancel();
    _radioStation = null;
    _radioMetadataService.dispose();
    await _disposeInactiveCrossfadeDeck();
    await _flushQueueItemsPersistence();
    await _sidecarDownloader.dispose();
    _sidecarSongsById.clear();
    _sidecarStreamUris.clear();
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
    await projectionDisposal;
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
  }

  void beginTeardown() {
    unawaited(disposeHandler());
    unawaited(_ensurePlayerDisposalStarted());
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
    if (!(_readRadioPlaybackAllowed?.call(Uri.parse(streamUrl)) ?? true)) {
      return Future<void>.error(const RadioPlaybackBlockedException());
    }
    _supersedeTransportIntent();
    final generation = _supersedeQueueWork(isLoading: true);
    return _queueLane.run((token) async {
      try {
        await _ready;
        _checkQueueWorkCurrent(token, generation);
        final streamUri = Uri.tryParse(streamUrl);
        if (streamUri == null || !isHostedHttpUri(streamUri)) {
          throw ArgumentError('Radio streams require a hosted HTTP(S) URL.');
        }

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

        // Invalidate old polls and ICY listeners before publishing the new
        // station, including while the new source is still loading.
        _radioMetadataService.stop();
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
          extras: <String, Object?>{'isRadio': true},
        );

        try {
          await _runTimedPlayerOperation(
            generation: generation,
            operation: 'radio source apply',
            action: () => _player.setAudioSource(
              AudioSource.uri(streamUri, tag: radioMediaItem),
            ),
            timeout: _playerLoadTimeout,
          );
        } on Object catch (error, stackTrace) {
          _checkQueueWorkCurrent(token, generation);
          AppLogger.error(
            'Failed to start radio stream on host=${Uri.tryParse(streamUrl)?.host}',
            error.runtimeType,
            stackTrace,
          );
          _radioMetadataService.stop();
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

        final azuraInfo = _tryExtractAzuracast(streamUrl);
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
        if (token.isCancelled || !_isActiveLoadGeneration(generation)) return;
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
              await _restorePreviousQueueAfterRadio(
                token,
                context: 'radio stop',
              );
            }),
          )
          .catchError((_) {}),
    );

    return stopPhase;
  }

  MediaItem _mediaItemForRadioStation(RadioStationMetadata station) =>
      MediaItem(
        id: 'radio:${station.stationId}',
        title: station.nowPlayingTitle ?? station.stationName,
        artist: station.nowPlayingArtist ?? station.stationName,
        artUri: station.nowPlayingArtUrl == null
            ? null
            : Uri.tryParse(station.nowPlayingArtUrl!),
        extras: <String, Object?>{'isRadio': true},
      );

  @override
  void updateRadioMetadata({
    String? title,
    String? artist,
    String? artUrl,
    bool replaceMetadata = false,
  }) {
    // The composition root calls this on policy changes, including re-enable.
    // Metadata replacements originate in the service itself; refreshing its
    // policy here would recursively apply the same fallback.
    if (!replaceMetadata) _radioMetadataService.refreshPolicy();

    final current = _radioStation;
    if (current == null) {
      return;
    }

    // Compute what the new RadioStationMetadata fields would be.
    final nextTitle = replaceMetadata
        ? title
        : title ?? current.nowPlayingTitle;
    final nextArtist = replaceMetadata
        ? artist
        : artist ?? current.nowPlayingArtist;
    final candidateArtUrl = replaceMetadata
        ? artUrl
        : artUrl ?? current.nowPlayingArtUrl;
    final candidateUri = candidateArtUrl == null
        ? null
        : Uri.tryParse(candidateArtUrl);
    final nextArtUrl =
        candidateUri != null &&
            isHostedHttpUri(candidateUri) &&
            (_readRadioArtworkAllowed?.call(candidateUri) ?? false)
        ? candidateArtUrl
        : null;

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
      nowPlayingTitle: nextTitle,
      nowPlayingArtist: nextArtist,
      nowPlayingArtUrl: nextArtUrl,
    );

    // Update the MediaItem for lock-screen / notification display. The art
    // URL was checked above; a refused one publishes no art, so the station
    // placeholder shows and AudioService has nothing to fetch.
    if (_queueReplacementMetadataAnchor == null) {
      _setCurrentMediaItem(_mediaItemForRadioStation(_radioStation!));
    }
    _broadcastPlaybackState();
    _emitSnapshot();
  }

  /// Attempt to extract an Azuracast base URL and station short name from the
  /// stream URL.
  ///
  /// Azuracast stream URLs follow the pattern:
  ///   `https://<host>/listen/<station_short_name>/<format>`
  ///
  /// Returns `(baseUrl, stationShortName)` or `null` if detection fails.
  static (String, String)? _tryExtractAzuracast(String streamUrl) {
    // Try parsing the stream URL for /listen/{station}/ or /hls/{station}/
    // pattern (both are valid Azuracast stream URL formats).
    final uri = Uri.tryParse(streamUrl);
    if (uri != null && isHostedHttpUri(uri) && uri.pathSegments.length >= 2) {
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

    return null;
  }
}
