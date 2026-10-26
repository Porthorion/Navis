part of 'navis_audio_handler.dart';

extension _NavisQueueLoading on NavisAudioHandler {
  int _supersedeQueueWork({
    bool isLoading = false,
    String? loadingSongId,
    List<String>? pendingLogicalQueueSongIds,
    bool navigation = false,
  }) {
    _invalidateTranscodeEndOccurrence();
    final previousAnchor = _queueReplacementMetadataAnchor;
    _clearQueueReplacementMetadataAnchor();
    _crossfadeFailedFrom = null;
    _crossfadeDisabledReason = null;
    // The user's command replaces any startup queue still waiting to restore.
    if (_queueRestoreOutcome == 'deferred_auth') {
      _queueRestoreOutcome = 'superseded';
    }
    // Navigation keeps the queue, so a coalesced save of an earlier edit
    // must still land; any other supersession persists its own queue.
    if (!navigation) {
      _queueItemsPersistTimer?.cancel();
      _queueItemsPersistTimer = null;
      _queueItemsPersistContext = null;
      _queueItemsPersistFirstScheduledAt = null;
    }
    _pendingLogicalQueueSongIds = pendingLogicalQueueSongIds == null
        ? null
        : List<String>.unmodifiable(pendingLogicalQueueSongIds);
    if (navigation) {
      _queueLane.cancelForNavigation();
    } else {
      _queueLane.cancelCurrent();
    }
    final generation = ++_loadGeneration;
    _activeLoadGeneration = generation;
    _isLoading = isLoading;
    _loadingSongId = isLoading ? loadingSongId : null;
    if (isLoading && loadingSongId != null) {
      final row =
          _pendingLogicalQueueSongs
              ?.where((song) => song.id == loadingSongId)
              .firstOrNull ??
          _remoteRows[loadingSongId];
      final item = row != null
          ? _mediaItemForSong(row)
          : _queueItems.where((item) => item.id == loadingSongId).firstOrNull ??
                (previousAnchor?.mediaItem.id == loadingSongId
                    ? previousAnchor?.mediaItem
                    : null);
      if (item != null) {
        _setQueueReplacementMetadataAnchor(
          expectedIndex: _navigationIntent.desiredIndex ?? 0,
          mediaItem: item,
        );
        _setCurrentMediaItem(item);
      }
    }
    _broadcastPlaybackState();
    _emitSnapshot();
    return generation;
  }

  bool _isActiveLoadGeneration(int generation) =>
      generation == _activeLoadGeneration;

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
    final departed = _prematureTranscodeDeparture?.item;
    if (departed != null) {
      final index = _departedQueueIndex(departed);
      if (index >= 0) {
        return NavisResolvedQueueMetadata(
          mediaItem: departed,
          currentIndex: index,
        );
      }
    }
    final restoredIndex = _restoredQueueIndex;
    if (restoredIndex != null && !_isLoading) {
      return NavisResolvedQueueMetadata(
        mediaItem: _queueItems.elementAtOrNull(restoredIndex),
        currentIndex: restoredIndex,
      );
    }
    final backendCurrentIndex = _player.currentIndex;
    if (!(_isLoading &&
            (_player.processingState == ProcessingState.idle ||
                _queueReplacementMetadataAnchor
                        ?.mediaItem
                        .extras?['sourceKind'] ==
                    null)) &&
        navisIsQueueReplacementMetadataAnchorConfirmed(
          queueItems: _queueItems,
          backendCurrentIndex: backendCurrentIndex,
          anchor: _queueReplacementMetadataAnchor,
        )) {
      _clearQueueReplacementMetadataAnchor();
    }
    final pending = _queueReplacementMetadataAnchor;
    if (_isLoading &&
        pending != null &&
        pending.mediaItem.id == _loadingSongId) {
      return NavisResolvedQueueMetadata(
        mediaItem: _currentMediaItem?.id == pending.mediaItem.id
            ? _currentMediaItem
            : pending.mediaItem,
        currentIndex: pending.expectedIndex - _deferredHead.length,
      );
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
    _activeStartupTrace?.mark(failed ? 'queueLoadFailed' : 'queueLoadComplete');
    _isLoading = false;
    _loadingSongId = null;
    // A failed or completed selection returns metadata authority to the
    // source the player actually holds. Pending metadata must not outlive it.
    _clearQueueReplacementMetadataAnchor();
    _clearPendingLogicalQueue();
    _pendingLogicalQueueSongs = null;
    if (_radioStation == null) {
      _setCurrentMediaItem(
        _isDesktopRuntime && failed && _player.audioSources.isEmpty
            ? _queueItems.where((item) => item.id == loadingSongId).firstOrNull
            : _player.audioSources.isEmpty
            ? null
            : _queueItems.elementAtOrNull(
                _player.currentIndex ?? _queueItems.length,
              ),
      );
    } else {
      _setCurrentMediaItem(_mediaItemForRadioStation(_radioStation!));
    }
    _captureTranscodeEndOccurrence(indexEvent: true);
    _broadcastPlaybackState();
    _applyReplayGainVolume();
    _syncRemotePlaybackStallWatchdog();
    _rearmHeldRemoteRecovery();
    if (_navigationIntent.isPending &&
        _navigationIntent.desiredIndex == _logicalCurrentIndex) {
      _navigationIntent.confirm(_navigationIntent.revision);
    }
    if (loadingSongId != null && failed) {
      _lastFailedSongId = loadingSongId;
    }
    _emitSnapshot();
    _continueIntoDeferredTail();
  }

