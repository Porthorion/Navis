import 'dart:async';
import 'dart:math' as math;
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/database/daos/history_dao.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/daos/match_flow_dao.dart';
import 'package:navis/src/database/daos/playlist_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/daos/play_queue_dao.dart';
import 'package:navis/src/database/daos/star_sync_dao.dart';
import 'package:navis/src/database/tables/schema_enums.dart' as schema;
import 'package:navis/src/features/auto/data/auto_media_id.dart';
import 'package:navis/src/features/auto/data/auto_media_tree_service.dart';
import 'package:navis/src/features/auto/domain/android_auto_constants.dart';
import 'package:navis/src/features/cache/data/rolling_cache_manager.dart';
import 'package:navis/src/features/cache/data/rolling_cache_sidecar_downloader.dart';
import 'package:navis/src/features/player/data/playback_art_cache.dart';
import 'package:navis/src/features/player/data/listenbrainz_feedback_service.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/data/radio_metadata_service.dart';
import 'package:navis/src/features/player/data/scrobble_service.dart';
import 'package:navis/src/features/player/data/linux_mpris_bridge.dart';
import 'package:navis/src/features/player/data/windows_smtc_bridge.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/network_usage_meter.dart';

part 'navis_playback_handler_contract.dart';
part 'navis_playback_rules.dart';
part 'navis_audio_handler_bootstrap.dart';
part 'navis_playback_lanes.dart';
part 'navis_audio_handler_support.dart';

class NavisAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler
    implements NavisPlaybackHandler {
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
    NetworkUsageReporter? reportNetworkUsage,
    void Function(RollingCacheActivity activity)? reportRollingCacheActivity,
    AudioPlayer? player,
  }) : _libraryDao = libraryDao,
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
       _reportNetworkUsage = reportNetworkUsage,
       _reportRollingCacheActivity = reportRollingCacheActivity,
       _artCache = _isAndroidRuntime
           ? PlaybackArtCache(reportNetworkUsage: reportNetworkUsage)
           : null {
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
    _crossfadeEnabled = runtime.crossfadeEnabled;
    _crossfadePlayer = runtime.crossfadeEnabled
        ? _buildBaseAudioPlayer()
        : null;
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
    _autoMediaTreeService = AutoMediaTreeService(
      libraryDao: _libraryDao,
      playlistDao: _playlistDao,
      playQueueDao: _playQueueDao,
      historyDao: _historyDao,
      readApiClient: _readApiClient,
      readDownloadedSongIds: _rollingCacheManager.getPermanentlyCachedSongIds,
    );
  }

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
  late final AutoMediaTreeService _autoMediaTreeService;
  // Only instantiated on Android: downloads cover art to local files so that
  // audio_service can populate METADATA_KEY_ALBUM_ART on the MediaSession,
  // which AAOS uses for the background art behind playback controls.
  final PlaybackArtCache? _artCache;
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
  final StreamController<PlaybackBufferState> _bufferStateController =
      StreamController<PlaybackBufferState>.broadcast();

  final StreamController<void> _radioStreamErrorController =
      StreamController<void>.broadcast();
  final StreamController<PlaybackLoadFailure> _loadFailureController =
      StreamController<PlaybackLoadFailure>.broadcast();

  final List<MediaItem> _queueItems = <MediaItem>[];
  List<String>? _pendingLogicalQueueSongIds;
  MediaItem? _currentMediaItem;
  NavisQueueReplacementMetadataAnchor? _queueReplacementMetadataAnchor;

  PlaybackSnapshot _snapshot = const PlaybackSnapshot.idle();
  PlaybackBufferState _bufferState = const PlaybackBufferState.idle();
  Timer? _positionPersistTimer;
  late final Future<void> _ready;
  Future<bool>? _prepareQueueForUserPlayInFlight;
  _SupersedingLane _queueLane = _SupersedingLane();
  final _seekLane = _SupersedingLane();
  final _playbackLane = _SerializationLane();
  int _transportGeneration = 0;
  bool? _latestExplicitTransportPlaying;
  Timer? _transportPersistTimer;
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
  String? _remotePlaybackStallSongId;
  Duration? _remotePlaybackStallPosition;
  Duration? _remotePlaybackStallBufferedPosition;
  bool _remotePlaybackRecoveryInProgress = false;
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
  static const Duration _playerLoadTimeout = Duration(seconds: 12);
  static const Duration _remotePlaybackStallTimeout = Duration(seconds: 12);
  static const Duration _playerResetTimeout = Duration(seconds: 4);
  static const Duration _playerControlTimeout = Duration(seconds: 4);
  int _loadGeneration = 0;
  int _activeLoadGeneration = 0;
  String? _loadingSongId;
  String? _lastFailedSongId;
  bool _isLoading = false;

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
  Stream<PlaybackLoadFailure> get loadFailureStream =>
      _loadFailureController.stream;

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
        final songs = (await _libraryDao.watchAllSongs().first)
            .where((song) => downloadedSongIds.contains(song.id))
            .toList(growable: false);
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
          AutoMediaContextType.genre when parsed.contextId != null =>
            _libraryDao.watchSongsByGenre(parsed.contextId!).first,
          AutoMediaContextType.downloads => () async {
            final downloadedSongIds = await _rollingCacheManager
                .getPermanentlyCachedSongIds();
            return (await _libraryDao.watchAllSongs().first)
                .where((item) => downloadedSongIds.contains(item.id))
                .toList(growable: false);
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
      case AutoMediaIdType.genre:
        final songs = await _libraryDao
            .watchSongsByGenre(parsed.entityId!)
            .first;
        if (songs.isEmpty) return false;
        await replaceQueueWithData(
          songs,
          autoPlay: autoPlay,
          expandMatchFlows: false,
        );
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
      case NavisAndroidAutoSearchType.genre:
        final songs = await _libraryDao.watchSongsByGenre(request.term).first;
        if (songs.isNotEmpty) {
          await replaceQueueWithData(songs, autoPlay: autoPlay);
          return _queueItems.isNotEmpty;
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
    // Pass URLs directly to libmpv so lavf's cache:// protocol gets the
    // original HTTPS stream rather than a local proxy, eliminating the
    // "[error] lavf: Failed to create file cache" log noise. Subsonic auth
    // is embedded in URL query params so no custom headers are needed.
    return AudioPlayer(
      audioPipeline: audioPipeline,
      userAgent: _isDesktopRuntime ? 'Navis Desktop' : null,
      useProxyForRequestHeaders: !_isDesktopRuntime,
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

  int _supersedeQueueWork({
    bool isLoading = false,
    String? loadingSongId,
    List<String>? pendingLogicalQueueSongIds,
  }) {
    _clearQueueReplacementMetadataAnchor();
    _pendingLogicalQueueSongIds = pendingLogicalQueueSongIds == null
        ? null
        : List<String>.unmodifiable(pendingLogicalQueueSongIds);
    _queueLane.cancelCurrent();
    _queueLane = _SupersedingLane();
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
    _isLoading = false;
    _loadingSongId = null;
    _clearPendingLogicalQueue();
    if (loadingSongId != null && failed) {
      _lastFailedSongId = loadingSongId;
    }
    _emitSnapshot();
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
    if (!_isActiveLoadGeneration(generation)) {
      return;
    }
    AppLogger.warning(
      'Recovering audio players after timeout in $operation '
      '(song=${songId ?? 'n/a'} generation=$generation).',
    );
    _cancelCrossfade();
    await _disposePlayerListeners();

    final previousPlayer = _player;
    final previousInactiveDeck = _crossfadePlayer;
    final previousVolume = previousPlayer.volume;
    final previousSpeed = previousPlayer.speed;
    final previousLoopMode = previousPlayer.loopMode;
    final previousShuffleModeEnabled = previousPlayer.shuffleModeEnabled;

    _player = _buildAudioPlayer(enableAndroidDsp: _androidDspPipelineEnabled);
    _wirePlayerListeners();
    _rebindRadioMetadataServiceToActivePlayer();

    try {
      await _player.setVolume(previousVolume).timeout(_playerResetTimeout);
      await _player.setSpeed(previousSpeed).timeout(_playerResetTimeout);
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

    _crossfadePlayer = _crossfadeEnabled ? _buildBaseAudioPlayer() : null;
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
        await inactiveDeck.setSpeed(previousSpeed).timeout(_playerResetTimeout);
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
    Duration timeout = _playerLoadTimeout,
  }) async {
    _lastFailedSongId = null;
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
      if (!_isActiveLoadGeneration(generation)) {
        throw OperationCancelledException();
      }
      return result;
    } on TimeoutException {
      timedOut = true;
      _lastFailedSongId = songId;
      if (songId != null) {
        _markSongLockCachingBypassed(
          songId,
          reason: 'player operation "$operation" timed out',
        );
      }
      _emitLoadFailure(
        operation: operation,
        message: 'Playback operation timed out after ${timeout.inSeconds}s.',
        songId: songId,
        isTimeout: true,
      );
      await _recoverPlayersFromTimeout(
        generation: generation,
        operation: operation,
        songId: songId,
      );
      throw PlaybackLoadTimeoutException(
        operation: operation,
        songId: songId,
        timeoutDuration: timeout,
      );
    }
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

  void _wirePlayerListeners() {
    _emitBufferState(
      songId: _radioStation == null ? _currentMediaItem?.id : null,
      bufferedPosition: Duration.zero,
      force: true,
    );
    _playbackEventSubscription = _player.playbackEventStream.listen(
      (_) {
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
    await player.setSpeed(_player.speed);
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
        forcePreloadWhenPaused: true,
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
        await _rebuildPlayerWithoutAndroidDsp(force: true);
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
        await _rebuildPlayerWithoutAndroidDsp(force: true);
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
    final prepared = <_PreparedQueueItem>[];
    for (final song in songs) {
      prepared.add(
        await _prepareSingleItem(song, preferLockCaching: preferLockCaching),
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

  /// Resolve a single song's playback source with the standard fallback chain
  /// (lock-caching → direct stream).
  Future<_PreparedQueueItem> _prepareSingleItem(
    SongsTableData song, {
    required bool preferLockCaching,
  }) async {
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
    if (source.sidecarCacheFilePath != null) {
      _rememberSidecarSong(song);
    }
    return _PreparedQueueItem(
      song: song,
      source: source,
      mediaItem: item,
      audioSource: source.asAudioSource(tag: item),
    );
  }

  Future<_PreparedQueueItem?> _prepareSingleItemForQueueFill(
    SongsTableData song,
  ) async {
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
  }) async {
    if (songs.isEmpty) {
      await _clearQueueInternal(persist: persist);
      return null;
    }

    final clampedIndex = startIndex.clamp(0, songs.length - 1);
    final startSong = songs[clampedIndex];

    // Resolve the target song's playback source.
    _PreparedQueueItem startItem;
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

    // Phase 1 loads only the start song's audio source into the player at
    // index 0.  _queueItems must contain only that one item so that the
    // currentIndexStream listener (which fires at index 0 immediately after
    // setAudioSource) maps index 0 → startItem.mediaItem, not the first
    // album track.  Phase 2 will insert/append the remaining items.
    _queueItems.clear();
    _queueItems.add(startItem.mediaItem);
    if (songs.length > 1) {
      _setQueueReplacementMetadataAnchor(
        expectedIndex: clampedIndex,
        mediaItem: startItem.mediaItem,
      );
    }

    // Set a single audio source on the player and start playback.
    _checkQueueWorkCurrent(token, generation);
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

    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _setCurrentMediaItem(startItem.mediaItem);

    if (autoPlay) {
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
  }) async {
    final clampedIndex = startIndex.clamp(0, songs.length - 1);

    // Collect songs that still need resolution (everything except startIndex).
    final beforeStart = songs.sublist(0, clampedIndex);
    final afterStart = clampedIndex + 1 < songs.length
        ? songs.sublist(clampedIndex + 1)
        : <SongsTableData>[];

    // We need to rebuild the player's audio source list to include all songs
    // in the correct order.  First, resolve sources for the remaining songs.
    const batchSize = 5;
    final preparedByIndex = <int, _PreparedQueueItem>{
      clampedIndex: startItem,
    };
    final skippedSongIds = <String>[];

    AppLogger.debug(
      'Queue replacement phase 2 start: requested=${songs.length} '
      'startIndex=$clampedIndex song=${startItem.song.id}',
    );

    // Resolve songs before the start index and insert them before the current
    // position.  _queueItems is intentionally NOT updated during these inserts:
    // the playbackEventStream fires position ticks on every event loop turn,
    // and any _emitSnapshot() call between _queueItems.insert() and the player
    // acknowledging the new currentIndex would produce a stale snapshot.
    // Keeping _queueItems=[startSong] throughout Phase 2 lets the metadata
    // anchor keep the display on the tapped song until _queueItems is rebuilt
    // atomically from allPrepared at the very end.
    var insertedBeforeCount = 0;
    for (var i = 0; i < beforeStart.length; i += batchSize) {
      _checkQueueWorkCurrent(token, generation);
      final batchEnd = math.min(i + batchSize, beforeStart.length);
      final batch = beforeStart.sublist(i, batchEnd);
      final prepared = <_PreparedQueueItem>[];
      for (var j = 0; j < batch.length; j++) {
        final originalIndex = i + j;
        final item = await _prepareSingleItemForQueueFill(batch[j]);
        if (item == null) {
          skippedSongIds.add(batch[j].id);
          continue;
        }
        preparedByIndex[originalIndex] = item;
        prepared.add(item);
      }

      _checkQueueWorkCurrent(token, generation);
      for (var j = 0; j < prepared.length; j++) {
        final positionBeforeMutation = _player.position;
        final wasPlayingBeforeMutation = _player.playing;
        try {
          await _runTimedPlayerOperation(
            generation: generation,
            operation: 'replace queue insert before',
            action: () => _player.insertAudioSource(
              insertedBeforeCount,
              prepared[j].audioSource,
            ),
            songId: prepared[j].song.id,
          );
        } on PlaybackLoadTimeoutException catch (error) {
          skippedSongIds.add(prepared[j].song.id);
          await _restoreStartItemAfterQueueFillTimeout(
            startItem: startItem,
            position: positionBeforeMutation,
            autoPlay: wasPlayingBeforeMutation,
            generation: generation,
            failedSongId: error.songId ?? prepared[j].song.id,
          );
          return;
        } on Object catch (error, stackTrace) {
          skippedSongIds.add(prepared[j].song.id);
          _markSongLockCachingBypassed(
            prepared[j].song.id,
            reason: 'queue fill insert failed',
          );
          AppLogger.warning(
            'Queue fill insert failed for song=${prepared[j].song.id}; '
            'skipping. $error\n$stackTrace',
          );
          continue;
        }
        insertedBeforeCount++;
        _checkQueueWorkCurrent(token, generation);
      }
      _observeLockCacheForPrepared(prepared);
    }

    // Resolve songs after the start index and append them.
    for (var i = 0; i < afterStart.length; i += batchSize) {
      _checkQueueWorkCurrent(token, generation);
      final batchEnd = math.min(i + batchSize, afterStart.length);
      final batch = afterStart.sublist(i, batchEnd);
      final prepared = <_PreparedQueueItem>[];
      for (var j = 0; j < batch.length; j++) {
        final originalIndex = clampedIndex + 1 + i + j;
        final item = await _prepareSingleItemForQueueFill(batch[j]);
        if (item == null) {
          skippedSongIds.add(batch[j].id);
          continue;
        }
        preparedByIndex[originalIndex] = item;
        prepared.add(item);
      }

      _checkQueueWorkCurrent(token, generation);
      for (var j = 0; j < prepared.length; j++) {
        final positionBeforeMutation = _player.position;
        final wasPlayingBeforeMutation = _player.playing;
        try {
          await _runTimedPlayerOperation(
            generation: generation,
            operation: 'replace queue append after',
            action: () => _player.addAudioSource(prepared[j].audioSource),
            songId: prepared[j].song.id,
          );
        } on PlaybackLoadTimeoutException catch (error) {
          skippedSongIds.add(prepared[j].song.id);
          await _restoreStartItemAfterQueueFillTimeout(
            startItem: startItem,
            position: positionBeforeMutation,
            autoPlay: wasPlayingBeforeMutation,
            generation: generation,
            failedSongId: error.songId ?? prepared[j].song.id,
          );
          return;
        } on Object catch (error, stackTrace) {
          skippedSongIds.add(prepared[j].song.id);
          _markSongLockCachingBypassed(
            prepared[j].song.id,
            reason: 'queue fill append failed',
          );
          AppLogger.warning(
            'Queue fill append failed for song=${prepared[j].song.id}; '
            'skipping. $error\n$stackTrace',
          );
          continue;
        }
        _checkQueueWorkCurrent(token, generation);
      }
      _observeLockCacheForPrepared(prepared);
    }

    // Build the prepared list in album order for two purposes:
    // (a) syncing the crossfade inactive deck, and
    // (b) atomically rebuilding _queueItems now that all inserts are done.
    final allPrepared = <_PreparedQueueItem>[];
    for (var i = 0; i < songs.length; i++) {
      final prepared = preparedByIndex[i];
      if (prepared != null) allPrepared.add(prepared);
    }
    final preparedStartIndex = allPrepared.indexWhere(
      (item) => item.song.id == startItem.song.id,
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

    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _broadcastPlaybackState();
    _emitSnapshot();

    AppLogger.debug(
      'Queue replacement phase 2 complete: requested=${songs.length} '
      'prepared=${allPrepared.length} skipped=${skippedSongIds.length} '
      'skippedIds=${skippedSongIds.join(',')}',
    );

    if (persist) {
      await _persistSafely(
        () => _persistQueueState(includeQueueItems: true),
        context: 'queue replacement (phase 2)',
      );
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

  Future<void> _restoreStartItemAfterQueueFillTimeout({
    required _PreparedQueueItem startItem,
    required Duration position,
    required bool autoPlay,
    required int generation,
    required String failedSongId,
  }) async {
    _lastFailedSongId = failedSongId;
    _clearPendingLogicalQueue();
    _clearQueueReplacementMetadataAnchor();
    _queueItems
      ..clear()
      ..add(startItem.mediaItem);
    await _setAudioSourcesWithFallback(
      audioSources: <AudioSource>[
        startItem.source.asClonedAudioSource(tag: startItem.mediaItem),
      ],
      preload: true,
      initialIndex: 0,
      initialPosition: position,
      generation: generation,
      songId: startItem.song.id,
    );
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _setCurrentMediaItem(startItem.mediaItem);
    if (autoPlay) {
      unawaited(_player.play());
    } else {
      await _player.pause();
    }
    _broadcastPlaybackState();
    _emitSnapshot();
    await _persistSafely(
      () => _persistQueueState(includeQueueItems: true),
      context: 'queue fill timeout restore',
    );
    AppLogger.warning(
      'Queue fill timed out for song=$failedSongId. Restored active start '
      'song=${startItem.song.id} so playback does not remain stuck.',
    );
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
    await inactiveDeck.setSpeed(_player.speed);
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
      await _rebuildPlayerWithoutAndroidDsp(force: true);
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
        await _rebuildPlayerWithoutAndroidDsp(force: true);
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
    _crossfadePlayer = _crossfadeEnabled ? _buildBaseAudioPlayer() : null;
  }

  @override
  Future<void> replaceQueue(
    List<String> songIds, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
  }) async {
    _supersedeTransportIntent();
    songIds = songIds.map(_canonicalSongId).toList(growable: false);
    final requestedStartIndex = songIds.isEmpty
        ? 0
        : startIndex.clamp(0, songIds.length - 1);
    _supersedeQueueWork(
      isLoading: songIds.isNotEmpty,
      loadingSongId: songIds.isEmpty ? null : songIds[requestedStartIndex],
      pendingLogicalQueueSongIds: songIds.length > 1 ? songIds : null,
    );
    final expansion = await _expandMatchFlowIds(
      songIds,
      startIndex: startIndex,
      expandMatchFlows: expandMatchFlows,
    );
    songIds = expansion.songIds;
    startIndex = expansion.startIndex;
    final normalizedStartIndex = songIds.isEmpty
        ? 0
        : startIndex.clamp(0, songIds.length - 1);
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

        final startItem = await _replaceQueuePhase1(
          songs: songs,
          startIndex: normalizedStartIndex,
          autoPlay: autoPlay,
          persist: false,
          generation: generation,
          token: token,
        );

        if (startItem == null || songs.length <= 1) {
          await _persistSafely(
            () => _persistQueueState(includeQueueItems: true),
            context: 'queue replacement (single song)',
          );
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
        );
        _completeQueueLoad(generation);
      } on OperationCancelledException {
        AppLogger.debug(
          'replaceQueue cancelled — superseded by newer command.',
        );
      } on PlaybackLoadTimeoutException catch (error) {
        _completeQueueLoad(
          generation,
          loadingSongId: error.songId ?? loadingSongId,
          failed: true,
        );
        if ((error.songId ?? loadingSongId) == loadingSongId) {
          final nextIndex = _nextPlayableIndexAfterFailure(
            normalizedStartIndex,
            songIds.length,
          );
          if (nextIndex != null) {
            unawaited(
              replaceQueue(
                songIds,
                startIndex: nextIndex,
                autoPlay: autoPlay,
                expandMatchFlows: false,
              ),
            );
          }
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
    _supersedeTransportIntent();
    final canonicalIds = songs
        .map((song) => _canonicalSongId(song.id))
        .toList(growable: false);
    final requestedStartIndex = canonicalIds.isEmpty
        ? 0
        : startIndex.clamp(0, canonicalIds.length - 1);
    _supersedeQueueWork(
      isLoading: canonicalIds.isNotEmpty,
      loadingSongId: canonicalIds.isEmpty
          ? null
          : canonicalIds[requestedStartIndex],
      pendingLogicalQueueSongIds: canonicalIds.length > 1 ? canonicalIds : null,
    );
    final hasRetiredIdentity = Iterable<int>.generate(
      songs.length,
    ).any((index) => canonicalIds[index] != songs[index].id);
    if (hasRetiredIdentity) {
      final canonicalSongs = await _libraryDao.getSongsByIds(canonicalIds);
      return replaceQueueWithData(
        canonicalSongs,
        startIndex: startIndex,
        autoPlay: autoPlay,
        expandMatchFlows: expandMatchFlows,
      );
    }
    if (expandMatchFlows && songs.isNotEmpty) {
      final expansion = await _expandMatchFlowIds(
        songs.map((song) => song.id).toList(growable: false),
        startIndex: startIndex,
        expandMatchFlows: true,
      );
      final expandedSongs = await _libraryDao.getSongsByIds(expansion.songIds);
      return replaceQueueWithData(
        expandedSongs,
        startIndex: expansion.startIndex,
        autoPlay: autoPlay,
        expandMatchFlows: false,
      );
    }
    final normalizedStartIndex = songs.isEmpty
        ? 0
        : startIndex.clamp(0, songs.length - 1);
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

        if (startItem == null || songs.length <= 1) {
          await _persistSafely(
            () => _persistQueueState(includeQueueItems: true),
            context: 'queue replacement with data (single song)',
          );
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
        );
        _completeQueueLoad(generation);
      } on OperationCancelledException {
        AppLogger.debug(
          'replaceQueueWithData cancelled — superseded by newer command.',
        );
      } on PlaybackLoadTimeoutException catch (error) {
        _completeQueueLoad(
          generation,
          loadingSongId: error.songId ?? loadingSongId,
          failed: true,
        );
        if ((error.songId ?? loadingSongId) == loadingSongId) {
          final nextIndex = _nextPlayableIndexAfterFailure(
            normalizedStartIndex,
            songs.length,
          );
          if (nextIndex != null) {
            unawaited(
              replaceQueueWithData(
                songs,
                startIndex: nextIndex,
                autoPlay: autoPlay,
                expandMatchFlows: false,
              ),
            );
          }
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
    return _queueLane.run((token) async {
      await _ready;
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

      // Prepare only the new songs and append their audio sources
      // incrementally – this does NOT interrupt current playback.
      final prepared = await _prepareQueueItemsFromIds(songIds);
      if (prepared.isEmpty) return;

      token.checkCancelled();

      final generation = _activeLoadGeneration;
      final inserted = <_PreparedQueueItem>[];
      final wasPlayingBeforeMutation = _player.playing;
      final firstInsertedIndex = _queueItems.length;
      final queueWasCompletedBeforeInsertion =
          _player.processingState == ProcessingState.completed;
      for (final entry in prepared) {
        await _runTimedPlayerOperation(
          generation: generation,
          operation: 'add to queue append',
          action: () => _player.addAudioSource(entry.audioSource),
          songId: entry.song.id,
        );
        _queueItems.add(entry.mediaItem);
        final inactiveDeck = _crossfadePlayer;
        if (inactiveDeck != null) {
          try {
            await _runTimedPlayerOperation(
              generation: generation,
              operation: 'add to queue inactive append',
              action: () => inactiveDeck.addAudioSource(
                entry.source.asClonedAudioSource(tag: entry.mediaItem),
              ),
              songId: entry.song.id,
            );
          } on Object catch (error) {
            AppLogger.debug(
              'addToQueue inactive deck append failed for ${entry.song.id}: '
              '$error',
            );
          }
        }
        inserted.add(entry);
        token.checkCancelled();
      }

      await _resumeInsertedItemIfCompleted(
        wasPlayingBeforeMutation: wasPlayingBeforeMutation,
        queueWasCompletedBeforeInsertion: queueWasCompletedBeforeInsertion,
        firstInsertedIndex: firstInsertedIndex,
      );

      if (inserted.isEmpty) {
        return;
      }

      _observeLockCacheForPrepared(inserted);
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
  Future<void> playNext(
    List<String> songIds, {
    bool expandMatchFlows = true,
  }) {
    return _queueLane.run((token) async {
      await _ready;
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

      // Prepare only the new songs and insert their audio sources
      // incrementally at the position right after the currently playing item.
      final prepared = await _prepareQueueItemsFromIds(incoming);
      if (prepared.isEmpty) return;

      token.checkCancelled();

      // Insert in reverse order at the same position so relative order is
      // preserved (first incoming song ends up right after current).
      final generation = _activeLoadGeneration;
      final inserted = <_PreparedQueueItem>[];
      final wasPlayingBeforeMutation = _player.playing;
      final currentIndex = (_player.currentIndex ?? 0).clamp(
        0,
        _queueItems.length - 1,
      );
      final insertAt = (currentIndex + 1).clamp(0, _queueItems.length);
      final queueWasCompletedBeforeInsertion =
          _player.processingState == ProcessingState.completed;
      for (var i = prepared.length - 1; i >= 0; i--) {
        final entry = prepared[i];
        try {
          await _runTimedPlayerOperation(
            generation: generation,
            operation: 'play next insert',
            action: () =>
                _player.insertAudioSource(insertAt, entry.audioSource),
            songId: entry.song.id,
          );
        } on Object catch (error) {
          if (inserted.isEmpty) {
            rethrow;
          }
          AppLogger.debug(
            'playNext stopped after partial insert: '
            'inserted=${inserted.length} remaining=${i + 1} error=$error',
          );
          break;
        }
        _queueItems.insert(insertAt, entry.mediaItem);
        final inactiveDeck = _crossfadePlayer;
        if (inactiveDeck != null) {
          try {
            await _runTimedPlayerOperation(
              generation: generation,
              operation: 'play next inactive insert',
              action: () => inactiveDeck.insertAudioSource(
                insertAt,
                entry.source.asClonedAudioSource(
                  tag: entry.mediaItem,
                ),
              ),
              songId: entry.song.id,
            );
          } on Object catch (error) {
            AppLogger.debug(
              'playNext inactive deck insert failed for ${entry.song.id}: '
              '$error',
            );
          }
        }
        inserted.add(entry);
        token.checkCancelled();
      }

      await _resumeInsertedItemIfCompleted(
        wasPlayingBeforeMutation: wasPlayingBeforeMutation,
        queueWasCompletedBeforeInsertion: queueWasCompletedBeforeInsertion,
        firstInsertedIndex: insertAt,
      );

      if (inserted.isEmpty) {
        return;
      }

      _observeLockCacheForPrepared(inserted);
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

        if (_queueItems.length == 1 && currentIndex == 0) {
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
    _supersedeTransportIntent();
    final loadingSongId = index >= 0 && index < _queueItems.length
        ? _queueItems[index].id
        : null;
    final generation = _supersedeQueueWork(
      isLoading: loadingSongId != null,
      loadingSongId: loadingSongId,
    );
    return _queueLane.run((token) async {
      try {
        await _ready;
        _checkQueueWorkCurrent(token, generation);
        if (index < 0 || index >= _queueItems.length) {
          _completeQueueLoad(generation);
          return;
        }
        await _runTimedPlayerOperation(
          generation: generation,
          operation: 'play from index seek',
          action: () => _player.seek(Duration.zero, index: index),
          songId: loadingSongId,
          timeout: _playerControlTimeout,
        );
        final inactiveDeck = _crossfadePlayer;
        if (inactiveDeck != null && inactiveDeck.sequence.length > index) {
          await _runTimedPlayerOperation(
            generation: generation,
            operation: 'play from index inactive seek',
            action: () => inactiveDeck.seek(Duration.zero, index: index),
            songId: loadingSongId,
            timeout: _playerControlTimeout,
          );
        }
        _checkQueueWorkCurrent(token, generation);
        unawaited(_player.play());
        await _persistSafely(_persistQueueState, context: 'play from index');
        _completeQueueLoad(generation);
      } on OperationCancelledException {
        AppLogger.debug(
          'playFromIndex cancelled — superseded by newer command.',
        );
      } on PlaybackLoadTimeoutException {
        _completeQueueLoad(
          generation,
          loadingSongId: loadingSongId,
          failed: true,
        );
        final nextIndex = _nextPlayableIndexAfterFailure(
          index,
          _queueItems.length,
        );
        if (nextIndex != null) {
          unawaited(playFromIndex(nextIndex));
        }
      } on Object {
        _completeQueueLoad(generation);
        rethrow;
      }
    });
  }

  @override
  Future<void> removeAt(int index) {
    return _queueLane.run((_) async {
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
    return _queueLane.run((_) async {
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
    _supersedeTransportIntent();
    _cancelCrossfade();
    final generation = _supersedeQueueWork();
    return _queueLane.run((token) async {
      await _ready;
      _checkQueueWorkCurrent(token, generation);
      await _clearQueueInternal(persist: true, generation: generation);
      _completeQueueLoad(generation);
    });
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
    _supersedeTransportIntent(shouldPlay: true);
    await _ready;

    if (_radioStation == null && _queueItems.isEmpty) {
      final prepared = await _prepareBestAvailableQueueForUserPlay();
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
        _queueItems.isNotEmpty) {
      await _player.seek(Duration.zero, index: 0);
      final inactiveDeck = _crossfadePlayer;
      if (inactiveDeck != null) {
        await inactiveDeck.seek(Duration.zero, index: 0);
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
    _supersedeTransportIntent(shouldPlay: false);
    await _ready;
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
      final inactiveDeck = _buildBaseAudioPlayer();
      _crossfadePlayer = inactiveDeck;
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
        _scheduleTransportPersistence(context: 'seek');
      }
    });
  }

  @override
  Map<String, Object?> collectPlaybackDiagnostics() {
    final snapshot = _snapshot;
    final songId = snapshot.currentSongId;
    final cacheActivity = _rollingCacheActivities.values.lastOrNull;
    final partialCacheBytes = _partialCacheBytesForSong(songId);
    return <String, Object?>{
      'songId': songId,
      'playing': snapshot.playing,
      'processingState': snapshot.processingState.name,
      'isLoading': snapshot.isLoading,
      'loadingSongId': snapshot.loadingSongId,
      'positionMs': snapshot.position.inMilliseconds,
      'bufferedPositionMs': snapshot.bufferedPosition.inMilliseconds,
      'durationMs': snapshot.duration.inMilliseconds,
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
      'seekEvents': List<Map<String, Object?>>.from(_seekDiagnosticsEvents),
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
  Future<void> skipToNext() {
    _supersedeTransportIntent();
    return _playbackLane.run(() async {
      await _ready;
      _cancelCrossfade();
      final currentIndex =
          _resolveCurrentQueueMetadata().currentIndex ?? _player.currentIndex;
      if (!navisCanSkipQueueItem(
        queueLength: _queueItems.length,
        currentIndex: currentIndex,
        forward: true,
      )) {
        return;
      }
      _emitManualTrackChangeCue(
        ManualTrackChangeDirection.next,
        fromSongId: _snapshot.currentSongId,
      );
      _clearQueueReplacementMetadataAnchor();
      await _player.seekToNext();
      _scheduleTransportPersistence(context: 'skip next');
    });
  }

  @override
  Future<void> skipToPrevious() {
    _supersedeTransportIntent();
    return _playbackLane.run(() async {
      await _ready;
      _cancelCrossfade();
      final currentIndex =
          _resolveCurrentQueueMetadata().currentIndex ?? _player.currentIndex;
      final action = navisResolvePreviousTrackAction(
        queueLength: _queueItems.length,
        currentIndex: currentIndex,
        position: _player.position,
      );
      switch (action) {
        case NavisPreviousTrackAction.none:
          return;
        case NavisPreviousTrackAction.restartCurrent:
          _clearQueueReplacementMetadataAnchor();
          await _player.seek(Duration.zero);
          _scheduleTransportPersistence(context: 'skip previous restart');
          return;
        case NavisPreviousTrackAction.skipToPrevious:
          _emitManualTrackChangeCue(
            ManualTrackChangeDirection.previous,
            fromSongId: _snapshot.currentSongId,
          );
          _clearQueueReplacementMetadataAnchor();
          await _player.seekToPrevious();
          _scheduleTransportPersistence(context: 'skip previous');
      }
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
    _supersedeTransportIntent(shouldPlay: false);
    await _ready;
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
    return _queueLane.run((_) async {
      await _ready;
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
    final resolvedCurrentIndex = _radioStation == null
        ? _resolveCurrentQueueMetadata().currentIndex
        : null;

    if (includeQueueItems) {
      await _playQueueDao.saveQueue(
        currentIndex: resolvedCurrentIndex,
        songIds: _queueItems.map((item) => item.id).toList(growable: false),
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
      queueLength: _radioStation == null ? _queueItems.length : 0,
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
      repeatMode: _mapRepeatMode(_player.loopMode),
      shuffleMode: _player.shuffleModeEnabled
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
    );
    playbackState.add(state);
  }

  Future<void> _notifyAndroidAutoBrowseRefresh() async {
    if (!_isAndroidRuntime) {
      return;
    }
    try {
      await AudioServiceBackground.notifyChildrenChanged();
      await AudioServiceBackground.notifyChildrenChanged(AutoMediaRoot.recent);
      await AudioServiceBackground.notifyChildrenChanged(
        AudioService.recentRootId,
      );
      AppLogger.info('Android Auto browse roots refresh requested.');
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Android Auto browse refresh request failed: $error\n$stackTrace',
      );
    }
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
    final queueToken = songId == null ? null : '${currentIndex ?? -1}:$songId';

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
    final resolved = _resolveCurrentQueueMetadata();
    final currentItem = resolved.mediaItem;
    final isLiked = currentItem?.extras?['liked'] as bool? ?? false;
    final nextSnapshot = PlaybackSnapshot(
      queueSongIds: _radioStation != null
          ? const <String>[]
          : _pendingLogicalQueueSongIds ??
                _queueItems.map((item) => item.id).toList(growable: false),
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
      repeatMode: _mapRepeatMode(_player.loopMode),
      isCurrentSongLiked: _radioStation == null && isLiked,
      radioStation: _radioStation,
      isLoading: _isLoading,
      hasPendingLogicalQueue:
          _radioStation == null && _pendingLogicalQueueSongIds != null,
      loadingSongId: _loadingSongId,
      lastFailedSongId: _lastFailedSongId,
    );
    final shouldBroadcast = !navisPlaybackSnapshotsStructurallyEqual(
      _snapshot,
      nextSnapshot,
    );
    _snapshot = nextSnapshot;
    if (!shouldBroadcast) {
      return;
    }
    if (!_snapshotController.isClosed) {
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

    final mediaItem = item;
    final fileSource = AudioSource.uri(
      Uri.file(cacheFile.path),
      tag: mediaItem,
    );
    final previousLoopMode = _player.loopMode;
    final previousShuffle = _player.shuffleModeEnabled;
    final queueGeneration = _supersedeQueueWork(
      isLoading: true,
      loadingSongId: song.id,
    );
    try {
      await _queueLane.run((queueToken) async {
        _checkQueueWorkCurrent(queueToken, queueGeneration);
        token.checkCancelled();
        if (!_isCurrentTransportIntent(transportGeneration)) {
          return;
        }
        await _setAudioSourcesWithFallback(
          audioSources: <AudioSource>[fileSource],
          preload: true,
          initialIndex: 0,
          initialPosition: position,
          generation: queueGeneration,
          songId: song.id,
        );
        _queueItems
          ..clear()
          ..add(
            mediaItem.copyWith(
              extras: <String, Object?>{
                ...?mediaItem.extras,
                'sourceKind': PlaybackSourceKind.file.name,
                'localSource': true,
                'cachedFilePath': cacheFile.path,
              },
            ),
          );
        queue.add(List<MediaItem>.unmodifiable(_queueItems));
        _setCurrentMediaItem(_queueItems.first);
      });
    } on Object catch (error, stackTrace) {
      AppLogger.debug(
        'Sidecar file seek fallback failed for ${song.id}: '
        '$error\n$stackTrace',
      );
      _completeQueueLoad(queueGeneration, loadingSongId: song.id, failed: true);
      return false;
    }
    token.checkCancelled();
    if (!_isCurrentTransportIntent(transportGeneration)) {
      return true;
    }
    await _player.setLoopMode(previousLoopMode);
    await _player.setShuffleModeEnabled(previousShuffle);
    final landed = _player.position;
    if ((position - landed).abs() >= const Duration(seconds: 2)) {
      await _player.seek(position);
    }
    if (autoPlay) {
      unawaited(_player.play());
    }
    _completeQueueLoad(queueGeneration);
    return true;
  }

  Future<void> _rebuildQueueForSeekRecovery(
    Duration position, {
    required bool autoPlay,
    required OperationToken token,
    required int transportGeneration,
    String reason = 'seek recovery — switched to direct stream',
  }) async {
    final currentIndex = _resolveCurrentQueueMetadata().currentIndex;
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

    final previousLoopMode = _player.loopMode;
    final previousShuffleModeEnabled = _player.shuffleModeEnabled;

    // Prefer a one-shot direct-stream rebuild for this seek. Do not permanently
    // bypass lock-caching for the song: desktop now uses sidecar caching with
    // native HTTPS seeks, and mobile lock-cache can still serve later plays.
    final currentSongId = _queueItems[currentIndex].id;

    token.checkCancelled();
    if (!_isCurrentTransportIntent(transportGeneration)) {
      return;
    }
    final queueGeneration = _supersedeQueueWork(
      isLoading: true,
      loadingSongId: currentSongId,
      pendingLogicalQueueSongIds: queueSongIds.length > 1 ? queueSongIds : null,
    );
    _PreparedQueueItem? startItem;
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
      );
    });
    token.checkCancelled();
    if (!_isCurrentTransportIntent(transportGeneration)) {
      final shouldPlay = _latestExplicitTransportPlaying;
      if (shouldPlay == true) {
        unawaited(_player.play());
      } else if (shouldPlay == false) {
        await _player.pause();
      }
      return;
    }
    await _player.setLoopMode(previousLoopMode);
    await _player.setShuffleModeEnabled(previousShuffleModeEnabled);
    // media_kit can drop initialPosition; correct before resuming playback.
    final landed = _player.position;
    if ((position - landed).abs() >= const Duration(seconds: 2)) {
      await _player.seek(position);
      token.checkCancelled();
      if (!_isCurrentTransportIntent(transportGeneration)) {
        return;
      }
    }
    if (autoPlay) {
      unawaited(_player.play());
    }
    final recoveredStartItem = startItem;
    if (recoveredStartItem == null || orderedSongs.length <= 1) {
      _completeQueueLoad(queueGeneration);
      return;
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

  Future<void> _recoverCurrentSongFromRemotePlaybackFailure({
    required String reason,
    Object? error,
    StackTrace? stackTrace,
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

    _remotePlaybackRecoveryInProgress = true;
    _cancelRemotePlaybackStallWatchdog();
    final songId = _queueItems[currentIndex].id;
    final autoPlay = _player.playing;
    final position = _player.position;
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
      if (sourceKind == PlaybackSourceKind.lockCachedStream.name) {
        try {
          final recoveryToken = OperationToken();
          final recoveryTransportGeneration = _transportGeneration;
          await _rebuildQueueForSeekRecovery(
            position,
            autoPlay: autoPlay,
            token: recoveryToken,
            transportGeneration: recoveryTransportGeneration,
            reason: '$reason — switched to direct stream',
          );
          return;
        } on Object catch (rebuildError, rebuildStackTrace) {
          AppLogger.warning(
            'Remote playback direct-stream rebuild failed for song=$songId. '
            '$rebuildError\n$rebuildStackTrace',
          );
        }
      }

      await _skipPastFailedRemoteSong(currentIndex, autoPlay: autoPlay);
    } finally {
      _remotePlaybackRecoveryInProgress = false;
      _emitSnapshot();
    }
  }

  Future<void> _skipPastFailedRemoteSong(
    int failedIndex, {
    required bool autoPlay,
  }) async {
    final nextIndex = _nextPlayableIndexAfterFailure(
      failedIndex,
      _queueItems.length,
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
    if (current == null) {
      return _playInstantRadio();
    }

    // The mediaItem id is the raw Subsonic song ID (e.g. "abc123"),
    // NOT the browse-tree "song/abc123" format.
    final seedId = current.id;

    final toggleCb = _preferredMixToggleCallback;
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

  /// Starts an Instant Radio seeded from a random liked song.
  ///
  /// Matches the behaviour of the home screen Instant Radio button: picks a
  /// random liked (starred) song as the seed and delegates to
  /// [_preferredMixCallback].  Falls back to `getRandomSongs()` when no liked
  /// songs exist or no API client is available.
  Future<bool> _playInstantRadio() async {
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
    final all = await _libraryDao.watchAllSongs().first;
    if (all.isEmpty) return false;
    final shuffled = List.of(all)..shuffle();
    await replaceQueueWithData(
      shuffled.take(50).toList(growable: false),
      expandMatchFlows: false,
    );
    return _queueItems.isNotEmpty;
  }

  Future<bool> _queueInstantRadioFallback({required bool autoPlay}) async {
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

    final all = await _libraryDao.watchAllSongs().first;
    if (all.isEmpty) {
      AppLogger.debug('Android Auto fallback: local library is empty.');
      return false;
    }

    final shuffled = List.of(all)..shuffle();
    AppLogger.debug(
      'Android Auto fallback: queueing local random songs '
      '(count=${shuffled.length}, autoPlay=$autoPlay).',
    );
    await replaceQueueWithData(
      shuffled.take(50).toList(growable: false),
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
    if (updated) {
      queue.add(List<MediaItem>.unmodifiable(_queueItems));
      _broadcastPlaybackState();
      _emitSnapshot();
    }
  }

  Future<void> _toggleCurrentSongLike() async {
    await _ready;
    final index = _resolveCurrentQueueMetadata().currentIndex;
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
      unawaited(
        _listenBrainzFeedbackService.enqueueSongFeedback(
          current.id,
          liked: !isLiked,
        ),
      );
    } on SubsonicConnectionException {
      // Offline — queue for retry and keep the optimistic UI (DB already updated).
      await _starSyncDao.queueStarAction(
        itemId: current.id,
        itemType: 'song',
        action: isLiked ? 'unstar' : 'star',
      );
      unawaited(
        _listenBrainzFeedbackService.enqueueSongFeedback(
          current.id,
          liked: !isLiked,
        ),
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
    _artCache?.dispose();
    _cancelCrossfade();
    _cancelRemotePlaybackStallWatchdog();
    await _disposeInactiveCrossfadeDeck();
    _positionPersistTimer?.cancel();
    _transportPersistTimer?.cancel();
    _radioStation = null;
    _radioMetadataService.dispose();
    await _sidecarDownloader.dispose();
    _sidecarSongsById.clear();
    await _interruptionSubscription?.cancel();
    await _becomingNoisySubscription?.cancel();
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
    await _snapshotController.close();
    await _manualTrackChangeCueController.close();
    await _positionController.close();
    await _bufferStateController.close();
    await _radioStreamErrorController.close();
    await _loadFailureController.close();
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
    unawaited(_disposeInactiveCrossfadeDeck());
    _positionPersistTimer?.cancel();
    _transportPersistTimer?.cancel();
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
