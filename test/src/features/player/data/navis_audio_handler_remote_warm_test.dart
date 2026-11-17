import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart'
    show AudioServicePlatform;
import 'package:audio_service_platform_interface/no_op_audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/playback_transport_trace.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';

import 'navis_audio_handler_navigation_harness.dart';

/// Issue #653: a cold remote song (Octo-Fiesta) answers only once the server
/// holds the whole file. While navigation waits for that first byte the old
/// song must be silent and pinned, the target must show as loading, and the
/// wait must be visible in the transport trace.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => AudioServicePlatform.instance = NoOpAudioService());

  const songCount = 6;
  const ids = ['song-0', 'song-1', 'song-2', 'song-3', 'song-4', 'song-5'];

  late HttpServer server;
  late NavisAudioHandler handler;
  late ControllableAudioPlayer player;
  late PlaybackTransportTrace trace;
  final requests = <String>[];

  /// Origin requests that are not the Range 0-1 warm: the lock-cache
  /// source's own whole-file fetch.
  final fetches = <String>[];
  final gates = <String, Completer<void>>{};
  final silent = <String>{};
  final failing = <String>{};
  final closed = <String>[];
  var prefetchAllowed = false;
  var replayGainMode = 'off';

  Future<void> setUpHandler({
    Set<String> localIds = const {},
    NavisPlaybackTimeouts timeouts = const NavisPlaybackTimeouts(),
    bool crossfade = false,
    bool replayGainInPipeline = true,
    bool cacheSongs = false,
    Set<String>? hungLoadSongs,
    Set<String> uncached = const {},
    bool prefetch = false,
    Set<String> gated = const {},
    Set<String> failIds = const {},
    bool? desktop,
    bool positionStreams = false,
    bool sidecarStreams = false,
    BridgeSidecar? sidecar,
    NavisQueueWindow queueWindow = const NavisQueueWindow(),
    int startIndex = 0,
  }) async {
    final previousHttp = HttpOverrides.current;
    HttpOverrides.global = null;
    requests.clear();
    fetches.clear();
    gates.clear();
    silent.clear();
    failing
      ..clear()
      ..addAll(failIds);
    closed.clear();
    prefetchAllowed = prefetch;
    for (final id in gated) {
      gates[id] = Completer<void>();
    }
    replayGainMode = 'off';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final id = request.uri.queryParameters['id'] ?? '';
      if (request.headers.value('range') == 'bytes=0-1') {
        requests.add(id);
      } else {
        fetches.add(id);
      }
      if (gates.containsKey(id) && !gates[id]!.isCompleted) {
        // A held request is answered on the raw socket, so a client that
        // hangs up while it waits is seen at once.
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.listen(
          (_) {},
          onDone: () => closed.add(id),
          onError: (Object _) => closed.add(id),
        );
        await gates[id]!.future;
        try {
          socket.add(
            'HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\n'.codeUnits + [1, 2],
          );
          await socket.flush();
          await socket.close();
        } on Object {
          // The client already hung up.
        }
        return;
      }
      try {
        if (silent.contains(id)) await Completer<void>().future;
        await gates[id]?.future;
        if (failing.contains(id)) {
          request.response.statusCode = 500;
        } else {
          request.response
            ..contentLength = 2
            ..add([1, 2]);
        }
        await request.response.close();
      } on HttpException {
        // The warm-up closes its probe as soon as the first byte arrives.
      }
    });
    final api = SubsonicApiClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      authConfig: const SubsonicAuthConfig(
        username: 'fixture',
        password: 'synthetic',
        apiVersion: '1.16.1',
      ),
      enableLogging: false,
    );
    final directory = await Directory.systemTemp.createTemp('navis-warm-');
    trace = PlaybackTransportTrace(enabled: true);
    final created = await createHandler(
      directory,
      songCount,
      cacheSongs: cacheSongs,
      hungLoadSongs: hungLoadSongs,
      rebuiltPlayers: hungLoadSongs == null
          ? null
          : <ControllableAudioPlayer>[],
      readApiClient: () => api,
      readNextSongPrefetchAllowed: () => prefetchAllowed,
      desktopRuntimeOverride: desktop,
      positionStreams: positionStreams,
      sidecarStreams: sidecarStreams,
      sidecarDownloader: sidecar,
      transportTrace: trace,
      queueWindow: queueWindow,
      timeouts: timeouts,
      crossfade: crossfade,
      replayGainInPipeline: replayGainInPipeline,
      readReplayGainMode: () => replayGainMode,
      replayGainUntaggedDb: -6,
    );
    handler = created.$1;
    player = created.$2;
    final database = created.$3;
    for (final id in uncached) {
      await database.cacheDao.removeCachedTrack(id);
    }
    player.simulateProgress = true;
    addTearDown(() async {
      for (final gate in gates.values) {
        if (!gate.isCompleted) gate.complete();
      }
      await handler.disposeHandler();
      await server.close(force: true);
      await database.close();
      await directory.delete(recursive: true);
      HttpOverrides.global = previousHttp;
    });
    final rows = {
      for (final row in await database.libraryDao.getSongsByIds(ids))
        row.id: row,
    };
    await handler.replaceQueueWithData(
      [
        for (final id in ids)
          rows[id]!.copyWith(isExternal: !localIds.contains(id)),
      ],
      startIndex: startIndex,
      expandMatchFlows: false,
    );
    await settleQueue(handler);
    expect(handler.snapshot.currentSongId, ids[startIndex]);
    if (!prefetch) requests.clear();
  }

  List<Map<String, Object?>> records(String kind) => [
    for (final entry in trace.entries)
      if (entry['kind'] == kind) entry,
  ];

  Map<String, Object?> warmEnd(String songId) =>
      records('remoteWarm')
          .lastWhere((e) => e['phase'] == 'end' && e['songId'] == songId);

  /// Holds [id]'s first byte, starts navigating to it and waits until the
  /// warm-up request has reached the server.
  Future<(Future<void>,)> navigateGated(int index, {bool pump = true}) async {
    final id = ids[index];
    gates[id] = Completer<void>();
    final seen = requests.where((r) => r == id).length;
    final navigation = handler.playFromIndex(index);
    await until(
      () => requests.where((r) => r == id).length > seen,
      reason: 'warm-up request for $id',
    );
    if (pump) await pumpEventQueue();
    return (navigation,);
  }

  Future<void> release(String id, (Future<void>,) navigation) async {
    gates[id]!.complete();
    await navigation.$1;
    await settleQueue(handler);
  }

  group('remote warm-up trace', () {
    test('a cold navigation records navigateLaneStart and the warm start and '
        'answered end', () async {
      await setUpHandler();
      final navigation = await navigateGated(3);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await release('song-3', navigation);
      final kinds = [
        for (final e in trace.entries)
          if (const {
            'navigate',
            'navigateLaneStart',
            'remoteWarm',
          }.contains(e['kind']))
            '${e['kind']}${e['phase'] != null ? ':${e['phase']}' : ''}',
      ];
      expect(kinds.skipWhile((k) => k != 'navigate').take(4), [
        'navigate',
        'navigateLaneStart',
        'remoteWarm:start',
        'remoteWarm:end',
      ]);
      final lane = records('navigateLaneStart').last;
      expect(lane['targetSongId'], 'song-3');
      expect(lane['requestedIndex'], 3);
      expect(lane['waitedMs'], isA<int>());
      final start = records('remoteWarm')
          .lastWhere((e) => e['phase'] == 'start');
      expect(start['songId'], 'song-3');
      expect(start['trigger'], 'navigate');
      final end = warmEnd('song-3');
      expect(end['outcome'], 'answered');
      expect(end['trigger'], 'navigate');
      expect(end['elapsedMs'] as int, greaterThanOrEqualTo(200));
    });

    test('the queue load warm records trigger initial', () async {
      await setUpHandler();
      final initial = records('remoteWarm')
          .where((e) => e['phase'] == 'start')
          .first;
      expect(initial['trigger'], 'initial');
      expect(initial['songId'], 'song-0');
    });

    test('a cold warm superseded by a later navigation records superseded '
        'and the later one answers', () async {
      await setUpHandler();
      final first = await navigateGated(3);
      gates['song-4'] = Completer<void>()..complete();
      await handler.playFromIndex(4);
      await settleQueue(handler);
      await first.$1;
      expect(warmEnd('song-3')['outcome'], 'superseded');
      expect(warmEnd('song-4')['outcome'], 'answered');
      expect(handler.snapshot.currentSongId, 'song-4');
    });

    test('a silent origin records timeout and the navigation still lands, '
        'unmuted', () async {
      await setUpHandler(
        timeouts: const NavisPlaybackTimeouts(
          remoteLoad: Duration(milliseconds: 300),
        ),
      );
      silent.add('song-3');
      await handler.playFromIndex(3);
      await settleQueue(handler);
      expect(warmEnd('song-3')['outcome'], 'timeout');
      expect(handler.snapshot.currentSongId, 'song-3');
      expect(player.volume, 1.0);
      expect(player.appliedLoopMode, LoopMode.off);
    });

    test('an origin error records error with the status', () async {
      await setUpHandler();
      failing.add('song-3');
      await handler.playFromIndex(3);
      await settleQueue(handler);
      final end = warmEnd('song-3');
      expect(end['outcome'], 'error');
      expect(end['httpStatus'], 500);
      expect(handler.snapshot.currentSongId, 'song-3');
      expect(player.volume, 1.0);
    });
  });

  group('cold remote warm: the old song is silent and the target loads', () {
    test(
      'the snapshot shows the target loading while the warm waits',
      () async {
        await setUpHandler();
        final navigation = await navigateGated(3);
        final snapshot = handler.snapshot;
        expect(snapshot.currentSongId, 'song-3');
        expect(snapshot.isLoading, isTrue);
        expect(snapshot.loadingSongId, 'song-3');
        expect(snapshot.processingState, AudioProcessingState.loading);
        expect(
          shouldShowRemotePlaybackLoading(
            playback: snapshot,
            currentIsExternal: true,
          ),
          isTrue,
        );
        await release('song-3', navigation);
      },
    );

    test('the previous song is muted and not paused, then the target plays '
        'at the full volume', () async {
      await setUpHandler();
      final navigation = await navigateGated(3);
      expect(player.volume, 0);
      expect(player.playing, isTrue);
      expect(player.appliedLoopMode, LoopMode.one);
      await release('song-3', navigation);
      expect(handler.snapshot.currentSongId, 'song-3');
      expect(player.volume, 1.0);
      expect(player.appliedLoopMode, LoopMode.off);
      expect(player.playing, isTrue);
    });

    test('the repeat mode the user chose comes back after the pin', () async {
      await setUpHandler();
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      final navigation = await navigateGated(3);
      expect(player.appliedLoopMode, LoopMode.one);
      await release('song-3', navigation);
      expect(player.appliedLoopMode, LoopMode.all);
    });

    test('a repeat change during the warm keeps the pin and applies after '
        'the landing', () async {
      await setUpHandler();
      final navigation = await navigateGated(3);
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      expect(player.appliedLoopMode, LoopMode.one);
      await release('song-3', navigation);
      expect(player.appliedLoopMode, LoopMode.all);
    });

    test('a hung native load after a timed-out warm leaves the old deck '
        'audible and unpinned', () async {
      await setUpHandler(
        timeouts: const NavisPlaybackTimeouts(
          remoteLoad: Duration(milliseconds: 300),
          load: Duration(milliseconds: 300),
          reset: Duration(milliseconds: 100),
          control: Duration(milliseconds: 100),
        ),
        hungLoadSongs: {'song-3'},
      );
      silent.add('song-3');
      await handler.playFromIndex(3);
      await until(
        () => !handler.snapshot.isLoading,
        reason: 'the navigation settles',
      );
      await settleQueue(handler);
      expect(warmEnd('song-3')['outcome'], 'timeout');
      expect(handler.debugActivePlayer.volume, greaterThan(0));
      expect(handler.debugActivePlayer.loopMode, isNot(LoopMode.one));
    });

    test('a user volume change during the warm stays silent and lands after '
        'the load', () async {
      await setUpHandler();
      final navigation = await navigateGated(3);
      await handler.setVolume(0.5);
      expect(player.volume, 0);
      await release('song-3', navigation);
      expect(player.volume, 0.5);
    });

    test('ducking begin and end during the warm stay silent', () async {
      await setUpHandler();
      final session = TestAudioSession();
      handler.debugWireAudioSession(session);
      final navigation = await navigateGated(3);
      session.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.duck),
      );
      await pumpEventQueue();
      expect(player.volume, 0);
      session.interruptions.add(
        AudioInterruptionEvent(false, AudioInterruptionType.duck),
      );
      await pumpEventQueue();
      expect(player.volume, 0);
      await release('song-3', navigation);
      expect(player.volume, 1.0);
    });

    test('a ReplayGain setting change during the warm stays silent and the '
        'target plays at its gain', () async {
      await setUpHandler(replayGainInPipeline: false);
      final navigation = await navigateGated(3);
      replayGainMode = 'track';
      await handler.applyRuntimeSettings();
      await pumpEventQueue();
      expect(player.volume, 0);
      await release('song-3', navigation);
      expect(player.volume, closeTo(0.501, 0.01));
    });

    test(
      'superseding a cold warm with a local song ends at full volume',
      () async {
        await setUpHandler(localIds: {'song-1'});
        final first = await navigateGated(3);
        expect(player.volume, 0);
        await handler.playFromIndex(1);
        await settleQueue(handler);
        await first.$1;
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(player.volume, 1.0);
        expect(player.appliedLoopMode, LoopMode.off);
      },
    );

    test('a second cold navigation inherits the mute: silent throughout, '
        'restored on load', () async {
      await setUpHandler();
      final first = await navigateGated(3);
      final second = await navigateGated(4);
      await pumpEventQueue();
      expect(player.appliedVolumes.skipWhile((v) => v != 0), everyElement(0));
      expect(player.volume, 0);
      await release('song-4', second);
      await first.$1;
      expect(player.volume, 1.0);
      expect(player.appliedLoopMode, LoopMode.off);
    });

    test('stop during the warm restores the volume, so a later play is '
        'audible', () async {
      await setUpHandler();
      final navigation = await navigateGated(3);
      await handler.stop();
      await pumpEventQueue();
      expect(player.volume, 1.0);
      expect(player.appliedLoopMode, LoopMode.off);
      gates['song-3']!.complete();
      await navigation.$1;
      await handler.play();
      await settleQueue(handler);
      expect(player.volume, 1.0);
    });

    test('pause during the warm keeps the mute and play resumes into the '
        'target', () async {
      await setUpHandler();
      final navigation = await navigateGated(3);
      await handler.pause();
      await pumpEventQueue();
      expect(player.volume, 0);
      await handler.play();
      expect(player.volume, 0);
      await release('song-3', navigation);
      expect(handler.snapshot.currentSongId, 'song-3');
      expect(player.volume, 1.0);
      expect(player.playing, isTrue);
    });

    test('no crossfade starts on the muted old deck during the warm', () async {
      await setUpHandler(crossfade: true);
      final navigation = await navigateGated(3);
      player.simulatedPosition =
          const Duration(minutes: 3) - const Duration(seconds: 8);
      handler.debugCheckCrossfadeTrigger(player.position);
      await pumpEventQueue();
      expect(fade(handler)['active'], isFalse);
      expect(player.volume, 0);
      expect(
        (handler.debugInactiveDeck! as ControllableAudioPlayer).playing,
        isFalse,
      );
      await release('song-3', navigation);
    });

    test(
      'a cold navigation started mid-crossfade silences both decks',
      () async {
        await setUpHandler(
          crossfade: true,
          cacheSongs: true,
          uncached: {'song-3'},
          localIds: {
            for (final id in ids)
              if (id != 'song-3') id,
          },
        );
        final incoming = handler.debugInactiveDeck! as ControllableAudioPlayer;
        player.simulatedPosition =
            const Duration(minutes: 3) - const Duration(seconds: 4);
        handler.debugCheckCrossfadeTrigger(player.position);
        await until(
          () => fade(handler)['active'] == true,
          reason: 'crossfade running',
        );
        final navigation = await navigateGated(3);
        await pumpEventQueue();
        expect(fade(handler)['active'], isFalse);
        expect(player.volume, 0);
        expect(incoming.volume, 0);
        await release('song-3', navigation);
      },
    );
  });

  group('the mute starts when the navigation is issued', () {
    test('a cold navigation queued behind a slow lane op mutes before the '
        'lane starts', () async {
      await setUpHandler(localIds: {'song-1'});
      final hold = Completer<void>();
      player
        ..seekGate = hold
        ..seekEntered = Completer<void>();
      final slow = handler.playFromIndex(1);
      await player.seekEntered!.future;
      gates['song-3'] = Completer<void>();
      final navigation = handler.playFromIndex(3);
      await pumpEventQueue();
      expect(requests.where((r) => r == 'song-3'), isEmpty);
      expect(handler.snapshot.currentSongId, 'song-3');
      expect(player.volume, 0);
      expect(player.appliedLoopMode, LoopMode.one);
      hold.complete();
      await until(
        () => requests.contains('song-3'),
        reason: 'warm-up request for song-3',
      );
      expect(player.volume, 0);
      gates['song-3']!.complete();
      await Future.wait([slow, navigation]);
      await settleQueue(handler);
      expect(handler.snapshot.currentSongId, 'song-3');
      expect(player.volume, 1.0);
      expect(player.appliedLoopMode, LoopMode.off);
    });

    // Songs 2-4 are in the player, songs 0-1 are in the deferred head: a
    // logical index and the player's row differ by two.
    const headed = NavisQueueWindow(
      deferThreshold: 4,
      ahead: 1,
      behind: 1,
      lowWater: 0,
      page: 2,
      nearJump: 1,
    );

    test('with songs released from the front, the early mute reads the '
        "player's row of the target", () async {
      await setUpHandler(
        localIds: {'song-3'},
        queueWindow: headed,
        startIndex: 3,
      );
      expect(handler.collectPlaybackDiagnostics()['deferredHeadLength'], 2);
      final hold = Completer<void>();
      player
        ..seekGate = hold
        ..seekEntered = Completer<void>();
      final slow = handler.playFromIndex(3);
      await player.seekEntered!.future;
      gates['song-4'] = Completer<void>();
      final navigation = handler.playFromIndex(4);
      await pumpEventQueue();
      expect(requests.where((r) => r == 'song-4'), isEmpty);
      expect(player.volume, 0);
      hold.complete();
      await until(
        () => requests.contains('song-4'),
        reason: 'warm-up request for song-2',
      );
      gates['song-4']!.complete();
      await Future.wait([slow, navigation]);
      await settleQueue(handler);
      expect(handler.snapshot.currentSongId, 'song-4');
      expect(player.volume, 1.0);
    });

    test('a navigation to a local song never mutes', () async {
      await setUpHandler(localIds: {'song-1'});
      final hold = Completer<void>();
      player
        ..seekGate = hold
        ..seekEntered = Completer<void>();
      final navigation = handler.playFromIndex(1);
      await player.seekEntered!.future;
      expect(player.appliedVolumes, everyElement(isNot(0)));
      expect(player.volume, 1.0);
      hold.complete();
      await navigation;
      expect(player.appliedVolumes, everyElement(isNot(0)));
    });

    test('a local navigation superseding a queued cold one restores the '
        'volume on its load', () async {
      await setUpHandler(localIds: {'song-1', 'song-2'});
      final hold = Completer<void>();
      player
        ..seekGate = hold
        ..seekEntered = Completer<void>();
      final slow = handler.playFromIndex(2);
      await player.seekEntered!.future;
      gates['song-3'] = Completer<void>();
      final cold = handler.playFromIndex(3);
      await pumpEventQueue();
      expect(player.volume, 0);
      final local = handler.playFromIndex(1);
      hold.complete();
      await Future.wait([slow, cold, local]);
      await settleQueue(handler);
      expect(handler.snapshot.currentSongId, 'song-1');
      expect(player.volume, 1.0);
      expect(player.appliedLoopMode, LoopMode.off);
    });
  });

  group('the warm pin and the anomaly detector', () {
    Future<List<Object?>> wrapAfter({required bool warm}) async {
      await setUpHandler(positionStreams: true);
      await handler.play();
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      (Future<void>,)? navigation;
      if (warm) navigation = await navigateGated(3);
      // The navigation's own position moves are explained for a while.
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      player.simulatedPosition = const Duration(seconds: 175);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      player.simulatedPosition = const Duration(milliseconds: 500);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final found =
          handler.collectPlaybackDiagnostics()['anomalies']! as List<Object?>;
      if (navigation != null) await release('song-3', navigation);
      return found;
    }

    test('the old song wrapping under the pin is no anomaly', () async {
      expect(await wrapAfter(warm: true), isEmpty);
    });

    test('the same wrap outside a warm is still recorded', () async {
      expect(await wrapAfter(warm: false), hasLength(1));
    });
  });

  group('radio and disposal during a navigation warm', () {
    test('radio started during the warm ends it: unmuted, unpinned', () async {
      await setUpHandler();
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      final navigation = await navigateGated(3);
      expect(player.volume, 0);
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: 'https://radio.example/live',
      );
      await pumpEventQueue();
      expect(player.volume, 1.0);
      expect(player.appliedLoopMode, isNot(LoopMode.one));
      gates['song-3']!.complete();
      await navigation.$1;
      await pumpEventQueue();
      expect(player.volume, 1.0);
    });

    test('disposeHandler during the warm closes the connection and leaves '
        'no timer', () async {
      await setUpHandler();
      final navigation = await navigateGated(3);
      await handler.disposeHandler();
      await until(() => closed.contains('song-3'), reason: 'socket closed');
      expect(handler.debugRemoteSettlingCount, 0);
      gates['song-3']!.complete();
      await navigation.$1.catchError((Object _) {});
    });
  });

  group('the old song reaches its end during the wait', () {
    void expectPinned(String reason) {
      expect(player.index, isNotNull, reason: reason);
      expect(player.state, isNot(ProcessingState.completed), reason: reason);
      expect(handler.snapshot.isLoading, isTrue, reason: reason);
      expect(handler.playbackState.value.playing, isTrue, reason: reason);
      expect(player.volume, 0, reason: reason);
    }

    test('old next == target: no advance, no unmute', () async {
      await setUpHandler();
      final navigation = await navigateGated(1);
      player.finishCurrentTrack();
      await pumpEventQueue();
      expect(player.index, 0);
      expectPinned('old next is the target');
      await release('song-1', navigation);
      expect(handler.snapshot.currentSongId, 'song-1');
      expect(player.volume, 1.0);
    });

    test('old song last in the queue: no queue finish', () async {
      await setUpHandler();
      await handler.playFromIndex(5);
      await settleQueue(handler);
      final navigation = await navigateGated(2);
      player.finishCurrentTrack();
      await pumpEventQueue();
      expect(player.index, 5);
      expectPinned('old song is last');
      await release('song-2', navigation);
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(handler.playbackState.value.playing, isTrue);
    });

    test(
      'old next is another cold remote song: no advance, no recovery',
      () async {
        await setUpHandler();
        final navigation = await navigateGated(3);
        player.finishCurrentTrack();
        await pumpEventQueue();
        expect(player.index, 0);
        expectPinned('old next is another cold song');
        expect(
          trace.entries.where((e) => '${e['kind']}'.contains('stall')),
          isEmpty,
        );
        await release('song-3', navigation);
        expect(handler.snapshot.currentSongId, 'song-3');
      },
    );
  });

  group('next-song prefetch', () {
    int count(String id) => requests.where((r) => r == id).length;
    Future<void> quiet() =>
        Future<void>.delayed(const Duration(milliseconds: 500));
    Future<void> prefetchAnswered(String id) => until(
      () => records('remoteWarm').any(
        (e) =>
            e['phase'] == 'end' &&
            e['songId'] == id &&
            e['trigger'] == 'prefetch',
      ),
      reason: 'prefetch of $id ended',
    );

    test('the next cold remote song gets one Range 0-1 GET, not one per '
        'position tick', () async {
      await setUpHandler(prefetch: true);
      await prefetchAnswered('song-1');
      await quiet();
      expect(count('song-1'), 1);
      expect(count('song-2'), 0);
      final starts = records('remoteWarm')
          .where((e) => e['phase'] == 'start' && e['songId'] == 'song-1');
      expect(starts.map((e) => e['trigger']), ['prefetch']);
    });

    test(
      'navigating to the song whose prefetch is in flight joins it',
      () async {
        await setUpHandler(prefetch: true, gated: {'song-1'});
        await until(() => count('song-1') == 1, reason: 'prefetch request');
        final navigation = handler.playFromIndex(1);
        await quiet();
        expect(handler.snapshot.isLoading, isTrue);
        expect(player.volume, 0);
        gates['song-1']!.complete();
        await navigation;
        await settleQueue(handler);
        expect(count('song-1'), 1);
        final join = records('remoteWarm')
            .singleWhere((e) => e['phase'] == 'join');
        expect(join['songId'], 'song-1');
        expect(join['trigger'], 'navigate');
        expect(join['startedBy'], 'prefetch');
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(player.volume, 1.0);
      },
    );

    test(
      'navigating to an answered prefetched song waits at most one poll',
      () async {
        await setUpHandler(prefetch: true);
        await prefetchAnswered('song-1');
        final started = DateTime.now();
        await handler.playFromIndex(1);
        expect(
          DateTime.now().difference(started).inMilliseconds,
          lessThan(400),
        );
        await settleQueue(handler);
        final join = records(
          'remoteWarm',
        ).singleWhere((e) => e['phase'] == 'join' && e['songId'] == 'song-1');
        expect(join['trigger'], 'navigate');
        expect(join['outcome'], 'answered');
        expect(count('song-1'), 1, reason: 'no second request for the song');
        expect(player.volume, 1.0);
      },
    );

    test('a queue edit that changes the next song leaves the in-flight '
        'prefetch open; the new next song starts after it ends', () async {
      await setUpHandler(prefetch: true, gated: {'song-1'});
      await until(() => count('song-1') == 1, reason: 'prefetch request');
      await handler.removeQueueItemAt(1);
      await settleQueue(handler);
      await quiet();
      expect(closed, isNot(contains('song-1')));
      expect(count('song-2'), 0);
      gates['song-1']!.complete();
      await until(() => count('song-2') == 1, reason: 'next prefetch');
      expect(count('song-1'), 1);
    });

    test('no prefetch starts while paused, gated off or navigating', () async {
      await setUpHandler(prefetch: true);
      await prefetchAnswered('song-1');
      await handler.pause();
      await handler.removeQueueItemAt(1);
      await settleQueue(handler);
      await quiet();
      expect(count('song-2'), 0, reason: 'paused');
      prefetchAllowed = false;
      await handler.play();
      await quiet();
      expect(count('song-2'), 0, reason: 'setting off');
      prefetchAllowed = true;
      gates['song-3'] = Completer<void>();
      final navigation = handler.playFromIndex(2);
      await until(() => handler.snapshot.isLoading, reason: 'loading');
      expect(count('song-4'), 0, reason: 'navigation pending');
      gates['song-3']!.complete();
      await navigation;
      await settleQueue(handler);
      await until(() => count('song-4') == 1, reason: 'prefetch after load');
    });

    test('local and downloaded next songs get no prefetch', () async {
      await setUpHandler(prefetch: true, localIds: {'song-1'});
      await quiet();
      expect(count('song-1'), 0);
      await handler.disposeHandler();
    });

    test('downloaded next songs get no prefetch', () async {
      await setUpHandler(prefetch: true, cacheSongs: true);
      await quiet();
      expect(count('song-1'), 0);
    });

    test(
      'the full download waits for the prefetch and the settle delay',
      () async {
        final previous = remoteSettleDelay;
        remoteSettleDelay = const Duration(seconds: 1);
        addTearDown(() => remoteSettleDelay = previous);
        await setUpHandler(prefetch: true, gated: {'song-1'});
        await until(() => count('song-1') == 1, reason: 'prefetch request');
        expect(handler.debugRemoteFullDownloadHeld('song-1'), isTrue);
        expect(handler.debugLockCacheWarmSongId, isNull);
        gates['song-1']!.complete();
        await prefetchAnswered('song-1');
        expect(handler.debugRemoteFullDownloadHeld('song-1'), isTrue);
        expect(handler.debugRemoteSettlingCount, 1);
        await until(
          () => !handler.debugRemoteFullDownloadHeld('song-1'),
          reason: 'settle delay over',
        );
        expect(handler.debugRemoteSettlingCount, 0);
      },
    );

    int fetched(String id) => fetches.where((r) => r == id).length;

    /// Android with a local current song, so the next cold remote song's own
    /// lock-cache source is the only thing that asks the origin for it.
    Future<void> setUpAndroid({
      bool prefetch = true,
      Set<String> gated = const {'song-1'},
    }) => setUpHandler(
      prefetch: prefetch,
      desktop: false,
      gated: gated,
      localIds: {'song-0'},
      cacheSongs: true,
      uncached: {'song-1', 'song-2', 'song-3', 'song-4', 'song-5'},
    );

    test('Android: the next cold song is fetched once, by its own lock-cache '
        'source, with no Range 0-1 warm (#653)', () async {
      await setUpAndroid();
      await until(() => fetched('song-1') == 1, reason: 'lock-cache fetch');
      expect(handler.debugLockCacheWarmSongId, 'song-1');
      expect(handler.debugRemoteFullDownloadHeld('song-1'), isFalse);
      await quiet();
      expect(count('song-1'), 0, reason: 'no separate warm request');
      expect(fetched('song-1'), 1);
      expect(
        records('remoteWarm').where((e) => e['songId'] == 'song-1'),
        isEmpty,
      );
      gates['song-1']!.complete();
      await quiet();
      expect(fetched('song-1'), 1);
    });

    test('Android: Next onto a song whose fetch is in flight joins it: one '
        'fetch, silent until the origin answers (#653)', () async {
      await setUpAndroid();
      await until(() => fetched('song-1') == 1, reason: 'lock-cache fetch');
      final navigation = handler.playFromIndex(1);
      await quiet();
      expect(handler.snapshot.isLoading, isTrue);
      expect(player.volume, 0);
      gates['song-1']!.complete();
      await navigation;
      await settleQueue(handler);
      expect(handler.snapshot.currentSongId, 'song-1');
      expect(player.volume, 1.0);
      expect(fetched('song-1'), 1);
      expect(count('song-1'), 0);
      final join = records('remoteWarm')
          .singleWhere((e) => e['phase'] == 'join');
      expect(join['trigger'], 'navigate');
      expect(join['startedBy'], 'lockCache');
      expect(warmEnd('song-1')['outcome'], 'answered');
    });

    test('Android: Next onto a cold song nobody fetched starts the source '
        'fetch, not a two-byte warm (#653)', () async {
      await setUpAndroid(prefetch: false);
      await quiet();
      expect(fetched('song-1'), 0);
      final navigation = handler.playFromIndex(1);
      await until(() => fetched('song-1') == 1, reason: 'lock-cache fetch');
      await pumpEventQueue();
      expect(handler.snapshot.isLoading, isTrue);
      expect(player.volume, 0);
      gates['song-1']!.complete();
      await navigation;
      await settleQueue(handler);
      expect(handler.snapshot.currentSongId, 'song-1');
      expect(player.volume, 1.0);
      expect(fetched('song-1'), 1);
      expect(count('song-1'), 0);
      final start = records('remoteWarm')
          .singleWhere((e) => e['phase'] == 'start');
      expect(start['startedBy'], 'lockCache');
    });

    test('Android: a navigation superseded while waiting leaves the source '
        'fetch running (#653)', () async {
      await setUpAndroid(prefetch: false);
      final first = handler.playFromIndex(1);
      await until(() => fetched('song-1') == 1, reason: 'lock-cache fetch');
      await quiet();
      // Back to the current song: song-1 stays its next song.
      await handler.playFromIndex(0);
      await first;
      await settleQueue(handler);
      expect(warmEnd('song-1')['outcome'], 'superseded');
      expect(closed, isNot(contains('song-1')));
      expect(fetched('song-1'), 1);
      expect(count('song-1'), 0);
    });

    test('Android: a fetch the player started two songs ahead survives a '
        'track change (#653)', () async {
      await setUpAndroid(prefetch: false, gated: {'song-3'});
      // The player's own preload of a song further ahead than the next one.
      unawaited(
        handler
            .debugRegisteredLockCacheSource('song-3')!
            .prefetch()
            .catchError((Object _) {}),
      );
      await until(() => fetched('song-3') == 1, reason: 'player fetch');
      gates['song-1'] = Completer<void>()..complete();
      await handler.playFromIndex(1);
      await settleQueue(handler);
      await quiet();
      expect(handler.snapshot.currentSongId, 'song-1');
      expect(closed, isNot(contains('song-3')));
      expect(fetched('song-3'), 1);
    });

    test('Android: a source whose fetch outlasts the wait times out without '
        'a second request (#653)', () async {
      await setUpHandler(
        prefetch: false,
        desktop: false,
        gated: {'song-1'},
        localIds: {'song-0'},
        cacheSongs: true,
        uncached: {'song-1', 'song-2', 'song-3', 'song-4', 'song-5'},
        timeouts: const NavisPlaybackTimeouts(
          remoteLoad: Duration(milliseconds: 300),
        ),
      );
      await handler.playFromIndex(1);
      await settleQueue(handler);
      expect(warmEnd('song-1')['outcome'], 'timeout');
      expect(fetched('song-1'), 1);
      expect(count('song-1'), 0);
    });

    test('an errored prefetch does not wait the settle delay', () async {
      await setUpHandler(prefetch: true, failIds: {'song-1'});
      await prefetchAnswered('song-1');
      await until(
        () => !handler.debugRemoteFullDownloadHeld('song-1'),
        cap: const Duration(seconds: 2),
        reason: 'no settle wait after an error',
      );
      await quiet();
      expect(count('song-1'), 1, reason: 'one attempt per song');
    });

    test('a timed-out prefetch holds the full download and the navigation '
        'sends no second request', () async {
      final previous = remoteSettleDelay;
      remoteSettleDelay = const Duration(seconds: 30);
      addTearDown(() => remoteSettleDelay = previous);
      await setUpHandler(
        prefetch: true,
        gated: {'song-1'},
        timeouts: const NavisPlaybackTimeouts(
          remoteLoad: Duration(milliseconds: 300),
        ),
      );
      await prefetchAnswered('song-1');
      expect(warmEnd('song-1')['outcome'], 'timeout');
      expect(handler.debugRemoteFullDownloadHeld('song-1'), isTrue);
      expect(handler.debugRemoteSettlingCount, 1);
      await handler.playFromIndex(1);
      await settleQueue(handler);
      expect(count('song-1'), 1, reason: 'no parallel request');
    });

    test(
      'disposeHandler closes the prefetch connection and settle timers',
      () async {
        await setUpHandler(prefetch: true, gated: {'song-1'});
        await until(() => count('song-1') == 1, reason: 'prefetch request');
        await handler.disposeHandler();
        await until(() => closed.contains('song-1'), reason: 'socket closed');
        expect(handler.debugRemoteSettlingCount, 0);
      },
    );

    test('no prefetch starts in radio mode', () async {
      await setUpHandler(prefetch: true);
      await prefetchAnswered('song-1');
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: 'https://radio.example/live',
      );
      await handler.removeQueueItemAt(1);
      await pumpEventQueue();
      await quiet();
      expect(count('song-2'), 0);
    });

    test('desktop: the sidecar download of the next song waits for the '
        'prefetch and the settle delay', () async {
      final previous = remoteSettleDelay;
      remoteSettleDelay = const Duration(seconds: 1);
      addTearDown(() => remoteSettleDelay = previous);
      final sidecar = BridgeSidecar();
      await setUpHandler(
        prefetch: true,
        desktop: true,
        sidecarStreams: true,
        sidecar: sidecar,
        gated: {'song-1'},
      );
      await until(() => count('song-1') == 1, reason: 'prefetch request');
      // The current song's own download finishes, so the next one may start.
      expect(sidecar.song, 'song-0');
      await sidecar.finish();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(sidecar.starts, 1, reason: 'prefetch in flight');
      gates['song-1']!.complete();
      await prefetchAnswered('song-1');
      expect(sidecar.starts, 1, reason: 'settle delay running');
      await until(
        () => sidecar.song == 'song-1',
        reason: 'download after delay',
      );
    });
  });
}
