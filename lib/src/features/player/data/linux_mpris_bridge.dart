import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Bridges Navis playback state with the Linux MPRIS D-Bus protocol.
///
/// Registers a full `org.mpris.MediaPlayer2` service at
/// `org.mpris.MediaPlayer2.navis` and forwards control commands from the
/// desktop shell (GNOME media bar, KDE, etc.) back to [NavisPlaybackHandler].
///
/// This replaces the incomplete `audio_service_mpris` integration which did
/// not implement `Seek`, `SetPosition`, `Shuffle`, or `LoopStatus`.
class LinuxMprisBridge {
  LinuxMprisBridge({
    required NavisPlaybackHandler handler,
    bool Function()? isLinuxRuntime,
  }) : _handler = handler,
       _isLinuxRuntime = isLinuxRuntime ?? _defaultIsLinuxRuntime {
    unawaited(_initialize());
  }

  final NavisPlaybackHandler _handler;
  final bool Function() _isLinuxRuntime;

  DBusClient? _dbusClient;
  _NavisMprisObject? _mprisObject;
  StreamSubscription<PlaybackSnapshot>? _snapshotSubscription;
  StreamSubscription<MediaItem?>? _mediaItemSubscription;

  bool _isDisposed = false;

  Future<void> _initialize() async {
    if (!_isLinuxRuntime() || _isDisposed) {
      return;
    }

    try {
      final client = DBusClient.session();
      _dbusClient = client;

      final obj = _NavisMprisObject(onCommand: _handleCommand);
      _mprisObject = obj;

      await client.registerObject(obj);
      await client.requestName(
        'org.mpris.MediaPlayer2.navis.instance${pid}',
        flags: {DBusRequestNameFlag.doNotQueue},
      );

      // Guard against dispose() being called while we were awaiting above.
      if (_isDisposed) {
        await client.close();
        return;
      }

      _wireListeners();
      AppLogger.info('Linux MPRIS bridge initialized.');
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Linux MPRIS bridge failed to initialize. '
        'Playback continues without MPRIS desktop integration. '
        '$error\n$stackTrace',
      );
    }
  }

  void _wireListeners() {
    _snapshotSubscription = _handler.snapshotStream.listen(
      (snapshot) => unawaited(_syncSnapshot(snapshot)),
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.warning(
          'Linux MPRIS snapshot stream error: $error\n$stackTrace',
        );
      },
    );

    _mediaItemSubscription = _handler.mediaItemStream.listen(
      (item) => unawaited(_syncMediaItem(item)),
      onError: (Object error, StackTrace stackTrace) {
        AppLogger.warning(
          'Linux MPRIS media item stream error: $error\n$stackTrace',
        );
      },
    );

    unawaited(_syncSnapshot(_handler.snapshot));
    unawaited(_syncMediaItem(_handler.currentMediaItem));
  }

  Future<void> _handleCommand(_MprisCommand command) async {
    if (_isDisposed) {
      return;
    }

    try {
      switch (command) {
        case _PlayCommand():
          await _handler.play();
        case _PauseCommand():
          await _handler.pause();
        case _PlayPauseCommand():
          final snapshot = _handler.snapshot;
          if (snapshot.playing) {
            await _handler.pause();
          } else {
            await _handler.play();
          }
        case _StopCommand():
          await _handler.pause();
        case _NextCommand():
          await _handler.skipToNext();
        case _PreviousCommand():
          await _handler.skipToPrevious();
        case _SeekCommand(offsetUs: final offsetUs):
          final base = _handler.snapshot.position;
          final target = base + Duration(microseconds: offsetUs);
          final clamped = target < Duration.zero ? Duration.zero : target;
          await _handler.seek(clamped);
          unawaited(_mprisObject?.emitSeeked(clamped));
        case _SetPositionCommand(
          trackId: final trackId,
          positionUs: final posUs,
        ):
          final obj = _mprisObject;
          if (obj == null || trackId != obj.currentTrackId) {
            return;
          }
          final dur = _handler.snapshot.duration;
          final target = Duration(microseconds: posUs);
          if (target < Duration.zero || (dur > Duration.zero && target > dur)) {
            return;
          }
          await _handler.seek(target);
          // Use the nullable field, not the local 'obj', so that a concurrent
          // dispose() that nulls _mprisObject prevents emitting on a closed client.
          unawaited(_mprisObject?.emitSeeked(target));
        case _SetLoopStatusCommand(loopStatus: final loopStatus):
          final repeatMode = switch (loopStatus) {
            'Track' => AudioServiceRepeatMode.one,
            'Playlist' => AudioServiceRepeatMode.all,
            _ => AudioServiceRepeatMode.none,
          };
          await _handler.setRepeatMode(repeatMode);
        case _SetShuffleCommand(enabled: final enabled):
          await _handler.setShuffleMode(
            enabled
                ? AudioServiceShuffleMode.all
                : AudioServiceShuffleMode.none,
          );
        case _SetRateCommand(rate: final rate):
          if (rate > 0.0) {
            await _handler.setPlaybackSpeed(rate);
            _mprisObject?.updateRate(rate);
          }
      }
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Linux MPRIS command handling failed: $error\n$stackTrace',
      );
    }
  }

  Future<void> _syncSnapshot(PlaybackSnapshot snapshot) async {
    final obj = _mprisObject;
    if (_isDisposed || obj == null) {
      return;
    }

    final status = switch (snapshot.processingState) {
      AudioProcessingState.loading ||
      AudioProcessingState.buffering ||
      AudioProcessingState.ready when snapshot.playing => 'Playing',
      AudioProcessingState.completed || AudioProcessingState.idle => 'Stopped',
      _ => 'Paused',
    };

    final loopStatus = switch (snapshot.repeatMode) {
      AudioServiceRepeatMode.one => 'Track',
      AudioServiceRepeatMode.all || AudioServiceRepeatMode.group => 'Playlist',
      _ => 'None',
    };

    obj.syncState(
      status: status,
      position: snapshot.position,
      loopStatus: loopStatus,
      shuffleEnabled: snapshot.shuffleMode == AudioServiceShuffleMode.all,
    );
  }

  Future<void> _syncMediaItem(MediaItem? item) async {
    final obj = _mprisObject;
    if (_isDisposed || obj == null) {
      return;
    }

    if (item == null) {
      obj.clearMetadata();
      return;
    }

    obj.updateMetadata(
      trackId: _sanitizeTrackId(item.id),
      title: item.title,
      artist: item.artist,
      album: item.album,
      artUrl: item.artUri?.toString(),
      duration: item.duration,
    );
  }

  Future<void> dispose() async {
    _isDisposed = true;
    await _snapshotSubscription?.cancel();
    await _mediaItemSubscription?.cancel();
    final client = _dbusClient;
    _dbusClient = null;
    _mprisObject = null;

    if (client != null) {
      try {
        await client.close();
      } on Object catch (error, stackTrace) {
        AppLogger.warning(
          'Linux MPRIS bridge dispose failed: $error\n$stackTrace',
        );
      }
    }
  }
}

