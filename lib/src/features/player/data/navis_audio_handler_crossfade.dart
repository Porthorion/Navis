part of 'navis_audio_handler.dart';

extension _NavisCrossfade on NavisAudioHandler {
  AudioPlayer _newCrossfadePlayer() =>
      _crossfadePlayerFactory?.call() ?? _buildBaseAudioPlayer();

  bool get _isRepeatOneCrossfade =>
      _isCrossfading &&
      _desiredLoopMode == LoopMode.one &&
      _crossfadeTargetIndex == _player.currentIndex;

  /// Returns the effective queue index of the next track, accounting for
  /// shuffle and loop modes. Returns `null` when there is no next track.
  int? _getNextEffectiveIndex() {
    final currentIndex = _player.currentIndex;
    if (currentIndex == null || _queueItems.isEmpty) {
      return null;
    }

    if (_player.loopMode == LoopMode.one) {
      return currentIndex;
    }

    final effectiveIndices = _player.effectiveIndices;
    if (effectiveIndices.isEmpty) {
      return null;
    }

    final positionInOrder = effectiveIndices.indexOf(currentIndex);
    if (positionInOrder < 0) {
      return null;
    }

    if (positionInOrder < effectiveIndices.length - 1) {
      return effectiveIndices[positionInOrder + 1];
    }

    // At the end of the queue – only wrap if looping all.
    if (_player.loopMode == LoopMode.all && effectiveIndices.isNotEmpty) {
      return effectiveIndices.first;
    }
    return null;
  }

  /// Start a cross-fade transition to the track at [nextIndex].
  Future<void> _startCrossfade(
    int nextIndex, {
    required Duration delayBeforeFade,
  }) async {
    final cfPlayer = _crossfadePlayer;
    if (_isCrossfading || cfPlayer == null) {
      return;
    }
    _isCrossfading = true;
    _crossfadeHandoffInProgress = false;
    _crossfadeTargetIndex = nextIndex;
    final from = _resolveCurrentQueueMetadata();
    final fromPosition = _player.position;
    final sessionToken = ++_crossfadeSessionToken;
    _crossfadeActiveTransitionId = sessionToken;
    _crossfadePrewarmLatencyMs = null;
    _crossfadeFadeStartedAt = null;
    final prewarmStopwatch = Stopwatch()..start();
    AppLogger.debug(
      'Cross-fade start: from=${_player.currentIndex} to=$nextIndex '
      'duration=${_crossfadeDurationSeconds}s token=$sessionToken',
    );

    try {
      await _prepareInactiveDeckForCrossfade(
        player: cfPlayer,
        nextIndex: nextIndex,
      ).timeout(_playerLoadTimeout);
      prewarmStopwatch.stop();
      _crossfadePrewarmLatencyMs = prewarmStopwatch.elapsedMilliseconds;
      if (!_isCrossfadeSessionActive(sessionToken, nextIndex)) {
        return;
      }
      if (_isRepeatOneCrossfade && _player.position < fromPosition) {
        // The native loop won the race with preparation. Retry at its next
        // ending instead of overlapping two starts of the song.
        _cancelCrossfade();
        return;
      }
      final fadeDelay = _isRepeatOneCrossfade && delayBeforeFade > Duration.zero
          ? _effectivePlaybackDuration(from.mediaItem) -
                _player.position -
                Duration(seconds: _crossfadeDurationSeconds)
          : delayBeforeFade;
      if (fadeDelay > Duration.zero) {
        AppLogger.debug(
          'Cross-fade prewarm ready: delaying fade start by '
          '${fadeDelay.inMilliseconds}ms '
          '(target=$nextIndex token=$sessionToken).',
        );
        await Future<void>.delayed(fadeDelay);
      }
      if (!_isCrossfadeSessionActive(sessionToken, nextIndex)) {
        return;
      }
      if (_isRepeatOneCrossfade && _player.position < fromPosition) {
        _cancelCrossfade();
        return;
      }
      // An edit during the delay can move the songs or the next one.
      if (!_sequenceMatchesQueue(cfPlayer) ||
          cfPlayer.currentIndex != nextIndex ||
          _getNextEffectiveIndex() != nextIndex) {
        throw StateError('The queue changed before the cross-fade started.');
      }
      if (_isRepeatOneCrossfade) {
        // The outgoing play can end without another native playback event.
        // Check its threshold before the native loop resets its position.
        _handleScrobbleSignals();
      }
      _armCrossfadeFallbackTimeout(
        nextIndex: nextIndex,
        sessionToken: sessionToken,
      );
      _crossfadeFadeStartedAt = DateTime.now();
      unawaited(cfPlayer.play());
      AppLogger.debug(
        'Cross-fade secondary player started: '
        'target=$nextIndex sourceKind=deckMirror token=$sessionToken',
      );
      _startCrossfadeFadeLoop(
        cfPlayer: cfPlayer,
        nextIndex: nextIndex,
        sessionToken: sessionToken,
      );
    } on Object catch (error, stackTrace) {
      if (_isCrossfadeSessionActive(sessionToken, nextIndex)) {
        final fromIndex = from.currentIndex;
        final fromSongId = from.mediaItem?.id;
        if (fromIndex != null && fromSongId != null) {
          _crossfadeFailedFrom = (index: fromIndex, songId: fromSongId);
        }
        AppLogger.warning(
          'Cross-fade start failed. Degrading to gapless transition. '
          '$error\n$stackTrace',
        );
        _emitCrossfadeMetric(
          transitionId: sessionToken,
          targetIndex: nextIndex,
          phase: 'prewarm_failed',
          fallbackReason: 'prewarm_failed',
          canceledReason: error.runtimeType.toString(),
        );
        if (error is TimeoutException &&
            identical(_crossfadePlayer, cfPlayer)) {
          // A timed-out native call can finish late. Retire only this deck;
          // the active player must keep its queue and continue gaplessly.
          _crossfadePlayer = _crossfadeEnabled ? _newCrossfadePlayer() : null;
          unawaited(_disposeAbandonedPlayer(cfPlayer));
        }
        _cancelCrossfade();
      }
    }
  }

