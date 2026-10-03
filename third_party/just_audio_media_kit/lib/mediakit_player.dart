library just_audio_media_kit;

import 'dart:async';

import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';
import 'src/audio_request_batch.dart';
import 'src/deferred_seek.dart';
import 'src/set_property.dart';
import 'src/equalizer_chain.dart';

/// An [AudioPlayerPlatform] which wraps `package:media_kit`'s [Player]
class MediaKitPlayer extends AudioPlayerPlatform {
  MediaKitPlayer(super.id, {EqualizerConfigurationMessage? equalizer}) {
    _equalizer = equalizer;
    _player = Player(
        configuration: PlayerConfiguration(
      pitch: JustAudioMediaKit.pitch,
      protocolWhitelist: JustAudioMediaKit.protocolWhitelist,
      title: JustAudioMediaKit.title,
      bufferSize: JustAudioMediaKit.bufferSize,
      logLevel: JustAudioMediaKit.mpvLogLevel,
      ready: _readyCompleter.complete,
    ));

    // Navis: Subsonic progressive streams are often not marked seekable by
    // lavf/libmpv (especially opus transcodes). Without this, seeks hang or
    // no-op with "Cannot seek in this stream".
    unawaited(setProperty(_player, 'force-seekable', 'yes'));

    // Navis: libmpv's built-in ytdl hook retries any http(s) URL that fails to
    // open through a yt-dlp/youtube-dl found on PATH. Subsonic stream URLs
    // carry the account's salt and token, which would then sit in that
    // subprocess's argv and be requested again. Navis never needs the hook.
    unawaited(setProperty(_player, 'ytdl', 'no'));

    // Navis: stream URLs carry the account's salt and token, so the server
    // certificate must be checked before they are sent.
    if (JustAudioMediaKit.tlsVerify) {
      unawaited(setProperty(_player, 'tls-verify', 'yes'));
    }

    if (JustAudioMediaKit.prefetchPlaylist) {
      setProperty(_player, 'prefetch-playlist', 'yes');
    }

    _nativeSeekingReady = configureNativeSeeking(_player, (seeking) {
      _nativeSeeking = seeking;
      if (!_mediaOpened) return;
      if (_processingState == ProcessingStateMessage.loading) {
        _finishLoadLater();
      } else if (_processingState != ProcessingStateMessage.idle &&
          _processingState != ProcessingStateMessage.completed) {
        _processingState = seeking || _player.state.buffering
            ? ProcessingStateMessage.buffering
            : ProcessingStateMessage.ready;
      }
      _updatePlaybackEvent();
    });

    _streamSubscriptions = [
      _player.stream.audioParams.listen((params) {
        final rate = params.sampleRate?.toDouble();
        if (rate != _sampleRate) {
          _sampleRate = rate;
          if (_equalizer != null) {
            unawaited(_serializeAudio(_applyAudio).catchError((Object error) {
              _eqState = EqualizerStateMessage(
                  enabled: false,
                  sampleRate: _sampleRate,
                  reason: 'Audio processing failed: $error');
            }));
          }
        }
      }),
      _player.stream.duration.listen((duration) {
        if (_currentMedia?.extras?['overrideDuration'] == null) {
          _updateDuration(duration);
        }
        _finishLoadLater();
        _updatePlaybackEvent();
      }),
      _player.stream.position.listen((position) {
        if (!_mediaOpened) return;
        _position = position;
        final start = _currentMedia?.start;
        if (start != null) _position -= start;
        if (_position < Duration.zero) _position = Duration.zero;
        _updatePlaybackEvent();
      }),
      _player.stream.buffering.listen((isBuffering) {
        final start = _currentMedia?.start;
        if (!isBuffering && start != null && _bufferedPosition <= start) {
          // Not ready yet, will be triggered by _player.stream.buffer
          return;
        }
        if (_processingState == ProcessingStateMessage.loading) {
          if (!isBuffering && _mediaOpened) {
            _finishLoadLater();
          }
        } else if (_processingState != ProcessingStateMessage.completed ||
            isBuffering) {
          _processingState = isBuffering
              ? ProcessingStateMessage.buffering
              : ProcessingStateMessage.ready;
          if (_duration == null) {
            _updateDuration(_player.state.duration);
          }
        }
        _errorCode = null;
        _errorMessage = null;
        _updatePlaybackEvent();
      }),
      _player.stream.buffer.listen((buffer) {
        _bufferedPosition = buffer;
        // Detect ready for clipping audio source
        final start = _currentMedia?.start;
        if (!_player.state.buffering &&
            _mediaOpened &&
            start != null &&
            _bufferedPosition > start) {
          _finishLoadLater();
        }
        _updatePlaybackEvent();
      }),
      _player.stream.volume.listen((volume) {
        _dataController.add(PlayerDataMessage(volume: volume / 100.0));
      }),
      _player.stream.completed.listen((completed) {
        if (!completed || !_mediaOpened) return;
        if (completed &&
            // is at the end of the [Playlist]
            _currentIndex == _player.state.playlist.medias.length - 1 &&
            // is not looping (technically this shouldn't be fired if the player is looping)
            _player.state.playlistMode == PlaylistMode.none) {
          _processingState = ProcessingStateMessage.completed;
        }
        _errorCode = null;
        _errorMessage = null;

        _updatePlaybackEvent();
      }),
      _player.stream.error.listen((error) {
        final errorUri = RegExp(r'Failed to open (.*)\.').firstMatch(error)?[1];
        if (errorUri == null || errorUri == _currentMedia?.uri) {
          _processingState = ProcessingStateMessage.idle;
          _errorCode = kErrorCode;
          _errorMessage = error;
          _updatePlaybackEvent();
          final load = _loadCompleter;
          if (load != null && !load.isCompleted) {
            load.completeError(StateError('Media source failed to load.'));
          }
        }
        _logger.severe('ERROR OCCURRED: $error');
      }),
      _player.stream.playlist.listen((playlist) {
        if (_currentIndex != playlist.index) {
          _bufferedPosition = _position = Duration.zero;
          _currentIndex = playlist.index;
        }
        _duration = _currentMedia?.extras?['overrideDuration'];
        if (!_bulkPlaylistMutation) _updatePlaybackEvent();
      }),
      _player.stream.playlistMode.listen((playlistMode) {
        _dataController.add(
            PlayerDataMessage(loopMode: _playlistModeToLoopMode(playlistMode)));
      }),
      _player.stream.pitch.listen((pitch) {
        _dataController.add(PlayerDataMessage(pitch: pitch));
      }),
      _player.stream.rate.listen((rate) {
        _dataController.add(PlayerDataMessage(speed: rate));
      }),
      _player.stream.log.listen((event) {
        print('MPV: [${event.level}] ${event.prefix}: ${event.text}');
      }),
    ];
  }
  static const kErrorCode = 1;

