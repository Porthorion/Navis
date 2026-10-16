part of 'navis_audio_handler.dart';

extension _NavisQueueWindow on NavisAudioHandler {
  /// Every queued song id in play order: the materialised queue followed by
  /// the deferred tail, or the requested order while a replacement loads.
  /// Cached per revision so playback events do not rebuild it.
  List<String> get _logicalQueueIds {
    final pending = _pendingLogicalQueueSongIds;
    if (pending != null) return pending;
    final cached = _logicalIdsCache;
    if (cached != null &&
        _logicalIdsQueueRevision == _queueItems.revision &&
        _logicalIdsTailRevision == _deferredTail.revision &&
        _logicalIdsHeadRevision == _deferredHead.revision) {
      return cached;
    }
    final ids = List<String>.unmodifiable(<String>[
      for (final entry in _deferredHead) entry.id,
      for (final item in _queueItems) item.id,
      for (final entry in _deferredTail) entry.id,
    ]);
    _logicalIdsCache = ids;
    _logicalIdsQueueRevision = _queueItems.revision;
    _logicalIdsTailRevision = _deferredTail.revision;
    _logicalIdsHeadRevision = _deferredHead.revision;
    return ids;
  }

  /// Drops every deferred song on both sides, for a queue that is being
  /// replaced or cleared, and restores the user's repeat mode and release
  /// backoff.
  Future<void> _clearDeferredTail() async {
    _deferredTail.clear();
    _deferredHead.clear();
    _tailReleaseFailures = 0;
    _tailReleaseRetryAt = null;
    await _syncNativeLoopMode();
  }

  _DeferredQueueEntry _deferredEntryFor(SongsTableData song) =>
      _DeferredQueueEntry(song.id, song.isExternal ? song : null);

  /// The deferred form of a materialised item, keeping a remote row.
  _DeferredQueueEntry _deferredEntryForItem(MediaItem item) =>
      _DeferredQueueEntry(item.id, _remoteRows[item.id]);

  /// Every queued song in logical order, as deferred entries.
  List<_DeferredQueueEntry> _logicalQueueEntries() => <_DeferredQueueEntry>[
    ..._deferredHead,
    for (final item in _queueItems) _deferredEntryForItem(item),
    ..._deferredTail,
  ];

  /// The logical index of materialised index [index].
  int? _logicalIndexOf(int? index) =>
      index == null ? null : index + _deferredHead.length;

  /// The logical index of the current song.
  int? get _logicalCurrentIndex =>
      _logicalIndexOf(_resolveCurrentQueueMetadata().currentIndex);

  void _rememberRemoteRow(SongsTableData song) {
    if (!song.isExternal) return;
    _remoteRows[song.id] = song;
    if (_remoteRows.length > 2 * _queueItems.length + 64) {
      final materialised = <String>{for (final item in _queueItems) item.id};
      _remoteRows.removeWhere(
        (id, _) => id != song.id && !materialised.contains(id),
      );
    }
  }

  bool _shouldDeferTail(int queueLength) =>
      queueLength > _queueWindow.deferThreshold;

  /// Applies the user's repeat mode to the native player, except that "all"
  /// waits until initial filling and deferred playback finish: the player
  /// would otherwise wrap before reaching every logical occurrence.
  Future<void> _syncNativeLoopMode() async {
    final native =
        _desiredLoopMode == LoopMode.all &&
            (_pendingLogicalQueueSongIds != null ||
                _deferredTail.isNotEmpty ||
                _deferredHead.isNotEmpty)
        ? LoopMode.off
        : _desiredLoopMode;
    if (_player.loopMode != native) {
      await _player.setLoopMode(native);
    }
    final inactiveDeck = _crossfadePlayer;
    if (inactiveDeck != null && inactiveDeck.loopMode != native) {
      await inactiveDeck.setLoopMode(native);
    }
  }