  void _reportDroppedSongs(List<String> songIds, QueueDropReason reason) {
    if (songIds.isEmpty || _droppedSongsController.isClosed) return;
    _droppedSongsController.add(
      QueueSongsDropped(
        songIds: List<String>.unmodifiable(songIds),
        reason: reason,
      ),
    );
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

  void _silenceAbandonedPlayer(AudioPlayer player) {
    // A stuck stop/dispose must never leave an orphan audible. Neither
    // operation depends on the other completing.
    unawaited(
      Future<void>.sync(() => player.setVolume(0)).catchError((Object _) {}),
    );
    unawaited(Future<void>.sync(player.pause).catchError((Object _) {}));
  }

  Future<void> _disposeAbandonedPlayer(AudioPlayer player) async {
    _silenceAbandonedPlayer(player);
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
    // Past the cap the trouble is not one song: stop quietly on this one.
    if (_autoFailovers >= _maxAutoFailovers) return null;
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
    AppLogger.warning(
      'Recovering audio players after timeout in $operation '
      '(song=${songId ?? 'n/a'} generation=$generation).',
    );
    _anomalies.event('reload', {'via': 'players'});
    _cancelCrossfade();
    _resumeLockCacheDownloads();
    // Native stop may hang; cancel this retired source before the bypass reload.
    final retiredIndex = _player.currentIndex;
    final retiredSource = retiredIndex == null || retiredIndex < 0
        ? null
        : _player.sequence.elementAtOrNull(retiredIndex);
    // ignore: experimental_member_use, reason: close the retired player's lock-cache transport.
    if (retiredSource is LockCachingAudioSource) {
      await retiredSource.cancelDownload();
    }
    // The abandoned player disposes every source it held, which detaches a
    // reused one from the new player: the reload builds fresh sources.
    for (final entry in _lockCacheSources.entries.toList()) {
      if (!identical(entry.value.source, retiredSource)) {
        await entry.value.source.cancelDownload();
      }
      _lockCacheSources.remove(entry.key);
      await _cacheProgressSubscriptions.remove(entry.key)?.cancel();
      _completeRollingCacheActivity(entry.key);
    }
    _lockCacheWarmSongId = null;
    _sidecarChainKey = null;
    _silenceAbandonedPlayer(_player);
    final inactive = _crossfadePlayer;
    if (inactive != null) _silenceAbandonedPlayer(inactive);
    await _disposePlayerListeners();

    final previousPlayer = _player;
    final previousInactiveDeck = _crossfadePlayer;
    final previousLoopMode = previousPlayer.loopMode;

    _player = _buildAudioPlayer(enableEqualizer: _equalizerPipelineEnabled);
    _wirePlayerListeners();
    _rebindRadioMetadataServiceToActivePlayer();

    try {
      await _restoreActivePlayerVolume().timeout(_playerResetTimeout);
      await _applyAdjustmentsToPlayer(
        _player,
        _appliedAdjustments,
      ).timeout(_playerResetTimeout);
      await _player.setLoopMode(previousLoopMode).timeout(_playerResetTimeout);
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Failed to restore active player state after timeout recovery: '
        '$error\n$stackTrace',
      );
    }

    _crossfadePlayer = _crossfadeEnabled ? _newCrossfadePlayer() : null;
    final inactiveDeck = _crossfadePlayer;
    if (inactiveDeck != null) {
      try {
        await inactiveDeck
            .setLoopMode(previousLoopMode)
            .timeout(_playerResetTimeout);
        await _applyAdjustmentsToPlayer(
          inactiveDeck,
          _appliedAdjustments,
        ).timeout(_playerResetTimeout);
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
    Duration? timeout,
    // Queue edits must commit a native change that succeeded, even if a newer
    // command superseded the generation meanwhile; dropping it would leave
    // the Dart queue and the player out of step.
    bool cancelAfterSuccess = true,
    // For edits of a loaded queue: the player rebuilt after a timeout starts
    // empty, so the materialised queue is loaded into it again.
    bool reloadQueueOnTimeout = false,
    bool extendWhileDownloading = false,
    bool fixedLoadDeadline = false,
    bool Function()? isCurrent,
  }) async {
    timeout ??= _playerLoadTimeout;
    _lastFailedSongId = null;
    _timedPlayerOperationCount++;
    final startupTrace = _activeStartupTrace;
    startupTrace?.mark('player:$operation:start');
    var timedOut = false;
    final elapsed = Stopwatch()..start();
    final operationPlayer = _player;
    try {
      final progress =
          extendWhileDownloading && _radioStation == null && songId != null
          ? _PlaybackProgressDeadline(
              initial: timeout,
              idle: _timeouts.progressIdle,
              hardCap: fixedLoadDeadline || timeout > _timeouts.seekProgress
                  ? timeout
                  : _timeouts.seekProgress,
              bytes: _receivedCacheBytesForSong(songId, includeRanges: true),
              buffer: _isDesktopRuntime
                  ? Duration.zero
                  : operationPlayer.bufferedPosition,
            )
          : null;
      final operationFuture = action();
      unawaited(
        operationFuture.then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {
            if (!timedOut && _isActiveLoadGeneration(generation)) {
              return;
            }
            final loggedError = operation == 'radio source apply'
                ? error.runtimeType
                : error;
            AppLogger.debug(
              'Ignoring late player operation failure for "$operation" '
              '(song=${songId ?? 'n/a'} generation=$generation): '
              '$loggedError\n$stackTrace',
            );
          },
        ),
      );
      final result = progress == null
          ? await operationFuture.timeout(timeout)
          : await _waitForProgressingLoad(
              operationFuture,
              progress,
              player: operationPlayer,
              songId: songId!,
              generation: generation,
              isCurrent: isCurrent,
            );
      startupTrace?.mark('player:$operation:complete');
      if (cancelAfterSuccess && !_isActiveLoadGeneration(generation)) {
        throw OperationCancelledException();
      }
      return result;
    } on TimeoutException {
      final timeoutDuration = elapsed.elapsed;
      startupTrace?.mark('player:$operation:timeout');
      timedOut = true;
      final isCurrent = _isActiveLoadGeneration(generation);
      _transportTrace.record(
        'recovery',
        () => <String, Object?>{
          'decision': 'playerOperationTimedOut',
          'operation': operation,
          'songId': songId,
          'timeoutMs': timeout!.inMilliseconds,
          'current': isCurrent,
        },
      );
      if (isCurrent) _lastFailedSongId = songId;
      if (isCurrent && songId != null) {
        _markSongLockCachingBypassed(
          songId,
          reason: 'player operation "$operation" timed out',
        );
      }
      AppLogger.warning(
        'Playback operation "$operation" timed out after '
        '${(timeoutDuration.inMilliseconds / 1000).toStringAsFixed(1)}s; '
        'recovering the player.',
      );
      final capture = (
        index: _player.currentIndex,
        position: _player.position,
        playing: _player.playing,
      );
      // An enclosing restore timeout may already have retired this player.
      if (identical(_player, operationPlayer)) {
        await _recoverPlayersFromTimeout(
          generation: generation,
          operation: operation,
          songId: songId,
        );
      }
      if (reloadQueueOnTimeout && isCurrent) {
        await _reloadQueueAfterTimeout(capture);
      }
      if (!isCurrent) throw OperationCancelledException();
      throw PlaybackLoadTimeoutException(
        operation: operation,
        songId: songId,
        timeoutDuration: timeoutDuration,
      );
    }
  }

  Future<T> _waitForProgressingLoad<T>(
    Future<T> operation,
    _PlaybackProgressDeadline progress, {
    required AudioPlayer player,
    required String songId,
    required int generation,
    bool Function()? isCurrent,
  }) async {
    final elapsed = Stopwatch()..start();
    var done = false;
    final completed = operation.whenComplete(() => done = true);
    // Observe failures while polling; completed rethrows below.
    final completion = completed.then<void>((_) {}, onError: (Object _) {});
    while (!done) {
      final now = elapsed.elapsed;
      // A new song must retire this engine before its successor uses the lane.
      if (!_isActiveLoadGeneration(generation)) {
        throw TimeoutException('Native load superseded');
      }
      if (isCurrent != null && !isCurrent()) {
        throw OperationCancelledException();
      }
      final canExtend =
          _queueLane.pendingCount == 0 ||
          (_queueLane.pendingCount == 1 && _pendingSeek?.songId == songId);
      if (canExtend) {
        progress.observe(
          now,
          bytes: _receivedCacheBytesForSong(songId, includeRanges: true),
          buffer: _isDesktopRuntime ? Duration.zero : player.bufferedPosition,
          processing: player.processingState,
        );
      }
      if (progress.expired(now) || (!canExtend && now >= progress.initial)) {
        throw TimeoutException('Native load stalled');
      }
      await Future.any<void>([
        completion,
        Future<void>.delayed(const Duration(milliseconds: 250)),
      ]);
    }
    return await completed;
  }

