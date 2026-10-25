part of 'navis_audio_handler.dart';

extension _NavisDiagnostics on NavisAudioHandler {
  void _invalidatePendingStartupSelection() {
    _activeStartupTrace?.mark('superseded');
    _activeStartupTrace = null;
  }

  void _acceptStartupSelection(String songId, {required bool isExternal}) {
    final trace = _activeStartupTrace;
    if (trace == null || !trace.awaitingHandler || trace.songId != songId) {
      beginPlaybackSelection(songId, isExternal: isExternal);
    }
    _activeStartupTrace?.awaitingHandler = false;
    _activeStartupTrace?.mark('handlerAccepted');
  }

  Map<String, Object?> _anomalyHeader() => <String, Object?>{
    'index': _logicalCurrentIndex,
    'platform': Platform.operatingSystem,
    'sourceKind': _currentSourceKind,
    'offset': _positionOffsetOf(_currentMediaItem) > Duration.zero,
    'loopMode': _desiredLoopMode.name,
    'shuffle': _shuffleEnabled,
    'crossfade': _crossfadeEnabled,
    'gapless': _gaplessEnabled,
    'processingState': _player.processingState.name,
  };

  /// Repeat One, or Repeat All over a single entry: the song restarts itself.
  bool get _anomalyLooping =>
      _desiredLoopMode == LoopMode.one ||
      (_desiredLoopMode == LoopMode.all && _queueItems.length == 1);

  /// Observation must never reach a player listener or a transport command.
  void _anomalySafely(void Function() body) {
    try {
      body();
    } on Object {
      // Observe only.
    }
  }

  void _observeAnomalyPosition(Duration position) => _anomalySafely(() {
    // The song the player itself plays, from the same event as its position:
    // _currentMediaItem is published up to ~1.5 s before a skipped-to song
    // loads, while the position stream still reports the previous song's.
    // The tag also stays right on a single-source cross-fade deck.
    final raw = _player.playbackEvent.currentIndex;
    final index = raw == null || raw < 0 ? null : raw;
    final tag = index == null
        ? null
        : _player.sequence.elementAtOrNull(index)?.tag;
    final song = tag is MediaItem ? tag : _currentMediaItem;
    if (song == null || _radioStation != null) return;
    final state = _player.processingState;
    final duration = _effectivePlaybackDuration(song);
    _anomalies.observePosition(
      position: position,
      entryKey:
          (index == null ? null : _queueItems.elementAtOrNull(index)) ?? song,
      songId: song.id,
      duration: duration > Duration.zero ? duration : null,
      repeatOne: _anomalyLooping,
      playing:
          _player.playing &&
          (state == ProcessingState.ready ||
              state == ProcessingState.buffering),
      seeking: _pendingSeek != null,
    );
  });

  /// Rows of the last 30 s kept for a record (downsampled by the recorder).
  void _recordAnomalyPlaybackEvent(PlaybackEvent event) => _anomalySafely(() {
    _anomalies.playbackEvent(
      state: event.processingState.name,
      index: event.currentIndex,
      updatePosition: event.updatePosition,
      updateTime: event.updateTime,
      advancing:
          _player.playing && event.processingState == ProcessingState.ready,
      // Paused or completed: the next position is a new baseline. Idle is
      // not: a failing stream goes idle, and its recovery must still be
      // compared with the position it lost (stop and loads are expectations).
      // A reload under a pending seek may drop `playing` for a moment.
      active:
          (_player.playing || _pendingSeek != null) &&
          event.processingState != ProcessingState.completed,
      fields: () => <String, Object?>{
        'state': event.processingState.name,
        'updatePositionMs': event.updatePosition.inMilliseconds,
        'updateTimeAgoMs': DateTime.now()
            .difference(event.updateTime)
            .inMilliseconds,
        'bufferedMs': event.bufferedPosition.inMilliseconds,
        'index': event.currentIndex,
      },
    );
  });

  /// A native loop on the same entry is expected, anything else a plain row.
  void _recordAnomalyDiscontinuity(PositionDiscontinuity discontinuity) =>
      _anomalySafely(() {
        final index = discontinuity.event.currentIndex;
        final fields = <String, Object?>{
          'reason': discontinuity.reason.name,
          'index': index,
          'fromIndex': discontinuity.previousEvent.currentIndex,
        };
        final loops =
            discontinuity.reason == PositionDiscontinuityReason.autoAdvance &&
            index == discontinuity.previousEvent.currentIndex &&
            _anomalyLooping;
        if (loops) {
          _anomalies.expect('loop', fields);
        } else {
          _anomalies.event('disc', fields);
        }
      });

  /// Whether [player] holds exactly the materialised queue, by song id (an
  /// id remapped to its canonical song since it was loaded still matches).
  bool _sequenceMatchesQueue(AudioPlayer player) {
    final sequence = player.sequence;
    if (sequence.length != _queueItems.length) return false;
    for (var i = 0; i < sequence.length; i++) {
      final nativeId = navisNativeSourceSongId(sequence[i]);
      if (nativeId == null) return false;
      final id = _queueItems[i].id;
      if (nativeId != id &&
          _canonicalSongId(nativeId) != _canonicalSongId(id)) {
        return false;
      }
    }
    return true;
  }

  void _traceSourceResolved(
    SongsTableData song,
    ResolvedPlaybackSource source,
  ) {
    _transportTrace.record('sourceResolved', () {
      final query =
          (source.uri ?? source.lockCachingStreamUri)?.queryParameters ??
          const <String, String>{};
      final cachedPath = source.cachedFilePath;
      return <String, Object?>{
        'songId': song.id,
        'sourceKind': source.kind.name,
        // Never the URL: it carries credentials.
        'format': query['format'],
        'maxBitRate': query['maxBitRate'],
        'timeOffset': query['timeOffset'],
        'sidecar': source.sidecarCacheFilePath != null,
        if (source.isLocal)
          'localFolder': source.uri!.pathSegments.reversed.skip(1).firstOrNull,
        if (cachedPath != null) 'cacheFile': true,
      };
    });
  }

  int? _partialCacheBytesForSong(String? songId) {
    if (songId == null) {
      return null;
    }
    if (_sidecarDownloader.activeSongId == songId) {
      return _sidecarDownloader.activeReceivedBytes;
    }
    for (final entry in _rollingCacheActivities.entries) {
      if (entry.value.songId != songId) {
        continue;
      }
      final partFile = File('${entry.key}.part');
      if (partFile.existsSync()) {
        return partFile.lengthSync();
      }
      final completed = File(entry.key);
      if (completed.existsSync()) {
        return completed.lengthSync();
      }
    }
    String? cachedPath;
    for (final item in _queueItems) {
      if (item.id != songId) {
        continue;
      }
      cachedPath = item.extras?['cachedFilePath'] as String?;
      break;
    }
    if (cachedPath == null || cachedPath.isEmpty) {
      return null;
    }
    final partFile = File('$cachedPath.part');
    if (partFile.existsSync()) {
      return partFile.lengthSync();
    }
    final completed = File(cachedPath);
    if (completed.existsSync()) {
      return completed.lengthSync();
    }
    return null;
  }
}