  bool _shouldReleaseTail() {
    if (_deferredTail.isEmpty ||
        _radioStation != null ||
        _pendingLogicalQueueSongIds != null ||
        _isLoading ||
        _isCrossfading ||
        _crossfadeHandoffInProgress) {
      return false;
    }
    final retryAt = _tailReleaseRetryAt;
    if (retryAt != null && DateTime.now().isBefore(retryAt)) return false;
    final current = _player.currentIndex ?? 0;
    return _queueItems.length - 1 - current < _queueWindow.lowWater;
  }

  /// Continues a completed native playlist after an initial fill or tail
  /// release, or wraps a queue whose played head has been released.
  void _continueIntoDeferredTail() {
    if (_continuingIntoDeferredTail ||
        _radioStation != null ||
        _pendingLogicalQueueSongIds != null ||
        _isLoading ||
        _player.processingState != ProcessingState.completed ||
        _latestExplicitTransportPlaying == false) {
      return;
    }
    final current = _logicalCurrentIndex;
    if (current == null) return;
    final next = current + 1;
    final wrap =
        next >= _logicalQueueIds.length &&
        _deferredHead.isNotEmpty &&
        _desiredLoopMode == LoopMode.all;
    if (next >= _logicalQueueIds.length && !wrap) return;
    _continuingIntoDeferredTail = true;
    unawaited(
      playFromIndex(wrap ? 0 : next)
          .whenComplete(() => _continuingIntoDeferredTail = false),
    );
  }

  /// Offers a background release when playback nears the end of the
  /// materialised queue. It runs only while the queue lane is idle and yields
  /// to every user command.
  void _maybeReleaseTail() {
    if (_disposeHandlerStarted) return;
    if (!_shouldReleaseTail()) {
      _maybeTrimPlayedSongs();
      return;
    }
    final started = _queueLane.tryRunIdle((token) async {
      if (!_shouldReleaseTail()) return;
      try {
        await _releaseTail(count: _queueWindow.page, token: token);
      } on OperationCancelledException {
        rethrow;
      } on Object catch (error, stackTrace) {
        _tailReleaseFailures++;
        final delay = Duration(
          seconds: math.min(60, 1 << math.min(6, _tailReleaseFailures)),
        );
        _tailReleaseRetryAt = DateTime.now().add(delay);
        Timer(delay, _maybeReleaseTail);
        AppLogger.warning(
          'Deferred queue release failed; retrying in ${delay.inSeconds}s. '
          '$error\n$stackTrace',
        );
      }
    });
    if (started == null) return;
    unawaited(started);
  }

  /// Moves up to [count] songs from the end of the deferred head back into
  /// the player, before the materialised queue, with one native insert (for
  /// Previous past the first song the player holds, or a near jump back).
  /// Permanently unavailable songs are dropped. Temporarily unavailable
  /// songs stay deferred with earlier history; only the suffix after them is
  /// released. A failed insert puts the songs back in the head.
  Future<void> _releaseHead({required int count, OperationToken? token}) async {
    if (_deferredHead.isEmpty || count <= 0) return;
    final take = count < _deferredHead.length ? count : _deferredHead.length;
    final start = _deferredHead.length - take;
    final entries = _deferredHead.sublist(start);
    final rows = await _rowsForDeferredEntries(entries);
    var retryThrough = -1;
    final (:prepared, :offsets) = await _prepareRowsConcurrently(
      rows,
      token: token,
      onRetryLater: (index) => retryThrough = math.max(retryThrough, index),
    );
    token?.checkCancelled();
    final releaseFrom = retryThrough + 1;
    if (releaseFrom == entries.length) {
      throw const PlaybackSourceTemporarilyUnavailableException(
        'Played songs are not playable right now.',
      );
    }
    final released = <_PreparedQueueItem>[
      for (var i = releaseFrom; i < entries.length; i++)
        if (offsets[i] case final offset?) prepared[offset],
    ];
    // Out of the head first: a timed-out insert reloads the materialised
    // queue, which must not list these songs twice.
    _deferredHead.removeRange(start + releaseFrom, _deferredHead.length);
    var inserted = const <_PreparedQueueItem>[];
    if (released.isNotEmpty) {
      try {
        inserted = await _applyMaterialisedInsert(
          released,
          at: 0,
          operation: 'release played songs',
        );
      } on Object {
        _deferredHead.addAll(entries.skip(releaseFrom));
        rethrow;
      }
    }
    final insertedIds = <_PreparedQueueItem>{...inserted};
    _reportDroppedSongs(<String>[
      for (var i = releaseFrom; i < entries.length; i++)
        if (offsets[i] == null || !insertedIds.contains(prepared[offsets[i]!]))
          entries[i].id,
    ], QueueDropReason.release);
    _afterQueueEdit(context: 'release played songs');
  }

