part of 'navis_audio_handler.dart';

extension _NavisQueueEditing on NavisAudioHandler {
  /// Appends [entries] to the end of the logical queue without interrupting
  /// playback. Behind a deferred tail they simply join it; otherwise up to one
  /// page is materialised with a single native append and the rest deferred.
  /// Returns the ids that were dropped as unplayable.
  Future<List<String>> _appendToQueue(
    List<_DeferredQueueEntry> entries, {
    required OperationToken token,
    required String context,
  }) async {
    if (entries.isEmpty) return const <String>[];
    if (_deferredTail.isNotEmpty) {
      _deferredTail.addAll(entries);
      _afterQueueEdit(context: context);
      return const <String>[];
    }
    final materialize = entries.length > _queueWindow.page
        ? entries.sublist(0, _queueWindow.page)
        : entries;
    final rows = await _rowsForDeferredEntries(materialize);
    final (:prepared, :offsets) = await _prepareRowsConcurrently(
      rows,
      token: token,
    );
    final skipped = <String>[
      for (var i = 0; i < materialize.length; i++)
        if (offsets[i] == null) materialize[i].id,
    ];
    var inserted = const <_PreparedQueueItem>[];
    if (prepared.isNotEmpty) {
      final wasPlayingBeforeMutation = _player.playing;
      final firstInsertedIndex = _queueItems.length;
      final queueWasCompletedBeforeInsertion =
          _player.processingState == ProcessingState.completed;
      inserted = await _applyMaterialisedInsert(
        prepared,
        at: _queueItems.length,
        operation: '$context append',
      );
      skipped.addAll(
        prepared
            .where((item) => !inserted.contains(item))
            .map((item) => item.song.id),
      );
      await _resumeInsertedItemIfCompleted(
        wasPlayingBeforeMutation: wasPlayingBeforeMutation,
        queueWasCompletedBeforeInsertion: queueWasCompletedBeforeInsertion,
        firstInsertedIndex: firstInsertedIndex,
      );
    }
    if (materialize.length < entries.length) {
      _deferredTail.addAll(entries.sublist(materialize.length));
      await _syncNativeLoopMode();
    }
    if (inserted.isEmpty && materialize.length == entries.length) {
      return skipped;
    }
    _afterQueueEdit(context: context);
    return skipped;
  }

  /// Inserts prepared songs at materialised index [at] with one native call
  /// (and one mirror call on an in-sync crossfade deck). A successful native
  /// call is always committed. When the batch fails, songs are inserted one by
  /// one and the failing ones skipped. Returns the songs that were inserted.
  Future<List<_PreparedQueueItem>> _applyMaterialisedInsert(
    List<_PreparedQueueItem> prepared, {
    required int at,
    required String operation,
  }) async {
    final inactiveDeck = _crossfadePlayer;
    final deckInSync =
        inactiveDeck != null &&
        inactiveDeck.sequence.length == _queueItems.length;
    Future<void> apply(int index, List<_PreparedQueueItem> items) {
      final sources = items
          .map((item) => item.audioSource)
          .toList(growable: false);
      return _runTimedPlayerOperation(
        generation: _activeLoadGeneration,
        operation: operation,
        action: () => index >= _queueItems.length
            ? _player.addAudioSources(sources)
            : _player.insertAudioSources(index, sources),
        songId: items.first.song.id,
        cancelAfterSuccess: false,
        reloadQueueOnTimeout: true,
      );
    }

    final inserted = <_PreparedQueueItem>[];
    try {
      await apply(at, prepared);
      _queueItems.insertAll(at, prepared.map((item) => item.mediaItem));
      inserted.addAll(prepared);
    } on PlaybackLoadTimeoutException {
      rethrow;
    } on OperationCancelledException {
      rethrow;
    } on Object catch (error) {
      AppLogger.warning(
        '$operation failed for ${prepared.length} songs; inserting them one '
        'by one. $error',
      );
      var index = at;
      for (final item in prepared) {
        try {
          await apply(index, <_PreparedQueueItem>[item]);
        } on PlaybackLoadTimeoutException {
          rethrow;
        } on Object {
          _lastFailedSongId = item.song.id;
          continue;
        }
        _queueItems.insert(index, item.mediaItem);
        inserted.add(item);
        index++;
      }
    }
    if (deckInSync && inserted.isNotEmpty) {
      final clones = inserted
          .map((item) => item.source.asClonedAudioSource(tag: item.mediaItem))
          .toList(growable: false);
      try {
        if (at >= inactiveDeck.sequence.length) {
          await inactiveDeck.addAudioSources(clones);
        } else {
          await inactiveDeck.insertAudioSources(at, clones);
        }
      } on Object catch (error) {
        AppLogger.debug('$operation inactive deck mirror failed: $error');
      }
    }
    _observeLockCacheForPrepared(inserted);
    return inserted;
  }

