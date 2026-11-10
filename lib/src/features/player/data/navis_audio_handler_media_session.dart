part of 'navis_audio_handler.dart';

extension _NavisMediaSession on NavisAudioHandler {
  void _setCurrentMediaItem(MediaItem? item) {
    _currentMediaItem = item;
    // A natural advance or queue edit replaced the song awaiting recovery.
    if (_pendingRemoteRecovery?.songId != item?.id) {
      _pendingRemoteRecovery = null;
    }
    final nextSongId = _radioStation == null ? item?.id : null;
    _completedCacheSongIds.removeWhere((id) => id != item?.id);
    if (_cachedExtent?.songId != item?.id) {
      _cachedExtent = null;
      _cancelCachedExtentTimer();
    }
    if (_playerRangeStart?.songId != item?.id) _playerRangeStart = null;
    // Re-learn a sidecar that finished while its song was not current: the
    // set is the only per-event source for the buffered line.
    if (item != null && _completedSidecarAvailable(item.id)) {
      _completedCacheSongIds.add(item.id);
    }
    if (_bufferState.songId != nextSongId) {
      _playerBufferedPosition = Duration.zero;
      _emitBufferState(
        songId: nextSongId,
        bufferedPosition: Duration.zero,
        force: true,
      );
    }
    _refreshBufferState(nextSongId);
    mediaItem.add(item);
    if (item != null && _artCache != null) {
      unawaited(_updateArtCacheFile(item));
    }
    _syncSidecarRollingCache(item);
    _cancelStaleLockCacheDownloads(item?.id);
    _syncLockCacheDownloadPriority();
  }

  /// Downloads the cover art for [trigger] to a local file and re-emits the
  /// current [MediaItem] with `artCacheFile` injected into
  /// [MediaItem.extras].
  ///
  /// ## Why extras, not artUri
  ///
  /// The app keeps the HTTP [MediaItem.artUri]. The system never sees it:
  /// on Android, [RealTimeProjectionAudioHandler] publishes a
  /// `content://<package>.artwork/cover/<key>` URI served by
  /// `NavisArtworkProvider` from this same cache file (Android Auto runs in
  /// a separate process and cannot read a plain `file://` path), and the
  /// Linux MPRIS and Windows SMTC bridges publish the file itself. Until this
  /// re-emit, an uncached cover is published without art (see
  /// [AndroidSystemArt]), so the system sees a change from no art to art. The
  /// Subsonic cover URL carries the account token, so it must not leave the
  /// app.
  ///
  /// * Java's `AudioService.setMetadata` reads `extras["artCacheFile"]`,
  ///   decodes the local JPEG with `BitmapFactory.decodeFile`, and stores the
  ///   result in `METADATA_KEY_ALBUM_ART` + `METADATA_KEY_DISPLAY_ICON` →
  ///   immediate bitmap display without a network round-trip.
  ///
  /// ## Cancellation safety
  ///
  /// `audio_service`'s `artFetchOperationId` mechanism cancels the previous
  /// HTTP-download listener when a new [MediaItem] is emitted.  Because we
  /// emit the updated item (with `artCacheFile` already in extras) *after* the
  /// download completes, the new listener sees the complete extras map and
  /// passes it straight to `_platform.setMediaItem` — the "show without art"
  /// intermediate call in audio_service's HTTP path still includes
  /// `artCacheFile`, so Java always has the bitmap.
  ///
  /// ## Queue persistence
  ///
  /// This method also updates [_queueItems] so that future `currentIndexStream`
  /// events (e.g. from Phase-2 insertions) deliver the art-cached version to
  /// `_setCurrentMediaItem`, preventing the art from reverting to blank.
  Future<void> _updateArtCacheFile(MediaItem trigger) async {
    final coverArtId = trigger.extras?['coverArtId'] as String?;
    final artUri = trigger.artUri;
    // Nothing to do if essential fields are missing.
    if (coverArtId == null || artUri == null) return;
    // Skip non-HTTP schemes (file://, content://, etc. — already handled).
    if (artUri.scheme != 'http' && artUri.scheme != 'https') return;
    // artCacheFile is already injected and still on disk — no need to
    // download again. A path whose file is gone (Android may clear the cache
    // directory) is fetched again and the item re-emitted, even though the
    // path string stays the same.
    final staleFile = trigger.extras?['artCacheFile'] as String?;
    if (staleFile != null && PlaybackArtCache.isImageFile(staleFile)) return;

    AppLogger.debug(
      '_updateArtCacheFile: requesting art cache for '
      'coverArtId=$coverArtId uri=${artUri.scheme}://${artUri.host}${artUri.path}',
    );
    final localPath = await _artCache!.getOrFetch(coverArtId, artUri);
    AppLogger.debug('_updateArtCacheFile: result for $coverArtId → $localPath');
    if (localPath == null) return;

    // Inject artCacheFile into a copy of [item]'s extras, preserving all
    // existing extras (coverArtId, albumId, replay-gain values, etc.).
    MediaItem withArtCache(MediaItem item) => item.copyWith(
      extras: <String, Object?>{...?item.extras, 'artCacheFile': localPath},
    );

    // Update every occurrence of this song in the queue so that future
    // currentIndexStream events deliver the art-cached version.
    for (var i = 0; i < _queueItems.length; i++) {
      if (_queueItems[i].id == trigger.id &&
          _needsArtFile(_queueItems[i], staleFile)) {
        _queueItems.replaceAt(i, withArtCache(_queueItems[i]));
      }
    }

    // Guard: only re-emit if we are still on the same track.
    final current = _currentMediaItem;
    if (current == null || current.id != trigger.id) return;
    // Guard: skip if a concurrent call already injected artCacheFile.
    if (!_needsArtFile(current, staleFile)) return;

    // Re-emit the current item with artCacheFile in extras.
    // audio_service's HTTP-path listener will call
    // `_platform.setMediaItem(item._toMessage())` which serialises the full
    // extras map — Java's AudioService.setMetadata reads artCacheFile from
    // there, decodes the bitmap, and populates METADATA_KEY_ALBUM_ART so
    // that AAOS displays the art on the now-playing screen.
    final updated = withArtCache(current);
    _currentMediaItem = updated;
    mediaItem.add(updated);
  }

  /// Whether [item] still needs `artCacheFile` injected: it has none, its
  /// file is gone or not an image, or it names [staleFile], which was just
  /// downloaded again and must be republished.
  static bool _needsArtFile(MediaItem item, String? staleFile) {
    final file = item.extras?['artCacheFile'] as String?;
    return file == null ||
        file == staleFile ||
        !PlaybackArtCache.isImageFile(file);
  }

  void _wireAudioSession(AudioSession session) {
    _audioSession = session;
    _interruptionSubscription = session.interruptionEventStream.listen((event) {
      if (event.begin) {
        if (event.type == AudioInterruptionType.duck) {
          if (!_isDucked) {
            _isDucked = true;
            unawaited(setVolume(_userVolume));
          }
          return;
        }
        _audioInterrupted = event.type == AudioInterruptionType.pause;
        _interruptedTransportGeneration = _player.playing
            ? _transportGeneration
            : null;
        _cancelCrossfade();
        unawaited(_player.pause());
        return;
      }

      if (event.type == AudioInterruptionType.duck) {
        if (_isDucked) {
          _isDucked = false;
          unawaited(setVolume(_userVolume));
        }
        return;
      }

      _audioInterrupted = false;
      final shouldResume =
          (_interruptedTransportGeneration == _transportGeneration ||
              _focusDeniedGeneration == _transportGeneration) &&
          !_player.playing;
      _interruptedTransportGeneration = null;
      if (shouldResume) {
        // An earlier denial's budget does not cover this resume.
        _focusDeniedSince = null;
        _focusRetries = 0;
        unawaited(_playWithFocusRecovery());
      }
    });

    _becomingNoisySubscription = session.becomingNoisyEventStream.listen((_) {
      _cancelCrossfade();
      if (_player.playing || _focusDeniedGeneration != null) {
        unawaited(pause());
      }
    });
  }