  bool _isCrossfadeSessionActive(int sessionToken, int nextIndex) {
    return _isCrossfading &&
        _crossfadeSessionToken == sessionToken &&
        _crossfadeTargetIndex == nextIndex;
  }

  void _armCrossfadeFallbackTimeout({
    required int nextIndex,
    required int sessionToken,
  }) {
    _crossfadeFallbackTimer?.cancel();
    final fadeDuration = Duration(seconds: _crossfadeDurationSeconds);
    final timeout = fadeDuration + const Duration(milliseconds: 2000);
    _crossfadeFallbackTimer = Timer(timeout, () {
      if (!_isCrossfadeSessionActive(sessionToken, nextIndex)) {
        return;
      }
      AppLogger.warning(
        'Cross-fade fallback timed out waiting for finalize completion '
        '(target=$nextIndex token=$sessionToken timeout=${timeout.inMilliseconds}ms). '
        'Degrading to gapless.',
      );
      _emitCrossfadeMetric(
        transitionId: sessionToken,
        targetIndex: nextIndex,
        phase: 'timeout',
        fallbackReason: 'finalize_timeout',
      );
      _cancelCrossfade();
    });
  }

  void _startCrossfadeFadeLoop({
    required AudioPlayer cfPlayer,
    required int nextIndex,
    required int sessionToken,
  }) {
    // Start a periodic fade timer.
    final fadeDurationMs = _crossfadeDurationSeconds * 1000;
    final finalizeAtMs = fadeDurationMs;
    final startTime = DateTime.now();
    _crossfadeFadeTimer?.cancel();
    _crossfadeFadeTimer = Timer.periodic(const Duration(milliseconds: 50), (
      timer,
    ) {
      if (!_isCrossfadeSessionActive(sessionToken, nextIndex) ||
          !identical(_crossfadePlayer, cfPlayer)) {
        timer.cancel();
        return;
      }
      if (_crossfadeHandoffInProgress) {
        timer.cancel();
        return;
      }

      final elapsed = DateTime.now().difference(startTime).inMilliseconds;
      final progress = (elapsed / fadeDurationMs).clamp(0.0, 1.0);

      // If the main player is ducked, respect that by scaling the
      // outgoing volume relative to the duck level.
      final outgoingBase = _isDucked ? _userVolume * 2 / 5 : _userVolume;
      final incomingBase = _isDucked ? _userVolume * 2 / 5 : _userVolume;
      unawaited(
        _player.setVolume((outgoingBase * (1.0 - progress)).clamp(0.0, 1.0)),
      );
      unawaited(cfPlayer.setVolume((incomingBase * progress).clamp(0.0, 1.0)));

      if (elapsed >= finalizeAtMs || progress >= 1.0) {
        timer.cancel();
        AppLogger.debug(
          'Cross-fade fade loop reached finalize point: '
          'elapsed=${elapsed}ms finalizeAt=${finalizeAtMs}ms '
          '(target=$nextIndex token=$sessionToken).',
        );
        unawaited(
          _finalizeCrossfadeAfterFade(
            nextIndex: nextIndex,
            sessionToken: sessionToken,
            cfPlayer: cfPlayer,
          ),
        );
      }
    });
  }

