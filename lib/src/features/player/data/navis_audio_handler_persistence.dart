part of 'navis_audio_handler.dart';

extension _NavisPersistence on NavisAudioHandler {
  Future<void> _restoreQueueAfterStartup() async {
    await _queueLane.run((token) => _restoreSavedQueue(token: token));
  }

  Future<void> _restoreSavedQueue({required OperationToken token}) async {
    final generation = ++_loadGeneration;
    _activeLoadGeneration = generation;
    try {
      _queueRestoreOutcome = 'loading';
      await _restoreQueueFromDisk(
        token: token,
        ownershipGeneration: generation,
      ).timeout(const Duration(seconds: 10));
    } on TimeoutException catch (error, stackTrace) {
      token.cancel();
      _queueRestoreOutcome = 'timeout';
      if (_isActiveLoadGeneration(generation)) {
        _completeQueueLoad(generation);
        _activeLoadGeneration = ++_loadGeneration;
      }
      // A native load cannot be cancelled by a Dart timeout. Retire its
      // player before another command can use it or receive its events.
      await _recoverPlayersFromTimeout(
        generation: generation,
        operation: 'saved queue restore',
      );
      await _clearQueueInternal(persist: false);
      // Keep the saved queue: large queues restore their current item
      // first, so a timeout is transient and must not lose the user's queue.
      AppLogger.warning(
        'Queue restore timed out; keeping the saved queue. '
        '$error\n$stackTrace',
      );
    } on OperationCancelledException {
      if (_queueRestoreOutcome != 'timeout') {
        _queueRestoreOutcome = 'superseded';
      }
    } on Object catch (error, stackTrace) {
      if (token.isCancelled) {
        _queueRestoreOutcome = 'superseded';
        return;
      }
      _queueRestoreOutcome = 'failed';
      AppLogger.error(
        'Queue restore failed. Clearing persisted queue to keep playback functional.',
        error,
        stackTrace,
      );
      await _clearPersistedQueueBestEffort();
    }
  }

  Future<void> _retryDeferredQueueRestoreOnce() async {
    await _ready;
    // A Play that is already restoring the saved queue needs no retry; a
    // later one waits for this retry instead.
    if (!_canRetryDeferredQueueRestore ||
        _prepareQueueForUserPlayInFlight != null) {
      return;
    }
    // Queued behind, never superseding, a command already in the lane; any
    // later queue command cancels it.
    await _queueLane.enqueue((token) async {
      if (token.isCancelled || !_canRetryDeferredQueueRestore) return;
      AppLogger.info('Retrying the deferred startup queue restore.');
      _queueRestoreRetryCount++;
      await _restoreSavedQueue(token: token);
    });
  }

  bool get _canRetryDeferredQueueRestore =>
      _queueRestoreOutcome == 'deferred_auth' &&
      !_disposeHandlerStarted &&
      _radioStation == null &&
      _queueItems.isEmpty &&
      !_isLoading;

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
    // Let a deferred restore that is already running finish instead of
    // restoring the saved queue a second time.
    final deferredRestore = _deferredQueueRestoreRetry;
    if (deferredRestore != null) {
      await deferredRestore;
    }
    if (_radioStation != null || _queueItems.isNotEmpty) {
      AppLogger.debug(
        'Android Auto resume: using active queue '
        '(queue=${_queueItems.length} radio=${_radioStation != null}).',
      );
      return true;
    }