  void _wirePlayerListeners() {
    final wiredPlayer = _player;
    _queueFinished = false;
    _finishObservedProcessingState = null;
    _playerBufferedPosition = Duration.zero;
    _emitBufferState(
      songId: _radioStation == null ? _currentMediaItem?.id : null,
      bufferedPosition: Duration.zero,
      force: true,
    );
    ({int? code, String? message, int? index})? lastNativeFailure;
    void fail(Object error, StackTrace stackTrace) {
      if (!identical(_player, wiredPlayer)) return;
      AppLogger.error(
        'Playback event stream error.',
        error.runtimeType,
        stackTrace,
      );
      // Network failures retain the station and its requested playback.
      if (_radioStation != null && _isTransientRadioFailure(error)) {
        final station = _radioStation!;
        final previous = _pendingRadioRecovery;
        _pendingRadioRecovery = (
          generation: _transportGeneration,
          station: station,
          // A repeated failure during one outage keeps its recovery budget.
          since: _radioOutageStart(station, previous),
        );
        _radioMetadataService.stop();
        AppLogger.startup(
          StartupEvent.radioRecovery,
          outcome: StartupOutcome.offline,
        );
        _scheduleNetworkPlaybackRetry();
        unawaited(_recoverRadioAfterNetworkFailure());
      } else if (_radioStation != null) {
        unawaited(_stopUnavailableRadio());
      } else {
        _loadedSourceFailed = true;
        unawaited(
          _recoverCurrentSongFromRemotePlaybackFailure(
            reason: 'playback event stream error',
            error: error,
            stackTrace: stackTrace,
          ),
        );
      }
    }

    _playbackEventSubscription = _player.playbackEventStream.listen((event) {
      if (!identical(_player, wiredPlayer)) return;
      _captureTranscodeEndOccurrence();
      _recordAnomalyPlaybackEvent(event);
      if (_transportTrace.enabled) {
        final traced = (
          state: _player.processingState,
          playing: _player.playing,
          index: _player.currentIndex,
        );
        if (traced != _tracedPlayerState || event.errorCode != null) {
          _tracedPlayerState = traced;
          _transportTrace.record(
            'playerState',
            () => <String, Object?>{
              'processingState': traced.state.name,
              'playing': traced.playing,
              'index': traced.index,
              'positionMs': _player.position.inMilliseconds,
              'bufferedMs': _player.bufferedPosition.inMilliseconds,
              if (event.errorCode != null) 'errorCode': event.errorCode,
            },
          );
        }
      }
      if (_player.playing) _onPlayerPlaying();
      // just_audio 0.10 reports native failures as event data. Repeated idle
      // events carry the same error; admit that failure only once.
      final failure = (
        code: event.errorCode,
        message: event.errorMessage,
        index: event.currentIndex,
      );
      if (failure.code != null && failure != lastNativeFailure) {
        lastNativeFailure = failure;
        fail(
          PlayerException(failure.code!, failure.message, failure.index),
          StackTrace.current,
        );
      } else if (failure.code == null) {
        lastNativeFailure = null;
        // Loading or playing again without an error: the failure is over.
        if (event.processingState != ProcessingState.idle) {
          _loadedSourceFailed = false;
        }
      }
      // Native playlist edits can emit before the Dart mirror commits.
      if (!_queueLane.isIdle &&
          _queueReplacementMetadataAnchor == null &&
          !_sequenceMatchesQueue(_player)) {
        if (_player.processingState == ProcessingState.completed &&
            _prematureTranscodeDeparture == null) {
          _retryPrematureTranscodeEnd(event);
        }
        return;
      }
      _syncBridgeDownloadPriority();
      final processing = _player.processingState;
      final index = _player.currentIndex;
      if (processing == ProcessingState.completed) {
        _continueIntoDeferredTail();
      } else {
        _endedSeekEcho = null;
      }
      if (navisQueueJustFinished(
        previous: _finishObservedProcessingState,
        current: processing,
        continuingPastCompletion: _continuingIntoDeferredTail,
        position: _restoredQueueIndex != null
            ? _restoredQueuePosition
            : _player.position,
        duration: _player.duration,
      )) {
        _queueFinished = true;
      } else if (processing != ProcessingState.completed) {
        _queueFinished = false;
      }
      _finishObservedProcessingState = processing;
      if (processing != _eqObservedProcessingState ||
          index != _eqObservedIndex) {
        _eqObservedProcessingState = processing;
        _eqObservedIndex = index;
        if (processing == ProcessingState.ready &&
            equalizerCapabilities.supported) {
          unawaited(
            refreshEqualizerState().catchError((
              Object error,
              StackTrace trace,
            ) {
              AppLogger.warning('EQ status refresh failed: $error\n$trace');
            }),
          );
        }
      }
      _handleScrobbleSignals();
      _broadcastPlaybackState();
      _emitSnapshot();
      _syncRemotePlaybackStallWatchdog();
    }, onError: fail);

    _positionDiscontinuitySubscription = _player.positionDiscontinuityStream
        .listen((discontinuity) {
          if (!identical(_player, wiredPlayer)) return;
          _recordAnomalyDiscontinuity(discontinuity);
          _onPositionDiscontinuity(discontinuity);
        });

    _currentIndexSubscription = _player.currentIndexStream.listen((
      index,
    ) async {
      // Let a same-turn discontinuity claim a cut before publishing its successor.
      if (_isDesktopRuntime) await Future<void>.value();
      if (_prematureTranscodeDeparture != null ||
          !identical(_player, wiredPlayer) ||
          index != wiredPlayer.currentIndex) {
        return;
      }
      // The display stays on the outgoing song (see [_resolveCurrentQueueMetadata]):
      // hand over to the incoming deck now, and let a failed hand-over replay
      // this event.
      if (_outgoingAdvancedMidFade) {
        _crossfadeIndexSuppressed = true;
        _jumpToIncomingVolume();
        unawaited(_completeCrossfade());
        return;
      }
      _anomalies.index(index);
      if (_transportTrace.enabled) {
        final nativeSongId = index == null || index >= _player.sequence.length
            ? null
            : navisNativeSourceSongId(_player.sequence[index]);
        if (_tracedNativeIndex != (index, nativeSongId)) {
          _tracedNativeIndex = (index, nativeSongId);
          _transportTrace.record(
            'nativeIndex',
            () => <String, Object?>{
              'index': index,
              'songId': nativeSongId,
              'loading': _isLoading,
              'positionMs': _player.position.inMilliseconds,
            },
          );
        }
      }

      // Stop may deliver old playlist indices during remote warm-up. Native
      // edits also emit indices before their materialised mirror commits.
      final pendingAnchor = _queueReplacementMetadataAnchor;
      if ((_isLoading &&
              (_player.processingState == ProcessingState.idle ||
                  (pendingAnchor != null &&
                      (pendingAnchor.mediaItem.extras?['sourceKind'] == null ||
                          _queueItems
                                  .elementAtOrNull(index ?? _queueItems.length)
                                  ?.id !=
                              _loadingSongId)))) ||
          (!_queueLane.isIdle &&
              _queueReplacementMetadataAnchor == null &&
              !_sequenceMatchesQueue(_player))) {
        _captureTranscodeEndOccurrence(indexEvent: true);
        return;
      }
      final resolved = _resolveCurrentQueueMetadata();
      final item = resolved.mediaItem;
      final pendingSeek = _pendingSeek;
      if (pendingSeek != null &&
          !_isLoading &&
          _queueLane.isIdle &&
          (item?.id != pendingSeek.songId ||
              _logicalIndexOf(resolved.currentIndex) !=
                  pendingSeek.queueIndex)) {
        _seekLane.cancelCurrent();
        _cancelPendingSeek();
      }
      final failedFade = _crossfadeFailedFrom;
      if (failedFade != null &&
          (failedFade.index != resolved.currentIndex ||
              failedFade.songId != item?.id)) {
        // Another entry plays: its transition, and this one's next time,
        // may be prepared again.
        _crossfadeFailedFrom = null;
        _crossfadeDisabledReason = null;
      }
      if (_isLoading && _queueReplacementMetadataAnchor == null) {
        _loadingSongId = item?.id;
      }
      if (item != null) {
        if (_transportTrace.enabled &&
            _tracedCurrentSong != (item.id, resolved.currentIndex)) {
          _tracedCurrentSong = (item.id, resolved.currentIndex);
          _transportTrace.record(
            'songCurrent',
            () => <String, Object?>{
              'songId': item.id,
              'index': resolved.currentIndex,
              'positionMs': _player.position.inMilliseconds,
            },
          );
        }
        _setCurrentMediaItem(item);
      } else if (_queueItems.isEmpty ||
          _player.processingState == ProcessingState.idle) {
        // Clear only when playback has no active queue/source. Keep the last
        // known item during transient index gaps so UI metadata stays stable.
        _setCurrentMediaItem(null);
      }
      _captureTranscodeEndOccurrence(indexEvent: true);
      _updateScrobbleSession(item, currentIndex: resolved.currentIndex);
      _applyReplayGainVolume();
      _broadcastPlaybackState();
      _emitSnapshot();
      _scheduleTransportPersistence(context: 'current index update');
      _maybeReleaseTail();
    });

    // just_audio derives these from sequenceStateStream without distinct(),
    // so every queue insert re-emits them. Without distinct() a large queue
    // fill queued two full queue-state writes per batch and delayed the final
    // queue persistence by tens of seconds.
    _shuffleModeSubscription = _player.shuffleModeEnabledStream
        .distinct()
        .listen((_) {
          if (!identical(_player, wiredPlayer)) return;
          _repushReplayGainLevels();
          _broadcastPlaybackState();
          unawaited(
            _persistSafely(
              () => _persistQueueState(includePosition: false),
              context: 'shuffle mode stream update',
            ),
          );
        });

    _loopModeSubscription = _player.loopModeStream.distinct().listen((_) {
      if (!identical(_player, wiredPlayer)) return;
      _repushReplayGainLevels();
      _broadcastPlaybackState();
      unawaited(
        _persistSafely(
          () => _persistQueueState(includePosition: false),
          context: 'loop mode stream update',
        ),
      );
    });

    _activePositionSubscription = _player
        .createPositionStream(
          minPeriod: const Duration(milliseconds: 100),
          maxPeriod: const Duration(milliseconds: 200),
        )
        .listen((position) {
          if (!identical(_player, wiredPlayer)) return;
          if (!_positionController.isClosed) {
            // The outgoing deck now plays the next song from ~0 mid-hand-over.
            // A premature-EOF reload does the same for ~40 ms: hold the cut
            // target until the reload is ready (same release point as the
            // play-hold). With no pending seek yet, skipping an emit is a
            // microtask gap (#210).
            final departure = _prematureTranscodeDeparture;
            final holding = departure != null && !departure.sourceReady;
            final held = holding && _pendingSeek?.songId == departure.item.id
                ? _pendingSeek?.position
                : null;
            if (!holding || held != null) {
              _positionController.add(
                held ??
                    (_outgoingAdvancedMidFade ? _transportPosition : position),
              );
              _lastPositionEmitAt = DateTime.now();
            }
          }
          _captureTranscodeEndOccurrence();
          _observePlaybackAdvance();
          _observeAnomalyPosition(position);
          // Paused edits may wait longer than the controller's bounded refresh
          // window. Observe their first processed block when playback resumes.
          if (equalizerCapabilities.supported &&
              equalizerState.pending &&
              _player.playing &&
              !_eqRefreshInFlight) {
            _eqRefreshInFlight = true;
            unawaited(
              refreshEqualizerState()
                  .catchError((Object error) {
                    _emitEqualizerState(
                      const EqualizerStateMessage(
                        enabled: false,
                        reason: 'EQ status could not be verified. Review playback settings.',
                      ),
                    );
                  })
                  .whenComplete(() => _eqRefreshInFlight = false),
            );
          }
          final startupTrace = _activeStartupTrace;
          if (startupTrace != null &&
              startupTrace.sourceApplied &&
              _player.playing &&
              _player.processingState == ProcessingState.ready &&
              _resolveCurrentQueueMetadata().mediaItem?.id ==
                  startupTrace.songId) {
            startupTrace.observePosition(position);
          }
        });

    _bufferedPositionSubscription = _player.bufferedPositionStream.listen((
      bufferedPosition,
    ) {
      if (!identical(_player, wiredPlayer)) return;
      _playerBufferedPosition = bufferedPosition;
      _syncLockCacheDownloadPriority();
      _refreshBufferState(_currentBufferSongId);
    });

    // Position monitoring for cross-fade triggering.
    _crossfadePositionSub = _player
        .createPositionStream(
          minPeriod: const Duration(milliseconds: 250),
          maxPeriod: const Duration(milliseconds: 500),
        )
        .listen((position) {
          if (!identical(_player, wiredPlayer)) return;
          _syncLockCacheDownloadPriority();
          _syncSidecarChain();
          _checkCrossfadeTrigger(position);
        });
  }

