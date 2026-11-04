import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations_en.dart';
import 'package:navis/src/features/player/data/macos_dock_menu_bridge.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';

import '../../../../helpers/fake_playback_handler.dart';

class _Handler extends InertPlaybackHandler {
  final _snapshots = StreamController<PlaybackSnapshot>.broadcast();
  final _items = StreamController<MediaItem?>.broadcast();
  final calls = <String>[];
  PlaybackSnapshot _snapshot = const PlaybackSnapshot.idle();
  MediaItem? _item;

  @override
  PlaybackSnapshot get snapshot => _snapshot;
  @override
  MediaItem? get currentMediaItem => _item;
  @override
  Stream<PlaybackSnapshot> get snapshotStream => _snapshots.stream;
  @override
  Stream<MediaItem?> get mediaItemStream => _items.stream;

  void emitSnapshot(PlaybackSnapshot snapshot) {
    _snapshot = snapshot;
    _snapshots.add(snapshot);
  }

  void emitItem(MediaItem? item) {
    _item = item;
    _items.add(item);
  }

  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> skipToNext() async => calls.add('skipToNext');
  @override
  Future<void> skipToPrevious() async => calls.add('skipToPrevious');
  @override
  Future<void> stopRadio() async => calls.add('stopRadio');
}

const _station = RadioStationMetadata(
  stationId: 'r1',
  stationName: 'Radio One',
  streamUrl: 'https://example.invalid/stream',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel(MacosDockMenuBridge.channelName);

  late _Handler handler;
  late List<Map<Object?, Object?>> updates;
  late MacosDockMenuBridge bridge;

  setUp(() async {
    handler = _Handler();
    updates = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'update') {
        updates.add(Map<Object?, Object?>.of(call.arguments as Map));
      }
      return null;
    });
    bridge = MacosDockMenuBridge(
      handler: handler,
      localizations: AppLocalizationsEn(),
    );
    await pumpEventQueue();
  });

  tearDown(() async {
    await bridge.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> command(String action) => messenger.handlePlatformMessage(
    channel.name,
    channel.codec.encodeMethodCall(
      MethodCall('command', <String, Object?>{'action': action}),
    ),
    (_) {},
  );

  test('pushes the empty state first, with labels', () {
    expect(updates, hasLength(1));
    expect(updates.single, containsPair('hasItem', false));
    expect(updates.single, containsPair('playPauseLabel', 'Play'));
    expect(updates.single, containsPair('nextLabel', 'Next'));
    expect(updates.single, containsPair('previousLabel', 'Previous'));
  });

  test('pushes the track and playing state, once per change', () async {
    handler.emitItem(const MediaItem(id: '1', title: 'Song', artist: 'Band'));
    await pumpEventQueue();
    // Progress ticks and repeated identical snapshots change nothing shown.
    handler.emitSnapshot(
      handler.snapshot.copyWith(position: const Duration(seconds: 3)),
    );
    handler.emitSnapshot(
      handler.snapshot.copyWith(position: const Duration(seconds: 4)),
    );
    await pumpEventQueue();
    expect(updates, hasLength(2));
    expect(updates.last, containsPair('title', 'Song'));
    expect(updates.last, containsPair('artist', 'Band'));
    expect(updates.last, containsPair('hasItem', true));

    handler.emitSnapshot(handler.snapshot.copyWith(playing: true));
    await pumpEventQueue();
    expect(updates, hasLength(3));
    expect(updates.last, containsPair('playing', true));
    expect(updates.last, containsPair('playPauseLabel', 'Pause'));
  });

  test('dispose empties the native menu', () async {
    handler.emitItem(const MediaItem(id: '1', title: 'Song'));
    await pumpEventQueue();
    await bridge.dispose();
    expect(updates.last, containsPair('hasItem', false));
  });

  group('commands', () {
    test('playPause follows the playing state', () async {
      await command('playPause');
      handler.emitSnapshot(handler.snapshot.copyWith(playing: true));
      await command('playPause');
      expect(handler.calls, ['play', 'pause']);
    });

    test('next and previous skip', () async {
      await command('next');
      await command('previous');
      expect(handler.calls, ['skipToNext', 'skipToPrevious']);
    });

    test(
      'in radio mode next leaves the station and previous is ignored',
      () async {
        handler.emitSnapshot(handler.snapshot.copyWith(radioStation: _station));
        await command('next');
        await command('previous');
        expect(handler.calls, ['stopRadio']);
      },
    );

    test('an unknown action does nothing', () async {
      await command('explode');
      expect(handler.calls, isEmpty);
    });
  });
}
