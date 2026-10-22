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

  void _observeAnomalyPosition(Duration position) {
    // The song the handler publishes: the native index is not the queue index
    // on a single-source cross-fade deck. The entry only labels a record.
    final song = _currentMediaItem;
    if (song == null || _radioStation != null) return;
    final index = _player.currentIndex;
    final state = _player.processingState;
    final duration = _effectivePlaybackDuration(song);
    _anomalies.observePosition(
      position: position,
      entryKey:
          (index == null ? null : _queueItems.elementAtOrNull(index)) ?? song,
      songId: song.id,
      duration: duration > Duration.zero ? duration : null,
      repeatOne: _desiredLoopMode == LoopMode.one,
      playing:
          _player.playing &&
          (state == ProcessingState.ready ||
              state == ProcessingState.buffering),
      seeking: _pendingSeek != null,
    );
  }

  /// Rows of the last 30 s kept for a record; unchanged events are skipped.
  void _recordAnomalyPlaybackEvent(PlaybackEvent event) {
    final key = (
      state: event.processingState,
      index: event.currentIndex,
      position: event.updatePosition,
    );
    if (key == _lastAnomalyPlaybackEvent) return;
    _lastAnomalyPlaybackEvent = key;
    _anomalies.event('pb', <String, Object?>{
      'state': event.processingState.name,
      'updatePositionMs': event.updatePosition.inMilliseconds,
      'updateTimeAgoMs': DateTime.now()
          .difference(event.updateTime)
          .inMilliseconds,
      'bufferedMs': event.bufferedPosition.inMilliseconds,
      'index': event.currentIndex,
    });
  }

  /// A native loop on the same entry is expected, anything else a plain row.
  void _recordAnomalyDiscontinuity(PositionDiscontinuity discontinuity) {
    final index = discontinuity.event.currentIndex;
    final fields = <String, Object?>{
      'reason': discontinuity.reason.name,
      'index': index,
      'fromIndex': discontinuity.previousEvent.currentIndex,
    };
    final loops =
        discontinuity.reason == PositionDiscontinuityReason.autoAdvance &&
        index == discontinuity.previousEvent.currentIndex &&
        (_desiredLoopMode == LoopMode.one ||
            (_desiredLoopMode == LoopMode.all && _queueItems.length == 1));
    if (loops) {
      _anomalies.expect('loop', fields);
    } else {
      _anomalies.event('disc', fields);
    }
  }

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