  /// The song id the seek bar buffered line tracks: the current queue song,
  /// or null while a radio station plays.
  String? get _currentBufferSongId => _radioStation == null
      ? _resolveCurrentQueueMetadata().mediaItem?.id
      : null;

  /// Draws the seek bar lines for [songId]: the range playable from the start
  /// (the further of the player's buffered position and what the rolling cache
  /// holds locally) and, after a seek past it, the player's own range ahead.
  ///
  /// [probe] is false for the refresh that follows a probe's own result, which
  /// must not start the next probe (the trailing timer does that).
  void _refreshBufferState(String? songId, {bool probe = true}) {
    var buffered = Duration.zero;
    Duration? aheadStart;
    Duration? aheadEnd;
    if (songId != null) {
      if (probe) _probeCachedExtent(songId);
      final raw = _playerBufferedPosition;
      final cached =
          _cachedPlayablePosition(
            songId,
            _effectivePlaybackDuration(_currentMediaItem),
          ) ??
          Duration.zero;
      final start = _playerRangeStartOf(songId);
      if (start <= cached + const Duration(seconds: 2) || raw <= cached) {
        buffered = raw > cached ? raw : cached;
      } else {
        buffered = cached;
        if (raw > start) {
          aheadStart = start;
          aheadEnd = raw;
        }
      }
    }
    _emitBufferState(
      songId: songId,
      bufferedPosition: buffered,
      aheadStart: aheadStart,
      aheadEnd: aheadEnd,
    );
  }

  /// Forgets the last seek target, so the player's range is no longer drawn
  /// apart (the seek failed, was cancelled, or a loop began a new occurrence).
  void _dropPlayerRangeStart() {
    if (_playerRangeStart == null) return;
    _playerRangeStart = null;
    _refreshBufferState(_currentBufferSongId);
  }

  /// Where the player's buffered range begins: the offset of an offset stream,
  /// else the target of the last seek in this queue occurrence, else 0.
  Duration _playerRangeStartOf(String songId) {
    final offset = _positionOffsetOf(_currentMediaItem);
    if (offset > Duration.zero) return offset;
    final seek = _playerRangeStart;
    return seek != null && seek.songId == songId
        ? seek.position
        : Duration.zero;
  }

