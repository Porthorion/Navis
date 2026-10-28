part of 'navis_audio_handler.dart';

/// Unchanged probe results after which the trailing probe stops.
const _cachedExtentMaxUnchanged = 5;

/// How long a next-song warm that ended without a file waits before the next
/// attempt, so a failing server is not asked on every position tick.
@visibleForTesting
Duration sidecarChainRetryDelay = const Duration(seconds: 30);

extension _NavisCache on NavisAudioHandler {
  /// The song that plays after [currentSongId], in play order (shuffled
  /// when shuffle is on). Repeat One replays the current song, so there is
  /// nothing further to warm; Repeat All wraps to the first song.
  String? _rollingCacheNextSongId(String? currentSongId) {
    final ids = _logicalQueueIds;
    final index = _logicalCurrentIndex;
    if (index == null ||
        index < 0 ||
        index >= ids.length ||
        ids[index] != currentSongId) {
      return null;
    }
    if (_desiredLoopMode == LoopMode.one) return currentSongId;
    if (index + 1 < ids.length) return ids[index + 1];
    return _desiredLoopMode == LoopMode.all ? ids.first : null;
  }

  /// Stops lock-cache downloads of songs other than the current and next
  /// ones. Such a download otherwise runs to completion after the player has
  /// moved on and, on a slow link, starves the song now playing (its first
  /// load timed out behind a skipped song's download). The partial file is
  /// discarded; the song downloads again if it is played again.
  void _cancelStaleLockCacheDownloads(String? currentSongId) {
    if (_lockCacheSources.isEmpty) return;
    final next = _rollingCacheNextSongId(currentSongId);
    for (final entry in _lockCacheSources.entries.toList()) {
      final songId = entry.value.songId;
      if (songId == currentSongId || songId == next) continue;
      final activity = _rollingCacheActivities[entry.key];
      if (activity == null || (activity.progress ?? 0) >= 0.999) continue;
      unawaited(entry.value.source.cancelDownload());
      _completeRollingCacheActivity(entry.key);
    }
  }

  void _rememberSidecarSong(SongsTableData song, Uri? streamUri) {
    _sidecarSongsById[song.id] = song;
    if (streamUri == null) {
      _sidecarStreamUris.remove(song.id);
    } else {
      _sidecarStreamUris[song.id] = streamUri;
    }
  }

  void _resumeLockCacheDownloads() {
    for (final entry in _lockCacheSources.values) {
      entry.source.resumeDownload();
    }
  }

  /// The lock-cache source of the published current song, which keeps its
  /// range fetches after its own registry entry is gone (download complete).
  /// Looked up by the published item, not the native index, which can move
  /// ahead of it.
  // ignore: experimental_member_use, reason: as above.
  LockCachingAudioSource? _playerCurrentSource() {
    final id = _currentMediaItem?.id;
    final index = _queueItems.indexWhere((item) => item.id == id);
    final source = index < 0 ? null : _player.sequence.elementAtOrNull(index);
    // ignore: experimental_member_use, reason: as above.
    return source is LockCachingAudioSource ? source : null;
  }

  /// The registered lock-cache source of [songId], if any.
  // ignore: experimental_member_use, reason: as above.
  LockCachingAudioSource? _lockCacheSourceOfSong(String songId) =>
      _lockCacheSources.values
          .where((entry) => entry.songId == songId)
          .firstOrNull
          ?.source;

  void _syncLockCacheDownloadPriority() {
    final current = _currentMediaItem;
    final next = _rollingCacheNextSongId(current?.id);
    final rangePlaying =
        defaultTargetPlatform == TargetPlatform.android &&
        !_disposeHandlerStarted &&
        _requestedPlaying &&
        current?.extras?['sourceKind'] ==
            PlaybackSourceKind.lockCachedStream.name &&
        _player.bufferedPosition - _player.position <
            const Duration(seconds: 30) &&
        _playerCurrentSource()?.hasActiveRangeFetch == true;
    for (final entry in _lockCacheSources.values) {
      if (rangePlaying &&
          (entry.songId == current?.id || entry.songId == next)) {
        entry.source.pauseDownload();
      } else {
        entry.source.resumeDownload();
      }
    }
  }