  /// Moves played songs beyond [NavisQueueWindow.behind] out of the player
  /// into the deferred head, with one native range removal, once more than
  /// [NavisQueueWindow.trimSlack] have piled up. Idle work.
  Future<void> _trimPlayedSongs({OperationToken? token}) async {
    final current = _player.currentIndex;
    if (current == null || !_shouldTrimPlayedSongs()) return;
    final count = current - _queueWindow.behind;
    final moved = _queueItems.sublist(0, count);
    // Dart first, so a timed-out removal reloads the trimmed queue.
    _queueItems.removeRange(0, count);
    _deferredHead.addAll(moved.map(_deferredEntryForItem));
    await _removeQueueSourceRange(
      0,
      count,
      generation: _activeLoadGeneration,
      operation: 'trim played songs',
    );
    token?.checkCancelled();
    await _syncNativeLoopMode();
    _afterQueueEdit(context: 'trim played songs');
  }

  void _maybeTrimPlayedSongs() {
    if (_disposeHandlerStarted || !_shouldTrimPlayedSongs()) return;
    final started = _queueLane.tryRunIdle((token) async {
      if (!_shouldTrimPlayedSongs()) return;
      try {
        await _trimPlayedSongs(token: token);
      } on OperationCancelledException {
        rethrow;
      } on Object catch (error, stackTrace) {
        AppLogger.warning('Trimming played songs failed. $error\n$stackTrace');
      }
    });
    if (started == null) return;
    unawaited(started);
  }

  bool _shouldTrimPlayedSongs() {
    if (_radioStation != null ||
        _pendingLogicalQueueSongIds != null ||
        _isLoading ||
        _isCrossfading ||
        _crossfadeHandoffInProgress) {
      return false;
    }
    final current = _player.currentIndex;
    // Only long queues (like any that deferred songs); a short queue stays
    // whole in the player.
    return current != null &&
        current < _queueItems.length &&
        current > _queueWindow.behind + _queueWindow.trimSlack &&
        _shouldDeferTail(
          _deferredHead.length + _queueItems.length + _deferredTail.length,
        );
  }

  Future<List<SongsTableData?>> _rowsForDeferredEntries(
    List<_DeferredQueueEntry> entries,
  ) async {
    // By canonical id: a song remapped to its canonical row may still wait
    // here under its old id until the queue catches up with the alias.
    final missing = <String>[
      for (final entry in entries)
        if (entry.song == null) _canonicalSongId(entry.id),
    ];
    final byId = <String, SongsTableData>{
      if (missing.isNotEmpty)
        for (final song in await _libraryDao.getSongsByIds(missing))
          song.id: song,
    };
    return <SongsTableData?>[
      for (final entry in entries)
        entry.song ?? byId[_canonicalSongId(entry.id)],
    ];
  }

  /// Finds [songId] in the logical queue, preferring [expected] and then the
  /// nearest other occurrence. Returns -1 when the song is no longer queued.
  int _locateQueueTarget(String songId, int expected) {
    final ids = _logicalQueueIds;
    if (expected >= 0 && expected < ids.length && ids[expected] == songId) {
      return expected;
    }
    for (var distance = 1; distance < ids.length; distance++) {
      final before = expected - distance;
      final after = expected + distance;
      if (before < 0 && after >= ids.length) break;
      if (before >= 0 && before < ids.length && ids[before] == songId) {
        return before;
      }
      if (after >= 0 && after < ids.length && ids[after] == songId) {
        return after;
      }
    }
    return -1;
  }
}