  void _emitBufferState({
    required String? songId,
    required Duration bufferedPosition,
    Duration? aheadStart,
    Duration? aheadEnd,
    bool force = false,
  }) {
    final safeBufferedPosition = bufferedPosition < Duration.zero
        ? Duration.zero
        : bufferedPosition;
    final next = PlaybackBufferState(
      songId: songId,
      bufferedPosition: safeBufferedPosition,
      aheadStart: aheadStart,
      aheadEnd: aheadEnd,
    );
    if (!force && _bufferState == next) return;
    _bufferState = next;
    if (!_bufferStateController.isClosed) {
      _bufferStateController.add(next);
    }
  }

  // ── ReplayGain ──────────────────────────────────────────────────────────

  /// Apply ReplayGain volume normalization for the current track.
  ///
  /// Scales the user volume by the song's ReplayGain level (see
  /// [_replayGainVolumeFor]). When the mode is 'off' (or while radio plays),
  /// restores to _userVolume.
  void _applyReplayGainVolume({
    bool forceDuringCrossfade = false,
    bool live = false,
  }) {
    final loading = _isLoading || _pendingLogicalQueueSongIds != null;
    if (loading || (_isCrossfading && !forceDuringCrossfade)) {
      // A settings change held back by a load or a fade still has to reach
      // the playing song, so the next write that goes through sends it live.
      _replayGainLivePending |= live;
      // Once the selected source is in the player the new song is the
      // audible one, so its cut must not wait for phase 2 (before that the
      // old song may still play and keeps its own level). A fade owns the
      // volume while it runs.
      if (loading && _loadingSourceInPlayer && !_isCrossfading) {
        unawaited(
          _player.setVolume(
            _replayGainVolumeFor(_resolveCurrentQueueMetadata().mediaItem),
          ),
        );
      }
      return;
    }
    live |= _replayGainLivePending;
    _replayGainLivePending = false;
    final current = _resolveCurrentQueueMetadata().mediaItem;
    // A song start (or a hand-over) forgets the Smart decisions of every
    // song that is neither playing nor fading in.
    final incoming = _queueItems
        .elementAtOrNull(_crossfadeTargetIndex ?? _queueItems.length)
        ?.id;
    _smartNeighbours.removeWhere(
      (id, _) => id != current?.id && id != incoming,
    );
    final queued = {for (final item in _queueItems) item.id};
    _pushedSmartNeighbours.removeWhere((id, _) => !queued.contains(id));
    // In the pipeline the song's start adopts the Smart pair last pushed to
    // native, which is the only place the level is applied.
    if (replayGainInPipeline) _replayGainDecisionFor(current);
    unawaited(_player.setVolume(_replayGainVolumeFor(current)));
    _applyReplayGainBoost(live: live);
  }

  /// Whether the player is mpv through media_kit (Linux, Windows and macOS).
  /// Tests inject the backend through the adjustment capabilities instead.
  bool get _usesMpv => _adjustmentCapabilities != null
      ? _adjustmentCapabilities == PlaybackAdjustmentCapabilities.mediaKit
      : JustAudioMediaKit.isRegistered;

  /// Whether the player is Android's ExoPlayer bridge (same injection rule).
  bool get _usesAndroidNative => _adjustmentCapabilities != null
      ? _adjustmentCapabilities == PlaybackAdjustmentCapabilities.android
      : _isAndroidRuntime;

  /// Whether the player is iOS's AVQueuePlayer with the equalizer's tap (same
  /// injection rule). Its boost is a gain stage in that tap, which gets the
  /// per-file map and owns the timing natively.
  bool get _usesIos => _adjustmentCapabilities != null
      ? _adjustmentCapabilities == PlaybackAdjustmentCapabilities.ios
      : _isIosRuntime;

  /// The player volume for [item]: the user volume (ducked or not) scaled by
  /// its ReplayGain cut, which only ever turns the song down. Turning a song
  /// up is the platform's boost stage ([_applyReplayGainBoost]), which a
  /// 0..1 volume cannot do.
  ///
  /// The player volume is linear (ExoPlayer, AVQueuePlayer), so the gain is
  /// `10^(dB/20)`. mpv never gets here: its cut rides the `@navis_rg` filter.
  /// Radio has no gain data and is left at the user volume.
  double _replayGainVolumeFor(MediaItem? item) {
    final base = _baseVolumeFor();
    // The backend applies the gain on the song's own samples: the player
    // volume stays user volume x ducking (x any cross-fade ramp).
    if (replayGainInPipeline) return base;
    final gainDb = _replayGainDecisionFor(
      item,
      playOrder: _loadingPlayOrder(item),
    )?.cutDb;
    if (gainDb == null) return base;
    return (math.pow(10, gainDb / 20).toDouble() * base).clamp(0.0, 1.0);
  }

  /// While a replacement loads, the incoming play order around its start
  /// song: [_queueItems] holds only the start song (and on iOS its successor)
  /// then, so Smart would read the wrong neighbours and step at the commit.
  /// Null for any other song, or when only ids are known (the restore fill,
  /// which is paused and so never audible before its commit).
  ({List<String?> albumIds, int index})? _loadingPlayOrder(MediaItem? item) {
    final songs = _pendingLogicalQueueSongs;
    final index = _navigationIntent.desiredIndex;
    if (songs == null || index == null || item == null) return null;
    if (songs.elementAtOrNull(index)?.id != item.id) return null;
    return (albumIds: [for (final song in songs) song.albumId], index: index);
  }

  /// The player volume without ReplayGain: the user volume, ducked or not.
  double _baseVolumeFor() => _isDucked ? _userVolume * 2 / 5 : _userVolume;

  /// The signed ReplayGain in dB native applies to [item] from its first
  /// sample, or null when it has none (radio). An update [push] records the
  /// Smart pair it used, which the song's start then freezes. A level sent
  /// with a source records it only for [playOrder] (see [_withReplayGain]):
  /// without one the queue may still be filling.
  double? _replayGainLevelFor(
    MediaItem item, {
    bool push = false,
    ({List<String?> albumIds, int index})? playOrder,
  }) {
    final decision = _replayGainDecisionFor(
      item,
      freeze: false,
      push: push,
      playOrder: playOrder,
    );
    if (decision == null && _radioStation != null) return null;
    return decision?.db ?? 0;
  }

  /// Gives [source] the ReplayGain of [item] before it is loaded or inserted,
  /// so the level arrives with the source message and the song's first samples
  /// play at it (a map pushed later is ignored by a player that is not
  /// active yet). Outside the pipeline it changes nothing.
  ///
  /// [playOrder] is the song list that will actually play, as album ids, and
  /// the source's position in it. A source that goes to a queue not yet in
  /// [_queueItems] (a replace, an insert, a released tail) passes it, so Smart
  /// reads the right neighbours and the song's start adopts the pair native
  /// holds. Without it the neighbours come from [_queueItems] and are not
  /// recorded.
  S _withReplayGain<S extends IndexedAudioSource>(
    S source,
    MediaItem? item, {
    ({List<String?> albumIds, int index})? playOrder,
  }) {
    if (replayGainInPipeline && item != null) {
      source.replayGainDb = _replayGainLevelFor(
        item,
        push: playOrder != null,
        playOrder: playOrder,
      );
    }
    return source;
  }

  /// Re-stamps [prepared], which will sit at [at] in [queue], with the levels
  /// that queue gives them. [queue] is the whole play order after the change.
  void _stampReplayGainFor(
    Iterable<_PreparedQueueItem> prepared,
    List<String?> queue, {
    required int at,
  }) {
    var index = at;
    for (final item in prepared) {
      final source = item.audioSource;
      if (source is IndexedAudioSource) {
        _withReplayGain(
          source,
          item.mediaItem,
          playOrder: (albumIds: queue, index: index),
        );
      }
      index++;
    }
  }