  Future<void> _finalizeCrossfadeAfterFade({
    required int nextIndex,
    required int sessionToken,
    required AudioPlayer cfPlayer,
  }) async {
    if (!_isCrossfadeSessionActive(sessionToken, nextIndex) ||
        !identical(_crossfadePlayer, cfPlayer)) {
      return;
    }
    AppLogger.debug(
      'Cross-fade finalize: deck swap completion '
      '(current=${_player.currentIndex} target=$nextIndex token=$sessionToken).',
    );
    if (!_isCrossfadeSessionActive(sessionToken, nextIndex) ||
        !identical(_crossfadePlayer, cfPlayer)) {
      return;
    }
    await _completeCrossfade();
  }

  Future<void> _completeCrossfade() async {
    final inFlight = _crossfadeCompletionFuture;
    if (inFlight != null) {
      return inFlight;
    }
    final future = _completeCrossfadeInternal();
    _crossfadeCompletionFuture = future;
    try {
      await future;
    } finally {
      if (identical(_crossfadeCompletionFuture, future)) {
        _crossfadeCompletionFuture = null;
      }
    }
  }

  Future<void> _completeCrossfadeInternal() async {
    final cfPlayer = _crossfadePlayer;
    final handoffTargetIndex = _crossfadeTargetIndex;
    final transitionId = _crossfadeActiveTransitionId ?? _crossfadeSessionToken;
    final fadeElapsedMs = _crossfadeFadeStartedAt == null
        ? null
        : DateTime.now().difference(_crossfadeFadeStartedAt!).inMilliseconds;
    _crossfadeHandoffInProgress = true;
    _crossfadeFadeTimer?.cancel();
    _crossfadeFadeTimer = null;
    _crossfadeFallbackTimer?.cancel();
    _crossfadeFallbackTimer = null;
    _crossfadeSessionToken += 1;

    if (cfPlayer == null) {
      AppLogger.debug(
        'Cross-fade completion skipped: secondary player absent.',
      );
      _emitCrossfadeMetric(
        transitionId: transitionId,
        targetIndex: handoffTargetIndex,
        phase: 'missing_incoming_player',
        fallbackReason: 'incoming_absent',
        fadeElapsedMs: fadeElapsedMs,
      );
      AppLogger.debug(
        'Cross-fade complete: degraded to gapless on main player '
        '(index=${_player.currentIndex}).',
      );
      _isCrossfading = false;
      _crossfadeTargetIndex = null;
      _crossfadeActiveTransitionId = null;
      _crossfadePrewarmLatencyMs = null;
      _crossfadeFadeStartedAt = null;
      _applyReplayGainVolume(forceDuringCrossfade: true);
      return;
    }

    if (!_sequenceMatchesQueue(cfPlayer)) {
      // A queue edit the deck missed: keep the active player, which holds the
      // queue, and let it continue gaplessly.
      AppLogger.warning(
        'Cross-fade deck no longer matches the queue '
        '(target=$handoffTargetIndex); keeping the active player.',
      );
      _emitCrossfadeMetric(
        transitionId: transitionId,
        targetIndex: handoffTargetIndex,
        phase: 'deck_mismatch',
        fallbackReason: 'deck_mismatch',
        fadeElapsedMs: fadeElapsedMs,
      );
      _cancelCrossfade();
      _applyReplayGainVolume(forceDuringCrossfade: true);
      return;
    }

    final sw = Stopwatch()..start();
    try {
      final outgoingPlayer = _player;
      final incomingPlayer = cfPlayer;
      final shouldKeepPlaying =
          outgoingPlayer.playing || incomingPlayer.playing;
      final mainTargetVolume = _isDucked
          ? (_userVolume * 2 / 5).clamp(0.0, 1.0)
          : _userVolume;
      await _setVolumeIfChanged(incomingPlayer, mainTargetVolume);
      await _setVolumeIfChanged(outgoingPlayer, 0);

      final repeatingCurrent = _isRepeatOneCrossfade;
      await _disposePlayerListeners();
      _player = incomingPlayer;
      _crossfadePlayer = outgoingPlayer;
      if (repeatingCurrent) {
        // The queue occurrence is unchanged, but the incoming deck is a new
        // play. Prewarming alone must never start a second scrobble session.
        _updateScrobbleSession(null);
      }
      _wirePlayerListeners();
      _rebindRadioMetadataServiceToActivePlayer();
      _handleScrobbleSignals();
      _broadcastPlaybackState();
      _emitSnapshot();
      _scheduleTransportPersistence(context: 'crossfade handoff');

      try {
        await _crossfadePlayer?.pause();
      } on Object {
        // Best-effort reset only.
      }
      await _setVolumeIfChanged(_crossfadePlayer!, 0);
      if (shouldKeepPlaying && !_player.playing) {
        unawaited(_player.play());
      }
      sw.stop();

      AppLogger.debug(
        'Cross-fade complete: deck swap at ${_player.position.inMilliseconds}ms '
        '(swap=${sw.elapsedMilliseconds}ms '
        'currentIndex=${_player.currentIndex} targetIndex=$handoffTargetIndex).',
      );
      _emitCrossfadeMetric(
        transitionId: transitionId,
        targetIndex: handoffTargetIndex,
        phase: 'completed',
        swapLatencyMs: sw.elapsedMilliseconds,
        fadeElapsedMs: fadeElapsedMs,
      );
      _applyReplayGainVolume(forceDuringCrossfade: true);
    } on Object catch (error, stackTrace) {
      AppLogger.warning('Cross-fade completion failed: $error\n$stackTrace');
      _emitCrossfadeMetric(
        transitionId: transitionId,
        targetIndex: handoffTargetIndex,
        phase: 'completion_failed',
        fallbackReason: 'completion_failed',
        canceledReason: error.runtimeType.toString(),
        fadeElapsedMs: fadeElapsedMs,
      );
    } finally {
      _isCrossfading = false;
      _crossfadeHandoffInProgress = false;
      // A release skipped during the fade can run now.
      scheduleMicrotask(_maybeReleaseTail);
      _crossfadeTargetIndex = null;
      _crossfadeActiveTransitionId = null;
      _crossfadePrewarmLatencyMs = null;
      _crossfadeFadeStartedAt = null;
      _applyReplayGainVolume(forceDuringCrossfade: true);
    }
  }

