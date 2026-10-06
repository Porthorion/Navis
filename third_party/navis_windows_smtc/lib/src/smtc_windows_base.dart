import 'dart:async';

import 'package:navis_windows_smtc/src/enums/button_event.dart';
import 'package:navis_windows_smtc/src/enums/repeat_mode.dart';
import 'package:navis_windows_smtc/src/rust/api/api.dart' as api;
import 'package:navis_windows_smtc/src/rust/frb_generated.dart';
import 'package:navis_windows_smtc/src/rust/internal/config.dart';
import 'package:navis_windows_smtc/src/rust/internal/metadata.dart';
import 'package:navis_windows_smtc/src/rust/internal/playback_status.dart';
import 'package:navis_windows_smtc/src/rust/internal/timeline.dart';

/// Complete native SMTC state applied as one ordered operation.
class WindowsSmtcState {
  const new({
    required this.enabled,
    required this.config,
    required this.status,
    required this.timeline,
    required this.shuffleEnabled,
    required this.repeatMode,
    this.metadata,
    this.updateMetadata = true,
  });

  final bool enabled;
  final SMTCConfig config;
  final PlaybackStatus status;
  final PlaybackTimeline timeline;
  final bool shuffleEnabled;
  final RepeatMode repeatMode;
  final MusicMetadata? metadata;

  /// False for playback-only updates; null metadata otherwise clears the session.
  final bool updateMetadata;
}

/// Navis-owned wrapper for Windows System Media Transport Controls.
///
/// The session is created disabled and with an explicitly disabled control
/// configuration before it is exposed to Dart. That removes the startup race
/// present in the upstream package constructor, which scheduled its initial
/// configuration without awaiting it.
class WindowsSmtcSession {
  new _(this._internal) {
    _buttonPressStream = api
        .smtcButtonPressEvent(internal: _internal)
        .map(PressedButton.fromString)
        .asBroadcastStream();
    _shuffleChangeStream = api
        .smtcShuffleRequestEvent(internal: _internal)
        .asBroadcastStream();
    _repeatModeChangeStream = api
        .smtcRepeatModeRequestEvent(internal: _internal)
        .map(RepeatMode.fromString)
        .asBroadcastStream();
    _positionChangeStream = api
        .smtcPositionChangeRequestEvent(internal: _internal)
        .map((position) => Duration(milliseconds: position))
        .asBroadcastStream();
  }

  static const _disabledConfig = SMTCConfig(
    playEnabled: false,
    pauseEnabled: false,
    stopEnabled: false,
    nextEnabled: false,
    prevEnabled: false,
    fastForwardEnabled: false,
    rewindEnabled: false,
  );

  final api.SmtcInternal _internal;
  late final Stream<PressedButton> _buttonPressStream;
  late final Stream<bool> _shuffleChangeStream;
  late final Stream<RepeatMode> _repeatModeChangeStream;
  late final Stream<Duration> _positionChangeStream;
  Future<void> _writes = Future<void>.value();
  bool _disposed = false;

  static Future<WindowsSmtcSession> create() async {
    await RustLib.init();
    await RustLib.instance.executeRustInitializers();
    final internal = api.smtcNew(enabled: false);
    try {
      await api.smtcUpdateConfig(internal: internal, config: _disabledConfig);
      return WindowsSmtcSession._(internal);
    } on Object {
      internal.dispose();
      rethrow;
    }
  }

  Stream<PressedButton> get buttonPressStream => _buttonPressStream;
  Stream<bool> get shuffleChangeStream => _shuffleChangeStream;
  Stream<RepeatMode> get repeatModeChangeStream => _repeatModeChangeStream;
  Stream<Duration> get positionChangeStream => _positionChangeStream;

  Future<void> applyState(WindowsSmtcState state) {
    return _enqueue(() async {
      if (state.enabled) {
        await api.smtcEnableSmtc(internal: _internal);
      } else {
        await api.smtcDisableSmtc(internal: _internal);
      }
      await api.smtcUpdateConfig(internal: _internal, config: state.config);
      await api.smtcUpdatePlaybackStatus(
        internal: _internal,
        status: state.status,
      );
      await api.smtcUpdateTimeline(
        internal: _internal,
        timeline: state.timeline,
      );
      await api.smtcUpdateShuffle(
        internal: _internal,
        shuffle: state.shuffleEnabled,
      );
      await api.smtcUpdateRepeatMode(
        internal: _internal,
        repeatMode: state.repeatMode.asString,
      );
      if (!state.updateMetadata) return;
      final metadata = state.metadata;
      if (metadata == null) {
        await api.smtcClearMetadata(internal: _internal);
      } else {
        await api.smtcUpdateMetadata(
          internal: _internal,
          metadata: windowsNativeMetadata(metadata),
        );
      }
    });
  }

  Future<void> _enqueue(Future<void> Function() write) {
    if (_disposed) {
      return Future<void>.value();
    }
    final next = _writes.then((_) => write());
    _writes = next.catchError((Object _) {});
    return next;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _writes;
    _internal.dispose();
    RustLib.dispose();
  }
}

/// Converts local file URIs to the paths required by WinRT StorageFile.
/// Remote thumbnails are refused even if a caller bypasses Navis's bridge.
MusicMetadata windowsNativeMetadata(MusicMetadata metadata) {
  final thumbnail = metadata.thumbnail;
  final uri = thumbnail == null ? null : Uri.tryParse(thumbnail);
  String? path;
  if (uri?.scheme == 'file') {
    try {
      path = uri!.toFilePath(windows: true);
    } on UnsupportedError {
      // An unusable local URI leaves the session with text only.
    } on ArgumentError {
      // Malformed file URI.
    }
  } else if (uri != null && uri.scheme != 'http' && uri.scheme != 'https') {
    // Existing callers can still supply an absolute Windows path.
    path = thumbnail;
  }
  return MusicMetadata(
    title: metadata.title,
    artist: metadata.artist,
    album: metadata.album,
    albumArtist: metadata.albumArtist,
    thumbnail: path,
  );
}