  /// Loads the materialised queue into a player rebuilt after a queue edit
  /// timed out, at the same song and position. Without it the Dart queue
  /// would list songs the empty player does not hold. Runs inside the lane
  /// work that timed out, so waiting edits see matching queues. Songs past
  /// the release window go back to the deferred tail; songs that can no
  /// longer be prepared are dropped.
  Future<void> _reloadQueueAfterTimeout(
    ({int? index, Duration position, bool playing}) capture,
  ) async {
    if (_queueItems.isEmpty) return;
    _anomalies.event('reload', {
      'via': 'queue',
      'targetMs': capture.position.inMilliseconds,
    });
    var current = (capture.index ?? 0).clamp(0, _queueItems.length - 1);
    // The captured index is the player's, but the Dart queue may already
    // carry the edit (an entry removed ahead of the playing song, which has
    // not happened natively): follow the song that was playing instead.
    final playingId = _currentMediaItem?.id;
    if (playingId != null && _queueItems[current].id != playingId) {
      final moved = <int>[
        for (var i = 0; i < _queueItems.length; i++)
          if (_queueItems[i].id == playingId) i,
      ]..sort((a, b) => (a - current).abs().compareTo((b - current).abs()));
      if (moved.isNotEmpty) current = moved.first;
    }
    final end = math.min(_queueItems.length, current + _queueWindow.ahead + 1);
    final items = _queueItems.sublist(0, end);
    final beyond = _queueItems.sublist(end);
    try {
      final rows = await _rowsForDeferredEntries(
        items.map(_deferredEntryForItem).toList(growable: false),
      );
      final (:prepared, :offsets) = await _prepareRowsConcurrently(rows);
      if (prepared.isEmpty) {
        throw StateError('No queued song can be prepared.');
      }
      // The current song, or the next one that is still available.
      final landed =
          offsets.skip(current).nonNulls.firstOrNull ?? prepared.length - 1;
      final dropped = <String>[
        for (var i = 0; i < items.length; i++)
          if (offsets[i] == null) items[i].id,
      ];
      _queueItems
        ..clear()
        ..addAll(prepared.map((item) => item.mediaItem));
      _deferredTail.insertAll(0, beyond.map(_deferredEntryForItem));
      await _player
          .setAudioSources(
            prepared.map((item) => item.audioSource).toList(growable: false),
            initialIndex: landed,
            initialPosition: offsets[current] == null
                ? Duration.zero
                : capture.position,
          )
          .timeout(_playerLoadTimeout);
      _observeLockCacheForPrepared(prepared);
      _setCurrentMediaItem(_queueItems[landed]);
      _reportDroppedSongs(dropped, QueueDropReason.rebuild);
      if (dropped.isNotEmpty) {
        AppLogger.warning(
          'Queue reload after a timeout dropped ${dropped.length} songs '
          'that could not be prepared: ${dropped.take(8).join(', ')}',
        );
      }
      if (_requestedPlaying) unawaited(_playWithFocusRecovery());
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Could not reload the queue after a player timeout. '
        '$error\n$stackTrace',
      );
    }
    _afterQueueEdit(context: 'reload queue after timeout');
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

  Future<void> _setQueueFromSongs(
    List<SongsTableData> songs, {
    required int startIndex,
    required bool autoPlay,
    Duration initialPosition = Duration.zero,
    required bool persist,
    bool preloadWhenPaused = true,
    bool forcePreloadWhenPaused = false,
    int generation = 0,
    OperationToken? token,
  }) async {
    final wasLoading = _isLoading;
    final selectionGeneration = generation > 0
        ? generation
        : _activeLoadGeneration;
    if (songs.isNotEmpty) {
      token?.checkCancelled();
      if (!_isActiveLoadGeneration(selectionGeneration)) {
        throw OperationCancelledException();
      }
      final start = startIndex.clamp(0, songs.length - 1);
      _isLoading = true;
      _loadingSongId = songs[start].id;
      _setQueueReplacementMetadataAnchor(
        expectedIndex: start,
        mediaItem: _mediaItemForSong(songs[start]),
      );
      _setCurrentMediaItem(_queueReplacementMetadataAnchor!.mediaItem);
      _broadcastPlaybackState();
      _emitSnapshot();
    }
    try {
      List<_PreparedQueueItem> prepared;
      try {
        prepared = await _prepareQueueItems(songs, preferLockCaching: true);
      } on PlaybackSourceUnavailableException {
        token?.checkCancelled();
        rethrow;
      } on Object catch (error, stackTrace) {
        token?.checkCancelled();
        AppLogger.warning(
          'Queue preparation failed while lock-cached sources were enabled. '
          'Retrying with direct-stream sources. '
          '$error\n$stackTrace',
        );
        prepared = await _prepareQueueItems(songs, preferLockCaching: false);
      }

      token?.checkCancelled();
      if (!_isActiveLoadGeneration(selectionGeneration)) {
        throw OperationCancelledException();
      }
      if (prepared.isEmpty) {
        await _clearQueueInternal(persist: persist);
        return;
      }

      final clampedIndex = startIndex.clamp(0, prepared.length - 1);
      Future<void> apply() => _applyPreparedQueue(
        prepared,
        startIndex: clampedIndex,
        autoPlay: autoPlay,
        initialPosition: initialPosition,
        preloadWhenPaused: preloadWhenPaused,
        forcePreloadWhenPaused: forcePreloadWhenPaused,
        generation: selectionGeneration,
        token: token,
      );
      try {
        await apply();
      } on Object catch (error, stackTrace) {
        token?.checkCancelled();
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
          await _rebuildPlayerWithoutEqualizer();
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
        prepared = await _prepareQueueItems(songs, preferLockCaching: false);
        try {
          await apply();
        } on Object catch (retryError, retryStackTrace) {
          token?.checkCancelled();
          if (!_isAndroidDspInitializationFailure(retryError)) {
            rethrow;
          }
          AppLogger.warning(
            'Direct-stream queue apply still hit Android DSP initialization '
            'failure. Forcing plain player rebind and retrying once more. '
            '$retryError\n$retryStackTrace',
          );
          await _rebuildPlayerWithoutEqualizer();
          await apply();
        }
      }

      _observeLockCacheForPrepared(prepared);

      if (persist) {
        await _persistSafely(
          () => _persistQueueState(includeQueueItems: true),
          context: 'queue replacement',
        );
      }

      _broadcastPlaybackState();
      _emitSnapshot();
    } finally {
      if (!wasLoading) _completeQueueLoad(selectionGeneration);
    }
  }

  Future<List<_PreparedQueueItem>> _prepareQueueItems(
    List<SongsTableData> songs, {
    required bool preferLockCaching,
  }) async {
    // Resolutions are independent; run a bounded chunk at a time. Order is
    // preserved and the first failure still propagates to the caller.
    const chunkSize = 64;
    final prepared = <_PreparedQueueItem>[];
    for (var offset = 0; offset < songs.length; offset += chunkSize) {
      prepared.addAll(
        await Future.wait(
          songs
              .skip(offset)
              .take(chunkSize)
              .map(
                (song) => _prepareSingleItem(
                  song,
                  preferLockCaching: preferLockCaching,
                ),
              ),
        ),
      );
    }
    _shareLockCacheSources(prepared);
    return prepared;
  }

  /// The lock-cache source already registered for [source]'s cache file, if
  /// any. A rebuilt queue (shuffle, reload) must keep playing from it, whether
  /// or not its download has started: a second source on the same `.part`
  /// would start a second overlapping origin download, and the next-song warm
  /// targets the registered one. Completion, error and teardown unregister it;
  /// a cancelled source stays usable (a later request downloads again).
  IndexedAudioSource? _runningLockCacheSource(ResolvedPlaybackSource source) {
    final path = source.cachedFilePath;
    if (source.kind != PlaybackSourceKind.lockCachedStream || path == null) {
      return null;
    }
    return _lockCacheSources[path]?.source;
  }

