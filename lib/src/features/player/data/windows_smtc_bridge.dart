import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis_windows_smtc/navis_windows_smtc.dart';

/// Bridges Navis playback state with Windows System Media Transport Controls.
class WindowsSmtcBridge {
  WindowsSmtcBridge({
    required NavisPlaybackHandler handler,
    WindowsSmtcClientFactory? createClient,
    bool Function()? isWindowsRuntime,
    this._timelineInterval = const Duration(seconds: 1),
  }) : _handler = handler,
       _createClient = createClient ?? _createDefaultSmtcClient,
       _isWindowsRuntime = isWindowsRuntime ?? _defaultIsWindowsRuntime,
       _latestSnapshot = handler.snapshot,
       _latestMediaItem = handler.currentMediaItem,
       _latestPlaybackPosition = handler.snapshot.position {
    unawaited(_initialize());
  }

  final NavisPlaybackHandler _handler;
  final WindowsSmtcClientFactory _createClient;
  final bool Function() _isWindowsRuntime;
  final Duration _timelineInterval;

  WindowsSmtcClient? _smtc;
  PlaybackSnapshot _latestSnapshot;
  MediaItem? _latestMediaItem;
  StreamSubscription<PlaybackSnapshot>? _snapshotSubscription;
  StreamSubscription<MediaItem?>? _mediaItemSubscription;
  StreamSubscription<PressedButton>? _buttonSubscription;
  StreamSubscription<bool>? _shuffleSubscription;
  StreamSubscription<RepeatMode>? _repeatSubscription;
  StreamSubscription<Duration>? _positionChangeSubscription;
  StreamSubscription<Duration>? _playbackPositionSubscription;
  Timer? _timelineTimer;
  Duration _latestPlaybackPosition;
  Duration? _lastTimelinePosition;
  Future<void> _stateWrites = Future<void>.value();
  int _stateRevision = 0;
  bool _isDisposed = false;