  /// Tells every deck how much each queued song is turned up.
  ///
  /// A backend without a boost stage ([replayGainBoostSupported] false and not
  /// [replayGainInPipeline]) gets nothing. Boost is derived from the same
  /// frozen decision as the cut, except for songs not playing yet, which read
  /// it without freezing.
  ///
  /// In the pipeline this is the update push of every queued song's level
  /// ([_pushReplayGainLevels]); [live] is set only by a settings change.
  void _applyReplayGainBoost({bool live = false}) {
    if (!replayGainBoostSupported && !replayGainInPipeline) return;
    unawaited(
      _applyToStableDecks((deck) => _sendReplayGainLevelsTo(deck, live: live))
          .catchError((Object error) {
            AppLogger.debug('ReplayGain boost could not be applied: $error');
          }),
    );
  }

  /// Sends one deck the boost of every song it holds. Only the deck that is
  /// heard freezes a Smart decision: the idle deck's current song may be
  /// stale, and a freeze there would outlive the prune at the next song start.
  Future<void> _sendReplayGainLevelsTo(
    AudioPlayer player, {
    bool live = false,
  }) async {
    if (replayGainInPipeline) return _pushReplayGainLevels(player, live: live);
    final current = player.currentIndex;
    final bySource = <IndexedAudioSource, double>{};
    final durationMsBySource = <IndexedAudioSource, int>{};
    final sequence = player.sequence;
    for (var i = 0; i < sequence.length; i++) {
      final item = _mediaItemOfSource(sequence[i]);
      if (item == null) continue;
      bySource[sequence[i]] =
          _replayGainDecisionFor(
            item,
            freeze: identical(player, _player) && i == current,
          )?.boostDb ??
          0;
      // The tag's duration times the iOS guard along with the player's own.
      final tagMs = item.duration?.inMilliseconds;
      if (tagMs != null && tagMs > 0) durationMsBySource[sequence[i]] = tagMs;
    }
    await player.setReplayGainBoost(
      currentDb: bySource[current == null ? null : sequence[current]] ?? 0,
      bySource: bySource,
      durationMsBySource: durationMsBySource,
    );
  }

  /// Updates one deck's in-pipeline level of every song it holds. Nothing
  /// freezes here: the heard song freezes at its start from the pair this push
  /// recorded, so native and the display agree.
  Future<void> _pushReplayGainLevels(
    AudioPlayer player, {
    required bool live,
  }) async {
    final bySource = <IndexedAudioSource, double>{};
    final heard = player.currentIndex;
    final sequence = player.sequence;
    // The main deck mirrors the queue, so each entry reads its own neighbours
    // there (a song queued twice is two entries), as its seed did. The heard
    // entry keeps its frozen pair.
    final albumIds =
        identical(player, _player) && sequence.length == _queueItems.length
        ? [for (final item in _queueItems) item.extras?['albumId'] as String?]
        : null;
    for (var i = 0; i < sequence.length; i++) {
      final source = sequence[i];
      final item = _mediaItemOfSource(source);
      // The deck and the queue can disagree for a moment around an edit: an
      // entry the queue does not name that way (song-id aliases count as the
      // same song) keeps the level it was loaded
      // with, and the next push (after the edit settles) sets it.
      if (albumIds != null &&
          (item == null ||
              _canonicalSongId(_queueItems[i].id) !=
                  _canonicalSongId(item.id))) {
        continue;
      }
      // A non-live push does not reach the heard entry (native froze it), so
      // it must not replace the pair that entry's level was built from.
      final push = live || i != heard;
      final db = item == null
          ? null
          : _replayGainLevelFor(
              item,
              push: push,
              playOrder: albumIds == null || i == heard
                  ? null
                  : (albumIds: albumIds, index: i),
            );
      if (db == null) continue;
      bySource[source] = db;
      // A reload re-sends these objects (navigation fallback), so the stamp
      // must follow the push. Native reads it only when it loads the source,
      // and the heard entry keeps its frozen stamp unless the push is live.
      if (push) source.replayGainDb = db;
    }
    await player.setReplayGainLevels(bySource: bySource, live: live);
  }

  /// The queue entry [source] plays. Rolling-cache sources on Android carry no
  /// tag, so they are found by the song id in their stream URL.
  MediaItem? _mediaItemOfSource(IndexedAudioSource source) {
    final tag = source.tag;
    final songId = tag is MediaItem ? tag.id : navisNativeSourceSongId(source);
    if (songId == null) return null;
    // The queue's copy first: a sync refreshes its ReplayGain
    // ([_refreshQueuedSongReplayGain]), while a tag is as old as its source.
    return _queueItems.where((item) => item.id == songId).firstOrNull ??
        (tag is MediaItem ? tag : null);
  }

  /// Pushes every queued level again after a loop or shuffle change, which
  /// moves the Smart wrap neighbours of the songs around the seam.
  void _repushReplayGainLevels() {
    if (replayGainInPipeline) _applyReplayGainBoost();
  }

  /// The in-pipeline ReplayGain stage as the status reports it (the key and
  /// gain native applies, clipped samples), or null without a processor.
  Map<String, Object?>? get _replayGainBoostStatus =>
      _usesAndroidNative && replayGainInPipeline
      ? <String, Object?>{
          'currentKey': equalizerState.replayGainCurrentKey,
          'appliedDb': equalizerState.replayGainAppliedDb,
          'clipSamples': equalizerState.boostClipSamples,
        }
      : _usesIos && replayGainBoostSupported
      // The iOS tap owns the guard, so what it reports is all there is.
      ? <String, Object?>{
          'requestedDb': equalizerState.boostRequestedDb,
          'appliedDb': equalizerState.boostAppliedDb,
          'guarded': equalizerState.boostGuarded,
          'clipSamples': equalizerState.boostClipSamples,
        }
      : null;

  /// What ReplayGain does to the current song, or null for radio. Read by
  /// diagnostics (`replayGain`) and the Now Playing page.
  ReplayGainDecision? get _currentReplayGainDecision => _replayGainDecisionFor(
    _resolveCurrentQueueMetadata().mediaItem,
    freeze: false,
  );

  /// The ReplayGain decision for [item], with Smart resolved from its
  /// neighbours in play order; null for radio. No item counts as untagged.
  /// A read that is not a song's own volume (diagnostics) passes `freeze:
  /// false`, so it never stores a decision the song start would not have.
  ReplayGainDecision? _replayGainDecisionFor(
    MediaItem? item, {
    bool freeze = true,
    bool push = false,
    ({List<String?> albumIds, int index})? playOrder,
  }) {
    if (_radioStation != null) return null;
    final runtime = _readRuntimeSettings();
    final extras = item?.extras;
    final neighbours = runtime.replayGainMode == 'smart' && item != null
        ? _smartNeighbourAlbums(
            item,
            freeze: freeze,
            push: push,
            playOrder: playOrder,
          )
        : null;
    return replayGainDecision(
      boostSupported: replayGainBoostSupported,
      mode: runtime.replayGainMode,
      albumId: extras?['albumId'] as String?,
      prevAlbumId: neighbours?.prev,
      nextAlbumId: neighbours?.next,
      trackGain: extras?['replayGainTrackGain'] as double?,
      albumGain: extras?['replayGainAlbumGain'] as double?,
      trackPeak: extras?['replayGainTrackPeak'] as double?,
      albumPeak: extras?['replayGainAlbumPeak'] as double?,
      preampDb: runtime.replayGainPreamp,
      untaggedDb: runtime.replayGainUntaggedDb,
    );
  }