  /// Within one prepared batch the first source per cache file wins, so a song
  /// that occurs twice is one source, one download.
  void _shareLockCacheSources(List<_PreparedQueueItem> prepared) {
    // ignore: experimental_member_use, reason: as above.
    final first = <String, LockCachingAudioSource>{};
    for (final item in prepared) {
      final path = item.source.cachedFilePath;
      final own = item.audioSource;
      // ignore: experimental_member_use, reason: as above.
      if (path == null || own is! LockCachingAudioSource) continue;
      item.audioSource = first.putIfAbsent(path, () => own);
    }
  }

  MediaItem _mediaItemForSong(
    SongsTableData song, {
    ResolvedPlaybackSource? source,
  }) {
    return MediaItem(
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
  }

  /// Resolves a song with the standard lock-caching → direct stream fallback.
  ///
  /// [transcodeOffset] opens a server transcode that far into the song (the
  /// resolver never lock-caches such a stream).
  Future<_PreparedQueueItem> _prepareSingleItem(
    SongsTableData song, {
    required bool preferLockCaching,
    Duration? transcodeOffset,
    bool fastSeekBridge = false,
    _PendingSeek? seekPreviewRequest,
  }) async {
    await (_cacheMaintenance ??= _maintainCacheBeforePlayback());
    final startupTrace = _activeStartupTrace;
    if (startupTrace?.songId == song.id) {
      startupTrace?.markOnce('sourceResolutionStart');
    }
    final effectivePreferLockCaching = _shouldPreferLockCachingForSong(
      song.id,
      preferLockCaching: preferLockCaching,
    );
    ResolvedPlaybackSource source;
    try {
      source = await _sourceResolver.resolveForSong(
        song,
        preferLockCaching: effectivePreferLockCaching,
        transcodeOffset: transcodeOffset,
        fastSeekBridge: fastSeekBridge,
      );
    } on PlaybackSourceUnavailableException {
      rethrow;
    } on Object catch (error, stackTrace) {
      if (!effectivePreferLockCaching) rethrow;
      _markSongLockCachingBypassed(song.id, reason: 'source resolution failed');
      AppLogger.warning(
        'Source resolution failed for song=${song.id} '
        'with lock-cached preference. Falling back to direct stream. '
        '$error\n$stackTrace',
      );
      source = await _sourceResolver.resolveForSong(
        song,
        preferLockCaching: false,
        transcodeOffset: transcodeOffset,
        fastSeekBridge: fastSeekBridge,
      );
    }
    final preview = seekPreviewRequest == null
        ? null
        : _takeSeekPreview(song, source, seekPreviewRequest);
    final item = _mediaItemForSong(song, source: source);
    _traceSourceResolved(song, source);
    if (startupTrace?.songId == song.id) {
      startupTrace?.sourceKind = source.kind.name;
      startupTrace?.markOnce('sourceResolutionComplete');
    }
    if (source.sidecarCacheFilePath != null) {
      // An offset source downloads the full, non-offset stream.
      _rememberSidecarSong(
        song,
        source.sidecarStreamUri ?? source.uri ?? source.lockCachingStreamUri,
      );
    }
    _rememberRemoteRow(song);
    return _PreparedQueueItem(
      song: song,
      source: source,
      mediaItem: item,
      audioSource:
          preview?.request?.asAudioSource(
            tag: item,
            positionOffset: source.positionOffset,
          ) ??
          _runningLockCacheSource(source) ??
          source.asAudioSource(tag: item),
    );
  }

  /// [onRetryLater] is called instead of logging a skip when the song may
  /// become playable again (offline, or no session yet).
  Future<_PreparedQueueItem?> _prepareSingleItemForQueueFill(
    SongsTableData song, {
    void Function()? onRetryLater,
  }) async {
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
    } on PlaybackSourceTemporarilyUnavailableException catch (error) {
      if (onRetryLater == null) {
        AppLogger.warning(
          'Queue fill source unavailable for song=${song.id}; skipping. '
          '$error',
        );
      }
      onRetryLater?.call();
      return null;
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
    // Open the start song's transcode this far into the song.
    Duration? transcodeOffset,
    bool fastSeekBridge = false,
    // False once the request that asked for this reload is superseded: its
    // source is then dropped before it stops the playing song.
    bool Function()? isStillWanted,
    // A start source the caller already has (a completed sidecar file).
    _PreparedQueueItem? preparedStart,
    // Leave the song paused; the caller resumes it once it has landed.
    bool holdPlayback = false,
  }) async {
    _transportTrace.record(
      'queueFill',
      () => <String, Object?>{
        'phase': 'phase1Start',
        'requested': songs.length,
        'startIndex': startIndex,
      },
    );
    if (songs.isEmpty) {
      await _clearQueueInternal(persist: persist);
      return null;
    }

    final clampedIndex = startIndex.clamp(0, songs.length - 1);
    final startSong = songs[clampedIndex];
    _checkQueueWorkCurrent(token, generation);
    _isLoading = true;
    _loadingSongId = startSong.id;
    _setQueueReplacementMetadataAnchor(
      expectedIndex: clampedIndex,
      mediaItem: _mediaItemForSong(startSong),
    );
    _setCurrentMediaItem(_queueReplacementMetadataAnchor!.mediaItem);
    _emitSnapshot();
    final startupTrace = _activeStartupTrace;
    startupTrace?.markOnce('selectedSourcePreparationStart');

    // Resolve the target song's playback source.
    _PreparedQueueItem startItem;
    if (preparedStart != null) {
      startItem = preparedStart;
    } else {
      try {
        startItem = await _prepareSingleItem(
          startSong,
          preferLockCaching: preferLockCaching,
          transcodeOffset: transcodeOffset,
          fastSeekBridge: fastSeekBridge,
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
          transcodeOffset: transcodeOffset,
          fastSeekBridge: fastSeekBridge,
        );
      }
    }

    // Pause independently of stop so a hung native stop cannot stay audible.
    _checkQueueWorkCurrent(token, generation);
    if (isStillWanted != null && !isStillWanted()) {
      // ignore: experimental_member_use, reason: Drop an adopted response before native attachment.
      if (startItem.audioSource case final StreamAudioSource source) {
        source.dispose();
      }
      throw OperationCancelledException();
    }
    _cancelCrossfade();
    try {
      await _runTimedPlayerOperation(
        generation: generation,
        operation: 'replace queue phase 1 pause',
        action: _player.pause,
        songId: startSong.id,
        timeout: _playerControlTimeout,
      );
      final deck = _crossfadePlayer;
      if (deck != null) {
        await _runTimedPlayerOperation(
          generation: generation,
          operation: 'replace queue phase 1 pause deck',
          action: deck.pause,
          songId: startSong.id,
          timeout: _playerControlTimeout,
        );
      }
      await _runTimedPlayerOperation(
        generation: generation,
        operation: 'replace queue phase 1 stop',
        action: _player.stop,
        songId: startSong.id,
        timeout: _playerResetTimeout,
      );
    } on PlaybackLoadTimeoutException {
      // Reset retired the hung deck and rebuilt an empty player. The selected
      // source has not failed: continue loading it on the replacement player.
      _checkQueueWorkCurrent(token, generation);
    }
    _broadcastPlaybackState();
    _emitSnapshot();

    if ((startItem.song.isExternal ||
            isExternalCatalogSource(id: startItem.song.id)) &&
        !startItem.source.isLocal) {
      await _warmRemoteStream(
        startItem.source.uri ?? startItem.source.lockCachingStreamUri,
        stillWanted: () =>
            !token.isCancelled && _isActiveLoadGeneration(generation),
      );
      startupTrace?.mark('remoteWarmupComplete');
    }

    _checkQueueWorkCurrent(token, generation);
    await _clearDeferredTail();
    _checkQueueWorkCurrent(token, generation);
    // Native index 0 must resolve to the selected occurrence as soon as
    // setAudioSources starts emitting events, including single-song loads.
    _restoredQueueIndex = null;
    _queueItems
      ..clear()
      ..add(startItem.mediaItem);
    _setQueueReplacementMetadataAnchor(
      expectedIndex: clampedIndex,
      mediaItem: startItem.mediaItem,
    );
    _setCurrentMediaItem(startItem.mediaItem);
    _emitSnapshot();
    startupTrace?.mark('selectedSourceApplyStart');
    try {
      await _setAudioSourcesWithFallback(
        audioSources: <AudioSource>[startItem.audioSource],
        preload: true,
        initialIndex: 0,
        initialPosition: initialPosition,
        generation: generation,
        songId: startSong.id,
        timeout: _loadTimeoutFor(startItem),
      );
    } on OperationCancelledException {
      rethrow;
    } on Object catch (error, stackTrace) {
      _checkQueueWorkCurrent(token, generation);
      final seek = _pendingSeek;
      final retryColdSeek =
          error is PlaybackLoadTimeoutException &&
          _isDesktopRuntime &&
          initialPosition == Duration.zero &&
          seek != null &&
          !seek.isRemoteRecovery &&
          seek.songId == startSong.id &&
          seek.recoveryAttempts == 0;
      if (!retryColdSeek &&
          startItem.source.kind != PlaybackSourceKind.lockCachedStream) {
        rethrow;
      }
      _markSongLockCachingBypassed(
        startSong.id,
        reason: 'phase 1 queue apply failed',
      );
      if (retryColdSeek) {
        seek
          ..recoveryAttempts = 1
          ..stage = 'recovering';
        initialPosition = seek.position;
        _setCurrentMediaItem(startItem.mediaItem);
        if (await _shouldSeekViaTranscodeOffset(seek.position, seek, token)) {
          transcodeOffset = Duration(seconds: seek.position.inSeconds);
          seek.path = 'transcodeOffset';
        }
      }
      AppLogger.warning(
        'Phase 1 queue apply failed; preparing a fresh source. '
        '$error\n$stackTrace',
      );
      // The retired player disposes its attached AudioSources asynchronously.
      startItem = await _prepareSingleItem(
        startSong,
        preferLockCaching: false,
        transcodeOffset: transcodeOffset,
        fastSeekBridge: fastSeekBridge,
      );
      _checkQueueWorkCurrent(token, generation);
      _queueItems
        ..clear()
        ..add(startItem.mediaItem);
      if (songs.length > 1 || retryColdSeek) {
        _setQueueReplacementMetadataAnchor(
          expectedIndex: clampedIndex,
          mediaItem: startItem.mediaItem,
        );
      }
      if (retryColdSeek) _setCurrentMediaItem(startItem.mediaItem);
      await _setAudioSourcesWithFallback(
        audioSources: <AudioSource>[startItem.audioSource],
        preload: true,
        initialIndex: 0,
        initialPosition: initialPosition,
        generation: generation,
        songId: startSong.id,
        // A cold retry must outlive the first load's silent-body deadline.
        // This is still one bounded source retry, including offset startup.
        timeout: retryColdSeek
            ? _timeouts.seekProgress
            : _loadTimeoutFor(startItem),
      );
    }
    _checkQueueWorkCurrent(token, generation);
    startupTrace?.mark('selectedSourceApplyComplete');

    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _setCurrentMediaItem(startItem.mediaItem);

    if (!holdPlayback &&
        (_latestExplicitTransportPlaying == true ||
            (autoPlay && _latestExplicitTransportPlaying != false))) {
      unawaited(_playWithFocusRecovery());
    } else {
      await _player.pause();
    }

    _observeLockCacheForPrepared([startItem]);

    _broadcastPlaybackState();
    _emitSnapshot();

    return startItem;
  }

