import 'package:navis/src/features/auto/domain/android_auto_constants.dart';
import 'package:navis/src/features/cache/data/rolling_cache_sidecar_downloader.dart';

import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;

import 'package:navis/src/features/player/domain/playback_adjustments.dart';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:navis/src/features/player/data/playback_art_cache.dart';
import 'package:navis/src/features/player/data/android_system_art.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:drift/drift.dart' show Value;
import 'package:navis/src/features/auto/data/auto_media_id.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:navis/src/features/player/data/radio_metadata_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/integrations/domain/integration_artwork.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/recommendation_service.dart';
import 'package:navis/src/features/player/data/lock_cache_follower_source.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/data/real_time_projection_audio_handler.dart';
import 'package:navis/src/features/player/data/scrobble_service.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';

import '../../../../helpers/test_database.dart';
import 'navis_audio_handler_navigation_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(const RadioFilters()));

  group('audio metadata invariants', () {
    const tiny = NavisQueueWindow(
      deferThreshold: 12,
      ahead: 3,
      lowWater: 2,
      page: 3,
      nearJump: 5,
      behind: 3,
      trimSlack: 1,
    );
    const deadlines = NavisPlaybackTimeouts(
      control: Duration(milliseconds: 100),
      load: Duration(milliseconds: 300),
      reset: Duration(milliseconds: 150),
      remoteLoad: Duration(seconds: 5),
    );
    List<String> ids(int count) => List.generate(count, (i) => 'song-$i');

    Future<(NavisAudioHandler, ControllableAudioPlayer, NavisDatabase)> fixture(
      List<ControllableAudioPlayer> players, {
      bool crossfade = false,
      int count = 60,
      NavisQueueWindow queueWindow = tiny,
      SubsonicApiClient? api,
      Future<void> Function(NavisDatabase)? seed,
      FakeAsync? clock,
      Set<String>? hungLoadSongs,
      ScrobbleService? scrobbleService,
      String replayGainMode = 'off',
    }) async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-invariant-',
      );
      final created = await createHandler(
        directory,
        count,
        crossfade: crossfade,
        players: players,
        queueWindow: queueWindow,
        timeouts: deadlines,
        readApiClient: () => api,
        seed: seed,
        clock: clock,
        hungLoadSongs: hungLoadSongs,
        scrobbleService: scrobbleService,
        replayGainMode: replayGainMode,
      );
      addTearDown(() async {
        var disposed = false;
        final disposing = created.$1.disposeHandler().then(
          (_) => disposed = true,
        );
        if (clock != null) {
          for (var i = 0; i < 10000 && !disposed; i++) {
            clock.flushMicrotasks();
            clock.elapse(const Duration(seconds: 1));
            await Future<void>.delayed(Duration.zero);
          }
        }
        await disposing;
        await created.$3.close();
        await directory.delete(recursive: true);
      });
      return created;
    }

    for (final count in [6, 300]) {
      for (final crossfade in [false, true]) {
        for (final action in [
          'auto',
          'next',
          'paused-next',
          'play',
          'restart',
          if (crossfade) 'fade',
        ]) {
          test(
            'shuffled next pass count=$count fade=$crossfade action=$action',
            () async {
              final players = <ControllableAudioPlayer>[];
              final (handler, _, database) = await fixture(
                players,
                count: count,
                crossfade: crossfade,
                queueWindow: const NavisQueueWindow(),
              );
              await handler.replaceQueue(
                ids(count),
                startIndex: 2,
                expandMatchFlows: false,
              );
              await handler.setShuffleMode(AudioServiceShuffleMode.all);
              await handler.setRepeatMode(
                action == 'restart'
                    ? AudioServiceRepeatMode.none
                    : AudioServiceRepeatMode.all,
              );
              final previous = List<String>.of(handler.snapshot.queueSongIds);
              await handler.playFromIndex(count - 1);
              await settleQueue(handler);
              expect(handler.snapshot.currentIndex, count - 1);
              if (action == 'paused-next') await handler.pause();
              final finished = handler.snapshot.currentSongId;
              // A real overlap intentionally runs both decks. Assert its
              // settled handoff; other paths retain per-emission checks.
              final check = action == 'fade' && count == 6
                  ? () async => expectAudioMatchesMetadata(
                      handler,
                      players,
                      settled: true,
                    )
                  : watchAudioMetadata(handler, players);
              final active =
                  handler.debugActivePlayer as ControllableAudioPlayer;
              switch (action) {
                case 'auto':
                  active.finishCurrentTrack();
                  await pumpEventQueue();
                case 'next':
                case 'paused-next':
                  await handler.skipToNext();
                case 'play':
                case 'restart':
                  active
                    ..state = ProcessingState.completed
                    ..simulatedPosition = active.simulatedDuration;
                  await handler.play();
                case 'fade':
                  if (count == 6) {
                    await handler.debugStartCrossfade();
                    await handler.debugCompleteCrossfade();
                  } else {
                    // Released windows already wrap through navigation.
                    handler.debugCheckCrossfadeTrigger(
                      active.simulatedDuration - const Duration(seconds: 5),
                    );
                    active.finishCurrentTrack();
                    await pumpEventQueue();
                  }
              }
              await settleQueue(handler);
              final order = handler.snapshot.queueSongIds;
              expect(order, isNot(previous));
              expect(order.toSet(), previous.toSet());
              expect(order, hasLength(count));
              expect(order.first, isNot(finished));
              expect(handler.snapshot.currentIndex, 0);
              expect(handler.snapshot.currentSongId, order.first);
              expect(
                (handler.debugActivePlayer as ControllableAudioPlayer)
                    .audibleSongId,
                action == 'paused-next' ? null : order.first,
              );
              expect(handler.snapshot.playing, action != 'paused-next');
              await check();
              await handler.debugFlushQueuePersistence();
              expect(
                (await database.playQueueDao.getQueueItems()).map(
                  (song) => song.id,
                ),
                order,
              );
              await handler.setShuffleMode(AudioServiceShuffleMode.none);
              await settleQueue(handler);
              expect(handler.snapshot.queueSongIds, ids(count));
              expect(handler.snapshot.currentSongId, order.first);
            },
          );
        }
      }
    }

    for (final original in <List<String>>[
      ['song-0', 'song-1'],
      ['song-0', 'song-1', 'song-0', 'song-2', 'song-2'],
      ['song-0', 'song-0', 'song-0'],
    ]) {
      test('shuffled next pass preserves occurrences $original', () async {
        final players = <ControllableAudioPlayer>[];
        final (handler, _, _) = await fixture(players, count: 3);
        await handler.replaceQueue(original, expandMatchFlows: false);
        await handler.setShuffleMode(AudioServiceShuffleMode.all);
        await handler.setRepeatMode(AudioServiceRepeatMode.all);
        await handler.playFromIndex(original.length - 1);
        expect(handler.snapshot.shuffleMode, AudioServiceShuffleMode.all);
        await settleQueue(handler);
        final finished = handler.snapshot.currentSongId;
        final check = watchAudioMetadata(handler, players);
        (handler.debugActivePlayer as ControllableAudioPlayer)
            .finishCurrentTrack();
        await pumpEventQueue();
        await settleQueue(handler);
        final order = List<String>.of(handler.snapshot.queueSongIds);
        expect(order..sort(), List<String>.of(original)..sort());
        if (original.toSet().length > 1) {
          expect(handler.snapshot.currentSongId, isNot(finished));
        }
        await check();
        await handler.setShuffleMode(AudioServiceShuffleMode.none);
        await settleQueue(handler);
        expect(handler.snapshot.queueSongIds, original);
      });
    }

    test(
      'failed shuffled wrap crossfade advances through completion',
      () async {
        final players = <ControllableAudioPlayer>[];
        final (handler, _, _) = await fixture(
          players,
          count: 6,
          crossfade: true,
        );
        await handler.replaceQueue(ids(6), expandMatchFlows: false);
        await handler.setShuffleMode(AudioServiceShuffleMode.all);
        await handler.setRepeatMode(AudioServiceRepeatMode.all);
        await handler.playFromIndex(5);
        await settleQueue(handler);
        expect(handler.snapshot.shuffleMode, AudioServiceShuffleMode.all);
        final active = handler.debugActivePlayer as ControllableAudioPlayer;
        final finished = handler.snapshot.currentSongId;
        (handler.debugInactiveDeck as ControllableAudioPlayer).failPlay = true;
        final check = watchAudioMetadata(handler, players);
        await handler.debugStartCrossfade();
        await pumpEventQueue();
        expect(active.index, active.sourceIds.length - 1);
        expect(handler.snapshot.currentSongId, finished);
        active.finishCurrentTrack();
        await pumpEventQueue();
        await settleQueue(handler);
        expect(handler.snapshot.currentIndex, 0);
        expect(handler.snapshot.currentSongId, isNot(finished));
        expect(handler.snapshot.queueSongIds.toSet(), ids(6).toSet());
        await check();
      },
    );

    for (final count in [6, 300]) {
      for (final crossfade in [false, true]) {
        for (final repeat in [
          AudioServiceRepeatMode.none,
          AudioServiceRepeatMode.all,
          AudioServiceRepeatMode.one,
        ]) {
          for (final (shuffled, entity) in [
            // Toggled on after the plain replace has started (see below).
            (true, false),
            (true, true),
            // Native Repeat All must not loop the one-song fill unshuffled
            // either. Entity Shuffle always turns shuffle on.
            (false, false),
          ]) {
            test('first ${shuffled ? 'shuffled ' : ''}song completes during '
                'initial fill count=$count fade=$crossfade repeat=$repeat '
                'entity=$entity', () async {
              final players = <ControllableAudioPlayer>[];
              final (handler, player, database) = await fixture(
                players,
                count: count,
                crossfade: crossfade,
                queueWindow: const NavisQueueWindow(),
              );
              if (shuffled && entity) {
                await handler.setShuffleMode(AudioServiceShuffleMode.all);
              }
              await handler.setRepeatMode(repeat);
              final gate = Completer<void>();
              final entered = Completer<void>();
              addTearDown(() {
                if (!gate.isCompleted) gate.complete();
              });
              player
                ..appendGate = gate
                ..appendEntered = entered;
              final rows = await database.libraryDao.getSongsByIds(ids(count));
              rows.shuffle(Random(19));
              final replacing = entity
                  ? handler.replaceQueueWithData(
                      rows,
                      originalOrder: ids(count),
                      expandMatchFlows: false,
                    )
                  : handler.replaceQueue(
                      ids(count),
                      startIndex: 2,
                      expandMatchFlows: false,
                    );
              await entered.future;
              final order = List<String>.of(handler.snapshot.queueSongIds);
              // Entity Shuffle supplies the play order with the start song
              // first; a plain replace plays in order from the start song,
              // whatever the previous queue's shuffle mode was.
              final start = entity ? 0 : 2;
              expect(player.sourceIds, [order[start]]);
              expect(player.index, 0);
              final check = watchAudioMetadata(handler, players);
              player.finishCurrentTrack();
              // Only Repeat One may replay the temporary one-song playlist.
              expect(
                player.processingState,
                repeat == AudioServiceRepeatMode.one
                    ? ProcessingState.ready
                    : ProcessingState.completed,
              );
              gate.complete();
              await replacing;
              await settleQueue(handler);
              final expected =
                  order[start + (repeat == AudioServiceRepeatMode.one ? 0 : 1)];
              expect(handler.snapshot.currentSongId, expected);
              expect(player.audibleSongId, expected);
              expect(player.simulatedPosition, Duration.zero);
              expect(handler.snapshot.queueSongIds, order);
              if (shuffled && !entity) {
                // Shuffle toggled on after the plain replace shuffles around
                // the current song and restores the order when turned off.
                await handler.setShuffleMode(AudioServiceShuffleMode.all);
                await settleQueue(handler);
                expect(handler.snapshot.currentSongId, expected);
                expect(handler.snapshot.queueSongIds.first, expected);
                expect(handler.snapshot.queueSongIds.toSet(), order.toSet());
                await handler.setShuffleMode(AudioServiceShuffleMode.none);
                await settleQueue(handler);
                expect(handler.snapshot.queueSongIds, order);
                expect(handler.snapshot.currentSongId, expected);
              }
              await check();
            });
          }
        }
      }
    }

    for (final crossfade in [false, true]) {
      for (final repeat in [
        AudioServiceRepeatMode.none,
        AudioServiceRepeatMode.all,
        AudioServiceRepeatMode.one,
      ]) {
        for (final state in ['stopped', 'playing', 'paused']) {
          test(
            'entity shuffle from $state, fade=$crossfade repeat=$repeat',
            () async {
              final players = <ControllableAudioPlayer>[];
              final (handler, _, database) = await fixture(
                players,
                crossfade: crossfade,
              );
              await handler.replaceQueue(ids(60), expandMatchFlows: false);
              await handler.setRepeatMode(repeat);
              if (state == 'stopped') await handler.stop();
              if (state == 'paused') await handler.pause();
              final check = watchAudioMetadata(handler, players);
              final rows = await database.libraryDao.getSongsByIds(ids(60));
              rows.shuffle(Random(19));
              await handler.replaceQueueWithData(
                rows,
                originalOrder: ids(60),
                expandMatchFlows: false,
              );
              await settleQueue(handler);
              expect(
                handler.snapshot.queueSongIds,
                rows.map((song) => song.id),
              );
              expect(handler.snapshot.shuffleMode, AudioServiceShuffleMode.all);
              await handler.debugFlushQueuePersistence();
              expect(
                (await database.playQueueDao.getQueueState())!.shuffleMode,
                ShuffleMode.all,
              );
              final saved = await database.playQueueDao.getQueueEntries();
              final original = List.of(saved)
                ..sort((a, b) => a.originalOrder!.compareTo(b.originalOrder!));
              expect(original.map((entry) => entry.song.id), ids(60));
              await handler.setShuffleMode(AudioServiceShuffleMode.none);
              await settleQueue(handler);
              expect(handler.snapshot.queueSongIds, ids(60));
              expect(handler.snapshot.currentSongId, rows.first.id);
              await check();
            },
          );
        }

        for (final hang in [
          null,
          'removeAudioSourceRange',
          'insertAudioSources',
        ]) {
          test(
            'shuffle toggle rollback, fade=$crossfade repeat=$repeat hang=$hang',
            () async {
              final players = <ControllableAudioPlayer>[];
              final (handler, player, database) = await fixture(
                players,
                crossfade: crossfade,
              );
              await handler.replaceQueue(
                ids(60),
                startIndex: 5,
                expandMatchFlows: false,
              );
              await handler.setRepeatMode(repeat);
              final check = watchAudioMetadata(handler, players);
              if (hang == 'removeAudioSourceRange') player.hang.add(hang!);
              await handler.setShuffleMode(AudioServiceShuffleMode.all);
              await settleQueue(handler);
              if (hang == 'removeAudioSourceRange') {
                expect(
                  handler.snapshot.shuffleMode,
                  AudioServiceShuffleMode.none,
                );
                expect(handler.snapshot.queueSongIds, ids(60));
                expect(player.audibleSongId, isNull);
                expect(player.appliedVolumes.last, 0);
              } else {
                expect(
                  handler.snapshot.shuffleMode,
                  AudioServiceShuffleMode.all,
                );
                if (hang == 'insertAudioSources') {
                  await handler.playFromIndex(10);
                  await settleQueue(handler);
                  (handler.debugActivePlayer as ControllableAudioPlayer).hang
                      .add(hang!);
                }
                await handler.setShuffleMode(AudioServiceShuffleMode.none);
                await settleQueue(handler);
                if (hang == null) {
                  expect(handler.snapshot.queueSongIds, ids(60));
                } else {
                  expect(
                    handler.snapshot.shuffleMode,
                    AudioServiceShuffleMode.all,
                  );
                }
              }
              await check();
              await handler.debugFlushQueuePersistence();
              expect(
                (await database.playQueueDao.getQueueItems()).map(
                  (song) => song.id,
                ),
                handler.snapshot.queueSongIds,
              );
            },
          );
        }

        test(
          'handler shuffle plus entity shuffle restores playlist order, fade=$crossfade repeat=$repeat',
          () async {
            final players = <ControllableAudioPlayer>[];
            final (handler, _, database) = await fixture(
              players,
              crossfade: crossfade,
            );
            await handler.setShuffleMode(AudioServiceShuffleMode.all);
            final rows = await database.libraryDao.getSongsByIds(ids(60));
            rows.shuffle(Random(19));
            await handler.setRepeatMode(repeat);
            final check = watchAudioMetadata(handler, players);
            await handler.replaceQueueWithData(
              rows,
              originalOrder: ids(60),
              expandMatchFlows: false,
            );
            expect(handler.snapshot.queueSongIds, rows.map((song) => song.id));
            await handler.setShuffleMode(AudioServiceShuffleMode.none);
            await settleQueue(handler);
            expect(handler.snapshot.queueSongIds, ids(60));
            expect(handler.snapshot.currentSongId, rows.first.id);
            await check();
          },
        );

        for (final forward in [true, false]) {
          test(
            'shuffle then navigation during Phase 2, fade=$crossfade repeat=$repeat forward=$forward',
            () async {
              final players = <ControllableAudioPlayer>[];
              final (handler, player, database) = await fixture(
                players,
                crossfade: crossfade,
                count: 6,
                queueWindow: const NavisQueueWindow(),
              );
              await handler.replaceQueue(ids(6), expandMatchFlows: false);
              await handler.setShuffleMode(AudioServiceShuffleMode.all);
              await handler.setRepeatMode(repeat);
              final rows = await database.libraryDao.getSongsByIds(ids(6));
              rows.shuffle(Random(19));
              final check = watchAudioMetadata(handler, players);
              final gate = Completer<void>();
              final entered = Completer<void>();
              player
                ..appendGate = gate
                ..appendEntered = entered;
              // Entity Shuffle: the supplied play order starts at its first song.
              final replacing = handler.replaceQueueWithData(
                rows,
                originalOrder: ids(6),
                expandMatchFlows: false,
              );
              await entered.future;
              final order = List<String>.of(handler.snapshot.queueSongIds);
              if (forward) {
                await handler.skipToNext();
              } else {
                // Advance desired intent then supersede it with Previous.
                await handler.skipToNext();
                await handler.skipToPrevious();
              }
              gate.complete();
              await replacing;
              await settleQueue(handler);
              expect(handler.snapshot.currentSongId, order[forward ? 1 : 0]);
              await check();
            },
          );
        }

        test(
          'plain replace during Phase 2 after a shuffled queue plays in order, fade=$crossfade repeat=$repeat',
          () async {
            final players = <ControllableAudioPlayer>[];
            final (handler, player, _) = await fixture(
              players,
              crossfade: crossfade,
              count: 6,
              queueWindow: const NavisQueueWindow(),
            );
            await handler.replaceQueue(ids(6), expandMatchFlows: false);
            await handler.setShuffleMode(AudioServiceShuffleMode.all);
            await handler.setRepeatMode(repeat);
            final check = watchAudioMetadata(handler, players);
            final gate = Completer<void>();
            final entered = Completer<void>();
            player
              ..appendGate = gate
              ..appendEntered = entered;
            final replacing = handler.replaceQueue(
              ids(6),
              startIndex: 2,
              expandMatchFlows: false,
            );
            await entered.future;
            expect(handler.snapshot.queueSongIds, ids(6));
            expect(handler.snapshot.currentSongId, 'song-2');
            gate.complete();
            await replacing;
            await settleQueue(handler);
            expect(handler.snapshot.queueSongIds, ids(6));
            expect(handler.snapshot.currentSongId, 'song-2');
            expect(handler.snapshot.shuffleMode, AudioServiceShuffleMode.none);
            await check();
          },
        );

        test(
          'shuffle toggle during replacement waits for the new queue, fade=$crossfade repeat=$repeat',
          () async {
            final players = <ControllableAudioPlayer>[];
            final (handler, player, _) = await fixture(
              players,
              crossfade: crossfade,
              count: 6,
              queueWindow: const NavisQueueWindow(),
            );
            await handler.replaceQueue(ids(6), expandMatchFlows: false);
            await handler.setRepeatMode(repeat);
            final check = watchAudioMetadata(handler, players);
            final gate = Completer<void>();
            final entered = Completer<void>();
            player
              ..loadGate = gate
              ..loadEntered = entered;
            final replacing = handler.replaceQueue(
              ids(6),
              startIndex: 2,
              expandMatchFlows: false,
            );
            await entered.future;
            final toggle = handler.setShuffleMode(AudioServiceShuffleMode.all);
            gate.complete();
            await Future.wait([replacing, toggle]);
            await handler.setShuffleMode(AudioServiceShuffleMode.none);
            await settleQueue(handler);
            expect(handler.snapshot.queueSongIds, ids(6));
            expect(handler.snapshot.currentSongId, 'song-2');
            await check();
          },
        );
      }
    }

    for (final crossfade in [false, true]) {
      test(
        'ReplayGain applies once the selected source is loaded, fade=$crossfade',
        () async {
          final players = <ControllableAudioPlayer>[];
          final (handler, player, _) = await fixture(
            players,
            count: 3,
            crossfade: crossfade,
            replayGainMode: 'track',
            queueWindow: const NavisQueueWindow(),
            seed: (database) async {
              await (database.update(
                database.songsTable,
              )..where((song) => song.id.equals('song-0'))).write(
                const SongsTableCompanion(replayGainTrackGain: Value(-6)),
              );
              await (database.update(
                database.songsTable,
              )..where((song) => song.id.equals('song-1'))).write(
                const SongsTableCompanion(replayGainTrackGain: Value(-12)),
              );
            },
          );
          await handler.replaceQueue(['song-0'], expandMatchFlows: false);
          expect(
            player.appliedVolumes.last,
            closeTo(pow(10, -6 / 20), 0.00001),
          );
          final gate = Completer<void>();
          final entered = Completer<void>();
          player
            ..appendGate = gate
            ..appendEntered = entered;
          final check = watchAudioMetadata(handler, players);
          final replacement = handler.replaceQueue([
            'song-1',
            'song-2',
          ], expandMatchFlows: false);
          await entered.future;
          expect(handler.snapshot.hasPendingLogicalQueue, isTrue);
          // The selected source is in the player and audible, so its gain
          // applies now instead of waiting for the logical queue to commit.
          expect(
            player.appliedVolumes.last,
            closeTo(pow(10, -12 / 20), 0.00001),
          );
          gate.complete();
          await replacement;
          await settleQueue(handler);
          expect(
            player.appliedVolumes.last,
            closeTo(pow(10, -12 / 20), 0.00001),
          );
          await check();
        },
      );
    }
    for (final repeat in [
      AudioServiceRepeatMode.none,
      AudioServiceRepeatMode.all,
      AudioServiceRepeatMode.one,
    ]) {
      for (final replaceSelection in [false, true]) {
        test(
          'Shuffle cancels a crossfade, replace=$replaceSelection repeat=$repeat',
          () async {
            final players = <ControllableAudioPlayer>[];
            final (handler, player, database) = await fixture(
              players,
              crossfade: true,
              count: 6,
              queueWindow: const NavisQueueWindow(),
            );
            await handler.replaceQueue(ids(6), expandMatchFlows: false);
            await handler.setRepeatMode(repeat);
            await handler.debugStartCrossfade();
            expect(
              (handler.collectPlaybackDiagnostics()['crossfade']!
                  as Map)['active'],
              isTrue,
            );
            final rows = await database.libraryDao.getSongsByIds(ids(6));
            rows.shuffle(Random(7));
            final check = watchAudioMetadata(handler, players);
            final replacement = replaceSelection
                ? handler.replaceQueueWithData(
                    rows,
                    originalOrder: ids(6),
                    expandMatchFlows: false,
                  )
                : handler.setShuffleMode(AudioServiceShuffleMode.all);
            await pumpEventQueue();
            await replacement;
            await settleQueue(handler);
            expect(
              players.where((player) => player.audibleSongId != null),
              hasLength(1),
            );
            expect(
              player.audibleSongId,
              replaceSelection ? rows.first.id : 'song-0',
            );
            await check();
          },
        );
      }
    }

    for (final crossfade in [false, true]) {
      for (final repeat in [
        AudioServiceRepeatMode.none,
        AudioServiceRepeatMode.all,
        AudioServiceRepeatMode.one,
      ]) {
        for (final failure in ['none', 'stop', 'load']) {
          test(
            'cold remote replacement publishes selected paused metadata, fade=$crossfade repeat=$repeat failure=$failure',
            () async {
              final previousHttp = HttpOverrides.current;
              HttpOverrides.global = null;
              final server = await HttpServer.bind(
                InternetAddress.loopbackIPv4,
                0,
              );
              final requested = Completer<void>();
              final firstBytes = Completer<void>();
              server.listen((request) async {
                if (!requested.isCompleted) requested.complete();
                await firstBytes.future;
                try {
                  request.response
                    ..bufferOutput = false
                    ..contentLength = 2
                    ..add([1, 2]);
                  await request.response.close();
                } on HttpException {
                  // A timed-out/superseded probe can close its socket first.
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
              final scrobbles = NoopScrobbleService();
              final hungLoadSongs = <String>{};
              final players = <ControllableAudioPlayer>[];
              final (handler, player, database) = await fixture(
                players,
                count: 3,
                crossfade: crossfade,
                hungLoadSongs: hungLoadSongs,
                scrobbleService: scrobbles,
                api: api,
                queueWindow: const NavisQueueWindow(),
              );
              addTearDown(() async {
                if (!firstBytes.isCompleted) firstBytes.complete();
                await server.close(force: true);
                HttpOverrides.global = previousHttp;
              });
              await handler.replaceQueue(ids(3), expandMatchFlows: false);
              await handler.setRepeatMode(repeat);
              final check = watchAudioMetadata(handler, players);
              final rows = await database.libraryDao.getSongsByIds(ids(3));
              final remote = rows[1].copyWith(
                id: 'cold-external',
                isExternal: true,
              );
              await database.libraryDao.upsertSongs([
                SongsTableCompanion.insert(
                  id: remote.id,
                  title: remote.title,
                  isExternal: const Value(true),
                ),
              ]);
              if (failure == 'stop') player.hang.add('stop');
              if (failure == 'load') hungLoadSongs.add(remote.id);
              final replacement = handler.replaceQueueWithData(
                [remote, rows[2]],
                originalOrder: [remote.id, rows[2].id],
                expandMatchFlows: false,
              );
              await requested.future;
              expect(
                players.every((player) => player.audibleSongId == null),
                isTrue,
              );
              expect(handler.snapshot.currentSongId, remote.id);
              expect(handler.snapshot.playing, isFalse);
              expect(handler.playbackState.value.playing, isFalse);
              expect(handler.mediaItem.valueOrNull?.id, remote.id);
              expect(handler.snapshot.loadingSongId, remote.id);
              // Old native callbacks cannot notify or scrobble an unrelated song.
              if (failure != 'stop') {
                player.moveTo(2);
                player.playbackEvents.add(player.playbackEvent);
                player.playbackEvents.addError(StateError('old source failed'));
                await pumpEventQueue();
                expect(handler.snapshot.currentSongId, remote.id);
                expect(handler.mediaItem.valueOrNull?.id, remote.id);
                expect(scrobbles.nowPlaying, isNot(contains('song-2')));
                expect(scrobbles.submissions, isNot(contains('song-2')));
                expect(
                  handler.collectPlaybackDiagnostics()['seekEvents'],
                  isEmpty,
                );
              }
              firstBytes.complete();
              await replacement;
              if (failure == 'load') {
                if (handler.snapshot.currentSongId != 'song-2' ||
                    handler.snapshot.isLoading) {
                  await handler.snapshotStream.firstWhere(
                    (snapshot) =>
                        snapshot.currentSongId == 'song-2' &&
                        !snapshot.isLoading,
                  );
                }
                expect(player.attemptedSongId, remote.id);
                expect(player.audibleSongId, isNull);
                expect(
                  players.where((player) => player.attemptedSongId == 'song-2'),
                  isNotEmpty,
                );
              } else {
                expect(handler.snapshot.currentSongId, remote.id);
              }
              await settleQueue(handler);
              await check();
            },
          );
        }
      }
    }
    final api = SubsonicApiClient(
      baseUrl: 'http://127.0.0.1:1',
      authConfig: const SubsonicAuthConfig(
        username: 'fixture',
        password: 'synthetic',
        apiVersion: '1.16.1',
      ),
      enableLogging: false,
    );
    for (final crossfade in [false, true]) {
      for (final repeat in [
        AudioServiceRepeatMode.none,
        AudioServiceRepeatMode.all,
        AudioServiceRepeatMode.one,
      ]) {
        for (final external in [false, true]) {
          for (final timesOut in [false, true]) {
            for (final direction in ['next', 'previous', 'tap']) {
              test(
                'navigation requested occurrence, external=$external timeout=$timesOut direction=$direction fade=$crossfade repeat=$repeat',
                () async {
                  final clock = HttpOverrides.runZoned(
                    FakeAsync.new,
                    createHttpClient: (_) => ProbeClient(),
                  );
                  final players = <ControllableAudioPlayer>[];
                  final (handler, player, database) = await fixture(
                    players,
                    count: 3,
                    crossfade: crossfade,
                    clock: clock,
                    api: api,
                    queueWindow: const NavisQueueWindow(),
                    seed: (database) async {
                      if (external) {
                        await database.cacheDao.removeCachedTrack('song-1');
                        await (database.update(
                          database.songsTable,
                        )..where((song) => song.id.equals('song-1'))).write(
                          const SongsTableCompanion(isExternal: Value(true)),
                        );
                      }
                    },
                  );
                  var loaded = false;
                  final replacing = handler
                      .replaceQueue(
                        ids(3),
                        startIndex: direction == 'previous' ? 2 : 0,
                        expandMatchFlows: false,
                      )
                      .then((_) => loaded = true);
                  for (var i = 0; i < 10000 && !loaded; i++) {
                    clock.flushMicrotasks();
                    await Future<void>.delayed(Duration.zero);
                  }
                  clock.flushMicrotasks();
                  await replacing;
                  var repeatApplied = false;
                  final repeating = handler
                      .setRepeatMode(repeat)
                      .then((_) => repeatApplied = true);
                  for (var i = 0; i < 10000 && !repeatApplied; i++) {
                    clock.flushMicrotasks();
                    await Future<void>.delayed(Duration.zero);
                  }
                  await repeating;
                  final failures = <PlaybackLoadFailure>[];
                  final subscription = handler.loadFailureStream.listen(
                    failures.add,
                  );
                  addTearDown(subscription.cancel);
                  final check = watchAudioMetadata(handler, players);
                  final initialPlayerCount = players.length;
                  final gate = Completer<void>();
                  player
                    ..seekGate = gate
                    ..seekEntered = Completer<void>();
                  clock.run(
                    (_) => unawaited(switch (direction) {
                      'next' => handler.skipToNext(),
                      'previous' => handler.skipToPrevious(),
                      _ => handler.playFromIndex(1),
                    }),
                  );
                  for (
                    var i = 0;
                    i < 10000 && !player.seekEntered!.isCompleted;
                    i++
                  ) {
                    clock.flushMicrotasks();
                    clock.elapse(const Duration(milliseconds: 10));
                    await Future<void>.delayed(Duration.zero);
                  }
                  expect(player.seekEntered!.isCompleted, isTrue);
                  clock.elapse(
                    timesOut
                        ? const Duration(seconds: 6)
                        : const Duration(milliseconds: 900),
                  );
                  if (external && !timesOut) {
                    expect(handler.snapshot.loadingSongId, 'song-1');
                    expect(
                      failures.where(
                        (event) => event.operation == 'manual queue navigation',
                      ),
                      isEmpty,
                    );
                    gate.complete();
                    clock.flushMicrotasks();
                  } else {
                    expect(failures, isEmpty);
                  }
                  for (
                    var i = 0;
                    i < 10000 &&
                        (handler.snapshot.isLoading ||
                            !handler.debugQueueLaneIdle);
                    i++
                  ) {
                    clock.flushMicrotasks();
                    clock.elapse(const Duration(milliseconds: 100));
                    await Future<void>.delayed(Duration.zero);
                  }
                  clock.flushMicrotasks();
                  await settleQueue(handler);
                  expect(failures, isEmpty);
                  expect(handler.snapshot.currentSongId, 'song-1');
                  if (timesOut || !external) {
                    expect(
                      players.skip(initialPlayerCount).first.attemptedSongId,
                      'song-1',
                      reason:
                          'first rebuild must retry the requested occurrence',
                    );
                  }
                  if (!gate.isCompleted) gate.complete();
                  await check();
                  clock.elapse(const Duration(seconds: 1));
                  clock.flushMicrotasks();
                  var persisted = false;
                  final persistence = handler.debugFlushQueuePersistence().then(
                    (_) => persisted = true,
                  );
                  for (var i = 0; i < 10000 && !persisted; i++) {
                    clock.flushMicrotasks();
                    await Future<void>.delayed(Duration.zero);
                  }
                  await persistence;
                  expect(
                    (await database.playQueueDao.getQueueState())!.currentIndex,
                    1,
                  );
                },
              );
            }
          }
        }
      }
    }
  });

  group('Android Auto resume precedence', () {
    for (final (name, active, saved, recent, liked, unavailable, expected) in [
      (
        'active before saved and fallbacks',
        true,
        true,
        true,
        true,
        null,
        'song-0',
      ),
      (
        'saved before recent and liked',
        false,
        true,
        true,
        true,
        null,
        'song-1',
      ),
      ('recent before liked', false, false, true, true, null, 'song-2'),
      ('liked before radio', false, false, false, true, null, 'song-3'),
      ('radio fallback', false, false, false, false, null, 'song-4'),
      ('no available source', false, false, false, false, null, null),
      (
        'failed saved restore tries recent',
        false,
        true,
        true,
        true,
        'song-1',
        'song-2',
      ),
      (
        'unavailable recent stops fallback',
        false,
        false,
        true,
        true,
        'song-2',
        null,
      ),
      (
        'unavailable liked stops fallback',
        false,
        false,
        false,
        true,
        'song-3',
        null,
      ),
    ]) {
      test(name, () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-resume-',
        );
        final radioRequests = <bool>[];
        late NavisAudioHandler radioHandler;
        final (handler, player, database) = await createHandler(
          directory,
          5,
          readCanStream: () => false,
          startPersonalRadio: ({required autoPlay, isCurrent}) async {
            radioRequests.add(autoPlay);
            if (expected != 'song-4') return false;
            await radioHandler.replaceQueue(
              ['song-4'],
              autoPlay: autoPlay,
              expandMatchFlows: false,
            );
            expect(radioHandler.snapshot.playing, isTrue);
            return true;
          },
        );
        radioHandler = handler;
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        if (active) {
          await handler.replaceQueue(['song-0'], autoPlay: false);
          await handler.debugFlushQueuePersistence();
        }
        if (saved) {
          await database.playQueueDao.saveQueue(
            songIds: ['song-1'],
            currentIndex: 0,
          );
        }
        if (recent) await database.historyDao.addPlayHistory('song-2');
        if (liked) {
          await database.libraryDao.setEntityStarred(
            'song',
            'song-3',
            DateTime.now(),
          );
        }
        if (unavailable != null) {
          final cached = await database.cacheDao.getCachedTrack(unavailable);
          await File(cached!.filePath).delete();
        }

        if (unavailable == 'song-2' || unavailable == 'song-3') {
          await expectLater(
            handler.play(),
            throwsA(isA<PlaybackSourceUnavailableException>()),
          );
        } else {
          await handler.play();
        }

        expect(handler.snapshot.currentSongId, expected);
        expect(player.playing, expected != null);
        expect(
          radioRequests,
          !active && !saved && !recent && !liked ? [true] : isEmpty,
        );
        if (expected == null && unavailable == null) {
          expect(
            handler.playbackState.value.processingState,
            AudioProcessingState.error,
          );
        }
      });
    }
  });

  group('Android Auto voice genres', () {
    Future<(NavisAudioHandler, NavisDatabase)> genreHandler() async {
      final directory = await Directory.systemTemp.createTemp('navis-auto-g-');
      final (handler, _, database) = await createHandler(
        directory,
        11,
        seed: (database) async {
          Future<void> tag(int i, String title, List<String> genres) =>
              database.libraryDao.upsertSongs([
                SongsTableCompanion.insert(
                  id: 'song-$i',
                  title: title,
                  genres: Value<List<String>?>(genres),
                ),
              ]);
          await tag(0, 'Song 0', ['Jazz']);
          await tag(1, 'Song 1', ['Jazz', 'Blues']);
          await tag(2, 'Song 2', ['Hip-Hop', 'Rock']);
          await tag(3, 'Song 3', ['World Music']);
          await tag(4, 'Song 4', ['Jazz']);
          await tag(5, 'Rock', ['Pop']);
          // A genre named like an artist ("Queen") and like an album ("Blues").
          await tag(6, 'Song 6', ['Queen']);
          await tag(7, 'Song 7', ['Pop']);
          await tag(8, 'Song 8', ['Pop']);
          await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
            ArtistsTableCompanion.insert(id: 'artist-q', name: 'Queen'),
          ]);
          await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
            AlbumsTableCompanion.insert(
              id: 'album-q',
              name: 'Hits',
              artistId: const Value('artist-q'),
            ),
            AlbumsTableCompanion.insert(id: 'album-b', name: 'Blues'),
          ]);
          for (final (song, album) in [
            ('song-7', 'album-q'),
            ('song-8', 'album-b'),
          ]) {
            await (database.update(database.songsTable)
                  ..where((row) => row.id.equals(song)))
                .write(SongsTableCompanion(albumId: Value(album)));
          }
        },
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      return (handler, database);
    }

    final jazz = <String>['song-0', 'song-1', 'song-4'];

    for (final query in ['jazz', 'Jazz Music', 'JAZZ']) {
      test(
        '"$query" plays the genre shuffled through the normal queue',
        () async {
          final (handler, _) = await genreHandler();
          await handler.prepareFromSearch(query);
          await settleQueue(handler);
          expect(
            handler.snapshot.queueSongIds,
            List<String>.of(jazz)..shuffle(Random(7)),
          );
        },
      );
    }

    test('a spelling variant of the name matches by its key', () async {
      final (handler, _) = await genreHandler();
      await handler.prepareFromSearch('hip hop');
      await settleQueue(handler);
      expect(handler.snapshot.queueSongIds, ['song-2']);
    });

    test('a genre named with "music" matches as spoken', () async {
      final (handler, _) = await genreHandler();
      await handler.prepareFromSearch('world music');
      await settleQueue(handler);
      expect(handler.snapshot.queueSongIds, ['song-3']);
    });

    test('an exact song title still wins over a genre of that name', () async {
      final (handler, _) = await genreHandler();
      await handler.prepareFromSearch('rock');
      await settleQueue(handler);
      expect(handler.snapshot.queueSongIds, ['song-5']);
    });

    test('an exact artist name wins over a genre of that name', () async {
      final (handler, _) = await genreHandler();
      await handler.prepareFromSearch('queen');
      await settleQueue(handler);
      expect(handler.snapshot.queueSongIds, ['song-7']);
    });

    test('an exact artist without songs falls through to the genre', () async {
      final (handler, database) = await genreHandler();
      await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(id: 'artist-j', name: 'Jazz'),
      ]);
      await handler.prepareFromSearch('jazz');
      await settleQueue(handler);
      expect(
        handler.snapshot.queueSongIds,
        List<String>.of(jazz)..shuffle(Random(7)),
      );
    });

    test('an exact artist name matches without accents', () async {
      final (handler, database) = await genreHandler();
      await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(id: 'artist-be', name: 'Beyoncé'),
      ]);
      await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(
          id: 'album-be',
          name: 'B Day',
          artistId: const Value('artist-be'),
        ),
      ]);
      await database.libraryDao.upsertSongs([
        SongsTableCompanion.insert(
          id: 'song-9',
          title: 'Halo',
          artistId: const Value('artist-be'),
          albumId: const Value('album-be'),
          genres: const Value<List<String>?>(['Beyonce']),
        ),
        SongsTableCompanion.insert(
          id: 'song-10',
          title: 'Other',
          genres: const Value<List<String>?>(['Beyonce']),
        ),
      ]);
      await handler.prepareFromSearch('beyonce');
      await settleQueue(handler);
      expect(handler.snapshot.queueSongIds, ['song-9']);
    });

    test('an exact album name wins over a genre of that name', () async {
      final (handler, _) = await genreHandler();
      await handler.prepareFromSearch('Blues');
      await settleQueue(handler);
      expect(handler.snapshot.queueSongIds, ['song-8']);
    });

    test('a genre extra plays the genre even with an empty query', () async {
      final (handler, _) = await genreHandler();
      await handler.prepareFromSearch('', {
        AndroidAutoConstants.mediaFocusKey:
            AndroidAutoConstants.mediaFocusGenre,
        AndroidAutoConstants.mediaGenreKey: 'Jazz',
      });
      await settleQueue(handler);
      expect(
        handler.snapshot.queueSongIds,
        List<String>.of(jazz)..shuffle(Random(7)),
      );
    });

    test('a failing genre lookup falls back to the normal search', () async {
      final (handler, database) = await genreHandler();
      await database.customStatement('DROP TABLE song_genre_index');
      // Not an exact title, so the genre lookup runs (and throws) first.
      await handler.prepareFromSearch('Song');
      await settleQueue(handler);
      expect(handler.snapshot.queueSongIds, isNotEmpty);
    });

    test('a spoken name that is not a genre keeps the normal search', () async {
      final (handler, _) = await genreHandler();
      await handler.prepareFromSearch('Song 3');
      await settleQueue(handler);
      expect(handler.snapshot.queueSongIds, ['song-3']);
    });
  });

  group('Android Auto collections', () {
    for (final crossfade in [false, true]) {
      test(
        'Shuffle liked preserves collection order, fade=$crossfade',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'navis-auto-shuffle-',
          );
          final players = <ControllableAudioPlayer>[];
          final (handler, _, database) = await createHandler(
            directory,
            6,
            crossfade: crossfade,
            players: players,
            seed: (database) async {
              for (var i = 0; i < 6; i++) {
                await database.libraryDao.setEntityStarred(
                  'song',
                  'song-$i',
                  DateTime(2026, 1, i + 1),
                );
              }
            },
          );
          addTearDown(() async {
            await handler.disposeHandler();
            await database.close();
            await directory.delete(recursive: true);
          });
          final original =
              (await database.libraryDao.watchAllStarredSongs().first)
                  .map((song) => song.id)
                  .toList();
          // This is the only Shuffle liked permutation; the handler must not
          // shuffle it again or save its random ranks as the original order.
          final expected = List<String>.of(original)..shuffle(Random(7));
          await handler.setShuffleMode(AudioServiceShuffleMode.all);
          final check = watchAudioMetadata(handler, players);
          await handler.prepareFromMediaId(AutoMediaRoot.shuffleLiked);
          await settleQueue(handler);
          expect(handler.snapshot.queueSongIds, expected);
          expect(handler.snapshot.playing, isFalse);
          await check();
          final restoreCheck = watchAudioMetadata(handler, players);
          await handler.setShuffleMode(AudioServiceShuffleMode.none);
          await settleQueue(handler);
          expect(handler.snapshot.queueSongIds, original);
          expect(handler.snapshot.currentSongId, expected.first);
          await restoreCheck();
        },
      );
    }

    for (final (type, root, order) in [
      (AutoMediaContextType.downloads, AutoMediaRoot.downloads, [2, 1, 0]),
      (AutoMediaContextType.liked, AutoMediaRoot.likedSongs, [2, 0]),
      (AutoMediaContextType.recent, AutoMediaRoot.recent, [2, 0]),
    ]) {
      for (final contextual in [false, true]) {
        test('${type.name} collection (contextual=$contextual)', () async {
          final directory = await Directory.systemTemp.createTemp(
            'navis-auto-',
          );
          final (handler, player, database) = await createHandler(
            directory,
            3,
            seed: (database) async {
              await database.libraryDao.upsertSongs([
                for (var i = 0; i < 3; i++)
                  SongsTableCompanion.insert(
                    id: 'song-$i',
                    title: 'Song $i',
                    createdAt: Value(DateTime(2026, 1, i + 1)),
                  ),
              ]);
              for (final i in [0, 2]) {
                await database.libraryDao.setEntityStarred(
                  'song',
                  'song-$i',
                  DateTime(2026, 1, i + 1),
                );
                await database
                    .into(database.playHistoryTable)
                    .insert(
                      PlayHistoryTableCompanion.insert(
                        songId: 'song-$i',
                        playedAt: DateTime(2026, 1, i + 1),
                      ),
                    );
              }
            },
          );
          addTearDown(() async {
            await handler.disposeHandler();
            await database.close();
            await directory.delete(recursive: true);
          });

          await handler.prepareFromMediaId(
            contextual
                ? AutoMediaId.song('song-0', contextType: type, contextId: root)
                : root,
          );

          expect(handler.snapshot.queueSongIds, [
            for (final i in order) 'song-$i',
          ]);
          expect(
            handler.snapshot.currentSongId,
            contextual ? 'song-0' : 'song-2',
          );
          expect(player.playing, isFalse);
        });
      }
    }
  });

  test('Previous restarts the first queue song within three seconds', () async {
    final directory = await Directory.systemTemp.createTemp('navis-previous-');
    final (handler, player, database) = await createHandler(directory, 2);
    addTearDown(() async {
      await handler.disposeHandler();
      await database.close();
      await directory.delete(recursive: true);
    });
    await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
    player.simulatedPosition = const Duration(seconds: 2);
    final cues = <TransportVisualCue>[];
    final subscription = handler.transportVisualCueStream.listen(cues.add);
    addTearDown(subscription.cancel);
    await handler.skipToPrevious();
    await Future<void>.delayed(Duration.zero);
    expect(handler.snapshot.currentSongId, 'song-0');
    expect(player.position, Duration.zero);
    expect(cues.last.intent, TransportVisualIntent.restartCurrent);
    expect(
      navisResolvePreviousTrackAction(
        queueLength: 2,
        currentIndex: 0,
        position: const Duration(seconds: 2),
      ),
      NavisPreviousTrackAction.restartCurrent,
    );
  });

  for (final noisy in [false, true]) {
    test('session pause stops both crossfade decks (noisy=$noisy)', () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-interrupted-fade-',
      );
      final (handler, player, database) = await createHandler(
        directory,
        3,
        crossfade: true,
      );
      final session = TestAudioSession();
      handler.debugWireAudioSession(session);
      addTearDown(() async {
        await handler.disposeHandler();
        await session.close();
        await database.close();
        await directory.delete(recursive: true);
      });
      await handler.replaceQueue([
        'song-0',
        'song-1',
        'song-2',
      ], expandMatchFlows: false);
      await handler.debugStartCrossfade();
      final deck = handler.debugInactiveDeck!;
      expect(deck.playing, isTrue);
      if (noisy) {
        session.noisy.add(null);
      } else {
        session.interruptions.add(
          AudioInterruptionEvent(true, AudioInterruptionType.pause),
        );
      }
      await Future<void>.delayed(Duration.zero);
      expect(player.playing, isFalse);
      expect(deck.playing, isFalse);
      expect(
        (handler.collectPlaybackDiagnostics()['crossfade']! as Map)['active'],
        isFalse,
      );
      if (!noisy) {
        session.interruptions.add(
          AudioInterruptionEvent(false, AudioInterruptionType.pause),
        );
        await Future<void>.delayed(Duration.zero);
        expect(player.playing, isTrue);
        expect(deck.playing, isFalse);
      }
    });
  }

  for (final (master, host, allowed) in [
    (false, 'foreign.example', false),
    (true, 'foreign.example', true),
    (false, 'SERVER.example', true),
  ]) {
    test('radio playback policy master=$master host=$host', () async {
      final directory = await Directory.systemTemp.createTemp('radio-policy-');
      final (handler, player, database) = await createHandler(
        directory,
        0,
        readRadioPlaybackAllowed: (stream) =>
            master || stream.host.toLowerCase() == 'server.example',
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final stops = player.stopCalls;
      final result = handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: 'https://$host/live',
      );
      if (allowed) {
        await result;
        expect(handler.snapshot.radioStation?.stationId, 'fixture');
      } else {
        await expectLater(
          result,
          throwsA(isA<RadioPlaybackBlockedException>()),
        );
        expect(player.stopCalls, stops);
        expect(handler.snapshot.radioStation, isNull);
      }
    });
  }

  for (final pauseDuring in [false, true]) {
    test(
      'interruption resume respects explicit Pause ($pauseDuring)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-interruption-',
        );
        final (handler, player, database) = await createHandler(directory, 1);
        final session = TestAudioSession();
        handler.debugWireAudioSession(session);
        addTearDown(() async {
          await handler.disposeHandler();
          expect(session.interruptions.hasListener, isFalse);
          expect(session.noisy.hasListener, isFalse);
          await session.close();
          await database.close();
          await directory.delete(recursive: true);
        });
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        session.interruptions.add(
          AudioInterruptionEvent(true, AudioInterruptionType.pause),
        );
        await Future<void>.delayed(Duration.zero);
        expect(player.playing, isFalse);
        if (pauseDuring) {
          await handler.pause();
        }
        session.interruptions.add(
          AudioInterruptionEvent(false, AudioInterruptionType.pause),
        );
        await Future<void>.delayed(Duration.zero);
        expect(player.playing, !pauseDuring);
        await handler.setVolume(0.8);
        player.appliedVolumes.clear();
        session.interruptions.add(
          AudioInterruptionEvent(true, AudioInterruptionType.duck),
        );
        await Future<void>.delayed(Duration.zero);
        session.interruptions.add(
          AudioInterruptionEvent(false, AudioInterruptionType.duck),
        );
        await Future<void>.delayed(Duration.zero);
        expect(player.appliedVolumes, [closeTo(0.32, 0.0001), 0.8]);
        handler.beginTeardown();
        await handler.disposeHandler();
      },
    );
  }

  for (final mediaClick in [false, true]) {
    test(
      'system pause during interruption sticks (click: $mediaClick)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-system-interruption-',
        );
        final (handler, player, database) = await createHandler(directory, 1);
        final system = RealTimeProjectionAudioHandler(handler);
        final session = TestAudioSession();
        handler.debugWireAudioSession(session);
        addTearDown(() async {
          await handler.disposeHandler();
          await system.dispose();
          await session.close();
          await database.close();
          await directory.delete(recursive: true);
        });
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        session.interruptions.add(
          AudioInterruptionEvent(true, AudioInterruptionType.pause),
        );
        await Future<void>.delayed(Duration.zero);
        expect(player.playing, isFalse);

        if (mediaClick) {
          await system.click();
        } else {
          await system.pause();
        }
        expect(player.playing, isFalse);
        session.interruptions.add(
          AudioInterruptionEvent(false, AudioInterruptionType.pause),
        );
        await Future<void>.delayed(Duration.zero);
        expect(player.playing, isFalse);

        await system.click();
        expect(player.playing, isTrue);
        await system.click();
        expect(player.playing, isFalse);
      },
    );
  }

  test(
    'mobile bootstrap rebuilds after begin then dispose in one process',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-reconnect-',
      );
      final fixtures =
          <(NavisAudioHandler, ControllableAudioPlayer, NavisDatabase)>[];
      final database = createTestDatabase();
      final cache = MockSystemArtCache();
      final services = <SwitchAudioHandler>[];
      final projections = <RealTimeProjectionAudioHandler>[];
      final container = ProviderContainer(
        overrides: [
          audioHandlerInitializerProvider.overrideWithValue(() async {
            final fixture = await createHandler(
              directory,
              1,
              sharedDatabase: database,
            );
            fixtures.add(fixture);
            final initialized = await initNavisAudioServiceHandler(
              builder: () {
                final projection = RealTimeProjectionAudioHandler(fixture.$1);
                projections.add(projection);
                return projection;
              },
              cacheManager: cache,
            );
            services.add(initialized.service);
            return initialized.handler;
          }),
        ],
      );
      addTearDown(() async {
        await container
            .read(audioBootstrapControllerProvider.notifier)
            .abortForSessionTeardown();
        container.dispose();
        for (final (handler, _, _) in fixtures) {
          await handler.disposeHandler();
        }
        await database.close();
        await directory.delete(recursive: true);
      });
      final bootstrap = container.read(
        audioBootstrapControllerProvider.notifier,
      );
      await bootstrap.retry();
      expect(container.read(audioBootstrapControllerProvider).isReady, isTrue);
      final first = fixtures.single.$1;
      final projectionClosed = projections.single.playbackState
          .listen((_) {})
          .asFuture<void>();
      await first.replaceQueue(['song-0'], expandMatchFlows: false);
      await bootstrap.abortForSessionTeardown();
      expect(container.read(audioHandlerProvider), isNull);
      await projectionClosed.timeout(const Duration(seconds: 1));
      expect(services.single.inner, isA<BaseAudioHandler>());

      bootstrap.ensureInitialized();
      await Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return !container.read(audioBootstrapControllerProvider).isReady;
      }).timeout(const Duration(seconds: 2));

      expect(container.read(audioBootstrapControllerProvider).isReady, isTrue);
      final rebuilt = container.read(audioHandlerProvider)!;
      expect(rebuilt, isNot(same(first)));
      await rebuilt.waitUntilReady();
      await rebuilt.replaceQueue(['song-0'], expandMatchFlows: false);
      expect(fixtures.last.$2.playing, isTrue);
      expect(services.last, same(services.first));
      await services.last.pause();
      expect(fixtures.last.$2.playing, isFalse);
      await services.last.click();
      expect(fixtures.last.$2.playing, isTrue);
    },
  );

  test(
    'mobile bootstrap completions retain their own session handler',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-init-race-',
      );
      final database = createTestDatabase();
      final first = await createHandler(directory, 1, sharedDatabase: database);
      final second = await createHandler(
        directory,
        1,
        sharedDatabase: database,
      );
      final projections = [
        RealTimeProjectionAudioHandler(first.$1),
        RealTimeProjectionAudioHandler(second.$1),
      ];
      addTearDown(() async {
        for (final (handler, _, _) in [first, second]) {
          await disposeNavisPlaybackHandler(handler);
        }
        await database.close();
        await directory.delete(recursive: true);
      });
      final initializations = await Future.wait([
        for (final projection in projections)
          initNavisAudioServiceHandler(
            builder: () => projection,
            cacheManager: MockSystemArtCache(),
          ),
      ]);
      expect(initializations.first.handler, same(first.$1));
      expect(initializations.last.handler, same(second.$1));
      expect(initializations.first.service, same(initializations.last.service));
      final closed = projections.first.queue.listen((_) {}).asFuture<void>();

      beginNavisPlaybackHandlerTeardown(first.$1);
      await disposeNavisPlaybackHandler(first.$1);

      await closed.timeout(const Duration(seconds: 1));
      expect(initializations.last.service.inner, same(projections.last));
      await second.$1.replaceQueue(['song-0'], expandMatchFlows: false);
      await initializations.last.service.pause();
      expect(second.$2.playing, isFalse);
    },
  );

  test(
    'a cleared cover file is downloaded once and republished with art',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-stale-art-',
      );
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => directory.path);
      PlaybackArtCache.resetKeyForTesting();
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        PlaybackArtCache.resetKeyForTesting();
      });
      await PlaybackArtCache.initializeKey(supportDirectory: directory);
      final art = JpegArtworkService();
      final (handler, _, database) = await createHandler(
        directory,
        3,
        sidecarStreams: true,
        artworkFileService: art,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
      });
      await database.libraryDao.upsertSongs([
        for (final id in ['song-0', 'song-1', 'song-2'])
          SongsTableCompanion.insert(
            id: id,
            title: id,
            duration: const Value(300),
            coverArt: Value('cover-$id'),
          ),
      ]);
      final projection = RealTimeProjectionAudioHandler(
        handler,
        systemArt: AndroidSystemArt(
          authority: 'app.test.artwork',
          fetch: handler.cacheSystemArtwork,
          cachedPath: handler.cachedSystemArtwork,
        ),
      );
      addTearDown(projection.dispose);
      final published = <MediaItem?>[];
      final sub = projection.mediaItem.listen(published.add);
      addTearDown(sub.cancel);

      await handler.replaceQueue(
        ['song-0', 'song-1', 'song-2'],
        startIndex: 0,
        expandMatchFlows: false,
      );
      await settleQueue(handler);
      await handler.play();
      for (
        var i = 0;
        i < 300 &&
            !(published.isNotEmpty &&
                published.last?.artUri?.scheme == 'content');
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(published.last?.artUri?.scheme, 'content');
      final file = File(published.last!.extras!['artCacheFile']! as String);
      expect(file.existsSync(), isTrue);

      // Move to song-1 and wait for its art, then delete song-0's file (Android
      // clears cacheDir) and come back to song-0.
      await handler.skipToQueueItem(1);
      await settleQueue(handler);
      for (
        var i = 0;
        i < 300 &&
            !(published.last?.id == 'song-1' &&
                published.last?.artUri?.scheme == 'content');
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      file.deleteSync();
      final getsBefore = art.gets;
      await handler.skipToQueueItem(0);
      await settleQueue(handler);
      await pumpEventQueue(times: 200);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await pumpEventQueue(times: 200);
      expect(art.gets - getsBefore, 1);
      expect(file.existsSync(), isTrue);
      final last = projection.mediaItem.value!;
      expect(last.id, 'song-0');
      expect(last.artUri?.scheme, 'content');
      expect(last.extras?['artCacheFile'], file.path);
    },
  );

  test(
    'begin then dispose closes all handler streams and browse parents',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-teardown-',
      );
      final artwork = TeardownArtworkService();
      final (handler, player, database) = await createHandler(
        directory,
        1,
        crossfade: true,
        artworkFileService: artwork,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final closed = <Future<void>>[
        for (final stream in <Stream<dynamic>>[
          handler.snapshotStream,
          handler.playbackAdjustmentsStream,
          handler.equalizerStateStream,
          handler.transportVisualCueStream,
          handler.positionStream,
          handler.bufferStateStream,
          handler.radioStreamErrorStream,
          handler.loadFailureStream,
          handler.droppedSongsStream,
          handler.subscribeToChildren('root'),
          handler.subscribeToChildren('root/recent'),
          handler.subscribeToChildren(AudioService.recentRootId),
        ])
          stream.listen((_) {}).asFuture<void>(),
      ];
      handler.beginTeardown();
      expect(player.stopCalls, 1);
      expect(
        artwork.closed,
        Platform.isAndroid || Platform.isLinux || Platform.isWindows,
      );
      final disposal = handler.disposeHandler();
      await disposal;
      await Future.wait(closed).timeout(const Duration(seconds: 1));
      expect(identical(disposal, handler.disposeHandler()), isTrue);
      expect(player.indexEvents.hasListener, isFalse);
      expect(handler.debugInactiveDeck, isNull);
    },
  );

  test(
    'desktop diagnostics expose bytes from the active sidecar attempt',
    () async {
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final release = Completer<void>();
      server.listen((request) async {
        try {
          request.response
            ..bufferOutput = false
            ..contentLength = 100 * 1024
            ..add(List<int>.filled(40 * 1024, 1));
          await request.response.flush();
          await release.future;
          request.response.add(List<int>.filled(60 * 1024, 1));
          await request.response.close();
        } on HttpException {
          // The handler cancels the unfinished transfer at teardown.
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
      final directory = await Directory.systemTemp.createTemp(
        'navis-sidecar-bytes-',
      );
      final (handler, _, database) = await createHandler(
        directory,
        1,
        sidecarStreams: true,
        readApiClient: () => api,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        release.complete();
        await database.close();
        await server.close(force: true);
        await directory.delete(recursive: true);
        HttpOverrides.global = previousHttp;
      });
      await handler.replaceQueue(['song-0'], expandMatchFlows: false);
      for (var attempt = 0; attempt < 400; attempt++) {
        final activity = handler.collectPlaybackDiagnostics()['cacheActivity'];
        if (activity is Map && (activity['progress'] as num) >= 0.4) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final diagnostics = handler.collectPlaybackDiagnostics();
      expect(diagnostics['cacheActivity'], isNotNull);
      expect(diagnostics['partialCacheBytes'], 40 * 1024);
    },
  );

  group('desktop next-song prefetch', () {
    const size = 8 * 1024;
    Future<
      ({
        NavisAudioHandler handler,
        ControllableAudioPlayer player,
        RollingCacheSidecarDownloader downloader,
        List<String> requests,
        Completer<void> release,
        List<bool> gate,
      })
    >
    serveQueue(
      int count, {
      bool allowed = true,
      Set<String> hold = const <String>{},
      Set<String> failFirst = const <String>{},
      Future<void> Function(NavisDatabase)? seed,
      int startIndex = 0,
      Future<void> Function(NavisAudioHandler)? beforePlay,
    }) async {
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final release = Completer<void>();
      final requests = <String>[];
      final gate = <bool>[allowed];
      server.listen((request) async {
        final id = request.uri.queryParameters['id']!;
        requests.add(id);
        if (failFirst.contains(id) &&
            requests.where((r) => r == id).length == 1) {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
          return;
        }
        try {
          request.response
            ..bufferOutput = false
            ..headers.contentType = ContentType('audio', 'mpeg')
            ..contentLength = size;
          if (hold.contains(id)) {
            request.response.add(List<int>.filled(size ~/ 2, 1));
            await request.response.flush();
            await release.future;
            request.response.add(List<int>.filled(size ~/ 2, 1));
          } else {
            request.response.add(List<int>.filled(size, 1));
          }
          await request.response.close();
        } on Object {
          // The handler cancels unfinished transfers at teardown.
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
      final directory = await Directory.systemTemp.createTemp(
        'navis-prefetch-',
      );
      final downloader = RollingCacheSidecarDownloader();
      final (handler, player, database) = await createHandler(
        directory,
        count,
        sidecarStreams: true,
        positionStreams: true,
        sidecarDownloader: downloader,
        readApiClient: () => api,
        nextSongPrefetchAllowed: allowed,
        readNextSongPrefetchAllowed: () => gate.first,
        seed: seed,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        if (!release.isCompleted) release.complete();
        await database.close();
        await server.close(force: true);
        await directory.delete(recursive: true);
        HttpOverrides.global = previousHttp;
      });
      await beforePlay?.call(handler);
      await handler.replaceQueue(
        [for (var i = 0; i < count; i++) 'song-$i'],
        startIndex: startIndex,
        expandMatchFlows: false,
      );
      return (
        handler: handler,
        player: player,
        downloader: downloader,
        requests: requests,
        release: release,
        gate: gate,
      );
    }

    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 600 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(condition(), isTrue);
    }

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 400));

    test('the next song downloads once the current one completes', () async {
      final s = await serveQueue(3);
      await until(() => s.requests.contains('song-1'));
      await settle();
      expect(s.requests, ['song-0', 'song-1']);
      final next = s.handler.queue.value[1].extras!['sidecarCacheFilePath'];
      expect(File(next as String).existsSync(), isTrue);
    });

    test('no next-song download when prefetch is not allowed', () async {
      final s = await serveQueue(3, allowed: false);
      final first = s.handler.queue.value[0].extras!['sidecarCacheFilePath'];
      await until(() => File(first as String).existsSync());
      await settle();
      expect(s.requests, ['song-0']);
    });

    test('a next song that is already downloaded is not fetched', () async {
      final s = await serveQueue(
        3,
        seed: (database) async {
          final dir = await Directory.systemTemp.createTemp('navis-warm-');
          final file = File('${dir.path}/song-1.mp3')
            ..writeAsBytesSync(<int>[1, 2, 3]);
          await database.cacheDao.upsertCachedTrack(
            CachedTracksTableCompanion.insert(
              songId: 'song-1',
              filePath: file.path,
              fileSize: 3,
              format: 'mp3',
              cacheType: CacheType.permanent,
              downloadStatus: DownloadStatus.complete,
              lastAccessedAt: DateTime.now(),
            ),
          );
        },
      );
      final first = s.handler.queue.value[0].extras!['sidecarCacheFilePath'];
      await until(() => File(first as String).existsSync());
      await settle();
      expect(s.requests, ['song-0']);
    });

    test('Repeat One warms nothing', () async {
      final s = await serveQueue(
        3,
        beforePlay: (handler) =>
            handler.setRepeatMode(AudioServiceRepeatMode.one),
      );
      final first = s.handler.queue.value[0].extras!['sidecarCacheFilePath'];
      await until(() => File(first as String).existsSync());
      await settle();
      expect(s.requests, ['song-0']);
    });

    test('Repeat All at the last song warms the first song', () async {
      final s = await serveQueue(
        2,
        startIndex: 1,
        beforePlay: (handler) =>
            handler.setRepeatMode(AudioServiceRepeatMode.all),
      );
      await until(() => s.requests.contains('song-0'));
      expect(s.requests, ['song-1', 'song-0']);
    });

    test('shuffle warms the next song in play order', () async {
      final s = await serveQueue(
        6,
        beforePlay: (handler) =>
            handler.setShuffleMode(AudioServiceShuffleMode.all),
      );
      final queue = s.handler.queue.value;
      await until(() => s.requests.length >= 2);
      final current = s.handler.mediaItem.value!.id;
      final at = queue.indexWhere((item) => item.id == current);
      expect(s.requests, [current, queue[at + 1].id]);
    });

    test(
      'the chained download continues when its song becomes current',
      () async {
        final s = await serveQueue(3, hold: {'song-1'});
        await until(() => s.downloader.activeSongId == 'song-1');
        await until(() => s.downloader.activeReceivedBytes == size ~/ 2);
        s.player.moveTo(1);
        await pumpEventQueue();
        expect(s.downloader.activeSongId, 'song-1');
        expect(s.downloader.activeReceivedBytes, size ~/ 2);
        s.release.complete();
        await settle();
        expect(s.requests.where((id) => id == 'song-1'), hasLength(1));
      },
    );

    test(
      're-publishing the finished current song keeps the warm running',
      () async {
        final s = await serveQueue(3, hold: {'song-1'});
        await until(() => s.downloader.activeReceivedBytes == size ~/ 2);
        final part = s.downloader.activePartFilePath;
        // Dropping the last song keeps next = song-1 and re-publishes song-0.
        await s.handler.removeQueueItemAt(2);
        await pumpEventQueue();
        expect(s.downloader.activeSongId, 'song-1');
        expect(s.downloader.activePartFilePath, part);
        expect(s.downloader.activeReceivedBytes, size ~/ 2);
        s.release.complete();
        await settle();
        expect(s.requests, ['song-0', 'song-1']);
      },
    );

    test('turning the gate off cancels an in-flight warm', () async {
      final s = await serveQueue(3, hold: {'song-1'});
      await until(() => s.downloader.activeReceivedBytes == size ~/ 2);
      s.gate[0] = false;
      await s.handler.removeQueueItemAt(2);
      await until(() => s.downloader.activeSongId == null);
      s.release.complete();
      await settle();
      expect(s.requests, ['song-0', 'song-1']);
    });

    test('a warm that failed is retried after the retry delay', () async {
      sidecarChainRetryDelay = const Duration(milliseconds: 150);
      addTearDown(() => sidecarChainRetryDelay = const Duration(seconds: 30));
      final s = await serveQueue(3, failFirst: {'song-1'});
      s.player.simulateProgress = true;
      s.player.emitPlayerEvent();
      await until(() => s.requests.contains('song-1'));
      await settle();
      // Position ticks must retry without a queue edit clearing the pair key.
      await until(() => s.requests.where((id) => id == 'song-1').length == 2);
    });

    test('a failed pair does not block the next pair', () async {
      final s = await serveQueue(4, failFirst: {'song-1'});
      await until(() => s.requests.contains('song-1'));
      await settle();
      s.player.moveTo(2);
      await until(() => s.requests.contains('song-3'));
    });

    test(
      'refilling a deleted current file immediately re-arms the warm',
      () async {
        final s = await serveQueue(3, hold: {'song-1'});
        await until(() => s.downloader.activeSongId == 'song-1');
        await until(() => s.downloader.activeReceivedBytes == size ~/ 2);
        final path =
            s.handler.queue.value[0].extras!['sidecarCacheFilePath']! as String;
        await until(() => File(path).existsSync());
        await settle();
        await File(path).delete();
        await s.handler.removeQueueItemAt(2);
        await until(() => s.requests.where((id) => id == 'song-0').length == 2);
        await until(() => File(path).existsSync());
        await settle();
        expect(s.requests, ['song-0', 'song-1', 'song-0', 'song-1']);
        expect(s.downloader.activeSongId, 'song-1');
        await until(() => s.downloader.activeReceivedBytes == size ~/ 2);
        s.release.complete();
      },
    );

    for (final (repeat, index, kept) in [
      (RepeatMode.off, 1, {1, 2}),
      (RepeatMode.one, 1, {1}),
      (RepeatMode.all, 2, {2, 0}),
    ]) {
      test(
        'startup eviction protects saved shuffled files with ${repeat.name}',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'navis-startup-keep-',
          );
          final paths = <String>[];
          final restore = Completer<void>();
          final (handler, _, database) = await createHandler(
            directory,
            3,
            cacheSongs: false,
            savedQueueIndex: index,
            rollingCacheBudgetBytes: 1,
            waitForReady: false,
            createPlayQueueDao: (db) =>
                GatedQueueEntriesDao(db, restore.future),
            seed: (database) async {
              await database.playQueueDao.saveQueue(
                songIds: ['song-0', 'song-1', 'song-2'],
                currentIndex: index,
                repeatMode: repeat,
                shuffleMode: ShuffleMode.all,
                originalOrder: [2, 0, 1],
              );
              for (var i = 0; i < 3; i++) {
                final path = p.join(directory.path, 'song-$i.mp3');
                paths.add(path);
                await File(path).writeAsBytes([1, 2, 3]);
                await database.cacheDao.upsertCachedTrack(
                  CachedTracksTableCompanion.insert(
                    songId: 'song-$i',
                    filePath: path,
                    fileSize: 3,
                    format: 'mp3',
                    cacheType: CacheType.rolling,
                    downloadStatus: DownloadStatus.complete,
                    lastAccessedAt: DateTime.now(),
                  ),
                );
              }
            },
          );
          addTearDown(() async {
            if (!restore.isCompleted) restore.complete();
            await handler.disposeHandler();
            await database.close();
            await directory.delete(recursive: true);
          });
          // Startup maintenance is concurrent with metadata restoration.
          final evicted = List.generate(
            3,
            (i) => i,
          ).firstWhere((i) => !kept.contains(i));
          await until(() => !File(paths[evicted]).existsSync());
          await settle();
          for (var i = 0; i < paths.length; i++) {
            expect(File(paths[i]).existsSync(), kept.contains(i));
          }
          restore.complete();
          await handler.debugWaitForStartupQueueRestore();
        },
      );
    }

    test(
      'the handler reports the current and next song as protected',
      () async {
        final s = await serveQueue(3);
        await until(() => s.requests.contains('song-1'));
        expect(s.handler.rollingCacheProtectedSongIds, {'song-0', 'song-1'});
      },
    );

    test('a queue edit cancels a chain that is no longer next', () async {
      final s = await serveQueue(3, hold: {'song-1'});
      await until(() => s.downloader.activeSongId == 'song-1');
      await s.handler.removeQueueItemAt(1);
      await until(() => s.downloader.activeSongId != 'song-1');
      await until(() => s.requests.contains('song-2'));
    });
  });

  group('android next-song warm', () {
    const size = 8 * 1024;
    Future<
      ({
        NavisAudioHandler handler,
        ControllableAudioPlayer player,
        int port,
        Map<String, int> maxActive,
        List<String> requests,
        Completer<void> release,
        List<bool> gate,
      })
    >
    serveQueue(
      int count, {
      bool allowed = true,
      Set<String> hold = const <String>{},
      Set<String> cached = const <String>{},
      Set<String> silent = const <String>{},
      Set<String> failFirst = const <String>{},
      Set<String> cutFirst = const <String>{},
      List<String>? ids,
      int startIndex = 0,
      RollingCacheSidecarDownloader? downloader,
      bool build = true,
      NavisQueueWindow window = const NavisQueueWindow(),
      PlaybackSourceResolver Function(PlaybackSourceResolver)? wrap,
      bool crossfade = false,
      bool supportsTranscodeOffset = false,
      // Songs whose second and later downloads stop half-way until the gate.
      Set<String> holdLater = const <String>{},
      Completer<void>? laterGate,
      List<ControllableAudioPlayer>? rebuiltPlayers,
      NavisPlaybackTimeouts timeouts = const NavisPlaybackTimeouts(),
    }) async {
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final release = Completer<void>();
      final requests = <String>[];
      final gate = <bool>[allowed];
      final active = <String, int>{};
      final maxActive = <String, int>{};
      server.listen((request) async {
        final id = request.uri.queryParameters['id']!;
        requests.add(id);
        final nth = requests.where((r) => r == id).length;
        active[id] = (active[id] ?? 0) + 1;
        maxActive[id] = max(maxActive[id] ?? 0, active[id]!);
        try {
          if (failFirst.contains(id) && nth == 1) {
            request.response.statusCode = HttpStatus.internalServerError;
            await request.response.close();
            return;
          }
          request.response
            ..bufferOutput = false
            ..headers.contentType = ContentType('audio', 'mpeg')
            ..contentLength = size;
          if (cutFirst.contains(id) && nth == 1) {
            request.response.add(List<int>.filled(size ~/ 2, 1));
            await request.response.flush();
            // Expiry destroys the socket without a terminating chunk.
            request.response.deadline = Duration.zero;
            await Future<void>.delayed(const Duration(milliseconds: 100));
            return;
          }
          if (holdLater.contains(id) && nth > 1) {
            request.response.add(List<int>.filled(size ~/ 2, 1));
            await request.response.flush();
            await laterGate?.future;
            request.response.add(List<int>.filled(size ~/ 2, 1));
          } else if (silent.contains(id)) {
            // Headers only: the warm has reported no progress yet.
            await request.response.flush();
            await release.future;
            request.response.add(List<int>.filled(size, 1));
          } else if (hold.contains(id)) {
            request.response.add(List<int>.filled(size ~/ 2, 1));
            await request.response.flush();
            await release.future;
            request.response.add(List<int>.filled(size ~/ 2, 1));
          } else {
            request.response.add(List<int>.filled(size, 1));
          }
          await request.response.close();
        } on Object {
          // The handler cancels unfinished transfers at teardown.
        } finally {
          active[id] = active[id]! - 1;
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
      final directory = await Directory.systemTemp.createTemp('navis-warm-a-');
      final (handler, player, database) = await createHandler(
        directory,
        count,
        desktopRuntimeOverride: false,
        sidecarDownloader: downloader,
        wrapResolver: wrap,
        queueWindow: window,
        crossfade: crossfade,
        supportsTranscodeOffset: supportsTranscodeOffset,
        timeouts: timeouts,
        rebuiltPlayers: rebuiltPlayers,
        cacheSongs: false,
        positionStreams: true,
        readApiClient: () => api,
        nextSongPrefetchAllowed: allowed,
        readNextSongPrefetchAllowed: () => gate.first,
        seed: (database) async {
          for (final id in cached) {
            final file = File('${directory.path}/$id.mp3')
              ..writeAsBytesSync(<int>[1, 2, 3]);
            await database.cacheDao.upsertCachedTrack(
              CachedTracksTableCompanion.insert(
                songId: id,
                filePath: file.path,
                fileSize: 3,
                format: 'mp3',
                cacheType: CacheType.permanent,
                downloadStatus: DownloadStatus.complete,
                lastAccessedAt: DateTime.now(),
              ),
            );
          }
        },
      );
      addTearDown(() async {
        await handler.disposeHandler();
        if (!release.isCompleted) release.complete();
        await database.close();
        await server.close(force: true);
        await directory.delete(recursive: true);
        HttpOverrides.global = previousHttp;
      });
      if (build) {
        await handler.replaceQueue(
          ids ?? [for (var i = 0; i < count; i++) 'song-$i'],
          startIndex: startIndex,
          expandMatchFlows: false,
        );
        await settleQueue(handler);
      }
      return (
        handler: handler,
        player: player,
        port: server.port,
        maxActive: maxActive,
        requests: requests,
        release: release,
        gate: gate,
      );
    }

    // ignore: experimental_member_use, reason: the lock-cache source the player requests.
    LockCachingAudioSource sourceAt(ControllableAudioPlayer p, int i) =>
        // ignore: experimental_member_use, reason: as above.
        p.audioSources[i] as LockCachingAudioSource;

    // A download can finish (and rename its partial file) between a response
    // and its first read: that is a finished download, not a failure.
    // ignore: experimental_member_use, reason: the lock-cache source response.
    Future<void> drain(StreamAudioResponse r) =>
        r.stream.drain<void>().onError<PathNotFoundException>((_, _) {});

    // The player's own request for the current song; its completion is what
    // starts the warm.
    Future<void> playCurrent(ControllableAudioPlayer p) =>
        sourceAt(p, 0).request().then(drain);

    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 600 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(condition(), isTrue);
    }

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 400));

    test('completion of the current song downloads the next one', () async {
      final s = await serveQueue(3);
      await playCurrent(s.player);
      await until(() => s.requests.contains('song-1'));
      await settle();
      expect(s.requests, ['song-0', 'song-1']);
    });

    test('no next-song download when prefetch is not allowed', () async {
      final s = await serveQueue(3, allowed: false);
      await playCurrent(s.player);
      await settle();
      expect(s.requests, ['song-0']);
    });

    test('a next song without a lock-cache source is not fetched', () async {
      final s = await serveQueue(3, cached: {'song-1'});
      await playCurrent(s.player);
      await settle();
      expect(s.requests, ['song-0']);
    });

    test('Repeat One warms nothing', () async {
      final s = await serveQueue(3);
      await s.handler.setRepeatMode(AudioServiceRepeatMode.one);
      await playCurrent(s.player);
      await settle();
      expect(s.requests, ['song-0']);
    });

    test(
      'the warm continues, not restarts, when its song becomes current',
      () async {
        final s = await serveQueue(3, hold: {'song-1'});
        await playCurrent(s.player);
        await until(() => s.requests.contains('song-1'));
        s.player.moveTo(1);
        await pumpEventQueue();
        // The player now asks for the song the warm is fetching.
        final asked = sourceAt(s.player, 1).request();
        s.release.complete();
        await drain(await asked);
        await settle();
        expect(s.requests.where((id) => id == 'song-1'), hasLength(1));
      },
    );

    // The partial file of the song at [i], which a cancelled download removes.
    Future<File> partOf(ControllableAudioPlayer p, int i) async =>
        File('${(await sourceAt(p, i).cacheFile).path}.part');

    test('a queue edit cancels a warm that is no longer next', () async {
      final s = await serveQueue(3, hold: {'song-1'});
      final part = await partOf(s.player, 1);
      await playCurrent(s.player);
      await until(() => s.requests.contains('song-1'));
      await until(() => part.existsSync());
      await s.handler.removeQueueItemAt(1);
      await until(() => s.requests.contains('song-2'));
      await until(() => !part.existsSync());
      await settle();
    });

    test(
      'returning to a finished song re-arms the warm of its successor',
      () async {
        final s = await serveQueue(3, hold: {'song-1'});
        final part = await partOf(s.player, 1);
        await playCurrent(s.player);
        await until(() => part.existsSync());
        s.player.moveTo(2);
        await until(() => !part.existsSync());
        s.player.moveTo(0);
        await until(() => s.requests.where((id) => id == 'song-1').length == 2);
        await settle();
      },
    );

    test('switching to radio cancels a running warm', () async {
      final s = await serveQueue(3, silent: {'song-1'});
      final warm = sourceAt(s.player, 1);
      await playCurrent(s.player);
      await until(() => s.requests.contains('song-1') && warm.isDownloading);
      unawaited(
        s.handler
            .playRadioStream(
              stationId: 'r',
              stationName: 'R',
              streamUrl: 'http://127.0.0.1:${s.port}/radio?id=radio',
            )
            .catchError((Object _) {}),
      );
      await until(() => !warm.isDownloading);
    });

    test(
      'a shuffle that keeps the warmed song next reuses its source',
      () async {
        final s = await serveQueue(2, hold: {'song-1'});
        final warm = sourceAt(s.player, 1);
        await playCurrent(s.player);
        await until(() => s.requests.contains('song-1') && warm.isDownloading);
        await s.handler.setShuffleMode(AudioServiceShuffleMode.all);
        await settleQueue(s.handler);
        expect(identical(sourceAt(s.player, 1), warm), isTrue);
        final asked = sourceAt(s.player, 1).request();
        s.release.complete();
        await drain(await asked);
        await settle();
        expect(s.requests.where((id) => id == 'song-1'), hasLength(1));
      },
    );

    test(
      'a shuffle before the warm starts keeps one source for the song',
      () async {
        final s = await serveQueue(2, hold: {'song-1'});
        final next = sourceAt(s.player, 1);
        await s.handler.setShuffleMode(AudioServiceShuffleMode.all);
        await settleQueue(s.handler);
        expect(identical(sourceAt(s.player, 1), next), isTrue);
        await playCurrent(s.player);
        await until(() => s.requests.contains('song-1') && next.isDownloading);
        final asked = sourceAt(s.player, 1).request();
        s.release.complete();
        await drain(await asked);
        await settle();
        expect(s.requests.where((id) => id == 'song-1'), hasLength(1));
      },
    );

    test('disposing the handler cancels a running warm', () async {
      final s = await serveQueue(3, hold: {'song-1'});
      final part = await partOf(s.player, 1);
      await playCurrent(s.player);
      await until(() => part.existsSync());
      await s.handler.disposeHandler();
      await until(() => !part.existsSync());
    });

    int count(List<String> requests, String id) =>
        requests.where((r) => r == id).length;

    // Position ticks drive the chain between track changes.
    void ticks(ControllableAudioPlayer p) {
      p.simulateProgress = true;
      p.emitPlayerEvent();
    }

    test('a failed warm backs off, then retries', () async {
      sidecarChainRetryDelay = const Duration(milliseconds: 900);
      addTearDown(() => sidecarChainRetryDelay = const Duration(seconds: 30));
      final s = await serveQueue(3, failFirst: {'song-1'});
      ticks(s.player);
      await playCurrent(s.player);
      await until(() => s.requests.contains('song-1'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(count(s.requests, 'song-1'), 1);
      await until(() => count(s.requests, 'song-1') == 2);
      await settle();
    });

    test('a warm cut mid-body is detected and retried', () async {
      sidecarChainRetryDelay = const Duration(milliseconds: 900);
      addTearDown(() => sidecarChainRetryDelay = const Duration(seconds: 30));
      final s = await serveQueue(3, cutFirst: {'song-1'});
      ticks(s.player);
      await playCurrent(s.player);
      await until(() => s.requests.contains('song-1'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(count(s.requests, 'song-1'), 1);
      await until(() => count(s.requests, 'song-1') == 2);
      await settle();
    });

    test(
      'closing the gate cancels the warm; reopening restarts at once',
      () async {
        final s = await serveQueue(3, hold: {'song-1'});
        ticks(s.player);
        final warm = sourceAt(s.player, 1);
        await playCurrent(s.player);
        await until(() => s.requests.contains('song-1') && warm.isDownloading);
        s.gate[0] = false;
        await until(() => !warm.isDownloading);
        s.gate[0] = true;
        await until(() => count(s.requests, 'song-1') == 2);
        await settle();
      },
    );

    test('the chain continues after the warm becomes current', () async {
      final s = await serveQueue(3, hold: {'song-1'});
      ticks(s.player);
      await playCurrent(s.player);
      await until(() => s.requests.contains('song-1'));
      s.player.moveTo(1);
      await pumpEventQueue();
      final asked = sourceAt(s.player, 1).request();
      s.release.complete();
      await drain(await asked);
      await until(() => s.requests.contains('song-2'));
      expect(s.requests, ['song-0', 'song-1', 'song-2']);
      await settle();
    });

    test(
      'a tick before the hand-over to the warmed song keeps its warm',
      () async {
        final s = await serveQueue(3, hold: {'song-1'});
        ticks(s.player);
        final warm = sourceAt(s.player, 1);
        await playCurrent(s.player);
        await until(() => s.requests.contains('song-1') && warm.isDownloading);
        // The player has moved to song 1; the handler has not published it yet,
        // so the published current song still reads song 0.
        s.player.index = 1;
        s.player.emitPlayerEvent();
        await pumpEventQueue();
        expect(warm.isDownloading, isTrue);
        s.player.moveTo(1);
        await pumpEventQueue();
        final asked = warm.request();
        s.release.complete();
        await drain(await asked);
        await until(() => s.requests.contains('song-2'));
        expect(s.requests, ['song-0', 'song-1', 'song-2']);
        await settle();
      },
    );

    test('Repeat All wraps the warm to the first song', () async {
      final s = await serveQueue(2, startIndex: 1);
      await s.handler.setRepeatMode(AudioServiceRepeatMode.all);
      ticks(s.player);
      await sourceAt(s.player, 1).request().then(drain);
      await until(() => s.requests.contains('song-0'));
      expect(s.requests, ['song-1', 'song-0']);
      await settle();
    });

    test('replacing the queue with the warmed song first reuses it', () async {
      final s = await serveQueue(3, hold: {'song-1'});
      ticks(s.player);
      final warm = sourceAt(s.player, 1);
      await playCurrent(s.player);
      await until(() => s.requests.contains('song-1') && warm.isDownloading);
      await s.handler.replaceQueue([
        'song-1',
        'song-2',
        'song-0',
      ], expandMatchFlows: false);
      await settleQueue(s.handler);
      expect(identical(sourceAt(s.player, 0), warm), isTrue);
      final asked = sourceAt(s.player, 0).request();
      s.release.complete();
      await drain(await asked);
      await settle();
      expect(count(s.requests, 'song-1'), 1);
    });

    test(
      'a song twice in the queue has one lock-cache source and one download',
      () async {
        final s = await serveQueue(
          3,
          hold: {'song-1'},
          ids: ['song-0', 'song-1', 'song-1'],
        );
        ticks(s.player);
        // One writer per cache file, and one instance never at two playlist
        // positions (just_audio derives the native id from it): the repeat
        // streams without downloading.
        // ignore: experimental_member_use, reason: the lock-cache source.
        expect(s.player.audioSources[1], isA<LockCachingAudioSource>());
        // ignore: experimental_member_use, reason: the lock-cache source.
        expect(s.player.audioSources[2], isNot(isA<LockCachingAudioSource>()));
        expect(
          s.player.audioSources.toSet(),
          hasLength(s.player.audioSources.length),
        );
        await playCurrent(s.player);
        await until(() => s.requests.contains('song-1'));
        s.player.moveTo(1);
        await pumpEventQueue();
        final asked = sourceAt(s.player, 1).request();
        s.release.complete();
        await drain(await asked);
        await settle();
        expect(count(s.requests, 'song-1'), 1);
        expect(s.maxActive['song-1'], 1);
      },
    );

    // What the native player does with an occurrence: a stream source is read
    // through its proxy request, a plain URI source is fetched from its origin.
    Future<int> readOccurrence(ControllableAudioPlayer p, int i) async {
      final source = p.audioSources[i];
      // ignore: experimental_member_use, reason: the proxy request contract.
      if (source is StreamAudioSource) {
        final response = await source.request();
        await drain(response);
        return response.contentLength ?? -1;
      }
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(
          (source as UriAudioSource).uri,
        )).close();
        return (await response.fold<int>(0, (n, chunk) => n + chunk.length));
      } finally {
        client.close(force: true);
      }
    }

    test(
      'a repeat occurrence of a completed song reads the cache file',
      () async {
        final s = await serveQueue(3, ids: ['song-0', 'song-1', 'song-1']);
        ticks(s.player);
        final leader = sourceAt(s.player, 1);
        await drain(await leader.request());
        final file = await leader.cacheFile;
        await until(() => file.existsSync());
        expect(count(s.requests, 'song-1'), 1);
        expect(await readOccurrence(s.player, 2), size);
        // The completed file is served: the origin is not asked again.
        expect(count(s.requests, 'song-1'), 1);
        // ignore: experimental_member_use, reason: the proxy request contract.
        expect(s.player.audioSources[2], isA<StreamAudioSource>());
      },
    );

    test('a repeat occurrence joins the leader download', () async {
      final s = await serveQueue(
        3,
        hold: {'song-1'},
        ids: ['song-0', 'song-1', 'song-1'],
      );
      ticks(s.player);
      final leader = sourceAt(s.player, 1);
      final first = leader.request();
      await until(() => s.requests.contains('song-1') && leader.isDownloading);
      final reading = readOccurrence(s.player, 2);
      await pumpEventQueue();
      s.release.complete();
      expect(await reading, size);
      await drain(await first);
      await settle();
      expect(count(s.requests, 'song-1'), 1);
      expect(s.maxActive['song-1'], 1);
    });

    // The cache file of a completed song is evicted while the song is queued:
    // the held writer downloads it again, registered like any running download,
    // and a new occurrence follows it instead of becoming a second writer.
    for (final edit in ['addToQueue', 'playNext', 'replaceQueue']) {
      test(
        'an evicted song re-downloads through its held writer, $edit',
        () async {
          final gate = Completer<void>();
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
          final s = await serveQueue(
            3,
            ids: ['song-0', 'song-1', 'song-1'],
            holdLater: {'song-1'},
            laterGate: gate,
          );
          ticks(s.player);
          final leader = sourceAt(s.player, 1);
          await drain(await leader.request());
          final file = await leader.cacheFile;
          await until(() => file.existsSync());
          await until(
            () => s.handler.debugRegisteredLockCacheSource('song-1') == null,
          );
          file.deleteSync();
          final reading = leader.request();
          await until(() => leader.isDownloading);
          expect(
            identical(
              s.handler.debugRegisteredLockCacheSource('song-1'),
              leader,
            ),
            isTrue,
            reason: 'the re-download must be registered again',
          );
          switch (edit) {
            case 'addToQueue':
              await s.handler.addToQueue(['song-1'], expandMatchFlows: false);
            case 'playNext':
              await s.handler.playNext(['song-1'], expandMatchFlows: false);
            default:
              await s.handler.replaceQueue([
                'song-0',
                'song-1',
                'song-1',
                'song-1',
              ], expandMatchFlows: false);
          }
          await settleQueue(s.handler);
          expect(
            identical(
              s.handler.debugRegisteredLockCacheSource('song-1'),
              leader,
            ),
            isTrue,
          );
          final ids = [for (final m in s.handler.queue.value) m.id];
          final writers = [
            for (var i = 0; i < ids.length; i++)
              // ignore: experimental_member_use, reason: the lock-cache source.
              if (ids[i] == 'song-1' &&
                  // ignore: experimental_member_use, reason: the lock-cache source.
                  s.player.audioSources[i] is LockCachingAudioSource)
                s.player.audioSources[i],
          ];
          expect(writers, hasLength(1));
          expect(identical(writers.single, leader), isTrue);
          for (var i = 0; i < ids.length; i++) {
            if (ids[i] == 'song-1' &&
                !identical(s.player.audioSources[i], leader)) {
              expect(s.player.audioSources[i], isA<LockCacheFollowerSource>());
            }
          }
          final last = ids.lastIndexOf('song-1');
          final second = readOccurrence(s.player, last);
          gate.complete();
          await second;
          await drain(await reading);
          await settle();
          // One origin download, then one re-download: never a second writer.
          expect(count(s.requests, 'song-1'), 2);
          expect(s.maxActive['song-1'], 1);
          // The re-download completed through the progress observer, so the
          // rolling cache registered the file and the registry entry is gone.
          await until(
            () => s.handler.debugRegisteredLockCacheSource('song-1') == null,
          );
          expect(file.existsSync(), isTrue);
        },
      );
    }

    test(
      'a new occurrence of an evicted song follows its idle held writer',
      () async {
        final s = await serveQueue(3, ids: ['song-0', 'song-1', 'song-1']);
        ticks(s.player);
        final leader = sourceAt(s.player, 1);
        await drain(await leader.request());
        final file = await leader.cacheFile;
        await until(() => file.existsSync());
        await until(
          () => s.handler.debugRegisteredLockCacheSource('song-1') == null,
        );
        file.deleteSync();
        await s.handler.addToQueue(['song-1'], expandMatchFlows: false);
        await settleQueue(s.handler);
        final added = s.player.audioSources.last;
        expect(added, isA<LockCacheFollowerSource>());
        expect(
          identical((added as LockCacheFollowerSource).leader, leader),
          isTrue,
        );
        await readOccurrence(s.player, s.player.audioSources.length - 1);
        await settle();
        expect(count(s.requests, 'song-1'), 2);
        expect(s.maxActive['song-1'], 1);
      },
    );

    test('a rebuild onto an idle evicted writer does not replay its completion', () async {
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final s = await serveQueue(
        4,
        ids: ['song-0', 'song-1', 'song-1', 'song-2'],
        holdLater: {'song-1'},
        laterGate: gate,
      );
      ticks(s.player);
      final leader = sourceAt(s.player, 1);
      await drain(await leader.request());
      final file = await leader.cacheFile;
      await until(() => file.existsSync());
      await until(
        () => s.handler.debugRegisteredLockCacheSource('song-1') == null,
      );
      await s.handler.skipToQueueItem(3);
      await settleQueue(s.handler);
      await settle();
      file.deleteSync();
      await s.handler.replaceQueue(
        ['song-1', 'song-0', 'song-1'],
        startIndex: 0,
        expandMatchFlows: false,
      );
      await settleQueue(s.handler);
      await settle();
      expect(identical(s.player.audioSources[0], leader), isTrue);
      // The file is gone: the stale 1.0 the progress stream replays is not a
      // completion, so the writer stays registered and the buffer is not full.
      expect(
        identical(s.handler.debugRegisteredLockCacheSource('song-1'), leader),
        isTrue,
      );
      expect(
        s.handler.bufferState.bufferedPosition,
        lessThan(const Duration(minutes: 3)),
      );
    });

    test('a source retired by a player recovery no longer re-registers', () async {
      final s = await serveQueue(
        3,
        hold: {'song-1'},
        ids: ['song-0', 'song-1', 'song-1'],
        rebuiltPlayers: <ControllableAudioPlayer>[],
        timeouts: const NavisPlaybackTimeouts(
          load: Duration(milliseconds: 150),
          reset: Duration(milliseconds: 150),
        ),
      );
      ticks(s.player);
      final leader = sourceAt(s.player, 1);
      expect(leader.onDownloadStart, isNotNull);
      s.player.hang.add('insertAudioSources');
      await expectLater(
        s.handler.playNext(['song-0'], expandMatchFlows: false),
        throwsA(isA<PlaybackLoadTimeoutException>()),
      );
      // Recovery unregistered the retired writer; a retry of its fetch must not
      // take the registry slot back from the rebuilt queue's source.
      expect(s.handler.debugRegisteredLockCacheSource('song-1'), isNot(leader));
      expect(leader.onDownloadStart, isNull);
      s.release.complete();
    });

    test('a repeat occurrence plays on after its leader is removed', () async {
      final s = await serveQueue(
        3,
        hold: {'song-1'},
        ids: ['song-0', 'song-1', 'song-1'],
      );
      ticks(s.player);
      final leader = sourceAt(s.player, 1);
      final first = leader.request();
      await until(() => s.requests.contains('song-1') && leader.isDownloading);
      await s.handler.removeQueueItemAt(1);
      await settleQueue(s.handler);
      expect(s.player.audioSources, hasLength(2));
      final reading = readOccurrence(s.player, 1);
      await pumpEventQueue();
      s.release.complete();
      expect(await reading, size);
      await drain(await first);
      await settle();
      expect(count(s.requests, 'song-1'), 1);
      expect(s.maxActive['song-1'], 1);
    });

    // The planner asks whether the origin serves ranges; a repeat occurrence
    // answers with its leader's origin, not with "a plain source: yes".
    for (final onRepeat in [false, true]) {
      test(
        'the seek planner uses the leader range support'
        ' (playing the ${onRepeat ? 'repeat' : 'first'} occurrence)',
        () async {
          final s = await serveQueue(
            3,
            hold: {'song-1'},
            ids: ['song-0', 'song-1', 'song-1'],
            supportsTranscodeOffset: true,
            wrap: (base) => TranscodedLockResolver(base),
          );
          ticks(s.player);
          final leader = sourceAt(s.player, 1);
          final first = leader.request();
          await until(() => leader.originSupportsRangeRequests == false);
          s.player.moveTo(onRepeat ? 2 : 1);
          await pumpEventQueue();
          await s.handler.previewSeek(const Duration(seconds: 150));
          // The origin (no Accept-Ranges) cannot serve the native seek: the
          // planner opens a transcode at the offset instead.
          expect(
            s.handler.collectPlaybackDiagnostics()['seekPreview'],
            isNotNull,
          );
          s.handler.cancelSeekPreview();
          s.release.complete();
          await drain(await first);
          await settle();
        },
      );
    }

    // Per player index: 'reg' when the player holds the registered source of
    // that song, else 'DIFF'/'UNREG'; plus how many instances each song has.
    String audit(NavisAudioHandler handler, ControllableAudioPlayer player) {
      final ids = [for (final m in handler.queue.value) m.id];
      final instances = <String, Set<int>>{};
      var bad = 0;
      // One source instance at two playlist positions merges their native ids
      // (any kind of source, so a follower is held to it as well).
      final positions = <int, List<int>>{};
      for (var i = 0; i < player.audioSources.length; i++) {
        final s = player.audioSources[i];
        (positions[identityHashCode(s)] ??= <int>[]).add(i);
        // ignore: experimental_member_use, reason: the lock-cache source.
        if (s is! LockCachingAudioSource) continue;
        final id = ids[i];
        // A finished download unregisters (the player keeps its source), and
        // how soon that happens relative to this audit depends on timing: a
        // slow runner has the current song's source still held here. Only a
        // completed download may be held unregistered; any other unregistered
        // source (never registered, or failed and removed) is a defect.
        final registered = handler.debugRegisteredLockCacheSource(id);
        if (!identical(s, registered) &&
            (registered != null || !handler.debugLockCacheCompleted(id))) {
          bad++;
        }
        (instances[id] ??= <int>{}).add(identityHashCode(s));
      }
      final multi = [
        for (final e in instances.entries)
          if (e.value.length > 1) e.key,
      ];
      final shared = [
        for (final p in positions.values)
          if (p.length > 1) p,
      ];
      return 'bad=$bad multiInstance=$multi atTwoPositions=$shared';
    }

    const oneInstance = 'bad=0 multiInstance=[] atTwoPositions=[]';

    test(
      'addToQueue and playNext duplicates keep one registered source',
      () async {
        final s = await serveQueue(
          4,
          hold: {'song-1', 'song-3'},
          ids: ['song-0', 'song-1'],
        );
        ticks(s.player);
        await s.handler.addToQueue([
          'song-1',
          'song-3',
          'song-3',
        ], expandMatchFlows: false);
        await settleQueue(s.handler);
        expect(audit(s.handler, s.player), oneInstance);
        await s.handler.playNext(['song-3', 'song-1'], expandMatchFlows: false);
        await settleQueue(s.handler);
        expect(audit(s.handler, s.player), oneInstance);
        await settle();
      },
    );

    // Each occurrence of a song is its own source instance (the native id
    // derives from it), with one lock-cache writer per song.
    void expectOccurrences(
      NavisAudioHandler handler,
      ControllableAudioPlayer player,
      List<String> ids,
    ) {
      expect([for (final m in handler.queue.value) m.id], ids);
      expect(player.audioSources, hasLength(ids.length));
      expect(player.audioSources.toSet(), hasLength(ids.length));
      expect(audit(handler, player), oneInstance);
      for (final id in ids.toSet()) {
        final writers = [
          for (var i = 0; i < ids.length; i++)
            // ignore: experimental_member_use, reason: the lock-cache source.
            if (ids[i] == id &&
                // ignore: experimental_member_use, reason: the lock-cache source.
                player.audioSources[i] is LockCachingAudioSource)
              i,
        ];
        expect(writers.length, lessThanOrEqualTo(1), reason: id);
      }
    }

    test('addToQueue of a queued song adds its own occurrence', () async {
      final s = await serveQueue(
        2,
        hold: {'song-1'},
        ids: ['song-0', 'song-1'],
      );
      ticks(s.player);
      await s.handler.addToQueue(['song-1', 'song-1'], expandMatchFlows: false);
      await settleQueue(s.handler);
      expectOccurrences(s.handler, s.player, [
        'song-0',
        'song-1',
        'song-1',
        'song-1',
      ]);
      await settle();
    });

    test(
      'playNext of the playing and a queued song adds occurrences',
      () async {
        final s = await serveQueue(
          2,
          hold: {'song-1'},
          ids: ['song-0', 'song-1'],
        );
        ticks(s.player);
        await s.handler.playNext(['song-0', 'song-1'], expandMatchFlows: false);
        await settleQueue(s.handler);
        expectOccurrences(s.handler, s.player, [
          'song-0',
          'song-0',
          'song-1',
          'song-1',
        ]);
        await settle();
      },
    );

    // A full queue rebuild while the registered source is held (the flag on
    // _prepareQueueItems/_reloadQueueAfterTimeout): the held source stays the
    // song's one writer at its first occurrence, the repeat is its own
    // instance, and nothing downloads twice.
    Future<void> expectHeldLeaderSurvives(
      ({
        NavisAudioHandler handler,
        ControllableAudioPlayer player,
        int port,
        Map<String, int> maxActive,
        List<String> requests,
        Completer<void> release,
        List<bool> gate,
      })
      s,
      // ignore: experimental_member_use, reason: the lock-cache source.
      LockCachingAudioSource leader,
      List<String> ids, {
      // A jump away cancels the unfinished warm (a later request downloads
      // again), so only a rebuild that stays put downloads exactly once.
      bool downloadsOnce = true,
    }) async {
      await settleQueue(s.handler);
      expect(
        identical(s.handler.debugRegisteredLockCacheSource('song-1'), leader),
        isTrue,
      );
      expect(
        identical(s.player.audioSources[ids.indexOf('song-1')], leader),
        isTrue,
      );
      expectOccurrences(s.handler, s.player, ids);
      s.release.complete();
      await drain(await leader.request());
      await settle();
      if (downloadsOnce) {
        expect(count(s.requests, 'song-1'), 1);
        expect(s.maxActive['song-1'], 1);
      }
    }

    test(
      'a queue rebuilt while the registered source is held keeps it',
      () async {
        const ids = ['song-0', 'song-1', 'song-1'];
        final s = await serveQueue(3, hold: {'song-1'}, ids: ids);
        ticks(s.player);
        final leader = sourceAt(s.player, 1);
        await playCurrent(s.player);
        await until(
          () => s.requests.contains('song-1') && leader.isDownloading,
        );
        await s.handler.replaceQueue(ids, expandMatchFlows: false);
        await expectHeldLeaderSurvives(s, leader, ids);
      },
    );

    test('a rebuild prepared while the source is held keeps it', () async {
      const ids = ['song-0', 'song-1', 'song-1'];
      final s = await serveQueue(3, hold: {'song-1'}, ids: ids);
      ticks(s.player);
      final leader = sourceAt(s.player, 1);
      await playCurrent(s.player);
      await until(() => s.requests.contains('song-1') && leader.isDownloading);
      // The rebuild replaces the whole queue: the player's own copy of the
      // registered source is not a reason to demote its first occurrence.
      final sources = await s.handler.debugPrepareReplacementSources(ids);
      expect(identical(sources[1], leader), isTrue);
      // ignore: experimental_member_use, reason: the lock-cache source.
      expect(sources[2], isNot(isA<LockCachingAudioSource>()));
      expect(sources.toSet(), hasLength(ids.length));
      s.release.complete();
      await settle();
    });

    test(
      'a queue restored after a failed far jump keeps the held source',
      () async {
        final ids = [
          'song-0',
          'song-1',
          'song-1',
          for (var i = 3; i < 60; i++) 'song-$i',
        ];
        final s = await serveQueue(
          60,
          hold: {'song-1'},
          ids: ids,
          window: const NavisQueueWindow(
            deferThreshold: 16,
            ahead: 8,
            lowWater: 3,
            page: 8,
            nearJump: 16,
          ),
        );
        ticks(s.player);
        final leader = sourceAt(s.player, 1);
        await playCurrent(s.player);
        await until(
          () => s.requests.contains('song-1') && leader.isDownloading,
        );
        s.player.failLoadSongId = 'song-50';
        await s.handler.playFromIndex(50);
        await until(
          () =>
              s.handler.snapshot.lastFailedSongId == 'song-50' &&
              !s.handler.snapshot.isLoading,
        );
        s.player.failLoadSongId = null;
        await expectHeldLeaderSurvives(
          s,
          leader,
          ids.take(9).toList(),
          downloadsOnce: false,
        );
      },
    );

    test(
      'a released tail with duplicates keeps one registered source',
      () async {
        final s = await serveQueue(
          4,
          hold: {'song-2'},
          ids: ['song-0', 'song-1', 'song-2', 'song-2', 'song-3', 'song-2'],
          window: const NavisQueueWindow(
            deferThreshold: 3,
            ahead: 1,
            lowWater: 1,
            page: 4,
            nearJump: 5,
            behind: 1,
            trimSlack: 1,
          ),
        );
        ticks(s.player);
        await s.handler.skipToNext();
        await settleQueue(s.handler);
        await until(() => s.player.audioSources.length == 6);
        await settleQueue(s.handler);
        expect(audit(s.handler, s.player), oneInstance);
        await settle();
      },
    );

    test(
      'a released tail is registered while its deck mirror is blocked',
      () async {
        final s = await serveQueue(
          4,
          hold: {'song-2'},
          ids: ['song-0', 'song-1', 'song-2', 'song-2', 'song-3', 'song-2'],
          crossfade: true,
          timeouts: const NavisPlaybackTimeouts(reset: Duration(seconds: 3)),
          window: const NavisQueueWindow(
            deferThreshold: 3,
            ahead: 1,
            lowWater: 1,
            page: 4,
            nearJump: 5,
            behind: 1,
            trimSlack: 1,
          ),
        );
        ticks(s.player);
        await s.handler.debugStartCrossfade();
        final deck = s.handler.debugInactiveDeck! as ControllableAudioPlayer;
        deck.hang.add('addAudioSources');
        unawaited(s.handler.skipToNext().catchError((Object _) {}));
        await until(() => s.player.audioSources.length == 6);
        // The native append is committed: the source the player holds must be
        // the registered one now, not once the (still blocked) mirror ends.
        await until(
          () => identical(
            s.handler.debugRegisteredLockCacheSource('song-2'),
            s.player.audioSources[2],
          ),
        );
        s.release.complete();
      },
    );

    test(
      'an inserted song is registered while its deck mirror is blocked',
      () async {
        final s = await serveQueue(
          3,
          hold: {'song-2'},
          ids: ['song-0', 'song-1'],
          crossfade: true,
          timeouts: const NavisPlaybackTimeouts(reset: Duration(seconds: 4)),
        );
        ticks(s.player);
        await s.handler.debugStartCrossfade();
        final deck = s.handler.debugInactiveDeck! as ControllableAudioPlayer;
        deck.hang.add('addAudioSources');
        unawaited(
          s.handler
              .addToQueue(['song-2'], expandMatchFlows: false)
              .catchError((Object _) {}),
        );
        await until(() => s.player.audioSources.length == 3);
        await until(
          () => identical(
            s.handler.debugRegisteredLockCacheSource('song-2'),
            s.player.audioSources[2],
          ),
        );
        s.release.complete();
      },
    );

    test('addToQueue on an empty queue shares duplicates', () async {
      final s = await serveQueue(3, hold: {'song-1'}, build: false);
      ticks(s.player);
      await s.handler.addToQueue([
        'song-0',
        'song-1',
        'song-1',
      ], expandMatchFlows: false);
      await settleQueue(s.handler);
      expect(audit(s.handler, s.player), oneInstance);
      await settle();
    });

    test(
      'a fill superseded after its native append is still registered',
      () async {
        final s = await serveQueue(3, hold: {'song-1'}, build: false);
        final p = s.player;
        final afterGate = Completer<void>();
        final afterEntered = Completer<void>();
        p.afterAppendGate = afterGate;
        p.afterAppendEntered = afterEntered;
        final first = s.handler.replaceQueue([
          'song-0',
          'song-1',
          'song-2',
        ], expandMatchFlows: false);
        await afterEntered.future.timeout(const Duration(seconds: 5));
        // The batch is in the player; a newer queue load supersedes the fill
        // before its native call returns.
        final x1 = sourceAt(p, 1);
        final second = s.handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        await pumpEventQueue();
        afterGate.complete();
        await first.catchError((Object _) {});
        expect(
          identical(s.handler.debugRegisteredLockCacheSource('song-1'), x1),
          isTrue,
        );
        await second.catchError((Object _) {});
        await settleQueue(s.handler);
        expect(audit(s.handler, p), oneInstance);
        await settle();
      },
    );

    test(
      'duplicates resolved out of order keep one registered source',
      () async {
        final s = await serveQueue(
          3,
          hold: {'song-1'},
          ids: ['song-0', 'song-1', 'song-1'],
          wrap: (base) => OutOfOrderResolver(base),
        );
        ticks(s.player);
        final player1 = sourceAt(s.player, 1);
        await playCurrent(s.player);
        await until(
          () => s.requests.contains('song-1') && player1.isDownloading,
        );
        s.player.moveTo(1);
        await pumpEventQueue();
        final asked = player1.request();
        s.release.complete();
        await drain(await asked);
        await settle();
        expect(count(s.requests, 'song-1'), 1);
        expect(s.maxActive['song-1'], 1);
      },
    );

    test('a superseded queue build does not poison the next one', () async {
      late GatedSourceResolver gated;
      final s = await serveQueue(
        3,
        hold: {'song-1'},
        build: false,
        wrap: (base) => gated = GatedSourceResolver(base),
      );
      gated
        ..blockedSongId = 'song-2'
        ..entered = Completer<void>()
        ..release = Completer<void>();
      final first = s.handler.replaceQueue([
        'song-0',
        'song-1',
        'song-2',
      ], expandMatchFlows: false);
      await gated.entered!.future;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final second = s.handler.replaceQueue([
        'song-0',
        'song-1',
      ], expandMatchFlows: false);
      gated.release!.complete();
      await Future.wait([
        first.catchError((Object _) {}),
        second.catchError((Object _) {}),
      ]);
      await settleQueue(s.handler);
      ticks(s.player);
      final player1 = sourceAt(s.player, 1);
      await playCurrent(s.player);
      await until(() => s.requests.contains('song-1') && player1.isDownloading);
      s.player.moveTo(1);
      await pumpEventQueue();
      final asked = player1.request();
      s.release.complete();
      await drain(await asked);
      await settle();
      expect(count(s.requests, 'song-1'), 1);
      expect(s.maxActive['song-1'], 1);
    });

    test('a queue reloaded after a player timeout is observed again', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final directory = await Directory.systemTemp.createTemp('navis-warm-n-');
      final rebuilt = <ControllableAudioPlayer>[];
      final created = <WarmRangeSource>[];
      final (handler, player, database) = await createHandler(
        directory,
        3,
        cacheSongs: false,
        positionStreams: true,
        rebuiltPlayers: rebuilt,
        desktopRuntimeOverride: false,
        timeouts: const NavisPlaybackTimeouts(
          load: Duration(milliseconds: 300),
          reset: Duration(milliseconds: 150),
          control: Duration(milliseconds: 300),
          progressIdle: Duration(milliseconds: 400),
          seekProgress: Duration(seconds: 3),
        ),
        wrapResolver: (base) => FreshRangeResolver(base, directory, created),
      );
      addTearDown(() async {
        await handler.disposeHandler();
        for (final source in created) {
          await source.progress.close();
        }
        await database.close();
        await directory.delete(recursive: true);
        debugDefaultTargetPlatformOverride = null;
      });
      player.simulateProgress = true;
      await handler.replaceQueue([
        'song-0',
        'song-1',
        'song-2',
      ], expandMatchFlows: false);
      await pumpEventQueue();
      player.isPlaying = true;
      player.hang.add('removeAudioSourceAt');
      await handler
          .removeAt(2)
          .timeout(const Duration(seconds: 6))
          .catchError((Object _) {});
      await pumpEventQueue();
      expect(rebuilt, isNotEmpty);
      final held = rebuilt.first.audioSources.cast<WarmRangeSource>();
      expect(held, isNotEmpty);
      expect(held.every((source) => source.progress.hasListener), isTrue);
    });

    test('a position tick while disposing does not restart the warm', () async {
      final gate = Completer<void>();
      final s = await serveQueue(
        3,
        hold: {'song-1'},
        downloader: SlowDisposeDownloader(gate),
      );
      ticks(s.player);
      final warm = sourceAt(s.player, 1);
      await playCurrent(s.player);
      await until(() => s.requests.contains('song-1') && warm.isDownloading);
      final disposing = s.handler.disposeHandler();
      await until(() => !warm.isDownloading);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(warm.isDownloading, isFalse);
      expect(count(s.requests, 'song-1'), 1);
      gate.complete();
      await disposing;
    });

    test(
      'the warm stays paused while the finished song has a range fetch',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final directory = await Directory.systemTemp.createTemp(
          'navis-warm-k-',
        );
        final sources = {
          for (var i = 0; i < 3; i++)
            'song-$i': WarmRangeSource(
              'song-$i',
              File('${directory.path}/$i.mp3'),
            ),
        };
        final (handler, player, database) = await createHandler(
          directory,
          3,
          cacheSongs: false,
          positionStreams: true,
          desktopRuntimeOverride: false,
          wrapResolver: (base) => RangeCacheResolver(base, sources),
        );
        addTearDown(() async {
          await handler.disposeHandler();
          for (final source in sources.values) {
            await source.progress.close();
          }
          await database.close();
          await directory.delete(recursive: true);
          debugDefaultTargetPlatformOverride = null;
        });
        player.simulateProgress = true;
        await handler.replaceQueue([
          'song-0',
          'song-1',
          'song-2',
        ], expandMatchFlows: false);
        await pumpEventQueue();
        sources['song-0']!.activeRange = true;
        player.emitBuffered(const Duration(seconds: 2));
        await pumpEventQueue();
        // The main download of song-0 finishes (its file is published); its
        // range fetch stays open.
        File('${directory.path}/0.mp3').writeAsBytesSync([1]);
        sources['song-0']!.progress.add(1.0);
        await pumpEventQueue();
        player.emitBuffered(const Duration(seconds: 3));
        await pumpEventQueue();
        expect(sources['song-1']!.warmed, isTrue);
        expect(sources['song-1']!.paused, isTrue);
      },
    );
  });

  for (final fail in [false, true]) {
    test(
      'desktop cache activity clears after ${fail ? 'retry exhaustion' : 'cancellation'}',
      () async {
        final previousHttp = HttpOverrides.current;
        HttpOverrides.global = null;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final release = Completer<void>();
        server.listen((request) async {
          try {
            request.response
              ..bufferOutput = false
              ..contentLength = 100 * 1024
              ..add(List<int>.filled(40 * 1024, 1));
            await request.response.flush();
            await release.future;
            await server.close(force: true);
          } on HttpException {
            // The handler cancels the unfinished transfer at teardown.
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
        final directory = await Directory.systemTemp.createTemp(
          'navis-sidecar-terminal-',
        );
        final (handler, _, database) = await createHandler(
          directory,
          2,
          sidecarStreams: true,
          readApiClient: () => api,
        );
        addTearDown(() async {
          await handler.disposeHandler();
          if (!release.isCompleted) release.complete();
          await database.close();
          await server.close(force: true);
          await directory.delete(recursive: true);
          HttpOverrides.global = previousHttp;
        });
        final cached = File.fromUri(directory.uri.resolve('cached.mp3'));
        await cached.writeAsBytes(<int>[1, 2, 3]);
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'song-1',
            filePath: cached.path,
            fileSize: 3,
            format: 'mp3',
            cacheType: CacheType.permanent,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        for (var attempt = 0; attempt < 400; attempt++) {
          final activity = handler
              .collectPlaybackDiagnostics()['cacheActivity'];
          if (activity is Map && (activity['progress'] as num) >= 0.4) break;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(
          handler.collectPlaybackDiagnostics()['cacheActivity'],
          isNotNull,
        );
        if (fail) {
          release.complete();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(
            handler.collectPlaybackDiagnostics()['sidecarCacheActiveSongId'],
            'song-0',
          );
          expect(
            handler.collectPlaybackDiagnostics()['cacheActivity'],
            isNotNull,
          );
          for (var attempt = 0; attempt < 2000; attempt++) {
            if (handler
                    .collectPlaybackDiagnostics()['sidecarCacheActiveSongId'] ==
                null) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        } else {
          await handler.skipToNext();
          await pumpEventQueue();
        }
        expect(
          handler.collectPlaybackDiagnostics()['sidecarCacheActiveSongId'],
          isNull,
        );
        expect(handler.collectPlaybackDiagnostics()['cacheActivity'], isNull);
      },
    );
  }

  for (final abandon in [false, true]) {
    test(
      'desktop current-index events ${abandon ? 'restart a full GET only after resume is abandoned' : 'retain the sidecar through Range resume'}',
      () async {
        final previousHttp = HttpOverrides.current;
        HttpOverrides.global = null;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final releaseCut = Completer<void>();
        final continuation = Completer<HttpResponse>();
        final ranges = <String?>[];
        final bytes = List<int>.generate(100 * 1024, (i) => i % 251);
        const prefix = 40 * 1024;
        server.listen((request) async {
          ranges.add(request.headers.value(HttpHeaders.rangeHeader));
          if (ranges.length == 1) {
            request.response
              ..contentLength = bytes.length
              ..add(bytes.sublist(0, prefix));
            await request.response.flush();
            await releaseCut.future;
            request.response.deadline = Duration.zero;
          } else if (ranges.length == 2) {
            continuation.complete(request.response);
          } else {
            request.response
              ..contentLength = bytes.length
              ..add(bytes);
            await request.response.close();
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
        final directory = await Directory.systemTemp.createTemp(
          'navis-sidecar-restart-',
        );
        final downloader = RollingCacheSidecarDownloader();
        final (handler, player, database) = await createHandler(
          directory,
          1,
          sidecarStreams: true,
          sidecarDownloader: downloader,
          readApiClient: () => api,
        );
        addTearDown(() async {
          await handler.disposeHandler();
          if (!releaseCut.isCompleted) releaseCut.complete();
          await database.close();
          await server.close(force: true);
          await directory.delete(recursive: true);
          HttpOverrides.global = previousHttp;
        });
        Future<void> until(bool Function() condition) async {
          for (var i = 0; i < 600 && !condition(); i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          expect(condition(), isTrue);
        }

        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        await until(() => downloader.activeReceivedBytes == prefix);
        final partPath = downloader.activePartFilePath!;
        final cacheFile = File(
          handler.mediaItem.value!.extras!['sidecarCacheFilePath']! as String,
        );
        releaseCut.complete();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        player.moveTo(player.currentIndex!);
        await pumpEventQueue();
        expect(ranges, [null]);
        expect(downloader.activePartFilePath, partPath);
        expect(downloader.activeReceivedBytes, prefix);
        expect(
          handler.collectPlaybackDiagnostics()['cacheActivity'],
          isNotNull,
        );

        final response = await continuation.future.timeout(
          const Duration(seconds: 3),
        );
        expect(ranges, [null, 'bytes=$prefix-']);
        player.moveTo(player.currentIndex!);
        await pumpEventQueue();
        expect(ranges.length, 2);
        expect(File(partPath).readAsBytesSync(), bytes.sublist(0, prefix));
        response.statusCode = abandon
            ? HttpStatus.ok
            : HttpStatus.partialContent;
        response.contentLength = abandon ? bytes.length : bytes.length - prefix;
        if (!abandon) {
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $prefix-${bytes.length - 1}/${bytes.length}',
          );
        }
        response.add(abandon ? bytes : bytes.sublist(prefix));
        await response.close();
        await until(() => downloader.activeSongId == null);
        expect(handler.collectPlaybackDiagnostics()['cacheActivity'], isNull);
        expect(File(partPath).existsSync(), isFalse);
        expect(cacheFile.existsSync(), !abandon);
        expect(player.playing, isTrue);
        expect(handler.snapshot.currentSongId, 'song-0');

        // Native position events re-emit the current index after termination.
        player.moveTo(player.currentIndex!);
        if (abandon) await until(() => ranges.length == 3);
        await until(
          () => cacheFile.existsSync() && downloader.activeSongId == null,
        );
        expect(ranges, [null, 'bytes=$prefix-', if (abandon) null]);
        expect(cacheFile.readAsBytesSync(), bytes);
      },
    );
  }

  test('remote warm-up stops after bytes when Range is ignored', () async {
    final previousHttp = HttpOverrides.current;
    HttpOverrides.global = null;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final firstBytes = Completer<void>();
    final release = Completer<void>();
    server.listen((request) async {
      try {
        request.response
          ..bufferOutput = false
          ..contentLength = 100 * 1024
          ..add(List<int>.filled(40 * 1024, 1));
        await request.response.flush();
        if (request.headers.value(HttpHeaders.rangeHeader) == 'bytes=0-1' &&
            !firstBytes.isCompleted) {
          firstBytes.complete();
        }
        await release.future;
        request.response.add(List<int>.filled(60 * 1024, 1));
        await request.response.close();
      } on HttpException {
        // The probe closes the ignored-range response after its first chunk.
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
    final directory = await Directory.systemTemp.createTemp('navis-warmup-');
    final (handler, player, database) = await createHandler(
      directory,
      1,
      sidecarStreams: true,
      readApiClient: () => api,
    );
    final song = (await database.libraryDao.getSongsByIds(['song-0'])).single;
    final replacing = handler.replaceQueueWithData([
      song.copyWith(isExternal: true),
    ], expandMatchFlows: false);
    addTearDown(() async {
      release.complete();
      await replacing;
      await handler.disposeHandler();
      await database.close();
      await server.close(force: true);
      await directory.delete(recursive: true);
      HttpOverrides.global = previousHttp;
    });
    await firstBytes.future.timeout(const Duration(seconds: 2));
    for (
      var attempt = 0;
      attempt < 100 && player.sourceIds.isEmpty;
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(player.sourceIds, ['song-0']);
    expect(release.isCompleted, isFalse);
  });

  test('begin then dispose cancels an in-flight sidecar client', () async {
    final directory = await Directory.systemTemp.createTemp(
      'navis-teardown-sidecar-',
    );
    final client = TeardownHttpClient();
    await HttpOverrides.runZoned(() async {
      final (handler, _, database) = await createHandler(
        directory,
        1,
        sidecarStreams: true,
        artworkFileService: TeardownArtworkService(),
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      await handler.replaceQueue(['song-0'], expandMatchFlows: false);
      await client.requested.future.timeout(const Duration(seconds: 2));
      handler.beginTeardown();
      await handler.disposeHandler();
      await pumpEventQueue();
      expect(client.closed, isTrue);
      expect(
        handler.collectPlaybackDiagnostics()['sidecarCacheActiveSongId'],
        isNull,
      );
    }, createHttpClient: (_) => client);
  });

  test(
    'radio refuses non-HTTP schemes before loading a player source',
    () async {
      final directory = Directory.systemTemp.createTempSync('radio-schemes-');
      final (handler, player, database) = await createHandler(directory, 0);
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        directory.deleteSync(recursive: true);
      });
      for (final url in [
        'file:///tmp/audio',
        'lavfi://test',
        'edl://test',
        'intent://test',
        'https:///missing-host',
      ]) {
        await expectLater(
          handler.playRadioStream(
            stationId: 'fixture',
            stationName: 'Fixture',
            streamUrl: url,
          ),
          throwsArgumentError,
        );
        expect(player.queuedSources, isEmpty);
        expect(handler.mediaItem.value, isNull);
      }
    },
    skip: !sqliteAvailable,
  );

  for (final path in [
    'stream',
    'listen/fixture/stream',
    'hls/fixture/live.m3u8',
  ]) {
    test('radio polling uses only AzuraCast stream shape: $path', () async {
      final dio = MockRadioDio();
      final requested = <String>[];
      when(
        () => dio.get<Map<String, dynamic>>(
          any(),
          options: any(named: 'options'),
        ),
      ).thenAnswer((invocation) async {
        requested.add(invocation.positionalArguments.first as String);
        return Response<Map<String, dynamic>>(
          requestOptions: RequestOptions(),
          statusCode: 200,
          data: {
            'now_playing': {
              'song': {'title': 'Track'},
            },
          },
        );
      });
      final directory = Directory.systemTemp.createTempSync('radio-url-');
      final (handler, _, database) = await createHandler(
        directory,
        0,
        readRadioMetadataAllowed: () => true,
        createRadioMetadataDio: () => dio,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        directory.deleteSync(recursive: true);
      });
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: 'https://radio.example.invalid/$path',
        homePageUrl: 'http://192.168.1.2/public/secret',
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        requested,
        path == 'stream'
            ? isEmpty
            : equals(['https://radio.example.invalid/api/nowplaying/fixture']),
      );
      expect(handler.mediaItem.value!.extras, {'isRadio': true});
      handler.updateRadioMetadata(title: 'Changed');
      expect(handler.mediaItem.value!.extras, {'isRadio': true});
    }, skip: !sqliteAvailable);
  }

  for (final initiallyAllowed in [true, false]) {
    test(
      'radio policy refresh resumes polling (initially $initiallyAllowed)',
      () async {
        var allowed = initiallyAllowed;
        var requests = 0;
        final dio = MockRadioDio();
        when(
          () => dio.get<Map<String, dynamic>>(
            any(),
            options: any(named: 'options'),
          ),
        ).thenAnswer((_) async {
          requests++;
          return Response<Map<String, dynamic>>(
            requestOptions: RequestOptions(),
            statusCode: 200,
            data: {
              'now_playing': {
                'song': {'title': 'Song', 'artist': 'Artist'},
              },
            },
          );
        });
        final directory = Directory.systemTemp.createTempSync('radio-policy-');
        final (handler, _, database) = await createHandler(
          directory,
          0,
          readRadioMetadataAllowed: () => allowed,
          createRadioMetadataDio: () => dio,
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          directory.deleteSync(recursive: true);
        });
        await handler.playRadioStream(
          stationId: 'fixture',
          stationName: 'Fixture',
          streamUrl: 'https://radio.example.invalid/listen/fixture/stream',
        );
        await Future<void>.delayed(Duration.zero);
        expect(requests, initiallyAllowed ? 1 : 0);
        allowed = false;
        handler.updateRadioMetadata();
        // The policy refresh stops polling synchronously.
        final before = requests;
        allowed = true;
        handler.updateRadioMetadata();
        await Future<void>.delayed(Duration.zero);
        expect(requests, before + 1);
        final radio =
            handler.collectPlaybackDiagnostics()['radio']!
                as Map<String, Object?>;
        expect(radio['metadataSource'], 'azuracast');
        expect(radio['nowPlayingTitle'], 'Song');
        expect(radio['nowPlayingArtist'], 'Artist');
      },
    );
  }

  for (final icyTitle in <String?>[null, 'ICY Song', 'ICY Artist - ICY Song']) {
    test('disabling radio lookups replaces Azuracast with $icyTitle', () async {
      var allowed = true;
      final dio = MockRadioDio();
      when(
        () => dio.get<Map<String, dynamic>>(
          any(),
          options: any(named: 'options'),
        ),
      ).thenAnswer(
        (_) async => Response<Map<String, dynamic>>(
          requestOptions: RequestOptions(),
          statusCode: 200,
          data: {
            'now_playing': {
              'song': {
                'title': 'API Song',
                'artist': 'API Artist',
                'art': 'https://art.example.invalid/old.jpg',
              },
            },
          },
        ),
      );
      final directory = Directory.systemTemp.createTempSync('radio-disable-');
      final (handler, player, database) = await createHandler(
        directory,
        0,
        readRadioMetadataAllowed: () => allowed,
        readRadioArtworkAllowed: (_) => allowed,
        createRadioMetadataDio: () => dio,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        directory.deleteSync(recursive: true);
      });
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: 'https://radio.example.invalid/listen/fixture/stream',
      );
      await Future<void>.delayed(Duration.zero);
      expect(handler.mediaItem.value!.title, 'API Song');
      player.currentIcyMetadata = icyTitle == null
          ? null
          : IcyMetadata(
              info: IcyInfo(title: icyTitle, url: null),
              headers: null,
            );
      allowed = false;
      handler.updateRadioMetadata();
      final radio = handler.collectPlaybackDiagnostics()['radio']! as Map;
      expect(
        handler.mediaItem.value!.title,
        icyTitle == null ? 'Fixture' : 'ICY Song',
      );
      expect(
        handler.mediaItem.value!.artist,
        icyTitle != null && icyTitle.contains(' - ') ? 'ICY Artist' : 'Fixture',
      );
      expect(radio['metadataSource'], icyTitle == null ? 'none' : 'icy');
      expect(
        radio['nowPlayingArtist'],
        icyTitle != null && icyTitle.contains(' - ') ? 'ICY Artist' : null,
      );
      expect(radio['nowPlayingArtHash'], isNull);
      expect(radio['publishedArtHash'], isNull);
    });
  }

  for (final streamFailure in [false, true]) {
    test(
      'radio failure logs omit URLs carried by native errors ($streamFailure)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-radio-logs-',
        );
        const url = 'https://radio.example.invalid/private?token=fixture-token';
        final lines = <String>[];
        await runZoned(
          () async {
            final (handler, player, database) = await createHandler(
              directory,
              0,
            );
            addTearDown(() async {
              await handler.disposeHandler();
              await database.close();
              await directory.delete(recursive: true);
            });
            if (!streamFailure) {
              player
                ..loadGate = (Completer<void>()..complete())
                ..blockedLoadError = StateError(url);
              await expectLater(
                handler.playRadioStream(
                  stationId: 'fixture',
                  stationName: 'Fixture',
                  streamUrl: url,
                ),
                throwsA(isA<RadioPlaybackUnavailableException>()),
              );
            } else {
              await handler.playRadioStream(
                stationId: 'fixture',
                stationName: 'Fixture',
                streamUrl: url,
              );
              player.playbackEvents.addError(
                StateError(url),
                StackTrace.current,
              );
              await pumpEventQueue();
            }
          },
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => lines.add(line),
          ),
        );
        expect(lines, isNotEmpty);
        expect(lines.join('\n'), isNot(contains('fixture-token')));
        expect(lines.join('\n'), isNot(contains('/private')));
      },
    );
  }

  test('the saved queue restore times out after ten seconds by default', () {
    expect(
      const NavisPlaybackTimeouts().queueRestore,
      const Duration(seconds: 10),
    );
  });

  for (final streamFailure in [false, true]) {
    test(
      'radio restore timeout keeps saved queue (failure=$streamFailure)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-radio-restore-',
        );
        final rebuilt = <ControllableAudioPlayer>[];
        final (handler, player, database) = await createHandler(
          directory,
          3,
          rebuiltPlayers: rebuilt,
          // Shortened from the 10 s default; the 12 s native load deadline
          // stays far above it, so the restore timeout still fires first.
          timeouts: const NavisPlaybackTimeouts(
            queueRestore: Duration(seconds: 1),
          ),
        );
        final gate = Completer<void>();
        final entered = Completer<void>();
        addTearDown(() async {
          if (!gate.isCompleted) gate.complete();
          await pumpEventQueue();
          await handler.disposeHandler();
          player.keepStreamsAfterDispose = false;
          await player.dispose();
          await database.close();
          await directory.delete(recursive: true);
        });
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        await handler.debugFlushQueuePersistence();
        await handler.playRadioStream(
          stationId: 'fixture',
          stationName: 'Fixture',
          streamUrl: 'https://radio.example.invalid/stream',
        );
        player
          ..gateNonEmptyLoadsOnly = true
          ..loadGate = gate
          ..loadEntered = entered
          ..keepStreamsAfterDispose = true;
        if (streamFailure) {
          player.playbackEvents.addError(
            StateError('fixture radio failure'),
            StackTrace.current,
          );
        } else {
          await handler.stopRadio();
        }
        await entered.future.timeout(const Duration(seconds: 2));
        await until(
          () =>
              handler.collectPlaybackDiagnostics()['queueRestoreOutcome'] ==
                  'timeout' &&
              handler.debugQueueLaneIdle,
          // Below the 12 s native load deadline, which also ends in 'timeout'.
          cap: const Duration(seconds: 5),
          reason: 'the restore timeout fires and its recovery finishes',
        );
        // Keeping the saved queue must hold after a debounced write (300 ms)
        // would have landed, not only at the instant the lane went idle.
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(
          (await database.playQueueDao.getQueueItems()).map((song) => song.id),
          ['song-0', 'song-1'],
        );
        expect(handler.debugQueueLaneIdle, isTrue);
        expect(
          handler.collectPlaybackDiagnostics()['queueRestoreOutcome'],
          'timeout',
        );
        await handler.replaceQueue(['song-2'], expandMatchFlows: false);
        gate.complete();
        await settleQueue(handler);
        // The stale restore completes now; its late effects (and the 300 ms
        // persistence debounce of the new queue) must not undo the selection.
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(handler.snapshot.currentSongId, 'song-2');
        expect(
          (await database.playQueueDao.getQueueItems()).map((song) => song.id),
          ['song-2'],
        );
      },
    );
  }

  test(
    'published radio items keep the stream URL in handler state only',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-radio-url-',
      );
      final (handler, _, database) = await createHandler(directory, 0);
      final projection = RealTimeProjectionAudioHandler(handler);
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      const url = 'https://radio.example.invalid/listen?token=fixture-token';
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: url,
      );
      for (final update in [false, true]) {
        if (update) {
          handler.updateRadioMetadata(title: 'Track', artist: 'Artist');
        }
        await Future<void>.delayed(Duration.zero);
        expect(handler.snapshot.radioStation!.streamUrl, url);
        for (final item in [
          handler.mediaItem.value!,
          ...handler.queue.value,
          projection.mediaItem.value!,
          ...projection.queue.value,
        ]) {
          expect(item.extras, {'isRadio': true});
          expect(item.toString(), isNot(contains('fixture-token')));
        }
        expect(
          handler.collectPlaybackDiagnostics().toString(),
          isNot(contains('fixture-token')),
        );
      }
    },
  );

  group('radio playback adjustments', () {
    const saved = PlaybackAdjustments(speed: 1.5, pitchSemitones: 3);
    const station = 'https://radio.example.invalid/live';

    Future<(NavisAudioHandler, ControllableAudioPlayer)> setup() async {
      final directory = Directory.systemTemp.createTempSync('radio-adjust-');
      final (handler, player, database) = await createHandler(directory, 2);
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        directory.deleteSync(recursive: true);
      });
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      await handler.setPlaybackAdjustments(saved);
      return (handler, player);
    }

    void expectNeutral(ControllableAudioPlayer player) {
      expect(player.appliedSpeed, 1);
      expect(player.appliedPitch, 1);
    }

    void expectSaved(ControllableAudioPlayer player) {
      expect(player.appliedSpeed, saved.speed);
      expect(player.appliedPitch, closeTo(saved.pitchFactor, 1e-9));
    }

    test('radio plays at 1x and original pitch, saved values stay', () async {
      final (handler, player) = await setup();
      await handler.playRadioStream(
        stationId: 'a',
        stationName: 'A',
        streamUrl: station,
      );
      expectNeutral(player);
      expect(handler.playbackAdjustments, saved);
    });

    test('a speed change during radio is stored but not applied', () async {
      final (handler, player) = await setup();
      await handler.playRadioStream(
        stationId: 'a',
        stationName: 'A',
        streamUrl: station,
      );
      await handler.setPlaybackSpeed(1.25);
      expectNeutral(player);
      expect(handler.playbackAdjustments.speed, 1.25);
      await handler.playRadioStream(
        stationId: 'b',
        stationName: 'B',
        streamUrl: station,
      );
      expectNeutral(player);
    });

    test('stopping radio brings the saved values back', () async {
      final (handler, player) = await setup();
      await handler.playRadioStream(
        stationId: 'a',
        stationName: 'A',
        streamUrl: station,
      );
      await handler.stopRadio();
      await settleQueue(handler);
      expectSaved(player);
    });

    test('playing songs after radio brings the saved values back', () async {
      final (handler, player) = await setup();
      await handler.playRadioStream(
        stationId: 'a',
        stationName: 'A',
        streamUrl: station,
      );
      expectNeutral(player);
      await handler.replaceQueue(['song-1'], expandMatchFlows: false);
      await settleQueue(handler);
      expectSaved(player);
    });

    test(
      'a clear superseded by a song load still restores saved values',
      () async {
        final (handler, player) = await setup();
        await handler.playRadioStream(
          stationId: 'a',
          stationName: 'A',
          streamUrl: station,
        );
        expectNeutral(player);
        // clearQueue nulls the station synchronously; the replace cancels its
        // pending lane job, so only the replace can re-apply the saved values.
        unawaited(handler.clearQueue());
        await handler.replaceQueue(['song-1'], expandMatchFlows: false);
        await settleQueue(handler);
        expectSaved(player);
      },
    );

    test(
      'a speed change overlapping the stop sync is not overwritten',
      () async {
        final directory = Directory.systemTemp.createTempSync('radio-adjust-');
        final (handler, player, database) = await createHandler(directory, 0);
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          directory.deleteSync(recursive: true);
        });
        await handler.setPlaybackAdjustments(saved);
        await handler.playRadioStream(
          stationId: 'a',
          stationName: 'A',
          streamUrl: station,
        );
        player
          ..speedGate = Completer<void>()
          ..speedEntered = Completer<void>();
        final gate = player.speedGate!;
        final stopping = handler.stopRadio();
        await player.speedEntered!.future;
        final change = handler.setPlaybackSpeed(1.25);
        await pumpEventQueue();
        gate.complete();
        await Future.wait([stopping, change]);
        await settleQueue(handler);
        expect(handler.playbackAdjustments.speed, 1.25);
        expect(player.appliedSpeed, 1.25);
      },
    );

    test('radio recovery after a transient failure stays neutral', () async {
      var online = false;
      final recovered = StreamController<void>.broadcast();
      addTearDown(recovered.close);
      final directory = Directory.systemTemp.createTempSync('radio-adjust-');
      final (handler, player, database) = await createHandler(
        directory,
        0,
        reconcileNetwork: () async =>
            (connected: online, serverReachable: online),
        recoveredNetwork: recovered.stream,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        directory.deleteSync(recursive: true);
      });
      await handler.setPlaybackAdjustments(saved);
      await handler.playRadioStream(
        stationId: 'a',
        stationName: 'A',
        streamUrl: station,
      );
      final loads = player.sourceLoads;
      player
        ..state = ProcessingState.idle
        ..isPlaying = false;
      player.playbackEvents.add(
        PlaybackEvent(
          processingState: ProcessingState.idle,
          errorCode: 0,
          errorMessage: 'Source error',
        ),
      );
      await pumpEventQueue();
      online = true;
      recovered.add(null);
      await pumpEventQueue(times: 100);
      expect(player.sourceLoads, greaterThan(loads));
      expectNeutral(player);
    });
  });

  group('radio metadata lifecycle', () {
    Future<(NavisAudioHandler, ControllableAudioPlayer)> setup({
      Dio? dio,
      List<ControllableAudioPlayer>? rebuilt,
      NavisPlaybackTimeouts timeouts = const NavisPlaybackTimeouts(),
    }) async {
      final directory = Directory.systemTemp.createTempSync('radio-lifecycle-');
      final (handler, player, database) = await createHandler(
        directory,
        0,
        readRadioMetadataAllowed: () => dio != null,
        createRadioMetadataDio: dio == null ? null : () => dio,
        readRadioArtworkAllowed: (_) => true,
        rebuiltPlayers: rebuilt,
        timeouts: timeouts,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        directory.deleteSync(recursive: true);
      });
      await handler.playRadioStream(
        stationId: 'a',
        stationName: 'Station A',
        streamUrl: 'https://radio.example.invalid/listen/a/stream',
      );
      return (handler, player);
    }

    test(
      'superseded radio source failure completes without reporting error',
      () async {
        final (handler, player) = await setup();
        final gate = Completer<void>();
        final entered = Completer<void>();
        final stopsBeforeSwitch = player.stopCalls;
        player.loadGate = gate;
        player.loadEntered = entered;
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final oldLoad = handler.playRadioStream(
          stationId: 'b',
          stationName: 'Station B',
          streamUrl: 'https://stream.example.invalid/b',
        );
        final oldResult = expectLater(oldLoad, completes);
        await entered.future;
        final newLoad = handler.playRadioStream(
          stationId: 'c',
          stationName: 'Station C',
          streamUrl: 'https://stream.example.invalid/c',
        );
        gate.completeError(StateError('superseded load failed'));
        await oldResult;
        await newLoad;
        expect(player.stopCalls, stopsBeforeSwitch + 2);
        expect(handler.snapshot.radioStation?.stationId, 'c');
        expect(handler.mediaItem.value?.title, 'Station C');
        expect(player.playing, isTrue);
      },
    );

    for (final failLoad in [false, true]) {
      test(
        'station A late poll is dropped ${failLoad ? 'after B load failure' : 'during B load'}',
        () async {
          final dio = MockRadioDio();
          final pending = Completer<Response<Map<String, dynamic>>>();
          when(
            () => dio.get<Map<String, dynamic>>(
              any(),
              options: any(named: 'options'),
            ),
          ).thenAnswer((_) => pending.future);
          final (handler, player) = await setup(dio: dio);
          final gate = Completer<void>();
          final entered = Completer<void>();
          if (failLoad) {
            player.failLoadSongId = 'radio:b';
          } else {
            player.loadGate = gate;
            player.loadEntered = entered;
          }
          if (!failLoad) {
            addTearDown(() {
              if (!gate.isCompleted) gate.complete();
            });
          }
          final switching = handler.playRadioStream(
            stationId: 'b',
            stationName: 'Station B',
            streamUrl: 'https://stream.example.invalid/b',
          );
          if (failLoad) {
            await expectLater(
              switching,
              throwsA(isA<RadioPlaybackUnavailableException>()),
            );
          } else {
            await entered.future;
          }
          // Finish A's in-flight request while B has not started listening.
          pending.complete(
            Response<Map<String, dynamic>>(
              requestOptions: RequestOptions(),
              statusCode: 200,
              data: {
                'now_playing': {
                  'song': {
                    'title': 'Old Song',
                    'artist': 'Old Artist',
                    'art': 'https://art.example.invalid/old.jpg',
                  },
                },
              },
            ),
          );
          await Future<void>.delayed(Duration.zero);
          if (failLoad) {
            // Wait one interval to prove the failed load stopped A's timer.
            await Future<void>.delayed(
              RadioMetadataService.pollingInterval +
                  const Duration(milliseconds: 50),
            );
            handler.updateRadioMetadata();
            verify(
              () => dio.get<Map<String, dynamic>>(
                any(),
                options: any(named: 'options'),
              ),
            ).called(1);
            expect(handler.snapshot.radioStation, isNull);
          } else {
            expect(handler.snapshot.radioStation!.nowPlayingTitle, isNull);
            expect(handler.snapshot.radioStation!.nowPlayingArtUrl, isNull);
            expect(handler.mediaItem.value!.title, isNot('Old Song'));
            final radio = handler.collectPlaybackDiagnostics()['radio']! as Map;
            expect(radio['metadataSource'], 'none');
            gate.complete();
            await switching;
          }
        },
      );
    }

    test(
      'diagnostics drops previous station art while the next source loads',
      () async {
        final (handler, player) = await setup();
        handler.updateRadioMetadata(
          title: 'Old Song',
          artUrl: 'https://art.example.invalid/old.jpg',
        );
        expect(
          (handler.collectPlaybackDiagnostics()['radio']!
              as Map)['publishedArtHash'],
          '522085851bcf10e0',
        );
        final gate = Completer<void>();
        final entered = Completer<void>();
        player.loadGate = gate;
        player.loadEntered = entered;
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final switching = handler.playRadioStream(
          stationId: 'b',
          stationName: 'Station B',
          streamUrl: 'https://stream.example.invalid/b',
        );
        await entered.future;
        final radio = handler.collectPlaybackDiagnostics()['radio']! as Map;
        expect(radio['stationId'], 'b');
        expect(radio['publishedArtHash'], isNull);
        gate.complete();
        await switching;
        handler.updateRadioMetadata(
          artUrl: 'https://art.example.invalid/new.jpg',
        );
        expect(
          (handler.collectPlaybackDiagnostics()['radio']!
              as Map)['publishedArtHash'],
          'b46273cb236821e0',
        );
      },
    );

    test('player rebind preserves the displayed metadata source', () async {
      final rebuilt = <ControllableAudioPlayer>[];
      final (handler, player) = await setup(
        rebuilt: rebuilt,
        timeouts: const NavisPlaybackTimeouts(
          reset: Duration(milliseconds: 50),
        ),
      );
      player.currentIcyMetadata = IcyMetadata(
        info: IcyInfo(title: 'Artist - Song', url: null),
        headers: null,
      );
      await handler.stopRadio();
      await handler.playRadioStream(
        stationId: 'a',
        stationName: 'Station A',
        streamUrl: 'https://stream.example.invalid/a',
      );
      player.hang.add('stop');
      await expectLater(
        handler.playRadioStream(
          stationId: 'b',
          stationName: 'Station B',
          streamUrl: 'https://stream.example.invalid/b',
        ),
        throwsA(isA<PlaybackLoadTimeoutException>()),
      );
      expect(rebuilt, hasLength(1));
      final radio = handler.collectPlaybackDiagnostics()['radio']! as Map;
      expect(radio['nowPlayingTitle'], 'Song');
      expect(radio['metadataSource'], 'icy');
      player.hang.clear();
    });
  });

  group('radio artwork publication', () {
    const ownArt = 'https://music.example.org:4533/rest/getCoverArt?id=r1';
    const externalArt = 'https://art.example.invalid/cover.jpg';

    Future<NavisAudioHandler> radioHandler(
      bool Function(Uri) readRadioArtworkAllowed, {
      String? icyTitle,
      String streamUrl = 'https://example.invalid/stream',
    }) async {
      final directory = Directory.systemTemp.createTempSync('radio-art-');
      final (handler, player, database) = await createHandler(
        directory,
        0,
        readRadioArtworkAllowed: readRadioArtworkAllowed,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        directory.deleteSync(recursive: true);
      });
      if (icyTitle != null) {
        player.currentIcyMetadata = IcyMetadata(
          info: IcyInfo(title: icyTitle, url: null),
          headers: null,
        );
      }
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: streamUrl,
      );
      return handler;
    }

    test(
      'radio diagnostics report host only and no metadata before reception',
      () async {
        final handler = await radioHandler(
          (_) => true,
          streamUrl: 'https://fixture:placeholder@stream.example.invalid:8443/live?token=placeholder',
        );
        expect(handler.collectPlaybackDiagnostics()['radio'], {
          'stationId': 'fixture',
          'stationName': 'Fixture',
          'streamHost': 'stream.example.invalid',
          'metadataSource': 'none',
          'nowPlayingTitle': null,
          'nowPlayingArtist': null,
          'nowPlayingArtHost': null,
          'nowPlayingArtHash': null,
          'publishedArtHost': null,
          'publishedArtHash': null,
        });
        await handler.stopRadio();
        expect(handler.collectPlaybackDiagnostics()['radio'], isNull);
      },
    );

    test('radio artwork diagnostics redact credentials and retain identity', () async {
      final handler = await radioHandler((_) => true);
      const art =
          'https://fixture:placeholder@art.example.invalid:8443/private/cover'
          '?u=fixture&t=placeholder&s=placeholder&p=placeholder&token=placeholder#private';
      handler.updateRadioMetadata(artUrl: art);
      final radio = handler.collectPlaybackDiagnostics()['radio']! as Map;
      expect(radio, isNot(contains('nowPlayingArtUrl')));
      expect(radio, isNot(contains('publishedArtUri')));
      expect(radio['nowPlayingArtHost'], 'art.example.invalid');
      expect(radio['publishedArtHost'], 'art.example.invalid');
      final identity = radio['nowPlayingArtHash'];
      expect(identity, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(radio['publishedArtHash'], identity);
      expect(handler.collectPlaybackDiagnostics()['radio'], radio);
      expect(radio.toString(), isNot(contains('placeholder')));
      expect(radio.toString(), isNot(contains('/private')));
      handler.updateRadioMetadata(artUrl: '$art-changed');
      final changed = handler.collectPlaybackDiagnostics()['radio']! as Map;
      expect(changed['nowPlayingArtHash'], isNot(identity));
      expect(changed['publishedArtHash'], changed['nowPlayingArtHash']);
    });

    test(
      'radio diagnostics identify ICY metadata and published artwork',
      () async {
        var allowed = true;
        final handler = await radioHandler(
          (_) => allowed,
          icyTitle: 'ICY Artist - ICY Song',
        );
        var radio =
            handler.collectPlaybackDiagnostics()['radio']!
                as Map<String, Object?>;
        expect(radio['metadataSource'], 'icy');
        expect(radio['nowPlayingTitle'], 'ICY Song');
        expect(radio['nowPlayingArtist'], 'ICY Artist');
        handler.updateRadioMetadata(artUrl: externalArt);
        radio =
            handler.collectPlaybackDiagnostics()['radio']!
                as Map<String, Object?>;
        expect(radio['nowPlayingArtHost'], 'art.example.invalid');
        expect(radio['nowPlayingArtHash'], '006b2f45dd4bfe45');
        expect(radio['publishedArtHash'], radio['nowPlayingArtHash']);
        allowed = false;
        handler.updateRadioMetadata();
        radio =
            handler.collectPlaybackDiagnostics()['radio']!
                as Map<String, Object?>;
        expect(radio['nowPlayingArtHash'], isNull);
        expect(radio['publishedArtHash'], isNull);
        expect(radio['metadataSource'], 'icy');
        expect(handler.mediaItem.value!.title, 'ICY Song');
        expect(handler.mediaItem.value!.artist, 'ICY Artist');
      },
    );

    test(
      'publishes the original http(s) URL while the policy allows it',
      () async {
        final handler = await radioHandler((_) => true);
        handler.updateRadioMetadata(title: 'Track', artUrl: externalArt);
        expect(handler.mediaItem.value!.artUri, Uri.parse(externalArt));
        expect(handler.mediaItem.value!.artUri!.scheme, 'https');
        expect(handler.snapshot.radioStation!.nowPlayingArtUrl, externalArt);
      },
    );

    test('a refused URL is never published and refused art is cleared', () async {
      var allowed = true;
      final handler = await radioHandler((_) => allowed);
      handler.updateRadioMetadata(title: 'Track', artUrl: externalArt);
      expect(handler.mediaItem.value!.artUri, isNotNull);

      // The policy changes while the station plays: the next update clears it.
      allowed = false;
      handler.updateRadioMetadata();
      expect(handler.mediaItem.value!.artUri, isNull);
      expect(handler.snapshot.radioStation!.nowPlayingArtUrl, isNull);

      handler.updateRadioMetadata(
        title: 'Next',
        artUrl: 'https://art.example.invalid/next.jpg',
      );
      expect(handler.mediaItem.value!.artUri, isNull);

      allowed = true;
      handler.updateRadioMetadata(
        title: 'Allowed',
        artUrl: 'https://art.example.invalid/allowed.jpg',
      );
      expect(
        handler.mediaItem.value!.artUri,
        Uri.parse('https://art.example.invalid/allowed.jpg'),
      );
    });

    test(
      'own-server art survives Online services off, external art does not',
      () async {
        var policy = const IntegrationPolicy();
        final handler = await radioHandler(
          (uri) => integrationAllowsRadioArtworkUri(
            policy,
            uri,
            serverHost: 'music.example.org',
          ),
        );
        handler.updateRadioMetadata(title: 'Own', artUrl: ownArt);
        expect(handler.mediaItem.value!.artUri, Uri.parse(ownArt));

        policy = const IntegrationPolicy(masterEnabled: false);
        handler.updateRadioMetadata();
        expect(handler.mediaItem.value!.artUri, Uri.parse(ownArt));

        handler.updateRadioMetadata(title: 'Away', artUrl: externalArt);
        expect(handler.mediaItem.value!.artUri, isNull);

        policy = const IntegrationPolicy(disabledKeys: {'radio.nowPlaying'});
        handler.updateRadioMetadata(title: 'Radio off', artUrl: externalArt);
        expect(handler.mediaItem.value!.artUri, isNull);
        handler.updateRadioMetadata(title: 'Own again', artUrl: ownArt);
        expect(handler.mediaItem.value!.artUri, Uri.parse(ownArt));
      },
    );

    test(
      'a non-http(s) URL is never published, even if a reader allows it',
      () async {
        final handler = await radioHandler((_) => true);
        for (final url in [
          'file:///data/user/0/app/cache/cover.jpg',
          'content://app.artwork/cover/x',
          'cover.jpg',
        ]) {
          handler.updateRadioMetadata(title: url, artUrl: url);
          expect(handler.mediaItem.value!.artUri, isNull, reason: url);
          expect(handler.snapshot.radioStation!.nowPlayingArtUrl, isNull);
        }
      },
    );

    test('without a readable policy no art is published', () async {
      final directory = Directory.systemTemp.createTempSync('radio-art-');
      final (handler, _, database) = await createHandler(directory, 0);
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        directory.deleteSync(recursive: true);
      });
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: 'https://example.invalid/stream',
      );
      handler.updateRadioMetadata(title: 'Track', artUrl: externalArt);
      expect(handler.mediaItem.value!.artUri, isNull);
    });
  });
}