bool _defaultIsLinuxRuntime() => !kIsWeb && Platform.isLinux;

/// Converts an arbitrary song ID to a valid D-Bus object path segment.
/// Object path components must match `[A-Za-z0-9_]+`.
String _sanitizeTrackId(String songId) {
  final sanitized = songId.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  final safe = sanitized.isEmpty ? 'unknown' : sanitized;
  return '/org/mpris/MediaPlayer2/Track/$safe';
}

// ---- Command types ----------------------------------------------------------

sealed class _MprisCommand {}

final class _PlayCommand extends _MprisCommand {}

final class _PauseCommand extends _MprisCommand {}

final class _PlayPauseCommand extends _MprisCommand {}

final class _StopCommand extends _MprisCommand {}

final class _NextCommand extends _MprisCommand {}

final class _PreviousCommand extends _MprisCommand {}

final class _SeekCommand extends _MprisCommand {
  _SeekCommand({required this.offsetUs});
  final int offsetUs;
}

final class _SetPositionCommand extends _MprisCommand {
  _SetPositionCommand({required this.trackId, required this.positionUs});
  final String trackId;
  final int positionUs;
}

final class _SetLoopStatusCommand extends _MprisCommand {
  _SetLoopStatusCommand({required this.loopStatus});
  final String loopStatus;
}

final class _SetShuffleCommand extends _MprisCommand {
  _SetShuffleCommand({required this.enabled});
  final bool enabled;
}