  /// Abort an in-progress cross-fade without completing the hand-off.
  void _cancelCrossfade() {
    final hasActiveCrossfade =
        _isCrossfading ||
        _crossfadeFadeTimer != null ||
        _crossfadeFallbackTimer != null ||
        _crossfadeTargetIndex != null;
    if (!hasActiveCrossfade) {
      return;
    }
    _crossfadeFadeTimer?.cancel();
    _crossfadeFadeTimer = null;
    _crossfadeFallbackTimer?.cancel();
    _crossfadeFallbackTimer = null;
    final transitionId = _crossfadeActiveTransitionId ?? _crossfadeSessionToken;
    _crossfadeSessionToken += 1;
    _isCrossfading = false;
    _crossfadeHandoffInProgress = false;
    scheduleMicrotask(_maybeReleaseTail);
    _emitCrossfadeMetric(
      transitionId: transitionId,
      targetIndex: _crossfadeTargetIndex,
      phase: 'canceled',
      canceledReason: 'explicit_cancel',
      fadeElapsedMs: _crossfadeFadeStartedAt == null
          ? null
          : DateTime.now().difference(_crossfadeFadeStartedAt!).inMilliseconds,
    );
    _crossfadeTargetIndex = null;
    _crossfadeActiveTransitionId = null;
    _crossfadePrewarmLatencyMs = null;
    _crossfadeFadeStartedAt = null;
    AppLogger.debug('Cross-fade canceled.');

    final cfPlayer = _crossfadePlayer;
    if (cfPlayer != null) {
      unawaited(_setVolumeIfChanged(cfPlayer, 0));
      unawaited(cfPlayer.pause());
    }

    // Restore the main player's volume to the user-requested level.
    unawaited(_player.setVolume(_isDucked ? _userVolume * 2 / 5 : _userVolume));
  }

