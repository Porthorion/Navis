import 'package:navis/src/features/player/domain/playback_adjustments.dart';

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/data/windows_smtc_bridge.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis_windows_smtc/navis_windows_smtc.dart';
import 'package:navis_windows_smtc/src/smtc_windows_base.dart'
    show windowsNativeMetadata;

import '../../../../helpers/fake_playback_handler.dart';

void main() {
  test('native boundary converts local URIs and refuses remote thumbnails', () {
    for (final thumbnail in [
      'file:///C:/cache/radio%20art.png',
      r'C:\cache\radio art.png',
      'https://radio.test/art.jpg',
      'http://radio.test/art.jpg',
      null,
    ]) {
      final native = windowsNativeMetadata(
        MusicMetadata(title: 'Station', thumbnail: thumbnail),
      );
      expect(native.title, 'Station');
      expect(
        native.thumbnail,
        thumbnail != null && !thumbnail.startsWith('http')
            ? r'C:\cache\radio art.png'
            : null,
      );
    }
  });

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

    for (final (name, item, expected) in <(String, MediaItem, String?)>[
      (
        'never hands Windows a credential-bearing cover URL',
        MediaItem(
          id: 'song-1',
          title: 'Track',
          artUri: Uri.parse(
            'https://music.test/rest/getCoverArt.view?id=c&u=me&t=tok&s=salt',
          ),
        ),
        null,
      ),
      (
        'uses the cached cover file',
        MediaItem(
          id: 'song-1',
          title: 'Track',
          artUri: Uri.parse(
            'https://music.test/rest/getCoverArt.view?id=c&u=me&t=tok&s=salt',
          ),
          extras: const <String, Object?>{
            'artCacheFile': r'C:\Users\me\AppData\Local\Temp\navis_art_c.jpg',
          },
        ),
        'file:///C:/Users/me/AppData/Local/Temp/navis_art_c.jpg',
      ),
      (
        'normalizes mixed separators in the cached Windows file URI',
        const MediaItem(
          id: 'song-1',
          title: 'Track',
          extras: <String, Object?>{
            'artCacheFile': r'S:\NavisTest\tmp/navis_art_c.jpg',
          },
        ),
        'file:///S:/NavisTest/tmp/navis_art_c.jpg',
      ),
      (
        'refuses remote artwork without a guarded downloader',
        MediaItem(
          id: 'radio',
          title: 'Station',
          artUri: Uri.parse('https://radio.test/art/now.jpg'),
        ),
        null,
      ),
    ]) {
      test(name, () async {
        final handler = _FakePlaybackHandler(
          initialSnapshot: const PlaybackSnapshot.idle().copyWith(
            queueSongIds: <String>['song-1'],
            currentSongId: 'song-1',
            currentIndex: 0,
            processingState: AudioProcessingState.ready,
            playing: true,
          ),
          initialMediaItem: item,
        );
        final client = _FakeWindowsSmtcClient();
        final bridge = WindowsSmtcBridge(
          handler: handler,
          createClient: () async => client,
          isWindowsRuntime: () => true,
        );

        await _flushAsync();

        expect(client.lastState?.metadata?.thumbnail, expected);
        await bridge.dispose();
      });
    }

    test('does not resend unchanged metadata during repeated syncs', () async {
      final handler = _FakePlaybackHandler(
        initialSnapshot: const PlaybackSnapshot.idle(),
        initialMediaItem: const MediaItem(id: 'radio:one', title: 'Station'),
      );
      final client = _FakeWindowsSmtcClient();
      final bridge = WindowsSmtcBridge(
        handler: handler,
        createClient: () async => client,
        isWindowsRuntime: () => true,
      );
      await _flushAsync();
      for (var i = 0; i < 5; i++) {
        handler.emitSnapshot(handler.snapshot.copyWith(playing: i.isEven));
        handler.emitMediaItem(handler.currentMediaItem);
        await _flushAsync();
      }
      expect(client.metadataUpdates, 1);
      expect(client.timelineUpdates, greaterThan(1));
      handler.emitMediaItem(handler.currentMediaItem!.copyWith(title: 'New'));
      await _flushAsync();
      expect(client.metadataUpdates, 2);
      handler.emitMediaItem(null);
      await _flushAsync();
      expect(client.metadataUpdates, 3);
      await bridge.dispose();
    });

    for (final radio in [true, false]) {
      test(
        'downloads remote artwork once to a local URI (radio: $radio)',
        () async {
          final item = MediaItem(
            id: radio ? 'radio:one' : 'song-1',
            title: 'Track',
            artUri: Uri.parse('https://radio.test/art/now.jpg'),
          );
          final handler = _FakePlaybackHandler(
            initialSnapshot: const PlaybackSnapshot.idle(),
            initialMediaItem: item,
          );
          final download = Completer<String?>();
          var calls = 0;
          final client = _FakeWindowsSmtcClient();
          final bridge = WindowsSmtcBridge(
            handler: handler,
            createClient: () async => client,
            isWindowsRuntime: () => true,
            readArtworkAllowed: (_) => true,
            fetchArtwork: (_) {
              calls++;
              return download.future;
            },
          );
          await _flushAsync();
          for (var i = 0; i < 5; i++) {
            handler.emitSnapshot(handler.snapshot);
            await _flushAsync();
          }
          expect(calls, 1);
          expect(client.lastState?.metadata?.thumbnail, isNull);
          download.complete(r'C:\cache\radio image.jpg');
          await _flushAsync();
          expect(
            client.lastState?.metadata?.thumbnail,
            'file:///C:/cache/radio%20image.jpg',
          );
          handler.emitSnapshot(handler.snapshot);
          await _flushAsync();
          expect(calls, 1);
          expect(client.metadataUpdates, 2);
          expect(
            client.states
                .map((state) => state.metadata?.thumbnail)
                .whereType<String>()
                .every((uri) => uri.startsWith('file:')),
            isTrue,
          );
          await bridge.dispose();
        },
      );
    }

    test(
      'policy refusal makes no request and publishes no thumbnail',
      () async {
        final handler = _FakePlaybackHandler(
          initialSnapshot: const PlaybackSnapshot.idle(),
          initialMediaItem: MediaItem(
            id: 'radio:one',
            title: 'Station',
            artUri: Uri.parse('https://radio.test/art.jpg'),
          ),
        );
        var calls = 0;
        final client = _FakeWindowsSmtcClient();
        final bridge = WindowsSmtcBridge(
          handler: handler,
          createClient: () async => client,
          isWindowsRuntime: () => true,
          readArtworkAllowed: (_) => false,
          fetchArtwork: (_) async {
            calls++;
            return r'C:\cache\radio.jpg';
          },
        );
        await _flushAsync();
        expect(calls, 0);
        expect(client.lastState?.metadata?.thumbnail, isNull);
        await bridge.dispose();
      },
    );

    test(
      'policy changes invalidate in-flight art even if re-enabled',
      () async {
        final item = MediaItem(
          id: 'radio:one',
          title: 'Station',
          artUri: Uri.parse('https://radio.test/art.jpg'),
        );
        final handler = _FakePlaybackHandler(
          initialSnapshot: const PlaybackSnapshot.idle(),
          initialMediaItem: item,
        );
        var allowed = true;
        final downloads = <Completer<String?>>[];
        final client = _FakeWindowsSmtcClient();
        final bridge = WindowsSmtcBridge(
          handler: handler,
          createClient: () async => client,
          isWindowsRuntime: () => true,
          readArtworkAllowed: (_) => allowed,
          fetchArtwork: (_) {
            final pending = Completer<String?>();
            downloads.add(pending);
            return pending.future;
          },
        );
        await _flushAsync();
        allowed = false;
        handler.emitSnapshot(handler.snapshot);
        await _flushAsync();
        allowed = true;
        handler.emitSnapshot(handler.snapshot);
        await _flushAsync();
        downloads.first.complete(r'C:\cache\stale.jpg');
        await _flushAsync();
        expect(client.lastState?.metadata?.thumbnail, isNull);
        expect(downloads, hasLength(2));
        downloads.last.complete(r'C:\cache\fresh.jpg');
        await _flushAsync();
        expect(
          client.lastState?.metadata?.thumbnail,
          'file:///C:/cache/fresh.jpg',
        );
        await bridge.dispose();
      },
    );

    for (final result in [null, 'https://radio.test/redirect.jpg']) {
      test(
        'failed or non-local download never publishes a URL ($result)',
        () async {
          final handler = _FakePlaybackHandler(
            initialSnapshot: const PlaybackSnapshot.idle(),
            initialMediaItem: MediaItem(
              id: 'radio:one',
              title: 'Station',
              artUri: Uri.parse('https://radio.test/art.jpg'),
            ),
          );
          var calls = 0;
          final client = _FakeWindowsSmtcClient();
          final bridge = WindowsSmtcBridge(
            handler: handler,
            createClient: () async => client,
            isWindowsRuntime: () => true,
            readArtworkAllowed: (_) => true,
            fetchArtwork: (_) async {
              calls++;
              return result;
            },
          );
          await _flushAsync();
          handler.emitSnapshot(handler.snapshot);
          await _flushAsync();
          expect(calls, 1);
          expect(client.lastState?.metadata?.thumbnail, isNull);
          expect(client.metadataUpdates, 1);
          await bridge.dispose();
        },
      );
    }

    test(
      'station change ignores stale art and bounds active downloads',
      () async {
        final first = MediaItem(
          id: 'radio:one',
          title: 'First',
          artUri: Uri.parse('https://radio.test/first.jpg'),
        );
        final second = MediaItem(
          id: 'radio:two',
          title: 'Second',
          artUri: Uri.parse('https://radio.test/second.jpg'),
        );
        final handler = _FakePlaybackHandler(
          initialSnapshot: const PlaybackSnapshot.idle(),
          initialMediaItem: first,
        );
        final downloads = <String, Completer<String?>>{};
        final client = _FakeWindowsSmtcClient();
        final bridge = WindowsSmtcBridge(
          handler: handler,
          createClient: () async => client,
          isWindowsRuntime: () => true,
          readArtworkAllowed: (_) => true,
          fetchArtwork: (item) {
            final pending = Completer<String?>();
            downloads[item.id] = pending;
            return pending.future;
          },
        );
        await _flushAsync();
        handler.emitMediaItem(second);
        await _flushAsync();
        expect(client.lastState?.metadata?.title, 'Second');
        expect(downloads.keys, ['radio:one']);
        downloads[first.id]!.complete(r'C:\cache\first.jpg');
        await _flushAsync();
        expect(client.lastState?.metadata?.thumbnail, isNull);
        expect(downloads.keys, ['radio:one', 'radio:two']);
        downloads[second.id]!.complete(r'C:\cache\second.jpg');
        await _flushAsync();
        expect(
          client.lastState?.metadata?.thumbnail,
          'file:///C:/cache/second.jpg',
        );
        expect(
          client.states.map((state) => state.metadata?.thumbnail),
          isNot(contains('file:///C:/cache/first.jpg')),
        );
        await bridge.dispose();
      },
    );

    test('disables unavailable controls for radio snapshots', () async {
      final handler = _FakePlaybackHandler(
        initialSnapshot: const PlaybackSnapshot.idle(),
        initialMediaItem: const MediaItem(id: 'radio:radio-1', title: 'Radio'),
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
        expect(client.metadataUpdates, 1);
        await bridge.dispose();
      },
    );

    test('retries metadata after a failed native apply', () async {
      final handler = _FakePlaybackHandler(
        initialSnapshot: const PlaybackSnapshot.idle(),
        initialMediaItem: const MediaItem(id: 'song-1', title: 'Track'),
      );
      final client = _FailOnceWindowsSmtcClient();
      final bridge = WindowsSmtcBridge(
        handler: handler,
        createClient: () async => client,
        isWindowsRuntime: () => true,
      );
      await _flushAsync();
      expect(client.metadataUpdates, 1);
      handler.emitSnapshot(handler.snapshot);
      await _flushAsync();
      expect(client.metadataUpdates, 2);
      handler.emitSnapshot(handler.snapshot);
      await _flushAsync();
      expect(client.metadataUpdates, 2);
      await bridge.dispose();
    });

    test('artwork completing after disposal cannot publish', () async {
      final handler = _FakePlaybackHandler(
        initialSnapshot: const PlaybackSnapshot.idle(),
        initialMediaItem: MediaItem(
          id: 'radio:one',
          title: 'Station',
          artUri: Uri.parse('https://radio.test/art.jpg'),
        ),
      );
      final pending = Completer<String?>();
      final client = _FakeWindowsSmtcClient();
      final bridge = WindowsSmtcBridge(
        handler: handler,
        createClient: () async => client,
        isWindowsRuntime: () => true,
        readArtworkAllowed: (_) => true,
        fetchArtwork: (_) => pending.future,
      );
      await _flushAsync();
      await bridge.dispose();
      final writes = client.states.length;
      pending.complete(r'C:\cache\art.jpg');
      await _flushAsync();
      expect(client.states, hasLength(writes));
      expect(client.states.last.metadata?.thumbnail, isNull);
    });

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
  int metadataUpdates = 0;
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
    if (state.updateMetadata) metadataUpdates++;
  }
}

class _FailOnceWindowsSmtcClient extends _FakeWindowsSmtcClient {
  bool _failNextWrite = true;

  @override
  Future<void> applyState(WindowsSmtcState state) async {
    await super.applyState(state);
    if (_failNextWrite) {
      _failNextWrite = false;
      throw StateError('native apply failed');
    }
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

class _FakePlaybackHandler extends InertPlaybackHandler {
  new({required PlaybackSnapshot initialSnapshot, MediaItem? initialMediaItem})
    : _snapshot = initialSnapshot,
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
  PlaybackSnapshot get snapshot => _snapshot;

  @override
  Stream<PlaybackSnapshot> get snapshotStream => _snapshotController.stream;

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
  Future<void> seek(Duration position) async {
    seekCalls.add(position);
  }

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
  Future<void> skipToNext() async {
    skipNextCalls += 1;
  }

  @override
  Future<void> skipToPrevious() async {
    skipPreviousCalls += 1;
  }
}