final class _SetRateCommand extends _MprisCommand {
  _SetRateCommand({required this.rate});
  final double rate;
}

// ---- D-Bus MPRIS object ----------------------------------------------------

/// D-Bus object that implements the full `org.mpris.MediaPlayer2` and
/// `org.mpris.MediaPlayer2.Player` interfaces, including working `Seek`,
/// `SetPosition`, `LoopStatus`, and `Shuffle` support.
class _NavisMprisObject extends DBusObject {
  _NavisMprisObject({required this.onCommand})
    : super(DBusObjectPath('/org/mpris/MediaPlayer2'));

  final Future<void> Function(_MprisCommand) onCommand;

  // ---- State (updated by LinuxMprisBridge) ----
  String _playbackStatus = 'Stopped';
  DBusValue _metadata = DBusDict.stringVariant({});
  Duration _position = Duration.zero;
  bool _shuffleEnabled = false;
  String _loopStatus = 'None';
  double _rate = 1.0;

  /// Current track D-Bus object path; used to validate `SetPosition` calls.
  String? currentTrackId;

  // ---- Seek-detection state -----------------------------------------------
  // Tracks the last known position and when it was recorded so that
  // non-MPRIS-initiated seeks (i.e. user drags the scrubber inside the app)
  // still emit the Seeked signal to GNOME Shell.

  static const _seekDetectionThreshold = Duration(seconds: 2);

  Duration _lastSyncedPosition = Duration.zero;
  DateTime _lastSyncedTime = DateTime.fromMillisecondsSinceEpoch(0);
  bool _wasPlaying = false;
  String? _lastSyncedTrackId;

  // ---- State update API used by LinuxMprisBridge --------------------------

  void syncState({
    required String status,
    required Duration position,
    required String loopStatus,
    required bool shuffleEnabled,
  }) {
    // Detect position jumps that weren't MPRIS-initiated — e.g. the user
    // seeked via the Navis UI while the media bar was showing. The MPRIS
    // spec requires a Seeked signal whenever position deviates from the
    // expected extrapolation (lastPos + elapsed * rate).
    //
    // Guard: only check when the same track is still playing so we don't
    // false-fire on a normal track advance (where updateMetadata() updates
    // currentTrackId before syncState() is called, making IDs differ).
    if (_wasPlaying &&
        currentTrackId != null &&
        currentTrackId == _lastSyncedTrackId) {
      final elapsed = DateTime.now().difference(_lastSyncedTime);
      final expectedUs =
          _lastSyncedPosition.inMicroseconds +
          (elapsed.inMicroseconds * _rate).round();
      final expectedPosition = Duration(
        microseconds: math.max(0, expectedUs),
      );
      if ((position - expectedPosition).abs() > _seekDetectionThreshold) {
        unawaited(emitSeeked(position));
      }
    }

    _lastSyncedPosition = position;
    _lastSyncedTime = DateTime.now();
    _wasPlaying = status == 'Playing';
    _lastSyncedTrackId = currentTrackId;

    // Position is not part of PropertiesChanged (clients poll it per spec).
    _position = position;

    final changed = <String, DBusValue>{};

    if (status != _playbackStatus) {
      _playbackStatus = status;
      changed['PlaybackStatus'] = DBusString(status);
    }
    if (loopStatus != _loopStatus) {
      _loopStatus = loopStatus;
      changed['LoopStatus'] = DBusString(loopStatus);
    }
    if (shuffleEnabled != _shuffleEnabled) {
      _shuffleEnabled = shuffleEnabled;
      changed['Shuffle'] = DBusBoolean(shuffleEnabled);
    }

    if (changed.isNotEmpty) {
      unawaited(
        emitPropertiesChanged(
          'org.mpris.MediaPlayer2.Player',
          changedProperties: changed,
        ),
      );
    }
  }

  void clearMetadata() {
    currentTrackId = null;
    _metadata = DBusDict.stringVariant({});
    unawaited(
      emitPropertiesChanged(
        'org.mpris.MediaPlayer2.Player',
        changedProperties: {'Metadata': _metadata},
      ),
    );
  }

