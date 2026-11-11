import 'package:flutter/foundation.dart' show listEquals;

import 'dart:math';

import 'package:navis/src/features/player/domain/playback_adjustments.dart';

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart'
    show AudioServicePlatform;
import 'package:audio_service_platform_interface/no_op_audio_service.dart';
import 'package:audio_session/audio_session.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:drift/drift.dart' show Value;
import 'package:mocktail/mocktail.dart';
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/models/models.dart' as models;
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/library/data/song_identity_reconciler.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/recommendation_service.dart';
import 'package:navis/src/features/player/presentation/personal_radio_notifier.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/data/navis_shuffle_order.dart';
import 'package:navis/src/features/player/data/real_time_projection_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';

import '../../../../helpers/test_database.dart';
import '../../../../helpers/library_sync_fakes.dart';
import '../../../../helpers/library_sync_plan.dart';
import 'navis_audio_handler_navigation_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    registerFallbackValue(const RadioFilters());
    // Linux and Windows default to the no-op platform; other hosts would talk
    // to unmocked audio_service plugin channels.
    AudioServicePlatform.instance = NoOpAudioService();
  });

  // Issue #383: a replacement that cancels the running edit before the edit
  // reaches its requeue check must not leave that edit marked as waiting, or
  // every later edit requeues itself forever on microtasks alone. That loop
  // starves timers (even the test timeout), so on a regression this test
  // hangs rather than fails: run it under a shell `timeout`.
  group('queue edit cancelled by a replacement', () {
    test('does not block a later edit', () async {
      final directory = await Directory.systemTemp.createTemp('navis-i383-');
      final (handler, _, database) = await createHandler(directory, 8);
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final ids = List<String>.generate(8, (i) => 'song-$i');
      await handler.replaceQueue(ids, expandMatchFlows: false);
      await settleQueue(handler);

      // The edit starts at once and waits for `_ready`; the replacement
      // cancels it there.
      final cancelled = handler.reorderQueue(5, 1);
      final replaced = handler.replaceQueue(
        ids.reversed.toList(),
        expandMatchFlows: false,
      );
      await expectLater(cancelled, throwsA(isA<OperationCancelledException>()));
      await replaced;

      await handler.reorderQueue(3, 0);
      expect(handler.snapshot.queueSongIds.first, 'song-4');
    });
  });

  group('idle playback recovery', () {
    NetworkReconciliation net({required bool online}) =>
        (connected: online, serverReachable: online);

    Future<(NavisAudioHandler, ControllableAudioPlayer, NavisDatabase)> setup({
      Future<NetworkReconciliation> Function()? reconcile,
      Future<bool> Function()? deviceConnected,
      Stream<void>? recovered,
      bool remote = false,
      int count = 3,
      NavisPlaybackTimeouts timeouts = const NavisPlaybackTimeouts(),
    }) async {
      final directory = await Directory.systemTemp.createTemp('navis-idle-');
      final created = await createHandler(
        directory,
        count,
        reconcileNetwork: reconcile,
        checkDeviceConnected: deviceConnected,
        recoveredNetwork: recovered,
        sidecarStreams: remote,
        timeouts: timeouts,
      );
      addTearDown(() async {
        await created.$1.disposeHandler();
        await created.$3.close();
        await directory.delete(recursive: true);
      });
      return created;
    }

    test('permanent focus loss permits a later explicit Play', () async {
      final (handler, player, _) = await setup();
      final session = TestAudioSession();
      handler.debugWireAudioSession(session);
      addTearDown(session.close);
      await handler.replaceQueue(['song-0'], expandMatchFlows: false);
      session.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown),
      );
      await pumpEventQueue();
      expect(player.playing, isFalse);
      await handler.play();
      await pumpEventQueue();
      expect(player.playing, isTrue);
    });

    test('headphone removal cancels a pending denied Play', () async {
      final (handler, player, _) = await setup();
      final session = TestAudioSession();
      handler.debugWireAudioSession(session);
      addTearDown(session.close);
      await handler.replaceQueue(
        ['song-0'],
        autoPlay: false,
        expandMatchFlows: false,
      );
      player.focusDenials = 1;
      await handler.play();
      await pumpEventQueue();
      session.noisy.add(null);
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 1150));
      expect(player.focusRequests, 1);
      expect(player.playing, isFalse);
    });

    test('denied Play resumes silently without another user command', () async {
      final (handler, player, _) = await setup();
      await handler.replaceQueue(
        ['song-0'],
        autoPlay: false,
        expandMatchFlows: false,
      );
      player.focusDenials = 1;
      final failures = <PlaybackLoadFailure>[];
      final subscription = handler.loadFailureStream.listen(failures.add);
      addTearDown(subscription.cancel);
      await handler.play();
      await Future<void>.delayed(const Duration(milliseconds: 1150));
      expect(player.focusRequests, 2);
      expect(player.playing, isTrue);
      expect(failures, isEmpty);
    });

    test(
      'a phone interruption blocks the focus retry until the call ends',
      () async {
        final (handler, player, _) = await setup();
        final session = TestAudioSession();
        handler.debugWireAudioSession(session);
        addTearDown(session.close);
        await handler.replaceQueue(
          ['song-0'],
          autoPlay: false,
          expandMatchFlows: false,
        );
        player.focusDenials = 1;
        await handler.play();
        await pumpEventQueue();
        session.interruptions.add(
          AudioInterruptionEvent(true, AudioInterruptionType.pause),
        );
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 1150));
        expect(player.focusRequests, 1);
        expect(player.playing, isFalse);
        session.interruptions.add(
          AudioInterruptionEvent(false, AudioInterruptionType.pause),
        );
        await pumpEventQueue();
        expect(player.focusRequests, 2);
        expect(player.playing, isTrue);
      },
    );

    test('Pause cancels the pending denied Play', () async {
      final (handler, player, _) = await setup();
      await handler.replaceQueue(
        ['song-0'],
        autoPlay: false,
        expandMatchFlows: false,
      );
      player.focusDenials = 1;
      await handler.play();
      await pumpEventQueue();
      await handler.pause();
      await Future<void>.delayed(const Duration(milliseconds: 1150));
      expect(player.focusRequests, 1);
      expect(player.playing, isFalse);
    });

    test('offline recovery waits before spending the reload retry and preserves position', () async {
      var online = false;
      final recovered = StreamController<void>.broadcast();
      addTearDown(recovered.close);
      final (handler, player, _) = await setup(
        reconcile: () async => net(online: online),
        recovered: recovered.stream,
        remote: true,
      );
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      player
        ..simulatedPosition = const Duration(seconds: 42)
        ..state = ProcessingState.buffering;
      final loads = player.sourceLoads;
      await handler.debugRecoverCurrentSong();
      await handler.debugRecoverCurrentSong();
      expect(player.sourceLoads, loads);
      expect(handler.snapshot.currentSongId, 'song-0');
      online = true;
      recovered.add(null);
      await pumpEventQueue(times: 100);
      await settleQueue(handler);
      expect(player.sourceLoads, greaterThan(loads));
      expect(handler.snapshot.currentSongId, 'song-0');
      expect(player.position, const Duration(seconds: 42));
      expect(player.playing, isTrue);
    });

    test(
      'a second verified network outage reloads the same song again',
      () async {
        var online = true;
        final recovered = StreamController<void>.broadcast();
        addTearDown(recovered.close);
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: online),
          recovered: recovered.stream,
          remote: true,
        );
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        for (var outage = 0; outage < 2; outage++) {
          online = false;
          player
            ..simulatedPosition = const Duration(seconds: 42)
            ..state = ProcessingState.buffering;
          final loads = player.sourceLoads;
          await handler.debugRecoverCurrentSong();
          online = true;
          recovered.add(null);
          await pumpEventQueue(times: 100);
          await settleQueue(handler);
          expect(player.sourceLoads, loads + 1);
          expect(handler.snapshot.currentSongId, 'song-0');
          expect(player.position, const Duration(seconds: 42));
        }
      },
    );

    for (final radio in [false, true]) {
      test(
        'native error fields recover ${radio ? 'radio' : 'a song'} after the network returns',
        () async {
          var online = false;
          final recovered = StreamController<void>.broadcast();
          addTearDown(recovered.close);
          final (handler, player, _) = await setup(
            reconcile: () async => net(online: online),
            recovered: recovered.stream,
            remote: !radio,
          );
          if (radio) {
            await handler.playRadioStream(
              stationId: 'fixture',
              stationName: 'Fixture',
              streamUrl: 'https://radio.example.invalid/live',
            );
          } else {
            await handler.replaceQueue([
              'song-0',
              'song-1',
            ], expandMatchFlows: false);
          }
          player
            ..simulatedPosition = const Duration(seconds: 42)
            ..state = ProcessingState.idle
            ..isPlaying = false;
          final loads = player.sourceLoads;
          final error = PlaybackEvent(
            processingState: ProcessingState.idle,
            updatePosition: const Duration(seconds: 42),
            currentIndex: 0,
            errorCode: 0,
            errorMessage: 'Source error',
          );
          player.playbackEvents.add(error);
          player.playbackEvents.add(error);
          await pumpEventQueue();
          expect(player.sourceLoads, loads);
          online = true;
          recovered.add(null);
          await pumpEventQueue(times: 100);
          expect(player.sourceLoads, greaterThan(loads));
          if (!radio) await settleQueue(handler);
          expect(handler.snapshot.currentIndex, radio ? null : 0);
          if (radio) {
            expect(
              (player.sequence.single as ProgressiveAudioSource)
                  .options!
                  .androidUseDefaultLoadErrorHandling,
              isTrue,
            );
          }
          expect(player.playing, isTrue);
          if (!radio) expect(player.position, const Duration(seconds: 42));
        },
      );
    }

    test(
      'a rejected station start clears its pending network recovery state',
      () async {
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: false),
        );
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..loadGate = gate
          ..loadEntered = entered
          ..blockedLoadError = StateError('fixture start failure');
        final starting = handler.playRadioStream(
          stationId: 'fixture',
          stationName: 'Fixture',
          streamUrl: 'https://radio.example.invalid/live',
        );
        final failed = expectLater(
          starting,
          throwsA(isA<RadioPlaybackUnavailableException>()),
        );
        await entered.future;
        player.playbackEvents.addError(PlayerException(0, 'Source error', 0));
        await pumpEventQueue();
        gate.complete();
        await failed;
        await pumpEventQueue();
        expect(handler.snapshot.isRadioMode, isFalse);
        expect(
          handler.snapshot.processingState,
          isNot(AudioProcessingState.buffering),
        );
      },
    );

    test('Pause then Play rearms radio recovery while older reconciliation finishes', () async {
      final reconciliation = Completer<bool>();
      final entered = Completer<void>();
      var checks = 0;
      final (handler, player, _) = await setup(
        reconcile: () {
          if (checks++ == 0) {
            entered.complete();
            return reconciliation.future.then((online) => net(online: online));
          }
          return Future.value(net(online: true));
        },
      );
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: 'https://radio.example.invalid/live',
      );
      final loads = player.sourceLoads;
      player
        ..state = ProcessingState.idle
        ..isPlaying = false;
      player.playbackEvents.addError(
        PlayerException(0, 'network unavailable', null),
      );
      await entered.future;
      await handler.pause();
      await handler.play();
      reconciliation.complete(true);
      await pumpEventQueue(times: 100);
      await Future<void>.delayed(const Duration(milliseconds: 3200));
      expect(player.sourceLoads, greaterThan(loads));
      expect(player.playing, isTrue);
      expect(handler.snapshot.radioStation?.stationId, 'fixture');
    });

    for (final cancel in ['none', 'stop', 'pause', 'replace']) {
      test('radio network recovery preserves intent ($cancel)', () async {
        var online = false;
        final recovered = StreamController<void>.broadcast();
        addTearDown(recovered.close);
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: online),
          recovered: recovered.stream,
        );
        await handler.playRadioStream(
          stationId: 'fixture',
          stationName: 'Fixture',
          streamUrl: 'https://radio.example.invalid/live',
        );
        final notices = <void>[];
        final subscription = handler.radioStreamErrorStream.listen(notices.add);
        addTearDown(subscription.cancel);
        final loads = player.sourceLoads;
        player.isPlaying = false;
        player.playbackEvents.addError(
          PlayerException(0, 'network unavailable', null),
        );
        await pumpEventQueue();
        expect(handler.snapshot.isRadioMode, isTrue);
        expect(notices, isEmpty);
        if (cancel == 'stop') await handler.stopRadio();
        if (cancel == 'pause') await handler.pause();
        if (cancel == 'replace')
          await handler.replaceQueue(
            ['song-2'],
            autoPlay: false,
            expandMatchFlows: false,
          );
        final loadsAfterCommand = player.sourceLoads;
        online = true;
        recovered.add(null);
        await pumpEventQueue(times: 100);
        if (cancel == 'none') {
          expect(player.sourceLoads, greaterThan(loads));
          expect(player.playing, isTrue);
          expect(handler.snapshot.radioStation?.stationId, 'fixture');
        } else {
          expect(player.sourceLoads, loadsAfterCommand);
          expect(player.playing, isFalse);
        }
      });
    }
    PlaybackEvent nativeError(int code, {String message = 'Source error'}) =>
        PlaybackEvent(
          processingState: ProcessingState.idle,
          updatePosition: const Duration(seconds: 42),
          currentIndex: 0,
          errorCode: code,
          errorMessage: message,
        );

    Future<void> failSong(ControllableAudioPlayer player) async {
      player
        ..simulatedPosition = const Duration(seconds: 42)
        ..state = ProcessingState.idle
        ..isPlaying = false
        ..errorCode = 0;
      player.playbackEvents.add(nativeError(0));
      await pumpEventQueue();
    }

    test('a natural advance clears a pending song recovery', () async {
      var online = false;
      final recovered = StreamController<void>.broadcast();
      addTearDown(recovered.close);
      final (handler, player, _) = await setup(
        reconcile: () async => net(online: online),
        recovered: recovered.stream,
        remote: true,
      );
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      player.state = ProcessingState.buffering;
      await handler.debugRecoverCurrentSong();
      expect(handler.snapshot.processingState, AudioProcessingState.buffering);
      player
        ..state = ProcessingState.ready
        ..moveTo(1);
      await pumpEventQueue();
      expect(handler.snapshot.currentSongId, 'song-1');
      expect(
        handler.snapshot.processingState,
        isNot(AudioProcessingState.buffering),
      );
      final loads = player.sourceLoads;
      online = true;
      recovered.add(null);
      await pumpEventQueue(times: 100);
      expect(player.sourceLoads, loads);
      expect(handler.snapshot.currentSongId, 'song-1');
    });

    test('a song that recovered by itself is not reloaded online', () async {
      var online = false;
      final recovered = StreamController<void>.broadcast();
      addTearDown(recovered.close);
      final (handler, player, _) = await setup(
        reconcile: () async => net(online: online),
        recovered: recovered.stream,
        remote: true,
      );
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      player
        ..simulatedPosition = const Duration(seconds: 42)
        ..state = ProcessingState.buffering;
      await handler.debugRecoverCurrentSong();
      player
        ..state = ProcessingState.ready
        ..simulatedPosition = const Duration(seconds: 50);
      final loads = player.sourceLoads;
      online = true;
      recovered.add(null);
      await pumpEventQueue(times: 100);
      expect(player.sourceLoads, loads);
      expect(player.position, const Duration(seconds: 50));
      expect(
        handler.snapshot.processingState,
        isNot(AudioProcessingState.buffering),
      );
    });

    test(
      'Pause in the offline hold, then Play once online, resumes the song',
      () async {
        var online = false;
        final recovered = StreamController<void>.broadcast();
        addTearDown(recovered.close);
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: online),
          recovered: recovered.stream,
          remote: true,
        );
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        await failSong(player);
        await handler.pause();
        online = true;
        recovered.add(null);
        await pumpEventQueue(times: 100);
        final loads = player.sourceLoads;
        await handler.play();
        await pumpEventQueue(times: 100);
        await settleQueue(handler);
        expect(player.sourceLoads, loads + 1);
        expect(handler.snapshot.currentSongId, 'song-0');
        expect(player.position, const Duration(seconds: 42));
        expect(player.playing, isTrue);
      },
    );

    test('a normal build installs no seek trace callback', () async {
      final (handler, _, _) = await setup();
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      await handler.seek(const Duration(seconds: 30));
      expect(handler.debugSeekTraceInstalled, isFalse);
    });

    test('a seek in the offline hold moves the recovery target', () async {
      var online = false;
      final recovered = StreamController<void>.broadcast();
      addTearDown(recovered.close);
      final (handler, player, _) = await setup(
        reconcile: () async => net(online: online),
        recovered: recovered.stream,
        remote: true,
        timeouts: const NavisPlaybackTimeouts(
          load: Duration(milliseconds: 300),
        ),
      );
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      final failures = <PlaybackLoadFailure>[];
      final subscription = handler.loadFailureStream.listen(failures.add);
      addTearDown(subscription.cancel);
      await failSong(player);
      await handler.seek(const Duration(seconds: 60));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final loads = player.sourceLoads;
      online = true;
      recovered.add(null);
      await pumpEventQueue(times: 100);
      await settleQueue(handler);
      expect(player.sourceLoads, loads + 1);
      expect(player.position, const Duration(seconds: 60));
      expect(player.playing, isTrue);
      expect(failures, isEmpty);
    });

    test('a station reconnects on device connectivity alone', () async {
      final (handler, player, _) = await setup(
        reconcile: () async => (connected: true, serverReachable: false),
      );
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: 'https://radio.example.invalid/live',
      );
      final loads = player.sourceLoads;
      player
        ..state = ProcessingState.idle
        ..isPlaying = false;
      player.playbackEvents.add(nativeError(2001));
      await pumpEventQueue(times: 100);
      expect(player.sourceLoads, loads + 1);
      expect(player.playing, isTrue);
      expect(handler.snapshot.radioStation?.stationId, 'fixture');
    });

    for (final (code, message) in [
      (2005, 'Source error'),
      (2004, 'Source error (HTTP 404)'),
    ]) {
      test('a dead station ($code $message) stops with one notice', () async {
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: true),
        );
        await handler.replaceQueue(
          ['song-0'],
          autoPlay: false,
          expandMatchFlows: false,
        );
        await handler.playRadioStream(
          stationId: 'fixture',
          stationName: 'Fixture',
          streamUrl: 'https://radio.example.invalid/live',
        );
        final notices = <void>[];
        final subscription = handler.radioStreamErrorStream.listen(notices.add);
        addTearDown(subscription.cancel);
        player
          ..state = ProcessingState.idle
          ..isPlaying = false;
        player.playbackEvents.add(nativeError(code, message: message));
        await pumpEventQueue(times: 100);
        await settleQueue(handler);
        expect(handler.snapshot.isRadioMode, isFalse);
        expect(notices, hasLength(1));
        expect(handler.snapshot.queueSongIds, ['song-0']);
        expect(player.playing, isFalse);
      });
    }

    test(
      'a dead station restores a queue over the eager limit paused',
      () async {
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: true),
          count: 70,
        );
        final songIds = List<String>.generate(70, (index) => 'song-$index');
        await handler.replaceQueue(
          songIds,
          autoPlay: false,
          expandMatchFlows: false,
        );
        await handler.playRadioStream(
          stationId: 'fixture',
          stationName: 'Fixture',
          streamUrl: 'https://radio.example.invalid/live',
        );
        player
          ..state = ProcessingState.idle
          ..isPlaying = false;
        final playRequests = player.focusRequests;
        player.playbackEvents.add(nativeError(2005));
        await pumpEventQueue(times: 100);
        await settleQueue(handler);
        expect(handler.snapshot.isRadioMode, isFalse);
        expect(handler.snapshot.queueSongIds, songIds);
        // A real Play waits for audio focus, so one requested here lands after
        // the restore's pause and starts the old queue.
        expect(player.focusRequests, playRequests);
        expect(player.playing, isFalse);
      },
    );

    for (final count in [1, 80]) {
      test(
        'rejected station start restores $count playing songs paused with one notice',
        () async {
          final (handler, player, _) = await setup(count: count);
          final songIds = List.generate(count, (index) => 'song-$index');
          await handler.replaceQueue(songIds, expandMatchFlows: false);
          await settleQueue(handler);
          await handler.debugFlushQueuePersistence();
          expect(player.playing, isTrue);
          final notices = <void>[];
          final subscription = handler.radioStreamErrorStream.listen(
            notices.add,
          );
          addTearDown(subscription.cancel);
          // The native load can fail without emitting a playback stream error,
          // and just_audio retains its separate playing flag after that failure.
          player.failLoadSongId = 'radio:dead';
          await expectLater(
            handler.playRadioStream(
              stationId: 'dead',
              stationName: 'Dead station',
              streamUrl: 'http://127.0.0.1:9/dead.mp3',
            ),
            throwsA(isA<RadioPlaybackUnavailableException>()),
          );
          await pumpEventQueue(times: 100);
          await settleQueue(handler);
          expect(handler.snapshot.queueSongIds, songIds);
          expect(handler.snapshot.isRadioMode, isFalse);
          expect(handler.snapshot.isLoading, isFalse);
          expect(player.playing, isFalse);
          expect(handler.snapshot.playing, isFalse);
          expect(handler.playbackState.value.playing, isFalse);
          expect(notices, hasLength(1));
        },
      );
    }

    test(
      'a dead station on first start does not leave the load stuck',
      () async {
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: true),
        );
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        await handler.debugFlushQueuePersistence();
        final notices = <void>[];
        final subscription = handler.radioStreamErrorStream.listen(notices.add);
        addTearDown(subscription.cancel);
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..loadGate = gate
          ..loadEntered = entered;
        final starting = handler.playRadioStream(
          stationId: 'fixture',
          stationName: 'Fixture',
          streamUrl: 'https://radio.example.invalid/live',
        );
        await entered.future;
        player.playbackEvents.add(nativeError(2005));
        await pumpEventQueue();
        gate.completeError(StateError('source load also rejected'));
        await starting;
        await pumpEventQueue(times: 100);
        await settleQueue(handler);
        expect(handler.snapshot.isRadioMode, isFalse);
        expect(handler.snapshot.isLoading, isFalse);
        expect(handler.snapshot.queueSongIds, ['song-0']);
        expect(handler.snapshot.playing, isFalse);
        expect(player.playing, isFalse);
        expect(notices, hasLength(1));
      },
    );

    Future<void> dropStation(ControllableAudioPlayer player) async {
      player
        ..state = ProcessingState.idle
        ..isPlaying = false;
      // A stream error, unlike a repeated native error event, is never merged.
      player.playbackEvents.addError(
        PlayerException(0, 'network unavailable', null),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await pumpEventQueue(times: 50);
    }

    test(
      'a station that keeps connecting and dropping stops after the budget',
      () async {
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: true),
          timeouts: const NavisPlaybackTimeouts(
            radioRecovery: Duration(milliseconds: 600),
            radioHealthyPlay: Duration(seconds: 30),
          ),
        );
        await handler.playRadioStream(
          stationId: 'fixture',
          stationName: 'Fixture',
          streamUrl: 'https://radio.example.invalid/live',
        );
        final notices = <void>[];
        final subscription = handler.radioStreamErrorStream.listen(notices.add);
        addTearDown(subscription.cancel);
        for (var i = 0; i < 12 && handler.snapshot.isRadioMode; i++) {
          // Each reconnect takes a while: that failure time adds up.
          final reconnect = Completer<void>();
          player.loadGate = reconnect;
          await dropStation(player);
          reconnect.complete();
          await pumpEventQueue(times: 50);
        }
        expect(handler.snapshot.isRadioMode, isFalse);
        expect(notices, hasLength(1));
      },
    );

    // Issue #527: a stalled or ended station stream never reports an error.
    void endStation(ControllableAudioPlayer player) {
      player
        ..state = ProcessingState.completed
        ..isPlaying = true;
      player.playbackEvents.add(player.playbackEvent);
    }

    void stallStation(ControllableAudioPlayer player) {
      player
        ..state = ProcessingState.buffering
        ..isPlaying = true;
      player.playbackEvents.add(player.playbackEvent);
    }

    Future<(NavisAudioHandler, ControllableAudioPlayer)> playStation({
      NavisPlaybackTimeouts timeouts = const NavisPlaybackTimeouts(),
      Future<NetworkReconciliation> Function()? reconcile,
    }) async {
      final (handler, player, _) = await setup(
        reconcile: reconcile ?? () async => net(online: true),
        timeouts: timeouts,
      );
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: 'https://radio.example.invalid/live',
      );
      return (handler, player);
    }

    String stationUrl(ControllableAudioPlayer player) =>
        (player.sequence.single as UriAudioSource).uri.toString();

    test('a station whose stream ends reconnects once', () async {
      final (handler, player) = await playStation();
      final loads = player.sourceLoads;
      final stops = player.stopCalls;
      endStation(player);
      await pumpEventQueue(times: 100);
      expect(player.sourceLoads, loads + 1);
      expect(player.stopCalls, stops + 1);
      expect(stationUrl(player), 'https://radio.example.invalid/live');
      expect(player.playing, isTrue);
      expect(handler.snapshot.radioStation?.stationId, 'fixture');
    });

    test('Play on an ended station reconnects instead of replaying', () async {
      final (handler, player) = await playStation();
      final loads = player.sourceLoads;
      // The end was never reported as an event (a dropped one).
      player
        ..state = ProcessingState.completed
        ..isPlaying = false;
      await handler.play();
      await pumpEventQueue(times: 100);
      expect(player.sourceLoads, loads + 1);
      expect(player.state, ProcessingState.ready);
      expect(player.playing, isTrue);
    });

    test('an error then an end in one outage reconnect once', () async {
      final (handler, player) = await playStation();
      final loads = player.sourceLoads;
      final reconnect = Completer<void>();
      player.loadGate = reconnect;
      await dropStation(player);
      endStation(player);
      await pumpEventQueue(times: 50);
      reconnect.complete();
      await pumpEventQueue(times: 100);
      expect(player.sourceLoads, loads + 1);
      expect(handler.snapshot.isRadioMode, isTrue);
    });

    test('a station that keeps ending stops after the budget', () async {
      final (handler, player) = await playStation(
        timeouts: const NavisPlaybackTimeouts(
          radioRecovery: Duration(milliseconds: 600),
          radioHealthyPlay: Duration(seconds: 30),
        ),
      );
      final notices = <void>[];
      final subscription = handler.radioStreamErrorStream.listen(notices.add);
      addTearDown(subscription.cancel);
      for (var i = 0; i < 12 && handler.snapshot.isRadioMode; i++) {
        final reconnect = Completer<void>();
        player.loadGate = reconnect;
        endStation(player);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        reconnect.complete();
        await pumpEventQueue(times: 50);
      }
      expect(handler.snapshot.isRadioMode, isFalse);
      expect(notices, hasLength(1));
    });

    for (final cancel in ['stop', 'replace']) {
      test('an ended station reconnect is abandoned on $cancel', () async {
        var online = false;
        final recovered = StreamController<void>.broadcast();
        addTearDown(recovered.close);
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: online),
          recovered: recovered.stream,
        );
        await handler.playRadioStream(
          stationId: 'fixture',
          stationName: 'Fixture',
          streamUrl: 'https://radio.example.invalid/live',
        );
        endStation(player);
        await pumpEventQueue();
        if (cancel == 'stop') {
          await handler.stopRadio();
        } else {
          await handler.replaceQueue(
            ['song-2'],
            autoPlay: false,
            expandMatchFlows: false,
          );
        }
        final loadsAfterCommand = player.sourceLoads;
        online = true;
        recovered.add(null);
        await pumpEventQueue(times: 100);
        expect(player.sourceLoads, loadsAfterCommand);
        expect(player.playing, isFalse);
      });
    }

    const stall = NavisPlaybackTimeouts(
      remoteStall: Duration(milliseconds: 300),
    );

    test(
      'a station stuck buffering reconnects after the stall timeout',
      () async {
        final (_, player) = await playStation(timeouts: stall);
        final loads = player.sourceLoads;
        stallStation(player);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(player.sourceLoads, loads);
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await pumpEventQueue(times: 100);
        expect(player.sourceLoads, loads + 1);
        expect(stationUrl(player), 'https://radio.example.invalid/live');
        expect(player.playing, isTrue);
      },
    );

    test(
      'a metadata update during a stall still reconnects the station',
      () async {
        final (handler, player) = await playStation(timeouts: stall);
        final loads = player.sourceLoads;
        stallStation(player);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        handler.updateRadioMetadata(title: 'Next song');
        await Future<void>.delayed(const Duration(milliseconds: 450));
        await pumpEventQueue(times: 100);
        expect(player.sourceLoads, loads + 1);
      },
    );

    test(
      're-selecting a stalled station does not add a stale reconnect',
      () async {
        final (handler, player) = await playStation(timeouts: stall);
        final loads = player.sourceLoads;
        stallStation(player);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final gate = player.loadGate = Completer<void>();
        final reselect = handler.playRadioStream(
          stationId: 'fixture',
          stationName: 'Fixture',
          streamUrl: 'https://radio.example.invalid/live',
        );
        await Future<void>.delayed(const Duration(milliseconds: 450));
        gate.complete();
        await reselect;
        await pumpEventQueue(times: 100);
        expect(player.sourceLoads, loads + 1);
      },
    );

    test('a station buffering with progress is left alone', () async {
      final (_, player) = await playStation(timeouts: stall);
      final loads = player.sourceLoads;
      stallStation(player);
      for (var i = 1; i <= 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        player.simulatedBuffered = Duration(seconds: i);
        player.playbackEvents.add(player.playbackEvent);
      }
      expect(player.sourceLoads, loads);
    });

    test('a ready station that keeps advancing is left alone', () async {
      final (_, player) = await playStation(timeouts: stall);
      final loads = player.sourceLoads;
      player
        ..simulateProgress = true
        ..state = ProcessingState.ready
        ..isPlaying = true;
      player.playbackEvents.add(player.playbackEvent);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(player.sourceLoads, loads);
    });

    test('a paused station is not watched for a stall', () async {
      final (_, player) = await playStation(timeouts: stall);
      final loads = player.sourceLoads;
      player
        ..state = ProcessingState.buffering
        ..isPlaying = false;
      player.playbackEvents.add(player.playbackEvent);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(player.sourceLoads, loads);
    });

    test(
      'a station that played healthily gets a fresh recovery budget',
      () async {
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: true),
          timeouts: const NavisPlaybackTimeouts(
            radioRecovery: Duration(milliseconds: 600),
            radioHealthyPlay: Duration(milliseconds: 200),
          ),
        );
        await handler.playRadioStream(
          stationId: 'fixture',
          stationName: 'Fixture',
          streamUrl: 'https://radio.example.invalid/live',
        );
        // About 250 ms of failure per drop would exceed the budget by the
        // fourth drop if it carried over.
        for (var i = 0; i < 5; i++) {
          final reconnect = Completer<void>();
          player.loadGate = reconnect;
          await dropStation(player);
          await Future<void>.delayed(const Duration(milliseconds: 150));
          reconnect.complete();
          await Future<void>.delayed(const Duration(milliseconds: 1200));
        }
        expect(handler.snapshot.isRadioMode, isTrue);
        expect(player.playing, isTrue);
      },
    );

    test(
      'a station on a flaky network that mostly plays keeps playing',
      () async {
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: true),
          timeouts: const NavisPlaybackTimeouts(
            radioRecovery: Duration(seconds: 1),
            radioHealthyPlay: Duration(seconds: 30),
          ),
        );
        await handler.playRadioStream(
          stationId: 'fixture',
          stationName: 'Fixture',
          streamUrl: 'https://radio.example.invalid/live',
        );
        // Each drop reconnects at once; only the play time between drops
        // adds up past the budget.
        for (var i = 0; i < 5; i++) {
          await dropStation(player);
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        expect(handler.snapshot.isRadioMode, isTrue);
        expect(player.playing, isTrue);
      },
    );

    test('being offline never stops a station or shows a notice', () async {
      var online = false;
      final recovered = StreamController<void>.broadcast();
      addTearDown(recovered.close);
      final (handler, player, _) = await setup(
        reconcile: () async => net(online: online),
        recovered: recovered.stream,
        timeouts: const NavisPlaybackTimeouts(
          radioRecovery: Duration(seconds: 3),
        ),
      );
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: 'https://radio.example.invalid/live',
      );
      final notices = <void>[];
      final subscription = handler.radioStreamErrorStream.listen(notices.add);
      addTearDown(subscription.cancel);
      final loads = player.sourceLoads;
      player
        ..state = ProcessingState.idle
        ..isPlaying = false;
      player.playbackEvents.add(nativeError(2001));
      await pumpEventQueue();
      // Offline past the budget: the retry at 3 s finds no connection.
      await Future<void>.delayed(const Duration(milliseconds: 4500));
      await pumpEventQueue(times: 100);
      expect(handler.snapshot.isRadioMode, isTrue);
      expect(notices, isEmpty);
      online = true;
      recovered.add(null);
      await pumpEventQueue(times: 100);
      expect(player.sourceLoads, greaterThan(loads));
      expect(player.playing, isTrue);
      expect(handler.snapshot.isRadioMode, isTrue);
    });

    test('a station reconnect never waits for the server probe', () async {
      final (handler, player, _) = await setup(
        reconcile: () => Completer<NetworkReconciliation>().future,
        deviceConnected: () async => true,
      );
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: 'https://radio.example.invalid/live',
      );
      final loads = player.sourceLoads;
      player
        ..state = ProcessingState.idle
        ..isPlaying = false;
      player.playbackEvents.add(nativeError(2001));
      await pumpEventQueue(times: 100);
      expect(player.sourceLoads, loads + 1);
      expect(player.playing, isTrue);
    });

    test(
      'an explicit Play overrides a focus holder that never returns focus',
      () async {
        final (handler, player, _) = await setup();
        final session = TestAudioSession();
        handler.debugWireAudioSession(session);
        addTearDown(session.close);
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        session.interruptions.add(
          AudioInterruptionEvent(true, AudioInterruptionType.pause),
        );
        await pumpEventQueue();
        expect(player.playing, isFalse);
        await handler.play();
        await pumpEventQueue();
        expect(player.playing, isTrue);
        expect(session.activations, [false]);
      },
    );

    test(
      'denied focus stops retrying after its budget and stays paused',
      () async {
        final (handler, player, _) = await setup(
          timeouts: const NavisPlaybackTimeouts(
            focusRetry: Duration(milliseconds: 500),
          ),
        );
        await handler.replaceQueue(
          ['song-0'],
          autoPlay: false,
          expandMatchFlows: false,
        );
        player.focusDenials = 100;
        await handler.play();
        await Future<void>.delayed(const Duration(milliseconds: 3500));
        expect(player.focusRequests, 2);
        expect(player.playing, isFalse);
        expect(handler.playbackState.value.playing, isFalse);
      },
    );

    test(
      'granted focus restarts the retry budget for a later denial',
      () async {
        final (handler, player, _) = await setup(
          timeouts: const NavisPlaybackTimeouts(
            focusRetry: Duration(milliseconds: 1500),
          ),
        );
        final session = TestAudioSession();
        handler.debugWireAudioSession(session);
        addTearDown(session.close);
        await handler.replaceQueue(
          ['song-0'],
          autoPlay: false,
          expandMatchFlows: false,
        );
        player
          ..playCompletesOnPause = true
          ..focusDenials = 1;
        await handler.play();
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        expect(player.playing, isTrue);
        // A native reload interrupts the pending play() call while playing.
        player.playCompleter!.completeError(
          PlayerInterruptedException('reload'),
        );
        player.playCompleter = null;
        session.interruptions.add(
          AudioInterruptionEvent(true, AudioInterruptionType.pause),
        );
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        player.focusDenials = 1;
        final requests = player.focusRequests;
        session.interruptions.add(
          AudioInterruptionEvent(false, AudioInterruptionType.pause),
        );
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        expect(player.focusRequests, requests + 2);
        expect(player.playing, isTrue);
      },
    );

    test('Play while recovery waits to reload plays with one press', () async {
      final (handler, player, _) = await setup(
        reconcile: () async => net(online: true),
        remote: true,
      );
      await handler.replaceQueue(
        ['song-0', 'song-1'],
        autoPlay: false,
        expandMatchFlows: false,
      );
      // A queue edit holds the lane, so the reload waits behind it.
      final gate = Completer<void>();
      final entered = Completer<void>();
      player
        ..appendGate = gate
        ..appendEntered = entered;
      final adding = handler
          .addToQueue(['song-2'], expandMatchFlows: false)
          .catchError((Object _) {});
      await entered.future;
      await failSong(player);
      await pumpEventQueue(times: 20);
      await handler.play();
      gate.complete();
      await adding;
      await pumpEventQueue(times: 100);
      await settleQueue(handler);
      expect(player.playing, isTrue);
      expect(
        handler.snapshot.processingState,
        isNot(AudioProcessingState.buffering),
      );
    });

    test(
      'Play survives a reload that fails again while the queue fills',
      () async {
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: true),
          remote: true,
        );
        await handler.replaceQueue(
          ['song-0', 'song-1'],
          autoPlay: false,
          expandMatchFlows: false,
        );
        // A queue edit holds the lane, so the reload waits behind it.
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..appendGate = gate
          ..appendEntered = entered;
        final adding = handler
            .addToQueue(['song-2'], expandMatchFlows: false)
            .catchError((Object _) {});
        await entered.future;
        await failSong(player);
        await pumpEventQueue(times: 20);
        await handler.play();
        // The reloaded stream fails at once, and the rest of the queue is
        // still being restored, so recovery cannot start again.
        final fill = Completer<void>();
        player
          ..failAfterLoad = true
          ..appendGate = fill
          ..appendEntered = Completer<void>();
        gate.complete();
        await adding;
        await pumpEventQueue(times: 100);
        player.failAfterLoad = false;
        fill.complete();
        await pumpEventQueue(times: 100);
        await settleQueue(handler);
        expect(player.state, ProcessingState.ready);
        expect(player.playing, isTrue);
      },
    );

    test('a held Play applies once a restore reloads its song', () async {
      final (handler, player, database) = await setup(
        reconcile: () async => net(online: false),
        remote: true,
        count: 70,
      );
      final ids = List<String>.generate(70, (index) => 'song-$index');
      await handler.replaceQueue(ids, autoPlay: false, expandMatchFlows: false);
      await settleQueue(handler);
      await database.playQueueDao.saveQueue(currentIndex: 0, songIds: ids);
      await failSong(player);
      // Offline, Play holds its request for the failed song.
      await handler.play();
      await pumpEventQueue(times: 20);
      // Android Auto restores the saved queue in two phases without
      // superseding the Play; the restore reloads the same song.
      await handler.prepareFromMediaId('recent/resume');
      await pumpEventQueue(times: 100);
      await settleQueue(handler);
      expect(player.state, ProcessingState.ready);
      expect(player.playing, isTrue);
      expect(
        handler.snapshot.processingState,
        isNot(AudioProcessingState.buffering),
      );
    });

    test(
      'a stream that fails right after its load reported ready ends paused',
      () async {
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: true),
          remote: true,
        );
        player.failOnPlay = true;
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        await pumpEventQueue(times: 100);
        await settleQueue(handler);
        expect(player.state, ProcessingState.idle);
        expect(player.playing, isFalse);
        expect(handler.snapshot.playing, isFalse);
      },
    );

    test(
      'a mid-queue stream that fails right after its load skips to the next',
      () async {
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: true),
          remote: true,
        );
        player.failOnPlay = true;
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        await pumpEventQueue(times: 100);
        await settleQueue(handler);
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(player.index, 1);
        expect(player.playing, isTrue);
      },
    );

    test('a paused load whose stream fails after apply never starts', () async {
      final (handler, player, _) = await setup(
        reconcile: () async => net(online: true),
        remote: true,
      );
      player.failOnPlay = true;
      await handler.replaceQueue(
        ['song-0', 'song-1'],
        autoPlay: false,
        expandMatchFlows: false,
      );
      await pumpEventQueue(times: 100);
      await settleQueue(handler);
      expect(player.playedFrom, isEmpty);
      expect(player.playing, isFalse);
      expect(handler.snapshot.playing, isFalse);
    });

    test(
      'a retry reload that also fails after apply skips without looping',
      () async {
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: true),
          remote: true,
        );
        player
          ..failOnPlay = true
          ..failOnPlayRepeats = 1;
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        await pumpEventQueue(times: 100);
        await settleQueue(handler);
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(player.index, 1);
        expect(player.playing, isTrue);
        // Both failing Plays were song-0's; song-1 then played without one.
        expect(player.failOnPlayRepeats, 0);
        expect(player.playedFrom, hasLength(2));
      },
    );

    test('an error event that is not idle still counts as a failure', () async {
      var online = false;
      final recovered = StreamController<void>.broadcast();
      addTearDown(recovered.close);
      final (handler, player, _) = await setup(
        reconcile: () async => net(online: online),
        recovered: recovered.stream,
        remote: true,
      );
      await handler.replaceQueue(
        ['song-0', 'song-1'],
        autoPlay: false,
        expandMatchFlows: false,
      );
      player
        ..simulatedPosition = const Duration(seconds: 42)
        ..state = ProcessingState.idle
        ..errorCode = 0;
      player.playbackEvents.add(
        PlaybackEvent(
          processingState: ProcessingState.buffering,
          updatePosition: const Duration(seconds: 42),
          currentIndex: 0,
          errorCode: 0,
          errorMessage: 'Source error',
        ),
      );
      await pumpEventQueue(times: 20);
      await handler.play();
      await pumpEventQueue(times: 20);
      final loads = player.sourceLoads;
      online = true;
      recovered.add(null);
      await pumpEventQueue(times: 100);
      await settleQueue(handler);
      expect(player.sourceLoads, greaterThan(loads));
      expect(player.playing, isTrue);
    });

    test('Play on a failed song during a seek never hangs', () async {
      final (handler, player, _) = await setup(
        reconcile: () async => net(online: false),
        remote: true,
        timeouts: const NavisPlaybackTimeouts(
          load: Duration(milliseconds: 300),
          seekProgress: Duration(milliseconds: 300),
        ),
      );
      await handler.replaceQueue(
        ['song-0', 'song-1'],
        autoPlay: false,
        expandMatchFlows: false,
      );
      await failSong(player);
      await handler.pause();
      // The seek waits for the failed source to become ready.
      final seeking = handler.seek(const Duration(seconds: 60));
      await pumpEventQueue();
      await handler.play();
      await seeking;
      await settleQueue(handler);
      expect(
        handler.snapshot.processingState,
        isNot(AudioProcessingState.buffering),
      );
    });

    test('Play on a song that was never prepared plays it directly', () async {
      final (handler, player, _) = await setup(remote: true);
      await handler.replaceQueue(
        ['song-0', 'song-1'],
        autoPlay: false,
        expandMatchFlows: false,
      );
      // With gapless off, an autoPlay:false load stays unprepared.
      player.state = ProcessingState.idle;
      final loads = player.sourceLoads;
      await handler.play();
      await pumpEventQueue(times: 100);
      expect(player.sourceLoads, loads);
      expect(player.playing, isTrue);
    });

    test(
      'Play on a song loaded after another one failed plays it directly',
      () async {
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: false),
          remote: true,
        );
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        await failSong(player);
        await pumpEventQueue(times: 20);
        await handler.replaceQueue(
          ['song-1', 'song-2'],
          autoPlay: false,
          expandMatchFlows: false,
        );
        // just_audio's idle player keeps the failed song's error until the
        // next song is prepared (a load with preload: false); its Play loads
        // the song.
        player
          ..state = ProcessingState.idle
          ..errorCode = 0
          ..playRequested = false;
        final loads = player.sourceLoads;
        await handler.play();
        await pumpEventQueue(times: 100);
        expect(player.sourceLoads, loads);
        expect(player.playRequested, isTrue);
      },
    );

    test('Play during the probe keeps a seek made during a stall', () async {
      final probe = Completer<NetworkReconciliation>();
      final (handler, player, _) = await setup(
        reconcile: () => probe.future,
        remote: true,
      );
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      player
        ..simulatedPosition = const Duration(seconds: 42)
        ..state = ProcessingState.buffering;
      final recovering = handler.debugRecoverCurrentSong();
      await pumpEventQueue();
      await handler.seek(const Duration(seconds: 180));
      // The stream resumes by itself at 1:00 while the probe still runs.
      player
        ..simulatedPosition = const Duration(seconds: 60)
        ..state = ProcessingState.ready;
      await handler.play();
      probe.complete(net(online: true));
      await recovering;
      await pumpEventQueue(times: 100);
      await settleQueue(handler);
      expect(player.position, const Duration(seconds: 180));
      expect(player.playing, isTrue);
    });

    test(
      'a seek during a stall applies once the song resumes by itself',
      () async {
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: false),
          remote: true,
        );
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        player
          ..simulatedPosition = const Duration(seconds: 42)
          ..state = ProcessingState.buffering;
        await handler.debugRecoverCurrentSong();
        player.state = ProcessingState.ready;
        await handler.seek(const Duration(seconds: 60));
        await pumpEventQueue(times: 100);
        await settleQueue(handler);
        expect(player.position, const Duration(seconds: 60));
        expect(
          handler.snapshot.processingState,
          isNot(AudioProcessingState.buffering),
        );
      },
    );

    test('Play in the offline hold keeps an earlier seek target', () async {
      var online = false;
      final recovered = StreamController<void>.broadcast();
      addTearDown(recovered.close);
      final (handler, player, _) = await setup(
        reconcile: () async => net(online: online),
        recovered: recovered.stream,
        remote: true,
      );
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      await failSong(player);
      await handler.seek(const Duration(seconds: 60));
      await handler.play();
      await pumpEventQueue(times: 20);
      online = true;
      recovered.add(null);
      await pumpEventQueue(times: 100);
      await settleQueue(handler);
      expect(player.position, const Duration(seconds: 60));
      expect(player.playing, isTrue);
    });

    test(
      'a resume after a long interruption has a fresh focus budget',
      () async {
        final (handler, player, _) = await setup(
          timeouts: const NavisPlaybackTimeouts(
            focusRetry: Duration(milliseconds: 1500),
          ),
        );
        final session = TestAudioSession();
        handler.debugWireAudioSession(session);
        addTearDown(session.close);
        await handler.replaceQueue(
          ['song-0'],
          autoPlay: false,
          expandMatchFlows: false,
        );
        player.focusDenials = 1;
        await handler.play();
        await pumpEventQueue();
        session.interruptions.add(
          AudioInterruptionEvent(true, AudioInterruptionType.pause),
        );
        // Past the first denial's budget; the resume retries after 1 s.
        await Future<void>.delayed(const Duration(milliseconds: 2600));
        player.focusDenials = 1;
        session.interruptions.add(
          AudioInterruptionEvent(false, AudioInterruptionType.pause),
        );
        await Future<void>.delayed(const Duration(milliseconds: 2500));
        expect(player.playing, isTrue);
      },
    );

    test(
      'a Play that re-arms recovery leaves no old focus budget behind',
      () async {
        var online = false;
        final recovered = StreamController<void>.broadcast();
        addTearDown(recovered.close);
        final (handler, player, _) = await setup(
          reconcile: () async => net(online: online),
          recovered: recovered.stream,
          remote: true,
          timeouts: const NavisPlaybackTimeouts(
            focusRetry: Duration(milliseconds: 1500),
          ),
        );
        await handler.replaceQueue(
          ['song-0', 'song-1'],
          autoPlay: false,
          expandMatchFlows: false,
        );
        player.focusDenials = 100;
        await handler.play();
        await failSong(player);
        // Re-arms recovery of the failed song without requesting focus.
        await handler.play();
        await pumpEventQueue(times: 20);
        // Offline for longer than the first denial's budget.
        await Future<void>.delayed(const Duration(milliseconds: 2600));
        player.focusDenials = 1;
        online = true;
        recovered.add(null);
        await pumpEventQueue(times: 100);
        await settleQueue(handler);
        // The reloaded song's denied play retries after 1 s.
        await Future<void>.delayed(const Duration(milliseconds: 2500));
        expect(player.playing, isTrue);
      },
    );

    test('the media button cancels a pending focus retry', () async {
      final (handler, player, _) = await setup();
      await handler.replaceQueue(
        ['song-0'],
        autoPlay: false,
        expandMatchFlows: false,
      );
      player.focusDenials = 100;
      await handler.play();
      await pumpEventQueue();
      await handler.click();
      // Between the cancelled retry at 1 s and the next one at 3 s.
      await Future<void>.delayed(const Duration(milliseconds: 2000));
      expect(player.focusRequests, 1);
      expect(player.playing, isFalse);
    });

    test('Play during a pending focus retry keeps its budget', () async {
      final (handler, player, _) = await setup(
        timeouts: const NavisPlaybackTimeouts(focusRetry: Duration(seconds: 5)),
      );
      await handler.replaceQueue(
        ['song-0'],
        autoPlay: false,
        expandMatchFlows: false,
      );
      player.focusDenials = 100;
      await handler.play();
      await Future<void>.delayed(const Duration(milliseconds: 2000));
      await handler.play();
      await Future<void>.delayed(const Duration(milliseconds: 6000));
      // Denied at 0, 1, 2 (this Play), 3 and the budget's end at 5 s. A
      // fresh budget would retry again at 7 s.
      expect(player.focusRequests, 5);
      expect(handler.playbackState.value.playing, isFalse);
    });
  });

  for (final fails in [false, true]) {
    test('bootstrap includes local initialization (failure: $fails)', () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-local-init-',
      );
      final gate = Completer<void>();
      final player = ControllableAudioPlayer()
        ..volumeGate = gate
        ..volumeEntered = Completer<void>()
        ..failVolume = fails;
      final (handler, _, database) = await createHandler(
        directory,
        1,
        initialPlayer: player,
        waitForReady: false,
      );
      final container = ProviderContainer(
        overrides: [
          audioHandlerInitializerProvider.overrideWithValue(
            () async => handler,
          ),
          audioBootstrapTimeoutProvider.overrideWithValue(
            const Duration(milliseconds: 30),
          ),
          audioBootstrapRetryDelayProvider.overrideWithValue(
            const Duration(days: 1),
          ),
        ],
      );
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        container.dispose();
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final bootstrap = container.read(
        audioBootstrapControllerProvider.notifier,
      );
      final initialization = bootstrap.retry();
      await player.volumeEntered!.future;
      if (fails) gate.complete();
      await initialization;
      final state = container.read(audioBootstrapControllerProvider);
      expect(state.status, AudioBootstrapStatus.failed);
      expect(state.timedOut, !fails);
      expect(container.read(audioHandlerProvider), isNull);
      if (!fails) {
        gate.complete();
        await pumpEventQueue(times: 100);
        expect(
          container.read(audioBootstrapControllerProvider).isReady,
          isTrue,
        );
      } else {
        expect(bootstrap.isRetryScheduled, isTrue);
      }
    });
  }

  test('bootstrap readiness excludes saved queue restoration', () async {
    final directory = await Directory.systemTemp.createTemp(
      'navis-ready-without-restore-',
    );
    late GatedPlayQueueDao library;
    final (handler, player, database) = await createHandler(
      directory,
      3,
      savedQueueIndex: 1,
      waitForReady: false,
      createPlayQueueDao: (db) => library = GatedPlayQueueDao(db),
    );
    final container = ProviderContainer(
      overrides: [
        audioHandlerInitializerProvider.overrideWithValue(() async => handler),
      ],
    );
    addTearDown(() async {
      if (!library.release.isCompleted) library.release.complete();
      container.dispose();
      await handler.disposeHandler();
      await database.close();
      await directory.delete(recursive: true);
    });
    await container.read(audioBootstrapControllerProvider.notifier).retry();
    await library.entered.future.timeout(const Duration(seconds: 1));
    expect(container.read(audioBootstrapControllerProvider).isReady, isTrue);
    expect(library.release.isCompleted, isFalse);
    expect(player.sequence, isEmpty);
    library.release.complete();
    await handler.debugWaitForStartupQueueRestore();
    expect(handler.snapshot.currentIndex, 1);
    expect(player.sequence, isEmpty);
  });

  for (final recent in [false, true]) {
    test(
      'large unavailable saved queue falls back on first Play (recent: $recent)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-large-fallback-',
        );
        final (handler, player, database) = await createHandler(
          directory,
          70,
          savedQueueIndex: 0,
          seed: (db) async {
            final cached = await db.cacheDao.getCachedTrack('song-0');
            await File(cached!.filePath).delete();
            if (recent) {
              await db.historyDao.addPlayHistory('song-1');
            } else {
              await db.libraryDao.setEntityStarred(
                'song',
                'song-1',
                DateTime.now(),
              );
            }
          },
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        await handler.play();
        expect(handler.snapshot.queueSongIds, ['song-1']);
        await settleQueue(handler);
        expect(player.sourceIds, ['song-1']);
        expect(player.isPlaying, isTrue);
        expect(handler.playbackState.value.errorMessage, isNull);
        await handler.debugFlushQueuePersistence();
        expect((await database.playQueueDao.getQueueItems()).map((s) => s.id), [
          'song-1',
        ]);
      },
    );
  }

  test(
    'second Play restarts superseded recent preparation for the newest command',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-second-play-',
      );
      late GatedHistoryDao history;
      final (handler, player, database) = await createHandler(
        directory,
        2,
        createHistoryDao: (db) => history = GatedHistoryDao(db),
      );
      addTearDown(() async {
        if (!history.release.isCompleted) history.release.complete();
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final first = handler.play();
      await history.entered.future.timeout(const Duration(seconds: 1));
      final second = handler.play();
      await pumpEventQueue();
      history.release.complete();
      await Future.wait([first, second]);
      await settleQueue(handler);
      expect(history.lookups, 2);
      expect(handler.snapshot.queueSongIds, ['song-1']);
      expect(player.sourceIds, ['song-1']);
      expect(player.isPlaying, isTrue);
      expect(player.sourceLoads, 1);
      expect(handler.playbackState.value.errorMessage, isNull);
    },
  );

  for (final command in ['pause', 'stop', 'replace', 'play']) {
    test(
      'overlapping empty-queue Plays respect newer $command during radio fetch',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-radio-transport-',
        );
        final entered = Completer<void>();
        final batch = Completer<RecommendationBatch>();
        final service = MockRecommendationService();
        var fetches = 0;
        when(
          () => service.personalRadio(
            any(),
            excludedIds: any(named: 'excludedIds'),
            count: any(named: 'count'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) {
          fetches++;
          if (!entered.isCompleted) entered.complete();
          return batch.future;
        });
        late ProviderContainer container;
        final (handler, player, database) = await createHandler(
          directory,
          2,
          startPersonalRadio: ({required autoPlay, isCurrent}) async =>
              (await container
                      .read(personalRadioProvider.notifier)
                      .start(autoPlay: autoPlay, isCurrent: isCurrent))
                  .succeeded,
        );
        container = ProviderContainer(
          overrides: [
            navisDatabaseProvider.overrideWithValue(database),
            audioHandlerProvider.overrideWithValue(handler),
            subsonicApiProvider.overrideWithValue(null),
            recommendationServiceProvider.overrideWithValue(service),
            lyricsPrewarmProvider.overrideWithValue((_) async {}),
          ],
        );
        addTearDown(() async {
          if (!batch.isCompleted) {
            batch.complete(
              const RecommendationBatch(
                songs: [],
                source: RecommendationSource.server,
              ),
            );
          }
          container.dispose();
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final first = handler.play();
        await entered.future.timeout(const Duration(seconds: 1));
        final second = handler.play();
        await pumpEventQueue();
        expect(fetches, 1, reason: 'both Plays join the held radio fetch');
        switch (command) {
          case 'pause':
            await handler.pause();
          case 'stop':
            await handler.stop();
          case 'replace':
            await handler.replaceQueue(['song-1'], autoPlay: false);
          case 'play':
            // The second Play remains the newest intent.
            break;
        }
        batch.complete(
          const RecommendationBatch(
            songs: [models.Song(id: 'song-0', title: 'Song 0')],
            source: RecommendationSource.server,
          ),
        );
        await Future.wait([first, second]);
        await settleQueue(handler);
        expect(handler.snapshot.queueSongIds, switch (command) {
          'replace' => ['song-1'],
          'play' => ['song-0'],
          _ => isEmpty,
        });
        expect(handler.snapshot.playing, command == 'play');
        expect(player.isPlaying, command == 'play');
        expect(
          player.sourceLoads,
          command == 'pause' || command == 'stop' ? 0 : 1,
        );
        expect(fetches, command == 'play' ? 2 : 1);
        expect(container.read(personalRadioProvider).busy, isFalse);
        expect(handler.playbackState.value.errorMessage, isNull);
        await handler.debugFlushQueuePersistence();
        expect(
          (await database.playQueueDao.getQueueItems()).map((song) => song.id),
          handler.snapshot.queueSongIds,
        );
      },
    );
  }

  for (final replacement in [false, true]) {
    test(
      'cancelled first Play preserves newer queue (replacement: $replacement)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-cancel-play-',
        );
        late GatedSourceResolver resolver;
        final (handler, player, database) = await createHandler(
          directory,
          3,
          savedQueueIndex: 0,
          wrapResolver: (base) => resolver = GatedSourceResolver(base)
            ..blockedSongId = 'song-0'
            ..entered = Completer<void>()
            ..release = Completer<void>(),
          seed: (db) => db.libraryDao.upsertSongs([
            SongsTableCompanion.insert(
              id: 'song-1',
              title: 'Fallback',
              starred: Value(DateTime.now()),
            ),
          ]),
        );
        addTearDown(() async {
          if (!resolver.release!.isCompleted) resolver.release!.complete();
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final play = handler.play();
        await resolver.entered!.future.timeout(const Duration(seconds: 1));
        final newer = replacement
            ? handler.replaceQueue(
                ['song-2'],
                autoPlay: false,
                expandMatchFlows: false,
              )
            : handler.clearQueue();
        resolver.release!.complete();
        await Future.wait([play, newer]);
        await settleQueue(handler);
        expect(
          handler.snapshot.queueSongIds,
          replacement ? ['song-2'] : isEmpty,
        );
        expect(player.isPlaying, isFalse);
      },
    );
  }

  for (final index in [0, 1]) {
    for (final seconds in [2, 42]) {
      test(
        'first Previous uses saved position (index: $index, seconds: $seconds)',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'navis-first-previous-',
          );
          final (handler, player, database) = await createHandler(
            directory,
            3,
            savedQueueIndex: index,
            seed: (db) => db.playQueueDao.saveQueue(
              songIds: ['song-0', 'song-1', 'song-2'],
              currentIndex: index,
              positionMs: seconds * 1000,
            ),
          );
          addTearDown(() async {
            await handler.disposeHandler();
            await database.close();
            await directory.delete(recursive: true);
          });
          expect(player.sequence, isEmpty);
          await handler.skipToPrevious();
          await settleQueue(handler);
          expect(
            handler.snapshot.currentIndex,
            seconds > 3 ? index : (index - 1).clamp(0, 2),
          );
          expect(player.position, Duration.zero);
          expect(player.isPlaying, isFalse);
        },
      );
    }
  }

  test(
    'radio after metadata restore retains station media-session metadata',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-restored-radio-',
      );
      final (handler, _, database) = await createHandler(
        directory,
        3,
        savedQueueIndex: 1,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final items = <MediaItem?>[];
      final subscription = handler.mediaItem.listen(items.add);
      addTearDown(subscription.cancel);
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture Radio',
        streamUrl: 'https://fixture.invalid/radio',
      );
      await pumpEventQueue();
      expect(handler.snapshot.radioStation?.stationId, 'fixture');
      expect(handler.mediaItem.value?.id, 'radio:fixture');
      final stationPublished = items.indexWhere(
        (item) => item?.id == 'radio:fixture',
      );
      expect(stationPublished, greaterThanOrEqualTo(0));
      expect(items.skip(stationPublished), everyElement(isNotNull));
      expect(handler.snapshot.queueSongIds, isEmpty);
    },
  );

  test('uncached saved queue publishes metadata and position before any source resolution', () async {
    final directory = await Directory.systemTemp.createTemp(
      'navis-lazy-restore-',
    );
    final api = SubsonicApiClient(
      baseUrl: 'https://example.com',
      authConfig: const SubsonicAuthConfig(
        username: 'fixture',
        password: 'synthetic',
        apiVersion: '1.16.1',
      ),
      enableLogging: false,
    );
    late GatedSourceResolver resolver;
    final (handler, player, database) = await createHandler(
      directory,
      3,
      savedQueueIndex: 2,
      cacheSongs: false,
      readApiClient: () => api,
      wrapResolver: (base) => resolver = GatedSourceResolver(base)
        ..blockedSongId = 'song-1'
        ..entered = Completer<void>()
        ..release = Completer<void>(),
      seed: (db) => db.playQueueDao.saveQueue(
        songIds: ['song-1', 'song-0', 'song-1'],
        currentIndex: 2,
        positionMs: 42000,
        repeatMode: RepeatMode.all,
      ),
    );
    addTearDown(() async {
      if (!resolver.release!.isCompleted) resolver.release!.complete();
      await handler.disposeHandler();
      await database.close();
      api.close();
      await directory.delete(recursive: true);
    });
    expect(resolver.entered!.isCompleted, isFalse);
    expect(player.sequence, isEmpty);
    expect(handler.snapshot.currentIndex, 2);
    expect(handler.snapshot.position, const Duration(seconds: 42));
    expect(handler.snapshot.queueSongIds, ['song-1', 'song-0', 'song-1']);
    expect(handler.queue.value.map((item) => item.id), [
      'song-1',
      'song-0',
      'song-1',
    ]);
    expect(handler.mediaItem.value?.id, 'song-1');
    expect(handler.playbackState.value.queueIndex, 2);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.ready,
    );
    expect(handler.playbackState.value.playing, isFalse);
    expect(
      handler.playbackState.value.updatePosition,
      const Duration(seconds: 42),
    );
    final play = handler.play();
    await resolver.entered!.future.timeout(const Duration(seconds: 1));
    expect(handler.snapshot.isLoading, isTrue);
    resolver.release!.complete();
    await play;
    expect(handler.snapshot.currentIndex, 2);
    expect(player.position, const Duration(seconds: 42));
    expect(player.isPlaying, isTrue);
    expect(handler.snapshot.repeatMode, AudioServiceRepeatMode.all);
    expect(handler.snapshot.queueSongIds, ['song-1', 'song-0', 'song-1']);
  });

  for (final command in ['prepare', 'seek', 'next']) {
    test('first $command lazily materializes the restored queue', () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-lazy-transport-',
      );
      final (handler, player, database) = await createHandler(
        directory,
        3,
        savedQueueIndex: 1,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      expect(player.sequence, isEmpty);
      switch (command) {
        case 'prepare':
          await handler.prepare();
        case 'seek':
          await handler.seek(const Duration(seconds: 9));
        case 'next':
          await handler.skipToNext();
      }
      await settleQueue(handler);
      expect(player.sequence, hasLength(3));
      expect(handler.snapshot.currentIndex, command == 'next' ? 2 : 1);
      expect(player.isPlaying, isFalse);
    });
  }

  group('pending selection metadata', () {
    for (final path in ['ids', 'rows', 'remote', 'skip', 'jump']) {
      test(
        'publishes target before source preparation completes ($path)',
        () async {
          late GatedSourceResolver resolver;
          final directory = await Directory.systemTemp.createTemp(
            'navis-pending-',
          );
          final (handler, player, database) = await createHandler(
            directory,
            4,
            wrapResolver: (base) => resolver = GatedSourceResolver(base),
            queueWindow: const NavisQueueWindow(
              deferThreshold: 1,
              ahead: 0,
              behind: 0,
              lowWater: 0,
              page: 1,
              nearJump: 0,
            ),
          );
          addTearDown(() async {
            resolver.release?.complete();
            await handler.disposeHandler();
            await database.close();
            await directory.delete(recursive: true);
          });
          final rows = await database.libraryDao.getSongsByIds([
            'song-0',
            'song-1',
            'song-2',
            'song-3',
          ]);
          await handler.replaceQueueWithData(
            path == 'skip' || path == 'jump' ? rows : [rows[0]],
            expandMatchFlows: false,
          );
          final target = rows[path == 'jump' ? 3 : 1].copyWith(
            title: 'Picked title',
            artistName: const Value('Picked artist'),
            albumName: const Value('Picked album'),
            duration: const Value(123),
          );
          await database.libraryDao.upsertSongs([
            SongsTableCompanion.insert(
              id: target.id,
              title: target.title,
              artistName: Value(target.artistName),
              albumName: Value(target.albumName),
              duration: Value(target.duration),
            ),
          ]);
          resolver.blockedSongId = target.id;
          resolver.entered = Completer<void>();
          resolver.release = Completer<void>();
          Future<void> operation;
          if (path == 'remote') {
            handler.beginPlaybackSelection(
              target.id,
              isExternal: true,
              song: target.copyWith(isExternal: true),
            );
            expect(handler.mediaItem.valueOrNull?.title, target.title);
            expect(handler.snapshot.loadingSongId, target.id);
            operation = handler.replaceQueueWithData([
              target.copyWith(isExternal: true),
            ], expandMatchFlows: false);
          } else if (path == 'ids') {
            operation = handler.replaceQueue([
              target.id,
            ], expandMatchFlows: false);
          } else if (path == 'rows') {
            operation = handler.replaceQueueWithData([
              target,
            ], expandMatchFlows: false);
            expect(handler.mediaItem.valueOrNull?.id, target.id);
          } else if (path == 'skip') {
            operation = handler.skipToNext();
          } else {
            operation = handler.playFromIndex(3);
          }
          await resolver.entered!.future;
          expect(player.audibleSongId, 'song-0');
          final pending = handler.mediaItem.valueOrNull!;
          expect(pending.id, target.id);
          expect(pending.title, target.title);
          expect(pending.artist, target.artistName);
          expect(pending.album, target.albumName);
          expect(pending.duration, const Duration(seconds: 123));
          expect(handler.snapshot.currentSongId, target.id);
          expect(handler.snapshot.isLoading, isTrue);
          expect(handler.snapshot.loadingSongId, target.id);
          resolver.blockedSongId = null;
          resolver.release!.complete();
          resolver.release = null;
          await operation;
          await settleQueue(handler);
          expect(handler.mediaItem.valueOrNull?.id, target.id);
          expect(handler.mediaItem.valueOrNull?.title, pending.title);
          expect(handler.snapshot.isLoading, isFalse);
        },
      );
    }

    test(
      'failed source preparation restores metadata for the held source',
      () async {
        late GatedSourceResolver resolver;
        final directory = await Directory.systemTemp.createTemp(
          'navis-pending-failed-',
        );
        final (handler, player, database) = await createHandler(
          directory,
          2,
          wrapResolver: (base) => resolver = GatedSourceResolver(base),
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final rows = await database.libraryDao.getSongsByIds([
          'song-0',
          'song-1',
        ]);
        await handler.replaceQueueWithData([rows[0]], expandMatchFlows: false);
        resolver.blockedSongId = 'song-1';
        resolver.entered = Completer<void>();
        resolver.release = Completer<void>();
        resolver.failure = StateError('source failed');
        final operation = handler.replaceQueueWithData([
          rows[1],
        ], expandMatchFlows: false);
        final failed = expectLater(operation, throwsStateError);
        await resolver.entered!.future;
        expect(handler.mediaItem.valueOrNull?.id, 'song-1');
        resolver.release!.complete();
        await failed;
        expect(handler.mediaItem.valueOrNull?.id, 'song-0');
        expect(handler.snapshot.currentSongId, 'song-0');
        expect(handler.snapshot.isLoading, isFalse);
        expect(player.audibleSongId, 'song-0');
      },
    );

    test('failed provisional persistence retains the radio session', () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-radio-held-',
      );
      final (handler, player, database) = await createHandler(directory, 1);
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      player.icyEvents = StreamController<IcyMetadata?>.broadcast();
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture FM',
        streamUrl: 'https://radio.example.invalid/stream',
      );
      player.icyEvents!.add(
        IcyMetadata(
          info: IcyInfo(title: 'Held artist - Held title', url: null),
          headers: null,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final held = handler.snapshot.radioStation;
      final heldItem = handler.mediaItem.valueOrNull;
      final song = (await database.libraryDao.getSongsByIds(['song-0'])).single;
      final attempt = handler.beginPlaybackSelection(
        'song-0',
        isExternal: true,
        song: song,
      );
      expect(handler.mediaItem.valueOrNull?.id, 'song-0');
      handler.notePlaybackSelectionStage(
        attempt,
        'provisionalPersistenceFailed',
      );
      expect(handler.snapshot.radioStation, held);
      expect(handler.mediaItem.valueOrNull, heldItem);
      expect(handler.snapshot.isLoading, isFalse);
      expect(player.audibleSongId, 'radio:fixture');
      expect(player.icyEvents!.hasListener, isTrue);
      player.icyEvents!.add(
        IcyMetadata(
          info: IcyInfo(title: 'New artist - New title', url: null),
          headers: null,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(handler.snapshot.radioStation?.nowPlayingTitle, 'New title');
      expect(handler.mediaItem.valueOrNull?.title, 'New title');
    });

    test('failed provisional persistence restores held metadata', () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-provisional-failed-',
      );
      final (handler, player, database) = await createHandler(directory, 2);
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final rows = await database.libraryDao.getSongsByIds([
        'song-0',
        'song-1',
      ]);
      await handler.replaceQueueWithData([rows[0]], expandMatchFlows: false);
      final attempt = handler.beginPlaybackSelection(
        'song-1',
        isExternal: true,
        song: rows[1],
      );
      expect(handler.mediaItem.valueOrNull?.id, 'song-1');
      handler.notePlaybackSelectionStage(
        attempt,
        'provisionalPersistenceFailed',
      );
      expect(handler.mediaItem.valueOrNull?.id, 'song-0');
      expect(handler.snapshot.isLoading, isFalse);
      expect(player.audibleSongId, 'song-0');
    });

    for (final command in ['next', 'previous', 'index']) {
      test(
        'materialized $command publishes metadata before seek settles',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'navis-pending-seek-',
          );
          final (handler, player, database) = await createHandler(directory, 3);
          addTearDown(() async {
            await handler.disposeHandler();
            await database.close();
            await directory.delete(recursive: true);
          });
          await handler.replaceQueue(
            ['song-0', 'song-1', 'song-2'],
            startIndex: 1,
            expandMatchFlows: false,
          );
          player.simulatedPosition = Duration.zero;
          player.seekGate = Completer<void>();
          player.seekEntered = Completer<void>();
          final gate = player.seekGate!;
          final operation = switch (command) {
            'next' => handler.skipToNext(),
            'previous' => handler.skipToPrevious(),
            _ => handler.playFromIndex(0),
          };
          final target = command == 'next' ? 'song-2' : 'song-0';
          expect(handler.mediaItem.valueOrNull?.id, target);
          await player.seekEntered!.future;
          expect(player.audibleSongId, 'song-1');
          expect(handler.snapshot.currentSongId, target);
          expect(
            handler.playbackState.value.processingState,
            AudioProcessingState.loading,
          );
          gate.complete();
          await operation;
          await settleQueue(handler);
          expect(player.audibleSongId, target);
          expect(handler.mediaItem.valueOrNull?.id, target);
        },
      );
    }

    test(
      'superseded source preparation cannot overwrite a newer target',
      () async {
        late GatedSourceResolver resolver;
        final directory = await Directory.systemTemp.createTemp(
          'navis-pending-race-',
        );
        final (handler, _, database) = await createHandler(
          directory,
          3,
          wrapResolver: (base) => resolver = GatedSourceResolver(base),
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final rows = await database.libraryDao.getSongsByIds([
          'song-0',
          'song-1',
          'song-2',
        ]);
        await handler.replaceQueueWithData([rows[0]], expandMatchFlows: false);
        resolver.blockedSongId = 'song-1';
        resolver.entered = Completer<void>();
        resolver.release = Completer<void>();
        final older = handler.replaceQueueWithData([
          rows[1],
        ], expandMatchFlows: false);
        await resolver.entered!.future;
        expect(handler.mediaItem.valueOrNull?.id, 'song-1');
        final published = <String?>[];
        final sub = handler.mediaItem.listen((item) => published.add(item?.id));
        addTearDown(sub.cancel);
        final newer = handler.replaceQueueWithData([
          rows[2],
        ], expandMatchFlows: false);
        expect(handler.mediaItem.valueOrNull?.id, 'song-2');
        await pumpEventQueue();
        published.clear();
        resolver.release!.complete();
        await Future.wait([older, newer]);
        expect(handler.mediaItem.valueOrNull?.id, 'song-2');
        expect(published, isNot(contains('song-1')));
        expect(handler.snapshot.isLoading, isFalse);
      },
    );
  });

  for (final preparationFailure in [true, false]) {
    test(
      'append skips ${preparationFailure ? 'unavailable sources' : 'failed native insertions'} and persists valid occurrences',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-append-',
        );
        final (handler, player, database) = await createHandler(directory, 4);
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        await handler.replaceQueue([
          'song-0',
          'song-0',
        ], expandMatchFlows: false);
        if (preparationFailure) {
          await database.cacheDao.removeCachedTrack('song-2');
        } else {
          player.failAppendSongId = 'song-2';
        }
        await handler.addToQueue([
          'song-1',
          'song-2',
          'song-3',
        ], expandMatchFlows: false);
        expect(handler.snapshot.queueSongIds, [
          'song-0',
          'song-0',
          'song-1',
          'song-3',
        ]);
        expect(handler.snapshot.currentIndex, 0);
        expect(player.isPlaying, isTrue);
        await handler.debugFlushQueuePersistence();
        expect((await database.playQueueDao.getQueueItems()).map((s) => s.id), [
          'song-0',
          'song-0',
          'song-1',
          'song-3',
        ]);
      },
    );
  }

  test(
    'speed and pitch apply to both decks, survive clear, and rollback together',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis_adjustment_decks_',
      );
      final (handler, player, database) = await createHandler(
        directory,
        2,
        crossfade: true,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      const values = PlaybackAdjustments(speed: 1.2735, pitchSemitones: -2.37);
      await handler.setPlaybackAdjustments(values);
      var diagnostics = handler.collectPlaybackDiagnostics();
      expect(player.appliedSpeed, values.speed);
      expect(player.appliedPitch, closeTo(values.pitchFactor, 0.000001));
      expect(diagnostics['crossfadeSpeed'], values.speed);
      expect(
        diagnostics['crossfadePitchFactor'],
        closeTo(values.pitchFactor, 0.000001),
      );
      await handler.clearQueue();
      diagnostics = handler.collectPlaybackDiagnostics();
      expect(diagnostics['playerSpeed'], values.speed);
      expect(
        diagnostics['crossfadePitchFactor'],
        closeTo(values.pitchFactor, 0.000001),
      );
      player.failPitchOnce = true;
      await expectLater(
        handler.setPlaybackAdjustments(
          const PlaybackAdjustments(speed: 1.75, pitchSemitones: 2),
        ),
        throwsStateError,
      );
      expect(player.appliedSpeed, values.speed);
      expect(player.appliedPitch, closeTo(values.pitchFactor, 0.000001));
      await handler.setPlaybackSpeed(1.375);
      expect(player.appliedPitch, closeTo(values.pitchFactor, 0.000001));
      expect(player.appliedSpeed, 1.375);
      final confirmations = <PlaybackAdjustments>[];
      final subscription = handler.playbackAdjustmentsStream.listen(
        confirmations.add,
      );
      const linked = PlaybackAdjustments(speed: 1.25, lockPitchToSpeed: true);
      final lockOperation = handler.setPlaybackAdjustments(linked);
      final directOperation = handler.setSpeed(1.3);
      await Future.wait([lockOperation, directOperation]);
      expect(player.appliedSpeed, 1.3);
      expect(player.appliedPitch, 1.3);
      expect(handler.playbackAdjustments.lockPitchToSpeed, isTrue);
      expect(handler.collectPlaybackDiagnostics()['crossfadePitchFactor'], 1.3);
      final frozen = handler.playbackAdjustments.copyWith(
        lockPitchToSpeed: false,
      );
      await handler.setPlaybackAdjustments(frozen);
      await handler.setPlaybackSpeed(1.5);
      expect(player.appliedPitch, closeTo(1.3, 1e-14));
      await Future<void>.delayed(Duration.zero);
      expect(confirmations.last, handler.playbackAdjustments);
      await subscription.cancel();
    },
  );

  group('iOS independent pitch (I21)', () {
    Future<(NavisAudioHandler, ControllableAudioPlayer)> iosHandler({
      bool? ios = true,
      PlaybackAdjustmentCapabilities? injected,
      EqCapabilities? equalizer = EqCapabilities.available,
    }) async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-ios-pitch-',
      );
      final (handler, player, database) = await createHandler(
        directory,
        1,
        iosRuntimeOverride: ios,
        adjustmentCapabilities: injected,
        equalizerCapabilities: equalizer,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      return (handler, player);
    }

    test('iOS with the equalizer pipeline on reports the iOS limits', () async {
      final (handler, _) = await iosHandler();
      expect(
        handler.playbackAdjustmentCapabilities,
        PlaybackAdjustmentCapabilities.ios,
      );
    });

    // One handler (and database) per test: drift warns when two are open at once.
    test('iOS without the equalizer pipeline reports no pitch', () async {
      final (off, _) = await iosHandler(equalizer: EqCapabilities.unavailable);
      expect(off.playbackAdjustmentCapabilities.pitchSupported, isFalse);
    });

    test('a non-iOS platform reports no pitch', () async {
      final (notIos, _) = await iosHandler(ios: false);
      expect(notIos.playbackAdjustmentCapabilities.pitchSupported, isFalse);
    });

    test('an unset platform reports no pitch', () async {
      final (unset, _) = await iosHandler(ios: null);
      expect(unset.playbackAdjustmentCapabilities.pitchSupported, isFalse);
    });

    test(
      'locked to speed 1.25 sends pitch 1.25 and a speed change re-sends it',
      () async {
        final (handler, player) = await iosHandler();
        await handler.setPlaybackAdjustments(
          const PlaybackAdjustments(speed: 1.25, lockPitchToSpeed: true),
        );
        expect(player.appliedSpeed, 1.25);
        expect(player.appliedPitch, 1.25);
        await handler.setPlaybackSpeed(1.5);
        expect(player.appliedPitch, 1.5);
      },
    );

    test('independent +5 semitones sends the pitch factor', () async {
      final (handler, player) = await iosHandler();
      await handler.setPlaybackAdjustments(
        const PlaybackAdjustments(speed: 1.5, pitchSemitones: 5),
      );
      expect(player.appliedSpeed, 1.5);
      expect(player.appliedPitch, closeTo(pow(2, 5 / 12), 1e-12));
    });

    test('pitch_unavailable downgrades the capabilities once and does not loop', () async {
      final (handler, player) = await iosHandler();
      final before = player.pitchCalls;
      player.pitchError = PlatformException(code: 'pitch_unavailable');
      await expectLater(
        handler.setPlaybackAdjustments(
          const PlaybackAdjustments(pitchSemitones: 2),
        ),
        throwsA(isA<PlatformException>()),
      );
      // One failing call; the rollback does not ask the player for pitch again.
      expect(player.pitchCalls, before + 1);
      expect(handler.playbackAdjustmentCapabilities.pitchSupported, isFalse);
      expect(handler.playbackAdjustments, const PlaybackAdjustments());
      // Speed still works for the rest of the session without touching pitch.
      await handler.setPlaybackSpeed(1.2);
      expect(player.appliedSpeed, 1.2);
      expect(player.pitchCalls, before + 1);
    });
  });

  test(
    'ignored seek during loading reloads the full queue at target',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-nav-test-',
      );
      final (handler, player, database) = await createHandler(directory, 3);
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final songs = await database.libraryDao.getSongsByIds(<String>[
        'song-0',
        'song-1',
        'song-2',
      ]);
      await handler.replaceQueueWithData(songs);
      expect(player.audioSources.length, 3);

      player.state = ProcessingState.loading;
      await handler.skipToNext();
      await handler.snapshotStream
          .firstWhere(
            (snapshot) =>
                snapshot.currentIndex == 1 &&
                snapshot.pendingQueueIndex == null &&
                snapshot.processingState == AudioProcessingState.ready,
          )
          .timeout(const Duration(seconds: 5));

      expect(player.currentIndex, 1);
      expect(player.lastSetAudioSourcesCount, 3);
      expect(player.audioSources.length, 3);
    },
  );

  group('iOS queue start (gapless)', () {
    // AVQueuePlayer joins songs gaplessly only when the queue did not start
    // with a single item, so on iOS the first load carries the start song and
    // the one after it. Phase 2 then fills in the rest around them.
    Future<(NavisAudioHandler, ControllableAudioPlayer, List<SongsTableData>)>
    replaceFour({
      required bool ios,
      required int startIndex,
      required Directory directory,
    }) async {
      final (handler, player, database) = await createHandler(
        directory,
        4,
        iosRuntimeOverride: ios,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final songs = await database.libraryDao.getSongsByIds(<String>[
        'song-0',
        'song-1',
        'song-2',
        'song-3',
      ]);
      await handler.replaceQueueWithData(songs, startIndex: startIndex);
      return (handler, player, songs);
    }

    const allSongs = <String>['song-0', 'song-1', 'song-2', 'song-3'];

    test('the first load holds the start song and the next one', () async {
      final directory = await Directory.systemTemp.createTemp('navis-ios-');
      final (handler, player, _) = await replaceFour(
        ios: true,
        startIndex: 0,
        directory: directory,
      );
      expect(player.setAudioSourcesCounts.first, 2);
      expect(player.setAudioSourcesCounts, hasLength(1));
      expect(player.sourceIds, allSongs);
      expect(handler.queue.value.map((item) => item.id), allSongs);
      expect(player.currentIndex, 0);
    });

    test(
      'a start in the middle loads it with the next, then both sides',
      () async {
        final directory = await Directory.systemTemp.createTemp('navis-ios-');
        final (handler, player, _) = await replaceFour(
          ios: true,
          startIndex: 2,
          directory: directory,
        );
        expect(player.setAudioSourcesCounts.first, 2);
        expect(player.sourceIds, allSongs);
        expect(handler.queue.value.map((item) => item.id), allSongs);
        expect(player.currentIndex, 2);
      },
    );

    test('the last song has no next one to load with it', () async {
      final directory = await Directory.systemTemp.createTemp('navis-ios-');
      final (_, player, _) = await replaceFour(
        ios: true,
        startIndex: 3,
        directory: directory,
      );
      expect(player.setAudioSourcesCounts.first, 1);
      expect(player.sourceIds, allSongs);
    });

    // The next song's resolve is gated (or fails) to exercise phase 1's wait.
    Future<
      (
        NavisAudioHandler,
        ControllableAudioPlayer,
        GatedSourceResolver,
        List<SongsTableData>,
      )
    >
    gatedFour({
      NavisPlaybackTimeouts timeouts = const NavisPlaybackTimeouts(),
      bool hold = true,
      StateError? failure,
    }) async {
      final directory = await Directory.systemTemp.createTemp('navis-ios-');
      late GatedSourceResolver resolver;
      final (handler, player, database) = await createHandler(
        directory,
        4,
        iosRuntimeOverride: true,
        timeouts: timeouts,
        wrapResolver: (base) => resolver = GatedSourceResolver(base)
          ..blockedSongId = 'song-1'
          ..entered = Completer<void>()
          ..release = hold ? Completer<void>() : (Completer<void>()..complete())
          ..failure = failure,
      );
      addTearDown(() async {
        if (!resolver.release!.isCompleted) resolver.release!.complete();
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final songs = await database.libraryDao.getSongsByIds(<String>[
        'song-0',
        'song-1',
        'song-2',
        'song-3',
      ]);
      return (handler, player, resolver, songs);
    }

    test('a next song that cannot resolve starts with one source', () async {
      final (handler, player, _, songs) = await gatedFour(
        hold: false,
        failure: StateError('unavailable'),
      );
      await handler.replaceQueueWithData(songs);
      expect(player.setAudioSourcesCounts.first, 1);
      // Phase 2 cannot resolve it either: the player and Dart agree without it.
      expect(player.sourceIds, ['song-0', 'song-2', 'song-3']);
      expect(handler.queue.value.map((item) => item.id), player.sourceIds);
    });

    test('a slow next song does not delay the start song', () async {
      final (handler, player, resolver, songs) = await gatedFour(
        timeouts: const NavisPlaybackTimeouts(
          nextSongPreload: Duration(milliseconds: 100),
        ),
      );
      final replace = handler.replaceQueueWithData(songs);
      await resolver.entered!.future.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(player.setAudioSourcesCounts, [1], reason: 'start song alone');
      expect(player.isPlaying || player.sourceIds.isNotEmpty, isTrue);
      resolver.release!.complete();
      await replace;
      expect(player.sourceIds, allSongs, reason: 'phase 2 appends song-1');
      expect(handler.queue.value.map((item) => item.id), allSongs);
    });

    test('a newer queue command while the next song resolves wins', () async {
      final (handler, player, resolver, songs) = await gatedFour();
      final older = handler.replaceQueueWithData(songs);
      await resolver.entered!.future.timeout(const Duration(seconds: 1));
      final newer = handler.replaceQueue([
        'song-2',
        'song-3',
      ], expandMatchFlows: false);
      resolver.release!.complete();
      await Future.wait([older.catchError((Object _) {}), newer]);
      await settleQueue(handler);
      expect(handler.queue.value.map((item) => item.id), ['song-2', 'song-3']);
      expect(player.sourceIds, ['song-2', 'song-3']);
    });

    test(
      'a fill that does not land leaves the queue listing the player',
      () async {
        final directory = await Directory.systemTemp.createTemp('navis-ios-');
        final (handler, player, database) = await createHandler(
          directory,
          4,
          iosRuntimeOverride: true,
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final songs = await database.libraryDao.getSongsByIds(allSongs);
        // Every append fails: only the start song and the preloaded next one land.
        player.failAppendSongId = 'song-2';
        await handler.replaceQueueWithData(songs);
        expect(player.sourceIds, ['song-0', 'song-1']);
        expect(handler.queue.value.map((item) => item.id), player.sourceIds);
      },
    );

    test(
      'an apply that fails does not leave the preloaded song in the queue',
      () async {
        final directory = await Directory.systemTemp.createTemp('navis-ios-');
        final (handler, player, database) = await createHandler(
          directory,
          4,
          iosRuntimeOverride: true,
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final songs = await database.libraryDao.getSongsByIds(allSongs);
        player.failLoadSongId = 'song-0';
        await handler.replaceQueueWithData(songs).catchError((Object _) {});
        await pumpEventQueue(times: 50);
        // The player holds nothing; the queue must not list the next song it
        // never received (a restore would take it for a loaded single song).
        expect(player.sourceIds, isEmpty);
        expect(handler.snapshot.queueSongIds, isNot(contains('song-1')));
        expect(handler.snapshot.queueSongIds.length, lessThanOrEqualTo(1));
      },
    );

    test(
      'an advance to the preloaded song before phase 2 lands is listed',
      () async {
        final directory = await Directory.systemTemp.createTemp('navis-ios-');
        final (handler, player, database) = await createHandler(
          directory,
          4,
          iosRuntimeOverride: true,
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final songs = await database.libraryDao.getSongsByIds(allSongs);
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..appendGate = gate
          ..appendEntered = entered;
        final replace = handler.replaceQueueWithData(songs);
        await entered.future.timeout(const Duration(seconds: 2));
        // Phase 2 is inside its first append: the player holds [song-0, song-1]
        // and Dart lists the same two. The player advances to song-1 now.
        expect(player.sourceIds, ['song-0', 'song-1']);
        player.moveTo(1);
        await pumpEventQueue(times: 50);
        expect(handler.snapshot.currentSongId, 'song-1');
        gate.complete();
        await replace;
        await settleQueue(handler);
        expect(player.sourceIds, allSongs);
        expect(handler.queue.value.map((item) => item.id), allSongs);
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(handler.snapshot.currentIndex, 1);
      },
    );

    test('other platforms keep loading only the start song first', () async {
      final directory = await Directory.systemTemp.createTemp('navis-ios-');
      final (handler, player, _) = await replaceFour(
        ios: false,
        startIndex: 0,
        directory: directory,
      );
      expect(player.setAudioSourcesCounts.first, 1);
      expect(player.sourceIds, allSongs);
      expect(handler.queue.value.map((item) => item.id), allSongs);
    });
  });

  test('large queue fill applies sources in batches, in order', () async {
    final directory = await Directory.systemTemp.createTemp('navis-nav-test-');
    final (handler, player, database) = await createHandler(directory, 100);
    addTearDown(() async {
      await handler.disposeHandler();
      await database.close();
      await directory.delete(recursive: true);
    });
    final ids = List<String>.generate(100, (index) => 'song-$index');
    final songs = await database.libraryDao.getSongsByIds(ids);
    final byId = {for (final song in songs) song.id: song};
    final filled = handler.snapshotStream
        .firstWhere((snapshot) => snapshot.queueSongIds.length == 100)
        .timeout(const Duration(seconds: 60));
    await handler.replaceQueueWithData([
      for (final id in ids) byId[id]!,
    ], startIndex: 50);
    await filled;

    // A small first batch then 64-song batches on each side of the start,
    // instead of one native mutation per song.
    expect(player.batchMutationCount, 4);
    expect(handler.snapshot.queueSongIds, ids);
    expect(player.sequence.map((source) => (source.tag as MediaItem).id), ids);
    expect(handler.snapshot.currentIndex, 50);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'large saved queue restores the current item first, then fills in order',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-nav-test-',
      );
      final (handler, player, database) = await createHandler(
        directory,
        100,
        savedQueueIndex: 40,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final ids = List<String>.generate(100, (index) => 'song-$index');

      // Ready resolves before the background fill, with the saved current
      // item already loaded and the full logical queue visible.
      expect(handler.snapshot.currentSongId, 'song-40');
      expect(handler.snapshot.queueSongIds, ids);

      expect(player.sequence, isEmpty);
      await handler.prepare();
      if (player.sequence.length != 100)
        await handler.snapshotStream
            .firstWhere((snapshot) => player.sequence.length == 100)
            .timeout(const Duration(seconds: 30));
      await pumpEventQueue();
      expect(
        player.sequence.map((source) => (source.tag as MediaItem).id),
        ids,
      );
      expect(handler.snapshot.currentIndex, 40);
      expect(handler.snapshot.currentSongId, 'song-40');
      expect(
        (await database.playQueueDao.getQueueItems()).map((song) => song.id),
        ids,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('a burst of reorders persists the final queue once', () async {
    final directory = await Directory.systemTemp.createTemp('navis-nav-test-');
    final (handler, player, database) = await createHandler(directory, 6);
    addTearDown(() async {
      await handler.disposeHandler();
      await database.close();
      await directory.delete(recursive: true);
    });
    final ids = List<String>.generate(6, (index) => 'song-$index');
    await handler.replaceQueueWithData(
      await database.libraryDao.getSongsByIds(ids),
    );

    for (var i = 0; i < 4; i++) {
      await handler.reorderQueue(5, 1);
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final persistence =
        handler.collectPlaybackDiagnostics()['persistence']!
            as Map<String, Object?>;
    final byContext = persistence['byContext']! as Map<String, int>;
    expect(byContext['reorder queue'], 1);
    expect(
      (await database.playQueueDao.getQueueItems()).map((song) => song.id),
      handler.snapshot.queueSongIds,
    );
    expect(handler.snapshot.queueSongIds, isNot(ids));
  });

  test('skipping right after a queue edit still persists the edit', () async {
    final directory = await Directory.systemTemp.createTemp('navis-nav-test-');
    final (handler, player, database) = await createHandler(directory, 6);
    addTearDown(() async {
      await handler.disposeHandler();
      await database.close();
      await directory.delete(recursive: true);
    });
    final ids = List<String>.generate(6, (index) => 'song-$index');
    await handler.replaceQueueWithData(
      await database.libraryDao.getSongsByIds(ids),
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));

    await handler.reorderQueue(5, 1);
    await handler.skipToNext();
    // The real 300 ms debounce, awaited through its completed write.
    await until(
      () =>
          (((handler.collectPlaybackDiagnostics()['persistence']!
                      as Map<String, Object?>)['byContext']!
                  as Map<String, int>)['reorder queue'] ??
              0) >=
          1,
      cap: const Duration(seconds: 5),
      reason: 'the reorder is written despite the skip',
    );
    // Later saves (the skip's 250 ms transport write) must not undo it: keep
    // a window of three debounce periods past the write.
    await Future<void>.delayed(const Duration(milliseconds: 900));

    expect(handler.snapshot.queueSongIds, isNot(ids));
    expect(
      (await database.playQueueDao.getQueueItems()).map((song) => song.id),
      handler.snapshot.queueSongIds,
    );
  });

  test(
    'unavailable Next reports the desired radio tail during a burst',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-nav-test-',
      );
      final requests = <({int index, String songId})?>[];
      final (handler, player, database) = await createHandler(
        directory,
        3,
        onPersonalRadioQueueEnd: requests.add,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      await handler.replaceQueueWithData(
        await database.libraryDao.getSongsByIds(['song-0', 'song-1', 'song-2']),
      );

      final gate = Completer<void>();
      player.seekGate = gate;
      await handler.skipToNext();
      await handler.skipToNext();
      // Applied skips cancel any held tail skip.
      expect(requests, [null, null]);
      await handler.skipToNext();
      expect(requests.last, (index: 2, songId: 'song-2'));
      expect(handler.snapshot.pendingQueueIndex, 2);
      gate.complete();
      await handler.snapshotStream
          .firstWhere(
            (snapshot) =>
                snapshot.currentIndex == 2 &&
                snapshot.pendingQueueIndex == null,
          )
          .timeout(const Duration(seconds: 5));

      // Ordinary end-of-queue Next stays on the current song until append.
      await handler.skipToNext();
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(requests.nonNulls, [
        (index: 2, songId: 'song-2'),
        (index: 2, songId: 'song-2'),
      ]);

      // Repeat-all still wraps rather than requesting a refill skip.
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      await handler.skipToNext();
      await handler.snapshotStream
          .firstWhere(
            (snapshot) =>
                snapshot.currentIndex == 0 &&
                snapshot.pendingQueueIndex == null,
          )
          .timeout(const Duration(seconds: 5));
      // The wrap is an applied skip, so it only cancels.
      expect(requests.nonNulls, hasLength(2));
      expect(requests.last, isNull);
    },
  );

  test('burst keeps latest target and serializes player mutations', () async {
    final directory = await Directory.systemTemp.createTemp('navis-nav-test-');
    final (handler, player, database) = await createHandler(directory, 20);
    addTearDown(() async {
      await handler.disposeHandler();
      await database.close();
      await directory.delete(recursive: true);
    });
    final ids = List<String>.generate(20, (index) => 'song-$index');
    await handler.replaceQueueWithData(
      await database.libraryDao.getSongsByIds(ids),
    );
    final gate = Completer<void>();
    player.seekGate = gate;
    await handler.skipToNext();
    for (var i = 0; i < 99; i++) {
      await handler.skipToNext();
    }
    expect(handler.snapshot.pendingQueueIndex, 19);
    expect(
      handler.collectPlaybackDiagnostics()['navigation'],
      containsPair('pendingQueueMutations', 1),
    );
    gate.complete();
    await handler.snapshotStream
        .firstWhere(
          (snapshot) =>
              snapshot.currentIndex == 19 && snapshot.pendingQueueIndex == null,
        )
        .timeout(const Duration(seconds: 5));
    expect(player.maxConcurrentMutations, 1);
  });

  test(
    'Pause during a delayed selection stays paused when load completes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-nav-test-',
      );
      final (handler, player, database) = await createHandler(directory, 3);
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final songs = await database.libraryDao.getSongsByIds(<String>[
        'song-0',
        'song-1',
        'song-2',
      ]);
      await handler.replaceQueueWithData(songs);

      final loadEntered = Completer<void>();
      final releaseLoad = Completer<void>();
      player.state = ProcessingState.loading;
      player.loadGate = releaseLoad;
      player.loadEntered = loadEntered;
      await handler.playFromIndex(2);
      await loadEntered.future.timeout(const Duration(seconds: 5));
      await handler.pause();
      final settled = handler.snapshotStream
          .firstWhere(
            (snapshot) =>
                snapshot.currentIndex == 2 &&
                snapshot.pendingQueueIndex == null &&
                snapshot.processingState == AudioProcessingState.ready,
          )
          .timeout(const Duration(seconds: 5));
      releaseLoad.complete();
      final snapshot = await settled;

      expect(snapshot.playing, isFalse);
      expect(player.playing, isFalse);
    },
  );

  for (final input in ['ids', 'expanded rows', 'canonical rows']) {
    for (final duplicate in [false, true]) {
      test('missing prefix preserves the selected occurrence '
          '($input, duplicate=$duplicate)', () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-missing-',
        );
        final (handler, player, database) = await createHandler(directory, 2);
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final rows = await database.libraryDao.getSongsByIds([
          'song-0',
          'song-1',
        ]);
        final requested = [
          'missing',
          'song-0',
          'song-1',
          if (duplicate) ...['song-0', 'song-1'],
        ];
        final startIndex = duplicate ? 3 : 1;
        if (input == 'ids') {
          await handler.replaceQueue(
            requested,
            startIndex: startIndex,
            expandMatchFlows: false,
          );
        } else {
          final first = input == 'canonical rows'
              ? rows.first.copyWith(id: 'retired-0')
              : rows.first;
          if (input == 'canonical rows') {
            await handler.applySongIdentityAliases({'retired-0': 'song-0'});
          }
          await handler.replaceQueueWithData(
            [
              rows.first.copyWith(id: 'missing'),
              first,
              rows.last,
              if (duplicate) ...[first, rows.last],
            ],
            startIndex: startIndex,
            expandMatchFlows: input == 'expanded rows',
          );
        }

        expect(handler.snapshot.currentSongId, 'song-0');
        expect(handler.snapshot.currentIndex, duplicate ? 2 : 0);
        expect(player.index, duplicate ? 2 : 0);
        expect(handler.snapshot.queueSongIds, requested.skip(1));
        await handler.debugFlushQueuePersistence();
        expect(
          (await database.playQueueDao.getQueueState())!.currentIndex,
          duplicate ? 2 : 0,
        );
      });
    }
  }

  group('relinked remote copy in the deferred queue', () {
    // A queue longer than the loaded window keeps later songs deferred. A
    // remote copy there carries its own row; after its relink the entry must
    // hold the library id, or every queue save fails on the deleted row.
    for (final where in ['tail', 'head']) {
      test(
        'the $where entry takes the library id and the queue saves',
        () async {
          final directory = await Directory.systemTemp.createTemp('navis-ext-');
          final database = createTestDatabase();
          const window = NavisQueueWindow(
            deferThreshold: 1,
            ahead: 0,
            behind: 0,
            lowWater: 0,
            page: 1,
            nearJump: 0,
          );
          final first = await createHandler(
            directory,
            4,
            sharedDatabase: database,
            queueWindow: window,
          );
          final handler = first.$1;
          var handlerDisposed = false;
          addTearDown(() async {
            if (!handlerDisposed) await handler.disposeHandler();
            await database.close();
            await directory.delete(recursive: true);
          });
          await database
              .into(database.songsTable)
              .insert(
                SongsTableData(
                  id: 'ext-deezer-song-9',
                  title: 'Remote copy',
                  artistName: 'Artist',
                  albumName: 'Album',
                  duration: 180,
                  isProvisional: true,
                  isExternal: true,
                ),
              );
          final rows = await database.libraryDao.getSongsByIds([
            'song-0',
            'song-1',
            'song-2',
          ]);
          final remote = (await database.libraryDao.getSongById(
            'ext-deezer-song-9',
          ))!;
          if (where == 'tail') {
            await handler.replaceQueueWithData([
              rows[0],
              rows[1],
              remote,
            ], expandMatchFlows: false);
          } else {
            await handler.replaceQueueWithData(
              [remote, rows[0], rows[1]],
              startIndex: 1,
              expandMatchFlows: false,
            );
          }
          expect(handler.snapshot.queueSongIds, contains('ext-deezer-song-9'));

          await handler.applySongIdentityAliases({
            'ext-deezer-song-9': 'song-2',
          });
          await database.songIdentityDao.remapSongIdentity(
            oldSongId: 'ext-deezer-song-9',
            canonicalSongId: 'song-2',
            matchReason: 'exactMetadata',
          );
          await pumpEventQueue();
          await handler.debugFlushQueuePersistence();

          final live = handler.snapshot.queueSongIds;
          expect(live, isNot(contains('ext-deezer-song-9')));
          expect(live, contains('song-2'));
          final saved = (await database.playQueueDao.getQueueItems())
              .map((song) => song.id)
              .toList();
          expect(saved, live);

          handlerDisposed = true;
          await handler.disposeHandler();
          final second = await createHandler(
            directory,
            4,
            sharedDatabase: database,
            queueWindow: window,
          );
          addTearDown(second.$1.disposeHandler);
          await pumpEventQueue();
          expect(second.$1.snapshot.queueSongIds, live);
        },
      );
    }
  });

  test('a remote row handed over again after its relink is healed', () async {
    final directory = await Directory.systemTemp.createTemp('navis-ext-');
    final (handler, _, database) = await createHandler(
      directory,
      4,
      queueWindow: const NavisQueueWindow(
        deferThreshold: 1,
        ahead: 0,
        behind: 0,
        lowWater: 0,
        page: 1,
        nearJump: 0,
      ),
    );
    addTearDown(() async {
      await handler.disposeHandler();
      await database.close();
      await directory.delete(recursive: true);
    });
    const extId = 'ext-deezer-song-9';
    await database
        .into(database.songsTable)
        .insert(
          SongsTableData(
            id: extId,
            title: 'Remote copy',
            artistName: 'Artist',
            albumName: 'Album',
            duration: 180,
            isProvisional: true,
            isExternal: true,
          ),
        );
    final rows = await database.libraryDao.getSongsByIds(['song-0', 'song-1']);
    final remote = (await database.libraryDao.getSongById(extId))!;
    await handler.replaceQueueWithData([
      rows[0],
      rows[1],
      remote,
    ], expandMatchFlows: false);
    await handler.applySongIdentityAliases({extId: 'song-2'});
    await database.songIdentityDao.remapSongIdentity(
      oldSongId: extId,
      canonicalSongId: 'song-2',
      matchReason: 'exactMetadata',
    );
    await pumpEventQueue();

    // The in-memory row comes back although its database row is gone.
    await handler.replaceQueueWithData([
      rows[0],
      rows[1],
      remote,
    ], expandMatchFlows: false);
    expect(handler.snapshot.queueSongIds, contains(extId));
    await SongIdentityReconciler(
      database.songIdentityDao,
      onBeforeRemap: handler.applySongIdentityAliases,
    ).relinkExternalCopies(<String>[extId]);
    await pumpEventQueue();
    await handler.debugFlushQueuePersistence();

    final live = handler.snapshot.queueSongIds;
    expect(live, ['song-0', 'song-1', 'song-2']);
    expect(
      (await database.playQueueDao.getQueueItems()).map((song) => song.id),
      live,
    );
  });

  group('relinked remote copy ids', () {
    // A remote copy relinked to its library song (#209) is deleted, but
    // callers can still hand the handler its old id. Every entry resolves it.
    for (final nonEmpty in [false, true]) {
      for (final op in [
        'addToQueue',
        'playNext',
        'replaceQueue',
        'replaceQueueWithData',
      ]) {
        test('$op resolves the retired id (nonEmptyQueue=$nonEmpty)', () async {
          final directory = await Directory.systemTemp.createTemp('navis-ext-');
          final (handler, _, database) = await createHandler(directory, 3);
          addTearDown(() async {
            await handler.disposeHandler();
            await database.close();
            await directory.delete(recursive: true);
          });
          if (nonEmpty) {
            await handler.replaceQueue(['song-1'], expandMatchFlows: false);
          }
          await handler.applySongIdentityAliases({
            'ext-deezer-song-1': 'song-0',
          });

          switch (op) {
            case 'addToQueue':
              await handler.addToQueue(['ext-deezer-song-1']);
            case 'playNext':
              await handler.playNext(['ext-deezer-song-1']);
            case 'replaceQueue':
              await handler.replaceQueue([
                'ext-deezer-song-1',
              ], expandMatchFlows: false);
            case _:
              final rows = await database.libraryDao.getSongsByIds(['song-0']);
              await handler.replaceQueueWithData([
                rows.single.copyWith(id: 'ext-deezer-song-1'),
              ], expandMatchFlows: false);
          }

          expect(handler.snapshot.queueSongIds, contains('song-0'));
          expect(
            handler.snapshot.queueSongIds,
            isNot(contains('ext-deezer-song-1')),
          );
        });
      }
    }
  });

  group('queue replacement input contracts', () {
    for (final newerReplacement in [false, true]) {
      test('cancelled empty ID resolution preserves the newer queue command '
          '(replacement=$newerReplacement)', () async {
        final directory = await Directory.systemTemp.createTemp('navis-empty-');
        late GatedLibraryDao dao;
        final (handler, player, database) = await createHandler(
          directory,
          3,
          createLibraryDao: (database) => dao = GatedLibraryDao(database),
        );
        addTearDown(() async {
          if (!dao.release.isCompleted) dao.release.complete();
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final ids = ['song-0', 'song-1', 'song-2'];
        await handler.replaceQueue(ids, expandMatchFlows: false);
        final obsolete = handler.replaceQueue([
          'missing',
        ], expandMatchFlows: false);
        await dao.entered.future;
        final newer = newerReplacement
            ? handler.replaceQueue(ids, startIndex: 1, expandMatchFlows: false)
            : handler.skipToNext();
        final settled = handler.snapshotStream.firstWhere(
          (snapshot) =>
              !snapshot.isLoading && snapshot.pendingQueueIndex == null,
        );
        dao.release.complete();
        await obsolete;
        await newer;
        await settled;
        await handler.debugFlushQueuePersistence();

        expect(handler.snapshot.queueSongIds, ids);
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(player.sourceIds, ids);
        expect(
          (await database.playQueueDao.getQueueItems()).map((song) => song.id),
          ids,
        );
        expect(await database.playQueueDao.getQueueState(), isNotNull);
      });
    }

    for (final suppliedRows in [false, true]) {
      test('superseded empty clear keeps the saved queue across native awaits '
          '(rows=$suppliedRows)', () async {
        final directory = await Directory.systemTemp.createTemp('navis-clear-');
        final (handler, player, database) = await createHandler(directory, 3);
        final stopping = Completer<void>();
        final releaseStop = Completer<void>();
        final loading = Completer<void>();
        final releaseLoad = Completer<void>();
        addTearDown(() async {
          if (!releaseStop.isCompleted) releaseStop.complete();
          if (!releaseLoad.isCompleted) releaseLoad.complete();
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final ids = ['song-0', 'song-1', 'song-2'];
        await handler.replaceQueue(ids, expandMatchFlows: false);
        player
          ..stopEntered = stopping
          ..stopGate = releaseStop;
        final obsolete = suppliedRows
            ? handler.replaceQueueWithData([])
            : handler.replaceQueue(['missing'], expandMatchFlows: false);
        await stopping.future;
        player
          ..gateNonEmptyLoadsOnly = true
          ..loadEntered = loading
          ..loadGate = releaseLoad;
        final newer = handler.replaceQueue(
          ids,
          startIndex: 1,
          expandMatchFlows: false,
        );
        releaseStop.complete();
        await obsolete;
        await loading.future;
        expect(
          (await database.playQueueDao.getQueueItems()).map((song) => song.id),
          ids,
        );
        releaseLoad.complete();
        await newer;
        expect(handler.snapshot.queueSongIds, ids);
        expect(handler.snapshot.currentSongId, 'song-1');
      });
    }

    for (final suppliedRows in [false, true]) {
      test('admits and saves the logical selection before fill '
          '(rows=$suppliedRows)', () async {
        final directory = await Directory.systemTemp.createTemp('navis-admit-');
        final (handler, player, database) = await createHandler(directory, 4);
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final ids = List.generate(4, (i) => 'song-$i');
        final rows = await database.libraryDao.getSongsByIds(ids);
        final loaded = Completer<void>();
        final releaseLoad = Completer<void>();
        final filling = Completer<void>();
        final releaseFill = Completer<void>();
        player
          ..loadEntered = loaded
          ..loadGate = releaseLoad
          ..appendEntered = filling
          ..appendGate = releaseFill;
        final replacement = suppliedRows
            ? handler.replaceQueueWithData(
                rows,
                startIndex: 1,
                expandMatchFlows: false,
              )
            : handler.replaceQueue(ids, startIndex: 1, expandMatchFlows: false);
        expect(handler.snapshot.isLoading, isTrue);
        expect(handler.snapshot.queueSongIds, ids);
        expect(handler.snapshot.pendingQueueIndex, 1);
        await loaded.future;
        await handler.pause();
        releaseLoad.complete();
        await filling.future;
        final state = (await database.playQueueDao.getQueueState())!;
        expect(state.currentIndex, 1);
        expect(
          (await database.playQueueDao.getQueueItems()).map((s) => s.id),
          ids,
        );
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(handler.snapshot.hasPendingLogicalQueue, isTrue);
        expect(player.playing, isFalse);
        releaseFill.complete();
        await replacement;
        expect(handler.snapshot.queueSongIds, ids);
        expect(handler.snapshot.currentIndex, 1);
        expect(handler.snapshot.isLoading, isFalse);
        expect(player.playing, isFalse);

        if (suppliedRows) {
          await handler.replaceQueueWithData([]);
        } else {
          await handler.replaceQueue([]);
        }
        expect(handler.snapshot.queueSongIds, isEmpty);
        expect(handler.snapshot.isLoading, isFalse);
        expect(await database.playQueueDao.getQueueItems(), isEmpty);
      });

      test('timeout recovery keeps the admitted shuffle order and pause '
          '(rows=$suppliedRows)', () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-recover-',
        );
        final rebuilt = <ControllableAudioPlayer>[];
        final (handler, player, database) = await createHandler(
          directory,
          5,
          rebuiltPlayers: rebuilt,
          timeouts: const NavisPlaybackTimeouts(
            load: Duration(milliseconds: 300),
            remoteLoad: Duration(milliseconds: 300),
            reset: Duration(milliseconds: 100),
            control: Duration(milliseconds: 100),
          ),
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final ids = List.generate(5, (i) => 'song-$i');
        final rows = [
          for (final row in await database.libraryDao.getSongsByIds(ids))
            row.copyWith(title: 'Supplied ${row.id}', isExternal: true),
        ];
        await handler.applySongIdentityAliases({'song-3': 'song-4'});
        final inputIds = suppliedRows
            ? ids
            : ['song-0', 'song-1', 'song-2', 'song-4', 'song-4'];
        // Entity Shuffle supplies the shuffled play order and its original.
        final expected = shuffledFromStart(inputIds, 2, Random(7));
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..loadGate = gate
          ..loadEntered = entered;
        final replacement = suppliedRows
            ? handler.replaceQueueWithData([
                for (final id in expected) rows.firstWhere((r) => r.id == id),
              ], originalOrder: inputIds)
            : handler.replaceQueue(
                expected,
                originalOrder: inputIds,
                expandMatchFlows: false,
              );
        await entered.future;
        await handler.pause();
        await replacement;
        if (handler.snapshot.isLoading || handler.snapshot.currentIndex != 1) {
          await handler.snapshotStream.firstWhere(
            (snapshot) => !snapshot.isLoading && snapshot.currentIndex == 1,
          );
        }
        expect(handler.snapshot.queueSongIds, expected);
        expect(handler.snapshot.currentSongId, expected[1]);
        expect(handler.snapshot.playing, isFalse);
        expect(rebuilt.last.sourceIds, expected);
        if (suppliedRows) {
          expect(handler.queue.value.map((item) => item.title), [
            for (final id in expected) 'Supplied $id',
          ]);
        }
        gate.complete();
        await handler.setShuffleMode(AudioServiceShuffleMode.none);
        expect(handler.snapshot.queueSongIds, inputIds);
        expect(handler.snapshot.currentSongId, expected[1]);
      });
    }

    for (final duplicate in [false, true]) {
      test('timeout advances beyond the resolved missing selection '
          '(duplicate=$duplicate)', () async {
        final directory = await Directory.systemTemp.createTemp('navis-next-');
        final rebuilt = <ControllableAudioPlayer>[];
        final (handler, player, database) = await createHandler(
          directory,
          3,
          rebuiltPlayers: rebuilt,
          timeouts: const NavisPlaybackTimeouts(
            load: Duration(milliseconds: 100),
            reset: Duration(milliseconds: 100),
            control: Duration(milliseconds: 100),
          ),
        );
        final entered = Completer<void>();
        final releaseLoad = Completer<void>();
        addTearDown(() async {
          if (!releaseLoad.isCompleted) releaseLoad.complete();
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final requested = [
          'song-0',
          if (duplicate) 'song-1',
          'missing',
          'song-1',
          'song-2',
        ];
        final expected = requested.where((id) => id != 'missing').toList();
        player
          ..loadEntered = entered
          ..loadGate = releaseLoad;
        final replacement = handler.replaceQueue(
          requested,
          startIndex: duplicate ? 2 : 1,
          expandMatchFlows: false,
        );
        await entered.future;
        expect(player.attemptedSongId, 'song-1');
        await handler.pause();
        final recovered = handler.snapshotStream.firstWhere(
          (snapshot) => !snapshot.isLoading,
        );
        await replacement;
        await recovered;
        if (handler.snapshot.isLoading) {
          await handler.snapshotStream.firstWhere(
            (snapshot) => !snapshot.isLoading,
          );
        }
        await handler.debugFlushQueuePersistence();

        expect(handler.snapshot.currentSongId, 'song-2');
        expect(handler.snapshot.currentIndex, expected.length - 1);
        expect(handler.snapshot.queueSongIds, expected);
        expect(handler.snapshot.playing, isFalse);
        expect(rebuilt.single.sourceIds, expected);
        expect(
          (await database.playQueueDao.getQueueItems()).map((song) => song.id),
          expected,
        );
        expect(
          (await database.playQueueDao.getQueueState())!.currentIndex,
          expected.length - 1,
        );
      });
    }

    for (final input in [
      'ids',
      'expanded rows',
      'canonical rows',
      'exact rows',
    ]) {
      test('local row resolution preserves its read policy ($input)', () async {
        final directory = await Directory.systemTemp.createTemp('navis-rows-');
        final (handler, _, database) = await createHandler(
          directory,
          3,
          matchFlow: true,
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final flow = await database.matchFlowDao.createFlow();
        await database.matchFlowDao.addSong(flow, 'song-0');
        await database.matchFlowDao.addSong(flow, 'song-1');
        final rows = await database.libraryDao.getSongsByIds([
          'song-0',
          'song-2',
        ]);
        final supplied = [
          for (final row in rows) row.copyWith(title: 'Supplied'),
        ];
        if (input == 'ids') {
          await handler.applySongIdentityAliases({'retired-0': 'song-0'});
          await handler.replaceQueue(['retired-0', 'song-2'], startIndex: 1);
        } else {
          if (input == 'canonical rows') {
            await handler.applySongIdentityAliases({'retired-0': 'song-0'});
            supplied[0] = supplied[0].copyWith(id: 'retired-0');
          }
          await handler.replaceQueueWithData(
            supplied,
            startIndex: 1,
            expandMatchFlows: input == 'expanded rows',
          );
        }
        final expands = input == 'ids' || input == 'expanded rows';
        expect(
          handler.snapshot.queueSongIds,
          expands ? ['song-0', 'song-1', 'song-2'] : ['song-0', 'song-2'],
        );
        expect(handler.snapshot.currentIndex, expands ? 2 : 1);
        expect(handler.snapshot.currentSongId, 'song-2');
        expect(
          handler.currentMediaItem!.title,
          input == 'exact rows' ? 'Supplied' : 'Song 2',
        );
      });
    }

    test(
      'mixed rows bypass expansion and retain remote and retired local rows',
      () async {
        final directory = await Directory.systemTemp.createTemp('navis-mixed-');
        final (handler, _, database) = await createHandler(
          directory,
          3,
          matchFlow: true,
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final flow = await database.matchFlowDao.createFlow();
        await database.matchFlowDao.addSong(flow, 'song-0');
        await database.matchFlowDao.addSong(flow, 'song-2');
        final rows = await database.libraryDao.getSongsByIds([
          'song-0',
          'song-1',
        ]);
        await handler.applySongIdentityAliases({
          'song-0': 'song-2',
          'song-1': 'song-2',
        });
        await handler.replaceQueueWithData([
          rows[0].copyWith(isExternal: true, title: 'Remote exact'),
          rows[1].copyWith(title: 'Local exact'),
        ]);
        expect(handler.snapshot.queueSongIds, ['song-0', 'song-1']);
        expect(handler.queue.value.map((item) => item.title), [
          'Remote exact',
          'Local exact',
        ]);
        expect(handler.snapshot.currentSongId, 'song-0');
      },
    );
  });

  test('duplicate song IDs retain the selected queue occurrence', () async {
    final directory = await Directory.systemTemp.createTemp('navis-nav-test-');
    final (handler, player, database) = await createHandler(directory, 2);
    addTearDown(() async {
      await handler.disposeHandler();
      await database.close();
      await directory.delete(recursive: true);
    });
    final songs = await database.libraryDao.getSongsByIds(<String>[
      'song-0',
      'song-1',
    ]);
    await handler.replaceQueueWithData(<SongsTableData>[
      songs[0],
      songs[1],
      songs[0],
    ], startIndex: 2);

    expect(handler.snapshot.queueSongIds, <String>[
      'song-0',
      'song-1',
      'song-0',
    ]);
    expect(handler.snapshot.currentIndex, 2);
    expect(player.currentIndex, 2);

    await handler.skipToPrevious();
    await handler.snapshotStream
        .firstWhere(
          (snapshot) =>
              snapshot.currentIndex == 1 && snapshot.pendingQueueIndex == null,
        )
        .timeout(const Duration(seconds: 5));
    expect(player.currentIndex, 1);
  });

  test(
    'an edit made after a navigation never overtakes one made before it',
    () async {
      final directory = await Directory.systemTemp.createTemp('navis-fifo-');
      final (handler, player, database) = await createHandler(directory, 10);
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final ids = List<String>.generate(10, (i) => 'song-$i');
      // Hold the replacement in its native load.
      final gate = Completer<void>();
      final entered = Completer<void>();
      player
        ..loadGate = gate
        ..loadEntered = entered;
      final replacing = handler.replaceQueue(ids, expandMatchFlows: false);
      await entered.future;

      // A waits for the load a later navigation completes; B arrives after
      // that navigation.
      final first = handler.addToQueue(<String>[
        'song-1',
      ], expandMatchFlows: false);
      final navigation = handler.playFromIndex(2);
      final second = handler.addToQueue(<String>[
        'song-2',
      ], expandMatchFlows: false);
      gate.complete();
      await Future.wait(<Future<void>>[replacing, first, navigation, second])
          .timeout(const Duration(seconds: 5));

      expect(handler.snapshot.queueSongIds, <String>[
        ...ids,
        'song-1',
        'song-2',
      ]);
    },
  );

  test('an edit a replacement discards reports it was cancelled', () async {
    final directory = await Directory.systemTemp.createTemp('navis-cancel-');
    final (handler, player, database) = await createHandler(directory, 10);
    addTearDown(() async {
      await handler.disposeHandler();
      await database.close();
      await directory.delete(recursive: true);
    });
    final ids = List<String>.generate(10, (i) => 'song-$i');
    final gate = Completer<void>();
    final entered = Completer<void>();
    player
      ..loadGate = gate
      ..loadEntered = entered;
    final replacing = handler.replaceQueue(ids, expandMatchFlows: false);
    await entered.future;

    final edit = handler.addToQueue(<String>[
      'song-1',
    ], expandMatchFlows: false);
    final replacement = handler.replaceQueue(
      ids.reversed.toList(),
      expandMatchFlows: false,
    );
    gate.complete();

    await expectLater(edit, throwsA(isA<OperationCancelledException>()));
    await Future.wait(<Future<void>>[replacing, replacement]);
    expect(handler.snapshot.queueSongIds, ids.reversed.toList());
  });

  group('a queue edit whose native call never returns', () {
    const timeouts = NavisPlaybackTimeouts(
      load: Duration(milliseconds: 150),
      reset: Duration(milliseconds: 150),
    );
    List<String> ids(int count) =>
        List<String>.generate(count, (i) => 'song-$i');

    Future<
      (
        NavisAudioHandler,
        ControllableAudioPlayer,
        List<ControllableAudioPlayer>,
      )
    >
    playingAt(int index) async {
      final directory = await Directory.systemTemp.createTemp('navis-hang-');
      final rebuilt = <ControllableAudioPlayer>[];
      final (handler, player, database) = await createHandler(
        directory,
        10,
        timeouts: timeouts,
        rebuiltPlayers: rebuilt,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      await handler.replaceQueue(ids(10), expandMatchFlows: false);
      expect(player.sourceIds, ids(10));
      player
        ..moveTo(index)
        ..isPlaying = true;
      return (handler, player, rebuilt);
    }

    test('an insert that times out reloads the queue it left', () async {
      final (handler, player, rebuilt) = await playingAt(3);
      player.hang.add('insertAudioSources');

      await expectLater(
        handler.playNext(<String>['song-0'], expandMatchFlows: false),
        throwsA(isA<PlaybackLoadTimeoutException>()),
      );

      final active = rebuilt.first;
      expect(active.sourceIds, ids(10));
      expect(active.index, 3);
      expect(active.isPlaying, isTrue);
      expect(handler.snapshot.queueSongIds, ids(10));
      expect(handler.snapshot.currentSongId, 'song-3');

      // The next edit lands on the reloaded player.
      await handler.addToQueue(<String>['song-1'], expandMatchFlows: false);
      expect(active.sourceIds, <String>[...ids(10), 'song-1']);
    });

    test('an inactive deck insert that never returns frees the lane', () async {
      final directory = await Directory.systemTemp.createTemp('navis-deck-');
      final (handler, _, database) = await createHandler(
        directory,
        4,
        crossfade: true,
        timeouts: timeouts,
        rebuiltPlayers: <ControllableAudioPlayer>[],
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      await handler.replaceQueue(ids(3), expandMatchFlows: false);
      // A prepared deck mirrors the queue edits.
      await handler.debugStartCrossfade();
      final deck = handler.debugInactiveDeck! as ControllableAudioPlayer;
      expect(deck.sequence, hasLength(3));
      deck.hang.add('insertAudioSources');

      await handler
          .playNext(<String>['song-3'], expandMatchFlows: false)
          .timeout(const Duration(seconds: 3));
      await handler
          .playNext(<String>['song-3'], expandMatchFlows: false)
          .timeout(const Duration(seconds: 3));

      expect(
        handler.snapshot.queueSongIds.where((id) => id == 'song-3'),
        hasLength(2),
      );
    });

    test(
      'a removal before the current song that times out keeps the song',
      () async {
        final (handler, player, rebuilt) = await playingAt(3);
        player.hang.add('removeAudioSourceAt');

        await expectLater(
          handler.removeAt(1),
          throwsA(isA<PlaybackLoadTimeoutException>()),
        );

        final expected = ids(10)..removeAt(1);
        expect(rebuilt.first.sourceIds, expected);
        expect(rebuilt.first.index, 2);
        expect(handler.snapshot.currentSongId, 'song-3');
        expect(handler.snapshot.queueSongIds, expected);
      },
    );

    test('a removal that times out still removes the song', () async {
      final (handler, player, rebuilt) = await playingAt(3);
      player.hang.add('removeAudioSourceAt');

      await expectLater(
        handler.removeAt(6),
        throwsA(isA<PlaybackLoadTimeoutException>()),
      );

      final expected = ids(10)..removeAt(6);
      expect(rebuilt.first.sourceIds, expected);
      expect(rebuilt.first.index, 3);
      expect(handler.snapshot.queueSongIds, expected);
    });
  });

  test(
    'a seek served from a completed sidecar file keeps the whole queue',
    () async {
      final directory = await Directory.systemTemp.createTemp('navis-sidecar-');
      final (handler, player, database) = await createHandler(
        directory,
        5,
        sidecarStreams: true,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final ids = List<String>.generate(5, (i) => 'song-$i');
      await handler.replaceQueue(ids, startIndex: 1, expandMatchFlows: false);
      expect(player.sourceIds, ids);
      final sidecar =
          handler.queue.value[1].extras!['sidecarCacheFilePath'] as String;
      // Simulate a no-op native seek, then use the completed local source.
      player
        ..ignoreSeeks = true
        ..simulateProgress = true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await File(sidecar).writeAsBytes(List<int>.filled(64, 1));
      bool served() =>
          handler.queue.value.length == 5 &&
          handler.queue.value[1].extras!['sourceKind'] == 'file' &&
          player.sourceIds.length == 5 &&
          !handler.snapshot.isLoading;

      await handler.seek(const Duration(seconds: 30));
      for (var i = 0; i < 300 && !served(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(player.sourceIds, ids);
      expect(player.index, 1);
      expect(handler.snapshot.queueSongIds, ids);
      expect(handler.queue.value[1].extras!['sourceKind'], 'file');
    },
  );

  group('released queue window', () {
    const window = NavisQueueWindow(
      deferThreshold: 16,
      ahead: 8,
      lowWater: 3,
      page: 8,
      nearJump: 16,
    );
    List<String> ids(int count, [int from = 0]) =>
        List<String>.generate(count - from, (i) => 'song-${i + from}');

    Future<(NavisAudioHandler, ControllableAudioPlayer, NavisDatabase)>
    windowed(int count) async {
      final directory = await Directory.systemTemp.createTemp('navis-window-');
      final created = await createHandler(
        directory,
        count,
        queueWindow: window,
      );
      addTearDown(() async {
        await created.$1.disposeHandler();
        await created.$3.close();
        await directory.delete(recursive: true);
      });
      return created;
    }

    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 200 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(condition(), isTrue);
    }

    test(
      'OS Next is unavailable at the logical end after releasing history',
      () async {
        final (handler, player, _) = await windowed(60);
        await handler.replaceQueue(ids(60), expandMatchFlows: false);
        await handler.playFromIndex(59);
        await until(
          () =>
              !handler.snapshot.isLoading &&
              handler.snapshot.currentIndex == 59,
        );
        expect(
          handler.collectPlaybackDiagnostics()['deferredHeadLength'],
          greaterThan(0),
        );
        expect(handler.collectPlaybackDiagnostics()['deferredLength'], 0);
        expect(player.index, lessThan(59));
        expect(handler.playbackState.value.queueIndex, player.index);
        expect(
          handler.playbackState.value.controls.map((control) => control.action),
          isNot(contains(MediaAction.skipToNext)),
        );
        expect(
          handler.playbackState.value.systemActions,
          isNot(contains(MediaAction.skipToNext)),
        );
        expect(
          handler.playbackState.value.systemActions,
          contains(MediaAction.skipToPrevious),
        );
      },
    );

    test(
      'system projection composes its window offset with the deferred head',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-system-',
        );
        final (handler, player, database) = await createHandler(
          directory,
          300,
          queueWindow: const NavisQueueWindow(
            deferThreshold: 16,
            ahead: 40,
            behind: 100,
          ),
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        await handler.replaceQueue(
          ids(300),
          startIndex: 180,
          expandMatchFlows: false,
        );
        final system = RealTimeProjectionAudioHandler(handler);
        await until(() => system.queue.valueOrNull?.first.id == 'song-160');
        expect(handler.queue.value.first.id, 'song-80');
        expect(system.queue.value.first.id, 'song-160');

        await system.removeQueueItem(system.queue.value[1]);
        expect(handler.snapshot.queueSongIds, ids(300)..remove('song-161'));
        expect(player.sourceIds, isNot(contains('song-161')));
        await system.skipToQueueItem(0);
        await until(
          () =>
              handler.snapshot.currentIndex == 160 &&
              !handler.snapshot.isLoading,
        );

        expect(handler.snapshot.currentIndex, 160);
        expect(player.sourceIds[player.index!], 'song-160');
      },
    );

    test('system insert starts an empty queue', () async {
      final (handler, player, _) = await windowed(2);

      await handler.insertQueueItem(
        0,
        const MediaItem(id: 'song-1', title: 'Song 1'),
      );

      expect(handler.snapshot.queueSongIds, ['song-1']);
      expect(player.sourceIds, ['song-1']);
    });

    test('a long queue hands only a window to the player', () async {
      final (handler, player, database) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      expect(handler.snapshot.queueSongIds, ids(60));
      expect(player.sourceIds, ids(9));
      expect(handler.collectPlaybackDiagnostics()['deferredLength'], 51);
      await handler.debugFlushQueuePersistence();
      expect(
        (await database.playQueueDao.getQueueItems()).map((song) => song.id),
        ids(60),
      );
    });

    test('nearing the window end releases a page with one append', () async {
      final (handler, player, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      final batches = player.batchMutationCount;
      player.moveTo(6);
      await until(() => player.sourceIds.length == 17);
      expect(player.batchMutationCount, batches + 1);
      expect(player.sourceIds, ids(17));
      expect(handler.snapshot.queueSongIds, ids(60));
    });

    test(
      'songs that cannot play yet stay deferred instead of dropping',
      () async {
        final (handler, player, database) = await windowed(60);
        await handler.replaceQueue(ids(60), expandMatchFlows: false);
        // Without a cached copy or a session the tail cannot resolve for now.
        for (final id in ids(60, 9)) {
          await database.cacheDao.removeCachedTrack(id);
        }
        player.moveTo(6);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(player.sourceIds, ids(9));
        expect(handler.snapshot.queueSongIds, ids(60));
        expect(handler.collectPlaybackDiagnostics()['deferredLength'], 51);
        await handler.debugFlushQueuePersistence();
        expect(
          (await database.playQueueDao.getQueueItems()).map((song) => song.id),
          ids(60),
        );
      },
    );

    test(
      'a deferred song that can no longer be prepared is reported',
      () async {
        final (handler, player, database) = await windowed(60);
        final dropped = <QueueSongsDropped>[];
        final subscription = handler.droppedSongsStream.listen(dropped.add);
        addTearDown(subscription.cancel);
        await handler.replaceQueue(ids(60), expandMatchFlows: false);
        // Gone from the library while it waited in the tail.
        await database.customStatement(
          "DELETE FROM songs WHERE id = 'song-10'",
        );

        player.moveTo(6);
        await until(() => player.sourceIds.length == 16);

        expect(player.sourceIds, isNot(contains('song-10')));
        expect(dropped.single.songIds, <String>['song-10']);
        expect(dropped.single.reason, QueueDropReason.release);
      },
    );

    test('a near jump into the tail releases through it and seeks', () async {
      final (handler, player, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      // Navigation is admitted immediately and applied in the queue lane.
      await handler.playFromIndex(12);
      await until(() => handler.snapshot.currentSongId == 'song-12');
      expect(player.index, 12);
      expect(handler.snapshot.currentIndex, 12);
      expect(handler.snapshot.currentSongId, 'song-12');
      expect(player.sourceIds, ids(21));
      expect(handler.snapshot.queueSongIds, ids(60));
    });

    test('a far jump rebuilds the player around the target', () async {
      final (handler, player, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      await handler.playFromIndex(50);
      await until(
        () =>
            handler.snapshot.currentSongId == 'song-50' &&
            !handler.snapshot.isLoading,
      );
      expect(handler.snapshot.currentIndex, 50);
      expect(handler.snapshot.currentSongId, 'song-50');
      expect(handler.snapshot.queueSongIds, ids(60));
      // Only a window around the target: 32 before it, 8 after.
      expect(player.sourceIds, ids(59, 18));
      expect(handler.collectPlaybackDiagnostics()['deferredHeadLength'], 18);
      expect(player.index, 32);
    });

    test('jumping back into released songs brings them back', () async {
      final (handler, player, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      await handler.playFromIndex(50);
      await until(
        () =>
            handler.snapshot.currentSongId == 'song-50' &&
            !handler.snapshot.isLoading,
      );

      // Near: the head releases back into the player.
      await handler.playFromIndex(5);
      await until(
        () =>
            handler.snapshot.currentSongId == 'song-5' &&
            !handler.snapshot.isLoading,
      );
      expect(handler.snapshot.currentIndex, 5);
      expect(handler.snapshot.queueSongIds, ids(60));
      // The target, the songs after it and a page before it (here the rest
      // of the 18 released songs).
      expect(player.sourceIds, ids(59));
      expect(player.sourceIds[player.index!], 'song-5');
    });

    group('played songs', () {
      const small = NavisQueueWindow(
        deferThreshold: 16,
        ahead: 4,
        lowWater: 2,
        page: 4,
        nearJump: 8,
        behind: 4,
        trimSlack: 2,
      );

      Future<(NavisAudioHandler, ControllableAudioPlayer, NavisDatabase)>
      trimmed() async {
        final directory = await Directory.systemTemp.createTemp('navis-trim-');
        final created = await createHandler(directory, 60, queueWindow: small);
        final (handler, player, database) = created;
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        await handler.replaceQueue(ids(60), expandMatchFlows: false);
        // Play through ten songs.
        for (var i = 0; i < 10; i++) {
          player.moveTo(player.index! + 1);
          await until(() => handler.snapshot.currentSongId == 'song-${i + 1}');
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        return created;
      }

      int head(NavisAudioHandler handler) =>
          handler.collectPlaybackDiagnostics()['deferredHeadLength'] as int;

      for (final projected in [false, true]) {
        test(
          'system skip selects the published occurrence with a deferred head '
          '(projected=$projected)',
          () async {
            final (handler, player, _) = await trimmed();
            final system = projected
                ? RealTimeProjectionAudioHandler(handler)
                : handler;
            await until(() => system.queue.valueOrNull?.isNotEmpty ?? false);
            final selected = system.queue.value.first.id;
            expect(selected, 'song-6');

            await system.skipToQueueItem(0);
            await until(
              () =>
                  handler.snapshot.currentSongId == selected &&
                  !handler.snapshot.isLoading,
            );

            expect(handler.snapshot.currentSongId, selected);
            expect(handler.snapshot.currentIndex, 6);
            expect(player.sourceIds[player.index!], selected);
          },
        );

        test(
          'system remove edits the published occurrence with a deferred head '
          '(projected=$projected)',
          () async {
            final (handler, player, _) = await trimmed();
            final system = projected
                ? RealTimeProjectionAudioHandler(handler)
                : handler;
            await until(() => system.queue.valueOrNull?.isNotEmpty ?? false);
            final removed = system.queue.value.first;
            expect(removed.id, 'song-6');

            await system.removeQueueItem(removed);

            expect(handler.snapshot.queueSongIds, ids(60)..remove('song-6'));
            expect(handler.snapshot.currentSongId, 'song-10');
            expect(player.sourceIds, isNot(contains('song-6')));
          },
        );
      }

      for (final projected in [false, true]) {
        test('system remove-at edits the native occurrence '
            '(projected=$projected)', () async {
          final (handler, player, _) = await trimmed();
          final system = projected
              ? RealTimeProjectionAudioHandler(handler)
              : handler;
          await until(() => system.queue.valueOrNull?.isNotEmpty ?? false);

          await system.removeQueueItemAt(0);

          expect(handler.snapshot.queueSongIds, ids(60)..remove('song-6'));
          expect(handler.snapshot.currentSongId, 'song-10');
          expect(player.sourceIds, isNot(contains('song-6')));
        });

        test('system insert edits the native position '
            '(projected=$projected)', () async {
          final (handler, player, _) = await trimmed();
          final system = projected
              ? RealTimeProjectionAudioHandler(handler)
              : handler;
          await until(() => system.queue.valueOrNull?.isNotEmpty ?? false);

          await system.insertQueueItem(
            1,
            const MediaItem(id: 'song-0', title: 'Song 0'),
          );

          expect(handler.snapshot.queueSongIds, ids(60)..insert(7, 'song-0'));
          expect(handler.snapshot.currentSongId, 'song-10');
          expect(player.sourceIds.take(3), ['song-6', 'song-0', 'song-7']);
        });
      }

      test('retaining a singleton seed clears deferred played songs', () async {
        final (handler, player, database) = await trimmed();
        for (var index = 59; index >= 6; index--) {
          if (index != 10) await handler.removeAt(index);
        }
        expect(head(handler), 6);
        expect(handler.queue.value.map((item) => item.id), ['song-10']);
        expect(handler.collectPlaybackDiagnostics()['deferredLength'], 0);
        expect(player.index, 0);
        player.simulatedPosition = const Duration(seconds: 15);
        final seeks = player.seekCalls;

        await handler.retainCurrentSongAsQueue('song-10');

        expect(handler.snapshot.queueSongIds, ['song-10']);
        expect(head(handler), 0);
        expect(handler.snapshot.currentIndex, 0);
        expect(player.sourceIds, ['song-10']);
        expect(player.simulatedPosition, const Duration(seconds: 15));
        expect(player.seekCalls, seeks);
        expect(player.isPlaying, isTrue);
        expect(
          (await database.playQueueDao.getQueueItems()).map((song) => song.id),
          ['song-10'],
        );
      });

      for (final allUnavailable in [true, false]) {
        test('offline backward jump retains temporarily unavailable history '
            '(allUnavailable=$allUnavailable)', () async {
          final (handler, player, database) = await trimmed();
          final dropped = <QueueSongsDropped>[];
          final subscription = handler.droppedSongsStream.listen(dropped.add);
          addTearDown(subscription.cancel);
          await database.cacheDao.deleteCachedTracksBySongIds(
            allUnavailable ? ids(6) : ['song-2'],
          );

          await handler.playFromIndex(4);
          await until(() => !handler.snapshot.isLoading);

          expect(handler.snapshot.queueSongIds, ids(60));
          expect(dropped, isEmpty);
          expect(head(handler), allUnavailable ? 6 : 3);
          expect(
            handler.snapshot.currentSongId,
            allUnavailable ? 'song-10' : 'song-4',
          );
          expect(
            player.sourceIds[player.index!],
            allUnavailable ? 'song-10' : 'song-4',
          );
          await handler.debugFlushQueuePersistence();
          expect(
            (await database.playQueueDao.getQueueItems()).map(
              (song) => song.id,
            ),
            ids(60),
          );
        });
      }

      test('beyond the window leave the player in batches', () async {
        final (handler, player, database) = await trimmed();
        expect(head(handler), 6);
        expect(player.sourceIds.first, 'song-6');
        expect(player.index, 4);
        expect(handler.snapshot.currentIndex, 10);
        expect(handler.snapshot.queueSongIds, ids(60));
        await handler.debugFlushQueuePersistence();
        expect(
          (await database.playQueueDao.getQueueItems()).map((s) => s.id),
          ids(60),
        );
        expect((await database.playQueueDao.getQueueState())!.currentIndex, 10);
      });

      test(
        'come back with Previous past the first song the player holds',
        () async {
          final (handler, player, _) = await trimmed();
          for (var target = 9; target >= 4; target--) {
            await handler.skipToPrevious();
            await until(
              () =>
                  handler.snapshot.currentSongId == 'song-$target' &&
                  !handler.snapshot.isLoading,
            );
          }
          expect(handler.snapshot.currentIndex, 4);
          expect(player.sourceIds[player.index!], 'song-4');
          expect(handler.snapshot.queueSongIds, ids(60));
          // One release of the target and a page before it.
          expect(head(handler), 1);
        },
      );
    });

    test('a far jump whose song cannot load keeps the old queue', () async {
      final (handler, player, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      player
        ..moveTo(3)
        ..isPlaying = true;
      await until(() => handler.snapshot.currentSongId == 'song-3');
      player.failLoadSongId = 'song-50';

      await handler.playFromIndex(50);
      await until(
        () =>
            handler.snapshot.lastFailedSongId == 'song-50' &&
            !handler.snapshot.isLoading,
      );

      expect(handler.snapshot.currentSongId, 'song-3');
      expect(handler.snapshot.currentIndex, 3);
      expect(handler.snapshot.queueSongIds, ids(60));
      expect(player.sourceIds.first, 'song-0');
      expect(player.sourceIds[player.index!], 'song-3');
    });

    test('a far jump back rebuilds around the first song', () async {
      final (handler, player, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      await handler.playFromIndex(50);
      await until(
        () =>
            handler.snapshot.currentSongId == 'song-50' &&
            !handler.snapshot.isLoading,
      );

      await handler.playFromIndex(0);
      await until(
        () =>
            handler.snapshot.currentSongId == 'song-0' &&
            !handler.snapshot.isLoading,
      );
      expect(handler.snapshot.currentIndex, 0);
      expect(handler.snapshot.queueSongIds, ids(60));
      expect(player.sourceIds, ids(9));
      expect(handler.collectPlaybackDiagnostics()['deferredHeadLength'], 0);
    });

    group('a remote row matched to a local song', () {
      // The caller's remote row shares a local id; re-reading it by id would
      // silently swap in the local row.
      Future<List<SongsTableData>> queueWithRemote(
        NavisDatabase database,
      ) async {
        final rows = await database.libraryDao.getSongsByIds(ids(60));
        return <SongsTableData>[
          for (final row in rows)
            row.id == 'song-3'
                ? row.copyWith(title: 'Remote 3', isExternal: true)
                : row,
        ];
      }

      String titleOf(NavisAudioHandler handler, String id) =>
          handler.queue.value.firstWhere((item) => item.id == id).title;

      test('keeps its row through a far jump rebuild', () async {
        final (handler, _, database) = await windowed(60);
        await handler.replaceQueueWithData(
          await queueWithRemote(database),
          startIndex: 0,
          autoPlay: false,
          expandMatchFlows: false,
        );
        expect(titleOf(handler, 'song-3'), 'Remote 3');
        await handler.playFromIndex(50);
        await until(
          () =>
              handler.snapshot.currentSongId == 'song-50' &&
              !handler.snapshot.isLoading,
        );
        // Now among the released songs; bring it back.
        await handler.playFromIndex(3);
        await until(
          () =>
              handler.snapshot.currentSongId == 'song-3' &&
              !handler.snapshot.isLoading,
        );
        expect(titleOf(handler, 'song-3'), 'Remote 3');
      });

      test('keeps its row when moved behind the window and back', () async {
        final (handler, player, database) = await windowed(60);
        await handler.replaceQueueWithData(
          await queueWithRemote(database),
          startIndex: 0,
          autoPlay: false,
          expandMatchFlows: false,
        );
        await handler.reorderQueue(3, 40);
        expect(player.sourceIds, isNot(contains('song-3')));
        await handler.reorderQueue(
          handler.snapshot.queueSongIds.indexOf('song-3'),
          3,
        );
        await until(() => player.sourceIds.contains('song-3'));
        expect(titleOf(handler, 'song-3'), 'Remote 3');
      });
    });

    test('edits inside the deferred tail touch no native state', () async {
      final (handler, player, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      final sources = player.sourceIds;
      final mutations = player.batchMutationCount;
      await handler.removeAt(40);
      await handler.reorderQueue(50, 30);
      await handler.addToQueue(['song-0'], expandMatchFlows: false);
      final expected = ids(60)..removeAt(40);
      expected.insert(30, expected.removeAt(50));
      expected.add('song-0');
      expect(handler.snapshot.queueSongIds, expected);
      expect(player.sourceIds, sources);
      expect(player.batchMutationCount, mutations);
    });

    test('moving a deferred song into the window inserts it once', () async {
      final (handler, player, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      await handler.reorderQueue(40, 3);
      expect(handler.snapshot.queueSongIds[3], 'song-40');
      expect(player.sourceIds[3], 'song-40');
      expect(player.sourceIds, hasLength(10));
      expect(handler.snapshot.queueSongIds, hasLength(60));
    });

    group('Navis-owned shuffle', () {
      for (final (count, current) in [(12, 5), (60, 5), (100, 50)]) {
        test('turning shuffle on shuffles the whole queue without restarting '
            '($count songs at $current)', () async {
          final (handler, player, _) = await windowed(count);
          await handler.replaceQueue(
            ids(count),
            startIndex: current,
            expandMatchFlows: false,
          );
          await handler.play();
          player.simulatedPosition = const Duration(seconds: 42);
          final item = handler.mediaItem.value;
          final loads = player.sourceLoads;
          final seeks = player.seekCalls;
          final stops = player.stopCalls;
          final starts = player.playedFrom.length;
          final check = watchAudioMetadata(handler, [player]);
          if (current > window.behind) {
            expect(
              handler.collectPlaybackDiagnostics()['deferredHeadLength'],
              isPositive,
            );
          }

          await handler.setShuffleMode(AudioServiceShuffleMode.all);

          final queue = handler.snapshot.queueSongIds;
          expect(queue, shuffledFromStart(ids(count), current, Random(7)));
          expect(queue.first, 'song-$current');
          expect(queue, hasLength(count));
          expect(queue.toSet(), ids(count).toSet());
          expect(handler.snapshot.currentIndex, 0);
          expect(handler.snapshot.shuffleMode, AudioServiceShuffleMode.all);
          expect(handler.mediaItem.value, same(item));
          expect(player.index, 0);
          expect(player.position, const Duration(seconds: 42));
          expect(player.playing, isTrue);
          expect(player.sourceLoads, loads);
          expect(player.seekCalls, seeks);
          expect(player.stopCalls, stops);
          expect(player.playedFrom, hasLength(starts));
          expect(handler.playbackState.value.queueIndex, 0);
          expect(handler.queue.value.first, same(item));
          if (count > window.deferThreshold) {
            expect(
              handler.collectPlaybackDiagnostics()['deferredLength'],
              isPositive,
            );
            expect(player.sourceIds.length, lessThan(count));
          }
          expect(handler.collectPlaybackDiagnostics()['deferredHeadLength'], 0);
          await check();

          await handler.setShuffleMode(AudioServiceShuffleMode.none);

          expect(handler.snapshot.queueSongIds, ids(count));
          expect(handler.snapshot.currentIndex, current);
          expect(handler.snapshot.currentSongId, 'song-$current');
          expect(handler.mediaItem.value, same(item));
          expect(player.position, const Duration(seconds: 42));
          expect(player.playing, isTrue);
          expect(player.sourceLoads, loads);
          expect(player.seekCalls, seeks);
          expect(player.stopCalls, stops);
          expect(player.playedFrom, hasLength(starts));
          expectNativeMirrorsQueue(handler, player);
        });
      }

      for (final repeat in [
        AudioServiceRepeatMode.none,
        AudioServiceRepeatMode.all,
        AudioServiceRepeatMode.one,
      ]) {
        test('previous after shuffle behaves like the start of a queue '
            '($repeat)', () async {
          final (handler, player, _) = await windowed(60);
          await handler.replaceQueue(
            ids(60),
            startIndex: 5,
            expandMatchFlows: false,
          );
          await handler.setRepeatMode(repeat);
          player.simulatedPosition = const Duration(seconds: 42);
          await handler.setShuffleMode(AudioServiceShuffleMode.all);
          expect(handler.snapshot.currentIndex, 0);
          final order = List<String>.of(handler.snapshot.queueSongIds);
          expect(
            player.appliedLoopMode,
            repeat == AudioServiceRepeatMode.one ? LoopMode.one : LoopMode.off,
          );

          await handler.skipToPrevious();
          await settleQueue(handler);
          expect(handler.snapshot.currentIndex, 0);
          expect(handler.snapshot.currentSongId, 'song-5');
          expect(player.position, Duration.zero);

          await handler.skipToPrevious();
          await settleQueue(handler);
          final expected = repeat == AudioServiceRepeatMode.all ? 59 : 0;
          expect(handler.snapshot.currentIndex, expected);
          expect(handler.snapshot.currentSongId, order[expected]);
          expect(handler.snapshot.queueSongIds, order);
          expectNativeMirrorsQueue(handler, player);
        });
      }

      test('turning shuffle off restores the order, with songs added while '
          'shuffled', () async {
        final (handler, player, _) = await windowed(60);
        await handler.replaceQueue(ids(60), expandMatchFlows: false);
        player.moveTo(5);
        await handler.setShuffleMode(AudioServiceShuffleMode.all);
        await handler.playNext(<String>['song-0'], expandMatchFlows: false);
        await handler.addToQueue(<String>['song-1'], expandMatchFlows: false);
        // Later in the shuffled play order.
        player.moveTo(7);
        final playing = handler.snapshot.queueSongIds[7];

        await handler.setShuffleMode(AudioServiceShuffleMode.none);

        final expected = <String>[...ids(6), 'song-0', ...ids(60, 6), 'song-1'];
        expect(handler.snapshot.queueSongIds, expected);
        expect(handler.snapshot.shuffleMode, AudioServiceShuffleMode.none);
        expect(handler.snapshot.currentSongId, playing);
        expect(handler.snapshot.currentIndex, expected.indexOf(playing));
        expect(player.sourceIds[player.index!], playing);
        expectNativeMirrorsQueue(handler, player);
      });

      Future<void> expectMode(
        NavisAudioHandler handler,
        NavisDatabase database,
        AudioServiceShuffleMode mode,
      ) async {
        await handler.debugFlushQueuePersistence();
        expect(handler.snapshot.shuffleMode, mode);
        expect(handler.playbackState.value.shuffleMode, mode);
        expect(
          (await database.playQueueDao.getQueueState())!.shuffleMode,
          mode == AudioServiceShuffleMode.all
              ? ShuffleMode.all
              : ShuffleMode.off,
        );
      }

      for (final rows in [false, true]) {
        test('a plain replace after shuffle plays in order with shuffle off '
            '(rows=$rows)', () async {
          final (handler, player, database) = await windowed(60);
          await handler.replaceQueue(ids(60), expandMatchFlows: false);
          await handler.setShuffleMode(AudioServiceShuffleMode.all);
          await expectMode(handler, database, AudioServiceShuffleMode.all);
          expect(handler.snapshot.queueSongIds, isNot(ids(60)));

          if (rows) {
            await handler.replaceQueueWithData(
              await database.libraryDao.getSongsByIds(ids(60)),
              startIndex: 10,
              expandMatchFlows: false,
            );
          } else {
            await handler.replaceQueue(
              ids(60),
              startIndex: 10,
              expandMatchFlows: false,
            );
          }
          expect(handler.snapshot.queueSongIds, ids(60));
          expect(handler.snapshot.currentSongId, 'song-10');
          await expectMode(handler, database, AudioServiceShuffleMode.none);
          expectNativeMirrorsQueue(handler, player);

          // The toggle still shuffles and restores the new queue.
          await handler.setShuffleMode(AudioServiceShuffleMode.all);
          expect(handler.snapshot.currentSongId, 'song-10');
          expect(handler.snapshot.queueSongIds.first, 'song-10');
          expect(handler.snapshot.queueSongIds, isNot(ids(60)));
          await handler.setShuffleMode(AudioServiceShuffleMode.none);
          expect(handler.snapshot.queueSongIds, ids(60));
          expect(handler.snapshot.currentSongId, 'song-10');
        });
      }

      test(
        'entity Shuffle turns shuffle on and the next Play turns it off',
        () async {
          final (handler, player, database) = await windowed(60);
          final shuffled = (await database.libraryDao.getSongsByIds(ids(60)))
            ..shuffle(Random(5));
          await handler.replaceQueueWithData(
            shuffled,
            originalOrder: ids(60),
            expandMatchFlows: false,
          );
          expect(handler.snapshot.queueSongIds, [
            for (final r in shuffled) r.id,
          ]);
          await expectMode(handler, database, AudioServiceShuffleMode.all);

          await handler.replaceQueue(ids(60), expandMatchFlows: false);
          expect(handler.snapshot.queueSongIds, ids(60));
          await expectMode(handler, database, AudioServiceShuffleMode.none);
          expectNativeMirrorsQueue(handler, player);
        },
      );

      test(
        'Add to queue and Play next never change the shuffle mode',
        () async {
          final (handler, _, database) = await windowed(30);
          await handler.replaceQueue(ids(10), expandMatchFlows: false);
          await handler.setShuffleMode(AudioServiceShuffleMode.all);
          await handler.addToQueue(['song-20'], expandMatchFlows: false);
          await handler.playNext(['song-21'], expandMatchFlows: false);
          await expectMode(handler, database, AudioServiceShuffleMode.all);
          expect(handler.snapshot.queueSongIds, hasLength(12));

          await handler.setShuffleMode(AudioServiceShuffleMode.none);
          await handler.addToQueue(['song-22'], expandMatchFlows: false);
          await handler.playNext(['song-23'], expandMatchFlows: false);
          await expectMode(handler, database, AudioServiceShuffleMode.none);
        },
      );

      test('batched inserts into a shuffled queue keep it shuffled', () async {
        final (handler, _, database) = await windowed(30);
        await handler.replaceQueue(ids(10), expandMatchFlows: false);
        await handler.setShuffleMode(AudioServiceShuffleMode.all);
        final order = List.of(handler.snapshot.queueSongIds);
        await handler.mergeIntoUpcoming(
          await database.libraryDao.getSongsByIds(ids(30, 10)),
          notBefore: 1,
          random: Random(7),
        );
        await expectMode(handler, database, AudioServiceShuffleMode.all);
        expect(handler.snapshot.queueSongIds, hasLength(30));
        // The earlier songs keep their shuffled order.
        expect(
          handler.snapshot.queueSongIds.where(ids(10).contains).toList(),
          order,
        );
      });

      test('clearing the queue ends its shuffle mode', () async {
        final (handler, _, database) = await windowed(30);
        await handler.replaceQueue(ids(10), expandMatchFlows: false);
        await handler.setShuffleMode(AudioServiceShuffleMode.all);
        await handler.clearQueue();
        expect(handler.snapshot.shuffleMode, AudioServiceShuffleMode.none);
        await handler.addToQueue(ids(5), expandMatchFlows: false);
        expect(handler.snapshot.queueSongIds, ids(5));
        await expectMode(handler, database, AudioServiceShuffleMode.none);
      });

      test(
        'a mix started from a shuffled queue starts with shuffle off',
        () async {
          final (handler, _, database) = await windowed(30);
          await handler.replaceQueue(ids(10), expandMatchFlows: false);
          await handler.setShuffleMode(AudioServiceShuffleMode.all);
          final current = handler.snapshot.currentSongId!;
          await handler.retainCurrentSongAsQueue(current);
          await handler.addToQueue(ids(30, 20), expandMatchFlows: false);
          expect(handler.snapshot.queueSongIds, [current, ...ids(30, 20)]);
          await expectMode(handler, database, AudioServiceShuffleMode.none);

          // Toggling on and off again still restores the mix order.
          await handler.setShuffleMode(AudioServiceShuffleMode.all);
          await handler.setShuffleMode(AudioServiceShuffleMode.none);
          expect(handler.snapshot.queueSongIds, [current, ...ids(30, 20)]);
        },
      );

      test(
        'no emission pairs the old queue with the new mode or the reverse',
        () async {
          final (handler, _, _) = await windowed(30);
          await handler.replaceQueue(ids(10), expandMatchFlows: false);
          await handler.setShuffleMode(AudioServiceShuffleMode.all);
          final shuffled = List.of(handler.snapshot.queueSongIds);
          expect(shuffled, isNot(ids(10)));
          final seen = <PlaybackSnapshot>[];
          final sub = handler.snapshotStream.listen(seen.add);
          await handler.replaceQueue(
            ids(10),
            startIndex: 3,
            expandMatchFlows: false,
          );
          await settleQueue(handler);
          await sub.cancel();
          expect(seen, isNotEmpty);
          for (final snapshot in seen) {
            final oldQueue = listEquals(snapshot.queueSongIds, shuffled);
            final newQueue = listEquals(snapshot.queueSongIds, ids(10));
            expect(oldQueue || newQueue, isTrue);
            expect(
              snapshot.shuffleMode,
              oldQueue
                  ? AudioServiceShuffleMode.all
                  : AudioServiceShuffleMode.none,
              reason: 'queue ${snapshot.queueSongIds}',
            );
          }
        },
      );

      test('repeat all never reshuffles an in-order queue', () async {
        final (handler, player, _) = await windowed(12);
        await handler.replaceQueue(ids(12), expandMatchFlows: false);
        await handler.setShuffleMode(AudioServiceShuffleMode.all);
        await handler.replaceQueue(ids(12), expandMatchFlows: false);
        await handler.setRepeatMode(AudioServiceRepeatMode.all);
        player.moveTo(11);
        await handler.skipToNext();
        await until(() => handler.snapshot.currentSongId == 'song-0');
        expect(handler.snapshot.queueSongIds, ids(12));
        expect(handler.snapshot.shuffleMode, AudioServiceShuffleMode.none);
      });

      Future<(NavisAudioHandler, ControllableAudioPlayer)> restoring({
        required List<String> playOrder,
        required int currentIndex,
        List<int>? originalOrder,
      }) async {
        final directory = await Directory.systemTemp.createTemp('navis-shuf-');
        final (handler, player, database) = await createHandler(
          directory,
          60,
          queueWindow: window,
          seed: (database) => database.playQueueDao.saveQueue(
            currentIndex: currentIndex,
            songIds: playOrder,
            shuffleMode: ShuffleMode.all,
            originalOrder: originalOrder,
          ),
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        await until(
          () =>
              handler.snapshot.queueSongIds.length == 60 &&
              !handler.snapshot.isLoading,
        );
        return (handler, player);
      }

      test(
        'a saved shuffled queue restores in play order and unshuffles',
        () async {
          final playOrder = ids(60).reversed.toList();
          final (handler, player) = await restoring(
            playOrder: playOrder,
            currentIndex: 2,
            originalOrder: <int>[for (var i = 59; i >= 0; i--) i],
          );
          expect(handler.snapshot.queueSongIds, playOrder);
          expect(handler.snapshot.shuffleMode, AudioServiceShuffleMode.all);
          expect(handler.snapshot.currentSongId, 'song-57');

          await handler.setShuffleMode(AudioServiceShuffleMode.none);
          expect(handler.snapshot.queueSongIds, ids(60));
          expect(handler.snapshot.currentSongId, 'song-57');
          expectNativeMirrorsQueue(handler, player);
        },
      );

      test('a queue saved before Navis owned shuffle is shuffled again after '
          'the current song', () async {
        final (handler, player) = await restoring(
          playOrder: ids(60),
          currentIndex: 4,
        );
        final queue = handler.snapshot.queueSongIds;
        expect(queue.take(5), ids(5));
        expect(queue.skip(5).toSet(), ids(60, 5).toSet());
        expect(queue.skip(5), isNot(ids(60, 5)));
        expect(handler.snapshot.currentSongId, 'song-4');

        await handler.setShuffleMode(AudioServiceShuffleMode.none);
        expect(handler.snapshot.queueSongIds, ids(60));
        expectNativeMirrorsQueue(handler, player);
      });

      test('the play order and the original order are both saved', () async {
        final directory = await Directory.systemTemp.createTemp('navis-shuf-');
        final (handler, player, database) = await createHandler(
          directory,
          60,
          queueWindow: window,
        );
        var closed = false;
        Future<void> close() async {
          if (closed) return;
          await handler.disposeHandler();
          await database.close();
          closed = true;
        }

        addTearDown(() async {
          await close();
          await directory.delete(recursive: true);
        });
        await handler.replaceQueue(ids(60), expandMatchFlows: false);
        player.moveTo(3);
        await handler.setShuffleMode(AudioServiceShuffleMode.all);
        await handler.debugFlushQueuePersistence();

        final saved = await database.playQueueDao.getQueueEntries();
        expect(
          saved.map((entry) => entry.song.id),
          handler.snapshot.queueSongIds,
        );
        final byOriginal = List.of(saved)
          ..sort((a, b) => a.originalOrder!.compareTo(b.originalOrder!));
        expect(byOriginal.map((entry) => entry.song.id), ids(60));
        final state = (await database.playQueueDao.getQueueState())!;
        expect(state.currentIndex, 0);
        expect(state.shuffleMode, ShuffleMode.all);
        final playOrder = List.of(handler.snapshot.queueSongIds);
        await close();
        final (restored, restoredPlayer) = await restoring(
          playOrder: saved.map((entry) => entry.song.id).toList(),
          currentIndex: state.currentIndex!,
          originalOrder: saved.map((entry) => entry.originalOrder!).toList(),
        );
        expect(restored.snapshot.queueSongIds, playOrder);
        expect(restored.snapshot.currentSongId, 'song-3');
        expect(restored.snapshot.currentIndex, 0);
        expect(restored.snapshot.shuffleMode, AudioServiceShuffleMode.all);
        await restored.setShuffleMode(AudioServiceShuffleMode.none);
        expect(restored.snapshot.queueSongIds, ids(60));
        expect(restored.snapshot.currentSongId, 'song-3');
        expect(restored.snapshot.currentIndex, 3);
        expectNativeMirrorsQueue(restored, restoredPlayer);
      });
    });

    test('repeat all waits until nothing is deferred on either side', () async {
      final (handler, player, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      expect(handler.snapshot.repeatMode, AudioServiceRepeatMode.all);
      expect(player.appliedLoopMode, LoopMode.off);
      await handler.playFromIndex(59);
      await until(
        () =>
            handler.snapshot.currentSongId == 'song-59' &&
            !handler.snapshot.isLoading,
      );
      // The first songs were released from the player, so it cannot wrap to
      // them itself; Navis wraps once the last song ends.
      expect(player.appliedLoopMode, LoopMode.off);
      player.state = ProcessingState.completed;
      await handler.play();
      await until(
        () =>
            handler.snapshot.currentSongId == 'song-0' &&
            !handler.snapshot.isLoading,
      );
      expect(handler.snapshot.currentIndex, 0);
      expect(player.appliedLoopMode, LoopMode.off);
    });

    test('repeat all resumes when a new queue has nothing deferred', () async {
      final (handler, player, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      expect(player.appliedLoopMode, LoopMode.off);
      await handler.replaceQueue(['song-3'], expandMatchFlows: false);
      expect(player.appliedLoopMode, LoopMode.all);
      expect(handler.snapshot.repeatMode, AudioServiceRepeatMode.all);
    });

    test('previous from the first song wraps into the deferred tail with '
        'repeat all', () async {
      final (handler, _, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      await handler.skipToPrevious();
      await until(
        () =>
            handler.snapshot.currentSongId == 'song-59' &&
            !handler.snapshot.isLoading,
      );
      expect(handler.snapshot.queueSongIds, ids(60));
    });

    test('an upcoming merge keeps the next two songs and one native '
        'removal', () async {
      final (handler, player, database) = await windowed(30);
      await handler.replaceQueue(ids(10), expandMatchFlows: false);
      final incoming = await database.libraryDao.getSongsByIds(ids(30, 10));
      final removals = player.rangeRemovals;
      await handler.mergeIntoUpcoming(
        incoming,
        notBefore: 1,
        random: Random(7),
      );
      final queue = handler.snapshot.queueSongIds;
      expect(queue, hasLength(30));
      expect(queue.take(3), ['song-0', 'song-1', 'song-2']);
      expect(queue.toSet(), ids(30).toSet());
      expect(player.rangeRemovals, removals + 1);
      // The earlier songs keep their relative order among the new ones.
      final earlier = queue.where(ids(10).contains).toList();
      expect(earlier, ids(10));
    });

    test('a merge into a queue with deferred songs makes no native call '
        'and spreads over the deferred songs', () async {
      final (handler, player, database) = await windowed(60);
      await handler.replaceQueue(ids(40), expandMatchFlows: false);
      final held = player.sourceIds;
      expect(held, ids(9));
      final removals = player.rangeRemovals;
      final batches = player.batchMutationCount;
      final incoming = await database.libraryDao.getSongsByIds(ids(60, 40));
      await handler.mergeIntoUpcoming(
        incoming,
        notBefore: 1,
        random: Random(7),
      );
      expect(player.sourceIds, held);
      expect(player.rangeRemovals, removals);
      expect(player.batchMutationCount, batches);
      final queue = handler.snapshot.queueSongIds;
      expect(queue.take(9), held);
      expect(queue.toSet(), ids(60).toSet());
      expect(queue.where(ids(40).contains).toList(), ids(40));
      // Not simply appended: new songs land among the deferred ones.
      expect(
        queue.skip(9).take(31).toSet().intersection(ids(60, 40).toSet()),
        isNotEmpty,
      );
    });

    test('a song refreshed in place does not stop a release', () async {
      final (handler, player, _) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      // Liked-state (and art) updates replace queue entries outside the
      // queue lane, any time.
      var refreshing = true;
      var liked = false;
      final refresher = () async {
        while (refreshing) {
          liked = !liked;
          await handler.syncSongLikedState('song-0', liked: liked);
          await Future<void>.delayed(Duration.zero);
        }
      }();
      addTearDown(() => refreshing = false);
      player.moveTo(6);
      await until(() => player.sourceIds.length == 17);
      refreshing = false;
      await refresher;
      expect(player.sourceIds, ids(17));
      expect(handler.snapshot.queueSongIds, ids(60));
    });
    test('the notification like on a remote song changes nothing', () async {
      final (handler, _, database) = await windowed(3);
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(id: 'ext-deezer-song-1', title: 'Remote'),
      ]);
      // Played from a cached file, so the queue can load without a session.
      final cached = File(
        '${(await Directory.systemTemp.createTemp('navis-ext-')).path}/ext.mp3',
      )..createSync();
      addTearDown(() => cached.parent.delete(recursive: true));
      await cached.writeAsBytes(<int>[1, 2, 3]);
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'ext-deezer-song-1',
          filePath: cached.path,
          fileSize: 3,
          format: 'mp3',
          cacheType: CacheType.permanent,
          downloadStatus: DownloadStatus.complete,
          lastAccessedAt: DateTime.now(),
        ),
      );
      await handler.replaceQueue(<String>[
        'ext-deezer-song-1',
        'song-1',
      ], expandMatchFlows: false);

      expect(handler.snapshot.currentSongId, 'ext-deezer-song-1');
      await handler.toggleLike();

      expect(
        await database.libraryDao.getSongStarred('ext-deezer-song-1'),
        isNull,
      );
      expect(await database.starSyncDao.getPendingActions(), isEmpty);
    });

    test('an alias update from inside a database transaction does not wait '
        'for queue work', () async {
      final (handler, player, database) = await windowed(60);
      await handler.replaceQueue(ids(60), expandMatchFlows: false);
      // As sync does, before it remaps the rows in the same transaction: the
      // queue must not make the transaction wait for it.
      await database.transaction(() async {
        await handler
            .applySongIdentityAliases(<String, String>{'song-30': 'song-31'})
            .timeout(const Duration(seconds: 2));
      });
      await until(
        () =>
            handler.debugQueueLaneIdle &&
            handler.snapshot.queueSongIds[30] == 'song-31',
      );
      // Queue work started from inside the transaction must not keep using
      // it after it closed: its coalesced save lands, and a release still
      // reads the database.
      await Future<void>.delayed(const Duration(seconds: 1));
      final saved = await database.playQueueDao.getQueueItems();
      expect(saved.elementAt(30).id, 'song-31');
      player.moveTo(6);
      await until(() => player.sourceIds.length == 17);
    });
  });

  for (final (count, lateFailure) in [(3, false), (3, true), (70, false)]) {
    const loadDeadline = Duration(milliseconds: 500);
    test('timed-out explicit saved queue preparation cannot change a newer selection '
        '(count=$count, lateFailure=$lateFailure)', () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-restore-timeout-',
      );
      final gate = Completer<void>();
      final entered = Completer<void>();
      final initialPlayer = ControllableAudioPlayer()
        ..loadGate = gate
        ..loadEntered = entered
        ..keepStreamsAfterDispose = true
        ..blockedLoadError = lateFailure
            ? StateError('late restore failure')
            : null;
      final rebuilt = <ControllableAudioPlayer>[];
      final (handler, _, database) = await createHandler(
        directory,
        count,
        savedQueueIndex: 0,
        initialPlayer: initialPlayer,
        waitForReady: false,
        rebuiltPlayers: rebuilt,
        // Shortened from the 12 s default. prepare() runs the in-lane restore,
        // which never arms the queueRestore timer: the gated native load's
        // deadline is the only timeout here, already spent before
        // replaceQueue, so no later deadline is left to race the selection.
        timeouts: const NavisPlaybackTimeouts(load: loadDeadline),
      );
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        await pumpEventQueue();
        await handler.disposeHandler();
        initialPlayer.keepStreamsAfterDispose = false;
        await initialPlayer.dispose();
        await database.close();
        await directory.delete(recursive: true);
      });
      await handler.waitUntilReady();
      await handler.debugWaitForStartupQueueRestore();
      expect(initialPlayer.sequence, isEmpty);
      final preparing = handler.prepare();
      await entered.future.timeout(const Duration(seconds: 5));
      await preparing.timeout(const Duration(seconds: 30));
      expect((await database.playQueueDao.getQueueItems()).length, count);

      await handler.replaceQueue(['song-2'], expandMatchFlows: false);
      final selectedPlayer =
          handler.debugActivePlayer as ControllableAudioPlayer;
      expect(selectedPlayer.isPlaying, isTrue);
      gate.complete();
      await pumpEventQueue(times: 50);

      expect(identical(handler.debugActivePlayer, selectedPlayer), isTrue);
      expect(selectedPlayer.isPlaying, isTrue);
      expect(selectedPlayer.sourceIds, ['song-2']);
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(handler.mediaItem.value?.id, 'song-2');
      expect(handler.snapshot.queueSongIds, ['song-2']);
      expect(
        handler.collectPlaybackDiagnostics()['queueRestoreOutcome'],
        'timeout',
      );
      await handler.debugFlushQueuePersistence();
      expect(
        (await database.playQueueDao.getQueueItems()).map((song) => song.id),
        ['song-2'],
      );
    });
  }

  group('deferred startup queue restore', () {
    SubsonicApiClient createApiClient() => SubsonicApiClient(
      baseUrl: 'https://example.com',
      authConfig: const SubsonicAuthConfig(
        username: 'alice',
        password: 'secret',
        apiVersion: '1.16.1',
      ),
      enableLogging: false,
    );

    String restoreOutcome(NavisAudioHandler handler) =>
        handler.collectPlaybackDiagnostics()['queueRestoreOutcome']! as String;

    test('restores a reconfirmed song after the library rebuild', () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-rebuilt-queue-restore-',
      );
      final api = createApiClient();
      final (handler, player, database) = await createHandler(
        directory,
        1,
        savedQueueIndex: 0,
        cacheSongs: false,
        readApiClient: () => api,
        seed: (database) async {
          final repository = await seedSyncSession(database);
          await database.libraryDao.clearLibraryData();
          const album = models.Album(
            id: 'album',
            name: 'Album',
            songCount: 1,
            songs: [
              models.Song(
                id: 'song-0',
                title: 'Reconfirmed song',
                albumId: 'album',
              ),
            ],
          );
          final syncApi = FakeLibrarySyncApi()
            ..fastPathPages[0] = [album]
            ..albumDetails['album'] = album;
          final result = await serialDriftEngine(
            api: syncApi,
            database: database,
            repository: repository,
          ).executeSyncPlan(syncPlanForTest(LibrarySyncPlanKind.fullRepair));
          expect(result.freshness, LibrarySyncFreshness.current);
        },
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      expect(restoreOutcome(handler), 'restored');
      expect(handler.snapshot.queueSongIds, ['song-0']);
      expect(handler.snapshot.currentIndex, 0);
      expect(handler.mediaItem.value?.title, 'Reconfirmed song');
      expect(player.isPlaying, isFalse);
      expect(await database.playQueueDao.getQueueItems(), hasLength(1));
    });

    test(
      'publishes paused metadata before the session becomes available',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-deferred-restore-',
        );
        SubsonicApiClient? api;
        final (handler, player, database) = await createHandler(
          directory,
          3,
          savedQueueIndex: 1,
          cacheSongs: false,
          readApiClient: () => api,
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });

        expect(restoreOutcome(handler), 'restored');
        expect(handler.snapshot.queueSongIds, ['song-0', 'song-1', 'song-2']);
        expect(player.sequence, isEmpty);

        // Still no session: the retry defers again and keeps the saved queue.
        await handler.retryDeferredQueueRestore();
        expect(restoreOutcome(handler), 'restored');
        expect(handler.snapshot.queueSongIds, ['song-0', 'song-1', 'song-2']);
        expect(player.sequence, isEmpty);

        api = createApiClient();
        await handler.prepare();

        expect(restoreOutcome(handler), 'restored');
        expect(handler.snapshot.queueSongIds, ['song-0', 'song-1', 'song-2']);
        expect(handler.snapshot.currentIndex, 1);
        expect(player.isPlaying, isFalse);
        expect((await database.playQueueDao.getQueueItems()).map((s) => s.id), [
          'song-0',
          'song-1',
          'song-2',
        ]);

        // Once restored, a later session change does not restore again.
        await handler.replaceQueue(
          ['song-2'],
          autoPlay: false,
          expandMatchFlows: false,
        );
        await handler.retryDeferredQueueRestore();
        expect(handler.snapshot.queueSongIds, ['song-2']);
      },
    );

    test('yields to a queue the user starts meanwhile', () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-deferred-restore-user-',
      );
      SubsonicApiClient? api;
      final (handler, player, database) = await createHandler(
        directory,
        3,
        savedQueueIndex: 0,
        cacheSongs: false,
        readApiClient: () => api,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      expect(restoreOutcome(handler), 'restored');

      api = createApiClient();
      // The session arrives together with the user's own selection.
      final retry = handler.retryDeferredQueueRestore();
      final userQueue = handler.replaceQueue([
        'song-2',
      ], expandMatchFlows: false);
      await Future.wait([retry, userQueue]);
      await handler.retryDeferredQueueRestore();

      expect(handler.snapshot.queueSongIds, ['song-2']);
      expect(handler.snapshot.queueSongIds, ['song-2']);
      expect(player.isPlaying, isTrue);
    });

    test(
      'restores offline metadata and streams only after explicit Play',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-deferred-restore-offline-',
        );
        final api = createApiClient();
        var online = false;
        final (handler, player, database) = await createHandler(
          directory,
          2,
          savedQueueIndex: 1,
          cacheSongs: false,
          readApiClient: () => api,
          readCanStream: () => online,
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        expect(restoreOutcome(handler), 'restored');
        expect(player.sequence, isEmpty);
        expect(handler.snapshot.currentIndex, 1);

        online = true;
        await handler.play();

        expect(restoreOutcome(handler), 'restored');
        expect(handler.snapshot.queueSongIds, ['song-0', 'song-1']);
        expect(handler.snapshot.currentIndex, 1);
        expect(player.isPlaying, isTrue);
      },
    );
  });

  group('queue window model', () {
    // A tiny window, so heads, tails, releases and trims happen constantly.
    const tiny = NavisQueueWindow(
      deferThreshold: 12,
      ahead: 3,
      lowWater: 2,
      page: 3,
      nearJump: 5,
      behind: 3,
      trimSlack: 1,
    );
    final seeds =
        int.tryParse(Platform.environment['NAVIS_QUEUE_MODEL_SEEDS'] ?? '') ??
        500;
    const steps = 24;
    const songCount = 30;

    Future<void> settle(NavisAudioHandler handler) async {
      if (handler.snapshot.isLoading) {
        await handler.snapshotStream.firstWhere(
          (snapshot) => !snapshot.isLoading,
        );
      }
      var quiet = 0;
      for (var i = 0; i < 2000 && quiet < 3; i++) {
        await Future<void>.delayed(Duration.zero);
        quiet = handler.debugQueueLaneIdle && !handler.snapshot.isLoading
            ? quiet + 1
            : 0;
      }
      if (quiet < 3) fail('queue work did not settle');
    }

    test('matches a plain list through random edits and navigation', () async {
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      Completer<void>? warmEntered;
      Completer<void>? warmGate;
      server.listen((request) async {
        final gate = warmGate;
        if (gate != null) {
          if (warmEntered case final entered? when !entered.isCompleted) {
            entered.complete();
          }
          await gate.future;
        }
        try {
          request.response
            ..contentLength = 2
            ..add([1, 2]);
          await request.response.close();
        } on HttpException {
          // Navigation may supersede a warm-up probe.
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
      addTearDown(() async {
        if (warmGate case final gate? when !gate.isCompleted) gate.complete();
        await server.close(force: true);
        HttpOverrides.global = previousHttp;
      });
      final directory = await Directory.systemTemp.createTemp('navis-model-');
      addTearDown(() => directory.delete(recursive: true));
      for (var seed = 0; seed < seeds; seed++) {
        final random = Random(seed);
        final players = <ControllableAudioPlayer>[];
        final (handler, player, database) = await createHandler(
          directory,
          songCount,
          queueWindow: tiny,
          players: players,
          readApiClient: () => api,
        );
        final invariant = watchAudioMetadata(handler, players);
        final log = <String>[];
        try {
          var model = List<String>.generate(20, (i) => 'song-$i');
          var current = random.nextInt(model.length);
          await handler.replaceQueue(
            model,
            startIndex: current,
            expandMatchFlows: false,
          );
          await settle(handler);

          void check(String step) {
            expectAudioMatchesMetadata(handler, players, settled: true);
            final reason = 'seed $seed after ${log.join(', ')}';
            final snapshot = handler.snapshot;
            expect(snapshot.queueSongIds, model, reason: reason);
            expect(snapshot.currentIndex, current, reason: reason);
            expect(snapshot.currentSongId, model[current], reason: reason);
            final head =
                handler.collectPlaybackDiagnostics()['deferredHeadLength']
                    as int;
            final native = player.sourceIds;
            expect(
              native,
              model.sublist(head, head + native.length),
              reason: reason,
            );
            expect(player.index! + head, current, reason: reason);
            expect(player.shuffleEnabled, isFalse, reason: reason);
          }

          check('start');
          for (var step = 0; step < steps; step++) {
            final song = 'song-${random.nextInt(songCount)}';
            switch (random.nextInt(10)) {
              case 0:
                log.add('next');
                await handler.skipToNext();
                if (current < model.length - 1) current++;
              case 1:
                log.add('previous');
                await handler.skipToPrevious();
                if (current > 0) current--;
              case 2:
                final target = random.nextInt(model.length);
                log.add('jump $target');
                await handler.playFromIndex(target);
                current = target;
              case 3:
                final index = player.index!;
                if (index + 1 >= player.sourceIds.length) continue;
                log.add('advance');
                player.moveTo(index + 1);
                current++;
              case 4:
                log.add('add $song');
                await handler.addToQueue(<String>[
                  song,
                ], expandMatchFlows: false);
                model = <String>[...model, song];
              case 5:
                log.add('play next $song');
                await handler.playNext(<String>[song], expandMatchFlows: false);
                model = <String>[...model]..insert(current + 1, song);
              case 6:
                if (model.length < 3) continue;
                var index = random.nextInt(model.length);
                if (index == current) index = (index + 1) % model.length;
                log.add('remove $index');
                await handler.removeAt(index);
                model = <String>[...model]..removeAt(index);
                if (index < current) current--;
              case 7:
                var from = random.nextInt(model.length);
                if (from == current) from = (from + 1) % model.length;
                final to = random.nextInt(model.length + 1);
                final adjusted = from < to ? to - 1 : to;
                if (from == adjusted) continue;
                log.add('move $from to $to');
                await handler.reorderQueue(from, to);
                final next = <String>[...model];
                next.insert(adjusted, next.removeAt(from));
                model = next;
                if (from < current && adjusted >= current) {
                  current--;
                } else if (from > current && adjusted <= current) {
                  current++;
                }
              case 9:
                final cold = seed % 10 == 0;
                log.add('replace shuffled rows external cold=$cold');
                final ids = List<String>.generate(20, (i) => 'song-$i');
                final rows = await database.libraryDao.getSongsByIds(ids);
                rows[1] = rows[1].copyWith(
                  id: cold ? 'cold-model-$seed-$step' : rows[1].id,
                  isExternal: true,
                );
                if (cold) {
                  await database.libraryDao.upsertSongs([
                    SongsTableCompanion.insert(
                      id: rows[1].id,
                      title: rows[1].title,
                      isExternal: const Value(true),
                    ),
                  ]);
                }
                final original = rows.map((song) => song.id).toList();
                rows.shuffle(Random(seed * steps + step));
                // A cold external selection tests the same first-byte gate as
                // entity Shuffle while the model continues editing its queue.
                if (cold) {
                  final remote = rows.indexWhere((song) => song.isExternal);
                  rows.insert(0, rows.removeAt(remote));
                  warmEntered = Completer<void>();
                  warmGate = Completer<void>();
                }
                final replacing = handler.replaceQueueWithData(
                  rows,
                  originalOrder: original,
                  expandMatchFlows: false,
                );
                if (cold) {
                  await warmEntered!.future;
                  expectAudioMatchesMetadata(
                    handler,
                    players,
                    previousSongId: model[current],
                  );
                  warmGate!.complete();
                  warmGate = null;
                }
                await replacing;
                model = rows.map((song) => song.id).toList();
                current = 0;
              case 8:
                final on =
                    handler.snapshot.shuffleMode ==
                    AudioServiceShuffleMode.none;
                log.add(on ? 'shuffle on' : 'shuffle off');
                final playing = model[current];
                await handler.setShuffleMode(
                  on
                      ? AudioServiceShuffleMode.all
                      : AudioServiceShuffleMode.none,
                );
                await settle(handler);
                final reordered = handler.snapshot.queueSongIds;
                expect(
                  List<String>.of(reordered)..sort(),
                  List<String>.of(model)..sort(),
                  reason: 'seed $seed: ${log.join(', ')}',
                );
                expect(
                  handler.snapshot.currentSongId,
                  playing,
                  reason: 'seed $seed: ${log.join(', ')}',
                );
                if (on) {
                  expect(
                    handler.snapshot.currentIndex,
                    0,
                    reason: 'seed $seed: ${log.join(', ')}',
                  );
                  expect(
                    reordered.first,
                    playing,
                    reason: 'seed $seed: ${log.join(', ')}',
                  );
                }
                model = List<String>.of(reordered);
                current = handler.snapshot.currentIndex!;
            }
            await settle(handler);
            check(log.last);
          }
          await handler.debugFlushQueuePersistence();
          final saved = await database.playQueueDao.getQueueItems();
          expect(
            saved.map((song) => song.id),
            model,
            reason: 'seed $seed saved: ${log.join(', ')}',
          );
          expect(
            (await database.playQueueDao.getQueueState())!.currentIndex,
            current,
            reason: 'seed $seed saved index: ${log.join(', ')}',
          );
          await invariant();
        } finally {
          handler.debugSnapshotObserver = null;
          await handler.disposeHandler();
          await database.close();
        }
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
