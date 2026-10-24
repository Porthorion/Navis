part of 'navis_audio_handler.dart';

/// Songs skipped automatically in a row, with no healthy playback between,
/// before playback stops quietly on the current song.
const _maxAutoFailovers = 2;

extension _NavisRecovery on NavisAudioHandler {
  /// Fed by the position stream: a source that really advances is alive, and
  /// a few seconds of it end a failover chain. Reads the backend's own
  /// position on desktop (see [_seekSettlementPosition]), because the
  /// interpolated clock keeps moving on a backend stuck in `ready`. Seek
  /// jumps are not advance, and a new song starts its own play time.
  void _observePlaybackAdvance() {
    final position = _seekSettlementPosition;
    final previous = _advancePosition;
    _advancePosition = position;
    final songId = _resolveCurrentQueueMetadata().mediaItem?.id;
    final index = _player.currentIndex;
    // An occurrence is a song at a queue position; a native loop starts a new
    // one (see _onPositionDiscontinuity).
    if (songId != _advanceSongId || index != _advanceIndex) {
      _advanceSongId = songId;
      _advanceIndex = index;
      _playedSinceFailover = Duration.zero;
    }
    final delta = previous == null ? Duration.zero : position - previous;
    if (!_player.playing ||
        _player.processingState != ProcessingState.ready ||
        delta <= Duration.zero ||
        delta > const Duration(seconds: 2)) {
      return;
    }
    _lastAdvanceAt = DateTime.now();
    _playedSinceFailover += delta;
    if (_playedSinceFailover >= _timeouts.healthyPlayback) {
      _autoFailovers = 0;
      // Sustained play also renews this song's one stream retry. A retry
      // resumes at the song position and resets the counter, so each cycle
      // needs healthyPlayback of real advance: a source that fails again
      // within that is skipped. ponytail: a source that keeps failing but
      // plays healthyPlayback each cycle renews forever, which is accepted
      // under Repeat One (endless by definition, each cycle plays real audio).
      _remotePlaybackRecoveryAttempts.remove('$_transportGeneration:$songId');
    }
  }

  bool get _playbackAdvancing =>
      _player.playing &&
      _player.processingState == ProcessingState.ready &&
      _lastAdvanceAt != null &&
      DateTime.now().difference(_lastAdvanceAt!) <
          _seekBufferingRecoveryTimeout;

  /// A user selection is a fresh intent: no failover history and no play time
  /// carried over from the previous song.
  void _resetFailoverAccounting() {
    _autoFailovers = 0;
    _playedSinceFailover = Duration.zero;
  }

  void _countAutoFailover() {
    _autoFailovers++;
    _playedSinceFailover = Duration.zero;
  }