  void updateMetadata({
    required String trackId,
    required String title,
    String? artist,
    String? album,
    String? artUrl,
    Duration? duration,
  }) {
    currentTrackId = trackId;
    _metadata = DBusDict.stringVariant({
      'mpris:trackid': DBusObjectPath(trackId),
      'xesam:title': DBusString(title),
      if (artist != null) 'xesam:artist': DBusArray.string([artist]),
      if (album != null) 'xesam:album': DBusString(album),
      if (artUrl != null) 'mpris:artUrl': DBusString(artUrl),
      if (duration != null && duration > Duration.zero)
        'mpris:length': DBusInt64(duration.inMicroseconds),
    });
    unawaited(
      emitPropertiesChanged(
        'org.mpris.MediaPlayer2.Player',
        changedProperties: {'Metadata': _metadata},
      ),
    );
  }

  void updateRate(double rate) {
    if (rate == _rate) return;
    _rate = rate;
    unawaited(
      emitPropertiesChanged(
        'org.mpris.MediaPlayer2.Player',
        changedProperties: {'Rate': DBusDouble(rate)},
      ),
    );
  }

  Future<void> emitSeeked(Duration position) => emitSignal(
    'org.mpris.MediaPlayer2.Player',
    'Seeked',
    [DBusInt64(position.inMicroseconds)],
  );

  // ---- DBusObject overrides ------------------------------------------------

  @override
  List<DBusIntrospectInterface> introspect() {
    return [
      DBusIntrospectInterface(
        'org.mpris.MediaPlayer2',
        methods: [
          DBusIntrospectMethod('Raise'),
          DBusIntrospectMethod('Quit'),
        ],
        properties: [
          DBusIntrospectProperty(
            'CanQuit',
            DBusSignature('b'),
            access: DBusPropertyAccess.read,
          ),
          DBusIntrospectProperty(
            'CanRaise',
            DBusSignature('b'),
            access: DBusPropertyAccess.read,
          ),
          DBusIntrospectProperty(
            'HasTrackList',
            DBusSignature('b'),
            access: DBusPropertyAccess.read,
          ),
          DBusIntrospectProperty(
            'Identity',
            DBusSignature('s'),
            access: DBusPropertyAccess.read,
          ),
          DBusIntrospectProperty(
            'SupportedUriSchemes',
            DBusSignature('as'),
            access: DBusPropertyAccess.read,
          ),
          DBusIntrospectProperty(
            'SupportedMimeTypes',
            DBusSignature('as'),
            access: DBusPropertyAccess.read,
          ),
        ],
      ),
      DBusIntrospectInterface(
        'org.mpris.MediaPlayer2.Player',
        methods: [
          DBusIntrospectMethod('Next'),
          DBusIntrospectMethod('Previous'),
          DBusIntrospectMethod('Pause'),
          DBusIntrospectMethod('PlayPause'),
          DBusIntrospectMethod('Stop'),
          DBusIntrospectMethod('Play'),
          DBusIntrospectMethod(
            'Seek',
            args: [
              DBusIntrospectArgument(
                DBusSignature('x'),
                DBusArgumentDirection.in_,
                name: 'Offset',
              ),
            ],
          ),
          DBusIntrospectMethod(
            'SetPosition',
            args: [
              DBusIntrospectArgument(
                DBusSignature('o'),
                DBusArgumentDirection.in_,
                name: 'TrackId',
              ),
              DBusIntrospectArgument(
                DBusSignature('x'),
                DBusArgumentDirection.in_,
                name: 'Position',
              ),
            ],
          ),
          DBusIntrospectMethod(
            'OpenUri',
            args: [
              DBusIntrospectArgument(
                DBusSignature('s'),
                DBusArgumentDirection.in_,
                name: 'Uri',
              ),
            ],
          ),
        ],
        signals: [
          DBusIntrospectSignal(
            'Seeked',
            args: [
              DBusIntrospectArgument(
                DBusSignature('x'),
                DBusArgumentDirection.out,
                name: 'Position',
              ),
            ],
          ),
        ],
        properties: [
          DBusIntrospectProperty(
            'PlaybackStatus',
            DBusSignature('s'),
            access: DBusPropertyAccess.read,
          ),
          DBusIntrospectProperty(
            'LoopStatus',
            DBusSignature('s'),
            access: DBusPropertyAccess.readwrite,
          ),
          DBusIntrospectProperty(
            'Rate',
            DBusSignature('d'),
            access: DBusPropertyAccess.readwrite,
          ),
          DBusIntrospectProperty(
            'Shuffle',
            DBusSignature('b'),
            access: DBusPropertyAccess.readwrite,
          ),
          DBusIntrospectProperty(
            'Metadata',
            DBusSignature('a{sv}'),
            access: DBusPropertyAccess.read,
          ),
          DBusIntrospectProperty(
            'Volume',
            DBusSignature('d'),
            access: DBusPropertyAccess.readwrite,
          ),
          DBusIntrospectProperty(
            'Position',
            DBusSignature('x'),
            access: DBusPropertyAccess.read,
          ),
          DBusIntrospectProperty(
            'MinimumRate',
            DBusSignature('d'),
            access: DBusPropertyAccess.read,
          ),
          DBusIntrospectProperty(
            'MaximumRate',
            DBusSignature('d'),
            access: DBusPropertyAccess.read,
          ),
          DBusIntrospectProperty(
            'CanGoNext',
            DBusSignature('b'),
            access: DBusPropertyAccess.read,
          ),
          DBusIntrospectProperty(
            'CanGoPrevious',
            DBusSignature('b'),
            access: DBusPropertyAccess.read,
          ),
          DBusIntrospectProperty(
            'CanPlay',
            DBusSignature('b'),
            access: DBusPropertyAccess.read,
          ),
          DBusIntrospectProperty(
            'CanPause',
            DBusSignature('b'),
            access: DBusPropertyAccess.read,
          ),
          DBusIntrospectProperty(
            'CanSeek',
            DBusSignature('b'),
            access: DBusPropertyAccess.read,
          ),
          DBusIntrospectProperty(
            'CanControl',
            DBusSignature('b'),
            access: DBusPropertyAccess.read,
          ),
        ],
      ),
    ];
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface == 'org.mpris.MediaPlayer2') {
      switch (methodCall.name) {
        case 'Raise':
        case 'Quit':
          return DBusMethodSuccessResponse();
        default:
          return DBusMethodErrorResponse.unknownMethod();
      }
    }

