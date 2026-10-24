part of 'navis_audio_handler.dart';

enum _SeekPlan {
  native,
  offset,
  offsetPendingRanges,
  bridge,
  bridgeAfterGuard,
  cachedBridge,
}

typedef _SeekPreviewKey = ({
  String songId,
  int? queueIndex,
  Object representation,
  bool bridge,
  Duration offset,
});

class _SeekPreview {
  new(this.key);
  final _SeekPreviewKey key;
  ResolvedPlaybackSource? source;
  SeekPreviewRequest? request;
}

extension _NavisSeekPreview on NavisAudioHandler {
  Duration? _seekOffset(Duration position, MediaItem? item) {
    final duration = _effectivePlaybackDuration(item);
    var seconds = position.inSeconds;
    if (duration > const Duration(seconds: 1)) {
      seconds = math.min(
        seconds,
        (duration - const Duration(seconds: 1)).inSeconds,
      );
    }
    return seconds < 1 ? null : Duration(seconds: seconds);
  }

  // The same read-only decision serves preview admission and committed seeks.
  _SeekPlan _seekPlan(
    Duration target,
    String songId, {
    bool? originSupportsRanges,
  }) {
    final item = _currentMediaItem;
    if (item == null ||
        item.id != songId ||
        _radioStation != null ||
        isExternalCatalogSource(id: item.id)) {
      return _SeekPlan.native;
    }
    final extras = item.extras ?? const <String, Object?>{};
    final kind = extras['sourceKind'];
    if ((kind == PlaybackSourceKind.lockCachedStream.name ||
            kind == PlaybackSourceKind.directStream.name) &&
        extras['transcodingApplied'] == true &&
        _sourceResolver.supportsTranscodeOffset &&
        _completedCacheFileFor(item) == null) {
      if (_positionOffsetOf(item) > Duration.zero) return _SeekPlan.offset;
      if (target >= const Duration(seconds: 1)) {
        if (kind == PlaybackSourceKind.lockCachedStream.name) {
          final index = _player.currentIndex;
          final source = index == null
              ? null
              : _player.sequence.elementAtOrNull(index);
          final ranges =
              originSupportsRanges ??
              // ignore: experimental_member_use, reason: Read the existing origin capability without starting a request.
              (source is LockCachingAudioSource
                  ? source.originSupportsRangeRequests
                  : true);
          if (ranges == null) return _SeekPlan.offsetPendingRanges;
          if (!ranges) return _SeekPlan.offset;
        } else if (_isDesktopRuntime) {
          return _SeekPlan.offset;
        }
      }
    }
    if (!_shouldFastSeek(target, songId)) return _SeekPlan.native;
    final bridging = extras['bridgeFormat'] != null;
    final cached = _cachedPlayablePosition(
      item.id,
      _effectivePlaybackDuration(item),
    );
    if (bridging && cached != null && target <= cached) {
      return _SeekPlan.cachedBridge;
    }
    return bridging || _fastSeekLinkIsSlow(item)
        ? _SeekPlan.bridge
        : _SeekPlan.bridgeAfterGuard;
  }

  _SeekPreviewKey? _previewKey(Duration position) {
    final songId = _snapshot.currentSongId;
    if (songId == null ||
        _disposeHandlerStarted ||
        _isLoading ||
        _pendingSeek != null) {
      return null;
    }
    final plan = _seekPlan(position, songId);
    if (plan != _SeekPlan.offset && plan != _SeekPlan.bridge) return null;
    final offset = _seekOffset(position, _currentMediaItem);
    if (offset == null) return null;
    final item = _currentMediaItem!;
    final cached = _cachedPlayablePosition(
      songId,
      _effectivePlaybackDuration(item),
    );
    if (cached != null && position <= cached) return null;
    return (
      songId: songId,
      queueIndex: _navigationIntent.desiredIndex ?? _logicalCurrentIndex,
      representation: _sourceResolver.seekPreviewRepresentation,
      bridge: plan == _SeekPlan.bridge,
      offset: offset,
    );
  }

  Future<void> _previewSeek(Duration position) async {
    final key = _previewKey(navisSanitizeSeekPosition(position));
    if (key != null && _seekPreview?.key == key) return;
    cancelSeekPreview();
    if (key == null) return;
    final preview = _SeekPreview(key);
    _seekPreview = preview;
    _seekPreviewExpiry = Timer(const Duration(seconds: 10), () {
      if (identical(_seekPreview, preview)) cancelSeekPreview();
    });
    try {
      final song =
          _sidecarSongsById[key.songId] ??
          _remoteRows[key.songId] ??
          (await _libraryDao.getSongsByIds([key.songId])).firstOrNull;
      if (song == null || !identical(_seekPreview, preview)) return;
      final source = await _sourceResolver.resolveForSong(
        song,
        preferLockCaching: false,
        transcodeOffset: key.offset,
        fastSeekBridge: key.bridge,
      );
      if (!identical(_seekPreview, preview)) return;
      if (_previewKey(position) != key ||
          source.isLocal ||
          source.positionOffset != key.offset) {
        cancelSeekPreview();
        return;
      }
      preview.source = source;
      preview.request = SeekPreviewRequest(
        source.uri!,
        userAgent: _playbackUserAgent,
      );
    } on Object catch (error) {
      if (identical(_seekPreview, preview)) cancelSeekPreview();
      AppLogger.debug('Seek preview unavailable: ${error.runtimeType}');
    }
  }

  bool _previewMatchesRelease(Duration position, {required bool bridge}) {
    final preview = _seekPreview;
    if (preview == null || preview.request?.usable != true) return false;
    final key = preview.key;
    final offset = _seekOffset(position, _currentMediaItem);
    if (offset == null) return false;
    final delta = position - key.offset;
    return key.songId == _snapshot.currentSongId &&
        key.queueIndex ==
            (_navigationIntent.desiredIndex ?? _logicalCurrentIndex) &&
        key.representation == _sourceResolver.seekPreviewRepresentation &&
        key.bridge == bridge &&
        delta >= Duration.zero &&
        delta <= const Duration(seconds: 2);
  }

  // Check again after resolution: cache, account or representation can change
  // while queue work is awaiting its turn.
  _SeekPreview? _takeSeekPreview(
    SongsTableData song,
    ResolvedPlaybackSource source,
    _PendingSeek seekRequest,
  ) {
    if (!_isCurrentSeek(seekRequest)) return null;
    final preview = _seekPreview;
    if (preview == null) return null;
    final prepared = preview.source;
    final matches =
        prepared != null &&
        preview.request?.usable == true &&
        preview.key.songId == song.id &&
        preview.key.queueIndex ==
            (_navigationIntent.desiredIndex ?? _logicalCurrentIndex) &&
        preview.key.representation ==
            _sourceResolver.seekPreviewRepresentation &&
        prepared.kind == source.kind &&
        prepared.metadata.format == source.metadata.format &&
        prepared.metadata.bitRate == source.metadata.bitRate &&
        prepared.bridgeFormat == source.bridgeFormat &&
        prepared.bridgeBitRate == source.bridgeBitRate &&
        prepared.positionOffset == source.positionOffset;
    if (!matches) {
      cancelSeekPreview();
      return null;
    }
    seekRequest
      ..previewOffset = source.positionOffset
      ..previewRequest = preview.request;
    _seekPreview = null;
    _seekPreviewExpiry?.cancel();
    _seekPreviewExpiry = null;
    return preview;
  }
}