  /// Publishes a queue edit: one queue emission, one coalesced save, one
  /// snapshot.
  void _afterQueueEdit({required String context}) {
    final seek = _pendingSeek;
    if (seek != null &&
        _resolveCurrentQueueMetadata().mediaItem?.id == seek.songId) {
      seek.queueIndex = _logicalCurrentIndex;
    }
    // An edit may have emptied the deferred tail, which re-enables repeat-all.
    unawaited(
      _syncNativeLoopMode().catchError((Object error) {
        AppLogger.debug('Repeat mode sync after "$context" failed: $error');
      }),
    );
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    // An index event emitted during the native edit may have been deferred
    // until this mirror committed. Refresh its song-scoped state now.
    if (!_isLoading && _pendingLogicalQueueSongIds == null) {
      final resolved = _resolveCurrentQueueMetadata();
      _updateScrobbleSession(
        resolved.mediaItem,
        currentIndex: resolved.currentIndex,
      );
      _applyReplayGainVolume();
    }
    _scheduleQueueItemsPersistence(context: context);
    _broadcastPlaybackState();
    _emitSnapshot();
  }

  /// Runs a queue edit in order behind other queue work. An edit that finds
  /// a replacement still loading (its owner was superseded by a navigation
  /// queued after this edit) waits for that once, so it applies to the
  /// finished queue rather than the half-built one. Waiting means going to
  /// the back of the lane, so later edits that reach the front first go
  /// back too: edits always apply in the order they were made.
  Future<void> _enqueueQueueEdit(
    Future<void> Function(OperationToken token) edit,
  ) {
    final done = Completer<void>();
    final sequence = ++_queueEditSequence;
    var waitedForLoad = false;
    Future<void> attempt() async {
      var requeue = false;
      OperationToken? ran;
      try {
        await _queueLane.enqueue((token) async {
          await _ready;
          final behindWaitingEdit = _requeuedQueueEdits.any(
            (earlier) => earlier < sequence,
          );
          if (behindWaitingEdit ||
              (!waitedForLoad && _pendingLogicalQueueSongIds != null)) {
            if (!behindWaitingEdit) waitedForLoad = true;
            _requeuedQueueEdits.add(sequence);
            requeue = true;
            return;
          }
          ran = token;
          await edit(token);
        });
      } on Object catch (error, stackTrace) {
        _requeuedQueueEdits.remove(sequence);
        if (!done.isCompleted) done.completeError(error, stackTrace);
        return;
      }
      if (requeue) {
        unawaited(attempt());
        return;
      }
      _requeuedQueueEdits.remove(sequence);
      if (done.isCompleted) return;
      // A replacement discarded the edit before it ran or stopped it midway;
      // report that rather than success.
      if (ran == null || ran!.isCancelled) {
        done.completeError(OperationCancelledException());
      } else {
        done.complete();
      }
    }

    unawaited(attempt());
    return done.future;
  }

