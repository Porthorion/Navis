import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:smtc_windows/smtc_windows.dart';
import 'package:smtc_windows/src/rust/api/api.dart' as smtc_api;
import 'package:smtc_windows/src/rust/frb_generated.dart' show RustLib;

/// Bridges Navis playback state with Windows System Media Transport Controls.
class WindowsSmtcBridge {
  WindowsSmtcBridge({
    required NavisPlaybackHandler handler,
    WindowsSmtcClientFactory? createClient,
    bool Function()? isWindowsRuntime,
  }) : _handler = handler,
       _createClient = createClient ?? _createDefaultSmtcClient,
       _isWindowsRuntime = isWindowsRuntime ?? _defaultIsWindowsRuntime {
    unawaited(_initialize());
  }

  final NavisPlaybackHandler _handler;
  final WindowsSmtcClientFactory _createClient;
  final bool Function() _isWindowsRuntime;

  WindowsSmtcClient? _smtc;
  StreamSubscription<PlaybackSnapshot>? _snapshotSubscription;
  StreamSubscription<MediaItem?>? _mediaItemSubscription;
  StreamSubscription<PressedButton>? _buttonSubscription;
  StreamSubscription<bool>? _shuffleSubscription;
  StreamSubscription<RepeatMode>? _repeatSubscription;
  StreamSubscription<Duration>? _positionChangeSubscription;

  bool _isDisposed = false;

  Future<void> _initialize() async {
    if (!_isWindowsRuntime() || _isDisposed) {
      return;
    }

    try {
      if (_isDisposed) {
        return;
      }
      _smtc = await _createClient();
      _wireControlListeners();
      _wirePlaybackStateListeners();
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
      (snapshot) => unawaited(_syncSnapshot(snapshot)),
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.warning(
          'Windows SMTC snapshot stream error: $error\n$stackTrace',
        );
      },
    );

    _mediaItemSubscription = _handler.mediaItemStream.listen(
      (item) => unawaited(_syncMediaItem(item)),
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.warning(
          'Windows SMTC media item stream error: $error\n$stackTrace',
        );
      },
    );

    unawaited(_syncSnapshot(_handler.snapshot));
    unawaited(_syncMediaItem(_handler.currentMediaItem));
  }

  void _wireControlListeners() {
    final smtc = _smtc;
    if (smtc == null) {
      return;
    }

    _buttonSubscription = smtc.buttonPressStream.listen(
      (event) => unawaited(_handleButtonPress(event)),
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.warning(
          'Windows SMTC button stream error: $error\n$stackTrace',
        );
      },
    );

    _shuffleSubscription = smtc.shuffleChangeStream.listen(
      (enabled) => unawaited(_handleShuffleRequest(enabled)),
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.warning(
          'Windows SMTC shuffle stream error: $error\n$stackTrace',
        );
      },
    );

    _repeatSubscription = smtc.repeatModeChangeStream.listen(
      (mode) => unawaited(_handleRepeatRequest(mode)),
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.warning(
          'Windows SMTC repeat-mode stream error: $error\n$stackTrace',
        );
      },
    );

    _positionChangeSubscription = smtc.positionChangeStream.listen(
      (position) => unawaited(_handlePositionChangeRequest(position)),
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.warning(
          'Windows SMTC position change stream error: $error\n$stackTrace',
        );
      },
    );
  }

  Future<void> _handleButtonPress(PressedButton event) async {
    if (_isDisposed) {
      return;
    }

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
        'Windows SMTC button handling failed for $event: '
        '$error\n$stackTrace',
      );
    }
  }

  Future<void> _handlePositionChangeRequest(Duration position) async {
    if (_isDisposed) {
      return;
    }
    try {
      await _handler.seek(position);
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Windows SMTC position change request failed: $error\n$stackTrace',
      );
    }
  }

  Future<void> _seekRelative(Duration delta) async {
    final base = _handler.snapshot.position;
    final target = base + delta;
    await _handler.seek(target < Duration.zero ? Duration.zero : target);
  }

  Future<void> _handleShuffleRequest(bool enabled) async {
    if (_isDisposed) {
      return;
    }

    final mode = enabled
        ? AudioServiceShuffleMode.all
        : AudioServiceShuffleMode.none;
    try {
      await _handler.setShuffleMode(mode);
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Windows SMTC shuffle request failed: $error\n$stackTrace',
      );
    }
  }

  Future<void> _handleRepeatRequest(RepeatMode mode) async {
    if (_isDisposed) {
      return;
    }

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

  Future<void> _syncSnapshot(PlaybackSnapshot snapshot) async {
    final smtc = _smtc;
    if (_isDisposed || smtc == null) {
      return;
    }

    final status = switch (snapshot.processingState) {
      AudioProcessingState.loading ||
      AudioProcessingState.buffering ||
      AudioProcessingState.ready when snapshot.playing =>
        PlaybackStatus.playing,
      AudioProcessingState.completed ||
      AudioProcessingState.idle => PlaybackStatus.stopped,
      _ => PlaybackStatus.paused,
    };

    final durationMs = snapshot.duration.inMilliseconds;
    final positionMs = snapshot.position.inMilliseconds;
    final clampedPositionMs = durationMs > 0
        ? positionMs.clamp(0, durationMs)
        : positionMs;

    try {
      await smtc.setControlsEnabled(
        navisOsControlCapabilitiesForSnapshot(snapshot),
      );
      await smtc.setPlaybackStatus(status);
      await smtc.updateTimeline(
        PlaybackTimeline(
          startTimeMs: 0,
          endTimeMs: durationMs < 0 ? 0 : durationMs,
          positionMs: clampedPositionMs,
          minSeekTimeMs: 0,
          maxSeekTimeMs: durationMs > 0 ? durationMs : null,
        ),
      );
      await smtc.setShuffleEnabled(
        enabled: snapshot.shuffleMode == AudioServiceShuffleMode.all,
      );
      await smtc.setRepeatMode(
        switch (snapshot.repeatMode) {
          AudioServiceRepeatMode.none => RepeatMode.none,
          AudioServiceRepeatMode.one => RepeatMode.track,
          AudioServiceRepeatMode.all ||
          AudioServiceRepeatMode.group => RepeatMode.list,
        },
      );
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Windows SMTC snapshot sync failed: $error\n$stackTrace',
      );
    }
  }

  Future<void> _syncMediaItem(MediaItem? item) async {
    final smtc = _smtc;
    if (_isDisposed || smtc == null) {
      return;
    }

    if (item == null) {
      try {
        await smtc.clearMetadata();
      } on Object catch (error, stackTrace) {
        AppLogger.warning(
          'Windows SMTC metadata clear failed: $error\n$stackTrace',
        );
      }
      return;
    }

    try {
      await smtc.updateMetadata(
        MusicMetadata(
          title: item.title,
          artist: item.artist,
          album: item.album,
          albumArtist: item.artist,
          thumbnail: item.artUri?.toString(),
        ),
      );
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Windows SMTC metadata sync failed: $error\n$stackTrace',
      );
    }
  }

  Future<void> dispose() async {
    _isDisposed = true;
    await _snapshotSubscription?.cancel();
    await _mediaItemSubscription?.cancel();
    await _buttonSubscription?.cancel();
    await _shuffleSubscription?.cancel();
    await _repeatSubscription?.cancel();
    await _positionChangeSubscription?.cancel();

    final smtc = _smtc;
    _smtc = null;
    if (smtc != null) {
      try {
        await smtc.dispose();
      } on Object catch (error, stackTrace) {
        AppLogger.warning(
          'Windows SMTC dispose failed: $error\n$stackTrace',
        );
      }
    }
  }
}

