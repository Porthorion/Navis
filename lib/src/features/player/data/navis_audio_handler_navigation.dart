part of 'navis_audio_handler.dart';

extension _NavisNavigation on NavisAudioHandler {
  int _supersedeTransportIntent({bool? shouldPlay, bool preserveSeek = false}) {
    if (!preserveSeek || (shouldPlay != null && _pendingSeek == null)) {
      _seekFailureBlocksRecovery = false;
    }
    if (!preserveSeek) {
      _seekLane.cancelCurrent();
      _cancelPendingSeek();
    }
    _remotePlaybackRecoveryAttempts.clear();
    if (shouldPlay != null) _latestExplicitTransportPlaying = shouldPlay;
    return ++_transportGeneration;
  }

  bool _isCurrentTransportIntent(int generation) =>
      generation == _transportGeneration;

  Future<void> _navigateRelative({required bool forward}) {
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
      confirmedPosition: _player.position,
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
    if (!decision.canApply) return Future<void>.value();
    _invalidatePendingStartupSelection();
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
    final requestedIndex = decision.index!;
    final targetId = logicalIds[requestedIndex];
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
            autoPlay: false,
            persist: false,
            generation: generation,
            token: token,
          );
          _checkQueueWorkCurrent(token, generation);
          if (shouldPlay && _isCurrentTransportIntent(transportGeneration)) {
            unawaited(_player.play());
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
          unawaited(_player.play());
        }
        confirmSelection();
        _completeQueueLoad(generation);
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