  /// Moves the materialised songs from [from] onward back to the front of
  /// the deferred tail with one native range removal.
  Future<void> _deferMaterialisedFrom(int from) async {
    final end = _queueItems.length;
    if (from >= end) return;
    final inactiveDeck = _crossfadePlayer;
    final deckInSync =
        inactiveDeck != null && inactiveDeck.sequence.length == end;
    await _runTimedPlayerOperation(
      generation: _activeLoadGeneration,
      operation: 'defer materialised queue',
      reloadQueueOnTimeout: true,
      action: () => _player.removeAudioSourceRange(from, end),
      songId: _queueItems[from].id,
      timeout: _playerResetTimeout,
      cancelAfterSuccess: false,
    );
    final moved = _queueItems.sublist(from);
    _queueItems.removeRange(from, end);
    _deferredTail.insertAll(0, moved.map(_deferredEntryForItem));
    if (deckInSync) {
      try {
        await inactiveDeck.removeAudioSourceRange(from, end);
      } on Object catch (error) {
        AppLogger.debug('Deferred range deck mirror failed: $error');
      }
    }
  }

  /// Applies a queue edit the Dart queue already reflects to the active
  /// player, and then to the inactive crossfade deck when [mirror] says it
  /// is in step. A stuck native call times out and reloads the queue into
  /// rebuilt players instead of holding the queue lane forever.
  Future<void> _timedQueueEdit(
    String operation,
    Future<void> Function(AudioPlayer player) action, {
    required String songId,
    bool Function(AudioPlayer deck)? mirror,
  }) async {
    await _runTimedPlayerOperation(
      generation: _activeLoadGeneration,
      operation: operation,
      action: () => action(_player),
      songId: songId,
      timeout: _playerResetTimeout,
      cancelAfterSuccess: false,
      reloadQueueOnTimeout: true,
    );
    final deck = _crossfadePlayer;
    if (deck == null || !(mirror?.call(deck) ?? false)) return;
    try {
      await _runTimedPlayerOperation(
        generation: _activeLoadGeneration,
        operation: '$operation inactive',
        action: () => action(deck),
        songId: songId,
        timeout: _playerResetTimeout,
        cancelAfterSuccess: false,
        reloadQueueOnTimeout: true,
      );
    } on Object catch (error) {
      AppLogger.debug('$operation inactive deck mirror failed: $error');
    }
  }

  Future<void> _removeQueueSourceRange(
    int start,
    int end, {
    required int generation,
    required String operation,
  }) async {
    await _runTimedPlayerOperation(
      generation: generation,
      operation: operation,
      action: () => _player.removeAudioSourceRange(start, end),
      songId: '$start-$end',
      timeout: _playerResetTimeout,
      reloadQueueOnTimeout: true,
    );
    final inactiveDeck = _crossfadePlayer;
    if (inactiveDeck == null) {
      return;
    }
    try {
      await _runTimedPlayerOperation(
        generation: generation,
        operation: '$operation inactive',
        action: () => inactiveDeck.removeAudioSourceRange(start, end),
        songId: '$start-$end',
        timeout: _playerResetTimeout,
        // Recovery rebuilds both decks, emptying the active one too.
        reloadQueueOnTimeout: true,
      );
    } on Object catch (error) {
      AppLogger.debug(
        '$operation inactive deck range removal failed '
        'for $start-$end: $error',
      );
    }
  }

  Future<void> _resumeInsertedItemIfCompleted({
    required bool wasPlayingBeforeMutation,
    required bool queueWasCompletedBeforeInsertion,
    required int firstInsertedIndex,
  }) async {
    final resumeIndex = navisResumeIndexAfterQueueInsertion(
      wasPlayingBeforeMutation: wasPlayingBeforeMutation,
      queueWasCompletedBeforeMutation: queueWasCompletedBeforeInsertion,
      processingStateAfterMutation: _player.processingState,
      firstInsertedIndex: firstInsertedIndex,
      queueLength: _queueItems.length,
    );
    if (resumeIndex == null) {
      return;
    }

    _clearQueueReplacementMetadataAnchor();
    await _player.seek(Duration.zero, index: resumeIndex);
    final inactiveDeck = _crossfadePlayer;
    if (inactiveDeck != null) {
      try {
        await inactiveDeck.seek(Duration.zero, index: resumeIndex);
      } on Object catch (error) {
        AppLogger.debug(
          'inactive deck seek after completed queue insertion failed: $error',
        );
      }
    }
    if (resumeIndex >= 0 && resumeIndex < _queueItems.length) {
      _setCurrentMediaItem(_queueItems[resumeIndex]);
    }
    unawaited(_player.play());
  }