  /// `package:media_kit`'s [Player]
  late final Player _player;

  /// The subscriptions that have to be disposed
  late final List<StreamSubscription> _streamSubscriptions;

  final _readyCompleter = Completer<void>();

  /// Completes when the player is ready
  Future<void> ready() => _readyCompleter.future;

  static final _logger = Logger('MediaKitPlayer');

  final _eventController = StreamController<PlaybackEventMessage>.broadcast();
  final _dataController = StreamController<PlayerDataMessage>.broadcast();

  ProcessingStateMessage _processingState = ProcessingStateMessage.idle;
  Duration _bufferedPosition = Duration.zero;
  Duration _position = Duration.zero;
  Duration? _duration;
  bool _playing = false;
  bool _mediaOpened = false;
  bool _nativeSeeking = false;
  late final Future<void> _nativeSeekingReady;
  int? _errorCode;
  String? _errorMessage;
  Completer<Duration?>? _loadCompleter;
  int _loadGeneration = 0;

  /// The index that's currently playing
  int _currentIndex = 0;

  late final DeferredSeek _deferredSeek = DeferredSeek(
    // Progressive streams can become playable without a native duration.
    // force-seekable still permits an explicit seek once opening is ready.
    isReady: () =>
        _mediaOpened &&
        (_player.state.duration > Duration.zero || !_player.state.buffering),
    // Only native position events report a landed seek. The command's
    // completion can precede decoding or represent a native no-op.
    apply: (position) async {
      _nativeSeeking = true;
      _updatePlaybackEvent();
      await _player.seek(position + (_currentMedia?.start ?? Duration.zero));
    },
  );