    if (methodCall.interface == 'org.mpris.MediaPlayer2.Player') {
      switch (methodCall.name) {
        case 'Play':
          unawaited(onCommand(_PlayCommand()));
          return DBusMethodSuccessResponse();
        case 'Pause':
          unawaited(onCommand(_PauseCommand()));
          return DBusMethodSuccessResponse();
        case 'PlayPause':
          unawaited(onCommand(_PlayPauseCommand()));
          return DBusMethodSuccessResponse();
        case 'Stop':
          unawaited(onCommand(_StopCommand()));
          return DBusMethodSuccessResponse();
        case 'Next':
          unawaited(onCommand(_NextCommand()));
          return DBusMethodSuccessResponse();
        case 'Previous':
          unawaited(onCommand(_PreviousCommand()));
          return DBusMethodSuccessResponse();
        case 'Seek':
          if (methodCall.signature != DBusSignature('x')) {
            return DBusMethodErrorResponse.invalidArgs();
          }
          unawaited(
            onCommand(_SeekCommand(offsetUs: methodCall.values[0].asInt64())),
          );
          return DBusMethodSuccessResponse();
        case 'SetPosition':
          if (methodCall.signature != DBusSignature('ox')) {
            return DBusMethodErrorResponse.invalidArgs();
          }
          unawaited(
            onCommand(
              _SetPositionCommand(
                trackId: methodCall.values[0].asObjectPath().value,
                positionUs: methodCall.values[1].asInt64(),
              ),
            ),
          );
          return DBusMethodSuccessResponse();
        case 'OpenUri':
          return DBusMethodSuccessResponse();
        default:
          return DBusMethodErrorResponse.unknownMethod();
      }
    }

