part of 'navis_audio_handler.dart';

/// Untagged-song level when the library has too few tagged songs to measure.
const replayGainFallbackUntaggedDb = -8.0;

/// Fewest tagged songs before the library median is trusted.
const replayGainMinTaggedSongs = 20;

/// Largest believable ReplayGain value in dB; anything beyond is tag garbage.
const replayGainMaxAbsDb = 24.0;

/// Lowest fixed untagged level the user can pick, in dB.
const replayGainMinUntaggedDb = -15.0;

/// The Automatic untagged level: the median tagged track gain, or the fixed
/// fallback when fewer than [replayGainMinTaggedSongs] songs are tagged.
double automaticUntaggedGainDb({required int taggedCount, double? median}) {
  if (taggedCount < replayGainMinTaggedSongs || median == null) {
    return replayGainFallbackUntaggedDb;
  }
  return median.clamp(replayGainMinUntaggedDb, 0.0);
}

/// Which ReplayGain gain a song ended up using.
enum ReplayGainSource { track, album, untagged }

/// The gain and peak [mode] picks for a song, and which one it was.
///
/// Track and album gain fall back to each other; a gain beyond
/// [replayGainMaxAbsDb] is garbage and counts as missing. Anything but
/// 'album' prefers the track gain, so an unresolved 'smart' acts as 'track'.
({double? gain, double? peak, ReplayGainSource source}) _selectReplayGain({
  required String mode,
  double? trackGain,
  double? albumGain,
  double? trackPeak,
  double? albumPeak,
}) {
  bool usable(double? gain) =>
      gain != null && gain.isFinite && gain.abs() <= replayGainMaxAbsDb;
  return switch ((mode == 'album', usable(trackGain), usable(albumGain))) {
    (false, true, _) || (true, true, false) => (
      gain: trackGain,
      peak: trackPeak,
      source: ReplayGainSource.track,
    ),
    (_, _, true) => (
      gain: albumGain,
      peak: albumPeak,
      source: ReplayGainSource.album,
    ),
    _ => (gain: null, peak: null, source: ReplayGainSource.untagged),
  };
}

/// The most a song is ever turned up, in dB: one cap for every platform
/// (mpv's `@navis_rg` stage, Android's boost stage), so all boost alike.
const replayGainMaxBoostDb = 12.0;

/// How far under a song's peak ceiling its boost stops, in dB: a lossy copy
/// can overshoot the tagged peak.
const replayGainBoostMarginDb = 1.0;

/// Whether the player can turn songs up. mpv has the float `@navis_rg` filter
/// stage on Linux and Windows (macOS is off until [navisReplayGainInPipeline]
/// is); Android has the boost stage of its EQ processor, which exists only
/// while [androidProcessor] says the processor pipeline is installed (it is
/// gone after a rebuild without it).
@visibleForTesting
bool navisReplayGainBoostSupported({
  required bool usesMpv,
  required bool isMacOS,
  bool androidProcessor = false,
}) => (usesMpv && !isMacOS) || androidProcessor;

/// Whether the backend applies ReplayGain inside its audio path, on each
/// song's own samples (see the handler's `replayGainInPipeline`). True on mpv
/// except macOS, and on Android while [androidProcessor] says the EQ processor
/// pipeline is installed (without it the Dart cut through the player volume
/// stays). False on iOS: its equalizer tap carries the boost only, the cut
/// rides the player volume (the per-song cut in the tap is tracked in #392).
/// False on macOS too: mpv is off the pipeline until `af-command` is wired
/// (#490).
// ponytail: macOS stays on the old path until `af-command` and lavfi `volume`
// are verified on libmpv 0.36 (design D5: run
// `af-command navis_rg volume -4dB volume` on a Mac build); then drop isMacOS
// here and in the media_kit adapter's `replayGainFilter` default.
bool navisReplayGainInPipeline({
  required bool usesMpv,
  required bool isMacOS,
  bool androidProcessor = false,
}) => (usesMpv && !isMacOS) || androidProcessor;

/// How much ReplayGain turns one song down ([cutDb], 0 or less) or up
/// ([boostDb], 0 or more).
typedef ReplayGainLevels = ({double cutDb, double boostDb});