  void _cancelPendingSeek() {
    final request = _pendingSeek;
    if (request != null) {
      request.previewRequest?.cancel();
      request.outcome = 'superseded';
      request.stage = 'done';
      _pendingSeek = null;
      _syncBridgeDownloadPriority();
      _dropPlayerRangeStart();
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
      _latestExplicitTransportPlaying ??
      _prematureTranscodeDeparture?.playing ??
      _player.playing;

  bool get _visiblePlaying =>
      _pendingSeek == null && _prematureTranscodeDeparture == null
      ? navisVisiblePlaying(
          playerPlaying: _player.playing,
          queueFinished: _queueFinished,
        )
      : _requestedPlaying;

  Future<void> _waitForSeekSource(
    _PendingSeek request,
    OperationToken token,
  ) async {
    var sawLoading = _isLoading;
    // Phase one must finish before an older occurrence of the same song can
    // be mistaken for readiness on the source selected by this request.
    await _queueLane.enqueue((_) async => _checkSeekCurrent(request, token));
    final wait = Stopwatch()..start();
    final total = Stopwatch()..start();
    while (true) {
      _checkSeekCurrent(request, token);
      // A load this seek waited on ended in a quiet stop: nothing is loading
      // and nothing will become ready. (A seek made after the stop still
      // waits, because Play may re-arm the source.)
      sawLoading |= _isLoading;
      final stopped =
          sawLoading &&
          _remoteSourceFailed &&
          !_isLoading &&
          !_remotePlaybackRecoveryInProgress;
      if (stopped || total.elapsed >= _timeouts.seekProgress) {
        throw PlaybackLoadTimeoutException(operation: 'seek source readiness');
      }
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
      if (_isLoading && _loadingSongId == request.songId) {
        // Its native operation owns the bounded deadline, including retries.
        wait.reset();
      } else if (wait.elapsed >= deadline) {
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
    var nativeSeekTried = false;
    if (_isDesktopRuntime && seekRequest.recoveryAttempts > 0) {
      // A cold-source retry already opened the target, including transcodes.
      if (await _waitForSeekSettlement(seekRequest, token)) return;
      if (await _trySeekViaCompletedCacheFile(
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
    if (await _shouldSeekViaTranscodeOffset(position, seekRequest, token)) {
      try {
        if (await _seekViaTranscodeOffset(
          position,
          token: token,
          transportGeneration: transportGeneration,
          seekRequest: seekRequest,
        )) {
          return;
        }
      } on OperationCancelledException {
        rethrow;
      } on Object catch (error) {
        _checkSeekCurrent(seekRequest, token);
        AppLogger.debug(
          'Transcode offset seek failed: ${error.runtimeType}; '
          'using the cache path.',
        );
      }
      _checkSeekCurrent(seekRequest, token);
      seekRequest.path = null;
    }
    final plan = _seekPlan(position, seekRequest.songId);
    if (plan == _SeekPlan.bridge ||
        plan == _SeekPlan.bridgeAfterGuard ||
        plan == _SeekPlan.cachedBridge) {
      try {
        if (plan == _SeekPlan.cachedBridge) {
          final rebuilt = await _rebuildQueueForSeekRecovery(
            position,
            autoPlay: _requestedPlaying,
            token: token,
            transportGeneration: transportGeneration,
            seekRequest: seekRequest,
          );
          if (rebuilt && await _waitForSeekSettlement(seekRequest, token)) {
            return;
          }
        } else {
          if (plan == _SeekPlan.bridgeAfterGuard) {
            nativeSeekTried = true;
            try {
              await _runNativeSeek(
                seekRequest,
                token,
                operation: 'fast seek guard',
              );
              if (await _waitForSeekSettlement(
                seekRequest,
                token,
                deadline: _timeouts.fastSeekGuard,
              )) {
                return;
              }
            } on OperationCancelledException {
              rethrow;
            } on Object catch (error) {
              _checkSeekCurrent(seekRequest, token);
              AppLogger.debug(
                'Fast seek guard failed: ${error.runtimeType}; trying bridge.',
              );
            }
          }
          _checkSeekCurrent(seekRequest, token);
          if (seekRequest.unsettled.lastOrNull?['reason'] != 'cache complete' &&
              await _seekViaTranscodeOffset(
                position,
                token: token,
                transportGeneration: transportGeneration,
                seekRequest: seekRequest,
                fastSeekBridge: true,
              )) {
            return;
          }
        }
      } on OperationCancelledException {
        rethrow;
      } on Object catch (error) {
        _checkSeekCurrent(seekRequest, token);
        AppLogger.debug(
          'Fast seek bridge failed: ${error.runtimeType}; using native recovery.',
        );
        nativeSeekTried = false;
      }
      _checkSeekCurrent(seekRequest, token);
      seekRequest.path = null;
    }
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
      // An offset stream is linear, like any server transcode: it cannot
      // seek natively, so go straight to the completed file or a reload.
      if (!nativeSeekTried &&
          _positionOffsetOf(_currentMediaItem) == Duration.zero) {
        await _runNativeSeek(seekRequest, token, operation: 'seek');
        _checkSeekCurrent(seekRequest, token);
        if (await _waitForSeekSettlement(seekRequest, token)) return;
      }
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
    if (_isDesktopRuntime && seekRequest.recoveryAttempts > 0) {
      throw StateError('Seek failed after source recovery.');
    }
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

  bool _shouldFastSeek(Duration target, String songId) {
    final item = _currentMediaItem;
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.linux &&
            defaultTargetPlatform != TargetPlatform.windows) ||
        !_readRuntimeSettings().fastSeekingEnabled ||
        !_sourceResolver.supportsFastSeeking ||
        item == null ||
        item.id != songId ||
        _radioStation != null ||
        isExternalCatalogSource(id: item.id) ||
        (_sidecarSongsById[item.id] ?? _remoteRows[item.id])?.isExternal ==
            true ||
        item.extras?['sourceKind'] != PlaybackSourceKind.directStream.name ||
        item.extras?['transcodingApplied'] != false ||
        !isLosslessPlaybackFormat(item.extras?['resolvedFormat'] as String?) ||
        !_sourceResolver.supportsTranscodeOffset ||
        _completedCacheFileFor(item) != null) {
      return false;
    }
    if (item.extras?['bridgeFormat'] != null) return true;
    final cached = _cachedPlayablePosition(
      item.id,
      _effectivePlaybackDuration(item),
    );
    return target >= const Duration(seconds: 1) &&
        (cached == null || target > cached + const Duration(seconds: 2));
  }

  bool _fastSeekLinkIsSlow(MediaItem item) {
    if (_sidecarDownloader.activeSongId != item.id) return false;
    final rate = _sidecarDownloader.activeBytesPerSecond;
    final song = _sidecarSongsById[item.id] ?? _remoteRows[item.id];
    final kbps =
        item.extras?['resolvedBitRate'] as int? ?? song?.bitRate ?? 1000;
    // ponytail: average-rate heuristic, replace with a windowed estimator if it misclassifies
    return rate != null && rate * 8 / 1000 < 2 * kbps;
  }

  /// How far into the song the media item's stream starts (a `timeOffset`
  /// transcode); zero for every stream that starts at the beginning.
  Duration _positionOffsetOf(MediaItem? item) =>
      Duration(milliseconds: (item?.extras?['positionOffsetMs'] as int?) ?? 0);

  /// just_audio reports a native loop (repeat one, or repeat all over one
  /// song) and an advance as an autoAdvance discontinuity. A loop on the same
  /// index starts a new occurrence for the healthy-play counter, so the play
  /// time of the previous loop counts toward neither the new loop's healthy
  /// play nor its premature-end check. An advance leaves a song behind:
  /// repair it if it was an offset stream. A loop restarts an offset stream at
  /// its own start (the offset into the song) and an advance onto a song
  /// still holding an offset starts it there: reload the song from the start
  /// without an offset.
  void _onPositionDiscontinuity(PositionDiscontinuity discontinuity) {
    final index = discontinuity.event.currentIndex;
    final sequence = _player.sequence;
    if (discontinuity.reason != PositionDiscontinuityReason.autoAdvance ||
        index == null ||
        index < 0 ||
        index >= sequence.length ||
        _disposeHandlerStarted) {
      return;
    }
    if (_retryPrematureTranscodeEnd(discontinuity.previousEvent)) {
      return;
    }
    // A loop or an advance starts a new occurrence: the player's buffered
    // range starts over from its own position.
    _dropPlayerRangeStart();
    if (index == discontinuity.previousEvent.currentIndex) {
      _advancePosition = null;
      _playedSinceFailover = Duration.zero;
    } else {
      _repairDepartedOffsetEntries();
    }
    // seek() serialises behind the background queue fill that still holds
    // _isLoading after an offset reload, so a loop then is not dropped.
    if (_pendingSeek != null) return;
    final source = sequence[index];
    // A deck handover rebuilds the sources but not the queue entries, so the
    // entry's offset can outlive the stream's: reopening clears it too.
    if ((source is UriAudioSource && source.positionOffset > Duration.zero) ||
        _positionOffsetOf(_queueItems.elementAtOrNull(index)) > Duration.zero) {
      unawaited(seek(Duration.zero));
    }
  }

  void _invalidateTranscodeEndOccurrence() {
    _transcodeEndOccurrence = null;
    _transcodeEndInvalidatedAt = DateTime.now();
  }

  void _captureTranscodeEndOccurrence({bool indexEvent = false}) {
    if (!_isDesktopRuntime || _prematureTranscodeDeparture != null) return;
    // ponytail: the index listener can return during tail fill/release before
    // capturing an occurrence; like busy-lane cuts, these keep normal EOF.
    // Revisit both windows if recovery must cover background queue work.
    final event = _player.playbackEvent;
    final index = event.currentIndex;
    final invalidated = _transcodeEndInvalidatedAt;
    if (index == null ||
        event.processingState == ProcessingState.completed ||
        (invalidated != null && !event.updateTime.isAfter(invalidated)) ||
        !_sequenceMatchesQueue(_player)) {
      return;
    }
    final source = _player.sequence.elementAtOrNull(index);
    final item = _queueItems.elementAtOrNull(index);
    if (source == null ||
        item == null ||
        (!indexEvent &&
            _transcodeEndOccurrence != null &&
            !identical(source, _transcodeEndOccurrence?.source))) {
      return;
    }
    _transcodeEndOccurrence = (
      index: index,
      source: source,
      item: item,
      position: event.updatePosition,
      updateTime: event.updateTime,
    );
  }

  int _departedQueueIndex(MediaItem item) {
    final departure = _prematureTranscodeDeparture;
    return departure != null && identical(departure.item, item)
        ? _player.sequence.indexOf(departure.source)
        : -1;
  }

  /// A transcode can report a clean EOF after a connection cut. Judge its
  /// departed occurrence against server metadata, never the truncated duration.
  bool _retryPrematureTranscodeEnd(PlaybackEvent previousEvent) {
    final occurrence = _transcodeEndOccurrence;
    final index = previousEvent.currentIndex;
    // ponytail: cuts during background tail release/trim/fill keep normal EOF
    // behavior; revisit if recovery must wait for a busy queue lane.
    if (!_isDesktopRuntime ||
        _disposeHandlerStarted ||
        _isLoading ||
        !_queueLane.isIdle ||
        _pendingSeek != null ||
        _remotePlaybackRecoveryInProgress ||
        _isCrossfading ||
        _crossfadeHandoffInProgress ||
        _radioStation != null ||
        _latestExplicitTransportPlaying == false ||
        _pendingLogicalQueueSongIds != null ||
        !_sourceResolver.supportsTranscodeOffset ||
        index == null ||
        index < 0 ||
        index >= _queueItems.length) {
      return false;
    }
    final invalidated = _transcodeEndInvalidatedAt;
    if (occurrence == null ||
        occurrence.index != index ||
        (invalidated != null &&
            !previousEvent.updateTime.isAfter(invalidated)) ||
        !identical(
          occurrence.source,
          _player.sequence.elementAtOrNull(index),
        )) {
      return false;
    }
    final item = occurrence.item;
    final position = previousEvent.updateTime.isBefore(occurrence.updateTime)
        ? occurrence.position
        : previousEvent.updatePosition;
    final kind = item.extras?['sourceKind'];
    final duration = item.duration;
    // ponytail: metadata-only EOF detection; add native cut evidence if server
    // durations overstate real transcode ends by more than the 10-second margin.
    if ((kind != PlaybackSourceKind.directStream.name &&
            kind != PlaybackSourceKind.lockCachedStream.name) ||
        (item.extras?['transcodingApplied'] != true &&
            _positionOffsetOf(item) == Duration.zero) ||
        isExternalCatalogSource(id: item.id) ||
        _completedCacheFileFor(item) != null ||
        duration == null ||
        position < Duration.zero ||
        position + const Duration(seconds: 10) >= duration ||
        _remotePlaybackRecoveryAttempts.contains(
          '$_transportGeneration:${item.id}',
        )) {
      return false;
    }
    _prematureTranscodeDeparture = (
      item: item,
      source: occurrence.source,
      playing: _requestedPlaying,
      sourceReady: false,
    );
    _continuingIntoDeferredTail = true;
    unawaited(
      _retryRemotePlayback(
        currentIndex: index,
        songId: item.id,
        position: position,
        autoPlay: _requestedPlaying,
        transportGeneration: _transportGeneration,
        reason: 'premature transcode EOF',
        departedItem: item,
      ).whenComplete(() {
        if (identical(_prematureTranscodeDeparture?.item, item)) {
          _prematureTranscodeDeparture = null;
          _captureTranscodeEndOccurrence(indexEvent: true);
        }
        _continuingIntoDeferredTail = false;
        _handleScrobbleSignals();
        _broadcastPlaybackState();
        _emitSnapshot();
      }),
    );
    return true;
  }

  /// Whether a seek to [target] reopens the server transcode at that offset
  /// instead of seeking the stream: the song is a remote transcode that
  /// cannot seek natively (Android lock-cache origin without ranges, desktop
  /// direct stream, or a stream already opened at an offset) and no completed
  /// local copy exists.
  Future<bool> _shouldSeekViaTranscodeOffset(
    Duration target,
    _PendingSeek request,
    OperationToken token,
  ) async {
    final plan = _seekPlan(target, request.songId);
    if (plan == _SeekPlan.offsetPendingRanges) {
      final ranges = await _lockCacheServesRanges(request, token);
      return _seekPlan(target, request.songId, originSupportsRanges: ranges) ==
          _SeekPlan.offset;
    }
    return plan == _SeekPlan.offset;
  }

  /// Reloads the current song with its transcode opened at [position]
  /// (whole seconds, so the audio can start up to a second early), keeping
  /// the queue and the play state. A position under a second reloads the
  /// normal stream from the start. The download of the full song carries on.
  /// Returns whether the seek landed.
  Future<bool> _seekViaTranscodeOffset(
    Duration position, {
    required OperationToken token,
    required int transportGeneration,
    required _PendingSeek seekRequest,
    bool fastSeekBridge = false,
    MediaItem? departedItem,
  }) async {
    var offset = _seekOffset(position, departedItem ?? _currentMediaItem);
    _PreparedQueueItem? preparedStart;
    var landed = false;
    seekRequest
      ..path = fastSeekBridge ? 'fastSeekBridge' : 'transcodeOffset'
      ..stage = 'recovering';
    try {
      if (departedItem == null &&
          _previewMatchesRelease(position, bridge: fastSeekBridge)) {
        final preview = _seekPreview!;
        final rows = await _libraryDao.getSongsByIds([seekRequest.songId]);
        _checkSeekCurrent(seekRequest, token);
        final song =
            rows.firstOrNull ??
            _remoteRows[seekRequest.songId] ??
            _sidecarSongsById[seekRequest.songId];
        if (song != null) {
          final prepared = await _prepareSingleItem(
            song,
            preferLockCaching: false,
            transcodeOffset: preview.key.offset,
            fastSeekBridge: fastSeekBridge,
            seekPreviewRequest: seekRequest,
          );
          _checkSeekCurrent(seekRequest, token);
          if (seekRequest.previewRequest != null) {
            preparedStart = prepared;
            offset = prepared.source.positionOffset;
          }
        }
      } else {
        cancelSeekPreview();
      }
      final rebuilt = await _rebuildQueueForSeekRecovery(
        offset ?? Duration.zero,
        autoPlay: _requestedPlaying,
        token: token,
        transportGeneration: transportGeneration,
        seekRequest: seekRequest,
        preparedStart: preparedStart,
        transcodeOffset: offset,
        fastSeekBridge: fastSeekBridge,
        departedItem: departedItem,
      );
      _checkSeekCurrent(seekRequest, token);
      return landed =
          rebuilt && await _waitForSeekSettlement(seekRequest, token);
    } finally {
      if (!landed) {
        seekRequest.previewRequest?.cancel();
        seekRequest.previewRequest = null;
        seekRequest.previewOffset = null;
      }
    }
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
      extendWhileDownloading: !_isDesktopRuntime,
      isCurrent: () => _isCurrentSeek(request),
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
    OperationToken token, {
    Duration? deadline,
  }) async {
    request.stage = 'confirming';
    deadline ??= _isDesktopRuntime
        ? _timeouts.desktopSeekSettle
        : _timeouts.seekProgress;
    final elapsed = Stopwatch()..start();
    var lastActivity = Duration.zero;
    var lastPosition = _seekSettlementPosition;
    var lastBuffer = _player.bufferedPosition;
    final progress = _PlaybackProgressDeadline(
      initial: _isDesktopRuntime ? deadline : _playerLoadTimeout,
      idle: _timeouts.progressIdle,
      hardCap: deadline,
      bytes: _isDesktopRuntime
          ? null
          : _receivedCacheBytesForSong(request.songId),
      buffer: _isDesktopRuntime ? Duration.zero : lastBuffer,
    );
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
      final waitingForInput =
          processing == ProcessingState.loading ||
          processing == ProcessingState.buffering;
      final near =
          (position - (request.previewOffset ?? request.position)).abs() <
          const Duration(seconds: 2);
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
      progress.observe(
        now,
        bytes: _isDesktopRuntime
            ? null
            : _receivedCacheBytesForSong(request.songId),
        buffer: _isDesktopRuntime ? Duration.zero : buffer,
        processing: processing,
      );
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
      if (!progress.progressing(now) &&
          farSince != null &&
          now - farSince >= _seekBufferingRecoveryTimeout) {
        unsettled = 'missed target';
      } else if (!progress.progressing(now) &&
          !(near && !_requestedPlaying) &&
          now - lastActivity >= _seekBufferingRecoveryTimeout) {
        // A paused player holding the target is expected to stand still.
        unsettled = 'no progress';
      } else if (_currentMediaItem?.extras?['bridgeFormat'] == null &&
          _completedSidecarAvailable(request.songId)) {
        // The local copy seeks without the network: reload from it rather
        // than wait for the remote range.
        unsettled = 'cache complete';
      } else if (waitingForInput ? progress.expired(now) : now >= deadline) {
        // After extended buffering, ready gets the short stall window above
        // to prove motion instead of immediately failing the old load budget.
        unsettled = 'deadline';
      }
      if (unsettled != null) {
        request.unsettled.add(
          _unsettledProbe(unsettled, now, position, processing),
        );
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  Map<String, Object?> _unsettledProbe(
    String reason,
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
    // An Android offset stream is a direct stream; its lock-cache download
    // keeps filling the same file.
    if (extras['sourceKind'] != PlaybackSourceKind.lockCachedStream.name &&
        _positionOffsetOf(item) == Duration.zero) {
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
        ...Map<String, Object?>.of(extras)
          ..remove('bridgeFormat')
          ..remove('bridgeBitRate'),
        'sourceKind': PlaybackSourceKind.file.name,
        'localSource': true,
        'cachedFilePath': cacheFile.path,
        'positionOffsetMs': 0,
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
    Duration? transcodeOffset,
    bool fastSeekBridge = false,
    MediaItem? departedItem,
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
      final expectedIndex = departedItem == null
          ? metadata.currentIndex
          : _departedQueueIndex(departedItem);
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
          index: departedItem == null
              ? _player.currentIndex
              : _departedQueueIndex(departedItem),
          position: departedItem == null ? _player.position : position,
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
          final materialisedIndex = departedItem == null
              ? _resolveCurrentQueueMetadata().currentIndex
              : _departedQueueIndex(departedItem);
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
            transcodeOffset: transcodeOffset,
            fastSeekBridge: fastSeekBridge,
            // A departed song must be restored before a newer seek can use it.
            // Otherwise a newer seek reloads at its own offset in one load.
            isStillWanted:
                transcodeOffset == null ||
                    seekRequest == null ||
                    departedItem != null
                ? null
                : () => _isCurrentSeek(seekRequest),
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
          final failedItem = _queueItems.singleOrNull;
          if (!fastSeekBridge &&
              failedItem != null &&
              failedItem.id == currentSongId &&
              _sequenceMatchesQueue(_player)) {
            // Native already holds only this song; defer its neighbours so
            // native index zero cannot select the old queue head.
            _restoreQueueLists(
              _pendingQueueRestorePoint(
                queueSongIds,
                orderedSongs,
                failedItem,
                currentIndex,
                capture,
              ),
            );
          } else {
            _restoreQueueLists(restore);
          }
          if (fastSeekBridge) {
            // Native may already hold the failed bridge's single-item playlist.
            await _reloadQueueAfterTimeout(restore.capture);
          } else {
            _afterQueueEdit(context: 'seek recovery failed');
          }
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
    final departure = _prematureTranscodeDeparture;
    if (departure != null && seekRequest?.isRemoteRecovery == true) {
      _prematureTranscodeDeparture = (
        item: departure.item,
        source: departure.source,
        playing: departure.playing,
        sourceReady: true,
      );
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
    if (_disposeHandlerStarted ||
        _prematureTranscodeDeparture?.sourceReady == false) {
      return;
    }
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
  /// stream that recovery can reload, or when a load or user seek owns it.
  bool _rearmRemoteRecovery({
    required Duration? position,
    required bool autoPlay,
  }) {
    final sourceKind = _currentSourceKind;
    final songId = _resolveCurrentQueueMetadata().mediaItem?.id;
    if (songId == null ||
        _isLoading ||
        _pendingLogicalQueueSongIds != null ||
        _pendingSeek?.isRemoteRecovery == false ||
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
      requested: true,
    );
    unawaited(
      _recoverCurrentSongFromRemotePlaybackFailure(reason: 'user command'),
    );
    return true;
  }

  /// Restarts recovery for the Play or seek held on the current failed song,
  /// or applies it once a load has reloaded the song. While a load still
  /// owns the song the request is kept, and _completeQueueLoad calls this
  /// again once the load ends.
  void _rearmHeldRemoteRecovery() {
    final request = _pendingRemoteRecovery;
    final songId = _resolveCurrentQueueMetadata().mediaItem?.id;
    if (request == null ||
        songId == null ||
        !_ownsRemoteRecovery(songId) ||
        _remotePlaybackRecoveryInProgress ||
        _isLoading ||
        _pendingLogicalQueueSongIds != null) {
      return;
    }
    if (!_remoteSourceFailed ||
        !_rearmRemoteRecovery(
          position: request.position,
          autoPlay: request.autoPlay,
        )) {
      _applyPendingRemoteRecovery();
    }
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

  /// The native player reported a failure; a source that was never prepared
  /// is idle without one.
  bool get _remoteSourceFailed =>
      _player.processingState == ProcessingState.idle && _loadedSourceFailed;

  /// Applies the pending Play or seek to its song, which plays again without
  /// a reload.
  void _applyPendingRemoteRecovery() {
    final request = _pendingRemoteRecovery!;
    _pendingRemoteRecovery = null;
    if (request.position case final target?) unawaited(seek(target));
    if (request.autoPlay && !_player.playing) {
      unawaited(_playWithFocusRecovery());
    }
    _broadcastPlaybackState();
    _emitSnapshot();
  }

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
      _anomalies.event('stall');
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
        requested: false,
      );
    }
    _broadcastPlaybackState();
    _emitSnapshot();
    final ({
      int generation,
      String songId,
      Duration? position,
      bool autoPlay,
      bool requested,
    })
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
        if (latest != null &&
            latest.requested &&
            _ownsRemoteRecovery(songId) &&
            !_isLoading &&
            _pendingSeek == null) {
          // A seek during a stall still applies once the song plays again.
          _applyPendingRemoteRecovery();
        } else if (latest?.songId == songId) {
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
    await _retryRemotePlayback(
      currentIndex: currentIndex,
      songId: songId,
      position: pending.position ?? _player.position,
      autoPlay: pending.autoPlay,
      transportGeneration: pending.generation,
      reason: reason,
    );
  }

  Future<void> _retryRemotePlayback({
    required int currentIndex,
    required String songId,
    required Duration position,
    required bool autoPlay,
    required int transportGeneration,
    required String reason,
    MediaItem? departedItem,
  }) async {
    _remotePlaybackRecoveryInProgress = true;
    int? departedFailureSeekRevision;
    final attemptKey = '$transportGeneration:$songId';
    final duration = _effectivePlaybackDuration(
      departedItem ?? _currentMediaItem,
    );
    final atEnd = duration > Duration.zero && position >= duration;
    final isRetry =
        !atEnd &&
        navisShouldRetryRemotePlayback(
          alreadyRetried: _remotePlaybackRecoveryAttempts.contains(attemptKey),
        );
    if (isRetry) {
      _remotePlaybackRecoveryAttempts.add(attemptKey);
      _playedSinceFailover = Duration.zero;
    }
    _anomalies.event('recovery', {
      'targetMs': position.inMilliseconds,
      'retry': isRetry,
    });
    AppLogger.startup(
      StartupEvent.streamRecovery,
      attempt: isRetry ? 1 : 2,
      outcome: StartupOutcome.changed,
    );

    // Install the seek request before awaiting Pause's native acknowledgement.
    final pausing = departedItem == null
        ? null
        : _runTimedPlayerOperation(
            generation: _activeLoadGeneration,
            operation: 'pause premature transcode EOF',
            action: _player.pause,
            songId: songId,
            timeout: _timeouts.control,
          ).catchError((Object error) {
            AppLogger.debug('Pause before transcode recovery failed: $error');
          });
    try {
      if (isRetry) {
        try {
          var rebuilt = false;
          await _seekLane.run((recoveryToken) async {
            if (!_isCurrentTransportIntent(transportGeneration)) return;
            final request = _PendingSeek(
              generation: ++_seekRevision,
              songId: songId,
              queueIndex: departedItem == null
                  ? _logicalCurrentIndex
                  : _logicalIndexOf(currentIndex),
              position: position,
              isRemoteRecovery: true,
            );
            _pendingSeek = request;
            try {
              if (pausing != null) {
                await pausing;
              }
              _checkSeekCurrent(request, recoveryToken);
              final bridging =
                  (departedItem ?? _currentMediaItem)
                      ?.extras?['bridgeFormat'] !=
                  null;
              rebuilt =
                  departedItem == null &&
                  _completedCacheFileFor(_currentMediaItem) != null &&
                  await _trySeekViaCompletedCacheFile(
                    position,
                    autoPlay: autoPlay,
                    token: recoveryToken,
                    transportGeneration: transportGeneration,
                    seekRequest: request,
                  );
              _checkSeekCurrent(request, recoveryToken);
              if (rebuilt) return;
              if (departedItem != null ||
                  bridging ||
                  await _shouldSeekViaTranscodeOffset(
                    position,
                    request,
                    recoveryToken,
                  )) {
                try {
                  rebuilt = await _seekViaTranscodeOffset(
                    position,
                    token: recoveryToken,
                    transportGeneration: transportGeneration,
                    seekRequest: request,
                    fastSeekBridge: bridging,
                    departedItem: departedItem,
                  );
                  if (!rebuilt) {
                    throw StateError('Remote recovery did not settle.');
                  }
                } on OperationCancelledException {
                  rethrow;
                } on Object catch (error) {
                  if (!bridging) rethrow;
                  _checkSeekCurrent(request, recoveryToken);
                  AppLogger.debug(
                    'Bridge recovery rejected: ${error.runtimeType}; '
                    'recovering original.',
                  );
                  // The original may finish while the bridge reopen is pending.
                  rebuilt =
                      _completedCacheFileFor(_currentMediaItem) != null &&
                      await _trySeekViaCompletedCacheFile(
                        position,
                        autoPlay: autoPlay,
                        token: recoveryToken,
                        transportGeneration: transportGeneration,
                        seekRequest: request,
                      );
                  _checkSeekCurrent(request, recoveryToken);
                  if (!rebuilt) {
                    rebuilt = await _rebuildQueueForSeekRecovery(
                      position,
                      autoPlay: autoPlay,
                      token: recoveryToken,
                      transportGeneration: transportGeneration,
                      seekRequest: request,
                    );
                  }
                  if (!rebuilt) rethrow;
                }
              } else {
                rebuilt = await _rebuildQueueForSeekRecovery(
                  position,
                  autoPlay: autoPlay,
                  token: recoveryToken,
                  transportGeneration: transportGeneration,
                );
              }
            } finally {
              // Play/Pause preserve this seek even when transport changes.
              if (departedItem != null && identical(_pendingSeek, request)) {
                departedFailureSeekRevision = request.generation;
              }
              if (identical(_pendingSeek, request)) {
                _pendingSeek = null;
                _anomalies.event('seekDone', {'outcome': 'recovery'});
              }
              _syncBridgeDownloadPriority();
            }
          });
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
        } on OperationCancelledException {
          return;
        } on Object {
          AppLogger.startup(
            StartupEvent.streamRecovery,
            outcome: StartupOutcome.failure,
          );
        }
      }

      if (!_isCurrentTransportIntent(transportGeneration) &&
          !(departedFailureSeekRevision == _seekRevision &&
              identical(_prematureTranscodeDeparture?.item, departedItem))) {
        return;
      }
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
      // A Play during the reload re-armed this song; the reload yielded to it.
      final request = _pendingRemoteRecovery;
      if (request != null && _ownsRemoteRecovery(songId)) {
        if (_remoteSourceFailed) {
          _rearmHeldRemoteRecovery();
        } else {
          _applyPendingRemoteRecovery();
        }
      }
      _broadcastPlaybackState();
      _emitSnapshot();
    }
  }

  /// Plays the song after logical index [failedIndex], or stops quietly when
  /// none follows, the failover cap is reached, or the song is no longer
  /// queued. Play reloads the stopped song.
  Future<void> _skipPastFailedRemoteSong(
    int failedIndex, {
    required bool autoPlay,
  }) async {
    // The next song may still be deferred; playFromIndex releases it.
    final nextIndex = failedIndex < 0
        ? null
        : _nextPlayableIndexAfterFailure(failedIndex, _logicalQueueIds.length);
    if (nextIndex != null) {
      _countAutoFailover();
      await _applyNavigationDecision(
        _navigationIntent.select(nextIndex),
        logicalIds: _logicalQueueIds,
        shouldPlay: autoPlay,
        context: 'skip failed remote song',
      );
      return;
    }

    // Best effort, like _disposeAbandonedPlayer: a stuck native stop must not
    // park the seek lane that called this.
    final player = _player;
    var wedged = false;
    for (final halt in <Future<void> Function()>[player.pause, player.stop]) {
      try {
        await halt().timeout(_playerResetTimeout);
      } on Object {
        wedged = true;
      }
    }
    // A native call that never returned may leave the platform stuck, which
    // Play would then wait on: replace the player, keeping the queue.
    if (wedged) {
      await _recoverPlayersFromTimeout(
        generation: _activeLoadGeneration,
        operation: 'final quiet stop',
      );
    }
    _loadedSourceFailed = true;
    _broadcastPlaybackState();
    _emitSnapshot();
  }

  String? get _currentSourceKind {
    final index = _resolveCurrentQueueMetadata().currentIndex;
    if (index == null || index < 0 || index >= _queueItems.length) {
      return null;
    }
    return _queueItems[index].extras?['sourceKind'] as String?;
  }
}