  /// [removeAt] for index [index] past the deferred head.
  Future<void> _removeAtLocked(int index) async {
    {
      final total =
          _deferredHead.length + _queueItems.length + _deferredTail.length;
      if (index < 0 || index >= total - _deferredHead.length) {
        return;
      }

      if (total == 1) {
        await _clearQueueInternal(persist: true);
        return;
      }

      if (index >= _queueItems.length) {
        _deferredTail.removeAt(index - _queueItems.length);
        if (_deferredTail.isEmpty) await _syncNativeLoopMode();
        _scheduleQueueItemsPersistence(context: 'remove at');
        _broadcastPlaybackState();
        _emitSnapshot();
        return;
      }

      // The player needs a following song before its last materialised one
      // goes; otherwise removing the current song would end playback.
      if (index == _queueItems.length - 1 && _deferredTail.isNotEmpty) {
        try {
          await _releaseTail(count: _queueWindow.page);
        } on PlaybackSourceTemporarilyUnavailableException {
          // Nothing playable follows yet; the removal still applies.
        }
      }

      // Remove the audio source and queue item incrementally — this does NOT
      // interrupt playback of other items.  If the currently playing item is
      // removed, just_audio automatically advances to the next item.
      if (_logicalCurrentIndex == _deferredHead.length + index) {
        _seekLane.cancelCurrent();
        _cancelPendingSeek();
      }
      final removed = _queueItems.removeAt(index);
      await _timedQueueEdit(
        'remove queue item',
        (player) => player.removeAudioSourceAt(index),
        songId: removed.id,
        mirror: (deck) => deck.sequence.length > index,
      );

      // Update the mediaItem stream to match whatever is now current.
      final nowIndex = _player.currentIndex;
      if (nowIndex != null && nowIndex >= 0 && nowIndex < _queueItems.length) {
        _setCurrentMediaItem(_queueItems[nowIndex]);
      }

      _afterQueueEdit(context: 'remove at');
    }
  }

