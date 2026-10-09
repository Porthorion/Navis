part of 'navis_audio_handler.dart';

enum NavisAndroidAutoSearchType {
  empty,
  general,
  artist,
  album,
  playlist,
  title,
}

enum NavisPreviousTrackAction { none, restartCurrent, skipToPrevious }

const Duration navisPreviousTrackRestartThreshold = Duration(seconds: 3);

@immutable
class NavisQueueReplacementMetadataAnchor {
  const new({required this.expectedIndex, required this.mediaItem});

  final int expectedIndex;
  final MediaItem mediaItem;
}

@immutable
class NavisResolvedQueueMetadata {
  const new({required this.mediaItem, required this.currentIndex});

  final MediaItem? mediaItem;
  final int? currentIndex;
}

final class NavisAndroidAutoSearchRequest {
  const new({required this.type, required this.term});

  final NavisAndroidAutoSearchType type;
  final String term;
}

@visibleForTesting
NavisAndroidAutoSearchRequest navisAndroidAutoSearchRequest(
  String query, [
  Map<String, dynamic>? extras,
]) {
  final focus = _stringExtra(extras, AndroidAutoConstants.mediaFocusKey);
  final title = _stringExtra(extras, AndroidAutoConstants.mediaTitleKey);
  final artist = _stringExtra(extras, AndroidAutoConstants.mediaArtistKey);
  final album = _stringExtra(extras, AndroidAutoConstants.mediaAlbumKey);
  final playlist = _stringExtra(extras, AndroidAutoConstants.mediaPlaylistKey);
  final fallback = query.trim();

  NavisAndroidAutoSearchRequest request(
    NavisAndroidAutoSearchType type,
    String? value,
  ) {
    final term = (value ?? fallback).trim();
    return term.isEmpty
        ? const NavisAndroidAutoSearchRequest(
            type: NavisAndroidAutoSearchType.empty,
            term: '',
          )
        : NavisAndroidAutoSearchRequest(type: type, term: term);
  }

  switch (focus) {
    case AndroidAutoConstants.mediaFocusArtist:
      return request(NavisAndroidAutoSearchType.artist, artist);
    case AndroidAutoConstants.mediaFocusAlbum:
      return request(NavisAndroidAutoSearchType.album, album);
    case AndroidAutoConstants.mediaFocusPlaylist:
      return request(NavisAndroidAutoSearchType.playlist, playlist);
    case AndroidAutoConstants.mediaFocusSong:
      return request(NavisAndroidAutoSearchType.title, title);
  }

  if (title != null) return request(NavisAndroidAutoSearchType.title, title);
  if (artist != null) return request(NavisAndroidAutoSearchType.artist, artist);
  if (album != null) return request(NavisAndroidAutoSearchType.album, album);
  if (playlist != null) {
    return request(NavisAndroidAutoSearchType.playlist, playlist);
  }
  return request(NavisAndroidAutoSearchType.general, fallback);
}

