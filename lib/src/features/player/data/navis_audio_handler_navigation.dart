part of 'navis_audio_handler.dart';

extension _NavisNavigation on NavisAudioHandler {
  int _supersedeTransportIntent({bool? shouldPlay, bool preserveSeek = false}) {
    if (!preserveSeek || shouldPlay != null) cancelSeekPreview();
    if (!preserveSeek || (shouldPlay != null && _pendingSeek == null)) {
      _seekFailureBlocksRecovery = false;
    }
    if (!preserveSeek) {
      _invalidateTranscodeEndOccurrence();
      _prematureTranscodeDeparture = null;
      // Navigation, stop, queue loads and radio all move the position.
      _anomalies.expect('transport');
      _seekLane.cancelCurrent();
      _cancelPendingSeek();
    }
    _resumeLockCacheDownloads();
    _focusRetryTimer?.cancel();
    _focusDeniedGeneration = null;
    _focusRetries = 0;
    _focusDeniedSince = null;
    _networkRetryTimer?.cancel();
    _networkRetries = 0;
    _pendingRemoteRecovery = null;
    _remoteRecoveryWasOffline = false;
    _pendingRadioRecovery = null;
    _radioRecovered = null;
    _remotePlaybackRecoveryAttempts.clear();
    if (shouldPlay != null) _latestExplicitTransportPlaying = shouldPlay;
    return ++_transportGeneration;
  }

  bool _isCurrentTransportIntent(int generation) =>
      generation == _transportGeneration;

  Future<void> _navigateRelative({required bool forward}) {
    cancelSeekPreview();
    _resetFailoverAccounting();
    final logicalIds = _logicalQueueIds;
    final confirmedIndex = _logicalIndexOf(
      _resolveCurrentQueueMetadata().currentIndex ?? _player.currentIndex,
    );
    final effectiveOrder =
        _pendingLogicalQueueSongIds == null &&
            _player.effectiveIndices.length == logicalIds.length
        ? _player.effectiveIndices
        : List<int>.generate(logicalIds.length, (index) => index);
    final decision = _navigationIntent.relative(
      forward: forward,
      confirmedIndex: confirmedIndex,
      confirmedPosition: _restoredQueueIndex != null
          ? _restoredQueuePosition
          : _player.position,
      effectiveOrder: effectiveOrder,
      // The user's mode: the native loop is off while songs are deferred.
      loopAll: _desiredLoopMode == LoopMode.all,
    );
    final cue = switch (decision.outcome) {
      PlaybackNavigationOutcome.next => TransportVisualIntent.next,
      PlaybackNavigationOutcome.previous => TransportVisualIntent.previous,
      PlaybackNavigationOutcome.restart => TransportVisualIntent.restartCurrent,
      PlaybackNavigationOutcome.unavailableNext =>
        TransportVisualIntent.unavailableNext,
      PlaybackNavigationOutcome.unavailablePrevious =>
        TransportVisualIntent.unavailablePrevious,
    };
    _emitTransportVisualCue(cue, fromSongId: _snapshot.currentSongId);
    if (!decision.canApply) {
      final index = decision.index;
      if (decision.outcome == PlaybackNavigationOutcome.unavailableNext &&
          index != null &&
          index == logicalIds.length - 1) {
        // Pass the desired occurrence, which may still be loading in a burst.
        _onPersonalRadioQueueEnd?.call((
          index: index,
          songId: logicalIds[index],
        ));
      }
      return Future<void>.value();
    }
    // A newer Next, Previous or restart replaces any Next held at the tail.
    _onPersonalRadioQueueEnd?.call(null);
    _invalidatePendingStartupSelection();
    if (forward && decision.index == 0 && _shouldStartNextShufflePass) {
      return _startNextShufflePass(
        shouldPlay: _latestExplicitTransportPlaying ?? _player.playing,
      );
    }
    return _applyNavigationDecision(
      decision,
      logicalIds: logicalIds,
      shouldPlay: _latestExplicitTransportPlaying ?? _player.playing,
      context: forward ? 'skip next' : 'skip previous',
    );
  }