  Future<void> _initialize() async {
    if (!_isWindowsRuntime() || _isDisposed) return;
    try {
      final client = await _createClient();
      if (_isDisposed) {
        await client.dispose();
        return;
      }
      _smtc = client;
      _wireControlListeners(client);
      _wirePlaybackStateListeners();
      await _syncState();
      AppLogger.info('Windows SMTC bridge initialized.');
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Windows SMTC bridge failed to initialize. '
        'Playback continues without OS media control integration. '
        '$error\n$stackTrace',
      );
    }
  }

  void _wirePlaybackStateListeners() {
    _snapshotSubscription = _handler.snapshotStream.listen(
      (snapshot) {
        _latestSnapshot = snapshot;
        _latestPlaybackPosition = snapshot.position;
        unawaited(_syncState());
      },
      onError: _logStreamError('Windows SMTC snapshot stream'),
    );
    _mediaItemSubscription = _handler.mediaItemStream.listen(
      (item) {
        _latestMediaItem = item;
        unawaited(_syncState());
      },
      onError: _logStreamError('Windows SMTC media item stream'),
    );
    _playbackPositionSubscription = _handler.positionStream.listen(
      _handlePlaybackPosition,
      onError: _logStreamError('Windows SMTC playback position stream'),
    );
  }

  void _wireControlListeners(WindowsSmtcClient smtc) {
    _buttonSubscription = smtc.buttonPressStream.listen(
      (event) => unawaited(_handleButtonPress(event)),
      onError: _logStreamError('Windows SMTC button stream'),
    );
    _shuffleSubscription = smtc.shuffleChangeStream.listen(
      (enabled) => unawaited(_handleShuffleRequest(enabled)),
      onError: _logStreamError('Windows SMTC shuffle stream'),
    );
    _repeatSubscription = smtc.repeatModeChangeStream.listen(
      (mode) => unawaited(_handleRepeatRequest(mode)),
      onError: _logStreamError('Windows SMTC repeat-mode stream'),
    );
    _positionChangeSubscription = smtc.positionChangeStream.listen(
      (position) => unawaited(_handlePositionChangeRequest(position)),
      onError: _logStreamError('Windows SMTC position change stream'),
    );
  }

  void Function(Object, StackTrace) _logStreamError(String context) {
    return (Object error, StackTrace stackTrace) {
      AppLogger.warning('$context error: $error\n$stackTrace');
    };
  }

  Future<void> _handleButtonPress(PressedButton event) async {
    if (_isDisposed) return;
    try {
      switch (event) {
        case PressedButton.play:
          await _handler.play();
        case PressedButton.pause:
          await _handler.pause();
        case PressedButton.next:
          await _handler.skipToNext();
        case PressedButton.previous:
          await _handler.skipToPrevious();
        case PressedButton.fastForward:
          await _seekRelative(const Duration(seconds: 10));
        case PressedButton.rewind:
          await _seekRelative(const Duration(seconds: -10));
        case PressedButton.stop:
          await _handler.stop();
        case PressedButton.record ||
            PressedButton.channelUp ||
            PressedButton.channelDown:
          return;
      }
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Windows SMTC button handling failed for $event: $error\n$stackTrace',
      );
    }
  }

  Future<void> _handlePositionChangeRequest(Duration position) async {
    final capabilities = navisOsControlCapabilitiesForSnapshot(_latestSnapshot);
    if (_isDisposed || !capabilities.canSeek) return;
    try {
      await _handler.seek(_clampPosition(position));
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Windows SMTC position change request failed: $error\n$stackTrace',
      );
    }
  }

  Future<void> _seekRelative(Duration delta) =>
      _handler.seek(_clampPosition(_latestPlaybackPosition + delta));

  Duration _clampPosition(Duration position) {
    final duration = _latestSnapshot.duration;
    if (position < Duration.zero) return Duration.zero;
    if (duration > Duration.zero && position > duration) return duration;
    return position;
  }

  Future<void> _handleShuffleRequest(bool enabled) async {
    if (_isDisposed) return;
    try {
      await _handler.setShuffleMode(
        enabled ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Windows SMTC shuffle request failed: $error\n$stackTrace',
      );
    }
  }

  Future<void> _handleRepeatRequest(RepeatMode mode) async {
    if (_isDisposed) return;
    final repeatMode = switch (mode) {
      RepeatMode.none => AudioServiceRepeatMode.none,
      RepeatMode.track => AudioServiceRepeatMode.one,
      RepeatMode.list => AudioServiceRepeatMode.all,
    };
    try {
      await _handler.setRepeatMode(repeatMode);
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Windows SMTC repeat-mode request failed: $error\n$stackTrace',
      );
    }
  }

  Future<void> _syncState() async {
    final smtc = _smtc;
    if (_isDisposed || smtc == null) return;
    final revision = ++_stateRevision;
    final snapshot = _latestSnapshot;
    final item = _latestMediaItem;
    final capabilities = navisOsControlCapabilitiesForSnapshot(snapshot);
    final duration = snapshot.duration;
    final position = _clampPosition(_latestPlaybackPosition);
    final active = snapshot.hasActivePlayback && item != null;
    final status = switch (snapshot.processingState) {
      AudioProcessingState.loading ||
      AudioProcessingState.buffering ||
      AudioProcessingState.ready when snapshot.playing =>
        PlaybackStatus.playing,
      AudioProcessingState.completed ||
      AudioProcessingState.idle => PlaybackStatus.stopped,
      _ => PlaybackStatus.paused,
    };

    final state = WindowsSmtcState(
      enabled: active,
      config: SMTCConfig(
        playEnabled: active && capabilities.canPlay,
        pauseEnabled: active && capabilities.canPause,
        stopEnabled: active && capabilities.canStop,
        nextEnabled: active && capabilities.canSkipNext,
        prevEnabled: active && capabilities.canSkipPrevious,
        fastForwardEnabled: active && capabilities.canSeek,
        rewindEnabled: active && capabilities.canSeek,
      ),
      status: status,
      timeline: PlaybackTimeline(
        startTimeMs: 0,
        endTimeMs: duration.isNegative ? 0 : duration.inMilliseconds,
        positionMs: position.inMilliseconds,
        minSeekTimeMs: 0,
        maxSeekTimeMs: capabilities.canSeek ? duration.inMilliseconds : null,
      ),
      shuffleEnabled: snapshot.shuffleMode == AudioServiceShuffleMode.all,
      repeatMode: switch (snapshot.repeatMode) {
        AudioServiceRepeatMode.none => RepeatMode.none,
        AudioServiceRepeatMode.one => RepeatMode.track,
        AudioServiceRepeatMode.all ||
        AudioServiceRepeatMode.group => RepeatMode.list,
      },
      metadata: item == null
          ? null
          : MusicMetadata(
              title: item.title,
              artist: item.artist,
              album: item.album,
              albumArtist: item.artist,
              thumbnail: _safeArtworkUri(item.artUri),
            ),
    );
    final write = _stateWrites.then((_) => smtc.applyState(state));
    // Keep the state pipe usable after a failed native call. The failed call
    // itself is still reported below, while the next authoritative snapshot
    // is allowed to repair the Windows session.
    _stateWrites = write.catchError((Object _) {});
    try {
      await write;
      if (revision == _stateRevision) {
        _lastTimelinePosition = position;
      }
    } on Object catch (error, stackTrace) {
      AppLogger.warning('Windows SMTC state sync failed: $error\n$stackTrace');
    }
  }

  String? _safeArtworkUri(Uri? uri) {
    if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) {
      return null;
    }
    return uri.toString();
  }

  void _handlePlaybackPosition(Duration position) {
    _latestPlaybackPosition = position;
    final previous = _lastTimelinePosition;
    final discontinuity =
        previous != null &&
        (position - previous).abs() > const Duration(seconds: 2);
    if (discontinuity) {
      _timelineTimer?.cancel();
      _timelineTimer = null;
      unawaited(_syncState());
      return;
    }
    _timelineTimer ??= Timer(_timelineInterval, () {
      _timelineTimer = null;
      unawaited(_syncState());
    });
  }

  Future<void> dispose() async {
    _isDisposed = true;
    _timelineTimer?.cancel();
    _timelineTimer = null;
    await _snapshotSubscription?.cancel();
    await _mediaItemSubscription?.cancel();
    await _playbackPositionSubscription?.cancel();
    await _buttonSubscription?.cancel();
    await _shuffleSubscription?.cancel();
    await _repeatSubscription?.cancel();
    await _positionChangeSubscription?.cancel();
    await _stateWrites;
    final smtc = _smtc;
    _smtc = null;
    if (smtc != null) await smtc.dispose();
  }
}