  void _finishLoadLater() {
    final generation = _loadGeneration;
    unawaited(_finishLoad(generation).catchError((Object error) {
      if (generation != _loadGeneration) return;
      final load = _loadCompleter;
      if (load != null && !load.isCompleted) load.completeError(error);
    }));
  }

  Future<void> _finishLoad(int generation) async {
    if (!_mediaOpened || generation != _loadGeneration) return;
    await _deferredSeek.flush();
    if (generation != _loadGeneration || _deferredSeek.isPending) return;
    final start = _currentMedia?.start;
    if (_nativeSeeking ||
        _player.state.buffering ||
        (start != null && _bufferedPosition <= start)) return;
    if (_processingState == ProcessingStateMessage.loading) {
      _processingState = ProcessingStateMessage.ready;
      _updateDuration(_player.state.duration);
      _completeLoad(_duration);
      _updatePlaybackEvent();
    }
  }

  Media? get _currentMedia {
    final medias = _player.state.playlist.medias;
    if (medias.isEmpty) return null;
    return medias[_player.state.playlist.index];
  }

  /// Diagnostics only: the URI of the media mpv is playing.
  String? get debugCurrentMediaUri => _currentMedia?.uri;

  /// Credential-free native transport state for isolated runtime checks.
  Map<String, Object?> get debugTransportState => {
        'positionMs': _player.state.position.inMilliseconds,
        'durationMs': _player.state.duration.inMilliseconds,
        'playing': _player.state.playing,
        'buffering': _player.state.buffering,
        'requestedPlaying': _playing,
        'pendingPosition': _deferredSeek.isPending,
        'seeking': _nativeSeeking,
      };

  EqualizerConfigurationMessage? _equalizer;
  EqualizerStateMessage _eqState = const EqualizerStateMessage(enabled: false);
  Future<void> _audioLane = Future<void>.value();
  double _rate = 1;
  double _pitch = 1;
  double? _sampleRate;

  void _updateDuration(Duration duration) {
    final start = _currentMedia?.start;
    final end = _currentMedia?.end;
    if (end != null) duration = end;
    if (start != null) duration -= start;
    _duration = duration;
  }

  void _completeLoad(Duration? duration) {
    final load = _loadCompleter;
    if (load != null && !load.isCompleted) load.complete(duration);
  }

  PlaylistMode _loopModeToPlaylistMode(LoopModeMessage loopMode) {
    return switch (loopMode) {
      LoopModeMessage.off => PlaylistMode.none,
      LoopModeMessage.one => PlaylistMode.single,
      LoopModeMessage.all => PlaylistMode.loop,
    };
  }