/// What ReplayGain does to one song, or null when [mode] is 'off'.
///
/// A song with no usable gain takes [untaggedDb]. The pre-amp (clamped to
/// -6..6) is added and the song's known peak limits the result. The cut is
/// that result capped at 0 dB. The boost is its positive part, and only a
/// song with both a gain and a valid peak gets one: it stops
/// [replayGainBoostMarginDb] under the peak ceiling (no limiter follows) and
/// at [replayGainMaxBoostDb]. A platform that cannot boost
/// ([boostSupported] false) always reports 0. [mode] is 'off', 'track' or
/// 'album'; resolve 'smart' first with [resolveReplayGainMode].
ReplayGainLevels? replayGainLevels({
  required String mode,
  double? trackGain,
  double? albumGain,
  double? trackPeak,
  double? albumPeak,
  double preampDb = 0,
  required double untaggedDb,
  required bool boostSupported,
}) {
  if (mode == 'off') return null;
  final (:gain, :peak, source: _) = _selectReplayGain(
    mode: mode,
    trackGain: trackGain,
    albumGain: albumGain,
    trackPeak: trackPeak,
    albumPeak: albumPeak,
  );
  var db = (gain ?? untaggedDb) + preampDb.clamp(-6.0, 6.0);
  // A peak is a sample ratio near 1; anything else is tag garbage.
  double? ceilingDb;
  if (gain != null && peak != null && peak.isFinite && peak > 0 && peak <= 4) {
    ceilingDb = -20 * math.log(peak) / math.ln10;
    db = math.min(db, ceilingDb);
  }
  final room = ceilingDb == null
      ? 0.0
      : math.max(
          0.0,
          math.min(ceilingDb - replayGainBoostMarginDb, replayGainMaxBoostDb),
        );
  return (
    cutDb: math.min(db, 0),
    boostDb: boostSupported ? math.min(math.max(db, 0.0), room) : 0,
  );
}

/// The mode a song plays with: 'off', 'track' or 'album'.
///
/// 'smart' plays album gain when the song before or after it in play order is
/// from the same album ([albumId] non-empty and equal), and track gain
/// otherwise. A null or empty album id (remote songs, untagged songs) never
/// matches, not even another one. Any other [mode] passes through.
String resolveReplayGainMode(
  String mode, {
  String? albumId,
  String? prevAlbumId,
  String? nextAlbumId,
}) {
  if (mode != 'smart') return mode;
  final inAlbumRun =
      albumId != null &&
      albumId.isNotEmpty &&
      (albumId == prevAlbumId || albumId == nextAlbumId);
  return inAlbumRun ? 'album' : 'track';
}

/// What ReplayGain did to one song, for diagnostics and the Now Playing page.
@immutable
class ReplayGainDecision {
  const new({
    required this.mode,
    required this.resolvedMode,
    required this.cutDb,
    this.boostDb = 0,
    required this.source,
  });

  /// The user's setting: 'off', 'track', 'album' or 'smart' (Smart picked
  /// [resolvedMode] when this is 'smart').
  final String mode;

  /// The mode that was applied: 'off', 'track' or 'album'.
  final String resolvedMode;

  /// How much the song is turned down in dB (0 or less), or null when off.
  /// It is the only part that rides the player volume.
  final double? cutDb;

  /// How much the song is turned up in dB (0 or more) by the platform's boost
  /// stage; 0 when off or when the platform cannot boost.
  final double boostDb;

  /// The signed adjustment in dB, or null when off: the boost when there is
  /// one, the cut otherwise.
  double? get db => cutDb == null ? null : (boostDb > 0 ? boostDb : cutDb);

  /// The gain used after fallbacks, or null when off.
  final ReplayGainSource? source;

  Map<String, Object?> toJson() => <String, Object?>{
    'mode': mode,
    'resolvedMode': resolvedMode,
    'source': source?.name,
    'db': db,
    'cutDb': cutDb,
    'boostDb': boostDb,
  };
}

/// [replayGainLevels] with the mode resolved from the song's queue neighbours
/// (see [resolveReplayGainMode]), plus which gain was used.
ReplayGainDecision replayGainDecision({
  required String mode,
  String? albumId,
  String? prevAlbumId,
  String? nextAlbumId,
  double? trackGain,
  double? albumGain,
  double? trackPeak,
  double? albumPeak,
  double preampDb = 0,
  required double untaggedDb,
  required bool boostSupported,
}) {
  final resolved = resolveReplayGainMode(
    mode,
    albumId: albumId,
    prevAlbumId: prevAlbumId,
    nextAlbumId: nextAlbumId,
  );
  final levels = replayGainLevels(
    mode: resolved,
    trackGain: trackGain,
    albumGain: albumGain,
    trackPeak: trackPeak,
    albumPeak: albumPeak,
    preampDb: preampDb,
    untaggedDb: untaggedDb,
    boostSupported: boostSupported,
  );
  return ReplayGainDecision(
    mode: mode,
    resolvedMode: resolved,
    cutDb: levels?.cutDb,
    boostDb: levels?.boostDb ?? 0,
    source: levels == null
        ? null
        : _selectReplayGain(
            mode: resolved,
            trackGain: trackGain,
            albumGain: albumGain,
            trackPeak: trackPeak,
            albumPeak: albumPeak,
          ).source,
  );
}

