import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/data/linux_mpris_bridge.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';

void main() {
  late _Handler handler;
  late _Client client;
  late LinuxMprisBridge bridge;

  setUp(() async {
    handler = _Handler();
    client = _Client();
    bridge = LinuxMprisBridge(
      handler: handler,
      isLinuxRuntime: () => true,
      createClient: () => client,
    );
    await pumpEventQueue();
    handler.emitSnapshot(
      handler.snapshot.copyWith(position: const Duration(seconds: 10)),
    );
    await pumpEventQueue();
    client.seeked.clear();
  });

  tearDown(() async {
    await bridge.dispose();
    await handler.close();
  });

  test('introspection XML preserves the MPRIS protocol surface', () {
    final xml = client.object
        .introspect()
        .map((interface) => interface.toXml().toXmlString(pretty: true))
        .join('\n');
    expect(xml, '''
<interface name="org.mpris.MediaPlayer2">
  <method name="Raise"/>
  <method name="Quit"/>
  <property name="CanQuit" type="b" access="read"/>
  <property name="CanRaise" type="b" access="read"/>
  <property name="HasTrackList" type="b" access="read"/>
  <property name="Identity" type="s" access="read"/>
  <property name="SupportedUriSchemes" type="as" access="read"/>
  <property name="SupportedMimeTypes" type="as" access="read"/>
</interface>
<interface name="org.mpris.MediaPlayer2.Player">
  <method name="Next"/>
  <method name="Previous"/>
  <method name="Pause"/>
  <method name="PlayPause"/>
  <method name="Stop"/>
  <method name="Play"/>
  <method name="Seek">
    <arg name="Offset" type="x" direction="in"/>
  </method>
  <method name="SetPosition">
    <arg name="TrackId" type="o" direction="in"/>
    <arg name="Position" type="x" direction="in"/>
  </method>
  <method name="OpenUri">
    <arg name="Uri" type="s" direction="in"/>
  </method>
  <signal name="Seeked">
    <arg name="Position" type="x"/>
  </signal>
  <property name="PlaybackStatus" type="s" access="read"/>
  <property name="LoopStatus" type="s" access="readwrite"/>
  <property name="Rate" type="d" access="readwrite"/>
  <property name="Shuffle" type="b" access="readwrite"/>
  <property name="Metadata" type="a{sv}" access="read"/>
  <property name="Volume" type="d" access="readwrite"/>
  <property name="Position" type="x" access="read"/>
  <property name="MinimumRate" type="d" access="read"/>
  <property name="MaximumRate" type="d" access="read"/>
  <property name="CanGoNext" type="b" access="read"/>
  <property name="CanGoPrevious" type="b" access="read"/>
  <property name="CanPlay" type="b" access="read"/>
  <property name="CanPause" type="b" access="read"/>
  <property name="CanSeek" type="b" access="read"/>
  <property name="CanControl" type="b" access="read"/>
</interface>''');
  });

  Future<void> expectProperties(
    String interface,
    Map<String, DBusValue> values,
  ) async {
    final all = await client.object.getAllProperties(interface);
    expect(all.returnValues, DBusGetAllPropertiesResponse(values).returnValues);
    for (final entry in values.entries) {
      final single = await client.object.getProperty(interface, entry.key);
      expect(single.returnValues, [
        DBusVariant(entry.value),
      ], reason: entry.key);
    }
  }

  test('Get and GetAll preserve the root values', () async {
    await expectProperties('org.mpris.MediaPlayer2', {
      'CanQuit': const DBusBoolean(false),
      'CanRaise': const DBusBoolean(false),
      'HasTrackList': const DBusBoolean(false),
      'Identity': const DBusString('Navis'),
      'SupportedUriSchemes': DBusArray.string([]),
      'SupportedMimeTypes': DBusArray.string([]),
    });
  });

  test('Get and GetAll preserve the paused player values', () async {
    await expectProperties('org.mpris.MediaPlayer2.Player', {
      'PlaybackStatus': const DBusString('Paused'),
      'LoopStatus': const DBusString('None'),
      'Rate': const DBusDouble(1),
      'Shuffle': const DBusBoolean(false),
      'Metadata': DBusDict.stringVariant({
        'mpris:trackid': DBusObjectPath('/org/mpris/MediaPlayer2/Track/song_1'),
        'xesam:title': const DBusString('First'),
      }),
      'Volume': const DBusDouble(1),
      'Position': const DBusInt64(10000000),
      'MinimumRate': const DBusDouble(0.5),
      'MaximumRate': const DBusDouble(2),
      'CanGoNext': const DBusBoolean(false),
      'CanGoPrevious': const DBusBoolean(false),
      'CanPlay': const DBusBoolean(true),
      'CanPause': const DBusBoolean(false),
      'CanSeek': const DBusBoolean(false),
      'CanControl': const DBusBoolean(true),
    });
  });

  test('property reads follow playback, rate and track-time updates', () async {
    handler.emitSnapshot(
      handler.snapshot.copyWith(
        queueSongIds: ['song-0', 'song-1', 'song-2'],
        currentIndex: 1,
        playing: true,
        repeatMode: AudioServiceRepeatMode.all,
        shuffleMode: AudioServiceShuffleMode.all,
        duration: const Duration(minutes: 3),
        position: const Duration(microseconds: 12345678),
      ),
    );
    handler.emitAdjustments(const PlaybackAdjustments(speed: 1.75));
    await pumpEventQueue();
    await expectProperties('org.mpris.MediaPlayer2.Player', {
      'PlaybackStatus': const DBusString('Playing'),
      'LoopStatus': const DBusString('Playlist'),
      'Rate': const DBusDouble(1.75),
      'Shuffle': const DBusBoolean(true),
      'Metadata': DBusDict.stringVariant({
        'mpris:trackid': DBusObjectPath('/org/mpris/MediaPlayer2/Track/song_1'),
        'xesam:title': const DBusString('First'),
      }),
      'Volume': const DBusDouble(1),
      'Position': const DBusInt64(12345678),
      'MinimumRate': const DBusDouble(0.5),
      'MaximumRate': const DBusDouble(2),
      'CanGoNext': const DBusBoolean(true),
      'CanGoPrevious': const DBusBoolean(true),
      'CanPlay': const DBusBoolean(false),
      'CanPause': const DBusBoolean(true),
      'CanSeek': const DBusBoolean(true),
      'CanControl': const DBusBoolean(true),
    });
  });

  test('unknown property and interface responses remain distinct', () async {
    for (final interface in [
      'org.mpris.MediaPlayer2',
      'org.mpris.MediaPlayer2.Player',
      'unknown',
    ]) {
      final response = await client.object.getProperty(interface, 'unknown');
      expect(response, isA<DBusMethodErrorResponse>());
      expect(
        (response as DBusMethodErrorResponse).errorName,
        'org.freedesktop.DBus.Error.UnknownProperty',
      );
    }
    final all = await client.object.getAllProperties('unknown');
    expect(all.returnValues, DBusGetAllPropertiesResponse({}).returnValues);
    final method = await client.object.handleMethodCall(
      const DBusMethodCall(
        sender: ':fixture',
        interface: 'unknown',
        name: 'Play',
        values: [],
      ),
    );
    expect(
      (method as DBusMethodErrorResponse).errorName,
      'org.freedesktop.DBus.Error.UnknownInterface',
    );
  });

  test('paused UI timeline seek emits Seeked in microseconds', () async {
    handler.emitPosition(const Duration(seconds: 45));
    await pumpEventQueue();
    expect(client.seeked, [const DBusInt64(45000000)]);

    final response = await client.object.getProperty(
      'org.mpris.MediaPlayer2.Player',
      'Position',
    );
    expect(response.returnValues, [const DBusVariant(DBusInt64(45000000))]);

    handler.emitSnapshot(handler.snapshot);
    handler.emitPosition(const Duration(seconds: 45));
    await pumpEventQueue();
    expect(client.seeked, hasLength(1));
  });

  test('paused handler seek emits once after interleaved timeline updates', () async {
    await handler.seek(const Duration(seconds: 45));
    expect(client.seeked, [const DBusInt64(45000000)]);
    final response = await client.object.getProperty(
      'org.mpris.MediaPlayer2.Player',
      'Position',
    );
    expect(response.returnValues, [const DBusVariant(DBusInt64(45000000))]);

    // A second completed seek is independent, even within the same event burst.
    await handler.seek(const Duration(seconds: 10));
    await handler.seek(const Duration(seconds: 45));
    await handler.seek(const Duration(seconds: 46));
    await handler.seek(const Duration(seconds: 46));
    expect(client.seeked, [
      const DBusInt64(45000000),
      const DBusInt64(10000000),
      const DBusInt64(45000000),
      const DBusInt64(46000000),
      const DBusInt64(46000000),
    ]);
  });

  test(
    'failed handler seek and a track switch do not report completion',
    () async {
      handler.emitSnapshot(
        handler.snapshot.copyWith(
          pendingSeekPosition: const Duration(seconds: 45),
        ),
      );
      await pumpEventQueue();
      handler.emitSnapshot(
        handler.snapshot.copyWith(pendingSeekPosition: null),
      );
      await pumpEventQueue();
      expect(client.seeked, isEmpty);

      handler.emitSnapshot(
        handler.snapshot.copyWith(
          pendingSeekPosition: const Duration(seconds: 45),
        ),
      );
      await pumpEventQueue();
      handler.items.add(const MediaItem(id: 'song-2', title: 'Second'));
      await pumpEventQueue();
      handler.emitSnapshot(handler.snapshot);
      await pumpEventQueue();
      handler.emitSnapshot(
        handler.snapshot.copyWith(
          position: const Duration(seconds: 45),
          pendingSeekPosition: null,
        ),
      );
      await pumpEventQueue();
      expect(client.seeked, isEmpty);
    },
  );

  test(
    'playing UI timeline seek emits Seeked without a structural snapshot',
    () async {
      handler.emitSnapshot(handler.snapshot.copyWith(playing: true));
      await pumpEventQueue();
      handler.emitPosition(const Duration(seconds: 60));
      await pumpEventQueue();
      expect(client.seeked, [const DBusInt64(60000000)]);
    },
  );

  test(
    'MPRIS seek emits once when the handler publishes its timeline',
    () async {
      await client.object.handleMethodCall(
        const DBusMethodCall(
          sender: ':fixture',
          interface: 'org.mpris.MediaPlayer2.Player',
          name: 'Seek',
          values: [DBusInt64(35000000)],
        ),
      );
      await pumpEventQueue();
      expect(client.seeked, [const DBusInt64(45000000)]);
    },
  );

  test('ordinary playing timeline ticks do not emit Seeked', () async {
    handler.emitSnapshot(handler.snapshot.copyWith(playing: true));
    await pumpEventQueue();
    for (var second = 11; second < 16; second++) {
      handler.emitPosition(Duration(seconds: second));
      await pumpEventQueue();
    }
    expect(client.seeked, isEmpty);
  });

  test('track changes do not emit Seeked', () async {
    handler.items.add(const MediaItem(id: 'song-2', title: 'Second'));
    await pumpEventQueue();
    handler.emitPosition(Duration.zero);
    await pumpEventQueue();
    expect(client.seeked, isEmpty);
  });
}