  LoopModeMessage _playlistModeToLoopMode(PlaylistMode playlistMode) {
    return switch (playlistMode) {
      PlaylistMode.none => LoopModeMessage.off,
      PlaylistMode.single => LoopModeMessage.one,
      PlaylistMode.loop => LoopModeMessage.all,
    };
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _eventController.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream =>
      _dataController.stream;

  /// Updates the playback event
  /// True while [concatenatingInsertAll] applies several children; playlist
  /// updates then defer their playback event to the end of the insert.
  bool _bulkPlaylistMutation = false;

  void _updatePlaybackEvent() {
    _eventController.add(PlaybackEventMessage(
      processingState: _nativeSeeking &&
              _processingState != ProcessingStateMessage.loading &&
              _processingState != ProcessingStateMessage.idle
          ? ProcessingStateMessage.buffering
          : _processingState,
      updateTime: DateTime.now(),
      updatePosition: _position,
      bufferedPosition: _bufferedPosition,
      duration: _duration,
      icyMetadata: null,
      currentIndex: _currentIndex,
      androidAudioSessionId: null,
      errorCode: _errorCode,
      errorMessage: _errorMessage,
    ));
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _logger.finest('load(${request.toMap()})');
    // A later load supersedes the old wait. The previous caller must settle
    // even if libmpv never emits a ready event for its retired source.
    _completeLoad(null);
    final generation = ++_loadGeneration;
    final load = Completer<Duration?>();
    unawaited(
        load.future.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    _mediaOpened = false;
    _loadCompleter = load;
    _deferredSeek.beginLoad(request.initialPosition);
    _currentIndex = request.initialIndex ?? 0;
    _bufferedPosition = Duration.zero;
    _position = Duration.zero;
    _duration = null;
    _processingState = ProcessingStateMessage.loading;
    _errorCode = null;
    _errorMessage = null;
    _updatePlaybackEvent();

    try {
      await _nativeSeekingReady;
      if (request.audioSourceMessage is ConcatenatingAudioSourceMessage) {
        final audioSource =
            request.audioSourceMessage as ConcatenatingAudioSourceMessage;
        final playable = Playlist(
            audioSource.children.map(_convertAudioSourceIntoMediaKit).toList(),
            index: _currentIndex);

        await _player.open(playable, play: _playing);
      } else {
        final playable =
            _convertAudioSourceIntoMediaKit(request.audioSourceMessage);
        _logger.finest('playable is $playable');
        await _player.open(playable, play: _playing);
      }
      if (generation != _loadGeneration) return LoadResponse(duration: null);
      _mediaOpened = true;
      if (_equalizer != null) await _serializeAudio(_applyAudio);

      await _finishLoad(generation);
      _updatePlaybackEvent();
      return LoadResponse(duration: await load.future);
    } finally {
      if (identical(_loadCompleter, load)) _loadCompleter = null;
    }
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    _playing = true;
    if (_mediaOpened) {
      await _player.play();
    }
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    _playing = false;
    if (_mediaOpened) {
      await _player.pause();
    }
    return PauseResponse();
  }

  Future<void> setAudioDevice(String device) async {
    await setProperty(_player, 'audio-device', device);
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) {
    return _player
        .setVolume(request.volume * 100.0)
        .then((value) => SetVolumeResponse());
  }

  Future<T> _serializeAudio<T>(Future<T> Function() operation) {
    final result = _audioLane.then((_) => operation());
    _audioLane =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> _applyAudio(
      {double? rate,
      double? pitch,
      EqualizerConfigurationMessage? equalizer}) async {
    await ready();
    final nextRate = rate ?? _rate;
    final nextPitch = pitch ?? _pitch;
    final nextEq = equalizer ?? _equalizer!;
    final chain = EqualizerChain.compile(nextEq,
        speed: nextRate, pitch: nextPitch, sampleRate: _sampleRate);
    try {
      await setProperty(_player, 'audio-pitch-correction', 'no');
      await setProperty(_player, 'speed', nextPitch.toString());
      await setProperty(_player, 'af', chain.filters);
      await verifyOwnedAudioChain(_player, chain.filters, nextPitch);
    } catch (_) {
      // Only needed to roll back, and compiling a chain with the EQ on is
      // not free.
      final previous = EqualizerChain.compile(_equalizer!,
          speed: _rate, pitch: _pitch, sampleRate: _sampleRate);
      try {
        await setProperty(_player, 'speed', _pitch.toString());
        await setProperty(_player, 'af', previous.filters);
        await verifyOwnedAudioChain(_player, previous.filters, _pitch);
      } catch (rollbackError) {
        _eqState = EqualizerStateMessage(
            enabled: false,
            sampleRate: _sampleRate,
            reason: 'Audio processing could not be restored: $rollbackError');
      }
      rethrow;
    }
    _rate = nextRate;
    _pitch = nextPitch;
    _equalizer = nextEq;
    _eqState = chain.state;
    _dataController.add(PlayerDataMessage(speed: _rate, pitch: _pitch));
  }

  late final AudioRequestBatch<EqualizerConfigurationMessage> _audioRequests =
      AudioRequestBatch<EqualizerConfigurationMessage>(
          ({rate, pitch, equalizer}) => _serializeAudio(() =>
              _applyAudio(rate: rate, pitch: pitch, equalizer: equalizer)));

  @override
  Future<EqualizerStateMessage> setEqualizer(
      EqualizerConfigurationMessage configuration) async {
    if (_equalizer == null) throw UnsupportedError('EQ pipeline unavailable');
    await _audioRequests.request(equalizer: configuration);
    return _eqState;
  }

  @override
  Future<EqualizerStateMessage> getEqualizerState() async {
    await _audioLane;
    return _eqState;
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    if (_equalizer == null) {
      await _player.setRate(request.speed);
    } else {
      await _audioRequests.request(rate: request.speed);
    }
    return SetSpeedResponse();
  }

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async {
    if (_equalizer == null) {
      await _player.setPitch(request.pitch);
      await verifyPlaybackAdjustments(_player);
    } else {
      await _audioRequests.request(pitch: request.pitch);
    }
    return SetPitchResponse();
  }

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    await _player.setPlaylistMode(_loopModeToPlaylistMode(request.loopMode));
    return SetLoopModeResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
      SetShuffleModeRequest request) async {
    final shuffling = request.shuffleMode != ShuffleModeMessage.none;
    await _player.setShuffle(shuffling);

    _dataController.add(PlayerDataMessage(
        shuffleMode:
            shuffling ? ShuffleModeMessage.all : ShuffleModeMessage.none));
    return SetShuffleModeResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _logger.finest('seek(${request.toMap()})');
    if (request.index != null) {
      await _player.jump(request.index!);
      if (!_playing) await _player.pause();
    }

    final position = request.position;
    if (position != null) {
      _deferredSeek.request(position);
      await _deferredSeek.flush();
    } else {
      _position = Duration.zero;
    }

    // reset position on seek
    _updatePlaybackEvent();
    return SeekResponse();
  }

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
      ConcatenatingInsertAllRequest request) async {
    // _logger.fine('concatenatingInsertAll(${request.toMap()})');
    // Each add/move re-emits the playlist. Emit one playback event after the
    // whole insert instead of two per child, so a large queue fill does not
    // flood just_audio (and its listeners) with intermediate states.
    _bulkPlaylistMutation = true;
    try {
      for (var offset = 0; offset < request.children.length; offset++) {
        await _player
            .add(_convertAudioSourceIntoMediaKit(request.children[offset]));

        final length = _player.state.playlist.medias.length;

        if (length == 0 || length == 1) continue;

        // Children keep their order: child N belongs at index + N.
        final target = request.index + offset;
        if (target < (length - 1) && target >= 0) {
          // `add` appends at length - 1. Passing length asks libmpv to move a
          // nonexistent entry, leaving its playlist out of sync with
          // just_audio.
          await _player.move(length - 1, target);
        }
      }
    } finally {
      _bulkPlaylistMutation = false;
    }
    _updatePlaybackEvent();

    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
      ConcatenatingRemoveRangeRequest request) async {
    // One playback event for the range, as for inserts, rather than one per
    // removed child.
    _bulkPlaylistMutation = true;
    try {
      for (var i = request.startIndex; i < request.endIndex; i++) {
        await _player.remove(request.startIndex);
      }
    } finally {
      _bulkPlaylistMutation = false;
    }
    _updatePlaybackEvent();

    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(
      ConcatenatingMoveRequest request) {
    return _player
        .move(
            request.currentIndex,
            // not sure why, but apparently there's an underlying difference between just_audio's move implementation
            // and media_kit, so let's fix it
            request.currentIndex > request.newIndex
                ? request.newIndex
                : request.newIndex + 1)
        .then((_) => ConcatenatingMoveResponse());
  }

  /// Release the resources used by this player.
  Future<void> release() async {
    _logger.info('releasing player resources');
    ++_loadGeneration;
    _completeLoad(null);
    _loadCompleter = null;
    _mediaOpened = false;
    await _player.dispose();
    // cancel all stream subscriptions
    for (final subscription in _streamSubscriptions) {
      unawaited(subscription.cancel());
    }
    _streamSubscriptions.clear();
  }

  /// Converts an [AudioSourceMessage] into a [Media] for playback
  Media _convertAudioSourceIntoMediaKit(AudioSourceMessage audioSource) {
    switch (audioSource) {
      case final UriAudioSourceMessage uriSource:
        return Media(uriSource.uri, httpHeaders: audioSource.headers);

      // removed because it doesn't seem to be actually working.
      // Related media-kit issue: https://github.com/media-kit/media-kit/issues/28
      // case final SilenceAudioSourceMessage silenceSource:
      //   // from https://github.com/bleonard252/just_audio_mpv/blob/main/lib/src/mpv_player.dart#L137
      //   return Media(
      //     'av://lavfi:anullsrc=d=${silenceSource.duration.inMilliseconds}ms',
      //     extras: {'overrideDuration': silenceSource.duration},
      //   );

      case final ClippingAudioSourceMessage clippingSource:
        return Media(clippingSource.child.uri,
            start: clippingSource.start, end: clippingSource.end);

      default:
        throw UnsupportedError(
            '${audioSource.runtimeType} is currently not supported');
    }
  }
}