bool _defaultIsWindowsRuntime() => !kIsWeb && Platform.isWindows;

typedef WindowsSmtcClientFactory = Future<WindowsSmtcClient> Function();

Future<WindowsSmtcClient> _createDefaultSmtcClient() async {
  await SMTCWindows.initialize();
  return _DirectSmtcClient();
}

abstract class WindowsSmtcClient {
  Stream<PressedButton> get buttonPressStream;
  Stream<bool> get shuffleChangeStream;
  Stream<RepeatMode> get repeatModeChangeStream;

  /// Emits the absolute position (in milliseconds since track start) when the
  /// user drags the SMTC timeline slider or otherwise requests a seek via OS
  /// media controls.
  Stream<Duration> get positionChangeStream;

  Future<void> setPlaybackStatus(PlaybackStatus status);
  Future<void> updateTimeline(PlaybackTimeline timeline);
  Future<void> setShuffleEnabled({required bool enabled});
  Future<void> setRepeatMode(RepeatMode mode);
  Future<void> setControlsEnabled(NavisOsControlCapabilities capabilities);
  Future<void> updateMetadata(MusicMetadata metadata);
  Future<void> clearMetadata();
  Future<void> dispose();
}

/// Low-level SMTC client that talks directly to the Rust FFI layer so that
/// ALL available event streams — including position-change requests — are
/// exposed.  The public `SMTCWindows` wrapper in the `smtc_windows` package
/// does not surface the position-change stream, so we bypass it here.
class _DirectSmtcClient implements WindowsSmtcClient {
  _DirectSmtcClient() {
    final internal = smtc_api.smtcNew(enabled: true);
    _internal = internal;

    _buttonPressStream = smtc_api
        .smtcButtonPressEvent(internal: internal)
        .map(PressedButton.fromString)
        .asBroadcastStream();
    _shuffleStream = smtc_api
        .smtcShuffleRequestEvent(internal: internal)
        .asBroadcastStream();
    _repeatStream = smtc_api
        .smtcRepeatModeRequestEvent(internal: internal)
        .map(RepeatMode.fromString)
        .asBroadcastStream();
    _positionStream = smtc_api
        .smtcPositionChangeRequestEvent(internal: internal)
        .map((ms) => Duration(milliseconds: ms.toInt()))
        .asBroadcastStream();

    smtc_api
        .smtcUpdateConfig(
          internal: internal,
          config: const SMTCConfig(
            playEnabled: false,
            pauseEnabled: false,
            stopEnabled: false,
            nextEnabled: false,
            prevEnabled: false,
            fastForwardEnabled: false,
            rewindEnabled: false,
          ),
        )
        .ignore();
  }

