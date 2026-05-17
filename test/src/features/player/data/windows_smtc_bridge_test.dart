import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/windows_smtc_bridge.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:smtc_windows/smtc_windows.dart';

void main() {
  group('WindowsSmtcBridge', () {
    test('maps SMTC button events to playback handler actions', () async {
      final handler = _FakePlaybackHandler(
        initialSnapshot: const PlaybackSnapshot.idle().copyWith(
          position: Duration(seconds: 20),
        ),
      );
      final client = _FakeWindowsSmtcClient();

      final bridge = WindowsSmtcBridge(
        handler: handler,
        createClient: () async => client,
        isWindowsRuntime: () => true,
      );

      await _flushAsync();
      client.emitButton(PressedButton.play);
      client.emitButton(PressedButton.pause);
      client.emitButton(PressedButton.next);
      client.emitButton(PressedButton.previous);
      client.emitButton(PressedButton.fastForward);
      client.emitButton(PressedButton.rewind);
      client.emitButton(PressedButton.stop);
      await _flushAsync();

      expect(handler.playCalls, 1);
      expect(handler.pauseCalls, 2);
      expect(handler.skipNextCalls, 1);
      expect(handler.skipPreviousCalls, 1);
      expect(handler.seekCalls, <Duration>[
        const Duration(seconds: 30),
        const Duration(seconds: 10),
      ]);

      await bridge.dispose();
      expect(client.disposed, isTrue);
    });

    test('syncs playback snapshot and media metadata to SMTC', () async {
      final initialItem = MediaItem(
        id: 'song-1',
        title: 'Track',
        artist: 'Artist',
        album: 'Album',
      );
      final handler = _FakePlaybackHandler(
        initialSnapshot: const PlaybackSnapshot.idle(),
        initialMediaItem: initialItem,
      );
      final client = _FakeWindowsSmtcClient();

      final bridge = WindowsSmtcBridge(
        handler: handler,
        createClient: () async => client,
        isWindowsRuntime: () => true,
      );

      await _flushAsync();

      handler.emitSnapshot(
        const PlaybackSnapshot.idle().copyWith(
          processingState: AudioProcessingState.ready,
          playing: true,
          duration: Duration(seconds: 100),
          position: Duration(seconds: 40),
          shuffleMode: AudioServiceShuffleMode.all,
          repeatMode: AudioServiceRepeatMode.one,
        ),
      );
      final updatedItem = initialItem.copyWith(title: 'Track 2');
      handler.emitMediaItem(updatedItem);

      await _flushAsync();

      expect(client.lastPlaybackStatus, PlaybackStatus.playing);
      expect(client.lastTimeline?.endTimeMs, 100000);
      expect(client.lastTimeline?.positionMs, 40000);
      expect(client.lastShuffleEnabled, isTrue);
      expect(client.lastRepeatMode, RepeatMode.track);
      expect(client.lastMetadata?.title, 'Track 2');

      handler.emitMediaItem(null);
      await _flushAsync();
      expect(client.clearMetadataCalls, greaterThanOrEqualTo(1));

      await bridge.dispose();
    });
  });
}

Future<void> _flushAsync() async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
}

class _FakeWindowsSmtcClient implements WindowsSmtcClient {
  final StreamController<PressedButton> _buttonController =
      StreamController<PressedButton>.broadcast();
  final StreamController<bool> _shuffleController =
      StreamController<bool>.broadcast();
  final StreamController<RepeatMode> _repeatController =
      StreamController<RepeatMode>.broadcast();

  PlaybackStatus? lastPlaybackStatus;
  PlaybackTimeline? lastTimeline;
  bool? lastShuffleEnabled;
  RepeatMode? lastRepeatMode;
  MusicMetadata? lastMetadata;
  int clearMetadataCalls = 0;
  bool disposed = false;

  @override
  Stream<PressedButton> get buttonPressStream => _buttonController.stream;

  @override
  Stream<bool> get shuffleChangeStream => _shuffleController.stream;

  @override
  Stream<RepeatMode> get repeatModeChangeStream => _repeatController.stream;

  @override
  Stream<Duration> get positionChangeStream => const Stream.empty();

  void emitButton(PressedButton button) {
    _buttonController.add(button);
  }

  @override
  Future<void> clearMetadata() async {
    clearMetadataCalls += 1;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _buttonController.close();
    await _shuffleController.close();
    await _repeatController.close();
  }