bool _defaultIsWindowsRuntime() => !kIsWeb && Platform.isWindows;

typedef WindowsSmtcClientFactory = Future<WindowsSmtcClient> Function();

Future<WindowsSmtcClient> _createDefaultSmtcClient() async {
  return OwnedWindowsSmtcClient(await WindowsSmtcSession.create());
}

abstract class WindowsSmtcClient {
  Stream<PressedButton> get buttonPressStream;
  Stream<bool> get shuffleChangeStream;
  Stream<RepeatMode> get repeatModeChangeStream;
  Stream<Duration> get positionChangeStream;
  Future<void> applyState(WindowsSmtcState state);
  Future<void> dispose();
}

class OwnedWindowsSmtcClient implements WindowsSmtcClient {
  OwnedWindowsSmtcClient(this._session);

  final WindowsSmtcSession _session;

  @override
  Stream<PressedButton> get buttonPressStream => _session.buttonPressStream;
  @override
  Stream<bool> get shuffleChangeStream => _session.shuffleChangeStream;
  @override
  Stream<RepeatMode> get repeatModeChangeStream =>
      _session.repeatModeChangeStream;
  @override
  Stream<Duration> get positionChangeStream => _session.positionChangeStream;
  @override
  Future<void> applyState(WindowsSmtcState state) => _session.applyState(state);
  @override
  Future<void> dispose() => _session.dispose();
}