  Future<void> _prepareInactiveDeckForCrossfade({
    required AudioPlayer player,
    required int nextIndex,
  }) async {
    if (nextIndex < 0 || nextIndex >= _queueItems.length) {
      throw StateError('Next index $nextIndex is out of queue range.');
    }
    await _syncInactiveDeckQueueFromActive(player, initialIndex: nextIndex);
    try {
      await player.pause();
    } on Object {
      // Best-effort reset only.
    }
    await _setVolumeIfChanged(player, 0);
    if (player.shuffleModeEnabled) {
      await player.setShuffleModeEnabled(false);
    }
    if (player.loopMode != _player.loopMode) {
      await player.setLoopMode(_player.loopMode);
    }
    await _applyAdjustmentsToPlayer(player, _appliedAdjustments);
    await player.seek(Duration.zero, index: nextIndex);
  }

  /// Loads the materialised queue onto the inactive deck unless it already
  /// holds exactly that queue. Queue edits do not wait for a cross-fade, so an
  /// edit that lands while the deck loads makes the loaded list stale: the
  /// deck is loaded once more, and if the queue moves again this throws (the
  /// fade then degrades to a gapless transition).
  Future<void> _syncInactiveDeckQueueFromActive(
    AudioPlayer player, {
    required int initialIndex,
  }) async {
    if (_sequenceMatchesQueue(player)) return;
    for (var attempt = 0; ; attempt++) {
      final structure = _queueItems.structureRevision;
      await _loadInactiveDeck(player, initialIndex: initialIndex);
      if (_queueItems.structureRevision == structure &&
          _sequenceMatchesQueue(player)) {
        return;
      }
      if (attempt > 0 || _getNextEffectiveIndex() != initialIndex) {
        throw StateError('The queue changed while the cross-fade deck loaded.');
      }
      _crossfadePhaseCounts['deck_resynced'] =
          (_crossfadePhaseCounts['deck_resynced'] ?? 0) + 1;
    }
  }

  Future<void> _loadInactiveDeck(
    AudioPlayer player, {
    int? initialIndex,
  }) async {
    if (_queueItems.isEmpty) {
      await player.setAudioSources(const <AudioSource>[]);
      return;
    }
    final orderedSongs = (await _rowsForDeferredEntries(
      _queueItems.map(_deferredEntryForItem).toList(growable: false),
    )).nonNulls.toList(growable: false);
    if (orderedSongs.length != _queueItems.length) {
      throw StateError(
        'Inactive deck queue sync failed due to missing song metadata.',
      );
    }
    final prepared = await _prepareQueueItems(
      orderedSongs,
      preferLockCaching: true,
    );
    final resolvedInitialIndex = (initialIndex ?? _player.currentIndex ?? 0)
        .clamp(0, math.max(0, prepared.length - 1))
        .toInt();
    final inactiveSources = prepared
        .map((entry) => entry.source.asClonedAudioSource(tag: entry.mediaItem))
        .toList(growable: false);
    try {
      await player.setAudioSources(
        inactiveSources,
        preload: true,
        initialIndex: resolvedInitialIndex,
      );
    } on Object catch (error, stackTrace) {
      _markPreparedLockCachingBypassed(
        prepared,
        reason: 'inactive deck sync failed',
      );
      AppLogger.warning(
        'Inactive deck sync failed with lock-cached sources. '
        'Retrying with direct streams only. $error\n$stackTrace',
      );
      final directPrepared = await _prepareQueueItems(
        orderedSongs,
        preferLockCaching: false,
      );
      final directSources = directPrepared
          .map(
            (entry) => entry.source.asClonedAudioSource(tag: entry.mediaItem),
          )
          .toList(growable: false);
      await player.setAudioSources(
        directSources,
        preload: true,
        initialIndex: resolvedInitialIndex,
      );
    }
    await _setVolumeIfChanged(player, 0);
    await player.pause();
  }