class _Client extends Fake implements DBusClient {
  late DBusObject object;
  final seeked = <DBusValue>[];

  @override
  Future<void> registerObject(DBusObject object) async {
    this.object = object;
    object.client = this;
  }

  @override
  Future<DBusRequestNameReply> requestName(
    String name, {
    Set<DBusRequestNameFlag> flags = const {},
  }) async => DBusRequestNameReply.primaryOwner;

  @override
  Future<void> emitSignal({
    String? destination,
    required DBusObjectPath path,
    required String interface,
    required String name,
    Iterable<DBusValue> values = const [],
  }) async {
    if (name == 'Seeked') seeked.add(values.single);
  }

  @override
  Future<void> close() async {}
}

class _Handler extends Fake implements NavisPlaybackHandler {
  PlaybackSnapshot _snapshot = const PlaybackSnapshot.idle().copyWith(
    queueSongIds: ['song-1'],
    currentIndex: 0,
    processingState: AudioProcessingState.ready,
  );
  final snapshots = StreamController<PlaybackSnapshot>.broadcast();
  final positions = StreamController<Duration>.broadcast();
  final items = StreamController<MediaItem?>.broadcast();
  PlaybackAdjustments _adjustments = const PlaybackAdjustments();
  final adjustmentChanges = StreamController<PlaybackAdjustments>.broadcast();

