part of 'navis_audio_handler.dart';

extension _NavisCache on NavisAudioHandler {
  /// Stops lock-cache downloads of songs other than the current and next
  /// ones. Such a download otherwise runs to completion after the player has
  /// moved on and, on a slow link, starves the song now playing (its first
  /// load timed out behind a skipped song's download). The partial file is
  /// discarded; the song downloads again if it is played again.
  void _cancelStaleLockCacheDownloads(String? currentSongId) {
    if (_lockCacheSources.isEmpty) return;
    final index = _resolveCurrentQueueMetadata().currentIndex;
    final next = index == null || index + 1 >= _queueItems.length
        ? null
        : _queueItems[index + 1].id;
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
    final songId = activity.songId;
    if (songId != null) _cacheProgressAt[songId] = DateTime.now();
    _reportRollingCacheActivity?.call(activity);
  }

  /// Whether [songId]'s cache download is at least half done and received
  /// bytes within the last [_seekBufferingRecoveryTimeout].
  bool _cacheDownloadNearlyDone(String songId) {
    final at = _cacheProgressAt[songId];
    return at != null &&
        _rollingCacheActivities.values.any(
          (a) => a.songId == songId && (a.progress ?? 0) >= 0.5,
        ) &&
        DateTime.now().difference(at) < _seekBufferingRecoveryTimeout;
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
    final songId = _rollingCacheActivities.remove(cacheFilePath)?.songId;
    if (songId != null) _cacheProgressAt.remove(songId);
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