  void _emitCrossfadeMetric({
    required int transitionId,
    required int? targetIndex,
    required String phase,
    int? swapLatencyMs,
    int? fadeElapsedMs,
    String? fallbackReason,
    String? canceledReason,
  }) {
    final metric = CrossfadeTransitionMetric(
      transitionId: transitionId,
      targetIndex: targetIndex,
      phase: phase,
      platform: defaultTargetPlatform.name,
      backend: _isDesktopRuntime ? 'just_audio_media_kit' : 'just_audio_native',
      sourceKind:
          (targetIndex != null &&
              targetIndex >= 0 &&
              targetIndex < _queueItems.length)
          ? (_queueItems[targetIndex].extras?['sourceKind'] as String?)
          : null,
      format:
          (targetIndex != null &&
              targetIndex >= 0 &&
              targetIndex < _queueItems.length)
          ? (_queueItems[targetIndex].extras?['resolvedFormat'] as String?)
          : null,
      sampleRate:
          (targetIndex != null &&
              targetIndex >= 0 &&
              targetIndex < _queueItems.length)
          ? (_queueItems[targetIndex].extras?['sampleRate'] as int?)
          : null,
      prewarmLatencyMs: _crossfadePrewarmLatencyMs,
      fadeDurationMs: _crossfadeDurationSeconds * 1000,
      fadeElapsedMs: fadeElapsedMs,
      swapLatencyMs: swapLatencyMs,
      fallbackReason: fallbackReason,
      canceledReason: canceledReason,
    );
    _crossfadePhaseCounts[phase] = (_crossfadePhaseCounts[phase] ?? 0) + 1;
    AppLogger.debug('Cross-fade metric: ${metric.toDebugString()}');
  }

  Future<void> _clearInactiveDeckForQueueChange({
    int generation = 0,
    String? songId,
  }) async {
    final inactiveDeck = _crossfadePlayer;
    if (inactiveDeck == null) {
      return;
    }
    // Do not mirror the active queue at its current index. Two
    // LockCachingAudioSource instances would then own the same `.part` file.
    // The inactive deck is populated lazily at the next-track index when a
    // crossfade approaches.
    if (generation > 0) {
      await _runTimedPlayerOperation(
        generation: generation,
        operation: 'inactive deck clear',
        action: () => inactiveDeck.setAudioSources(const <AudioSource>[]),
        songId: songId,
      );
    } else {
      await inactiveDeck.setAudioSources(const <AudioSource>[]);
    }
    await inactiveDeck.setLoopMode(_player.loopMode);
    await _applyAdjustmentsToPlayer(inactiveDeck, _appliedAdjustments);
    await _setVolumeIfChanged(inactiveDeck, 0);
    await inactiveDeck.pause();
  }

  Future<void> _disposeInactiveCrossfadeDeck() async {
    final inactiveDeck = _crossfadePlayer;
    if (inactiveDeck == null) {
      return;
    }
    _crossfadePlayer = null;
    try {
      await inactiveDeck.pause();
    } on Object {
      // Best-effort shutdown only.
    }
    await _setVolumeIfChanged(inactiveDeck, 0);
    try {
      await inactiveDeck.dispose();
    } on Object {
      // Best-effort shutdown only.
    }
  }
}