  /// The album ids of the songs before and after [item] in play order, as
  /// Smart ReplayGain should see them.
  ///
  /// The materialised queue is the play order (Navis owns shuffle and never
  /// enables native shuffle), so the neighbours are its adjacent items. The
  /// released queue window keeps well more than one song on both sides of
  /// the current song materialised, so a deferred entry is never a neighbour
  /// of a song that is playing or fading in. With repeat-all and nothing
  /// deferred, play order wraps, so the last song's next is the first and the
  /// first's previous is the last (a lone song is not its own neighbour).
  ///
  /// The pair is frozen per song in [_smartNeighbours], so it is read once
  /// per song start, not on every volume write. An entry is dropped when
  /// another song starts (pruned in [_applyReplayGainVolume]), when the queue
  /// is replaced or cleared ([_clearDeferredTail]) and when the ReplayGain
  /// mode changes ([applyRuntimeSettings]). It is kept across
  /// ducking, cross-fade ramps, volume changes, shuffle toggles and queue
  /// edits, so the level never jumps mid-song. Every navigation, including a
  /// jump to another copy of the playing song, drops them
  /// ([_applyNavigationDecision]). While a queue load settles the neighbours
  /// may be incomplete, so nothing is frozen then.
  ///
  /// [playOrder] reads a list that is not [_queueItems] yet (see
  /// [_withReplayGain]); it ignores a frozen pair, which belongs to a song
  /// already playing.
  ({String? prev, String? next}) _smartNeighbourAlbums(
    MediaItem item, {
    required bool freeze,
    bool push = false,
    ({List<String?> albumIds, int index})? playOrder,
  }) {
    final frozen = playOrder == null ? _smartNeighbours[item.id] : null;
    if (frozen != null) return frozen;
    final length = playOrder?.albumIds.length ?? _queueItems.length;
    final index = playOrder?.index ?? _queueIndexOfSong(item);
    String? albumAt(int i) => i < 0
        ? null
        : playOrder != null
        ? playOrder.albumIds.elementAtOrNull(i)
        : _queueItems.elementAtOrNull(i)?.extras?['albumId'] as String?;
    final wraps =
        _desiredLoopMode == LoopMode.all &&
        length > 1 &&
        _deferredHead.isEmpty &&
        _deferredTail.isEmpty;
    final last = length - 1;
    var neighbours = (
      prev: albumAt(wraps && index == 0 ? last : index - 1),
      next: albumAt(wraps && index == last ? 0 : index + 1),
    );
    // In the pipeline native holds the pair last pushed (or sent with the
    // source): the song's start adopts it, so a queue edit between that push
    // and the start cannot make the display disagree with what plays.
    if (replayGainInPipeline && freeze) {
      neighbours = _pushedSmartNeighbours[item.id] ?? neighbours;
    }
    if (push) _pushedSmartNeighbours[item.id] = neighbours;
    if (freeze &&
        playOrder == null &&
        !_isLoading &&
        _pendingLogicalQueueSongIds == null &&
        index >= 0) {
      _smartNeighbours[item.id] = neighbours;
    }
    return neighbours;
  }

  /// Where [item] sits in the materialised queue: the cross-fade target or
  /// the current song when it is that song, else its first occurrence; -1
  /// when it is not queued.
  int _queueIndexOfSong(MediaItem item) {
    final target = _crossfadeTargetIndex;
    if (target != null && _queueItems.elementAtOrNull(target)?.id == item.id) {
      return target;
    }
    final current = _resolveCurrentQueueMetadata().currentIndex;
    if (current != null &&
        _queueItems.elementAtOrNull(current)?.id == item.id) {
      return current;
    }
    return _queueItems.indexWhere((queued) => queued.id == item.id);
  }

  EqualizerConfigurationMessage _equalizerMessage(EqConfiguration values) =>
      EqualizerConfigurationMessage(
        diagnostics: diagnosticsBuildEnabled,
        enabled: values.enabled,
        preampDb: values.preampDb,
        autoHeadroom: values.autoHeadroom,
        filters: values.filters
            .map(
              (filter) => EqualizerFilterMessage(
                type: filter.type.name,
                frequencyHz: filter.frequencyHz,
                gainDb: filter.gainDb,
                q: filter.q,
                enabled: filter.enabled,
              ),
            )
            .toList(),
      );

  void _emitEqualizerState(EqualizerStateMessage native) {
    if (_equalizerController.isClosed) return;
    _equalizerController.add(
      EqApplicationState(
        desired: _desiredEqualizer,
        applied: _desiredEqualizer.copyWith(enabled: native.enabled),
        sampleRate: native.sampleRate,
        responseSampleRate: native.responseSampleRate ?? native.sampleRate,
        headroomDb: native.headroomDb,
        reason: native.reason,
        pending: native.pending,
        replayGainCurrentKey: native.replayGainCurrentKey,
        replayGainAppliedDb: native.replayGainAppliedDb,
        boostRequestedDb: native.boostRequestedDb,
        boostAppliedDb: native.boostAppliedDb,
        boostClipSamples: native.boostClipSamples,
        boostGuarded: native.boostGuarded,
        processedFrames: native.processedFrames,
        levelDeltaDb: native.levelDeltaDb,
        resetCount: native.resetCount,
        tapPrepareCount: native.tapPrepareCount,
        flushCount: native.flushCount,
        transitionGapsMs: native.transitionGapsMs,
        pitchCents: native.pitchCents,
        pitchActive: native.pitchActive,
        pitchLatencyFrames: native.pitchLatencyFrames,
        pitchResetCount: native.pitchResetCount,
        pitchInputHz: native.pitchInputHz,
        pitchOutputHz: native.pitchOutputHz,
        pitchPullMismatches: native.pitchPullMismatches,
        pitchReason: native.pitchReason,
        formatStreams: native.formatStreams
            ?.map((stream) => stream.toJson())
            .toList(growable: false),
        unmatchedFrames: native.unmatchedFrames,
        overlapBlocks: native.overlapBlocks,
        livePipelines: native.livePipelines,
        prepareCalls: native.prepareCalls,
        unprepareCalls: native.unprepareCalls,
        clampedUnprepares: native.clampedUnprepares,
      ),
    );
  }

  Future<T> _applyToStableDecks<T>(
    Future<T> Function(AudioPlayer player) apply,
  ) async {
    while (true) {
      final active = _player;
      final inactive = _crossfadePlayer;
      final result = await apply(active);
      if (inactive != null) await apply(inactive);
      if (identical(active, _player) && identical(inactive, _crossfadePlayer)) {
        return result;
      }
    }
  }

  Future<void> _setEqualizer(EqConfiguration values) {
    final work = _equalizerLane.then((_) async {
      if (!values.isValid || !equalizerCapabilities.supported) {
        throw ArgumentError('Unsupported equalizer configuration');
      }
      final previous = _desiredEqualizer;
      final message = _equalizerMessage(values);
      try {
        final native = await _applyToStableDecks(
          (player) => player.setEqualizer(message),
        );
        _desiredEqualizer = values;
        _emitEqualizerState(native);
      } on Object {
        try {
          await _player.setEqualizer(_equalizerMessage(previous));
          await _crossfadePlayer?.setEqualizer(_equalizerMessage(previous));
        } on Object catch (rollbackError, stackTrace) {
          AppLogger.warning('EQ rollback failed: $rollbackError\n$stackTrace');
          _emitEqualizerState(
            const EqualizerStateMessage(
              enabled: false,
              reason: 'EQ could not be restored after an audio-engine error. Review playback settings.',
            ),
          );
        }
        rethrow;
      }
    });
    _equalizerLane = work.catchError((Object _) {});
    return work;
  }

  /// Every player write of speed and pitch goes through here. Radio always
  /// plays at 1x and original pitch; the saved song values stay in
  /// [_appliedAdjustments] and apply again once songs play.
  Future<void> _applyAdjustmentsToPlayer(
    AudioPlayer player,
    PlaybackAdjustments values,
  ) async {
    final effective = _radioStation != null
        ? const PlaybackAdjustments()
        : values;
    // Issued together so the desktop backend can apply both with one audio
    // filter rebuild; every failure is still observed.
    try {
      await Future.wait(<Future<void>>[
        player.setSpeed(effective.speed),
        if (playbackAdjustmentCapabilities.pitchSupported)
          player.setPitch(effective.pitchFactor),
      ]);
    } on PlatformException catch (error) {
      if (error.code == 'pitch_unavailable') _pitchUnavailable = true;
      rethrow;
    }
  }