  void emitAdjustments(PlaybackAdjustments adjustments) {
    _adjustments = adjustments;
    adjustmentChanges.add(adjustments);
  }

  void emitSnapshot(PlaybackSnapshot snapshot) {
    _snapshot = snapshot;
    snapshots.add(snapshot);
  }

  void emitPosition(Duration position) {
    _snapshot = _snapshot.copyWith(position: position);
    positions.add(position);
  }

  @override
  Future<void> seek(Duration position) async {
    final before = snapshot.position;
    emitSnapshot(snapshot.copyWith(pendingSeekPosition: position));
    await pumpEventQueue(times: 1);
    for (var i = 0; i < 2; i++) {
      emitPosition(position);
      await pumpEventQueue(times: 1);
      emitSnapshot(snapshot.copyWith(position: before));
      await pumpEventQueue(times: 1);
    }
    emitPosition(position);
    await pumpEventQueue(times: 1);
    emitSnapshot(snapshot.copyWith(pendingSeekPosition: null));
    await pumpEventQueue(times: 1);
  }

  Future<void> close() async {
    await snapshots.close();
    await positions.close();
    await items.close();
    await adjustmentChanges.close();
  }

  @override
  PlaybackSnapshot get snapshot => _snapshot;
  @override
  Stream<PlaybackSnapshot> get snapshotStream => snapshots.stream;
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  MediaItem? get currentMediaItem =>
      const MediaItem(id: 'song-1', title: 'First');
  @override
  Stream<MediaItem?> get mediaItemStream => items.stream;
  @override
  PlaybackAdjustments get playbackAdjustments => _adjustments;
  @override
  Stream<PlaybackAdjustments> get playbackAdjustmentsStream =>
      adjustmentChanges.stream;
}