  /// Resolves [batch] and applies every playable source with one [apply]
  /// call. Returns the number of sources applied to the player.
  ///
  /// A timeout leaves the player in an uncertain state and is rethrown, as is
  /// cancellation. Any other failure skips the whole batch, matching the
  /// previous per-song skip semantics at batch granularity.
  Future<int> _fillQueueBatch({
    required List<SongsTableData> batch,
    required int firstOriginalIndex,
    required Map<int, _PreparedQueueItem> preparedByIndex,
    required List<String> skippedSongIds,
    required int generation,
    required OperationToken token,
    required String operation,
    required Future<void> Function(List<AudioSource> sources) apply,
  }) async {
    _checkQueueWorkCurrent(token, generation);
    // Each resolution is independent and mostly waits on a database or file
    // check, so resolve the batch concurrently. Results keep queue order.
    final resolveWatch = Stopwatch()..start();
    final resolved = await Future.wait(
      batch.map(_prepareSingleItemForQueueFill),
    );
    _queueFillResolveMs += resolveWatch.elapsedMilliseconds;
    final prepared = <_PreparedQueueItem>[];
    final preparedIndexes = <int>[];
    for (var j = 0; j < batch.length; j++) {
      final item = resolved[j];
      if (item == null) {
        skippedSongIds.add(batch[j].id);
        continue;
      }
      prepared.add(item);
      preparedIndexes.add(firstOriginalIndex + j);
    }
    _shareLockCacheSources(prepared);
    _checkQueueWorkCurrent(token, generation);
    if (prepared.isEmpty) {
      return 0;
    }
    final applyWatch = Stopwatch()..start();
    try {
      _queueFillBatches++;
      await _runTimedPlayerOperation(
        generation: generation,
        operation: operation,
        action: () => apply(
          prepared.map((item) => item.audioSource).toList(growable: false),
        ),
        songId: prepared.first.song.id,
        reloadQueueOnTimeout: true,
      );
    } on PlaybackLoadTimeoutException catch (error) {
      _lastFailedSongId = error.songId ?? prepared.first.song.id;
      AppLogger.warning(
        'Queue fill "$operation" timed out for ${prepared.length} songs; '
        'aborting the uncertain player state.',
      );
      rethrow;
    } on OperationCancelledException {
      rethrow;
    } on Object catch (error, stackTrace) {
      for (final item in prepared) {
        skippedSongIds.add(item.song.id);
        _markSongLockCachingBypassed(
          item.song.id,
          reason: 'queue fill batch failed',
        );
      }
      AppLogger.warning(
        'Queue fill "$operation" failed for ${prepared.length} songs; '
        'skipping the batch. $error\n$stackTrace',
      );
      return 0;
    }
    _queueFillNativeMs += applyWatch.elapsedMilliseconds;
    _transportTrace.record(
      'queueFill',
      () => <String, Object?>{
        'phase': 'append',
        'operation': operation,
        'count': prepared.length,
        'firstSongId': prepared.first.song.id,
        'applyMs': applyWatch.elapsedMilliseconds,
      },
    );
    for (var j = 0; j < prepared.length; j++) {
      preparedByIndex[preparedIndexes[j]] = prepared[j];
    }
    _checkQueueWorkCurrent(token, generation);
    _observeLockCacheForPrepared(prepared);
    return prepared.length;
  }