    return DBusMethodErrorResponse.unknownInterface();
  }

  @override
  Future<DBusMethodResponse> getProperty(
    String interface,
    String name,
  ) async {
    if (interface == 'org.mpris.MediaPlayer2') {
      return switch (name) {
        'CanQuit' => DBusGetPropertyResponse(const DBusBoolean(false)),
        'CanRaise' => DBusGetPropertyResponse(const DBusBoolean(false)),
        'HasTrackList' => DBusGetPropertyResponse(const DBusBoolean(false)),
        'Identity' => DBusGetPropertyResponse(const DBusString('Navis')),
        'SupportedUriSchemes' => DBusGetPropertyResponse(DBusArray.string([])),
        'SupportedMimeTypes' => DBusGetPropertyResponse(DBusArray.string([])),
        _ => DBusMethodErrorResponse.unknownProperty(),
      };
    }

    if (interface == 'org.mpris.MediaPlayer2.Player') {
      return switch (name) {
        'PlaybackStatus' => DBusGetPropertyResponse(
          DBusString(_playbackStatus),
        ),
        'LoopStatus' => DBusGetPropertyResponse(DBusString(_loopStatus)),
        'Rate' => DBusGetPropertyResponse(DBusDouble(_rate)),
        'Shuffle' => DBusGetPropertyResponse(DBusBoolean(_shuffleEnabled)),
        'Metadata' => DBusGetPropertyResponse(_metadata),
        'Volume' => DBusGetPropertyResponse(const DBusDouble(1.0)),
        'Position' => DBusGetPropertyResponse(
          DBusInt64(_position.inMicroseconds),
        ),
        'MinimumRate' => DBusGetPropertyResponse(const DBusDouble(0.5)),
        'MaximumRate' => DBusGetPropertyResponse(const DBusDouble(2.0)),
        'CanGoNext' => DBusGetPropertyResponse(const DBusBoolean(true)),
        'CanGoPrevious' => DBusGetPropertyResponse(const DBusBoolean(true)),
        'CanPlay' => DBusGetPropertyResponse(const DBusBoolean(true)),
        'CanPause' => DBusGetPropertyResponse(const DBusBoolean(true)),
        'CanSeek' => DBusGetPropertyResponse(const DBusBoolean(true)),
        'CanControl' => DBusGetPropertyResponse(const DBusBoolean(true)),
        _ => DBusMethodErrorResponse.unknownProperty(),
      };
    }

    return DBusMethodErrorResponse.unknownProperty();
  }

  @override
  Future<DBusMethodResponse> setProperty(
    String interface,
    String name,
    DBusValue value,
  ) async {
    if (interface == 'org.mpris.MediaPlayer2.Player') {
      switch (name) {
        case 'LoopStatus':
          unawaited(
            onCommand(_SetLoopStatusCommand(loopStatus: value.asString())),
          );
          return DBusMethodSuccessResponse();
        case 'Shuffle':
          unawaited(
            onCommand(_SetShuffleCommand(enabled: value.asBoolean())),
          );
          return DBusMethodSuccessResponse();
        case 'Rate':
          unawaited(onCommand(_SetRateCommand(rate: value.asDouble())));
          return DBusMethodSuccessResponse();
        case 'Volume':
          // Volume is managed by Navis internally; ignore MPRIS volume requests.
          return DBusMethodSuccessResponse();
        default:
          return DBusMethodErrorResponse.unknownProperty();
      }
    }

    return DBusMethodErrorResponse.unknownProperty();
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    if (interface == 'org.mpris.MediaPlayer2') {
      return DBusGetAllPropertiesResponse({
        'CanQuit': const DBusBoolean(false),
        'CanRaise': const DBusBoolean(false),
        'HasTrackList': const DBusBoolean(false),
        'Identity': const DBusString('Navis'),
        'SupportedUriSchemes': DBusArray.string([]),
        'SupportedMimeTypes': DBusArray.string([]),
      });
    }

    if (interface == 'org.mpris.MediaPlayer2.Player') {
      return DBusGetAllPropertiesResponse({
        'PlaybackStatus': DBusString(_playbackStatus),
        'LoopStatus': DBusString(_loopStatus),
        'Rate': DBusDouble(_rate),
        'Shuffle': DBusBoolean(_shuffleEnabled),
        'Metadata': _metadata,
        'Volume': const DBusDouble(1.0),
        'Position': DBusInt64(_position.inMicroseconds),
        'MinimumRate': const DBusDouble(0.5),
        'MaximumRate': const DBusDouble(2.0),
        'CanGoNext': const DBusBoolean(true),
        'CanGoPrevious': const DBusBoolean(true),
        'CanPlay': const DBusBoolean(true),
        'CanPause': const DBusBoolean(true),
        'CanSeek': const DBusBoolean(true),
        'CanControl': const DBusBoolean(true),
      });
    }

    return DBusGetAllPropertiesResponse({});
  }
}
