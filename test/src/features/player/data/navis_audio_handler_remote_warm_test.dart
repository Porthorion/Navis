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
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/data/lock_cache_follower_source.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/data/playback_transport_trace.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';

import 'navis_audio_handler_navigation_harness.dart';

/// A resolver that can be told to build direct streams only, as a recovery
/// or offset reload does (`preferLockCaching: false`).
class DirectOnlyResolver extends GatedSourceResolver {
  new(super.delegate);
  bool forceDirect = false;

  @override
  Future<ResolvedPlaybackSource> resolveForSong(
    SongsTableData song, {
    bool preferLockCaching = true,
    bool allowStreaming = true,
    Duration? transcodeOffset,
    bool fastSeekBridge = false,
  }) => delegate.resolveForSong(
    song,
    preferLockCaching: preferLockCaching && !forceDirect,
    allowStreaming: allowStreaming,
    transcodeOffset: transcodeOffset,
    fastSeekBridge: fastSeekBridge,
  );
}

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
  late NavisDatabase database;
  late PlaybackTransportTrace trace;
  final requests = <String>[];

  /// The queue [setUpHandler] loaded, for tests that load it again.
  var queueRows = <SongsTableData>[];

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
    PlaybackSourceResolver Function(PlaybackSourceResolver)? wrapResolver,
    bool Function()? readCrossfade,
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
      songCount + 2,
      cacheSongs: cacheSongs,
      hungLoadSongs: hungLoadSongs,
      rebuiltPlayers: hungLoadSongs == null
          ? null
          : <ControllableAudioPlayer>[],
      readApiClient: () => api,
      readNextSongPrefetchAllowed: () => prefetchAllowed,
      // Unset means Android on its direct-stream path: the host platform would
      // make these tests desktop, which does no warm (#681).
      desktopRuntimeOverride: desktop ?? false,
      positionStreams: positionStreams,
      sidecarStreams: sidecarStreams,
      sidecarDownloader: sidecar,
      transportTrace: trace,
      queueWindow: queueWindow,
      wrapResolver:
          wrapResolver ?? (desktop == null ? DirectStreamResolver.new : null),
      timeouts: timeouts,
      crossfade: crossfade,
      readCrossfade: readCrossfade,
      replayGainInPipeline: replayGainInPipeline,
      readReplayGainMode: () => replayGainMode,
      replayGainUntaggedDb: -6,
    );
    handler = created.$1;
    player = created.$2;
    database = created.$3;
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
    queueRows = [
      for (final id in ids)
        rows[id]!.copyWith(isExternal: !localIds.contains(id)),
    ];
    await handler.replaceQueueWithData(
      queueRows,
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
      bool crossfade = false,
      bool positionStreams = false,
      bool Function()? readCrossfade,
      Set<String> gated = const {'song-1'},
      Set<String>? hungLoadSongs,
      PlaybackSourceResolver Function(PlaybackSourceResolver)? wrapResolver,
    }) => setUpHandler(
      hungLoadSongs: hungLoadSongs,
      prefetch: prefetch,
      crossfade: crossfade,
      readCrossfade: readCrossfade,
      positionStreams: positionStreams,
      desktop: false,
      gated: gated,
      wrapResolver: wrapResolver,
      localIds: {'song-0'},
      cacheSongs: true,
      uncached: {
        'song-1',
        'song-2',
        'song-3',
        'song-4',
        'song-5',
        'song-6',
        'song-7',
      },
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

    /// The player's own preload of [id]: its lock-cache source fetches the
    /// origin without any navigation asking for it.
    Future<void> playerFetches(String id) async {
      unawaited(
        handler
            .debugRegisteredLockCacheSource(id)!
            .prefetch()
            .catchError((Object _) {}),
      );
      await until(() => fetched(id) == 1, reason: 'player fetch of $id');
    }

    test('Android: the initial play of a cold remote song is one origin '
        'request and waits for its headers (#653)', () async {
      final release = Timer(const Duration(milliseconds: 700), () {
        gates['song-2']!.complete();
      });
      addTearDown(release.cancel);
      final watch = Stopwatch()..start();
      await setUpHandler(
        prefetch: true,
        desktop: false,
        gated: {'song-2'},
        localIds: {'song-0'},
        cacheSongs: true,
        uncached: {'song-1', 'song-2', 'song-3', 'song-4', 'song-5'},
        startIndex: 2,
      );
      expect(watch.elapsedMilliseconds, greaterThan(600));
      expect(count('song-2'), 0, reason: 'no Range 0-1 warm');
      expect(fetched('song-2'), 1);
      final start = records(
        'remoteWarm',
      ).firstWhere((e) => e['phase'] == 'start' && e['trigger'] == 'initial');
      expect(start['startedBy'], 'lockCache');
    });

    test('Android: a direct-stream reload keeps the two-byte warm and does '
        'not fetch through the unused registered source (#653)', () async {
      late DirectOnlyResolver resolver;
      await setUpAndroid(
        prefetch: false,
        gated: {},
        wrapResolver: (base) => resolver = DirectOnlyResolver(base),
      );
      expect(handler.debugRegisteredLockCacheSource('song-1'), isNotNull);
      resolver.forceDirect = true;
      requests.clear();
      fetches.clear();
      await handler.replaceQueueWithData(queueRows, startIndex: 1);
      await settleQueue(handler);
      expect(handler.snapshot.currentSongId, 'song-1');
      expect(count('song-1'), 1, reason: 'the two-byte warm');
      expect(fetched('song-1'), 0, reason: 'no whole-file fetch');
    });

    test('Android: dispose cancels a registered download still running '
        '(#653)', () async {
      await setUpAndroid(prefetch: false, gated: {'song-3'});
      await playerFetches('song-3');
      await handler.disposeHandler();
      await until(
        () => closed.contains('song-3'),
        reason: 'origin connection of song-3 closed',
      );
    });

    test('Android: a prefetch still starting when dispose begins never '
        'reaches the origin or the cache folder (#720)', () async {
      await setUpAndroid(prefetch: false, gated: {});
      final source = handler.debugRegisteredLockCacheSource('song-3')!;
      final folder = (await source.cacheFile).parent;
      List<String> listing() =>
          folder.listSync().map((e) => e.path).toList()..sort();
      final before = listing();
      unawaited(source.prefetch().catchError((Object _) {}));
      await handler.disposeHandler();
      await quiet();
      expect(fetched('song-3'), 0);
      expect(listing(), before);
      // The player retrying after our cancel error must not restart it.
      await expectLater(source.request(), throwsA(isA<StateError>()));
      await quiet();
      expect(fetched('song-3'), 0);
      expect(listing(), before);
    });

    test('Android: a download finishing as dispose begins starts no next-song '
        'warm (#720)', () async {
      await setUpAndroid();
      await until(() => fetched('song-1') == 1, reason: 'lock-cache fetch');
      gates['song-1']!.complete();
      await handler.disposeHandler();
      await quiet();
      expect(fetched('song-2'), 0);
    });

    test('Android: re-publishing the old current song during a far '
        'navigation keeps the target fetch (#653)', () async {
      await setUpAndroid(prefetch: false, gated: {'song-5'});
      final navigation = handler.playFromIndex(5);
      await until(() => fetched('song-5') == 1, reason: 'target fetch');
      await pumpEventQueue();
      // The player reports its index again and the like state re-publishes
      // the current item, as on any state change during the wait.
      player.emitIndexAgain();
      await handler.toggleLike();
      await quiet();
      expect(closed, isNot(contains('song-5')));
      gates['song-5']!.complete();
      await navigation;
      await settleQueue(handler);
      expect(handler.snapshot.currentSongId, 'song-5');
      expect(fetched('song-5'), 1);
    });

    test('Android: Repeat All keeps the downloads wrapped past the end '
        '(#653)', () async {
      await setUpAndroid(prefetch: false, gated: {'song-1'});
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      await playerFetches('song-1');
      await handler.playFromIndex(4);
      await settleQueue(handler);
      await quiet();
      expect(handler.snapshot.currentSongId, 'song-4');
      expect(closed, isNot(contains('song-1')));
      expect(fetched('song-1'), 1);
    });

    test('Android: user Repeat One keeps only the current song download '
        '(#653)', () async {
      await setUpAndroid(prefetch: false, gated: {'song-3'});
      await handler.setRepeatMode(AudioServiceRepeatMode.one);
      await playerFetches('song-3');
      await handler.playFromIndex(1);
      await settleQueue(handler);
      await until(
        () => closed.contains('song-3'),
        reason: 'song-3 download cancelled',
      );
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

    test('desktop: no warm request, the next song\'s sidecar download '
        'starts at once (#681)', () async {
      final sidecar = BridgeSidecar();
      await setUpHandler(
        prefetch: true,
        desktop: true,
        sidecarStreams: true,
        sidecar: sidecar,
      );
      expect(sidecar.song, 'song-0');
      await sidecar.finish();
      // The fake clears `song` after the completion callback, which already
      // started the next download: two starts, no settle delay in between.
      await until(
        () => sidecar.starts == 2,
        reason: 'download of the next song, not held',
      );
      await quiet();
      expect(requests, isEmpty);
      expect(
        records('remoteWarm').where((e) => e['trigger'] == 'prefetch'),
        isEmpty,
      );
    });

    // #653 crossfade: after a swap the active deck must keep the lock-cache
    // followers, so navigation warms join the one writer's download. The fake
    // player cannot show just_audio's removal-time range-fetch cancel (the
    // vendored retain flag and the real-player tests cover it).
    Future<ControllableAudioPlayer> swap() async {
      final deck = handler.debugInactiveDeck! as ControllableAudioPlayer;
      await handler.debugStartCrossfade();
      await until(() => deck.playing, reason: 'incoming deck started');
      await handler.debugCompleteCrossfade();
      await settleQueue(handler);
      expect(handler.debugActivePlayer, same(deck));
      return deck;
    }

    // ignore: experimental_member_use, reason: as above.
    LockCachingAudioSource? writerOf(AudioSource? source) => switch (source) {
      // ignore: experimental_member_use, reason: as above.
      final LockCachingAudioSource writer => writer,
      LockCacheFollowerSource(:final leader) => leader,
      _ => null,
    };

    /// At most one writer per song across both decks, and every follower
    /// reads that writer, which is the song its row plays.
    void expectOneWriterPerSong() {
      // ignore: experimental_member_use, reason: as above.
      final writers = <String, Set<LockCachingAudioSource>>{};
      for (final deck in [
        handler.debugActivePlayer,
        handler.debugInactiveDeck!,
      ]) {
        for (final source in deck.sequence) {
          final writer = writerOf(source);
          if (writer == null) continue;
          final id = writer.uri.queryParameters['id']!;
          expect(navisNativeSourceSongId(source), id, reason: 'row of $id');
          (writers[id] ??= Set.identity()).add(writer);
        }
      }
      for (final entry in writers.entries) {
        expect(entry.value, hasLength(1), reason: 'writers of ${entry.key}');
      }
    }

    void expectLockCacheStart(String id) {
      expect(count(id), 0, reason: 'no Range 0-1 warm');
      expect(fetched(id), 1, reason: 'one origin fetch');
      final start = records('remoteWarm').lastWhere(
        (e) =>
            e['songId'] == id &&
            (e['phase'] == 'start' || e['phase'] == 'join'),
      );
      expect(start['startedBy'], 'lockCache');
    }

    test('Android crossfade: Next after one swap is a lock-cache start with '
        'one fetch (#653)', () async {
      await setUpAndroid(prefetch: false, crossfade: true, gated: {});
      await swap();
      expectOneWriterPerSong();
      await handler.skipToNext();
      await settleQueue(handler);
      expect(handler.snapshot.currentSongId, 'song-2');
      expectLockCacheStart('song-2');
      expectOneWriterPerSong();
    });

    test('Android crossfade: a far jump after one swap is a lock-cache '
        'start with one fetch (#653)', () async {
      await setUpAndroid(prefetch: false, crossfade: true, gated: {});
      await swap();
      await handler.playFromIndex(4);
      await settleQueue(handler);
      expect(handler.snapshot.currentSongId, 'song-4');
      expectLockCacheStart('song-4');
    });

    test(
      'Android crossfade: the swaps alternate decks without reloading the '
      'parked deck and the follower deck keeps the lock cache (#653)',
      () async {
        await setUpAndroid(prefetch: false, crossfade: true, gated: {});
        final first = await swap();
        expectOneWriterPerSong();
        final loadsBeforeSecond = player.setAudioSourcesCounts.length;
        await swap();
        expect(
          player.setAudioSourcesCounts,
          hasLength(loadsBeforeSecond),
          reason: 'the parked deck already matches the queue',
        );
        expectOneWriterPerSong();
        final loadsBeforeThird = first.setAudioSourcesCounts.length;
        expect(await swap(), same(first));
        expect(first.setAudioSourcesCounts, hasLength(loadsBeforeThird));
        expect(handler.snapshot.currentSongId, 'song-3');
        expectOneWriterPerSong();
        await handler.skipToNext();
        await settleQueue(handler);
        expect(handler.snapshot.currentSongId, 'song-4');
        expectLockCacheStart('song-4');
      },
    );

    Future<List<SongsTableData>> externalSongs(List<String> songIds) async => [
      for (final row in await database.libraryDao.getSongsByIds(songIds))
        row.copyWith(isExternal: true),
    ];

    test('Android crossfade: a song inserted after a swap reaches the parked '
        'deck as a follower of the active writer (#653)', () async {
      await setUpAndroid(prefetch: false, crossfade: true, gated: {});
      final first = await swap();
      final parked = handler.debugInactiveDeck! as ControllableAudioPlayer;
      await handler.insertQueueRuns([
        QueueInsertRun(6, await externalSongs(['song-6'])),
      ]);
      await settleQueue(handler);
      final active = handler.debugActivePlayer.sequence[6];
      final mirrored = parked.sequence[6];
      // ignore: experimental_member_use, reason: as above.
      expect(active, isA<LockCachingAudioSource>());
      expect(mirrored, isA<LockCacheFollowerSource>());
      expect(writerOf(mirrored), same(active));
      expect(writerOf(active)!.retainDownloadForFollowers, isTrue);
      expectOneWriterPerSong();
      await swap();
      expect(handler.debugActivePlayer, isNot(same(first)));
      await handler.playFromIndex(6);
      await settleQueue(handler);
      expect(handler.snapshot.currentSongId, 'song-6');
      expectLockCacheStart('song-6');
      expectOneWriterPerSong();
    });

    test('Android crossfade: a repeat inserted after a swap never puts the '
        'parked deck writer on the active deck (#653)', () async {
      await setUpAndroid(prefetch: false, crossfade: true, gated: {});
      await swap();
      await handler.insertQueueRuns([
        QueueInsertRun(2, await externalSongs(['song-4'])),
      ]);
      await settleQueue(handler);
      expectOneWriterPerSong();
      final active = handler.debugActivePlayer.sequence;
      expect(active[2], isA<LockCacheFollowerSource>());
      expect(writerOf(active[2]), same(writerOf(active[5])));
    });

    test('Android crossfade: a parked deck rebuilt after a failed mirror '
        'keeps following the live writer (#653)', () async {
      await setUpAndroid(prefetch: false, crossfade: true, gated: {'song-3'});
      await swap();
      await playerFetches('song-3');
      final parked = handler.debugInactiveDeck! as ControllableAudioPlayer;
      parked.failAppendSongId = 'song-6';
      await handler.insertQueueRuns([
        QueueInsertRun(6, await externalSongs(['song-6'])),
      ]);
      await settleQueue(handler);
      parked.failAppendSongId = null;
      final writer = handler.debugRegisteredLockCacheSource('song-3')!;
      expect(writerOf(handler.debugActivePlayer.sequence[3]), same(writer));
      await handler.debugStartCrossfade();
      await settleQueue(handler);
      expect(parked.sequence, hasLength(7), reason: 'the deck was rebuilt');
      expect(parked.sequence[3], isA<LockCacheFollowerSource>());
      expect(writerOf(parked.sequence[3]), same(writer));
      expect(handler.debugRegisteredLockCacheSource('song-3'), same(writer));
      expect(fetched('song-3'), 1);
      expectOneWriterPerSong();
    });

    test('Android crossfade: the diagnostics count the sources of each deck '
        '(#653)', () async {
      await setUpAndroid(prefetch: false, crossfade: true, gated: {});
      await swap();
      final crossfade = fade(handler);
      expect(crossfade['activeDeckSources'], {
        'writer': 0,
        'follower': 5,
        'copy': 0,
        'other': 1,
      });
      expect(crossfade['inactiveDeckSources'], {
        'writer': 5,
        'follower': 0,
        'copy': 0,
        'other': 1,
      });
      // Every writer that followers read is flagged.
      for (final source in handler.debugInactiveDeck!.sequence) {
        final writer = writerOf(source);
        // ignore: experimental_member_use, reason: as above.
        if (writer != null) expect(writer.retainDownloadForFollowers, isTrue);
      }
    });

    test('Android crossfade: a plain copy of a lock-cached song is counted '
        'as a copy, not as another source (#653)', () async {
      await setUpAndroid(prefetch: false, crossfade: true, gated: {});
      await swap();
      final parked = handler.debugInactiveDeck! as ControllableAudioPlayer;
      await parked.setAudioSources([
        for (final item in handler.queue.value)
          AudioSource.uri(
            Uri.parse(
              'http://127.0.0.1:${server.port}/rest/stream?id=${item.id}',
            ),
            tag: item,
          ),
      ]);
      expect(fade(handler)['inactiveDeckSources'], {
        'writer': 0,
        'follower': 0,
        'copy': ids.length - 1,
        'other': 1,
      });
    });

    // ignore: experimental_member_use, reason: as above.
    Set<LockCachingAudioSource> heldWriters() => {
      for (final deck in [
        handler.debugActivePlayer,
        handler.debugInactiveDeck!,
      ])
        for (final source in deck.sequence)
          if (writerOf(source) case final writer?) writer,
    };

    test('Android crossfade: timeout recovery clears the retain flag of every '
        'writer, a follower being the retired current row (#653)', () async {
      await setUpAndroid(
        prefetch: false,
        crossfade: true,
        gated: {'song-1'},
        hungLoadSongs: {},
      );
      await swap();
      await playerFetches('song-1');
      final active = handler.debugActivePlayer;
      expect(
        active.sequence[active.currentIndex!],
        isA<LockCacheFollowerSource>(),
      );
      final writers = heldWriters();
      expect(writers, isNotEmpty);
      // ignore: experimental_member_use, reason: as above.
      expect(writers.every((w) => w.retainDownloadForFollowers), isTrue);
      await handler.debugRecoverPlayersFromTimeout();
      // ignore: experimental_member_use, reason: as above.
      expect(writers.any((w) => w.retainDownloadForFollowers), isFalse);
      await until(() => closed.contains('song-1'), reason: 'retired download');
      expect(handler.debugRegisteredLockCacheSource('song-1'), isNull);
    });

    test('Android crossfade: disposing the handler clears the retain flag of '
        'every writer (#653)', () async {
      await setUpAndroid(prefetch: false, crossfade: true, gated: {});
      await swap();
      final writers = heldWriters();
      expect(writers, isNotEmpty);
      // ignore: experimental_member_use, reason: as above.
      expect(writers.every((w) => w.retainDownloadForFollowers), isTrue);
      await handler.disposeHandler();
      // ignore: experimental_member_use, reason: as above.
      expect(writers.any((w) => w.retainDownloadForFollowers), isFalse);
    });

    test('Android crossfade: range priority follows a follower to its '
        'writer (#653)', () async {
      final directory = await Directory.systemTemp.createTemp('navis-r653-');
      addTearDown(() => directory.delete(recursive: true));
      final sources = {
        for (final id in ids)
          id: RangeCacheSource(id, File('${directory.path}/$id.mp3')),
      };
      await setUpAndroid(
        prefetch: false,
        crossfade: true,
        positionStreams: true,
        gated: {},
        wrapResolver: (base) => RangeCacheResolver(base, sources),
      );
      addTearDown(() async {
        for (final source in sources.values) {
          await source.progress.close();
        }
      });
      final deck = await swap();
      sources['song-1']!.activeRange = true;
      deck.emitBuffered(const Duration(seconds: 2));
      await pumpEventQueue();
      for (final id in ['song-1', 'song-2', 'song-3']) {
        expect(sources[id]!.paused, isTrue, reason: id);
      }
    });

    test('Android crossfade: the download window after a swap keeps the '
        'current and next three songs (#653)', () async {
      await setUpAndroid(
        prefetch: false,
        crossfade: true,
        gated: {'song-2', 'song-5'},
      );
      await playerFetches('song-2');
      await playerFetches('song-5');
      await swap();
      await until(() => closed.contains('song-5'), reason: 'song-5 dropped');
      expect(closed, isNot(contains('song-2')));
    });

    test('Android crossfade: crossfade turned off after a swap keeps Next a '
        'lock-cache start (#653)', () async {
      var crossfadeOn = true;
      await setUpAndroid(
        prefetch: false,
        crossfade: true,
        gated: {},
        readCrossfade: () => crossfadeOn,
      );
      await swap();
      crossfadeOn = false;
      await handler.applyRuntimeSettings();
      await settleQueue(handler);
      await handler.skipToNext();
      await settleQueue(handler);
      expect(handler.snapshot.currentSongId, 'song-2');
      expectLockCacheStart('song-2');
    });

    test('Android crossfade: a queue replace after a swap rebuilds one '
        'writer per song that the active deck reads (#653)', () async {
      await setUpAndroid(prefetch: false, crossfade: true, gated: {});
      await swap();
      await handler.replaceQueueWithData(queueRows, startIndex: 0);
      await settleQueue(handler);
      expectOneWriterPerSong();
      for (final id in ['song-2', 'song-3']) {
        final index = ids.indexOf(id);
        expect(
          writerOf(handler.debugActivePlayer.sequence[index]),
          same(handler.debugRegisteredLockCacheSource(id)),
          reason: id,
        );
      }
      expect(fetched('song-1'), 0);
    });

    test('Android without crossfade: Next is a lock-cache start and the '
        'player holds no follower (#653)', () async {
      await setUpAndroid(prefetch: false, gated: {});
      await handler.skipToNext();
      await settleQueue(handler);
      expectLockCacheStart('song-1');
      expect(player.sequence.whereType<LockCacheFollowerSource>(), isEmpty);
    });

    test('desktop crossfade: the deck holds direct streams, no lock-cache '
        'sources (#653)', () async {
      await setUpHandler(
        desktop: true,
        crossfade: true,
        sidecarStreams: true,
        sidecar: BridgeSidecar(),
        localIds: {'song-0'},
        cacheSongs: true,
        uncached: {'song-1', 'song-2', 'song-3', 'song-4', 'song-5'},
      );
      final deck = await swap();
      for (final source in [
        ...deck.sequence,
        ...handler.debugInactiveDeck!.sequence,
      ]) {
        expect(writerOf(source), isNull);
      }
    });
  });

  group('desktop restores the 1.5.1 start: no remote warm (#681)', () {
    test('the queue load sends no warm request', () async {
      await setUpHandler(desktop: true);
      expect(records('remoteWarm'), isEmpty);
      expect(requests, isEmpty);
    });

    test(
      'Next to a cold remote song switches at once: no warm, no mute',
      () async {
        await setUpHandler(desktop: true);
        final navigation = handler.skipToNext();
        await pumpEventQueue();
        expect(player.volume, 1.0);
        await navigation;
        await settleQueue(handler);
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(requests, isEmpty);
        expect(records('remoteWarm'), isEmpty);
        expect(player.volume, 1.0);
      },
    );

    test(
      'a jump to a cold remote song is not muted and sends no warm',
      () async {
        await setUpHandler(desktop: true);
        final navigation = handler.playFromIndex(3);
        await pumpEventQueue();
        expect(player.volume, 1.0);
        await navigation;
        await settleQueue(handler);
        expect(handler.snapshot.currentSongId, 'song-3');
        expect(requests, isEmpty);
        expect(records('remoteWarm'), isEmpty);
      },
    );
  });

  group('Android keeps the remote warm (#681)', () {
    test('the queue load and a navigation still warm', () async {
      await setUpHandler(desktop: false);
      expect(
        records('remoteWarm')
            .where((e) => e['phase'] == 'start' && e['trigger'] == 'initial'),
        isNotEmpty,
      );
      await handler.playFromIndex(3);
      await settleQueue(handler);
      expect(warmEnd('song-3')['trigger'], 'navigate');
    });
  });

  group('desktop: a finished sidecar replaces the queued stream (#685)', () {
    late BridgeSidecar sidecar;
    late SwapProbeResolver probe;

    Future<void> setUpDesktop({bool crossfade = false}) async {
      sidecar = BridgeSidecar();
      await setUpHandler(
        prefetch: true,
        desktop: true,
        crossfade: crossfade,
        sidecarStreams: true,
        sidecar: sidecar,
        wrapResolver: (base) => probe = SwapProbeResolver(base),
      );
      await settleQueue(handler);
    }

    /// Lets the chain reach [id], then finishes its download.
    Future<void> finishSidecarOf(String id) async {
      // The fake clears `song` after each completion, so count the starts.
      final start = ids.indexOf(id) + 1;
      await until(() => sidecar.starts >= start, reason: 'sidecar on $id');
      expect(sidecar.downloadUri!.queryParameters['id'], id);
      await sidecar.finish();
    }

    bool isFile(int index) {
      final source = player.sequence[index];
      return source is UriAudioSource && source.uri.scheme == 'file';
    }

    int resolves(String id) => probe.calls.where((c) => c == id).length;

    int starved() => [
      for (final e in trace.entries)
        if (e['decision'] == 'starvedWithFile') e,
    ].length;

    void expectNoStreamTraffic() {
      expect(fetches, isEmpty);
      expect(requests, isEmpty);
    }

    test('the finished next song is a file; Next plays it with no rebuild '
        'and no stream request', () async {
      await setUpDesktop();
      await finishSidecarOf('song-0');
      await finishSidecarOf('song-1');
      await settleQueue(handler);
      expect(player.sourceIds.take(2), ['song-0', 'song-1']);
      expect(isFile(1), isTrue);
      final loads = player.sourceLoads;
      await handler.skipToNext();
      await settleQueue(handler);
      expect(handler.snapshot.currentSongId, 'song-1');
      expect(isFile(1), isTrue);
      expect(player.sourceLoads, loads);
      expect(starved(), 0);
      expectNoStreamTraffic();
    });

    test('Next while the swap is still queued lands on the file', () async {
      await setUpDesktop();
      await finishSidecarOf('song-0');
      await finishSidecarOf('song-1');
      await handler.skipToNext();
      await settleQueue(handler);
      expect(handler.snapshot.currentSongId, 'song-1');
      expect(isFile(1), isTrue);
      expectNoStreamTraffic();
    });

    test(
      'a quality mismatch resolves once and is dropped, no swap loop',
      () async {
        await setUpDesktop();
        probe.streamOnly.add('song-1');
        await finishSidecarOf('song-0');
        final base = resolves('song-1');
        await finishSidecarOf('song-1');
        await settleQueue(handler);
        expect(resolves('song-1'), base + 1);
        expect(isFile(1), isFalse);
        // Another trigger finds nothing pending for it.
        await handler.skipToNext();
        await handler.skipToNext();
        await settleQueue(handler);
        expect(resolves('song-1'), base + 1);
      },
    );

    test('a song that became current during the swap insert keeps its stream '
        'and stays pending', () async {
      await setUpDesktop();
      await finishSidecarOf('song-0');
      final stream = player.audioSources[1];
      final gate = Completer<void>();
      player.insertGate = gate;
      player.insertEntered = Completer<void>();
      await finishSidecarOf('song-1');
      await player.insertEntered!.future;
      player.index = 1;
      player.indexEvents.add(1);
      gate.complete();
      await settleQueue(handler);
      expect(player.sequence.length, 6);
      expect(player.audioSources[1], same(stream));
      expect(isFile(1), isFalse);
      expect(handler.debugFileSwapPending, contains('song-1'));
      expect([
        for (final s in player.sequence) navisNativeSourceSongId(s),
      ], ids.take(6).toList());
    });

    test('crossfade on, not fading: the deck mirror gets the file', () async {
      await setUpDesktop(crossfade: true);
      // One completed fade leaves both decks holding the whole queue.
      final deck = handler.debugInactiveDeck! as ControllableAudioPlayer;
      await handler.debugStartCrossfade();
      await until(() => deck.playing, reason: 'incoming deck started');
      await handler.debugCompleteCrossfade();
      await settleQueue(handler);
      final other = handler.debugInactiveDeck! as ControllableAudioPlayer;
      expect(other.sequence.length, 6);
      // Each finish starts the next download; walk to song-2's.
      for (var i = 0; i < 4; i++) {
        if (sidecar.downloadUri!.queryParameters['id'] == 'song-2') break;
        await sidecar.finish();
        await pumpEventQueue();
      }
      expect(sidecar.downloadUri!.queryParameters['id'], 'song-2');
      await sidecar.finish();
      await settleQueue(handler);
      for (final p in [deck, other]) {
        final source = p.sequence[2];
        expect(source is UriAudioSource && source.uri.scheme == 'file', isTrue);
      }
    });

    test('the current song re-published before the edit does not lose the '
        'swap', () async {
      await setUpDesktop();
      await finishSidecarOf('song-0');
      await finishSidecarOf('song-1');
      // Removing a later song re-publishes the current media item.
      await handler.removeQueueItemAt(5);
      await settleQueue(handler);
      expect(isFile(1), isTrue);
    });

    test('a sidecar finishing while a crossfade onto it runs is skipped, '
        'with no deck removal and no cut', () async {
      await setUpDesktop(crossfade: true);
      await finishSidecarOf('song-0');
      final deck = handler.debugInactiveDeck! as ControllableAudioPlayer;
      player.simulatedPosition =
          const Duration(minutes: 3) - const Duration(seconds: 4);
      handler.debugCheckCrossfadeTrigger(player.position);
      await until(() => fade(handler)['active'] == true, reason: 'fading');
      await until(() => deck.sequence.isNotEmpty, reason: 'deck loaded');
      await settleQueue(handler);
      final removedBefore = deck.sequence.length;
      final targetBefore = deck.sequence[1];
      final loads = deck.sourceLoads + player.sourceLoads;
      final base = resolves('song-1');
      await finishSidecarOf('song-1');
      await settleQueue(handler);
      expect(deck.sequence.length, removedBefore);
      expect(deck.sequence[1], same(targetBefore));
      expect(deck.sourceLoads + player.sourceLoads, loads);
      expect(resolves('song-1'), base);
      expect(fade(handler)['active'], isTrue);
    });

    test('a crossfade starting during the swap insert keeps the deck entry, '
        'and the id stays pending', () async {
      await setUpDesktop(crossfade: true);
      final first = handler.debugInactiveDeck! as ControllableAudioPlayer;
      await handler.debugStartCrossfade();
      await until(() => first.playing, reason: 'incoming deck started');
      await handler.debugCompleteCrossfade();
      await settleQueue(handler);
      final active = handler.debugActivePlayer as ControllableAudioPlayer;
      final deck = handler.debugInactiveDeck! as ControllableAudioPlayer;
      for (var i = 0; i < 4; i++) {
        if (sidecar.downloadUri!.queryParameters['id'] == 'song-2') break;
        await sidecar.finish();
        await pumpEventQueue();
      }
      expect(sidecar.downloadUri!.queryParameters['id'], 'song-2');
      await settleQueue(handler);
      final deckBefore = deck.sequence[2];
      final mainBefore = active.sequence[2];
      final gate = Completer<void>();
      active.insertGate = gate;
      active.insertEntered = Completer<void>();
      await sidecar.finish();
      await active.insertEntered!.future;
      active.simulatedPosition =
          const Duration(minutes: 3) - const Duration(seconds: 4);
      handler.debugCheckCrossfadeTrigger(active.position);
      await until(() => fade(handler)['active'] == true, reason: 'fading');
      gate.complete();
      await settleQueue(handler);
      expect(deck.sequence[2], same(deckBefore));
      expect(active.sequence[2], same(mainBefore));
      expect(active.sequence.length, 6);
      expect(handler.debugFileSwapPending, contains('song-2'));
    });

    test('a queue replacement clears the pending swaps', () async {
      await setUpDesktop();
      await finishSidecarOf('song-0');
      probe.blockedSongId = 'song-1';
      probe.failure = StateError('unavailable');
      await finishSidecarOf('song-1');
      await settleQueue(handler);
      expect(handler.debugFileSwapPending, contains('song-1'));
      await handler.replaceQueueWithData(queueRows, startIndex: 0);
      await settleQueue(handler);
      expect(handler.debugFileSwapPending, isEmpty);
    });

    test('Android lock-cache completion makes no queue edit', () async {
      final directory = await Directory.systemTemp.createTemp('navis-lock-');
      addTearDown(() => directory.delete(recursive: true));
      final created = <WarmRangeSource>[];
      await setUpHandler(
        desktop: false,
        wrapResolver: (base) => FreshRangeResolver(base, directory, created),
      );
      final lock = created.firstWhere(
        (s) => s.uri.queryParameters['id'] == 'song-1',
      );
      File('${directory.path}/song-1.mp3').writeAsBytesSync(List.filled(64, 1));
      final loads = player.sourceLoads;
      lock.progress.add(1);
      await pumpEventQueue(times: 50);
      await settleQueue(handler);
      expect(handler.debugLockCacheCompleted('song-1'), isTrue);
      expect(handler.debugFileSwapPending, isEmpty);
      expect(player.sourceLoads, loads);
    });

    test('an unavailable prepared source keeps the id pending; a later '
        'trigger swaps', () async {
      await setUpDesktop();
      await finishSidecarOf('song-0');
      probe.blockedSongId = 'song-1';
      probe.failure = StateError('unavailable');
      await finishSidecarOf('song-1');
      await settleQueue(handler);
      expect(isFile(1), isFalse);
      probe.blockedSongId = null;
      probe.failure = null;
      // Moving two songs ahead leaves song-1 behind: navigation repairs it.
      await handler.skipToNext();
      await handler.skipToNext();
      await settleQueue(handler);
      await until(() => isFile(1), reason: 'later trigger swaps');
    });
  });
}

/// Counts resolves and can answer a stream where a finished file would be.
class SwapProbeResolver extends GatedSourceResolver {
  new(super.delegate);
  final calls = <String>[];
  final streamOnly = <String>{};

  @override
  Future<ResolvedPlaybackSource> resolveForSong(
    SongsTableData song, {
    bool preferLockCaching = true,
    bool allowStreaming = true,
    Duration? transcodeOffset,
    bool fastSeekBridge = false,
  }) async {
    final resolved = await super.resolveForSong(
      song,
      preferLockCaching: preferLockCaching,
      allowStreaming: allowStreaming,
      transcodeOffset: transcodeOffset,
      fastSeekBridge: fastSeekBridge,
    );
    calls.add(song.id);
    if (resolved.kind == PlaybackSourceKind.file &&
        streamOnly.contains(song.id)) {
      return ResolvedPlaybackSource.directStream(
        songId: song.id,
        uri: Uri.parse('https://fixture.invalid/stream?id=${song.id}'),
        metadata: const ResolvedPlaybackMetadata(isTranscoded: false),
      );
    }
    return resolved;
  }
}
