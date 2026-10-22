part of 'navis_audio_handler.dart';

/// Unchanged probe results after which the trailing probe stops.
const _cachedExtentMaxUnchanged = 5;

extension _NavisCache on NavisAudioHandler {
  /// Stops lock-cache downloads of songs other than the current and next
  /// ones. Such a download otherwise runs to completion after the player has
  /// moved on and, on a slow link, starves the song now playing (its first
  /// load timed out behind a skipped song's download). The partial file is
  /// discarded; the song downloads again if it is played again.
  void _cancelStaleLockCacheDownloads(String? currentSongId) {
    if (_lockCacheSources.isEmpty) return;
    final ids = _logicalQueueIds;
    final index = _logicalCurrentIndex;
    final next =
        index == null ||
            index < 0 ||
            index + 1 >= ids.length ||
            ids[index] != currentSongId
        ? null
        : ids[index + 1];
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

  void _syncBridgeDownloadPriority() {
    final buffering =
        _player.processingState == ProcessingState.loading ||
        _player.processingState == ProcessingState.buffering;
    if (_currentMediaItem?.extras?['bridgeFormat'] != null &&
        (_requestedPlaying || _pendingSeek != null) &&
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
    if (sidecarPath == null ||
        sidecarPath.isEmpty ||
        song == null ||
        streamUri == null) {
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
        },
        onTerminated: () => _completeRollingCacheActivity(sidecarPath),
      ),
    );
    _syncBridgeDownloadPriority();
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

    late final StreamSubscription<double> subscription;
    subscription = source.downloadProgressStream.listen(
      (progress) {
        _cacheReceivedBytes[cacheFilePath] = source.downloadedBytes;
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
        _lockCacheSources.remove(cacheFilePath);
        unawaited(subscription.cancel());
        unawaited(
          _registerRollingCacheTrack(
            song: song,
            resolvedSource: resolvedSource,
            cacheFilePath: cacheFilePath,
          ).whenComplete(() => _completeRollingCacheActivity(cacheFilePath)),
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.debug(
          'Lock-cached source progress listener failed for ${song.id}: '
          '$error\n$stackTrace',
        );
        _cacheProgressSubscriptions.remove(cacheFilePath);
        _lockCacheSources.remove(cacheFilePath);
        unawaited(subscription.cancel());
        _completeRollingCacheActivity(cacheFilePath);
      },
      onDone: () {
        _lockCacheSources.remove(cacheFilePath);
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
  int? _receivedCacheBytesForSong(String songId) {
    if (_isDesktopRuntime) {
      return _sidecarDownloader.activeSongId == songId
          ? _sidecarDownloader.activeReceivedBytes
          : null;
    }
    for (final entry in _rollingCacheActivities.entries) {
      if (entry.value.songId == songId) return _cacheReceivedBytes[entry.key];
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
}
