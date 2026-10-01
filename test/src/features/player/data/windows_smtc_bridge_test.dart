import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/windows_smtc_bridge.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis_windows_smtc/navis_windows_smtc.dart';

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
      expect(handler.pauseCalls, 1);
      expect(handler.stopCalls, 1);
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
          queueSongIds: <String>['song-0', 'song-1', 'song-2'],
          currentSongId: 'song-1',
          currentIndex: 1,
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

      expect(client.lastState?.enabled, isTrue);
      expect(client.lastState?.status, PlaybackStatus.playing);
      expect(client.lastState?.timeline.endTimeMs, 100000);
      expect(client.lastState?.timeline.positionMs, 40000);
      expect(client.lastState?.shuffleEnabled, isTrue);
      expect(client.lastState?.repeatMode, RepeatMode.track);
      expect(client.lastState?.config.playEnabled, isFalse);
      expect(client.lastState?.config.pauseEnabled, isTrue);
      expect(client.lastState?.config.stopEnabled, isTrue);
      expect(client.lastState?.config.nextEnabled, isTrue);
      expect(client.lastState?.config.prevEnabled, isTrue);
      expect(client.lastState?.config.fastForwardEnabled, isTrue);
      expect(client.lastState?.config.rewindEnabled, isTrue);
      expect(client.lastState?.metadata?.title, 'Track 2');

      handler.emitMediaItem(null);
      await _flushAsync();
      expect(client.lastState?.metadata, isNull);

      await bridge.dispose();
    });

    test(
      'keeps text metadata when artwork is not a usable network URI',
      () async {
        final handler = _FakePlaybackHandler(
          initialSnapshot: const PlaybackSnapshot.idle().copyWith(
            queueSongIds: <String>['song-1'],
            currentSongId: 'song-1',
            currentIndex: 0,
            processingState: AudioProcessingState.ready,
            playing: true,
          ),
          initialMediaItem: MediaItem(
            id: 'song-1',
            title: 'Track',
            artist: 'Artist',
            artUri: Uri.parse('file:///not-safe-for-smtc.jpg'),
          ),
        );
        final client = _FakeWindowsSmtcClient();
        final bridge = WindowsSmtcBridge(
          handler: handler,
          createClient: () async => client,
          isWindowsRuntime: () => true,
        );

        await _flushAsync();

        expect(client.lastState?.metadata?.title, 'Track');
        expect(client.lastState?.metadata?.thumbnail, isNull);
        await bridge.dispose();
      },
    );

    test('disables unavailable controls for radio snapshots', () async {
      final handler = _FakePlaybackHandler(
        initialSnapshot: const PlaybackSnapshot.idle(),
        initialMediaItem: const MediaItem(
          id: 'radio:radio-1',
          title: 'Radio',
        ),
      );
      final client = _FakeWindowsSmtcClient();

      final bridge = WindowsSmtcBridge(
        handler: handler,
        createClient: () async => client,
        isWindowsRuntime: () => true,
      );
      await _flushAsync();

      handler.emitSnapshot(
        const PlaybackSnapshot(
          queueSongIds: <String>[],
          currentSongId: null,
          currentIndex: null,
          playing: true,
          processingState: AudioProcessingState.ready,
          position: Duration.zero,
          duration: Duration.zero,
          bufferedPosition: Duration.zero,
          shuffleMode: AudioServiceShuffleMode.none,
          repeatMode: AudioServiceRepeatMode.none,
          radioStation: RadioStationMetadata(
            stationId: 'radio-1',
            stationName: 'Radio',
            streamUrl: 'https://example.com/stream',
          ),
        ),
      );
      await _flushAsync();

      expect(client.lastState?.enabled, isTrue);
      expect(client.lastState?.config.playEnabled, isFalse);
      expect(client.lastState?.config.pauseEnabled, isTrue);
      expect(client.lastState?.config.stopEnabled, isTrue);
      expect(client.lastState?.config.nextEnabled, isFalse);
      expect(client.lastState?.config.prevEnabled, isFalse);
      expect(client.lastState?.config.fastForwardEnabled, isFalse);
      expect(client.lastState?.config.rewindEnabled, isFalse);

      await bridge.dispose();
    });

    test('presents real listening time at non-normal speeds', () async {
      final handler = _FakePlaybackHandler(
        initialSnapshot: const PlaybackSnapshot.idle().copyWith(
          queueSongIds: <String>['song-1'],
          currentSongId: 'song-1',
          currentIndex: 0,
          processingState: AudioProcessingState.ready,
          playing: true,
          duration: Duration(seconds: 180),
          position: Duration(seconds: 90),
        ),
        initialMediaItem: const MediaItem(id: 'song-1', title: 'Track'),
      );
      final client = _FakeWindowsSmtcClient();
      final bridge = WindowsSmtcBridge(
        handler: handler,
        createClient: () async => client,
        isWindowsRuntime: () => true,
      );
      await _flushAsync();
      expect(client.lastState?.timeline.endTimeMs, 180000);

      handler.emitAdjustments(const PlaybackAdjustments(speed: 1.5));
      await _flushAsync();
      expect(client.lastState?.timeline.endTimeMs, 120000);
      expect(client.lastState?.timeline.positionMs, 60000);

      // A request to 1:20 of the 2:00 real-time timeline is 2:00 of track.
      client.emitPositionRequest(const Duration(seconds: 80));
      await _flushAsync();
      expect(handler.seekCalls, <Duration>[const Duration(seconds: 120)]);

      await bridge.dispose();
    });

    test('clamps SMTC seek requests and ignores live-radio seeks', () async {
      final handler = _FakePlaybackHandler(
        initialSnapshot: const PlaybackSnapshot.idle().copyWith(
          queueSongIds: <String>['song-1'],
          currentSongId: 'song-1',
          currentIndex: 0,
          duration: Duration(seconds: 100),
        ),
        initialMediaItem: const MediaItem(id: 'song-1', title: 'Track'),
      );
      final client = _FakeWindowsSmtcClient();
      final bridge = WindowsSmtcBridge(
        handler: handler,
        createClient: () async => client,
        isWindowsRuntime: () => true,
      );
      await _flushAsync();

      client.emitPositionRequest(const Duration(seconds: 140));
      await _flushAsync();
      expect(handler.seekCalls, <Duration>[const Duration(seconds: 100)]);

      handler.emitSnapshot(
        const PlaybackSnapshot(
          queueSongIds: <String>[],
          currentSongId: null,
          currentIndex: null,
          playing: true,
          processingState: AudioProcessingState.ready,
          position: Duration.zero,
          duration: Duration.zero,
          bufferedPosition: Duration.zero,
          shuffleMode: AudioServiceShuffleMode.none,
          repeatMode: AudioServiceRepeatMode.none,
          radioStation: RadioStationMetadata(
            stationId: 'radio-1',
            stationName: 'Radio',
            streamUrl: 'https://example.com/stream',
          ),
        ),
      );
      await _flushAsync();
      client.emitPositionRequest(const Duration(seconds: 20));
      await _flushAsync();
      expect(handler.seekCalls, <Duration>[const Duration(seconds: 100)]);

      await bridge.dispose();
    });

    test(
      'coalesces normal timeline updates and sends seeks immediately',
      () async {
        final handler = _FakePlaybackHandler(
          initialSnapshot: const PlaybackSnapshot.idle().copyWith(
            currentSongId: 'song-1',
            duration: const Duration(minutes: 3),
          ),
        );
        final client = _FakeWindowsSmtcClient();
        final bridge = WindowsSmtcBridge(
          handler: handler,
          createClient: () async => client,
          isWindowsRuntime: () => true,
          timelineInterval: const Duration(milliseconds: 20),
        );
        await _flushAsync();
        final initialUpdates = client.timelineUpdates;

        handler.emitPosition(const Duration(milliseconds: 100));
        handler.emitPosition(const Duration(milliseconds: 200));
        await _flushAsync();
        expect(client.timelineUpdates, initialUpdates);

        await Future<void>.delayed(const Duration(milliseconds: 25));
        expect(client.timelineUpdates, initialUpdates + 1);
        expect(client.lastState?.timeline.positionMs, 200);

        handler.emitPosition(const Duration(seconds: 30));
        await _flushAsync();
        expect(client.timelineUpdates, initialUpdates + 2);
        expect(client.lastState?.timeline.positionMs, 30000);

        await bridge.dispose();
      },
    );

    test(
      'serializes startup and newer state writes in publication order',
      () async {
        final handler = _FakePlaybackHandler(
          initialSnapshot: const PlaybackSnapshot.idle(),
          initialMediaItem: const MediaItem(id: 'song-1', title: 'Track'),
        );
        final client = _BlockingWindowsSmtcClient();
        final bridge = WindowsSmtcBridge(
          handler: handler,
          createClient: () async => client,
          isWindowsRuntime: () => true,
        );

        await client.firstWriteStarted.future;
        handler.emitSnapshot(
          const PlaybackSnapshot.idle().copyWith(
            queueSongIds: <String>['song-1'],
            currentSongId: 'song-1',
            currentIndex: 0,
            processingState: AudioProcessingState.ready,
            playing: true,
          ),
        );
        await _flushAsync();
        expect(client.states, hasLength(1));
        expect(client.states.single.enabled, isFalse);

        client.releaseFirstWrite();
        await _flushAsync();
        await _flushAsync();

        expect(client.states, hasLength(2));
        expect(client.states.last.enabled, isTrue);
        expect(client.states.last.status, PlaybackStatus.playing);
        await bridge.dispose();
      },
    );

    test('continues without SMTC when native initialization fails', () async {
      final handler = _FakePlaybackHandler(
        initialSnapshot: const PlaybackSnapshot.idle(),
      );
      final bridge = WindowsSmtcBridge(
        handler: handler,
        createClient: () => Future<WindowsSmtcClient>.error(
          StateError('native SMTC unavailable'),
        ),
        isWindowsRuntime: () => true,
      );

      await _flushAsync();
      await expectLater(bridge.dispose(), completes);
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
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();

  WindowsSmtcState? lastState;
  final List<WindowsSmtcState> states = <WindowsSmtcState>[];
  int timelineUpdates = 0;
  bool disposed = false;

  @override
  Stream<PressedButton> get buttonPressStream => _buttonController.stream;

  @override
  Stream<bool> get shuffleChangeStream => _shuffleController.stream;

  @override
  Stream<RepeatMode> get repeatModeChangeStream => _repeatController.stream;

  @override
  Stream<Duration> get positionChangeStream => _positionController.stream;

  void emitButton(PressedButton button) {
    _buttonController.add(button);
  }

  void emitPositionRequest(Duration position) {
    _positionController.add(position);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _buttonController.close();
    await _shuffleController.close();
    await _repeatController.close();
    await _positionController.close();
  }

  @override
  Future<void> applyState(WindowsSmtcState state) async {
    lastState = state;
    states.add(state);
    timelineUpdates += 1;
  }
}

class _BlockingWindowsSmtcClient extends _FakeWindowsSmtcClient {
  final Completer<void> firstWriteStarted = Completer<void>();
  final Completer<void> _firstWriteRelease = Completer<void>();
  bool _blockFirstWrite = true;

  void releaseFirstWrite() => _firstWriteRelease.complete();

  @override
  Future<void> applyState(WindowsSmtcState state) async {
    await super.applyState(state);
    if (_blockFirstWrite) {
      _blockFirstWrite = false;
      firstWriteStarted.complete();
      await _firstWriteRelease.future;
    }
  }
}

class _FakePlaybackHandler implements NavisPlaybackHandler {
  @override
  EqCapabilities get equalizerCapabilities => EqCapabilities.unavailable;
  @override
  EqApplicationState get equalizerState => EqApplicationState(
    desired: EqConfiguration.flat(),
    applied: EqConfiguration.flat(),
  );
  @override
  Stream<EqApplicationState> get equalizerStateStream => const Stream.empty();
  @override
  Future<void> setEqualizer(EqConfiguration values) async =>
      throw UnsupportedError('This fake has no EQ backend');
  @override
  Future<void> refreshEqualizerState() async {}

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
  final StreamController<PlaybackBufferState> _bufferStateController =
      StreamController<PlaybackBufferState>.broadcast();
  final StreamController<MediaItem?> _mediaItemController =
      StreamController<MediaItem?>.broadcast();
  final StreamController<void> _radioErrorController =
      StreamController<void>.broadcast();

  int playCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;
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

  void emitPosition(Duration position) {
    _snapshot = _snapshot.copyWith(position: position);
    _positionController.add(position);
  }

  @override
  MediaItem? get currentMediaItem => _currentMediaItem;

  @override
  Stream<MediaItem?> get mediaItemStream => _mediaItemController.stream;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  PlaybackBufferState get bufferState => PlaybackBufferState(
    songId: _snapshot.currentSongId,
    bufferedPosition: _snapshot.bufferedPosition,
  );

  @override
  Stream<PlaybackBufferState> get bufferStateStream =>
      _bufferStateController.stream;

  @override
  Stream<void> get radioStreamErrorStream => _radioErrorController.stream;

  @override
  Stream<PlaybackLoadFailure> get loadFailureStream =>
      const Stream<PlaybackLoadFailure>.empty();

  @override
  Stream<QueueSongsDropped> get droppedSongsStream =>
      const Stream<QueueSongsDropped>.empty();

  @override
  Stream<TransportVisualCue> get transportVisualCueStream =>
      const Stream<TransportVisualCue>.empty();

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
  Future<void> applySongIdentityAliases(Map<String, String> aliases) async {}

  @override
  Future<void> clearQueue() async {}

  @override
  Future<void> resetSession() => clearQueue();

  @override
  Future<void> pause() async {
    pauseCalls += 1;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
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
  Future<void> retainCurrentSongAsQueue(String songId) async {}

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
  Map<String, Object?> collectPlaybackDiagnostics() =>
      const <String, Object?>{};

  PlaybackAdjustments adjustments = const PlaybackAdjustments();
  final StreamController<PlaybackAdjustments> _adjustmentsController =
      StreamController<PlaybackAdjustments>.broadcast();

  void emitAdjustments(PlaybackAdjustments values) {
    adjustments = values;
    _adjustmentsController.add(values);
  }

  @override
  PlaybackAdjustments get playbackAdjustments => adjustments;

  @override
  Stream<PlaybackAdjustments> get playbackAdjustmentsStream =>
      _adjustmentsController.stream;

  @override
  PlaybackAdjustmentCapabilities get playbackAdjustmentCapabilities =>
      PlaybackAdjustmentCapabilities.android;

  @override
  Future<void> setPlaybackAdjustments(PlaybackAdjustments values) =>
      setPlaybackSpeed(values.speed);

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

  @override
  Future<void> retryDeferredQueueRestore() async {}
}
