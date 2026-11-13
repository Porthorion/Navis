import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart'
    show AudioServicePlatform;
import 'package:audio_service_platform_interface/no_op_audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/data/playback_transport_trace.dart';

import 'navis_audio_handler_navigation_harness.dart';

/// Gates only the [gateOnNth] resolve of [blockedSongId], so a test can hold
/// the retry's resolve instead of the first attempt's.
class NthGateResolver extends GatedSourceResolver {
  new(super.delegate);
  int gateOnNth = 1;
  int _seen = 0;
  String? throwFor;

  @override
  Future<ResolvedPlaybackSource> resolveForSong(
    SongsTableData song, {
    bool preferLockCaching = true,
    bool allowStreaming = true,
    Duration? transcodeOffset,
    bool fastSeekBridge = false,
  }) {
    if (song.id == throwFor) throw StateError('boom ${song.id}');
    final pass = song.id == blockedSongId && ++_seen != gateOnNth;
    if (!pass) {
      return super.resolveForSong(
        song,
        preferLockCaching: preferLockCaching,
        allowStreaming: allowStreaming,
        transcodeOffset: transcodeOffset,
        fastSeekBridge: fastSeekBridge,
      );
    }
    return delegate.resolveForSong(
      song,
      preferLockCaching: preferLockCaching,
      allowStreaming: allowStreaming,
      transcodeOffset: transcodeOffset,
      fastSeekBridge: fastSeekBridge,
    );
  }
}

