part of 'navis_audio_handler.dart';

extension _NavisRadio on NavisAudioHandler {
  bool _isTransientRadioFailure(Object error) =>
      error is SocketException ||
      error is HttpException ||
      error is TimeoutException ||
      (error is PlayerException &&
          navisShouldReconnectRadioSource(
            errorCode: error.code,
            message: error.message,
            usesMediaKit: JustAudioMediaKit.isRegistered,
          ));

  /// The station is gone or stayed unreachable: stop it, restore the previous
  /// queue paused, and tell the user once, since only they can pick another.
  void _stopUnavailableRadio() {
    AppLogger.startup(
      StartupEvent.radioRecovery,
      outcome: StartupOutcome.unavailable,
    );
    // Tear down radio state synchronously so that no further metadata
    // callbacks (Azuracast polling / ICY subscription) fire while the
    // lane is busy cleaning up the player. This also lets the UI reflect
    // the stopped state immediately rather than waiting for lane turn.
    _radioStation = null;
    _pendingRadioRecovery = null;
    _networkRetryTimer?.cancel();
    _radioMetadataService.stop();
    _broadcastPlaybackState();
    _emitSnapshot();
    _radioStreamErrorController.add(null);
    // Schedule player cleanup and queue restore on the lane.
    unawaited(
      _queueLane.run((_) async {
        await _player.stop();
        await _player.setAudioSources(const <AudioSource>[]);
        queue.add(const <MediaItem>[]);
        _setCurrentMediaItem(null);
        _broadcastPlaybackState();
        _emitSnapshot();
      }),
    );
    unawaited(
      _queueLane.run((token) async {
        await _restorePreviousQueueAfterRadio(
          token,
          context: 'radio stream error',
        );
      }),
    );
  }

  Future<void> _recoverRadioAfterNetworkFailure() async {
    final pending = _pendingRadioRecovery;
    if (pending == null || _radioRecoveryInProgress || _disposeHandlerStarted)
      return;
    _radioRecoveryInProgress = true;
    bool current() =>
        !_disposeHandlerStarted &&
        _isCurrentTransportIntent(pending.generation) &&
        identical(_radioStation, pending.station);
    try {
      // Stations are third-party hosts: they need a connection, not the
      // Navidrome server.
      if (!((await reconcileNetwork?.call())?.connected ?? true)) return;
      if (!current()) return;
      await _queueLane.run((token) async {
        if (!current()) return;
        final station = pending.station;
        final generation = _loadGeneration;
        await _runTimedPlayerOperation(
          generation: generation,
          operation: 'radio recovery stop',
          action: _player.stop,
          timeout: _playerResetTimeout,
        );
        if (!current()) return;
        final item = _mediaItemForRadioStation(station);
        await _runTimedPlayerOperation(
          generation: generation,
          operation: 'radio recovery source',
          action: () => _player.setAudioSource(
            AudioSource.uri(Uri.parse(station.streamUrl), tag: item),
          ),
          timeout: _playerLoadTimeout,
        );
        if (!current()) return;
        _pendingRadioRecovery = null;
        _networkRetryTimer?.cancel();
        _networkRetries = 0;
        queue.add([item]);
        _setCurrentMediaItem(item);
        final azura = NavisAudioHandler._tryExtractAzuracast(station.streamUrl);
        _radioMetadataService.startListening(
          stationId: station.stationId,
          azuracastApiUrl: azura?.$1,
          stationShortName: azura?.$2,
        );
        if (_latestExplicitTransportPlaying != false)
          unawaited(_playWithFocusRecovery());
        AppLogger.startup(
          StartupEvent.radioRecovery,
          outcome: StartupOutcome.success,
        );
        _broadcastPlaybackState();
        _emitSnapshot();
      });
    } on Object {
      AppLogger.startup(
        StartupEvent.radioRecovery,
        outcome: StartupOutcome.failure,
      );
    } finally {
      _radioRecoveryInProgress = false;
      // Pause then Play may replace the request while reconciliation awaits.
      // Re-arm that current request even when this attempt was superseded.
      final latest = _pendingRadioRecovery;
      if (!_disposeHandlerStarted &&
          latest != null &&
          _isCurrentTransportIntent(latest.generation) &&
          identical(_radioStation, latest.station)) {
        if (DateTime.now().difference(latest.since) >=
            _timeouts.radioRecovery) {
          _stopUnavailableRadio();
        } else {
          _scheduleNetworkPlaybackRetry();
        }
      }
    }
  }

  RadioMetadataService _newRadioMetadataService() => RadioMetadataService(
    handler: this,
    player: _player,
    dio: _createRadioMetadataDio?.call(),
    isAllowed: _readRadioMetadataAllowed,
  );

  /// Starts an Instant Mix seeded from the current song or local library.
  Future<bool> _playInstantMixFromCurrentSong() async {
    final current = _currentMediaItem;
    // Android Auto may start before a media item or the Flutter shell exists.
    final seedId = current?.id ?? await _coldStartMixSeed();
    if (seedId == null) return false;

    if (current != null) {
      try {
        await _preferredMixToggleCallback(seedId);
        return true;
      } on Object catch (e, st) {
        AppLogger.warning('Instant Mix (toggle) failed for $seedId: $e\n$st');
      }
    }

    try {
      await _preferredMixCallback(seedId);
      return true;
    } on Object catch (e, st) {
      AppLogger.warning(
        'Instant Mix (preferred mode) failed for $seedId: $e\n$st',
      );
      return false;
    }
  }

  Future<String?> _coldStartMixSeed() async {
    final liked = await _libraryDao.watchAllStarredSongs().first;
    if (liked.isNotEmpty) return liked.first.id;
    final first = await _libraryDao.getSongsSorted(
      SongSortOrder.newest,
      limit: 1,
    );
    return first.isEmpty ? null : first.first.id;
  }

  Future<bool> _startInstantRadio({
    required bool autoPlay,
    bool Function()? isCurrent,
  }) => _startPersonalRadio(autoPlay, isCurrent: isCurrent);

  Future<void> _restorePreviousQueueAfterRadio(
    OperationToken token, {
    required String context,
  }) async {
    if (_queueItems.isNotEmpty || _radioStation != null) return;
    try {
      await _restoreSavedQueue(token: token);
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Queue restore after $context failed: $error\n$stackTrace',
      );
    }
  }
}