  /// Re-applies the saved values after [_radioStation] changed. Runs on
  /// [_adjustmentLane] and reads [_appliedAdjustments] when it executes, so an
  /// overlapping speed change is never overwritten by a stale value. A failure
  /// must not abort radio start or the return to songs.
  Future<void> _syncPlayerAdjustments() async {
    final operation = _adjustmentLane.then(
      (_) => _applyToStableDecks(
        (player) => _applyAdjustmentsToPlayer(player, _appliedAdjustments),
      ),
    );
    _adjustmentLane = operation.catchError((Object _) {});
    try {
      await operation.timeout(_playerResetTimeout);
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Playback adjustment sync after a radio change failed: '
        '$error\n$stackTrace',
      );
    }
  }

  Future<void> _setPlaybackAdjustments(
    PlaybackAdjustments requested, {
    double? speed,
  }) {
    final operation = _adjustmentLane.then((_) async {
      final values = speed == null
          ? requested
          : _appliedAdjustments.copyWith(speed: speed);
      if (!playbackAdjustmentCapabilities.supports(values)) {
        throw ArgumentError('Unsupported speed/pitch adjustment');
      }
      final previous = _appliedAdjustments;
      try {
        await _applyToStableDecks(
          (player) => _applyAdjustmentsToPlayer(player, values),
        );
        _appliedAdjustments = values;
        if (!_adjustmentController.isClosed) _adjustmentController.add(values);
        _broadcastPlaybackState();
      } on Object {
        // A pair may fail halfway through, so restore both decks before
        // reporting failure to the shared controls.
        try {
          await _applyAdjustmentsToPlayer(_player, previous);
          final inactive = _crossfadePlayer;
          if (inactive != null) {
            await _applyAdjustmentsToPlayer(inactive, previous);
          }
        } on Object catch (error, stackTrace) {
          AppLogger.warning(
            'Playback adjustment rollback failed: $error\n$stackTrace',
          );
        }
        rethrow;
      }
    });
    _adjustmentLane = operation.catchError((Object _) {});
    return operation;
  }

  void _broadcastPlaybackState() {
    final resolved = _resolveCurrentQueueMetadata();
    final currentItem = resolved.mediaItem;
    final currentIndex = resolved.currentIndex;
    final nativeSource = _player.sequence.elementAtOrNull(
      _player.currentIndex ?? _player.sequence.length,
    );
    final pending =
        _isLoading &&
        _loadingSongId != null &&
        (currentItem?.extras?['sourceKind'] == null ||
            _player.processingState == ProcessingState.idle ||
            nativeSource == null ||
            navisNativeSourceSongId(nativeSource) != _loadingSongId);
    final processingState =
        _pendingRemoteRecovery != null ||
            _pendingRadioRecovery != null ||
            _prematureTranscodeDeparture != null
        ? AudioProcessingState.buffering
        : _restoredQueueIndex != null && !pending
        ? AudioProcessingState.ready
        : pending
        ? AudioProcessingState.loading
        : _mapProcessingState(_player.processingState);
    final effectiveDuration = _effectivePlaybackDuration(currentItem);
    final capabilities = navisOsControlCapabilities(
      queueLength: _radioStation == null ? _logicalQueueIds.length : 0,
      currentIndex: _radioStation == null
          ? _logicalIndexOf(currentIndex)
          : null,
      isRadioMode: _radioStation != null,
      duration: effectiveDuration,
      processingState: processingState,
      playing: _visiblePlaying,
    );
    final controls = navisNotificationControls(capabilities: capabilities);
    final state = playbackState.value.copyWith(
      controls: controls,
      systemActions: navisSystemActionsForCapabilities(capabilities),
      androidCompactActionIndices:
          navisNotificationCompactActionIndicesForControls(controls),
      processingState: processingState,
      playing: _visiblePlaying,
      updatePosition: _restoredQueueIndex != null
          ? _restoredQueuePosition
          : pending
          ? Duration.zero
          : _transportPosition,
      bufferedPosition: pending ? Duration.zero : _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _radioStation == null
          ? (_restoredQueueIndex ?? _player.currentIndex)
          : null,
      repeatMode: _mapRepeatMode(_desiredLoopMode),
      shuffleMode: _shuffleEnabled
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
    );
    playbackState.add(state);
  }

  AudioProcessingState _mapProcessingState(ProcessingState state) {
    return switch (state) {
      ProcessingState.idle => AudioProcessingState.idle,
      ProcessingState.loading => AudioProcessingState.loading,
      ProcessingState.buffering => AudioProcessingState.buffering,
      ProcessingState.ready => AudioProcessingState.ready,
      ProcessingState.completed => AudioProcessingState.completed,
    };
  }

  AudioServiceRepeatMode _mapRepeatMode(LoopMode mode) {
    return switch (mode) {
      LoopMode.off => AudioServiceRepeatMode.none,
      LoopMode.one => AudioServiceRepeatMode.one,
      LoopMode.all => AudioServiceRepeatMode.all,
    };
  }

  void _handleScrobbleSignals() {
    // Suppress scrobbling during radio playback.
    if (_radioStation != null || _prematureTranscodeDeparture != null) {
      return;
    }

    final resolved = _resolveCurrentQueueMetadata();
    final currentItem = resolved.mediaItem;
    final nativeSource = _player.sequence.elementAtOrNull(
      _player.currentIndex ?? _player.sequence.length,
    );
    if (_isLoading &&
        (_player.processingState == ProcessingState.idle ||
            nativeSource == null ||
            navisNativeSourceSongId(nativeSource) != currentItem?.id)) {
      return;
    }
    _updateScrobbleSession(currentItem, currentIndex: resolved.currentIndex);

    if (!_player.playing) {
      return;
    }

    final songId = _activeScrobbleSongId;
    final sessionKey = _activeScrobbleSessionKey;
    if (songId == null || sessionKey == null) {
      return;
    }

    if (!_sentNowPlayingScrobble) {
      _sentNowPlayingScrobble = true;
      unawaited(
        _scrobbleService.enqueueNowPlaying(
          songId: songId,
          sessionKey: sessionKey,
          track: _scrobblePayloadFor(currentItem),
        ),
      );

      // Record in local play history as soon as the track starts playing
      // so it appears in "Recently Played" without waiting for the full
      // scrobble submission threshold.
      unawaited(_recordPlayHistory(songId));
    }

    if (_sentSubmissionScrobble) {
      return;
    }

    final duration = _effectivePlaybackDuration(currentItem);
    final position = _player.position;
    final thresholdReached =
        _player.processingState == ProcessingState.completed ||
        _hasReachedSubmissionThreshold(duration: duration, position: position);

    if (!thresholdReached) {
      return;
    }

    _sentSubmissionScrobble = true;
    unawaited(
      _scrobbleService.enqueueSubmission(
        songId: songId,
        sessionKey: sessionKey,
        track: _scrobblePayloadFor(currentItem),
      ),
    );
  }

  ScrobbleTrackPayload? _scrobblePayloadFor(MediaItem? item) {
    if (item == null) {
      return null;
    }
    return ScrobbleTrackPayload(
      songId: item.id,
      title: item.title,
      artist: item.artist,
      album: item.album,
      duration: item.duration,
    );
  }

  Future<void> _recordPlayHistory(String songId) async {
    try {
      await _historyDao.addPlayHistory(songId);
    } on Object catch (error, stackTrace) {
      AppLogger.error('Failed to record play history', error, stackTrace);
    }
  }

  void _updateScrobbleSession(MediaItem? currentItem, {int? currentIndex}) {
    final departure = _prematureTranscodeDeparture;
    if (departure != null) {
      // A source reopen continues this occurrence, including its existing session.
      if (currentItem?.id == departure.item.id) {
        _activeScrobbleItem = currentItem;
        _activeScrobbleIndex = currentIndex;
      }
      return;
    }
    final songId = currentItem?.id;
    // The same play continues when only the queue around it changed (songs
    // inserted, released or moved before it shift its index; the queue entry
    // is the same object) or when its metadata was refreshed in place (for
    // example its liked state; the index is unchanged). Keying the session
    // on the index alone restarted it on every shift, recording duplicate
    // play history and scrobbles.
    if (songId != null &&
        songId == _activeScrobbleSongId &&
        (identical(currentItem, _activeScrobbleItem) ||
            currentIndex == _activeScrobbleIndex)) {
      _activeScrobbleItem = currentItem;
      _activeScrobbleIndex = currentIndex;
      return;
    }

    if (songId == null) {
      _activeScrobbleItem = null;
      _activeScrobbleIndex = null;
      _activeScrobbleSongId = null;
      _activeScrobbleSessionKey = null;
      _sentNowPlayingScrobble = false;
      _sentSubmissionScrobble = false;
      return;
    }

    _activeScrobbleItem = currentItem;
    _activeScrobbleIndex = currentIndex;
    _activeScrobbleSongId = songId;
    _activeScrobbleSessionKey =
        '${songId}_${DateTime.now().microsecondsSinceEpoch}';
    _sentNowPlayingScrobble = false;
    _sentSubmissionScrobble = false;
  }

  bool _hasReachedSubmissionThreshold({
    required Duration? duration,
    required Duration position,
  }) {
    if (duration == null || duration <= Duration.zero) {
      return false;
    }
    final halfDurationMs = duration.inMilliseconds ~/ 2;
    final thresholdMs = math.min(
      halfDurationMs,
      const Duration(minutes: 4).inMilliseconds,
    );
    return position.inMilliseconds >= thresholdMs;
  }

  void _emitSnapshot() {
    final resolved = _resolveCurrentQueueMetadata();
    final currentItem = resolved.mediaItem;
    // Native seek/playlist events may settle before their index subscription.
    // Publish media-session metadata from the same authority as this snapshot.
    if (_radioStation == null && _currentMediaItem?.id != currentItem?.id) {
      _setCurrentMediaItem(currentItem);
    }
    final isLiked = currentItem?.extras?['liked'] as bool? ?? false;
    final nextSnapshot = PlaybackSnapshot(
      queueSongIds: _radioStation != null ? const <String>[] : _logicalQueueIds,
      currentSongId: _radioStation != null ? null : currentItem?.id,
      currentIndex: _radioStation != null
          ? null
          : _logicalIndexOf(resolved.currentIndex),
      playing: _visiblePlaying,
      processingState:
          _pendingRemoteRecovery != null ||
              _pendingRadioRecovery != null ||
              _prematureTranscodeDeparture != null
          ? AudioProcessingState.buffering
          : _restoredQueueIndex != null && !_isLoading
          ? AudioProcessingState.ready
          : _mapProcessingState(_player.processingState),
      position: _restoredQueueIndex != null
          ? _restoredQueuePosition
          : _transportPosition,
      duration: _effectivePlaybackDuration(currentItem),
      bufferedPosition: _player.bufferedPosition,
      shuffleMode: _shuffleEnabled
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
      repeatMode: _mapRepeatMode(_desiredLoopMode),
      isCurrentSongLiked: _radioStation == null && isLiked,
      radioStation: _radioStation,
      isLoading: _isLoading,
      hasPendingLogicalQueue:
          _radioStation == null && _pendingLogicalQueueSongIds != null,
      pendingQueueIndex: _navigationIntent.isPending
          ? _navigationIntent.desiredIndex
          : null,
      pendingSeekPosition: _pendingSeek?.position,
      loadingSongId: _loadingSongId,
      lastFailedSongId: _lastFailedSongId,
    );
    final shouldBroadcast = !navisPlaybackSnapshotsStructurallyEqual(
      _snapshot,
      nextSnapshot,
    );
    if (nextSnapshot.currentSongId != _snapshot.currentSongId ||
        nextSnapshot.currentIndex != _snapshot.currentIndex) {
      cancelSeekPreview();
    }
    _snapshot = nextSnapshot;
    final startupTrace = _activeStartupTrace;
    if (startupTrace != null &&
        startupTrace.sourceApplied &&
        currentItem?.id == startupTrace.songId &&
        nextSnapshot.processingState == AudioProcessingState.ready) {
      startupTrace.markOnce('playerReady');
    }
    if (!shouldBroadcast) {
      return;
    }
    if (!_snapshotController.isClosed) {
      _snapshotBroadcastCount++;
      debugSnapshotObserver?.call(_snapshot);
      _snapshotController.add(_snapshot);
    }
  }

  Duration _effectivePlaybackDuration(MediaItem? currentItem) {
    return resolveEffectivePlaybackDuration(
      isRadioMode: _radioStation != null,
      mediaDuration: currentItem?.duration,
      playerDuration: _player.duration,
    );
  }

  Future<void> _syncSongLikedState(String songId, {required bool liked}) async {
    await _ready;
    var updated = false;
    for (var i = 0; i < _queueItems.length; i++) {
      final item = _queueItems[i];
      if (item.id == songId) {
        final extras = <String, Object?>{...?item.extras};
        extras['liked'] = liked;
        _queueItems.replaceAt(i, item.copyWith(extras: extras));
        updated = true;
      }
    }
    final remote = _remoteRows[songId];
    if (remote != null) {
      _remoteRows[songId] = remote.copyWith(
        starred: Value(liked ? DateTime.now() : null),
      );
    }
    // Remote rows kept in the deferred tail carry their own liked state.
    for (var i = 0; i < _deferredTail.length; i++) {
      final entry = _deferredTail[i];
      final song = entry.song;
      if (entry.id == songId && song != null) {
        _deferredTail.replaceAt(
          i,
          _DeferredQueueEntry(
            entry.id,
            song.copyWith(starred: Value(liked ? DateTime.now() : null)),
          ),
        );
      }
    }
    if (updated) {
      queue.add(List<MediaItem>.unmodifiable(_queueItems));
      _broadcastPlaybackState();
      _emitSnapshot();
    }
  }

  Future<void> _toggleCurrentSongLike() async {
    await _ready;
    final index = _resolveCurrentQueueMetadata().currentIndex;
    if (index == null || index < 0 || index >= _queueItems.length) return;
    final current = _queueItems[index];
    // A remote copy cannot be liked: the DAO refuses it (no UI here).
    final liked = await _starSyncDao.toggleSongStarred(current.id);
    if (liked == null) return;
    await _syncSongLikedState(current.id, liked: liked);
    final currentIndex = _resolveCurrentQueueMetadata().currentIndex;
    if (currentIndex != null &&
        currentIndex >= 0 &&
        currentIndex < _queueItems.length &&
        _queueItems[currentIndex].id == current.id) {
      _setCurrentMediaItem(_queueItems[currentIndex]);
    }
    unawaited(
      _listenBrainzFeedbackService.enqueueSongFeedback(
        current.id,
        liked: liked,
      ),
    );
  }

  Future<void> _ensurePlayerDisposalStarted() {
    return _playerDisposalFuture ??= () async {
      try {
        await _player.stop();
      } on Object {
        // Ignore stop failures during teardown.
      }
      try {
        await _player.dispose();
      } on Object {
        // Ignore disposal failures during teardown.
      }
      final inactiveDeck = _crossfadePlayer;
      if (inactiveDeck != null) {
        try {
          await inactiveDeck.stop();
        } on Object {
          // Ignore stop failures during teardown.
        }
        try {
          await inactiveDeck.dispose();
        } on Object {
          // Ignore disposal failures during teardown.
        }
        _crossfadePlayer = null;
      }
    }();
  }
}
