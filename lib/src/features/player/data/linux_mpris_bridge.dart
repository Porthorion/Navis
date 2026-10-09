import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/system_media_art.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';
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
  new({
    required this._handler,
    bool Function()? isLinuxRuntime,
    DBusClient Function()? createClient,
  }) : _isLinuxRuntime = isLinuxRuntime ?? _defaultIsLinuxRuntime,
       _createClient = createClient ?? DBusClient.session {
    unawaited(_initialize());
  }

  final NavisPlaybackHandler _handler;
  final bool Function() _isLinuxRuntime;
  final DBusClient Function() _createClient;

  DBusClient? _dbusClient;
  _NavisMprisObject? _mprisObject;
  StreamSubscription<PlaybackSnapshot>? _snapshotSubscription;
  StreamSubscription<MediaItem?>? _mediaItemSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<PlaybackAdjustments>? _adjustmentsSubscription;

  bool _isDisposed = false;

  Future<void> _initialize() async {
    if (!_isLinuxRuntime() || _isDisposed) {
      return;
    }

    try {
      final client = _createClient();
      _dbusClient = client;

      final obj = _NavisMprisObject(onCommand: _handleCommand);
      _mprisObject = obj;

      await client.registerObject(obj);
      await _requestMprisBusName(client);

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

    _positionSubscription = _handler.positionStream.listen((position) {
      _mprisObject?.updatePosition(position);
    });

    // MPRIS clients extrapolate Position with Rate, so publish every speed
    // change, including ones made in the app, not only MPRIS SetRate.
    _adjustmentsSubscription = _handler.playbackAdjustmentsStream.listen(
      (adjustments) => _mprisObject?.updateRate(adjustments.speed),
    );
    _mprisObject?.updateRate(_handler.playbackAdjustments.speed);

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
          await _handler.stop();
        case _NextCommand():
          await _handler.skipToNext();
        case _PreviousCommand():
          await _handler.skipToPrevious();
        case _SeekCommand(:final offsetUs):
          final base = _handler.snapshot.position;
          final target = base + Duration(microseconds: offsetUs);
          final clamped = target < Duration.zero ? Duration.zero : target;
          await _seekFromMpris(clamped);
        case _SetPositionCommand(:final trackId, positionUs: final posUs):
          final obj = _mprisObject;
          if (obj == null || trackId != obj.currentTrackId) {
            return;
          }
          final dur = _handler.snapshot.duration;
          final target = Duration(microseconds: posUs);
          if (target < Duration.zero || (dur > Duration.zero && target > dur)) {
            return;
          }
          await _seekFromMpris(target);
        case _SetLoopStatusCommand(:final loopStatus):
          final repeatMode = switch (loopStatus) {
            'Track' => AudioServiceRepeatMode.one,
            'Playlist' => AudioServiceRepeatMode.all,
            _ => AudioServiceRepeatMode.none,
          };
          await _handler.setRepeatMode(repeatMode);
        case _SetShuffleCommand(:final enabled):
          await _handler.setShuffleMode(
            enabled
                ? AudioServiceShuffleMode.all
                : AudioServiceShuffleMode.none,
          );
        case _SetRateCommand(:final rate):
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

  Future<void> _seekFromMpris(Duration position) async {
    final obj = _mprisObject;
    if (obj == null) return;
    obj._systemSeekDepth++;
    try {
      await _handler.seek(position);
      // A concurrent dispose must prevent signaling on a closed client.
      unawaited(_mprisObject?.emitSeeked(position));
    } finally {
      obj._systemSeekDepth--;
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
      capabilities: navisOsControlCapabilitiesForSnapshot(snapshot),
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
      artUrl: systemArtUrl(item),
      duration: item.duration,
    );
  }

  Future<void> dispose() async {
    _isDisposed = true;
    await _snapshotSubscription?.cancel();
    await _mediaItemSubscription?.cancel();
    await _positionSubscription?.cancel();
    await _adjustmentsSubscription?.cancel();
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

Future<void> _requestMprisBusName(DBusClient client) async {
  final reply = await client.requestName(
    'org.mpris.MediaPlayer2.navis',
    flags: {DBusRequestNameFlag.doNotQueue},
  );
  if (reply == DBusRequestNameReply.primaryOwner ||
      reply == DBusRequestNameReply.alreadyOwner) {
    return;
  }
  await client.requestName(
    'org.mpris.MediaPlayer2.navis.instance$pid',
    flags: {DBusRequestNameFlag.doNotQueue},
  );
}

/// Converts an arbitrary song ID to a valid D-Bus object path segment.
/// Object path components must match `[A-Za-z0-9_]+`.
String _sanitizeTrackId(String songId) {
  final sanitized = songId.replaceAll(RegExp('[^A-Za-z0-9_]'), '_');
  final safe = sanitized.isEmpty ? 'unknown' : sanitized;
  return '/org/mpris/MediaPlayer2/Track/$safe';
}

// ---- Command types ----------------------------------------------------------

sealed class _MprisCommand;

final class _PlayCommand extends _MprisCommand;

final class _PauseCommand extends _MprisCommand;

final class _PlayPauseCommand extends _MprisCommand;

final class _StopCommand extends _MprisCommand;

final class _NextCommand extends _MprisCommand;

final class _PreviousCommand extends _MprisCommand;

final class _SeekCommand extends _MprisCommand {
  new({required this.offsetUs});
  final int offsetUs;
}

final class _SetPositionCommand extends _MprisCommand {
  new({required this.trackId, required this.positionUs});
  final String trackId;
  final int positionUs;
}

final class _SetLoopStatusCommand extends _MprisCommand {
  new({required this.loopStatus});
  final String loopStatus;
}

final class _SetShuffleCommand extends _MprisCommand {
  new({required this.enabled});
  final bool enabled;
}

final class _SetRateCommand extends _MprisCommand {
  new({required this.rate});
  final double rate;
}

// ---- D-Bus MPRIS object ----------------------------------------------------

/// D-Bus object that implements the full `org.mpris.MediaPlayer2` and
/// `org.mpris.MediaPlayer2.Player` interfaces, including working `Seek`,
/// `SetPosition`, `LoopStatus`, and `Shuffle` support.
class _NavisMprisObject extends DBusObject {
  new({required this.onCommand})
    : super(DBusObjectPath('/org/mpris/MediaPlayer2'));

  final Future<void> Function(_MprisCommand) onCommand;

  // ---- State (updated by LinuxMprisBridge) ----
  String _playbackStatus = 'Stopped';
  DBusValue _metadata = DBusDict.stringVariant({});
  Duration _position = Duration.zero;
  bool _shuffleEnabled = false;
  String _loopStatus = 'None';
  double _rate = 1;
  NavisOsControlCapabilities _capabilities = NavisOsControlCapabilities.idle;

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
  int _systemSeekDepth = 0;
  String? _lastSyncedTrackId;

  // ---- State update API used by LinuxMprisBridge --------------------------

  void syncState({
    required String status,
    required Duration position,
    required String loopStatus,
    required bool shuffleEnabled,
    required NavisOsControlCapabilities capabilities,
  }) {
    updatePosition(position);
    _wasPlaying = status == 'Playing';

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
    if (capabilities.canSkipNext != _capabilities.canSkipNext) {
      changed['CanGoNext'] = DBusBoolean(capabilities.canSkipNext);
    }
    if (capabilities.canSkipPrevious != _capabilities.canSkipPrevious) {
      changed['CanGoPrevious'] = DBusBoolean(capabilities.canSkipPrevious);
    }
    if (capabilities.canPlay != _capabilities.canPlay) {
      changed['CanPlay'] = DBusBoolean(capabilities.canPlay);
    }
    if (capabilities.canPause != _capabilities.canPause) {
      changed['CanPause'] = DBusBoolean(capabilities.canPause);
    }
    if (capabilities.canSeek != _capabilities.canSeek) {
      changed['CanSeek'] = DBusBoolean(capabilities.canSeek);
    }
    _capabilities = capabilities;

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

  void updatePosition(Duration position) {
    // Detect position jumps that weren't MPRIS-initiated — e.g. the user
    // seeked via the Navis UI while the media bar was showing. The MPRIS
    // spec requires a Seeked signal whenever position deviates from the
    // expected extrapolation (lastPos + elapsed * rate).
    //
    // Guard: only check when the same track is selected so we don't
    // false-fire on a normal track advance (where updateMetadata() updates
    // currentTrackId before syncState() is called, making IDs differ).
    if (_systemSeekDepth == 0 &&
        currentTrackId != null &&
        currentTrackId == _lastSyncedTrackId) {
      final elapsed = DateTime.now().difference(_lastSyncedTime);
      final expectedUs =
          _lastSyncedPosition.inMicroseconds +
          (_wasPlaying ? (elapsed.inMicroseconds * _rate).round() : 0);
      final expectedPosition = Duration(microseconds: math.max(0, expectedUs));
      if ((position - expectedPosition).abs() > _seekDetectionThreshold) {
        unawaited(emitSeeked(position));
      }
    }

    _lastSyncedPosition = position;
    _lastSyncedTime = DateTime.now();
    _lastSyncedTrackId = currentTrackId;

    // Position is not part of PropertiesChanged (clients poll it per spec).
    _position = position;
  }

  Future<void> emitSeeked(Duration position) {
    _lastSyncedPosition = position;
    _lastSyncedTime = DateTime.now();
    _lastSyncedTrackId = currentTrackId;
    return emitSignal('org.mpris.MediaPlayer2.Player', 'Seeked', [
      DBusInt64(position.inMicroseconds),
    ]);
  }

  late final _properties = <String, Map<String, _MprisProperty>>{
    'org.mpris.MediaPlayer2': {
      'CanQuit': _MprisProperty('b', () => const DBusBoolean(false)),
      'CanRaise': _MprisProperty('b', () => const DBusBoolean(false)),
      'HasTrackList': _MprisProperty('b', () => const DBusBoolean(false)),
      'Identity': _MprisProperty('s', () => const DBusString('Navis')),
      'SupportedUriSchemes': _MprisProperty('as', () => DBusArray.string([])),
      'SupportedMimeTypes': _MprisProperty('as', () => DBusArray.string([])),
    },
    'org.mpris.MediaPlayer2.Player': {
      'PlaybackStatus': _MprisProperty('s', () => DBusString(_playbackStatus)),
      'LoopStatus': _MprisProperty(
        's',
        () => DBusString(_loopStatus),
        access: DBusPropertyAccess.readwrite,
      ),
      'Rate': _MprisProperty(
        'd',
        () => DBusDouble(_rate),
        access: DBusPropertyAccess.readwrite,
      ),
      'Shuffle': _MprisProperty(
        'b',
        () => DBusBoolean(_shuffleEnabled),
        access: DBusPropertyAccess.readwrite,
      ),
      'Metadata': _MprisProperty('a{sv}', () => _metadata),
      'Volume': _MprisProperty(
        'd',
        () => const DBusDouble(1),
        access: DBusPropertyAccess.readwrite,
      ),
      'Position': _MprisProperty(
        'x',
        () => DBusInt64(_position.inMicroseconds),
      ),
      'MinimumRate': _MprisProperty('d', () => const DBusDouble(0.5)),
      'MaximumRate': _MprisProperty('d', () => const DBusDouble(2)),
      'CanGoNext': _MprisProperty(
        'b',
        () => DBusBoolean(_capabilities.canSkipNext),
      ),
      'CanGoPrevious': _MprisProperty(
        'b',
        () => DBusBoolean(_capabilities.canSkipPrevious),
      ),
      'CanPlay': _MprisProperty('b', () => DBusBoolean(_capabilities.canPlay)),
      'CanPause': _MprisProperty(
        'b',
        () => DBusBoolean(_capabilities.canPause),
      ),
      'CanSeek': _MprisProperty('b', () => DBusBoolean(_capabilities.canSeek)),
      'CanControl': _MprisProperty('b', () => const DBusBoolean(true)),
    },
  };

  List<DBusIntrospectProperty> _introspectProperties(String interface) => [
    for (final entry in _properties[interface]!.entries)
      DBusIntrospectProperty(
        entry.key,
        DBusSignature(entry.value.signature),
        access: entry.value.access,
      ),
  ];

  // ---- DBusObject overrides ------------------------------------------------

  @override
  List<DBusIntrospectInterface> introspect() {
    return [
      DBusIntrospectInterface(
        'org.mpris.MediaPlayer2',
        methods: [DBusIntrospectMethod('Raise'), DBusIntrospectMethod('Quit')],
        properties: _introspectProperties('org.mpris.MediaPlayer2'),
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
        properties: _introspectProperties('org.mpris.MediaPlayer2.Player'),
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
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final property = _properties[interface]?[name];
    return property == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(property.read());
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
          unawaited(onCommand(_SetShuffleCommand(enabled: value.asBoolean())));
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
    final properties = _properties[interface];
    return DBusGetAllPropertiesResponse({
      if (properties != null)
        for (final entry in properties.entries) entry.key: entry.value.read(),
    });
  }
}

class _MprisProperty {
  const new(this.signature, this.read, {this.access = DBusPropertyAccess.read});

  final String signature;
  final DBusPropertyAccess access;
  final DBusValue Function() read;
}