  Future<void> _applyPreparedQueue(
    List<_PreparedQueueItem> prepared, {
    required int startIndex,
    required bool autoPlay,
    required Duration initialPosition,
    required bool preloadWhenPaused,
    bool forcePreloadWhenPaused = false,
    int generation = 0,
    OperationToken? token,
  }) async {
    token?.checkCancelled();
    if (!_isActiveLoadGeneration(generation)) {
      throw OperationCancelledException();
    }
    _queueItems
      ..clear()
      ..addAll(prepared.map((entry) => entry.mediaItem));
    _restoredQueueIndex = null;
    await _clearDeferredTail();
    token?.checkCancelled();
    if (!_isActiveLoadGeneration(generation)) {
      throw OperationCancelledException();
    }

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
      token: token,
    );
    token?.checkCancelled();
    if (!_isActiveLoadGeneration(generation)) {
      throw OperationCancelledException();
    }
    await _clearInactiveDeckForQueueChange(
      generation: generation,
      songId: prepared[startIndex].song.id,
    );

    token?.checkCancelled();
    if (!_isActiveLoadGeneration(generation)) {
      throw OperationCancelledException();
    }
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _setCurrentMediaItem(_queueItems[startIndex]);

    // IMPORTANT: Do NOT await _player.play() here.  play() returns a Future
    // that only completes when playback finishes or is interrupted.  Awaiting
    // it inside a _runSerialized block would deadlock all subsequent serialized
    // operations (pause, seek, skip, queue mutations) until the track ends.
    if (autoPlay) {
      unawaited(_playWithFocusRecovery());
    } else {
      await _player.pause();
    }
  }

  Future<void> _setAudioSourcesWithFallback({
    required List<AudioSource> audioSources,
    required bool preload,
    required int initialIndex,
    required Duration initialPosition,
    int generation = 0,
    String? songId,
    Duration? timeout,
    OperationToken? token,
  }) async {
    // A new load replaces the failed source, even one left unprepared.
    _loadedSourceFailed = false;
    const operations = <String>[
      'active queue apply',
      'active queue apply retry',
      'active queue apply final retry',
    ];
    Future<Duration?> apply() => _player.setAudioSources(
      audioSources,
      preload: preload,
      initialIndex: initialIndex,
      initialPosition: initialPosition,
    );
    token?.checkCancelled();
    _tracedNativeIndex = null;
    _tracedCurrentSong = null;
    _transportTrace.record(
      'setAudioSources',
      () => <String, Object?>{
        'count': audioSources.length,
        'initialIndex': initialIndex,
        'initialPositionMs': initialPosition.inMilliseconds,
        'songId': songId,
        'preload': preload,
      },
    );
    for (var attempt = 0; attempt < operations.length; attempt++) {
      try {
        if (generation > 0) {
          await _runTimedPlayerOperation(
            generation: generation,
            operation: operations[attempt],
            timeout: timeout,
            action: apply,
            songId: songId,
            extendWhileDownloading: preload,
            // Poll cancellation with hardCap == initial for offset loads.
            fixedLoadDeadline:
                _isDesktopRuntime && initialPosition != Duration.zero,
          );
        } else {
          await apply();
        }
        break;
      } on Object catch (error, stackTrace) {
        if (attempt == operations.length - 1) rethrow;
        token?.checkCancelled();
        if (!_isAndroidDspInitializationFailure(error)) rethrow;
        AppLogger.warning(
          attempt == 0
              ? 'Android DSP initialization failed during queue apply. '
                    'Disabling DSP pipeline for this session and retrying. '
                    '$error\n$stackTrace'
              : 'Android DSP fallback retry failed again. Rebuilding a plain player '
                    'instance and retrying one final time. '
                    '$error\n$stackTrace',
        );
        await _rebuildPlayerWithoutEqualizer();
      }
    }
    token?.checkCancelled();
    await _restoreActivePlayerVolume();
  }

  /// Waits, up to [NavisPlaybackTimeouts.remoteLoad], for the server to answer
  /// a request for the first bytes of a remote song's stream. A server that
  /// fetches a remote song on its first play (Octo-Fiesta) sends nothing
  /// until the whole file has arrived; players give up on such a silent
  /// connection long before that (ExoPlayer after 8 s, through the lock-cache
  /// proxy too), while once the server has the file it answers at once.
  /// Failures are left to the player's own load; a newer command
  /// ([stillWanted] turning false) ends the wait at once.
  Future<void> _warmRemoteStream(
    Uri? uri, {
    required bool Function() stillWanted,
  }) async {
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return;
    }
    final client = HttpClient()..connectionTimeout = _timeouts.remoteLoad;
    final answered = () async {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');
      final response = await request.close();
      await response.firstWhere((chunk) => chunk.isNotEmpty);
    }();
    final elapsed = Stopwatch()..start();
    var done = false;
    unawaited(
      answered.then<void>(
        (_) => done = true,
        onError: (Object error) {
          done = true;
          AppLogger.debug('Remote stream warm-up ended: ${error.runtimeType}');
        },
      ),
    );
    while (!done && stillWanted() && elapsed.elapsed < _timeouts.remoteLoad) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    client.close(force: true);
  }

  /// The native load deadline for a queue starting at [item].
  Duration _loadTimeoutFor(_PreparedQueueItem item) =>
      (item.song.isExternal || isExternalCatalogSource(id: item.song.id)) &&
          !item.source.isLocal
      ? _timeouts.remoteLoad
      : _playerLoadTimeout;

  Future<void> _restoreActivePlayerVolume() {
    final target = _isDucked ? _userVolume * 2 / 5 : _userVolume;
    return _player.setVolume(target.clamp(0.0, 1.0));
  }

  bool _isAndroidDspInitializationFailure(Object error) {
    return navisIsAndroidDspInitializationFailure(
      error,
      isAndroidRuntime: _isAndroidRuntime,
    );
  }

  Future<void> _rebuildPlayerWithoutEqualizer() async {
    _anomalies.event('reload', {'via': 'equalizer'});
    final previousPlayer = _player;
    final previousLoopMode = previousPlayer.loopMode;

    _equalizerPipelineEnabled = false;
    _emitEqualizerState(
      const EqualizerStateMessage(
        enabled: false,
        reason:
            'EQ was bypassed because the audio engine could not initialize it.',
      ),
    );
    await _disposePlayerListeners();
    _player = _buildAudioPlayer(enableEqualizer: false);
    _wirePlayerListeners();
    _rebindRadioMetadataServiceToActivePlayer();

    await _restoreActivePlayerVolume();
    await _applyAdjustmentsToPlayer(_player, _appliedAdjustments);
    await _player.setLoopMode(previousLoopMode);

    await previousPlayer.dispose();
    final inactiveDeck = _crossfadePlayer;
    if (inactiveDeck != null) {
      try {
        await inactiveDeck.dispose();
      } on Object {
        // Best-effort reset only.
      }
    }
    _crossfadePlayer = _crossfadeEnabled ? _newCrossfadePlayer() : null;
  }

  /// Maps a requested occurrence past rows the DAO could no longer resolve.
  int _startIndexAfterRowResolution(
    List<String> ids,
    int startIndex,
    List<SongsTableData> songs,
  ) {
    if (songs.isEmpty) return 0;
    final available = songs.map((song) => song.id).toSet();
    final beforeSelection = ids
        .take(startIndex.clamp(0, ids.length - 1))
        .where((id) => available.contains(id.trim()))
        .length;
    return beforeSelection.clamp(0, songs.length - 1);
  }

  int _admitQueueReplacement(
    List<String> ids, {
    required int startIndex,
    required bool autoPlay,
    required bool inPlayOrder,
    required bool shuffled,
    List<SongsTableData>? suppliedRows,
  }) {
    // The first broadcast of the new queue already carries its mode. The
    // original order follows in [_applyNewQueueMode], once the rows are known:
    // saving the old queue against it would reconcile it away.
    if (!inPlayOrder) _shuffleEnabled = shuffled;
    _cancelCrossfade();
    _restoredQueueIndex = null;
    _restoredQueuePosition = Duration.zero;
    _navigationIntent.reset();
    _pendingLogicalQueueSongs = suppliedRows;
    _supersedeTransportIntent(shouldPlay: autoPlay);
    final start = ids.isEmpty ? 0 : startIndex.clamp(0, ids.length - 1);
    if (ids.isNotEmpty) {
      _navigationIntent.select(start);
      _acceptStartupSelection(
        ids[start],
        isExternal: isExternalCatalogSource(
          id: ids[start],
          apiIsExternal: suppliedRows?[start].isExternal ?? false,
        ),
      );
    }
    return _supersedeQueueWork(
      isLoading: ids.isNotEmpty,
      loadingSongId: ids.isEmpty ? null : ids[start],
      pendingLogicalQueueSongIds: ids.length > 1 ? ids : null,
    );
  }

  /// [inPlayOrder] is for reloading the current queue (failure recovery):
  /// the songs are already in play order and are never shuffled again.
  Future<void> _replaceQueueIds(
    List<String> songIds, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    required bool inPlayOrder,
    List<String>? originalOrder,
  }) async {
    final canonicalIds = songIds.map(_canonicalSongId).toList(growable: false);
    final admittedGeneration = _admitQueueReplacement(
      canonicalIds,
      startIndex: startIndex,
      autoPlay: autoPlay,
      inPlayOrder: inPlayOrder,
      shuffled: originalOrder != null,
    );
    if (canonicalIds.isNotEmpty) {
      final selected =
          canonicalIds[startIndex.clamp(0, canonicalIds.length - 1)];
      final song = await _libraryDao.getSongById(selected);
      if (!_isActiveLoadGeneration(admittedGeneration)) return;
      if (song != null) {
        _setQueueReplacementMetadataAnchor(
          expectedIndex: _navigationIntent.desiredIndex ?? 0,
          mediaItem: _mediaItemForSong(song),
        );
        _setCurrentMediaItem(_queueReplacementMetadataAnchor!.mediaItem);
        _emitSnapshot();
      }
    }
    final expansion = await _expandMatchFlowIds(
      canonicalIds,
      startIndex: startIndex,
      expandMatchFlows: expandMatchFlows,
    );
    if (!_isActiveLoadGeneration(admittedGeneration)) return;
    _applyNewQueueMode(
      inPlayOrder: inPlayOrder,
      originalOrder: originalOrder
          ?.map(_canonicalSongId)
          .toList(growable: false),
    );
    final orderedIds = expansion.songIds;
    final orderedStart = expansion.startIndex;
    await _runQueueReplacement(
      songIds: orderedIds,
      startIndex: orderedStart,
      autoPlay: autoPlay,
      context: 'replaceQueue',
      resolve: () async {
        final songs = await _libraryDao.getSongsByIds(orderedIds);
        return (
          songs,
          _startIndexAfterRowResolution(orderedIds, orderedStart, songs),
        );
      },
      recover: ({required startIndex, required autoPlay}) => _replaceQueueIds(
        orderedIds,
        startIndex: startIndex,
        autoPlay: autoPlay,
        expandMatchFlows: false,
        inPlayOrder: true,
      ),
    );
  }

  /// [inPlayOrder] as for [_replaceQueueIds].
  Future<void> _replaceQueueRows(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
    required bool inPlayOrder,
    List<String>? originalOrder,
  }) async {
    // Whole-entity playback retains supplied remote sources even when they
    // have since been matched to a local identity.
    final canonicalIds = navisQueueSourceIds(
      songs,
      canonicalize: _canonicalSongId,
    );
    final admittedGeneration = _admitQueueReplacement(
      canonicalIds,
      startIndex: startIndex,
      autoPlay: autoPlay,
      inPlayOrder: inPlayOrder,
      shuffled: originalOrder != null,
      suppliedRows: songs,
    );
    // Mixed-source queues keep every row, including a retired local identity;
    // ID-based expansion or rereading could replace the remote source.
    final hasExternalSource = songs.any((song) => song.isExternal);
    final hasRetiredIdentity =
        !hasExternalSource &&
        Iterable<int>.generate(songs.length)
            .any((index) => canonicalIds[index] != songs[index].id);
    if (hasRetiredIdentity) {
      final canonicalSongs = await _libraryDao.getSongsByIds(canonicalIds);
      if (!_isActiveLoadGeneration(admittedGeneration)) return;
      await _replaceQueueRows(
        canonicalSongs,
        startIndex: _startIndexAfterRowResolution(
          canonicalIds,
          startIndex,
          canonicalSongs,
        ),
        autoPlay: autoPlay,
        expandMatchFlows: expandMatchFlows,
        inPlayOrder: inPlayOrder,
        originalOrder: originalOrder
            ?.map(_canonicalSongId)
            .toList(growable: false),
      );
      return;
    }
    if (expandMatchFlows && songs.isNotEmpty && !hasExternalSource) {
      final expansion = await _expandMatchFlowIds(
        songs.map((song) => song.id).toList(growable: false),
        startIndex: startIndex,
        expandMatchFlows: true,
      );
      final expandedSongs = await _libraryDao.getSongsByIds(expansion.songIds);
      if (!_isActiveLoadGeneration(admittedGeneration)) return;
      await _replaceQueueRows(
        expandedSongs,
        startIndex: _startIndexAfterRowResolution(
          expansion.songIds,
          expansion.startIndex,
          expandedSongs,
        ),
        autoPlay: autoPlay,
        expandMatchFlows: false,
        inPlayOrder: inPlayOrder,
        originalOrder: originalOrder,
      );
      return;
    }
    if (!_isActiveLoadGeneration(admittedGeneration)) return;
    _applyNewQueueMode(inPlayOrder: inPlayOrder, originalOrder: originalOrder);
    final orderedSongs = songs;
    final orderedStart = startIndex;
    await _runQueueReplacement(
      songIds: orderedSongs.map((song) => song.id).toList(growable: false),
      startIndex: orderedStart,
      autoPlay: autoPlay,
      context: 'replaceQueueWithData',
      clearEmptyRows: orderedSongs.isEmpty,
      resolve: () => (orderedSongs, orderedStart),
      recover: ({required startIndex, required autoPlay}) => _replaceQueueRows(
        orderedSongs,
        startIndex: startIndex,
        autoPlay: autoPlay,
        expandMatchFlows: false,
        inPlayOrder: true,
      ),
    );
  }

  Future<void> _runQueueReplacement({
    required List<String> songIds,
    required int startIndex,
    required bool autoPlay,
    required String context,
    required FutureOr<(List<SongsTableData>, int)> Function() resolve,
    required Future<void> Function({
      required int startIndex,
      required bool autoPlay,
    })
    recover,
    bool clearEmptyRows = false,
  }) {
    final normalizedStartIndex = songIds.isEmpty
        ? 0
        : startIndex.clamp(0, songIds.length - 1);
    if (songIds.isNotEmpty) _navigationIntent.select(normalizedStartIndex);
    final loadingSongId = songIds.isEmpty
        ? null
        : songIds[normalizedStartIndex];
    final generation = _supersedeQueueWork(
      isLoading: songIds.isNotEmpty,
      loadingSongId: loadingSongId,
      pendingLogicalQueueSongIds: songIds.length > 1 ? songIds : null,
    );
    // Empty supplied input clears without row resolution or radio teardown.
    if (clearEmptyRows) {
      return _queueLane.run((token) async {
        await _ready;
        _checkQueueWorkCurrent(token, generation);
        await _clearQueueInternal(persist: true, generation: generation);
        _completeQueueLoad(generation);
      });
    }
    return _queueLane.run((token) async {
      int? nextRecoveryIndex;
      int? failedStartIndex;
      try {
        await _ready;
        _checkQueueWorkCurrent(token, generation);
        _cancelCrossfade();
        _radioMetadataService.stop();
        _radioStation = null;

        final (songs, selectedOccurrence) = await resolve();
        _checkQueueWorkCurrent(token, generation);
        final resolvedStartIndex = songs.isEmpty
            ? 0
            : selectedOccurrence.clamp(0, songs.length - 1);
        if (songs.isEmpty) {
          _clearPendingLogicalQueue();
          await _clearQueueInternal(persist: true, generation: generation);
          _completeQueueLoad(generation);
          return;
        }
        failedStartIndex = resolvedStartIndex;
        final nextOccurrence = _nextPlayableIndexAfterFailure(
          resolvedStartIndex,
          songs.length,
        );
        if (nextOccurrence != null) {
          // Map the next resolved occurrence back to the adapter's input position.
          final available = songs.map((song) => song.id).toSet();
          nextRecoveryIndex = songIds.indexed
              .where((entry) => available.contains(entry.$2.trim()))
              .elementAt(nextOccurrence)
              .$1;
        }
        _navigationIntent.select(resolvedStartIndex);
        _pendingLogicalQueueSongIds = songs.length > 1
            ? songs.map((song) => song.id).toList(growable: false)
            : null;
        _pendingLogicalQueueSongs = songs;

        final startItem = await _replaceQueuePhase1(
          songs: songs,
          startIndex: resolvedStartIndex,
          autoPlay: autoPlay,
          persist: false,
          generation: generation,
          token: token,
        );
        if (startItem != null) {
          await _persistLogicalQueue(
            songs.map((song) => song.id).toList(growable: false),
            resolvedStartIndex,
            generation: generation,
          );
        }
        if (startItem == null || songs.length <= 1) {
          _completeQueueLoad(generation);
          return;
        }
        await _replaceQueuePhase2(
          songs: songs,
          startIndex: resolvedStartIndex,
          startItem: startItem,
          persist: true,
          token: token,
          generation: generation,
          deferTail: _shouldDeferTail(songs.length),
        );
        _completeQueueLoad(generation);
      } on OperationCancelledException {
        AppLogger.debug('$context cancelled — superseded by newer command.');
      } on PlaybackLoadTimeoutException catch (error) {
        if (!_isActiveLoadGeneration(generation)) return;
        // The count may have grown since the start was resolved.
        final capped = _autoFailovers >= _maxAutoFailovers;
        final nextIndex = capped ? null : nextRecoveryIndex;
        if (_player.audioSources.isEmpty &&
            (nextIndex != null || (!_isDesktopRuntime && !capped))) {
          _queueItems.clear();
          _clearQueueReplacementMetadataAnchor();
          _setCurrentMediaItem(null);
          queue.add(const <MediaItem>[]);
        } else if (_player.audioSources.isEmpty && _queueItems.isNotEmpty) {
          // Keep the failed final occurrence reloadable by an explicit Play.
          final ids = _logicalQueueIds;
          final seek = _pendingSeek;
          _restoreQueueLists(
            _pendingQueueRestorePoint(
              ids,
              _pendingLogicalQueueSongs ?? const <SongsTableData>[],
              _queueItems.first,
              seek?.queueIndex ?? failedStartIndex ?? ids.length - 1,
              (
                index: 0,
                position: seek?.position ?? Duration.zero,
                playing: false,
              ),
            ),
          );
          _loadedSourceFailed = true;
        }
        if (nextIndex != null) {
          // Admission of the recovery owns the next loading target; do not
          // publish a settled song backed by the empty retired player first.
          _countAutoFailover();
          unawaited(
            recover(
              startIndex: nextIndex,
              autoPlay: _latestExplicitTransportPlaying ?? autoPlay,
            ),
          );
        } else {
          _completeQueueLoad(
            generation,
            loadingSongId: error.songId ?? loadingSongId,
            failed: true,
          );
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

  /// A new queue takes its shuffle mode from the action that started it:
  /// entity Shuffle supplies its play order with the pre-shuffle ranks
  /// ([originalOrder], never shuffled twice) and turns shuffle on; every other
  /// start (Play, a song tap, search, radio, mixes, links) plays in order with
  /// shuffle off. [inPlayOrder] reloads of the current queue (failure
  /// recovery) keep the mode and order they have. The shuffle toggle still
  /// acts on the current queue afterwards.
  void _applyNewQueueMode({
    required bool inPlayOrder,
    List<String>? originalOrder,
  }) {
    if (inPlayOrder) return;
    _shuffleEnabled = originalOrder != null;
    _originalOrder = originalOrder == null
        ? null
        : List<String>.of(originalOrder);
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
    _applyNewQueueMode(inPlayOrder: false);
    startIndex = expansion.startIndex;
    final songs = await _libraryDao.getSongsByIds(expansion.songIds);
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
    void checkCurrent() {
      if (generation > 0 && !_isActiveLoadGeneration(generation)) {
        throw OperationCancelledException();
      }
    }

    checkCurrent();
    _restoredQueueIndex = null;
    _clearQueueReplacementMetadataAnchor();
    _queueItems.clear();
    // Shuffle belongs to a queue: the next one takes its mode from the action
    // that starts it.
    _shuffleEnabled = false;
    _originalOrder = null;
    await _clearDeferredTail();
    checkCurrent();
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
      await _applyAdjustmentsToPlayer(inactiveDeck, _appliedAdjustments);
      checkCurrent();
      await _setVolumeIfChanged(inactiveDeck, 0);
      checkCurrent();
    }
    await _applyAdjustmentsToPlayer(_player, _appliedAdjustments);
    checkCurrent();
    _updateScrobbleSession(null);
    queue.add(const <MediaItem>[]);
    _setCurrentMediaItem(null);
    if (persist) {
      await _playQueueDao.clearQueue();
      checkCurrent();
    }
    _broadcastPlaybackState();
    _emitSnapshot();
  }
}