/// Whether a native source failure can recover after reconnecting a station.
///
/// Android reports Media3 `PlaybackException.errorCode`: network and timeout
/// failures are transient; a 4xx HTTP status (the vendored player appends
/// `(HTTP <status>)` to the message), a missing file, unsupported or
/// malformed content and decoder failures are permanent. media-kit reports
/// every source failure as its code 1, so those stay transient and only the
/// recovery budget ends them. Code 0 is an unclassified source failure.
bool navisShouldReconnectRadioSource({
  required int errorCode,
  String? message,
  required bool usesMediaKit,
}) {
  if (usesMediaKit && errorCode == MediaKitPlayer.kErrorCode) return true;
  if (errorCode == 2004) {
    final status = RegExp(r'\(HTTP (\d{3})\)').firstMatch(message ?? '');
    final code = int.tryParse(status?.group(1) ?? '');
    return code == null || code < 400 || code >= 500;
  }
  return switch (errorCode) {
    // Unclassified, unspecified, remote, behind live window and timeout.
    0 || 1000 || 1001 || 1002 || 1003 => true,
    // Unspecified IO, connection failed or timed out, read out of range.
    2000 || 2001 || 2002 || 2008 => true,
    _ => false,
  };
}

enum NavisAndroidAutoSearchType {
  empty,
  general,
  artist,
  album,
  playlist,
  title,
  genre,
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
  final genre = _stringExtra(extras, AndroidAutoConstants.mediaGenreKey);
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

  // A genre extra decides the request only when no other focus
  // (artist/album/playlist/song) is set.
  if (genre != null &&
      (focus == null || focus == AndroidAutoConstants.mediaFocusGenre)) {
    return request(NavisAndroidAutoSearchType.genre, genre);
  }

  switch (focus) {
    case AndroidAutoConstants.mediaFocusGenre:
      return request(NavisAndroidAutoSearchType.genre, null);
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

/// [name] as the local search matches it: trimmed, lowercased, accents folded.
String _foldedName(String name) => foldSearchLetters(name.trim().toLowerCase());

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
/// multi-song jump restarts the queue from the start. Continuing into songs
/// not yet loaded
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
  ResolvedPlaybackSource? source,
}) {
  return <String, Object?>{
    'albumId': song.albumId,
    'artistId': song.artistId,
    // Used by PlaybackArtCache on Android to key the local cover-art file so
    // audio_service can set METADATA_KEY_ALBUM_ART on the MediaSession.
    'coverArtId': song.coverArt,
    'sourceKind': source?.kind.name,
    'localSource': source?.isLocal,
    'cachedFilePath': source?.cachedFilePath ?? source?.sidecarCacheFilePath,
    'sidecarCacheFilePath': source?.sidecarCacheFilePath,
    // How far into the song the stream starts (a `timeOffset` transcode).
    'positionOffsetMs': source?.positionOffset.inMilliseconds,
    if (source?.bridgeFormat != null) 'bridgeFormat': source!.bridgeFormat,
    if (source?.bridgeBitRate != null) 'bridgeBitRate': source!.bridgeBitRate,
    // Never the stream URL: audio_service publishes every String extra to
    // the platform media session, and the URL carries the account token.
    'resolvedFormat': source?.metadata.format,
    'resolvedBitRate': source?.metadata.bitRate,
    'resolvedSampleRate': source?.metadata.sampleRate,
    'transcodingApplied': source?.metadata.isTranscoded,
    'liked': song.starred != null,
    'replayGainTrackGain': song.replayGainTrackGain,
    'replayGainAlbumGain': song.replayGainAlbumGain,
    'replayGainTrackPeak': song.replayGainTrackPeak,
    'replayGainAlbumPeak': song.replayGainAlbumPeak,
  };
}