  Future<void> _applyNavigationDecision(
    PlaybackNavigationDecision decision, {
    required List<String> logicalIds,
    required bool shouldPlay,
    required String context,
  }) {
    // Landing on the song that plays as an offset stream would restart it at
    // its offset, the middle of the song: reload it from the start instead.
    if (decision.index == _logicalCurrentIndex &&
        _positionOffsetOf(_currentMediaItem) > Duration.zero) {
      _navigationIntent.confirm(decision.revision);
      _supersedeTransportIntent(shouldPlay: shouldPlay);
      return seek(Duration.zero);
    }
    final restorePosition =
        decision.outcome != PlaybackNavigationOutcome.restart &&
            _restoredQueueIndex == decision.index
        ? _restoredQueuePosition
        : Duration.zero;
    final requestedIndex = decision.index!;
    final targetId = logicalIds[requestedIndex];
    _transportTrace.record(
      'navigate',
      () => <String, Object?>{
        'context': context,
        'outcome': decision.outcome.name,
        'requestedIndex': requestedIndex,
        'fromIndex': _player.currentIndex,
        'targetSongId': targetId,
        'positionMs': _player.position.inMilliseconds,
      },
    );
    if (_navigationInFlightRevision != null) {
      _navigationSupersededCount++;
    }
    _navigationInFlightRevision = decision.revision;
    _navigationIssuedAt = DateTime.now();
    _queueFinished = false;
    final transportGeneration = _supersedeTransportIntent(
      shouldPlay: shouldPlay,
    );
    final generation = _supersedeQueueWork(
      isLoading: true,
      loadingSongId: targetId,
      pendingLogicalQueueSongIds: _pendingLogicalQueueSongIds,
      navigation: true,
    );
    final pendingSongs = _pendingLogicalQueueSongs;
    final work = _queueLane.navigate((token) async {
      var index = requestedIndex;
      var selectionConfirmed = false;
      var rebuiltPendingQueue = false;
      int? preparedTargetIndex;
      // Set for a far jump, so a target that cannot load leaves the old
      // queue playing.
      _QueueRestorePoint? farJumpRestore;
      void confirmSelection() {
        if (selectionConfirmed ||
            !_isActiveLoadGeneration(generation) ||
            !_navigationIntent.isCurrent(decision.revision)) {
          return;
        }
        selectionConfirmed = true;
        _navigationIntent.confirm(decision.revision);
        _navigationCompletedCount++;
        _scheduleTransportPersistence(context: context);
        _emitSnapshot();
      }

      Future<void> failNavigation(Object error, StackTrace stackTrace) async {
        final restore = farJumpRestore;
        if (restore != null) await _restoreQueueAfterFailedJump(restore);
        _navigationIntent.confirm(decision.revision);
        _completeQueueLoad(generation, loadingSongId: targetId, failed: true);
        _emitLoadFailure(
          operation: context,
          message: 'Could not change to the selected track.',
          songId: targetId,
        );
        AppLogger.warning('Manual navigation failed: $error\n$stackTrace');
      }

      try {
        await _ready;
        _checkQueueWorkCurrent(token, generation);
        _cancelCrossfade();

        List<SongsTableData>? rebuildSongs;
        if (_pendingLogicalQueueSongIds != null) {
          rebuildSongs =
              pendingSongs ?? await _libraryDao.getSongsByIds(logicalIds);
          _checkQueueWorkCurrent(token, generation);
          if (rebuildSongs.length != logicalIds.length) {
            throw StateError('A queued song is no longer available.');
          }
        } else {
          // Queue edits that ran after this decision may have moved the song.
          index = _locateQueueTarget(targetId, requestedIndex);
          if (index < 0) {
            throw StateError('The selected song is no longer queued.');
          }
          if (index < _deferredHead.length &&
              _deferredHead.length - index <= _queueWindow.nearJump) {
            // A played song released from the player: bring it back with
            // the songs after it and a page before it (so further Previous
            // presses stay in the player), then seek.
            await _releaseHead(
              count: _deferredHead.length - index + _queueWindow.page,
            );
            _checkQueueWorkCurrent(token, generation);
            index = _locateQueueTarget(targetId, index);
            if (index < 0 || index < _deferredHead.length) {
              throw StateError('The selected song is no longer available.');
            }
          }
          final logicalTarget = index;
          final materialised = index - _deferredHead.length;
          final offset = materialised - _queueItems.length;
          // A player that no longer holds the queue (rebuilt empty after a
          // timeout) is rebuilt around the target, as for a far jump.
          final playerHoldsQueue = _sequenceMatchesQueue(_player);
          if (playerHoldsQueue &&
              materialised >= 0 &&
              materialised < _queueItems.length) {
            index = materialised;
          } else if (playerHoldsQueue &&
              offset >= 0 &&
              offset < _queueWindow.nearJump) {
            // Near the materialised end: release through the target and
            // seek, as for any queued song.
            final before = _queueItems.length;
            final released = await _releaseTail(
              count: offset + 1 + _queueWindow.ahead,
            );
            _checkQueueWorkCurrent(token, generation);
            final landed = released.skip(offset).nonNulls.firstOrNull;
            if (landed == null) {
              throw StateError('The selected song is no longer available.');
            }
            index = before + landed;
          } else {
            // Far into the tail or the played head: rebuild the player
            // around the target. Only a window around it is materialised;
            // the old queue is kept if the target cannot load.
            final entries = _logicalQueueEntries();
            final rows = await _rowsForDeferredEntries(entries);
            _checkQueueWorkCurrent(token, generation);
            final songs = <SongsTableData>[];
            final missing = <String>[];
            var jumpIndex = -1;
            for (var i = 0; i < rows.length; i++) {
              final row = rows[i];
              if (row == null) {
                missing.add(entries[i].id);
                continue;
              }
              if (i == logicalTarget) jumpIndex = songs.length;
              songs.add(row);
            }
            if (jumpIndex < 0) {
              throw StateError('The selected song is no longer available.');
            }
            farJumpRestore = _QueueRestorePoint(
              head: List<_DeferredQueueEntry>.of(_deferredHead),
              items: List<MediaItem>.of(_queueItems),
              tail: List<_DeferredQueueEntry>.of(_deferredTail),
              capture: (
                index: _player.currentIndex,
                position: _player.position,
                playing: _player.playing,
              ),
              missing: missing,
            );
            rebuildSongs = songs;
            index = jumpIndex;
            _setQueueReplacementMetadataAnchor(
              expectedIndex: index,
              mediaItem: _mediaItemForSong(songs[index]),
            );
            _setCurrentMediaItem(_queueReplacementMetadataAnchor!.mediaItem);
            _pendingLogicalQueueSongIds = List<String>.unmodifiable(
              songs.map((song) => song.id),
            );
            _emitSnapshot();
          }
        }

        if (rebuildSongs != null) {
          rebuiltPendingQueue = true;
          final songs = rebuildSongs;
          final rebuildIds = songs
              .map((song) => song.id)
              .toList(growable: false);
          final startItem = await _replaceQueuePhase1(
            songs: songs,
            startIndex: index,
            initialPosition: restorePosition,
            autoPlay: false,
            persist: false,
            generation: generation,
            token: token,
          );
          _checkQueueWorkCurrent(token, generation);
          if (shouldPlay && _isCurrentTransportIntent(transportGeneration)) {
            unawaited(_playWithFocusRecovery());
          }
          final preparedMetadata = _resolveCurrentQueueMetadata();
          if (preparedMetadata.currentIndex == index &&
              preparedMetadata.mediaItem?.id == rebuildIds[index]) {
            confirmSelection();
          }
          await _persistLogicalQueue(rebuildIds, index, generation: generation);
          if (startItem != null && songs.length > 1) {
            await _replaceQueuePhase2(
              songs: songs,
              startIndex: index,
              startItem: startItem,
              persist: true,
              token: token,
              generation: generation,
              deferTail: _shouldDeferTail(songs.length),
            );
          }
          preparedTargetIndex = _queueItems.indexWhere(
            (item) => identical(item, startItem?.mediaItem),
          );
        } else {
          final source = _player.audioSources.elementAtOrNull(index);
          final uri = switch (source) {
            UriAudioSource(:final uri) => uri,
            // Navis uses the vendored lock-cache primitive for remote sources.
            // ignore: experimental_member_use
            LockCachingAudioSource(:final uri) => uri,
            _ => null,
          };
          final coldRemote =
              (isExternalCatalogSource(id: targetId) ||
                  _remoteRows.containsKey(targetId)) &&
              _queueItems[index].extras?['sourceKind'] !=
                  PlaybackSourceKind.file.name &&
              uri != null &&
              (uri.scheme == 'http' || uri.scheme == 'https');
          if (coldRemote) {
            await _warmRemoteStream(
              uri,
              stillWanted: () =>
                  !token.isCancelled && _isActiveLoadGeneration(generation),
            );
            _checkQueueWorkCurrent(token, generation);
          }
          if (_player.processingState != ProcessingState.loading) {
            await _runTimedPlayerOperation(
              generation: generation,
              operation: 'manual queue navigation',
              action: () => _player.seek(Duration.zero, index: index),
              songId: targetId,
              timeout: coldRemote
                  ? _timeouts.remoteLoad
                  : _playerControlTimeout,
            );
          }
          _checkQueueWorkCurrent(token, generation);
          // just_audio ignores seek while loading. Reload the complete source
          // list at the desired index rather than accepting that no-op as
          // success; `audioSource` alone is only the first playlist child.
          if (_player.processingState == ProcessingState.loading ||
              _player.currentIndex != index) {
            final sources = List<AudioSource>.of(_player.audioSources);
            if (sources.isEmpty || index >= sources.length) {
              throw StateError(
                'Playback source is unavailable for navigation.',
              );
            }
            await _runTimedPlayerOperation(
              generation: generation,
              operation: 'manual navigation stop loading',
              action: _player.stop,
              songId: targetId,
              timeout: _playerResetTimeout,
            );
            _checkQueueWorkCurrent(token, generation);
            await _runTimedPlayerOperation(
              generation: generation,
              operation: 'manual navigation reload',
              extendWhileDownloading: true,
              timeout: coldRemote ? _timeouts.remoteLoad : _playerLoadTimeout,
              action: () => _player.setAudioSources(
                sources,
                preload: true,
                initialIndex: index,
                initialPosition: Duration.zero,
              ),
              songId: targetId,
            );
          }
        }

        _checkQueueWorkCurrent(token, generation);
        if (farJumpRestore != null) {
          _reportDroppedSongs(farJumpRestore.missing, QueueDropReason.rebuild);
        }
        final confirmedMetadata = _resolveCurrentQueueMetadata();
        if (rebuiltPendingQueue
            ? preparedTargetIndex == null ||
                  preparedTargetIndex < 0 ||
                  confirmedMetadata.currentIndex != preparedTargetIndex ||
                  confirmedMetadata.mediaItem?.id !=
                      rebuildSongs?.elementAtOrNull(index)?.id
            : _player.currentIndex != index) {
          throw StateError('Player did not confirm the requested queue entry.');
        }
        if (!_navigationIntent.isCurrent(decision.revision)) {
          return;
        }
        if (shouldPlay &&
            _isCurrentTransportIntent(transportGeneration) &&
            !_player.playing) {
          unawaited(_playWithFocusRecovery());
        }
        confirmSelection();
        _completeQueueLoad(generation);
        // The song just left may be an offset stream: repair its entry as a
        // queued edit, ahead of any later navigation. The reopen below is the
        // safety net for a landing that beat the repair.
        _repairDepartedOffsetEntries();
        if (!rebuiltPendingQueue &&
            _positionOffsetOf(_queueItems.elementAtOrNull(index)) >
                Duration.zero) {
          unawaited(seek(Duration.zero));
        }
      } on OperationCancelledException catch (error, stackTrace) {
        // Usually a later command cancelled this work and owns the target.
        // When nothing did, the cancellation came from inside (a release that
        // lost a race with a queue change), and nothing else would finish
        // this load: it would stay loading and stop every refill.
        if (_disposeHandlerStarted ||
            token.isCancelled ||
            !_isActiveLoadGeneration(generation)) {
          return;
        }
        await failNavigation(error, stackTrace);
      } on PlaybackLoadTimeoutException {
        if (!_isActiveLoadGeneration(generation)) return;
        _navigationTimeoutCount++;
        _navigationIntent.confirm(decision.revision);
        // Retry the requested occurrence first. Phase 1 warms remote streams
        // and its replacement lifecycle advances only if that load also fails.
        final resumePlaying = _latestExplicitTransportPlaying ?? shouldPlay;
        var recoveryRows = pendingSongs;
        var recoveryIndex = requestedIndex;
        if (recoveryRows == null && logicalIds.any(_remoteRows.containsKey)) {
          final rows = await _rowsForDeferredEntries(<_DeferredQueueEntry>[
            for (final id in logicalIds)
              _DeferredQueueEntry(id, _remoteRows[id]),
          ]);
          if (!_isActiveLoadGeneration(generation)) return;
          recoveryRows = rows.nonNulls.toList(growable: false);
          recoveryIndex = _startIndexAfterRowResolution(
            logicalIds,
            requestedIndex,
            recoveryRows,
          );
        }
        final recovery = recoveryRows == null
            ? _replaceQueueIds(
                logicalIds,
                startIndex: requestedIndex,
                autoPlay: resumePlaying,
                expandMatchFlows: false,
                inPlayOrder: true,
              )
            : _replaceQueueRows(
                recoveryRows,
                startIndex: recoveryIndex,
                autoPlay: resumePlaying,
                expandMatchFlows: false,
                inPlayOrder: true,
              );
        unawaited(
          recovery.catchError((Object error, StackTrace stack) {
            AppLogger.warning('Navigation fallback failed: $error');
          }),
        );
      } on Object catch (error, stackTrace) {
        if (!_isActiveLoadGeneration(generation)) return;
        await failNavigation(error, stackTrace);
      } finally {
        if (_navigationInFlightRevision == decision.revision) {
          _navigationInFlightRevision = null;
        }
      }
    });
    // Intent was admitted synchronously above. Awaiting queue fill here would
    // make every button press wait for unrelated playlist insertion work.
    unawaited(work);
    return Future<void>.value();
  }