  void _syncBridgeDownloadPriority() {
    _syncLockCacheDownloadPriority();
    final buffering =
        _player.processingState == ProcessingState.loading ||
        _player.processingState == ProcessingState.buffering;
    if (_currentMediaItem?.extras?['bridgeFormat'] != null &&
        _requestedPlaying &&
        buffering &&
        _sidecarDownloader.activeSongId == _currentMediaItem?.id) {
      _sidecarDownloader.pause();
    } else {
      _sidecarDownloader.resume();
    }
  }

  void _syncSidecarRollingCache(MediaItem? item) {
    if (item?.extras?['bridgeFormat'] == null) _sidecarDownloader.resume();
    if (!_isDesktopRuntime || _radioStation != null) {
      unawaited(_sidecarDownloader.cancel());
      _syncSidecarChain();
      return;
    }
    if (item == null) {
      unawaited(_sidecarDownloader.cancel());
      return;
    }
    final sidecarPath = item.extras?['sidecarCacheFilePath'] as String?;
    // The provisional item of a reload (no source resolved yet) must not
    // cancel the download of the very song being reloaded: restarting it
    // wastes the bytes already fetched.
    if ((sidecarPath == null || sidecarPath.isEmpty) &&
        item.extras?['sourceKind'] == null &&
        _sidecarDownloader.activeSongId == item.id) {
      return;
    }
    final song = _sidecarSongsById[item.id];
    final streamUri = _sidecarStreamUris[item.id];
    // A re-published current song (queue edit, like) whose file is complete
    // must leave the next song's running warm alone.
    final active = _sidecarDownloader.activeSongId;
    final warmsNext =
        active != null &&
        active != item.id &&
        active == _rollingCacheNextSongId(item.id);
    if (sidecarPath == null ||
        sidecarPath.isEmpty ||
        song == null ||
        streamUri == null) {
      if (!warmsNext) {
        _sidecarChainKey = null;
        unawaited(_sidecarDownloader.cancel());
      }
      _syncSidecarChain();
      return;
    }
    if (!_completedCacheSongIds.contains(item.id) ||
        !File(sidecarPath).existsSync()) {
      _completedCacheSongIds.remove(item.id);
      // Refilling the current song cancels its warm without a failure backoff.
      _sidecarChainKey = null;
      _sidecarChainRetry = null;
      _startSidecarDownload(item, song, streamUri, sidecarPath);
    }
    _syncBridgeDownloadPriority();
    _syncSidecarChain();
  }