    final persistedSongs = await _playQueueDao.getQueueItems();
    if (persistedSongs.isNotEmpty) {
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
        .watchRecentlyPlayedSongs(limit: 50)
        .first;
    if (recentSongs.isNotEmpty) {
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
    if (likedSongs.isNotEmpty) {
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

    AppLogger.info('Android Auto resume: trying random song fallback.');
    return await _startInstantRadio(autoPlay: false);
  }

  Future<void> _persistSafely(
    Future<void> Function() persistOperation, {
    required String context,
  }) {
    // Queue replacement and delayed position saves may be issued from
    // different lanes. Commit them in issue order so an older asynchronous
    // write cannot land after a newer queue/current-index snapshot.
    final queued = Stopwatch()..start();
    final write = _persistTail.then((_) async {
      final waitedMs = queued.elapsedMilliseconds;
      final running = Stopwatch()..start();
      await navisPersistSafely(
        persistOperation,
        context: context,
        logWarning: AppLogger.warning,
      );
      final ranMs = running.elapsedMilliseconds;
      _persistOperationCount++;
      _persistRunMs += ranMs;
      _persistContextCounts[context] =
          (_persistContextCounts[context] ?? 0) + 1;
      if (ranMs >= 500) {
        _slowPersistence.add(<String, Object?>{
          'context': context,
          'waitedMs': waitedMs,
          'ranMs': ranMs,
        });
        if (_slowPersistence.length > 8) _slowPersistence.removeAt(0);
      }
    });
    _persistTail = write.catchError((Object error, StackTrace stackTrace) {
      AppLogger.warning('Playback persistence lane failed: $error');
    });
    return write;
  }

  Future<void> _persistPosition() {
    return _persistQueueState();
  }

  (schema.RepeatMode, schema.ShuffleMode, int) _playbackSaveFields({
    bool includePosition = true,
  }) => (
    switch (_desiredLoopMode) {
      LoopMode.one => schema.RepeatMode.one,
      LoopMode.all => schema.RepeatMode.all,
      LoopMode.off => schema.RepeatMode.off,
    },
    _shuffleEnabled ? schema.ShuffleMode.all : schema.ShuffleMode.off,
    includePosition
        ? _player.position.inMilliseconds
        : _snapshot.position.inMilliseconds,
  );

  Future<void> _persistLogicalQueue(
    List<String> songIds,
    int index, {
    required int generation,
  }) {
    final immutableIds = List<String>.unmodifiable(songIds);
    final (repeatMode, shuffleMode, positionMs) = _playbackSaveFields();
    return _persistSafely(() async {
      if (!_isActiveLoadGeneration(generation)) return;
      await _playQueueDao.saveQueue(
        currentIndex: index,
        songIds: immutableIds,
        shuffleMode: shuffleMode,
        repeatMode: repeatMode,
        positionMs: positionMs,
        originalOrder: _originalRanksFor(immutableIds),
      );
    }, context: 'logical queue selection');
  }

  /// Each song's unshuffled position while shuffle is on, for saving.
  List<int>? _originalRanksFor(List<String> playOrder) {
    if (!_shuffleEnabled) return null;
    final original = _originalOrder;
    if (original == null) return null;
    final ranks = reconcileOriginalRanks(playOrder, original);
    // Keep the reconciled order, so later edits reconcile against it.
    final byRank = unshuffledIndices(ranks);
    _originalOrder = <String>[for (final i in byRank) playOrder[i]];
    return ranks;
  }

  void _scheduleQueueItemsPersistence({required String context}) {
    _queueItemsPersistTimer?.cancel();
    _queueItemsPersistContext = context;
    // Coalesce bursts, but never postpone a save by more than two seconds.
    final firstPending = _queueItemsPersistFirstScheduledAt ??= DateTime.now();
    final waited = DateTime.now().difference(firstPending);
    const settle = Duration(milliseconds: 300);
    const maxWait = Duration(seconds: 2);
    _queueItemsPersistTimer = Timer(
      waited + settle > maxWait
          ? (maxWait - waited).isNegative
                ? Duration.zero
                : maxWait - waited
          : settle,
      () => unawaited(_flushQueueItemsPersistence()),
    );
  }

  /// Writes a scheduled full-queue persistence now, if one is pending.
  Future<void> _flushQueueItemsPersistence() async {
    final context = _queueItemsPersistContext;
    _queueItemsPersistTimer?.cancel();
    _queueItemsPersistTimer = null;
    _queueItemsPersistContext = null;
    _queueItemsPersistFirstScheduledAt = null;
    if (context == null) return;
    await _persistSafely(
      () => _persistQueueState(includeQueueItems: true),
      context: context,
    );
  }

  void _scheduleTransportPersistence({required String context}) {
    _transportPersistTimer?.cancel();
    _transportPersistTimer = Timer(const Duration(milliseconds: 250), () {
      _transportPersistTimer = null;
      unawaited(_persistSafely(_persistPosition, context: context));
    });
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

    final (repeatMode, shuffleMode, positionMs) = _playbackSaveFields(
      includePosition: includePosition,
    );
    final resolvedCurrentIndex = _radioStation == null
        ? _logicalCurrentIndex
        : null;

    if (includeQueueItems) {
      final songIds = _logicalQueueIds;
      await _playQueueDao.saveQueue(
        currentIndex: resolvedCurrentIndex,
        songIds: songIds,
        shuffleMode: shuffleMode,
        repeatMode: repeatMode,
        positionMs: positionMs,
        originalOrder: _originalRanksFor(songIds),
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
}