  /// [reorderQueue] with both indices past the deferred head.
  Future<void> _reorderLocked(int oldIndex, int newIndex) async {
    {
      final total = _queueItems.length + _deferredTail.length;
      if (total == 0) {
        return;
      }
      if (oldIndex < 0 || oldIndex >= total) {
        return;
      }
      // ReorderableListView can report newIndex == length when dragging to
      // the end; treat that as a valid destination.
      if (newIndex < 0 || newIndex > total) {
        return;
      }

      final adjustedIndex = oldIndex < newIndex
          ? newIndex - 1
          : newIndex.clamp(0, total - 1);
      if (oldIndex == adjustedIndex) {
        return;
      }

      var materialized = _queueItems.length;
      if (oldIndex >= materialized && adjustedIndex >= materialized) {
        // Both ends deferred: a Dart-only move.
        final entry = _deferredTail.removeAt(oldIndex - materialized);
        _deferredTail.insert(adjustedIndex - materialized, entry);
      } else if (oldIndex >= materialized) {
        // Deferred song moved into the player's window: resolve it and insert
        // it with one native call.
        final entry = _deferredTail.removeAt(oldIndex - materialized);
        final List<_PreparedQueueItem> inserted;
        try {
          final rows = await _rowsForDeferredEntries(<_DeferredQueueEntry>[
            entry,
          ]);
          final (:prepared, offsets: _) = await _prepareRowsConcurrently(rows);
          inserted = prepared.isEmpty
              ? const <_PreparedQueueItem>[]
              : await _applyMaterialisedInsert(
                  prepared,
                  at: adjustedIndex,
                  operation: 'reorder into window',
                );
        } on Object {
          // Keep the song queued where it was.
          _deferredTail.insert(oldIndex - materialized, entry);
          rethrow;
        }
        if (inserted.isEmpty) {
          _tailDroppedSongCount++;
          _reportDroppedSongs(<String>[entry.id], QueueDropReason.insert);
        }
      } else {
        if (adjustedIndex >= materialized &&
            oldIndex == (_player.currentIndex ?? -1)) {
          // Keep the playing song in the player: release through the target
          // so the move stays inside the window.
          try {
            await _releaseTail(count: adjustedIndex - materialized + 1);
          } on PlaybackSourceTemporarilyUnavailableException {
            // The target stays deferred; the move below handles that.
          }
          materialized = _queueItems.length;
        }
        if (adjustedIndex < materialized) {
          // Reorder the in-memory queue items to match the new order.
          final movedItem = _queueItems.removeAt(oldIndex);
          _queueItems.insert(adjustedIndex, movedItem);

          // Move the audio source in the player's playlist — this does NOT
          // interrupt playback; just_audio tracks the current item internally.
          _nativeMoveCount++;
          await _timedQueueEdit(
            'reorder queue',
            (player) => player.moveAudioSource(oldIndex, adjustedIndex),
            songId: movedItem.id,
            mirror: (deck) =>
                deck.sequence.length > oldIndex &&
                deck.sequence.length > adjustedIndex,
          );
        } else {
          // Materialised song moved behind the window: take it out of the
          // player and defer it at its new logical position.
          // Deferred before the native call, so a timeout cannot lose it.
          final movedItem = _queueItems.removeAt(oldIndex);
          _deferredTail.insert(
            adjustedIndex - _queueItems.length,
            _deferredEntryForItem(movedItem),
          );
          await _timedQueueEdit(
            'reorder behind window',
            (player) => player.removeAudioSourceAt(oldIndex),
            songId: movedItem.id,
            mirror: (deck) => deck.sequence.length > oldIndex,
          );
        }
      }

      // Reorders arrive in bursts (drag sequences), and each full-queue write
      // rewrites every row. Persist once the burst settles.
      _afterQueueEdit(context: 'reorder queue');
    }
  }

  /// Rewrites queued songs to their canonical ids after an alias update.
  void _remapQueueToCanonicalIds() {
    MediaItem remap(MediaItem item) {
      final canonicalId = _canonicalSongId(item.id);
      return canonicalId == item.id ? item : item.copyWith(id: canonicalId);
    }

    for (var index = 0; index < _queueItems.length; index++) {
      _queueItems.replaceAt(index, remap(_queueItems[index]));
    }
    for (var index = 0; index < _deferredTail.length; index++) {
      final entry = _deferredTail[index];
      // A remote row keeps its own id and source.
      if (entry.song != null) continue;
      final canonicalId = _canonicalSongId(entry.id);
      if (canonicalId != entry.id) {
        _deferredTail.replaceAt(index, _DeferredQueueEntry(canonicalId));
      }
    }
    final original = _originalOrder;
    if (original != null) {
      _originalOrder = original.map(_canonicalSongId).toList(growable: false);
    }
    final pending = _pendingLogicalQueueSongIds;
    if (pending != null) {
      _pendingLogicalQueueSongIds = List<String>.unmodifiable(
        pending.map(_canonicalSongId),
      );
    }
    if (_currentMediaItem != null) {
      _setCurrentMediaItem(remap(_currentMediaItem!));
    }
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _emitSnapshot();
    _scheduleQueueItemsPersistence(context: 'song identity alias update');
  }

  String _canonicalSongId(String songId) {
    var current = songId;
    final visited = <String>{};
    while (visited.add(current)) {
      final next = _songIdentityAliases[current];
      if (next == null || next == current) {
        return current;
      }
      current = next;
    }
    return current;
  }
}
