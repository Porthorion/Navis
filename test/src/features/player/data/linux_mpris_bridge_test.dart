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
    emitPosition(position);
    await pumpEventQueue();
  }

  Future<void> close() async {
    await snapshots.close();
    await positions.close();
    await items.close();
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
  PlaybackAdjustments get playbackAdjustments => const PlaybackAdjustments();
  @override
  Stream<PlaybackAdjustments> get playbackAdjustmentsStream =>
      const Stream.empty();
}
