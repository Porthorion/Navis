part of 'navis_audio_handler.dart';

extension _NavisRecovery on NavisAudioHandler {
  void _cancelPendingSeek() {
    final request = _pendingSeek;
    if (request != null) {
      request.outcome = 'superseded';
      request.stage = 'done';
      _pendingSeek = null;
    }
  }

  bool _isCurrentSeek(_PendingSeek request) => identical(_pendingSeek, request);

  void _checkSeekCurrent(_PendingSeek request, OperationToken token) {
    token.checkCancelled();
    if (!_isCurrentSeek(request)) throw OperationCancelledException();
  }

  bool _isCurrentSeekOrTransport(int generation, _PendingSeek? request) =>
      request == null
      ? _isCurrentTransportIntent(generation)
      : _isCurrentSeek(request);

  bool get _requestedPlaying =>
      _latestExplicitTransportPlaying ?? _player.playing;

  bool get _visiblePlaying => _pendingSeek == null
      ? navisVisiblePlaying(
          playerPlaying: _player.playing,
          queueFinished: _queueFinished,
        )
      : _requestedPlaying;

  Future<void> _waitForSeekSource(
    _PendingSeek request,
    OperationToken token,
  ) async {
    // Phase one must finish before an older occurrence of the same song can
    // be mistaken for readiness on the source selected by this request.
    await _queueLane.enqueue((_) async => _checkSeekCurrent(request, token));
    final wait = Stopwatch()..start();
    while (true) {
      _checkSeekCurrent(request, token);
      final selected = _resolveCurrentQueueMetadata().mediaItem?.id;
      final processing = _player.processingState;
      if (selected == request.songId &&
          processing != ProcessingState.loading &&
          processing != ProcessingState.idle) {
        request.stage = 'seeking';
        return;
      }
      final deadline = isExternalCatalogSource(id: request.songId)
          ? _timeouts.remoteLoad
          : _playerLoadTimeout;
      if (wait.elapsed >= deadline) {
        throw PlaybackLoadTimeoutException(operation: 'seek source readiness');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  Future<void> _seekWithRecovery(
    Duration position, {
    required OperationToken token,
    required int transportGeneration,
    required _PendingSeek seekRequest,
  }) async {
    _checkSeekCurrent(seekRequest, token);
    if (_currentSourceKind == PlaybackSourceKind.lockCachedStream.name &&
        position >= const Duration(seconds: 1) &&
        !await _lockCacheServesRanges(seekRequest, token)) {
      // The origin streams linearly (a server transcode that ignores Range),
      // so the lock-cache source serves every request from the start of the
      // song and ExoPlayer, which found no length, treats it as unseekable:
      // any seek, even within the buffered part, or a direct-stream reload
      // plays it from the beginning. The download runs faster than playback;
      // reload from the completed file instead, and otherwise leave playback
      // where it is.
      seekRequest.recoveryAttempts = 1;
      if (await _waitForCompletedLockCache(seekRequest, token) &&
          await _trySeekViaCompletedCacheFile(
            position,
            autoPlay: _requestedPlaying,
            token: token,
            transportGeneration: transportGeneration,
            seekRequest: seekRequest,
          ) &&
          await _waitForSeekSettlement(seekRequest, token)) {
        return;
      }
      throw StateError('The requested position has not been downloaded yet.');
    }
    try {
      await _runNativeSeek(seekRequest, token, operation: 'seek');
      _checkSeekCurrent(seekRequest, token);
      if (await _waitForSeekSettlement(seekRequest, token)) return;
    } on PlaybackLoadTimeoutException {
      // The timed operation retired the hung player and restored the queue.
      // A newer request can now use that player without the old call racing it.
      _checkSeekCurrent(seekRequest, token);
      seekRequest.recoveryAttempts = 1;
      await _runNativeSeek(
        seekRequest,
        token,
        operation: 'seek after player reset',
      );
      if (await _waitForSeekSettlement(seekRequest, token)) {
        if (_requestedPlaying) unawaited(_playWithFocusRecovery());
        return;
      }
      throw StateError('Seek failed after the player was reset.');
    } on OperationCancelledException {
      rethrow;
    } on Object catch (error) {
      _checkSeekCurrent(seekRequest, token);
      AppLogger.debug(
        'Native seek rejected: ${error.runtimeType}; recovering source.',
      );
    }
    _checkSeekCurrent(seekRequest, token);
    seekRequest.recoveryAttempts = 1;
    seekRequest.stage = 'recovering';
    final fromFile = await _trySeekViaCompletedCacheFile(
      position,
      autoPlay: _requestedPlaying,
      token: token,
      transportGeneration: transportGeneration,
      seekRequest: seekRequest,
    );
    if (!fromFile) {
      await _rebuildQueueForSeekRecovery(
        position,
        autoPlay: _requestedPlaying,
        token: token,
        transportGeneration: transportGeneration,
        seekRequest: seekRequest,
      );
    }
    _checkSeekCurrent(seekRequest, token);
    if (await _waitForSeekSettlement(seekRequest, token)) return;
    // The cache file finished while the reloaded stream was still fetching
    // the target: the local copy reaches it without the network.
    if (seekRequest.unsettled.lastOrNull?['reason'] == 'cache complete' &&
        await _trySeekViaCompletedCacheFile(
          position,
          autoPlay: _requestedPlaying,
          token: token,
          transportGeneration: transportGeneration,
          seekRequest: seekRequest,
        ) &&
        await _waitForSeekSettlement(seekRequest, token)) {
      return;
    }
    throw StateError('Seek failed after source recovery.');
  }

  Future<void> _runNativeSeek(
    _PendingSeek request,
    OperationToken token, {
    required String operation,
  }) => _queueLane.enqueue((_) async {
    // Native seeks share the queue mutation lane. A selection cannot load a
    // new source into an engine whose previous seek has not returned; a hung
    // call retires that engine before the next queued operation proceeds.
    _checkSeekCurrent(request, token);
    await _runTimedPlayerOperation(
      generation: _activeLoadGeneration,
      operation: operation,
      action: () => _player.seek(request.position),
      songId: request.songId,
      timeout: _timeouts.control,
      reloadQueueOnTimeout: true,
    );
    _checkSeekCurrent(request, token);
    if (_requestedPlaying && !_player.playing)
      unawaited(_playWithFocusRecovery());
    if (!_requestedPlaying && _player.playing) {
      await _runTimedPlayerOperation(
        generation: _activeLoadGeneration,
        operation: 'pause after seek',
        action: _player.pause,
        timeout: _timeouts.control,
        reloadQueueOnTimeout: true,
      );
    }
  });

  // just_audio interpolates position while ready. Desktop settlement uses
  // backend position events so that an optimistic clock cannot certify audio
  // that is still waiting on a Range response. ExoPlayer readiness is native.
  Duration get _seekSettlementPosition => _isDesktopRuntime
      ? _player.playbackEvent.updatePosition
      : _player.position;

  Future<bool> _waitForSeekSettlement(
    _PendingSeek request,
    OperationToken token,
  ) async {
    request.stage = 'confirming';
    final elapsed = Stopwatch()..start();
    var lastActivity = Duration.zero;
    var bufferGrewAt = Duration.zero;
    var lastPosition = _seekSettlementPosition;
    var lastBuffer = _player.bufferedPosition;
    var deadline = _playerLoadTimeout;
    Duration? nearSince;
    Duration? nearPosition;
    Duration? farSince;
    String? unsettled;
    while (true) {
      _checkSeekCurrent(request, token);
      final now = elapsed.elapsed;
      final position = _seekSettlementPosition;
      final buffer = _player.bufferedPosition;
      final processing = _player.processingState;
      final near =
          (position - request.position).abs() < const Duration(seconds: 2);
      final atEnd =
          processing == ProcessingState.completed &&
          _player.duration != null &&
          (request.position - _player.duration!).abs() <
              const Duration(seconds: 2);
      if (near) {
        nearSince ??= now;
        nearPosition ??= position;
      } else {
        nearSince = null;
        nearPosition = null;
      }
      // While a backend waits for data its processing state can flap between
      // ready and buffering many times a second, so settlement rests on the
      // native position: advancing from the target proves playback resumed
      // there, and a paused player has to hold the target.
      final settled =
          near &&
          (_requestedPlaying
              ? _player.playing &&
                    (atEnd ||
                        position - nearPosition! >=
                            const Duration(milliseconds: 250))
              : !_player.playing &&
                    processing != ProcessingState.idle &&
                    processing != ProcessingState.loading &&
                    now - nearSince! >= const Duration(milliseconds: 300));
      if (settled) return true;
      // A decoder may probe several HTTP ranges before producing a packet, so
      // native buffering counts as activity: only a player that is not
      // buffering and neither moves nor fills is stalled.
      if (buffer > lastBuffer) bufferGrewAt = now;
      if (buffer != lastBuffer ||
          position != lastPosition ||
          processing == ProcessingState.buffering) {
        lastActivity = now;
        lastBuffer = buffer;
        lastPosition = position;
      }
      farSince =
          !near &&
              processing != ProcessingState.buffering &&
              processing != ProcessingState.loading
          ? farSince ?? now
          : null;
      if (farSince != null && now - farSince >= _seekBufferingRecoveryTimeout) {
        unsettled = 'missed target';
      } else if (!(near && !_requestedPlaying) &&
          now - lastActivity >= _seekBufferingRecoveryTimeout) {
        // A paused player holding the target is expected to stand still.
        unsettled = 'no progress';
      } else if (_completedSidecarAvailable(request.songId)) {
        // The local copy seeks without the network: reload from it rather
        // than wait for the remote range.
        unsettled = 'cache complete';
      } else if (now >= deadline) {
        // A slow link legitimately takes longer for a far seek in a large
        // file; reloading would start the same transfer over. Keep waiting
        // while the player itself is still receiving data, or while a cache
        // download that will soon replace the stream is nearly done.
        if (now < _timeouts.seekProgress &&
            (now - bufferGrewAt < _seekBufferingRecoveryTimeout ||
                _cacheDownloadNearlyDone(request.songId))) {
          deadline = now + _seekBufferingRecoveryTimeout;
        } else {
          unsettled = 'deadline';
        }
      }
      if (unsettled != null) {
        request.unsettled.add(
          _unsettledProbe(unsettled, request, now, position, processing),
        );
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  Map<String, Object?> _unsettledProbe(
    String reason,
    _PendingSeek request,
    Duration elapsed,
    Duration position,
    ProcessingState processing,
  ) => <String, Object?>{
    'reason': reason,
    'elapsedMs': elapsed.inMilliseconds,
    'positionMs': position.inMilliseconds,
    'bufferedMs': _player.bufferedPosition.inMilliseconds,
    'processingState': processing.name,
    'playing': _player.playing,
  };

  /// Whether the current lock-cached source can serve a range beyond its
  /// download: true once its origin answered with byte-range support. Waits
  /// (up to the load deadline) for that answer when it has not arrived.
  Future<bool> _lockCacheServesRanges(
    _PendingSeek request,
    OperationToken token,
  ) async {
    final wait = Stopwatch()..start();
    while (true) {
      _checkSeekCurrent(request, token);
      final index = _player.currentIndex;
      final sequence = _player.sequence;
      final source = index == null || index >= sequence.length
          ? null
          : sequence[index];
      // ignore: experimental_member_use, reason: the lock-cached source reports whether its origin supports ranges.
      if (source is! LockCachingAudioSource) return true;
      final ranges = source.originSupportsRangeRequests;
      if (ranges != null) return ranges;
      if (wait.elapsed >= _playerLoadTimeout) return false;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Waits while the current song's lock-cache download keeps growing, until
  /// its completed file exists. Bounded by [NavisPlaybackTimeouts.seekProgress]
  /// and by [_seekBufferingRecoveryTimeout] without growth.
  Future<bool> _waitForCompletedLockCache(
    _PendingSeek request,
    OperationToken token,
  ) async {
    request.stage = 'waiting for cache';
    final wait = Stopwatch()..start();
    var lastBytes = -1;
    var grewAt = Duration.zero;
    while (wait.elapsed < _timeouts.seekProgress) {
      _checkSeekCurrent(request, token);
      if (_completedCacheFileFor(_currentMediaItem) != null) return true;
      final bytes = _partialCacheBytesForSong(request.songId) ?? -1;
      if (bytes != lastBytes) {
        lastBytes = bytes;
        grewAt = wait.elapsed;
      } else if (wait.elapsed - grewAt >= _seekBufferingRecoveryTimeout) {
        request.unsettled.add(<String, Object?>{
          'reason': 'cache stalled',
          'elapsedMs': wait.elapsed.inMilliseconds,
          'partialBytes': bytes,
        });
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return false;
  }

  /// The completed rolling-cache file of [item]'s stream: the desktop sidecar
  /// or the Android lock cache. Partial downloads are never returned.
  String? _completedCacheFileFor(MediaItem? item) {
    final path = item == null ? null : _cacheFilePathFor(item);
    if (path == null) return null;
    final file = File(path);
    return file.existsSync() && file.lengthSync() > 0 ? path : null;
  }

  /// Where [item]'s stream is being cached: the desktop sidecar file or the
  /// Android lock-cache file.
  String? _cacheFilePathFor(MediaItem item) {
    final extras = item.extras ?? const <String, Object?>{};
    final sidecar = extras['sidecarCacheFilePath'] as String?;
    if (sidecar != null && sidecar.isNotEmpty) return sidecar;
    if (extras['sourceKind'] != PlaybackSourceKind.lockCachedStream.name) {
      return null;
    }
    final lockCache = extras['cachedFilePath'] as String?;
    return lockCache == null || lockCache.isEmpty ? null : lockCache;
  }

  /// Reloads the queue with the current song played from its completed
  /// cache file (desktop sidecar or Android lock cache), which seeks without
  /// a network round-trip. The whole logical queue is kept.
  Future<bool> _trySeekViaCompletedCacheFile(
    Duration position, {
    required bool autoPlay,
    required OperationToken token,
    required int transportGeneration,
    _PendingSeek? seekRequest,
  }) async {
    final item = _currentMediaItem;
    if (item == null) {
      return false;
    }
    final sidecarPath = _cacheFilePathFor(item);
    if (sidecarPath == null) {
      return false;
    }
    final cacheFile = File(sidecarPath);
    final activity = _rollingCacheActivities[sidecarPath];
    if (seekRequest != null &&
        !cacheFile.existsSync() &&
        _sidecarDownloader.activeSongId == item.id &&
        activity?.songId == item.id &&
        (activity?.progress ?? 0) >= 0.5) {
      // A delayed range search may exhaust its deadline while the independent
      // cache download is nearing completion. Give that progressing download
      // one load deadline, without exposing its partial file as playable.
      seekRequest.stage = 'waiting for cache';
      final wait = Stopwatch()..start();
      var lastProgress = activity!.progress ?? 0;
      var progressedAt = Duration.zero;
      while (!cacheFile.existsSync() &&
          _sidecarDownloader.activeSongId == item.id &&
          wait.elapsed < _playerLoadTimeout) {
        _checkSeekCurrent(seekRequest, token);
        final progress = _rollingCacheActivities[sidecarPath]?.progress;
        if (progress != null && progress > lastProgress) {
          lastProgress = progress;
          progressedAt = wait.elapsed;
        }
        if (wait.elapsed - progressedAt >= _seekBufferingRecoveryTimeout) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      _checkSeekCurrent(seekRequest, token);
      seekRequest.stage = 'recovering';
    }
    if (!cacheFile.existsSync() || cacheFile.lengthSync() <= 0) {
      return false;
    }
    final song =
        _sidecarSongsById[item.id] ??
        _remoteRows[item.id] ??
        await _libraryDao.getSongById(item.id);
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
        seekRequest: seekRequest,
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
      if (seekRequest != null) rethrow;
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
  ///
  /// Recovery keeps the queue, like a navigation: queue edits already waiting
  /// (an artist's next albums) run first and are part of the rebuilt queue,
  /// and the queue is snapshotted only once they have. Once the current song
  /// is reloaded, the rest of the queue is always restored and the load
  /// completed, even when a newer transport command (another seek) arrives
  /// meanwhile; only the seek correction and resume yield to it.
  Future<bool> _rebuildQueueForSeekRecovery(
    Duration position, {
    required bool autoPlay,
    required OperationToken token,
    required int transportGeneration,
    _PendingSeek? seekRequest,
    _PreparedQueueItem? preparedStart,
  }) async {
    final metadata = _resolveCurrentQueueMetadata();
    // While a queue replacement is still filling, the player and the queue
    // lists hold only part of the queue; the whole order is the pending
    // logical queue.
    final pendingIds = _pendingLogicalQueueSongIds;
    final String currentSongId;
    var pendingIndex = -1;
    MediaItem? pendingCurrentItem;
    if (pendingIds != null) {
      pendingCurrentItem = metadata.mediaItem;
      final songId = pendingCurrentItem?.id;
      if (songId == null) return false;
      pendingIndex = _locateQueueTarget(songId, metadata.currentIndex ?? 0);
      if (pendingIndex < 0) return false;
      currentSongId = songId;
    } else {
      final expectedIndex = metadata.currentIndex;
      if (expectedIndex == null ||
          expectedIndex < 0 ||
          expectedIndex >= _queueItems.length ||
          _logicalQueueIds.isEmpty) {
        return false;
      }
      currentSongId = _queueItems[expectedIndex].id;
    }

    // Prefer a one-shot direct-stream rebuild for this seek. Do not permanently
    // bypass lock-caching for the song: desktop now uses sidecar caching with
    // native HTTPS seeks, and mobile lock-cache can still serve later plays.
    token.checkCancelled();
    if (!_isCurrentSeekOrTransport(transportGeneration, seekRequest)) {
      return false;
    }
    // Superseding cancels the fill, so read its rows first: without all of
    // them the fill must keep running rather than leave a partial queue.
    List<SongsTableData>? pendingRows;
    if (pendingIds != null) {
      final rows =
          _pendingLogicalQueueSongs ??
          await _libraryDao.getSongsByIds(pendingIds);
      token.checkCancelled();
      if (!identical(_pendingLogicalQueueSongIds, pendingIds) ||
          !_isCurrentSeekOrTransport(transportGeneration, seekRequest)) {
        // The fill completed or a newer command replaced the queue meanwhile.
        return false;
      }
      if (rows.length != pendingIds.length) {
        AppLogger.warning(
          'Seek recovery could not read the queue that is still loading. '
          'Skipping direct-stream fallback.',
        );
        return false;
      }
      pendingRows = rows;
    }
    // A fade would hand over to a deck that still holds the failing source.
    _cancelCrossfade();
    // Not loading yet: until the reload starts, refills and fades carry on,
    // so waiting behind queue work (or a slow read) cannot stall playback.
    final queueGeneration = _supersedeQueueWork(
      pendingLogicalQueueSongIds: _pendingLogicalQueueSongIds,
      navigation: true,
    );
    var rebuilt = false;
    _QueueRestorePoint? pendingRestore;
    _recoveryStage = 'waiting for lane';
    try {
      await _queueLane.navigate((queueToken) async {
        _checkQueueWorkCurrent(queueToken, queueGeneration);
        _recoveryStage = 'reading queue';
        final capture = (
          index: _player.currentIndex,
          position: _player.position,
          playing: _player.playing,
        );
        final List<String> queueSongIds;
        final List<SongsTableData> orderedSongs;
        final int currentIndex;
        final _QueueRestorePoint restore;
        final fillRows = pendingRows;
        if (fillRows != null) {
          // The interrupted fill's queue, including edits that ran before
          // this work. Restoring it keeps every song even if the reload
          // fails: the songs around the current one wait as deferred entries,
          // like a released long queue.
          final ids = _logicalQueueIds;
          final rows = listEquals(ids, pendingIds)
              ? fillRows
              : await _libraryDao.getSongsByIds(ids);
          _checkQueueWorkCurrent(queueToken, queueGeneration);
          final index = _locateQueueTarget(currentSongId, pendingIndex);
          if (index < 0 || rows.length != ids.length) {
            // An edit removed the song, or a row is missing: keep the queue
            // without reloading.
            pendingRestore = _pendingQueueRestorePoint(
              ids,
              <SongsTableData>[...fillRows, ...rows],
              pendingCurrentItem!,
              index,
              capture,
            );
            return;
          }
          queueSongIds = ids;
          orderedSongs = rows;
          currentIndex = index;
          restore = _pendingQueueRestorePoint(
            ids,
            rows,
            pendingCurrentItem!,
            index,
            capture,
          );
        } else {
          final materialisedIndex = _resolveCurrentQueueMetadata().currentIndex;
          if (materialisedIndex == null ||
              materialisedIndex < 0 ||
              materialisedIndex >= _queueItems.length ||
              _queueItems[materialisedIndex].id != currentSongId) {
            // The song changed while edits ran; there is nothing to recover.
            return;
          }
          currentIndex = materialisedIndex + _deferredHead.length;
          // The logical queue, so the deferred head and tail survive.
          queueSongIds = _logicalQueueIds;
          orderedSongs = (await _rowsForDeferredEntries(_logicalQueueEntries()))
              .nonNulls
              .toList(growable: false);
          _checkQueueWorkCurrent(queueToken, queueGeneration);
          if (orderedSongs.length != queueSongIds.length) {
            AppLogger.warning(
              'Seek recovery could not rebuild the full queue from the local '
              'songs table. Skipping direct-stream fallback.',
            );
            return;
          }
          restore = _QueueRestorePoint(
            head: List<_DeferredQueueEntry>.of(_deferredHead),
            items: List<MediaItem>.of(_queueItems),
            tail: List<_DeferredQueueEntry>.of(_deferredTail),
            capture: capture,
            missing: const <String>[],
          );
        }
        if (orderedSongs.length > 1) {
          _pendingLogicalQueueSongIds = List<String>.unmodifiable(queueSongIds);
          _pendingLogicalQueueSongs = orderedSongs;
        }
        final _PreparedQueueItem? startItem;
        _recoveryStage = 'reloading current song';
        _cancelCrossfade();
        _isLoading = true;
        _loadingSongId = currentSongId;
        _emitSnapshot();
        try {
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
            holdPlayback: true,
          );
        } on OperationCancelledException {
          // A newer command owns the queue, and rebuilds the pending one.
          rethrow;
        } on Object {
          // The song could not be reloaded (a stream that times out again
          // leaves both players rebuilt empty). Never leave the queue cut
          // down to that one song: put it back, so skipping past the song
          // rebuilds the player around the next one.
          _recoveryStage = 'reload failed';
          _restoreQueueLists(restore);
          _afterQueueEdit(context: 'seek recovery failed');
          rethrow;
        }
        rebuilt = true;
        // Land and resume before the rest of the queue is restored: on a long
        // queue that fill takes seconds, and the song must not be heard from
        // wherever the load left it meanwhile. This work owns the lane, so
        // the correction cannot race a queue edit.
        await _landRecoveredSong(
          position,
          queueGeneration: queueGeneration,
          token: token,
          transportGeneration: transportGeneration,
          seekRequest: seekRequest,
          autoPlay: autoPlay,
          songId: currentSongId,
        );
        final reloaded = startItem;
        if (reloaded == null || orderedSongs.length <= 1) {
          _recoveryStage = 'done';
          _completeQueueLoad(queueGeneration);
          return;
        }
        // Submitted from inside this work, so edits made meanwhile wait
        // behind it and apply to the restored queue.
        _recoveryStage = 'waiting to restore queue';
        unawaited(
          _queueLane.fill((fillToken) async {
            try {
              _checkQueueWorkCurrent(fillToken, queueGeneration);
              _recoveryStage = 'restoring queue';
              await _replaceQueuePhase2(
                songs: orderedSongs,
                startIndex: currentIndex,
                startItem: reloaded,
                persist: true,
                token: fillToken,
                generation: queueGeneration,
                deferTail: _shouldDeferTail(orderedSongs.length),
              );
              _recoveryStage = 'done';
              _completeQueueLoad(queueGeneration);
            } on OperationCancelledException {
              _recoveryStage = 'superseded';
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
      });
    } on Object {
      _completeQueueLoad(
        queueGeneration,
        loadingSongId: currentSongId,
        failed: true,
      );
      rethrow;
    }
    if (!rebuilt) {
      // Superseded before the reload, or nothing to recover: a superseding
      // command owns the load; otherwise the old queue is still in place.
      _recoveryStage = 'not rebuilt';
      final restoreFill = pendingRestore;
      if (restoreFill != null && _isActiveLoadGeneration(queueGeneration)) {
        // This work cancelled the fill, so the queue lists still hold only
        // part of it: put the whole queue back before completing the load.
        _restoreQueueLists(restoreFill);
        _afterQueueEdit(context: 'seek recovery skipped');
      }
      _completeQueueLoad(queueGeneration);
      return false;
    }
    if (token.isCancelled ||
        !_isCurrentSeekOrTransport(transportGeneration, seekRequest)) {
      return true;
    }
    await _syncNativeLoopMode();
    return true;
  }

  /// Puts the song a recovery reloaded (paused) at [position], then resumes
  /// it according to the latest Play/Pause intent. A newer seek or transport
  /// command owns the position and play state instead.
  Future<void> _landRecoveredSong(
    Duration position, {
    required int queueGeneration,
    required OperationToken token,
    required int transportGeneration,
    required _PendingSeek? seekRequest,
    required bool autoPlay,
    required String songId,
  }) async {
    bool current() =>
        !token.isCancelled &&
        _isCurrentSeekOrTransport(transportGeneration, seekRequest);
    if (!current()) return;
    // The backend normally starts the reload at [position]; correct one that
    // did not (a source that ignored its initial position).
    if ((position - _player.position).abs() >= const Duration(seconds: 2)) {
      try {
        await _runTimedPlayerOperation(
          generation: queueGeneration,
          operation: 'seek recovery correction',
          action: () => _player.seek(position),
          songId: songId,
          timeout: _timeouts.control,
          reloadQueueOnTimeout: true,
        );
      } on OperationCancelledException {
        rethrow;
      } on Object catch (error) {
        // The settlement probe that follows reports the failure; the rest of
        // the queue must still be restored.
        AppLogger.debug(
          'Seek recovery correction failed: ${error.runtimeType}',
        );
      }
      if (!current()) return;
    }
    if (seekRequest == null ? autoPlay : _requestedPlaying) {
      unawaited(_playWithFocusRecovery());
    }
  }

  /// A restore point for a queue that is still loading: [current] stays
  /// materialised and every other song in [ids] waits as a deferred entry,
  /// keeping the rows of remote songs from [rows].
  _QueueRestorePoint _pendingQueueRestorePoint(
    List<String> ids,
    List<SongsTableData> rows,
    MediaItem current,
    int currentIndex,
    ({int? index, Duration position, bool playing}) capture,
  ) {
    final rowsById = <String, SongsTableData>{
      for (final row in rows) row.id: row,
    };
    _DeferredQueueEntry entry(String id) {
      final row = rowsById[id];
      return row == null ? _DeferredQueueEntry(id) : _deferredEntryFor(row);
    }

    if (currentIndex < 0) {
      // The current song is no longer queued: keep the rest as the tail.
      return _QueueRestorePoint(
        head: const <_DeferredQueueEntry>[],
        items: <MediaItem>[current],
        tail: <_DeferredQueueEntry>[for (final id in ids) entry(id)],
        capture: capture,
        missing: const <String>[],
      );
    }
    return _QueueRestorePoint(
      head: <_DeferredQueueEntry>[
        for (final id in ids.take(currentIndex)) entry(id),
      ],
      items: <MediaItem>[current],
      tail: <_DeferredQueueEntry>[
        for (final id in ids.skip(currentIndex + 1)) entry(id),
      ],
      capture: capture,
      missing: const <String>[],
    );
  }

  Future<void> _playWithFocusRecovery({bool lastFocusAttempt = false}) async {
    if (_disposeHandlerStarted) return;
    final generation = _transportGeneration;
    final player = _player;
    if (_audioInterrupted) {
      _focusDeniedGeneration = generation;
      return;
    }
    try {
      // Completes only when playback pauses; the playback event listener
      // records the grant through _onPlayerPlaying.
      await player.play();
    } on AudioFocusDeniedException {
      if (_disposeHandlerStarted ||
          !_isCurrentTransportIntent(generation) ||
          !identical(player, _player))
        return;
      _focusDeniedGeneration = generation;
      final since = _focusDeniedSince ??= DateTime.now();
      final remaining = _timeouts.focusRetry - DateTime.now().difference(since);
      // Publish the paused state; the notification must not show Playing.
      _broadcastPlaybackState();
      _emitSnapshot();
      if (lastFocusAttempt || remaining <= Duration.zero) {
        // Focus stayed unavailable: stay paused silently until the user acts.
        _focusDeniedGeneration = null;
        _focusDeniedSince = null;
        _latestExplicitTransportPlaying = false;
        AppLogger.startup(
          StartupEvent.audioFocusRecovery,
          attempt: _focusRetries,
          outcome: StartupOutcome.timeout,
        );
        _broadcastPlaybackState();
        _emitSnapshot();
        return;
      }
      AppLogger.startup(
        StartupEvent.audioFocusRecovery,
        attempt: ++_focusRetries,
        outcome: StartupOutcome.unavailable,
      );
      final backoff = Duration(seconds: 1 << (_focusRetries - 1).clamp(0, 3));
      final last = backoff >= remaining;
      _focusRetryTimer?.cancel();
      _focusRetryTimer = Timer(last ? remaining : backoff, () {
        if (_focusDeniedGeneration == _transportGeneration &&
            !_audioInterrupted) {
          unawaited(_playWithFocusRecovery(lastFocusAttempt: last));
        }
      });
    } on Object {
      // Player event errors own source recovery; never leak a Play future error.
      AppLogger.startup(
        StartupEvent.streamRecovery,
        outcome: StartupOutcome.failure,
      );
    }
  }

  /// just_audio reports playing only once audio focus is granted.
  void _onPlayerPlaying() {
    if (_focusDeniedGeneration == null && _focusDeniedSince == null) return;
    _focusRetryTimer?.cancel();
    _focusDeniedGeneration = null;
    _focusRetries = 0;
    _focusDeniedSince = null;
    AppLogger.startup(
      StartupEvent.audioFocusRecovery,
      outcome: StartupOutcome.success,
    );
  }

  void _scheduleNetworkPlaybackRetry() {
    if (_disposeHandlerStarted || _networkRetryTimer?.isActive == true) return;
    var delay = Duration(seconds: 3 * (1 << _networkRetries.clamp(0, 3)));
    // A station's last attempt falls on its recovery deadline.
    if (_pendingRadioRecovery case final radio?) {
      final left =
          _timeouts.radioRecovery - DateTime.now().difference(radio.since);
      if (left < delay) delay = left.isNegative ? Duration.zero : left;
    }
    _networkRetryTimer = Timer(delay, () {
      _networkRetries++;
      _retryNetworkPlayback();
    });
  }

  void _retryNetworkPlayback() {
    if (_disposeHandlerStarted) return;
    if (_pendingRadioRecovery != null)
      unawaited(_recoverRadioAfterNetworkFailure());
    if (_pendingRemoteRecovery != null) {
      unawaited(
        _recoverCurrentSongFromRemotePlaybackFailure(
          reason: 'network recovered',
        ),
      );
    }
  }

  /// Replaces the current remote song's recovery request for this transport
  /// intent and starts recovery. False when the current song is not a remote
  /// stream that recovery can reload.
  bool _rearmRemoteRecovery({
    required Duration position,
    required bool autoPlay,
  }) {
    final sourceKind = _currentSourceKind;
    final songId = _resolveCurrentQueueMetadata().mediaItem?.id;
    if (songId == null ||
        (sourceKind != PlaybackSourceKind.lockCachedStream.name &&
            sourceKind != PlaybackSourceKind.directStream.name)) {
      return false;
    }
    _seekFailureBlocksRecovery = false;
    _pendingRemoteRecovery = (
      generation: _transportGeneration,
      songId: songId,
      position: position,
      autoPlay: autoPlay,
    );
    unawaited(
      _recoverCurrentSongFromRemotePlaybackFailure(reason: 'user command'),
    );
    return true;
  }

  bool _ownsRemoteRecovery(String songId) =>
      _pendingRemoteRecovery?.songId == songId &&
      _pendingRemoteRecovery?.generation == _transportGeneration;

  /// A failed source is idle; a stalled one is still waiting for data.
  bool get _remotePlaybackStillFailed => switch (_player.processingState) {
    ProcessingState.idle ||
    ProcessingState.loading ||
    ProcessingState.buffering => true,
    ProcessingState.ready || ProcessingState.completed => false,
  };

  void _syncRemotePlaybackStallWatchdog() {
    // A failed seek suppresses automatic recovery so it cannot later restart
    // or skip the song; once the song has played on normally for a few
    // seconds, a new stall is unrelated to the seek and is recovered again.
    final failedAt = _seekFailurePosition;
    if (_seekFailureBlocksRecovery &&
        _pendingSeek == null &&
        failedAt != null &&
        _player.playing &&
        _player.position - failedAt >= const Duration(seconds: 5)) {
      _seekFailureBlocksRecovery = false;
      _seekFailurePosition = null;
    }
    if (_isLoading ||
        _pendingLogicalQueueSongIds != null ||
        _pendingSeek != null ||
        _seekFailureBlocksRecovery ||
        _radioStation != null ||
        _queueItems.isEmpty) {
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
    if (_isLoading ||
        _pendingLogicalQueueSongIds != null ||
        _pendingSeek != null ||
        _seekFailureBlocksRecovery ||
        _remotePlaybackRecoveryInProgress ||
        _radioStation != null) {
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
    // The pending request is the one record of what to restore: Play and
    // seek may update it while the network check below is awaited.
    if (!_ownsRemoteRecovery(songId)) {
      _pendingRemoteRecovery = (
        generation: _transportGeneration,
        songId: songId,
        position: _player.position,
        autoPlay: _requestedPlaying,
      );
    }
    _broadcastPlaybackState();
    _emitSnapshot();
    final ({int generation, String songId, Duration position, bool autoPlay})
    pending;
    try {
      var online = false;
      try {
        online = (await reconcileNetwork?.call())?.serverReachable ?? true;
      } on Object {
        AppLogger.startup(
          StartupEvent.streamRecovery,
          outcome: StartupOutcome.unavailable,
        );
      }
      if (_disposeHandlerStarted) return;
      final latest = _pendingRemoteRecovery;
      // A song change, transport command or load replaced the request, or the
      // player recovered by itself: never reload a song that plays.
      if (latest == null ||
          !_ownsRemoteRecovery(songId) ||
          _isLoading ||
          _pendingSeek != null ||
          !_remotePlaybackStillFailed) {
        if (latest?.songId == songId) {
          _pendingRemoteRecovery = null;
          _broadcastPlaybackState();
          _emitSnapshot();
        }
        return;
      }
      if (!online) {
        _remoteRecoveryWasOffline = true;
        AppLogger.startup(
          StartupEvent.streamRecovery,
          outcome: StartupOutcome.offline,
        );
        _scheduleNetworkPlaybackRetry();
        return;
      }
      if (_remoteRecoveryWasOffline) {
        _remotePlaybackRecoveryAttempts.clear();
        _remoteRecoveryWasOffline = false;
      }
      pending = latest;
      _pendingRemoteRecovery = null;
    } finally {
      _remotePlaybackRecoveryInProgress = false;
    }
    final transportGeneration = pending.generation;
    final position = pending.position;
    final autoPlay = pending.autoPlay;
    _remotePlaybackRecoveryInProgress = true;
    final attemptKey = '$transportGeneration:$songId';
    final isRetry = navisShouldRetryRemotePlayback(
      alreadyRetried: _remotePlaybackRecoveryAttempts.contains(attemptKey),
    );
    if (isRetry) {
      _remotePlaybackRecoveryAttempts.add(attemptKey);
    }
    AppLogger.startup(
      StartupEvent.streamRecovery,
      attempt: isRetry ? 1 : 2,
      outcome: StartupOutcome.changed,
    );

    try {
      if (isRetry) {
        try {
          final recoveryToken = OperationToken();
          final rebuilt = await _rebuildQueueForSeekRecovery(
            position,
            autoPlay: autoPlay,
            token: recoveryToken,
            transportGeneration: transportGeneration,
          );
          AppLogger.startup(
            StartupEvent.streamRecovery,
            outcome: rebuilt
                ? StartupOutcome.success
                : StartupOutcome.unchanged,
          );
          _recordSeekDiagnosticsEvent(<String, Object?>{
            'at': DateTime.now().toUtc().toIso8601String(),
            'path': 'remote_retry',
            'requestedPositionMs': position.inMilliseconds,
            'songId': songId,
            'reason': reason,
            'outcome': rebuilt ? 'reloaded' : 'notRebuilt',
          });
          return;
        } on Object {
          AppLogger.startup(
            StartupEvent.streamRecovery,
            outcome: StartupOutcome.failure,
          );
        }
      }

      if (!_isCurrentTransportIntent(transportGeneration)) return;
      await _skipPastFailedRemoteSong(
        // By position in the whole queue: played songs may have moved out of
        // the player, and a failed reload restores the queue around it.
        _locateQueueTarget(songId, currentIndex + _deferredHead.length),
        autoPlay: _latestExplicitTransportPlaying ?? autoPlay,
      );
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

  /// Plays the song after logical index [failedIndex], or stops when none
  /// follows (or the failed song is no longer queued).
  Future<void> _skipPastFailedRemoteSong(
    int failedIndex, {
    required bool autoPlay,
  }) async {
    // The next song may still be deferred; playFromIndex releases it.
    final nextIndex = failedIndex < 0
        ? null
        : _nextPlayableIndexAfterFailure(failedIndex, _logicalQueueIds.length);
    if (nextIndex != null) {
      await _applyNavigationDecision(
        _navigationIntent.select(nextIndex),
        logicalIds: _logicalQueueIds,
        shouldPlay: autoPlay,
        context: 'skip failed remote song',
      );
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
}