  void _startSidecarDownload(
    MediaItem item,
    SongsTableData song,
    Uri streamUri,
    String sidecarPath,
  ) {
    unawaited(
      _sidecarDownloader.start(
        songId: song.id,
        uri: streamUri,
        cacheFilePath: sidecarPath,
        isTranscoded: item.extras?['transcodingApplied'] as bool? ?? false,
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
          _completedCacheSongIds.add(song.id);
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
          _syncSidecarChain();
        },
        onTerminated: () {
          _completeRollingCacheActivity(sidecarPath);
          // A warm that ended without a file is retried, but not at once.
          final key = _sidecarChainKey;
          if (key != null &&
              key.endsWith('>${song.id}') &&
              !File(sidecarPath).existsSync()) {
            _sidecarChainKey = null;
            if (key.startsWith('${_currentMediaItem?.id}>')) {
              _sidecarChainRetry = (
                key,
                DateTime.now().add(sidecarChainRetryDelay),
              );
            }
          }
        },
      ),
    );
  }

  /// Warms the song that plays next once the current song is on disk (so the
  /// two never compete), and cancels a warm that is no longer the next song
  /// after a skip, queue edit or shuffle. Desktop uses the one sidecar
  /// downloader; Android starts the download of the next song's own
  /// lock-cache source, which ExoPlayer later joins instead of restarting.
  /// Called on every track change, queue edit, download completion and
  /// position tick; the key makes each current-to-next pair start once.
  void _syncSidecarChain() {
    // A position tick during disposal must not restart a cancelled warm.
    if (_disposeHandlerStarted) return;
    if (_radioStation != null) {
      _cancelLockCacheWarm();
      return;
    }
    final desktop = _isDesktopRuntime;
    final current = _currentMediaItem;
    final nextId = _rollingCacheNextSongId(current?.id);
    if (!desktop) _pruneEndedLockCacheWarm();
    final active = desktop
        ? _sidecarDownloader.activeSongId
        : _lockCacheWarmSongId;
    // A next-song warm is running (the current song's own download is not
    // ours to stop). It ends when its song stopped being next or the gate
    // closed (setting turned off, or the link became cellular or metered).
    if (active != null &&
        active != current?.id &&
        (active != nextId || !_readRuntimeSettings().nextSongPrefetchAllowed)) {
      if (desktop) {
        _sidecarChainKey = null;
        unawaited(_sidecarDownloader.cancel());
      } else {
        _cancelLockCacheWarm();
      }
    }
    if (current == null ||
        nextId == null ||
        nextId == current.id ||
        (desktop ? _sidecarDownloader.activeSongId : _lockCacheWarmSongId) ==
            nextId) {
      return;
    }
    final key = '${current.id}>$nextId';
    if (_sidecarChainKey == key) return;
    final retry = _sidecarChainRetry;
    if (retry != null && retry.$1 == key && DateTime.now().isBefore(retry.$2)) {
      return;
    }
    final warm =
        current.extras?['sourceKind'] == PlaybackSourceKind.file.name ||
        _completedCacheSongIds.contains(current.id) ||
        _lockCacheFileComplete(current);
    if (!warm || !_readRuntimeSettings().nextSongPrefetchAllowed) return;
    if (!desktop) {
      _startLockCacheWarm(nextId, key);
      return;
    }
    final next = _queueItems.where((item) => item.id == nextId).firstOrNull;
    final path = next?.extras?['sidecarCacheFilePath'] as String?;
    final song = _sidecarSongsById[nextId];
    final uri = _sidecarStreamUris[nextId];
    if (next == null ||
        path == null ||
        path.isEmpty ||
        song == null ||
        uri == null) {
      return;
    }
    _startSidecarDownload(next, song, uri, path);
    // Remember the pair only once the download claimed the song (or its file
    // is already there); otherwise the next tick tries again.
    if (_sidecarDownloader.activeSongId == nextId || File(path).existsSync()) {
      _sidecarChainKey = key;
    }
  }

  /// Whether the current lock-cached song's final cache file is on disk (the
  /// `.part` file is a different path), e.g. after returning to a finished song.
  bool _lockCacheFileComplete(MediaItem item) {
    if (item.extras?['sourceKind'] !=
        PlaybackSourceKind.lockCachedStream.name) {
      return false;
    }
    final path = item.extras?['cachedFilePath'] as String?;
    return path != null && path.isNotEmpty && File(path).existsSync();
  }

  /// Android: stops the next-song warm, if any, and forgets its pair.
  void _cancelLockCacheWarm() {
    final id = _lockCacheWarmSongId;
    if (id == null) return;
    _lockCacheWarmSongId = null;
    _sidecarChainKey = null;
    for (final entry in _lockCacheSources.entries) {
      if (entry.value.songId != id) continue;
      unawaited(entry.value.source.cancelDownload());
      _completeRollingCacheActivity(entry.key);
    }
  }

  /// A warm whose download ended without finishing (its source is still
  /// registered) failed: free the slot and retry the pair after the delay.
  void _pruneEndedLockCacheWarm() {
    final id = _lockCacheWarmSongId;
    if (id == null) return;
    final source = _lockCacheSourceOfSong(id);
    if (source != null && source.isDownloading) return;
    _lockCacheWarmSongId = null;
    final key = _sidecarChainKey;
    if (source != null && key != null && key.endsWith('>$id')) {
      for (final entry in _lockCacheSources.entries) {
        if (entry.value.songId == id) _completeRollingCacheActivity(entry.key);
      }
      _sidecarChainKey = null;
      if (key.startsWith('${_currentMediaItem?.id}>')) {
        _sidecarChainRetry = (key, DateTime.now().add(sidecarChainRetryDelay));
      }
    }
  }

  /// Android: starts the next song's existing lock-cache source downloading,
  /// without a response (no replay buffer holds the body). The player's later
  /// request for that song joins the running download. Never a second source
  /// on the same partial file; no source (downloaded, cached, deferred tail)
  /// is no warm.
  void _startLockCacheWarm(String nextId, String key) {
    final source = _lockCacheSourceOfSong(nextId);
    if (source == null) return;
    _sidecarChainKey = key;
    _lockCacheWarmSongId = nextId;
    unawaited(
      source.prefetch().catchError((Object error) {
        // Our own cancel is not a failure; the chain already forgot the pair.
        if (_lockCacheWarmSongId != nextId) return;
        AppLogger.debug('Next-song warm of $nextId failed: $error');
        _pruneEndedLockCacheWarm();
      }),
    );
  }

  /// The current and next song ids (canonical) that eviction must keep.
  Set<String> _rollingCacheKeepSongIds() {
    final currentId = _currentMediaItem?.id;
    return <String>{
      for (final id in [currentId, _rollingCacheNextSongId(currentId)])
        if (id != null) _canonicalSongId(id),
    };
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
    _lockCacheSources[cacheFilePath] = (songId: song.id, source: source);
    // A finished download whose file is later evicted downloads again through
    // this same source: register it again, so the stale-download cancel, the
    // priority pause and the rolling-cache completion apply to it too.
    source.onDownloadStart = () {
      if (!_disposeHandlerStarted) {
        _observeLockCachingSource(
          song: song,
          resolvedSource: resolvedSource,
          source: source,
          cacheFilePath: cacheFilePath,
        );
      }
    };

    late final StreamSubscription<double> subscription;
    subscription = source.downloadProgressStream.listen(
      (progress) {
        _cacheReceivedBytes[cacheFilePath] = source.downloadedBytes;
        _syncLockCacheDownloadPriority();
        // The stream replays its last value on listen: a finished download
        // whose file was evicted still says 1.0, which is not a completion.
        if (progress >= 0.999 && !File(cacheFilePath).existsSync()) return;
        if (progress >= 0.999) _completedCacheSongIds.add(song.id);
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
        _lockCacheSources.remove(cacheFilePath)?.source.resumeDownload();
        unawaited(subscription.cancel());
        unawaited(
          _registerRollingCacheTrack(
            song: song,
            resolvedSource: resolvedSource,
            cacheFilePath: cacheFilePath,
          ).whenComplete(() => _completeRollingCacheActivity(cacheFilePath)),
        );
        _syncSidecarChain();
      },
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.debug(
          'Lock-cached source progress listener failed for ${song.id}: '
          '$error\n$stackTrace',
        );
        _cacheProgressSubscriptions.remove(cacheFilePath);
        _lockCacheSources.remove(cacheFilePath)?.source.resumeDownload();
        unawaited(subscription.cancel());
        _completeRollingCacheActivity(cacheFilePath);
      },
      onDone: () {
        _lockCacheSources.remove(cacheFilePath)?.source.resumeDownload();
        if (_cacheProgressSubscriptions.remove(cacheFilePath) != null) {
          _completeRollingCacheActivity(cacheFilePath);
        }
      },
    );

    _cacheProgressSubscriptions[cacheFilePath] = subscription;
    _syncLockCacheDownloadPriority();
  }

  void _updateRollingCacheActivity(
    String cacheFilePath,
    RollingCacheActivity activity,
  ) {
    _rollingCacheActivities[cacheFilePath] = activity;
    _reportRollingCacheActivity?.call(activity);
    _refreshBufferState(_currentBufferSongId);
  }

  /// How much of [songId], the current song, is playable from local data:
  /// all of it from a file or a finished download, else what the running
  /// download has fetched (read exactly from an Ogg or FLAC partial file, else
  /// its fraction, or bytes at the stream's bitrate when its length is
  /// unknown). Null when nothing is known.
  Duration? _cachedPlayablePosition(String songId, Duration duration) =>
      _cachedPlayable(songId, duration).position;

  /// [_cachedPlayablePosition] and where it came from, for diagnostics:
  /// `full`, `exact`, `progress`, `bitrate` or `none`.
  ({Duration? position, String source}) _cachedPlayable(
    String songId,
    Duration duration,
  ) {
    final item = _currentMediaItem;
    if (item == null || item.id != songId || duration <= Duration.zero) {
      return (position: null, source: 'none');
    }
    if (item.extras?['sourceKind'] == PlaybackSourceKind.file.name ||
        _completedCacheSongIds.contains(songId)) {
      return (position: duration, source: 'full');
    }
    final probe = _cachedExtent;
    final exact =
        probe != null &&
            probe.songId == songId &&
            probe.path == _partFilePathForSong(songId)
        ? probe.extent
        : null;
    final progress = _rollingCacheActivities.values
        .where((activity) => activity.songId == songId)
        .firstOrNull
        ?.progress;
    final bitRate = item.extras?['resolvedBitRate'] as int?;
    final bytes = _receivedCacheBytesForSong(songId);
    final Duration cached;
    final String source;
    if (exact != null) {
      cached = exact;
      source = 'exact';
    } else if (progress != null && progress > 0) {
      cached = duration * progress;
      source = 'progress';
    } else if (bytes != null && bitRate != null && bitRate > 0) {
      cached = Duration(milliseconds: bytes * 8 ~/ bitRate);
      source = 'bitrate';
    } else {
      return (position: null, source: 'none');
    }
    if (cached >= duration) return (position: duration, source: source);
    // Whole seconds, so a download does not rebuild the seek bar per chunk.
    return (position: Duration(seconds: cached.inSeconds), source: source);
  }

  /// The partial file the running download of [songId] writes, contiguous
  /// from byte 0 (the full stream, also while an offset stream plays).
  String? _partFilePathForSong(String songId) {
    if (_isDesktopRuntime) {
      return _sidecarDownloader.activeSongId == songId
          ? _sidecarDownloader.activePartFilePath
          : null;
    }
    for (final entry in _rollingCacheActivities.entries) {
      if (entry.value.songId == songId) return '${entry.key}.part';
    }
    return null;
  }

  /// Starts the throttled read of the exact cached time: one small file read
  /// at most once an interval (a second), however many chunks arrive. A failed
  /// read or an unknown format leaves the estimate in place. [retry] is the
  /// trailing probe; an event that finds the retries stopped restarts them.
  void _probeCachedExtent(String songId, {bool retry = false}) {
    final item = _currentMediaItem;
    final path = item?.id == songId ? _partFilePathForSong(songId) : null;
    if (item == null ||
        item.extras?['sourceKind'] == PlaybackSourceKind.file.name ||
        _completedCacheSongIds.contains(songId) ||
        path == null) {
      _cancelCachedExtentTimer();
      return;
    }
    var probe = _cachedExtent;
    if (probe == null || probe.songId != songId || probe.path != path) {
      probe = _cachedExtent = _CachedExtentProbe(songId, path);
    }
    if (!retry && probe.unchanged >= _cachedExtentMaxUnchanged) {
      probe.unchanged = 0;
    }
    final now = DateTime.now();
    final last = probe.lastAt;
    if (probe.inFlight ||
        (last != null && now.difference(last) < cachedExtentInterval)) {
      return;
    }
    probe
      ..inFlight = true
      ..lastAt = now;
    _cachedExtentProbeCount++;
    final current = probe;
    unawaited(
      Future<Duration?>.sync(() => cachedExtentReader(path))
          .catchError((Object _) => null)
          .then((extent) {
            current.inFlight = false;
            // Apply the result only to the probe of the file it was read
            // from: another song, or a restarted download (a new part file
            // for the same song), took over while the read ran.
            final target = _cachedExtent;
            if (target == null ||
                target.songId != current.songId ||
                target.path != current.path) {
              return;
            }
            final best = target.extent;
            if (extent != null && (best == null || extent > best)) {
              target.extent = extent;
              target.unchanged = 0;
            } else {
              target.unchanged++;
            }
            _refreshBufferState(_currentBufferSongId, probe: false);
            _armCachedExtentTimer(target);
          }),
    );
  }

  /// Probes once more after an interval, so a download that grows while the
  /// player sends no buffer events (a held or slow Android stream) is still
  /// followed. Stops after a streak of unchanged results (a stalled
  /// download); the next buffer event restarts it. ponytail: 1 Hz tail read
  /// while a partial download of the current song grows; the only Timer of
  /// the probe, an event-driven read with its own throttle is the alternative
  /// if the player ever reports its buffer on a steady clock.
  void _armCachedExtentTimer(_CachedExtentProbe probe) {
    if (_cachedExtentTimer?.isActive ?? false) return;
    if (_disposeHandlerStarted ||
        probe.unchanged >= _cachedExtentMaxUnchanged ||
        !identical(_cachedExtent, probe) ||
        _currentMediaItem?.id != probe.songId ||
        _currentMediaItem?.extras?['sourceKind'] ==
            PlaybackSourceKind.file.name ||
        _completedCacheSongIds.contains(probe.songId) ||
        _partFilePathForSong(probe.songId) != probe.path) {
      return;
    }
    _cachedExtentTimer = Timer(cachedExtentInterval, () {
      _cachedExtentTimer = null;
      _probeCachedExtent(probe.songId, retry: true);
    });
  }

  void _cancelCachedExtentTimer() {
    _cachedExtentTimer?.cancel();
    _cachedExtentTimer = null;
  }

  // Sidecar bytes prove linear load progress, never desktop seek progress.
  int? _receivedCacheBytesForSong(String songId, {bool includeRanges = false}) {
    if (_isDesktopRuntime) {
      return _sidecarDownloader.activeSongId == songId
          ? _sidecarDownloader.activeReceivedBytes
          : null;
    }
    for (final entry in _rollingCacheActivities.entries) {
      if (entry.value.songId == songId) {
        final bytes = _cacheReceivedBytes[entry.key];
        if (!includeRanges) return bytes;
        final source = _lockCacheSources[entry.key]?.source;
        return (bytes ?? 0) + (source?.rangeFetchBytes ?? 0);
      }
    }
    return null;
  }

  /// Whether the current song plays from the network while its completed
  /// sidecar file is on disk, so a seek can reload it from the file.
  bool _completedSidecarAvailable(String songId) {
    final item = _currentMediaItem;
    if (item == null || item.id != songId) return false;
    if (item.extras?['sourceKind'] == PlaybackSourceKind.file.name) {
      return false;
    }
    final path = item.extras?['sidecarCacheFilePath'] as String?;
    if (path == null || path.isEmpty) return false;
    final file = File(path);
    return file.existsSync() && file.lengthSync() > 0;
  }

  void _completeRollingCacheActivity(String cacheFilePath) {
    _rollingCacheActivities.remove(cacheFilePath);
    _cacheReceivedBytes.remove(cacheFilePath);
    _reportRollingCacheActivity?.call(
      _rollingCacheActivities.values.lastOrNull ??
          const RollingCacheActivity.idle(),
    );
    _refreshBufferState(_currentBufferSongId);
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
        keepSongIds: _rollingCacheKeepSongIds(),
      );
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Failed to register rolling cache entry for ${song.id}: '
        '$error\n$stackTrace',
      );
    }
  }

  /// Register rolling-cache progress listeners for any lock-cached entries
  /// in [prepared].
  void _observeLockCacheForPrepared(List<_PreparedQueueItem> prepared) {
    for (final entry in prepared) {
      // Register the source the player holds, never the resolver's own.
      final held = entry.audioSource;
      // ignore: experimental_member_use, reason: as above.
      if (held is LockCachingAudioSource &&
          entry.source.kind == PlaybackSourceKind.lockCachedStream &&
          entry.source.cachedFilePath != null) {
        _observeLockCachingSource(
          song: entry.song,
          resolvedSource: entry.source,
          source: held,
          cacheFilePath: entry.source.cachedFilePath!,
        );
      }
    }
  }
}