  /// Puts back the queue a far jump replaced when its target could not load,
  /// and loads it into the player at the song that was playing.
  Future<void> _restoreQueueAfterFailedJump(_QueueRestorePoint restore) async {
    _clearQueueReplacementMetadataAnchor();
    _clearPendingLogicalQueue();
    final unchanged =
        _deferredHead.length == restore.head.length &&
        _deferredTail.length == restore.tail.length &&
        listEquals(
          _queueItems.map((item) => item.id).toList(growable: false),
          restore.items.map((item) => item.id).toList(growable: false),
        );
    if (unchanged) return;
    _restoreQueueLists(restore);
    await _reloadQueueAfterTimeout(restore.capture);
  }

  /// Puts back the queue lists [restore] captured, without touching the
  /// player.
  void _restoreQueueLists(_QueueRestorePoint restore) {
    _clearQueueReplacementMetadataAnchor();
    _clearPendingLogicalQueue();
    _queueItems
      ..clear()
      ..addAll(restore.items);
    _deferredHead
      ..clear()
      ..addAll(restore.head);
    _deferredTail
      ..clear()
      ..addAll(restore.tail);
  }

  /// Puts the logical queue into [order] (every queued song, the current one
  /// at logical index [newCurrent]) without interrupting the current song,
  /// now at logical index [current]. The Dart queue changes first and each
  /// native call follows, so a timed-out call reloads the new order. The
  /// usual window is materialised around the current song; for a long queue
  /// older songs wait in the deferred head and later ones in the tail.
  Future<bool> _rearrangeQueue(
    List<_DeferredQueueEntry> order, {
    required int current,
    required int newCurrent,
    required OperationToken token,
  }) async {
    final restore = _QueueRestorePoint(
      head: List<_DeferredQueueEntry>.of(_deferredHead),
      items: List<MediaItem>.of(_queueItems),
      tail: List<_DeferredQueueEntry>.of(_deferredTail),
      capture: (
        index: _player.currentIndex,
        position: _player.position,
        playing: _player.playing,
      ),
      missing: const <String>[],
    );
    try {
      final generation = _activeLoadGeneration;
      final materialisedCurrent = current - _deferredHead.length;
      final before = order.sublist(0, newCurrent);
      final logicalIds = _logicalQueueIds;
      final keepHistory =
          newCurrent == current &&
          Iterable<int>.generate(current)
              .every((i) => logicalIds[i] == before[i].id);
      // Everything after the current song leaves the player and waits in the
      // tail in its new order.
      final end = _queueItems.length;
      _queueItems.removeRange(materialisedCurrent + 1, end);
      _deferredTail
        ..clear()
        ..addAll(order.sublist(newCurrent + 1));
      if (materialisedCurrent + 1 < end) {
        await _removeQueueSourceRange(
          materialisedCurrent + 1,
          end,
          generation: generation,
          operation: 'shuffle order upcoming',
        );
      }
      if (!keepHistory) {
        final keep = _shouldDeferTail(order.length)
            ? math.min(before.length, _queueWindow.behind)
            : before.length;
        _queueItems.removeRange(0, materialisedCurrent);
        _deferredHead
          ..clear()
          ..addAll(before.sublist(0, before.length - keep));
        if (materialisedCurrent > 0) {
          await _removeQueueSourceRange(
            0,
            materialisedCurrent,
            generation: generation,
            operation: 'shuffle order history',
          );
        }
        final materialise = before.sublist(before.length - keep);
        if (materialise.isNotEmpty) {
          final rows = await _rowsForDeferredEntries(materialise);
          final (:prepared, :offsets) = await _prepareRowsConcurrently(rows);
          _reportDroppedSongs(<String>[
            for (var i = 0; i < materialise.length; i++)
              if (offsets[i] == null) materialise[i].id,
          ], QueueDropReason.rebuild);
          if (prepared.isNotEmpty) {
            await _applyMaterialisedInsert(
              prepared,
              at: 0,
              operation: 'shuffle order history insert',
            );
          }
        }
      }
      final total =
          _deferredHead.length + _queueItems.length + _deferredTail.length;
      try {
        await _releaseTail(
          count: _shouldDeferTail(total)
              ? _queueWindow.ahead
              : _deferredTail.length,
          token: token,
        );
      } on PlaybackSourceTemporarilyUnavailableException {
        // Unplayable-for-now songs stay deferred; releases retry later.
      }
    } on PlaybackLoadTimeoutException {
      // Timed edits reload the partly edited queue. Restore the original
      // lists and current occurrence before rolling the shuffle mode back.
      await _player.pause();
      _restoreQueueLists(restore);
      await _reloadQueueAfterTimeout(restore.capture);
      return false;
    }
    _afterQueueEdit(context: 'shuffle order');
    return true;
  }