// Issue #619: a song tapped in a list while a queue plays must start, be
// retried once when silently dropped, and report when it still does not.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => AudioServicePlatform.instance = NoOpAudioService());

  const small = NavisQueueWindow(
    deferThreshold: 4,
    ahead: 1,
    behind: 1,
    lowWater: 0,
    page: 2,
    nearJump: 1,
  );

  List<Map<String, Object?>> entries(
    PlaybackTransportTrace trace,
    String kind,
  ) => trace.entries.where((e) => e['kind'] == kind).toList();

  Future<
    ({
      NavisAudioHandler handler,
      ControllableAudioPlayer player,
      NavisDatabase database,
      NthGateResolver resolver,
      PlaybackTransportTrace trace,
      List<SongsTableData> rows,
      Set<String> hungSongs,
    })
  >
  fixture({
    int count = 8,
    int queueSize = 6,
    bool crossfade = false,
    NavisPlaybackTimeouts timeouts = const NavisPlaybackTimeouts(
      load: Duration(milliseconds: 400),
    ),
    bool matchFlow = false,
    NavisQueueWindow window = const NavisQueueWindow(),
    int queueStart = 0,
    String replayGainMode = 'off',
  }) async {
    final directory = await Directory.systemTemp.createTemp('i619');
    final trace = PlaybackTransportTrace(enabled: true);
    final hungSongs = <String>{};
    late NthGateResolver resolver;
    final (handler, player, database) = await createHandler(
      directory,
      count,
      crossfade: crossfade,
      timeouts: timeouts,
      matchFlow: matchFlow,
      queueWindow: window,
      transportTrace: trace,
      replayGainMode: replayGainMode,
      replayGainInPipeline: replayGainMode == 'off' ? null : true,
      // A timed-out cached file is dropped, so the retry streams.
      readApiClient: () => SubsonicApiClient(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
        ),
        enableLogging: false,
      ),
      hungLoadSongs: hungSongs,
      rebuiltPlayers: <ControllableAudioPlayer>[],
      wrapResolver: (base) => resolver = NthGateResolver(base),
    );
    addTearDown(() async {
      if (resolver.release case final r? when !r.isCompleted) r.complete();
      await handler.disposeHandler();
      await database.close();
      await directory.delete(recursive: true);
    });
    final rows = await database.libraryDao.getSongsByIds([
      for (var i = 0; i < queueSize; i++) 'song-$i',
    ]);
    await handler.replaceQueueWithData(
      rows,
      startIndex: queueStart,
      expandMatchFlows: false,
    );
    await settleQueue(handler);
    await handler.play();
    await settleQueue(handler);
    return (
      handler: handler,
      player: player,
      database: database,
      resolver: resolver,
      trace: trace,
      rows: rows,
      hungSongs: hungSongs,
    );
  }

  group('dropped tap retry', () {
    test('a non-user supersede is retried once and lands', () async {
      final f = await fixture();
      f.player..hungLoadBudget = [1];
      f.hungSongs.add('song-3');
      await f.handler.replaceQueueWithData(f.rows, startIndex: 3);
      await settleQueue(f.handler);
      expect(f.handler.snapshot.currentSongId, 'song-3');
      final dropped = entries(f.trace, 'userPlayDropped');
      expect(dropped, hasLength(1));
      expect(dropped.single['retry'], 0);
      expect(dropped.single['reason'], startsWith('timeout:'));
    });

    test('a retry that is also dropped raises the notice exception', () async {
      final f = await fixture();
      f.player..hungLoadBudget = [2];
      f.hungSongs.add('song-3');
      await expectLater(
        f.handler.replaceQueueWithData(f.rows, startIndex: 3),
        throwsA(
          isA<PlaybackSelectionDroppedException>()
              .having((e) => e.songId, 'songId', 'song-3')
              .having((e) => e.title, 'title', 'Song 3'),
        ),
      );
      await settleQueue(f.handler); // the failover the second timeout starts
      final dropped = entries(f.trace, 'userPlayDropped');
      expect(dropped.map((e) => e['retry']), <Object?>[0, 1]);
    });

    test('a single-song tap while another queue plays is retried', () async {
      final f = await fixture();
      final one = f.rows.sublist(3, 4);
      f.player..hungLoadBudget = [1];
      f.hungSongs.add('song-3');
      await f.handler.replaceQueueWithData(one);
      await until(() => !f.handler.snapshot.isLoading);
      expect(f.handler.snapshot.currentSongId, 'song-3');
      expect(entries(f.trace, 'userPlayDropped'), hasLength(1));
      f.player.hungLoadBudget![0] = 2;
      await expectLater(
        f.handler.replaceQueueWithData(one),
        throwsA(isA<PlaybackSelectionDroppedException>()),
      );
      // The failed single song stays reloadable with an empty native list.
      await until(() => !f.handler.snapshot.isLoading);
    });

    test('a failover that supersedes the tap never reaches phase 1', () async {
      final f = await fixture();
      f.player..hungLoadBudget = [1];
      f.hungSongs.add('song-3');
      f.resolver
        ..blockedSongId = 'song-4'
        ..entered = Completer<void>()
        ..release = Completer<void>();
      final tap = f.handler.replaceQueueWithData(f.rows, startIndex: 3);
      await f.resolver.entered!.future;
      f.resolver.release!.complete();
      await tap;
      await settleQueue(f.handler);
      expect(f.handler.snapshot.currentSongId, 'song-3');
      final phase1Songs = entries(
        f.trace,
        'queueFill',
      ).where((e) => e['phase'] == 'phase1Start').map((e) => e['songId']);
      expect(phase1Songs, isNot(contains('song-4')));
    });

    test('a newer user tap suppresses retry and notice', () async {
      final f = await fixture();
      f.resolver
        ..blockedSongId = 'song-3'
        ..entered = Completer<void>()
        ..release = Completer<void>();
      final first = f.handler.replaceQueueWithData(f.rows, startIndex: 3);
      await f.resolver.entered!.future;
      final second = f.handler.replaceQueueWithData(f.rows, startIndex: 4);
      f.resolver.release!.complete();
      await first;
      await second;
      await settleQueue(f.handler);
      expect(f.handler.snapshot.currentSongId, 'song-4');
      expect(entries(f.trace, 'userPlayDropped'), isEmpty);
    });

    test('a double tap on one song lands without a drop', () async {
      final f = await fixture();
      final a = f.handler.replaceQueueWithData(f.rows, startIndex: 3);
      final b = f.handler.replaceQueueWithData(f.rows, startIndex: 3);
      await Future.wait([a, b]);
      await settleQueue(f.handler);
      expect(f.handler.snapshot.currentSongId, 'song-3');
      expect(entries(f.trace, 'userPlayDropped'), isEmpty);
    });

    test('Clear queue during the retry ends it quietly', () async {
      final f = await fixture();
      f.player..hungLoadBudget = [1];
      f.hungSongs.add('song-3');
      f.resolver
        ..gateOnNth = 2
        ..blockedSongId = 'song-3'
        ..entered = Completer<void>()
        ..release = Completer<void>();
      final tap = f.handler.replaceQueueWithData(f.rows, startIndex: 3);
      await f.resolver.entered!.future;
      final clearing = f.handler.clearQueue();
      f.resolver.release!.complete();
      await tap;
      await clearing;
      await settleQueue(f.handler);
      expect(f.handler.snapshot.queueSongIds, isEmpty);
      final dropped = entries(f.trace, 'userPlayDropped');
      expect(dropped, hasLength(1));
      expect(dropped.single['retry'], 0);
    });

    for (final stopInstead in [false, true]) {
      test(
        '${stopInstead ? 'stop' : 'pause'} during a gated tap: no retry',
        () async {
          final f = await fixture();
          f.resolver
            ..blockedSongId = 'song-3'
            ..entered = Completer<void>()
            ..release = Completer<void>();
          final tap = f.handler.replaceQueueWithData(f.rows, startIndex: 3);
          await f.resolver.entered!.future;
          final halting = stopInstead ? f.handler.stop() : f.handler.pause();
          f.resolver.release!.complete();
          await tap;
          await halting;
          expect(entries(f.trace, 'userPlayDropped'), isEmpty);
        },
      );
    }

    test('tapping the song that is already current lands', () async {
      final f = await fixture();
      await f.handler.replaceQueueWithData(f.rows);
      await settleQueue(f.handler);
      expect(f.handler.snapshot.currentSongId, 'song-0');
      expect(entries(f.trace, 'userPlayDropped'), isEmpty);
    });

    test('a tap with crossfade on is retried once', () async {
      final f = await fixture(crossfade: true);
      f.player..hungLoadBudget = [1];
      f.hungSongs.add('song-3');
      await f.handler.replaceQueueWithData(f.rows, startIndex: 3);
      await settleQueue(f.handler);
      expect(f.handler.snapshot.currentSongId, 'song-3');
      expect(entries(f.trace, 'userPlayDropped'), hasLength(1));
    });

    test('autoPlay false lands without a retry', () async {
      final f = await fixture();
      await f.handler.replaceQueueWithData(
        f.rows,
        startIndex: 3,
        autoPlay: false,
      );
      await settleQueue(f.handler);
      expect(f.handler.snapshot.currentSongId, 'song-3');
      expect(entries(f.trace, 'userPlayDropped'), isEmpty);
    });

    test('the ids path carries the DAO title on the final failure', () async {
      final f = await fixture();
      f.player..hungLoadBudget = [2];
      f.hungSongs.add('song-3');
      await expectLater(
        f.handler.replaceQueue(<String>[
          for (var i = 0; i < 6; i++) 'song-$i',
        ], startIndex: 3),
        throwsA(
          isA<PlaybackSelectionDroppedException>().having(
            (e) => e.title,
            'title',
            'Song 3',
          ),
        ),
      );
      await settleQueue(f.handler);
    });

    test('a far-jump load failure is recorded as a loadFailure', () async {
      final f = await fixture(count: 60, queueSize: 60, window: small);
      f.player.failLoadSongId = 'song-50';
      await f.handler.playFromIndex(50);
      await until(
        () =>
            f.handler.snapshot.lastFailedSongId == 'song-50' &&
            !f.handler.snapshot.isLoading,
      );
      final failures = entries(f.trace, 'loadFailure');
      expect(failures, isNotEmpty);
      expect(failures.first['songId'], 'song-50');
    });
  });

  group('stalled tap', () {
    const stall = Duration(milliseconds: 600);
    const timeouts = NavisPlaybackTimeouts(userSelectionStall: stall);

    test('notice once when the lane holds the tap past the deadline', () async {
      final f = await fixture(timeouts: timeouts);
      final stalls = <Object>[];
      f.handler.selectionStallStream.listen(stalls.add);
      // Park the adjustment sync that runs before phase 1.
      final gate = Completer<void>();
      f.player
        ..speedGate = gate
        ..speedEntered = Completer<void>();
      final tap = f.handler.replaceQueueWithData(f.rows, startIndex: 3);
      await f.player.speedEntered!.future;
      await Future<void>.delayed(stall + const Duration(milliseconds: 300));
      expect(stalls, hasLength(1));
      expect(
        (stalls.single as PlaybackSelectionDroppedException).songId,
        'song-3',
      );
      final stalled = entries(f.trace, 'userPlayStalled');
      expect(stalled, hasLength(1));
      expect(stalled.single['queueLane'], isA<Map<String, Object?>>());
      gate.complete();
      await tap;
      expect(stalls, hasLength(1));
    });

    test('no notice when phase 1 is reached before the deadline', () async {
      final f = await fixture(timeouts: timeouts);
      final stalls = <Object>[];
      f.handler.selectionStallStream.listen(stalls.add);
      f.resolver
        ..blockedSongId = 'song-3'
        ..entered = Completer<void>()
        ..release = Completer<void>();
      final tap = f.handler.replaceQueueWithData(f.rows, startIndex: 3);
      await f.resolver.entered!.future;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      f.resolver.release!.complete();
      await tap;
      await Future<void>.delayed(stall + const Duration(milliseconds: 300));
      expect(stalls, isEmpty);
      expect(entries(f.trace, 'userPlayStalled'), isEmpty);
    });

    test(
      'a slow load after phase 1 began is no stall and the retry lands',
      () async {
        final f = await fixture(
          timeouts: const NavisPlaybackTimeouts(
            load: Duration(milliseconds: 400),
            userSelectionStall: Duration(milliseconds: 100),
          ),
        );
        final stalls = <Object>[];
        f.handler.selectionStallStream.listen(stalls.add);
        f.player.hungLoadBudget = [1];
        f.hungSongs.add('song-3');
        await f.handler.replaceQueueWithData(f.rows, startIndex: 3);
        await settleQueue(f.handler);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(stalls, isEmpty);
        expect(entries(f.trace, 'userPlayStalled'), isEmpty);
        expect(f.handler.snapshot.currentSongId, 'song-3');
      },
    );

    test(
      'after a stall notice a later drop is neither retried nor reported',
      () async {
        final f = await fixture(
          timeouts: const NavisPlaybackTimeouts(
            load: Duration(milliseconds: 400),
            userSelectionStall: Duration(milliseconds: 100),
          ),
        );
        final stalls = <Object>[];
        f.handler.selectionStallStream.listen(stalls.add);
        // Hold the lane so phase 1 cannot begin, then drop the load.
        final gate = Completer<void>();
        f.player
          ..speedGate = gate
          ..speedEntered = Completer<void>();
        f.player.hungLoadBudget = [1];
        f.hungSongs.add('song-3');
        final tap = f.handler.replaceQueueWithData(f.rows, startIndex: 3);
        await f.player.speedEntered!.future;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(stalls, hasLength(1));
        gate.complete();
        await tap; // does not throw a second notice
        await settleQueue(f.handler);
        expect(stalls, hasLength(1));
        expect(f.handler.snapshot.currentSongId, isNot('song-3')); // no retry
        expect(
          entries(f.trace, 'userPlayDropped').map((e) => e['retry']),
          <Object?>[0],
        );
      },
    );

    test('no notice from a tap that a newer user tap replaced', () async {
      final f = await fixture(timeouts: timeouts);
      final stalls = <Object>[];
      f.handler.selectionStallStream.listen(stalls.add);
      f.resolver
        ..blockedSongId = 'song-3'
        ..entered = Completer<void>()
        ..release = Completer<void>();
      final first = f.handler.replaceQueueWithData(f.rows, startIndex: 3);
      await f.resolver.entered!.future;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final second = f.handler.replaceQueueWithData(f.rows, startIndex: 4);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      f.resolver.release!.complete();
      await Future.wait([first, second]);
      await Future<void>.delayed(stall + const Duration(milliseconds: 400));
      expect(f.handler.snapshot.currentSongId, 'song-4');
      expect(stalls, isEmpty);
    });
  });

  // Issue #619 (second cause): with Smart ReplayGain in the pipeline, a tap
  // whose start index is below the playing queue's deferred head threw a
  // RangeError in the neighbour lookup and then failed every such tap.
  group('smart ReplayGain with a deferred head', () {
    for (final mode in ['smart', 'track']) {
      for (final (name, album, start) in [
        ('one song at index 0', [0], 0),
        ('four songs at index 1', [0, 1, 2, 3], 1),
        ('start index below the head', [0, 1, 2, 3, 4, 5, 6, 7], 2),
        ('start index equal to the head', [0, 1, 2, 3, 4, 5, 6, 7], 6),
        ('start index above the head', [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], 8),
      ]) {
        test('$mode: $name lands and plays', () async {
          final f = await fixture(
            count: 10,
            queueSize: 10,
            window: small,
            queueStart: 7,
            replayGainMode: mode,
          );
          expect(
            f.handler.collectPlaybackDiagnostics()['deferredHeadLength'],
            6,
          );
          final rows = f.rows
              .where((r) => album.contains(int.parse(r.id.substring(5))))
              .toList();
          final target = rows[start].id;
          final seen = f.trace.entries.length;
          List<Map<String, Object?>> since(String kind) => f.trace.entries
              .skip(seen)
              .where((e) => e['kind'] == kind)
              .toList();
          await f.handler.replaceQueueWithData(rows, startIndex: start);
          await settleQueue(f.handler);
          expect(f.handler.snapshot.currentSongId, target);
          expect(f.handler.snapshot.currentIndex, start);
          expect(f.handler.snapshot.isLoading, isFalse);
          expect(
            since('sourceResolved').where((e) => e['songId'] == target),
            hasLength(1),
          );
          expect(since('userPlayFailed'), isEmpty);
        });
      }
    }
  });

  group('userPlayFailed', () {
    test('a non-cancel error is traced by type and rethrown', () async {
      final f = await fixture();
      f.resolver.throwFor = 'song-3';
      await expectLater(
        f.handler.replaceQueueWithData(f.rows, startIndex: 3),
        throwsA(isA<StateError>()),
      );
      final failed = entries(f.trace, 'userPlayFailed');
      expect(failed, hasLength(1));
      expect(failed.single['songId'], 'song-3');
      expect(failed.single['error'], 'StateError');
      expect(failed.single['retry'], 0);
    });
  });

  // Trimmed guard matrix from the #619 investigation: crossfade on, a list
  // tap while a queue plays must start the tapped song with no false drop.
  final cases =
      <
        ({
          String name,
          int queueStart,
          List<int> album,
          int tap,
          bool shuffle,
          bool matchFlow,
          NavisQueueWindow window,
        })
      >[
        for (final window in [const NavisQueueWindow(), small])
          for (final t in [
            (n: 'next', qs: 0, album: [0, 1, 2, 3, 4, 5], tap: 1),
            (n: 'current', qs: 0, album: [0, 1, 2, 3, 4, 5], tap: 0),
            (n: 'far', qs: 0, album: [0, 1, 2, 3, 4, 5, 6, 7], tap: 7),
            (n: 'absent', qs: 0, album: [10, 11, 12], tap: 1),
          ])
            (
              name: '${t.n} window=${window.deferThreshold}',
              queueStart: t.qs,
              album: t.album,
              tap: t.tap,
              shuffle: false,
              matchFlow: false,
              window: window,
            ),
        for (final matchFlow in [false, true])
          (
            name: matchFlow ? 'matchFlow on' : 'shuffle on',
            queueStart: 0,
            album: [0, 1, 2, 3, 4, 5],
            tap: 2,
            shuffle: !matchFlow,
            matchFlow: matchFlow,
            window: const NavisQueueWindow(),
          ),
      ];

  for (final c in cases) {
    test('list tap while playing: ${c.name}', () async {
      final f = await fixture(
        count: 14,
        queueSize: 10,
        crossfade: true,
        matchFlow: c.matchFlow,
        window: c.window,
      );
      if (c.shuffle) {
        await f.handler.setShuffleMode(AudioServiceShuffleMode.all);
        await settleQueue(f.handler);
      }
      final albumRows = await f.database.libraryDao.getSongsByIds([
        for (final i in c.album) 'song-$i',
      ]);
      final target = albumRows[c.tap].id;
      Future<String?> tap() async {
        await f.handler.replaceQueueWithData(albumRows, startIndex: c.tap);
        await settleQueue(f.handler);
        return f.handler.snapshot.currentSongId;
      }

      final first = await tap();
      final second = await tap();
      expect(
        (first, second, f.handler.snapshot.queueSongIds.length),
        (target, target, albumRows.length),
      );
      expect(f.handler.snapshot.playing, isTrue);
      expect(entries(f.trace, 'userPlayDropped'), isEmpty);
    });
  }

  // Mechanism: a failure the OLD player reports while the tapped song's
  // source is still resolving (before phase 1 pauses the old song).
  test('old player failure during a list tap keeps the tapped song', () async {
    final directory = await Directory.systemTemp.createTemp('i619');
    late GatedSourceResolver resolver;
    final (handler, player, database) = await createHandler(
      directory,
      8,
      wrapResolver: (base) => resolver = GatedSourceResolver(base),
    );
    addTearDown(() async {
      if (resolver.release case final r? when !r.isCompleted) r.complete();
      await handler.disposeHandler();
      await database.close();
      await directory.delete(recursive: true);
    });
    final rows = await database.libraryDao.getSongsByIds([
      for (var i = 0; i < 6; i++) 'song-$i',
    ]);
    await handler.replaceQueueWithData(rows, expandMatchFlows: false);
    await settleQueue(handler);
    await handler.play();
    await settleQueue(handler);
    resolver
      ..blockedSongId = 'song-3'
      ..entered = Completer<void>()
      ..release = Completer<void>();
    final tap = handler.replaceQueueWithData(rows, startIndex: 3);
    await resolver.entered!.future;
    player
      ..state = ProcessingState.idle
      ..isPlaying = false
      ..errorCode = 2001;
    player.playbackEvents.add(
      PlaybackEvent(
        processingState: ProcessingState.idle,
        updatePosition: const Duration(seconds: 42),
        currentIndex: 0,
        errorCode: 2001,
        errorMessage: 'Source error',
      ),
    );
    await pumpEventQueue();
    resolver.release!.complete();
    await tap;
    await settleQueue(handler);
    expect(
      handler.snapshot.currentSongId,
      'song-3',
      reason:
          'queue=${handler.snapshot.queueSongIds} '
          'idx=${handler.snapshot.currentIndex}',
    );
  });
}
