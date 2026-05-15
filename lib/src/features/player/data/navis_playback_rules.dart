part of 'navis_audio_handler.dart';

enum NavisAndroidAutoSearchType {
  empty,
  general,
  artist,
  album,
  playlist,
  genre,
  title,
}

final class NavisAndroidAutoSearchRequest {
  const NavisAndroidAutoSearchRequest({
    required this.type,
    required this.term,
  });

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

  switch (focus) {
    case AndroidAutoConstants.mediaFocusArtist:
      return request(NavisAndroidAutoSearchType.artist, artist);
    case AndroidAutoConstants.mediaFocusAlbum:
      return request(NavisAndroidAutoSearchType.album, album);
    case AndroidAutoConstants.mediaFocusPlaylist:
      return request(NavisAndroidAutoSearchType.playlist, playlist);
    case AndroidAutoConstants.mediaFocusGenre:
      return request(NavisAndroidAutoSearchType.genre, genre);
    case AndroidAutoConstants.mediaFocusSong:
      return request(NavisAndroidAutoSearchType.title, title);
  }

  if (title != null) return request(NavisAndroidAutoSearchType.title, title);
  if (artist != null) return request(NavisAndroidAutoSearchType.artist, artist);
  if (album != null) return request(NavisAndroidAutoSearchType.album, album);
  if (playlist != null) {
    return request(NavisAndroidAutoSearchType.playlist, playlist);
  }
  if (genre != null) return request(NavisAndroidAutoSearchType.genre, genre);
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
bool navisEffectiveGaplessEnabled({
  required bool gaplessEnabled,
  required bool crossfadeEnabled,
}) {
  return gaplessEnabled || crossfadeEnabled;
}

@visibleForTesting
bool navisShouldUseLockCachingForSong({
  required bool preferLockCaching,
  required bool isBypassedForSong,
}) {
  return preferLockCaching && !isBypassedForSong;
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
  // Recover when the seek significantly under-shot the target. This catches
  // both the "snap to near-zero" case and the "snap to buffer boundary" case
  // (e.g. user seeks to 60s but lands at 8s because only 8s is buffered).
  return delta >= const Duration(seconds: 2) &&
      actualPosition < requestedPosition;
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
    // Used by PlaybackArtCache on Android to key the local cover-art file so
    // audio_service can set METADATA_KEY_ALBUM_ART on the MediaSession.
    'coverArtId': song.coverArt,
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