  late final smtc_api.SmtcInternal _internal;
  late final Stream<PressedButton> _buttonPressStream;
  late final Stream<bool> _shuffleStream;
  late final Stream<RepeatMode> _repeatStream;
  late final Stream<Duration> _positionStream;

  @override
  Stream<PressedButton> get buttonPressStream => _buttonPressStream;

  @override
  Stream<bool> get shuffleChangeStream => _shuffleStream;

  @override
  Stream<RepeatMode> get repeatModeChangeStream => _repeatStream;

  @override
  Stream<Duration> get positionChangeStream => _positionStream;

  @override
  Future<void> setPlaybackStatus(PlaybackStatus status) =>
      smtc_api.smtcUpdatePlaybackStatus(
        internal: _internal,
        status: status,
      );

  @override
  Future<void> updateTimeline(PlaybackTimeline timeline) =>
      smtc_api.smtcUpdateTimeline(internal: _internal, timeline: timeline);

  @override
  Future<void> setShuffleEnabled({required bool enabled}) =>
      smtc_api.smtcUpdateShuffle(internal: _internal, shuffle: enabled);

  @override
  Future<void> setRepeatMode(RepeatMode mode) => smtc_api.smtcUpdateRepeatMode(
    internal: _internal,
    repeatMode: mode.asString,
  );

  @override
  Future<void> setControlsEnabled(NavisOsControlCapabilities capabilities) {
    return smtc_api.smtcUpdateConfig(
      internal: _internal,
      config: SMTCConfig(
        playEnabled: capabilities.canPlay,
        pauseEnabled: capabilities.canPause,
        stopEnabled: capabilities.canStop,
        nextEnabled: capabilities.canSkipNext,
        prevEnabled: capabilities.canSkipPrevious,
        fastForwardEnabled: capabilities.canSeek,
        rewindEnabled: capabilities.canSeek,
      ),
    );
  }

  @override
  Future<void> updateMetadata(MusicMetadata metadata) =>
      smtc_api.smtcUpdateMetadata(internal: _internal, metadata: metadata);

  @override
  Future<void> clearMetadata() =>
      smtc_api.smtcClearMetadata(internal: _internal);

  @override
  Future<void> dispose() {
    _internal.dispose();
    RustLib.dispose();
    return Future<void>.value();
  }
}

/// Compatibility shim — wraps an existing [SMTCWindows] instance.  The
/// position-change stream always emits nothing because the high-level
/// [SMTCWindows] class does not expose the underlying Rust event.
///
/// Used by tests that inject a mock [SMTCWindows]-based client.
class DefaultWindowsSmtcClient implements WindowsSmtcClient {
  DefaultWindowsSmtcClient(this._delegate);

  final SMTCWindows _delegate;

  @override
  Stream<PressedButton> get buttonPressStream => _delegate.buttonPressStream;

  @override
  Stream<bool> get shuffleChangeStream => _delegate.shuffleChangeStream;

  @override
  Stream<RepeatMode> get repeatModeChangeStream =>
      _delegate.repeatModeChangeStream;

  /// Position-change events are not available through the high-level
  /// [SMTCWindows] wrapper; always returns an empty stream.
  @override
  Stream<Duration> get positionChangeStream => const Stream.empty();

  @override
  Future<void> setPlaybackStatus(PlaybackStatus status) =>
      _delegate.setPlaybackStatus(status);

  @override
  Future<void> updateTimeline(PlaybackTimeline timeline) =>
      _delegate.updateTimeline(timeline);

  @override
  Future<void> setShuffleEnabled({required bool enabled}) =>
      _delegate.setShuffleEnabled(enabled);

  @override
  Future<void> setRepeatMode(RepeatMode mode) => _delegate.setRepeatMode(mode);

  @override
  Future<void> setControlsEnabled(NavisOsControlCapabilities capabilities) {
    return _delegate.updateConfig(
      SMTCConfig(
        playEnabled: capabilities.canPlay,
        pauseEnabled: capabilities.canPause,
        stopEnabled: capabilities.canStop,
        nextEnabled: capabilities.canSkipNext,
        prevEnabled: capabilities.canSkipPrevious,
        fastForwardEnabled: capabilities.canSeek,
        rewindEnabled: capabilities.canSeek,
      ),
    );
  }

  @override
  Future<void> updateMetadata(MusicMetadata metadata) =>
      _delegate.updateMetadata(metadata);

  @override
  Future<void> clearMetadata() => _delegate.clearMetadata();

  @override
  Future<void> dispose() => _delegate.dispose();
}