  @override
  Future<void> setPlaybackStatus(PlaybackStatus status) async {
    lastPlaybackStatus = status;
  }

  @override
  Future<void> setRepeatMode(RepeatMode mode) async {
    lastRepeatMode = mode;
  }

  @override
  Future<void> setShuffleEnabled({required bool enabled}) async {
    lastShuffleEnabled = enabled;
  }

  @override
  Future<void> updateMetadata(MusicMetadata metadata) async {
    lastMetadata = metadata;
  }

  @override
  Future<void> updateTimeline(PlaybackTimeline timeline) async {
    lastTimeline = timeline;
  }
}

class _FakePlaybackHandler implements NavisPlaybackHandler {
  _FakePlaybackHandler({
    required PlaybackSnapshot initialSnapshot,
    MediaItem? initialMediaItem,
  }) : _snapshot = initialSnapshot,
       _currentMediaItem = initialMediaItem;

  PlaybackSnapshot _snapshot;
  MediaItem? _currentMediaItem;

  final StreamController<PlaybackSnapshot> _snapshotController =
      StreamController<PlaybackSnapshot>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<MediaItem?> _mediaItemController =
      StreamController<MediaItem?>.broadcast();
  final StreamController<void> _radioErrorController =
      StreamController<void>.broadcast();

  int playCalls = 0;
  int pauseCalls = 0;
  int skipNextCalls = 0;
  int skipPreviousCalls = 0;
  final List<Duration> seekCalls = <Duration>[];

  void emitSnapshot(PlaybackSnapshot snapshot) {
    _snapshot = snapshot;
    _snapshotController.add(snapshot);
  }

  void emitMediaItem(MediaItem? item) {
    _currentMediaItem = item;
    _mediaItemController.add(item);
  }

  @override
  MediaItem? get currentMediaItem => _currentMediaItem;

  @override
  Stream<MediaItem?> get mediaItemStream => _mediaItemController.stream;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<void> get radioStreamErrorStream => _radioErrorController.stream;

  @override
  Stream<PlaybackLoadFailure> get loadFailureStream =>
      const Stream<PlaybackLoadFailure>.empty();

  @override
  Stream<ManualTrackChangeCue> get manualTrackChangeCueStream =>
      const Stream<ManualTrackChangeCue>.empty();

  @override
  PlaybackSnapshot get snapshot => _snapshot;

  @override
  Stream<PlaybackSnapshot> get snapshotStream => _snapshotController.stream;

  @override
  Future<void> addToQueue(
    List<String> songIds, {
    bool expandMatchFlows = true,
  }) async {}

  @override
  Future<void> applyRuntimeSettings() async {}

  @override
  Future<void> clearQueue() async {}

  @override
  Future<void> pause() async {
    pauseCalls += 1;
  }

  @override
  Future<void> play() async {
    playCalls += 1;
  }

  @override
  Future<void> playFromIndex(int index) async {}

  @override
  Future<void> playNext(
    List<String> songIds, {
    bool expandMatchFlows = true,
  }) async {}

  @override
  Future<void> playRadioStream({
    required String stationId,
    required String stationName,
    required String streamUrl,
    String? homePageUrl,
  }) async {}

  @override
  Future<void> removeAt(int index) async {}

  @override
  Future<void> reorderQueue(int oldIndex, int newIndex) async {}

  @override
  Future<void> replaceQueue(
    List<String> songIds, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
  }) async {}

  @override
  Future<void> replaceQueueWithData(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
  }) async {}

  @override
  Future<void> seek(Duration position) async {
    seekCalls.add(position);
  }

  @override
  Future<void> setPlaybackSpeed(double speed) async {}

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {}

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> skipToNext() async {
    skipNextCalls += 1;
  }

  @override
  Future<void> skipToPrevious() async {
    skipPreviousCalls += 1;
  }

  @override
  Future<void> stopRadio() async {}

  @override
  Future<void> syncSongLikedState(String songId, {required bool liked}) async {}

  @override
  Future<void> toggleLike() async {}

  @override
  void updateRadioMetadata({
    String? title,
    String? artist,
    String? artUrl,
  }) {}

  @override
  void registerPreferredMixCallback(
    Future<void> Function(String seedSongId) callback,
  ) {}
  @override
  void registerPreferredMixToggleCallback(
    Future<void> Function(String seedSongId) callback,
  ) {}

  @override
  Future<void> waitUntilReady() async {}
}