  bool get _shouldStartNextShufflePass =>
      _shuffleEnabled &&
      _desiredLoopMode == LoopMode.all &&
      _logicalQueueIds.length > 1 &&
      _logicalCurrentIndex == _logicalQueueIds.length - 1;

  /// All forward wraps share one shuffle and keep the original ranks intact.
  Future<void> _startNextShufflePass({
    bool crossfade = false,
    bool shouldPlay = true,
    Duration delayBeforeFade = Duration.zero,
  }) => _nextShufflePass ??= _runNextShufflePass(
    crossfade: crossfade,
    shouldPlay: shouldPlay,
    delayBeforeFade: delayBeforeFade,
  ).whenComplete(() => _nextShufflePass = null);

  Future<void> _runNextShufflePass({
    required bool crossfade,
    required bool shouldPlay,
    required Duration delayBeforeFade,
  }) async {
    final generation = _activeLoadGeneration;
    final transport = _transportGeneration;
    bool stillWanted() =>
        _isActiveLoadGeneration(generation) &&
        _isCurrentTransportIntent(transport);
    var rearranged = false;
    try {
      await _enqueueQueueEdit((token) async {
        if (!stillWanted() || !_shuffleEnabled) return;
        final entries = _logicalQueueEntries();
        final current = _logicalCurrentIndex;
        if (current == null || current != entries.length - 1) return;
        final finished = entries[current];
        final starts = <int>[
          for (var i = 0; i < entries.length; i++)
            if (entries[i].id != finished.id) i,
        ];
        // A queue consisting of one repeated song has no different start.
        final start = starts.isEmpty
            ? 0
            : starts[_shuffleRandom.nextInt(starts.length)];
        final order = shuffledFromStart(entries, start, _shuffleRandom);
        if (crossfade) {
          // Native completion must still stop here if deck preparation fails.
          order.remove(finished);
          order.add(finished);
        }
        if (order.length > 2 && listEquals(order, entries)) {
          // Do not reuse an entire pass just because the random draw matched.
          final other = order.indexWhere(
            (entry) => entry.id != order.first.id && entry.id != finished.id,
            1,
          );
          if (other >= 0) {
            final item = order[0];
            order[0] = order[other];
            order[other] = item;
          }
        }
        _cancelCrossfade();
        rearranged = await _rearrangeQueue(
          order,
          current: current,
          newCurrent: order.indexOf(finished),
          token: token,
        );
        token.checkCancelled();
      });
    } on OperationCancelledException {
      return;
    }
    if (!rearranged || !stillWanted() || !_shuffleEnabled) return;
    _navigationIntent.reset();
    if (crossfade && _deferredHead.isEmpty) {
      await _startCrossfade(
        0,
        delayBeforeFade: delayBeforeFade,
        startsNextPass: true,
      );
    } else {
      await _applyNavigationDecision(
        _navigationIntent.select(0),
        logicalIds: _logicalQueueIds,
        shouldPlay: shouldPlay,
        context: 'shuffle next pass',
      );
    }
  }

  void _emitTransportVisualCue(
    TransportVisualIntent intent, {
    required String? fromSongId,
  }) {
    if (_transportVisualCueController.isClosed) {
      return;
    }
    _transportVisualCueController.add(
      TransportVisualCue(
        token: ++_transportVisualCueToken,
        intent: intent,
        fromSongId: fromSongId,
      ),
    );
  }
}