String? _stringExtra(Map<String, dynamic>? extras, String key) {
  final value = extras?[key];
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

bool _containsIgnoreCase(String value, String query) {
  return value.toLowerCase().contains(query.toLowerCase());
}

bool _equalsIgnoreCase(String value, String query) {
  return value.trim().toLowerCase() == query.trim().toLowerCase();
}

@visibleForTesting
bool navisIsQueueReplacementMetadataAnchorConfirmed({
  required List<MediaItem> queueItems,
  required int? backendCurrentIndex,
  required NavisQueueReplacementMetadataAnchor? anchor,
}) {
  if (anchor == null || backendCurrentIndex == null) {
    return false;
  }
  if (backendCurrentIndex != anchor.expectedIndex) {
    return false;
  }
  return backendCurrentIndex >= 0 &&
      backendCurrentIndex < queueItems.length &&
      queueItems[backendCurrentIndex].id == anchor.mediaItem.id;
}

@visibleForTesting
NavisResolvedQueueMetadata navisResolveQueueMetadata({
  required List<MediaItem> queueItems,
  List<String>? logicalQueueSongIds,
  required int? backendCurrentIndex,
  required MediaItem? fallbackMediaItem,
  required NavisQueueReplacementMetadataAnchor? anchor,
}) {
  if (anchor != null &&
      !navisIsQueueReplacementMetadataAnchorConfirmed(
        queueItems: queueItems,
        backendCurrentIndex: backendCurrentIndex,
        anchor: anchor,
      )) {
    final expectedIndex = anchor.expectedIndex;
    if (expectedIndex >= 0 &&
        expectedIndex < queueItems.length &&
        queueItems[expectedIndex].id == anchor.mediaItem.id) {
      return NavisResolvedQueueMetadata(
        mediaItem: queueItems[expectedIndex],
        currentIndex: expectedIndex,
      );
    }

    final logicalQueue = logicalQueueSongIds;
    if (logicalQueue != null &&
        expectedIndex >= 0 &&
        expectedIndex < logicalQueue.length &&
        logicalQueue[expectedIndex] == anchor.mediaItem.id) {
      return NavisResolvedQueueMetadata(
        mediaItem: anchor.mediaItem,
        currentIndex: expectedIndex,
      );
    }

    final anchoredIndex = queueItems.indexWhere(
      (item) => item.id == anchor.mediaItem.id,
    );
    if (anchoredIndex >= 0) {
      return NavisResolvedQueueMetadata(
        mediaItem: queueItems[anchoredIndex],
        currentIndex: anchoredIndex,
      );
    }
  }

  if (backendCurrentIndex == null ||
      backendCurrentIndex < 0 ||
      backendCurrentIndex >= queueItems.length) {
    if (fallbackMediaItem != null) {
      final fallbackIndex = queueItems.indexWhere(
        (item) => item.id == fallbackMediaItem.id,
      );
      if (fallbackIndex >= 0) {
        return NavisResolvedQueueMetadata(
          mediaItem: queueItems[fallbackIndex],
          currentIndex: fallbackIndex,
        );
      }
    }
    return NavisResolvedQueueMetadata(
      mediaItem: fallbackMediaItem,
      currentIndex: null,
    );
  }

  return NavisResolvedQueueMetadata(
    mediaItem: queueItems[backendCurrentIndex],
    currentIndex: backendCurrentIndex,
  );
}

@visibleForTesting
bool navisShouldPreloadQueue({
  required bool autoPlay,
  required bool preloadWhenPaused,
  required bool gaplessEnabled,
  bool forcePreloadWhenPaused = false,
}) {
  return autoPlay ||
      forcePreloadWhenPaused ||
      (preloadWhenPaused && gaplessEnabled);
}

@visibleForTesting
bool navisPlaybackSnapshotsStructurallyEqual(
  PlaybackSnapshot previous,
  PlaybackSnapshot next,
) {
  // The handler reuses one list per queue revision, so an unchanged queue is
  // usually the identical list and skips the element-wise comparison.
  return (identical(previous.queueSongIds, next.queueSongIds) ||
          listEquals(previous.queueSongIds, next.queueSongIds)) &&
      previous.currentSongId == next.currentSongId &&
      previous.currentIndex == next.currentIndex &&
      previous.playing == next.playing &&
      previous.processingState == next.processingState &&
      previous.duration == next.duration &&
      previous.shuffleMode == next.shuffleMode &&
      previous.repeatMode == next.repeatMode &&
      previous.isCurrentSongLiked == next.isCurrentSongLiked &&
      _radioStationsEqual(previous.radioStation, next.radioStation) &&
      previous.isLoading == next.isLoading &&
      previous.hasPendingLogicalQueue == next.hasPendingLogicalQueue &&
      previous.pendingQueueIndex == next.pendingQueueIndex &&
      previous.pendingSeekPosition == next.pendingSeekPosition &&
      previous.loadingSongId == next.loadingSongId &&
      previous.lastFailedSongId == next.lastFailedSongId;
}

bool _radioStationsEqual(
  RadioStationMetadata? previous,
  RadioStationMetadata? next,
) {
  if (identical(previous, next)) {
    return true;
  }
  if (previous == null || next == null) {
    return false;
  }
  return previous.stationId == next.stationId &&
      previous.stationName == next.stationName &&
      previous.streamUrl == next.streamUrl &&
      previous.homePageUrl == next.homePageUrl &&
      previous.nowPlayingTitle == next.nowPlayingTitle &&
      previous.nowPlayingArtist == next.nowPlayingArtist &&
      previous.nowPlayingArtUrl == next.nowPlayingArtUrl;
}

@visibleForTesting
bool navisEffectiveGaplessEnabled({
  required bool gaplessEnabled,
  required bool crossfadeEnabled,
}) {
  return gaplessEnabled || crossfadeEnabled;
}

/// The song a native player source plays, for diagnostics: its [MediaItem]
/// tag, or for an Android lock-cached stream, which is built before its
/// [MediaItem] and so carries no tag, the `id` of its stream URL.
@visibleForTesting
String? navisNativeSourceSongId(IndexedAudioSource source) {
  final tag = source.tag;
  if (tag is MediaItem) return tag.id;
  // ignore: experimental_member_use, reason: Android rolling-cache playback uses LockCachingAudioSource.
  if (source is LockCachingAudioSource) {
    final id = source.uri.queryParameters['id'];
    return id == null || id.isEmpty ? null : id;
  }
  return null;
}

@visibleForTesting
bool navisShouldUseLockCachingForSong({
  required bool preferLockCaching,
  required bool isBypassedForSong,
}) {
  return preferLockCaching && !isBypassedForSong;
}

@visibleForTesting
int? navisResumeIndexAfterQueueInsertion({
  required bool wasPlayingBeforeMutation,
  required bool queueWasCompletedBeforeMutation,
  required ProcessingState processingStateAfterMutation,
  required int firstInsertedIndex,
  required int queueLength,
}) {
  if (!wasPlayingBeforeMutation) {
    return null;
  }
  if (!queueWasCompletedBeforeMutation &&
      processingStateAfterMutation != ProcessingState.completed) {
    return null;
  }
  if (firstInsertedIndex < 0 || firstInsertedIndex >= queueLength) {
    return null;
  }
  return firstInsertedIndex;
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

@immutable
class NavisOsControlCapabilities {
  const new({
    required this.canPlay,
    required this.canPause,
    required this.canStop,
    required this.canSeek,
    required this.canSkipNext,
    required this.canSkipPrevious,
    required this.isLive,
  });

  final bool canPlay;
  final bool canPause;
  final bool canStop;
  final bool canSeek;
  final bool canSkipNext;
  final bool canSkipPrevious;
  final bool isLive;

  static const idle = NavisOsControlCapabilities(
    canPlay: false,
    canPause: false,
    canStop: false,
    canSeek: false,
    canSkipNext: false,
    canSkipPrevious: false,
    isLive: false,
  );
}

@visibleForTesting
NavisOsControlCapabilities navisOsControlCapabilities({
  required int queueLength,
  required int? currentIndex,
  required bool isRadioMode,
  required Duration duration,
  required AudioProcessingState processingState,
  required bool playing,
}) {
  final hasValidQueueIndex =
      currentIndex != null && currentIndex >= 0 && currentIndex < queueLength;
  final hasActivePlayback = isRadioMode || hasValidQueueIndex;
  if (!hasActivePlayback) {
    return NavisOsControlCapabilities.idle;
  }

  final hasKnownDuration = duration > Duration.zero;
  final isLive = isRadioMode || !hasKnownDuration;
  final isLoading =
      processingState == AudioProcessingState.loading ||
      processingState == AudioProcessingState.buffering;

  return NavisOsControlCapabilities(
    canPlay: !playing && !isLoading,
    canPause: playing,
    canStop: true,
    canSeek: !isRadioMode && hasKnownDuration,
    canSkipNext:
        !isRadioMode &&
        navisCanSkipQueueItem(
          queueLength: queueLength,
          currentIndex: currentIndex,
          forward: true,
        ),
    canSkipPrevious:
        !isRadioMode &&
        (navisCanSkipQueueItem(
              queueLength: queueLength,
              currentIndex: currentIndex,
              forward: false,
            ) ||
            (hasKnownDuration && hasValidQueueIndex)),
    isLive: isLive,
  );
}

NavisOsControlCapabilities navisOsControlCapabilitiesForSnapshot(
  PlaybackSnapshot snapshot,
) {
  return navisOsControlCapabilities(
    queueLength: snapshot.queueSongIds.length,
    currentIndex: snapshot.currentIndex,
    isRadioMode: snapshot.isRadioMode,
    duration: snapshot.duration,
    processingState: snapshot.processingState,
    playing: snapshot.playing,
  );
}

@visibleForTesting
List<MediaControl> navisNotificationControls({
  required NavisOsControlCapabilities capabilities,
}) {
  return <MediaControl>[
    if (capabilities.canSkipPrevious) MediaControl.skipToPrevious,
    if (capabilities.canPause)
      MediaControl.pause
    else if (capabilities.canPlay)
      MediaControl.play,
    if (capabilities.canSkipNext) MediaControl.skipToNext,
  ];
}

@visibleForTesting
List<int> navisNotificationCompactActionIndicesForControls(
  List<MediaControl> controls,
) {
  return List<int>.generate(controls.length, (index) => index);
}

@visibleForTesting
Set<MediaAction> navisSystemActionsForCapabilities(
  NavisOsControlCapabilities capabilities,
) {
  return <MediaAction>{
    if (capabilities.canSeek) ...<MediaAction>{
      MediaAction.seek,
      MediaAction.seekForward,
      MediaAction.seekBackward,
    },
    if (capabilities.canPlay) MediaAction.play,
    if (capabilities.canPause) MediaAction.pause,
    if (capabilities.canStop) MediaAction.stop,
    if (capabilities.canSkipNext) MediaAction.skipToNext,
    if (capabilities.canSkipPrevious) MediaAction.skipToPrevious,
    MediaAction.prepare,
    MediaAction.prepareFromMediaId,
    MediaAction.prepareFromSearch,
    MediaAction.playFromMediaId,
    MediaAction.playFromSearch,
  };
}

@visibleForTesting
PlaybackState navisAndroidAutoPlaybackErrorState(
  PlaybackState current,
  String message,
) {
  return current.copyWith(
    processingState: AudioProcessingState.error,
    playing: false,
    controls: const <MediaControl>[],
    androidCompactActionIndices: const <int>[],
    systemActions: const <MediaAction>{
      MediaAction.prepare,
      MediaAction.prepareFromMediaId,
      MediaAction.prepareFromSearch,
      MediaAction.playFromMediaId,
      MediaAction.playFromSearch,
    },
    errorCode: 1,
    errorMessage: message,
  );
}

@visibleForTesting
Duration navisSanitizeSeekPosition(Duration position) {
  if (position < Duration.zero) {
    return Duration.zero;
  }
  return position;
}

@visibleForTesting
bool navisShouldWatchRemotePlaybackForStall({
  required String? sourceKind,
  required AudioProcessingState processingState,
}) {
  final isRemoteSource =
      sourceKind == PlaybackSourceKind.lockCachedStream.name ||
      sourceKind == PlaybackSourceKind.directStream.name;
  final isWaitingForRemoteData =
      processingState == AudioProcessingState.loading ||
      processingState == AudioProcessingState.buffering;
  return isRemoteSource && isWaitingForRemoteData;
}

@visibleForTesting
bool navisShouldRetryRemotePlayback({required bool alreadyRetried}) =>
    !alreadyRetried;

@visibleForTesting
bool navisShouldRestartCompletedQueue({
  required int queueLength,
  required int? currentIndex,
  required bool hasPendingLogicalQueue,
}) {
  if (queueLength <= 0 || hasPendingLogicalQueue) {
    return false;
  }
  return currentIndex == null || currentIndex >= queueLength - 1;
}

/// Whether the UI and system controls should show playback as running.
///
/// just_audio leaves `playing` true after the last song ends, which kept a
/// pause button on a finished queue, so a finished queue reads as paused.
@visibleForTesting
bool navisVisiblePlaying({
  required bool playerPlaying,
  required bool queueFinished,
}) => playerPlaying && !queueFinished;

/// Whether a playback event means the queue has just finished.
///
/// Only the transition into `completed` at the end of the song counts: the
/// desktop backend can keep reporting `completed`, or re-enter it, while a
/// restarted song plays from the start. Continuing into songs not yet loaded
/// into the player is not a finish.
@visibleForTesting
bool navisQueueJustFinished({
  required ProcessingState? previous,
  required ProcessingState current,
  required bool continuingPastCompletion,
  required Duration position,
  required Duration? duration,
}) =>
    current == ProcessingState.completed &&
    previous != ProcessingState.completed &&
    !continuingPastCompletion &&
    (duration == null || position >= duration - const Duration(seconds: 1));

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
bool navisCanRestartCurrentQueueItem({
  required int queueLength,
  required int? currentIndex,
}) {
  return queueLength > 0 &&
      currentIndex != null &&
      currentIndex >= 0 &&
      currentIndex < queueLength;
}

NavisPreviousTrackAction navisResolvePreviousTrackAction({
  required int queueLength,
  required int? currentIndex,
  required Duration position,
}) {
  if (!navisCanRestartCurrentQueueItem(
    queueLength: queueLength,
    currentIndex: currentIndex,
  )) {
    return NavisPreviousTrackAction.none;
  }
  if (position > navisPreviousTrackRestartThreshold) {
    return NavisPreviousTrackAction.restartCurrent;
  }
  if (navisCanSkipQueueItem(
    queueLength: queueLength,
    currentIndex: currentIndex,
    forward: false,
  )) {
    return NavisPreviousTrackAction.skipToPrevious;
  }
  return NavisPreviousTrackAction.restartCurrent;
}

@visibleForTesting
Map<String, Object?> navisResolvedPlaybackExtras({
  required SongsTableData song,
  required ResolvedPlaybackSource source,
}) {
  return <String, Object?>{
    'albumId': song.albumId,
    'artistId': song.artistId,
    // Used by PlaybackArtCache on Android to key the local cover-art file so
    // audio_service can set METADATA_KEY_ALBUM_ART on the MediaSession.
    'coverArtId': song.coverArt,
    'sourceKind': source.kind.name,
    'localSource': source.isLocal,
    'cachedFilePath': source.cachedFilePath ?? source.sidecarCacheFilePath,
    'sidecarCacheFilePath': source.sidecarCacheFilePath,
    // Never the stream URL: audio_service publishes every String extra to
    // the platform media session, and the URL carries the account token.
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
