import 'dart:math';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;

import 'package:navis/src/features/player/domain/playback_adjustments.dart';

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart'
    show AudioServicePlatform;
import 'package:audio_service_platform_interface/no_op_audio_service.dart';
import 'package:audio_session/audio_session.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' show Value;
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/recommendation_service.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/data/scrobble_service.dart';
import 'package:navis/src/features/player/domain/streaming_quality.dart';

import 'navis_audio_handler_navigation_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    registerFallbackValue(const RadioFilters());
    // Linux and Windows default to the no-op platform; other hosts would talk
    // to unmocked audio_service plugin channels.
    AudioServicePlatform.instance = NoOpAudioService();
  });

  group('ReplayGain loudness (#313)', () {
    const mpv = PlaybackAdjustmentCapabilities.mediaKit;
    const exo = PlaybackAdjustmentCapabilities.android;
    double linearFactor(double db) => pow(10, db / 20).toDouble();

    // song-N carries gains[N]; a null entry is an untagged song. peaks[N] is
    // its track peak (a sample ratio), when given.
    Future<(NavisAudioHandler, ControllableAudioPlayer)> gained(
      List<double?> gains, {
      List<double?>? peaks,
      PlaybackAdjustmentCapabilities caps = exo,
      EqCapabilities? eq,
      bool crossfade = false,
      bool positionStreams = false,
      int? durationSeconds,
      String mode = 'track',
      String Function()? readMode,
      double untagged = replayGainFallbackUntaggedDb,
      bool Function(Uri)? radioAllowed,
      bool? pipeline,
    }) async {
      final directory = await Directory.systemTemp.createTemp('navis-rg-');
      final (handler, player, database) = await createHandler(
        directory,
        gains.length,
        replayGainInPipeline: pipeline,
        replayGainMode: mode,
        readReplayGainMode: readMode,
        replayGainUntaggedDb: untagged,
        adjustmentCapabilities: caps,
        equalizerCapabilities: eq,
        crossfade: crossfade,
        positionStreams: positionStreams,
        readRadioPlaybackAllowed: radioAllowed,
        seed: (database) async {
          for (var i = 0; i < gains.length; i++) {
            await (database.update(
              database.songsTable,
            )..where((song) => song.id.equals('song-$i'))).write(
              SongsTableCompanion(
                replayGainTrackGain: Value(gains[i]),
                replayGainTrackPeak: Value(peaks?.elementAtOrNull(i)),
                duration: Value(durationSeconds),
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
      return (handler, player);
    }

    test('mpv applies the gain in its filter chain, not the volume', () async {
      final (handler, player) = await gained(
        [-10.5],
        caps: mpv,
        pipeline: true,
      );
      await handler.setVolume(0.25);
      await handler.replaceQueue(['song-0'], expandMatchFlows: false);
      expect(handler.replayGainInPipeline, isTrue);
      expect(player.volume, 0.25);
      expect(player.sourceGains.any((g) => g.db == -10.5), isTrue);
    });

    test('ExoPlayer volume is linear', () async {
      final (handler, player) = await gained([-10.5], caps: exo);
      await handler.setVolume(0.25);
      await handler.replaceQueue(['song-0'], expandMatchFlows: false);
      expect(player.volume, closeTo(0.25 * linearFactor(-10.5), 0.00001));
    });

    for (final (name, caps) in [('mpv', mpv), ('ExoPlayer', exo)]) {
      test('a +14.4 dB song never exceeds the slider ($name)', () async {
        final (handler, player) = await gained([14.4], caps: caps);
        await handler.setVolume(0.25);
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        expect(player.volume, 0.25);
      });
    }

    // The by-URI boost channel mpv used before the filter chain (#392); only
    // the generic non-Android path still speaks it, and phase 5 removes both.
    group('boost', () {
      test(
        'a quiet song with room is turned up on mpv, not by the volume',
        () async {
          final (handler, player) = await gained(
            [6, -10.5],
            peaks: [0.1, 0.5],
            caps: mpv,
            pipeline: false,
          );
          await handler.setVolume(0.25);
          await handler.replaceQueue([
            'song-0',
            'song-1',
          ], expandMatchFlows: false);
          expect(handler.replayGainBoostSupported, isTrue);
          expect(player.volume, 0.25, reason: 'the cut is 0 dB');
          expect(handler.currentReplayGainDecision?.boostDb, 6);
          expect(handler.currentReplayGainDecision?.db, 6);
          final sent = player.boostMessages.last;
          expect(sent.currentDb, 6);
          expect(sent.bySongId, {'song-0': 6.0, 'song-1': 0.0});
        },
      );

      test('a cut song sends no boost and keeps its volume cut', () async {
        final (handler, player) = await gained(
          [-10.5],
          peaks: [0.1],
          caps: mpv,
          pipeline: false,
        );
        await handler.setVolume(0.25);
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        expect(player.volume, closeTo(0.25 * linearFactor(-10.5), 0.00001));
        expect(player.boostMessages.last.currentDb, 0);
      });

      test('a song without a peak is never boosted', () async {
        final (handler, player) = await gained([6], caps: mpv, pipeline: false);
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        expect(player.boostMessages.last.currentDb, 0);
        expect(handler.currentReplayGainDecision?.boostDb, 0);
      });

      test('the boost stops 1 dB under the peak ceiling', () async {
        // Peak 0.5 -> ceiling 6.02 dB -> boost 5.02 dB.
        final (handler, player) = await gained(
          [9],
          peaks: [0.5],
          caps: mpv,
          pipeline: false,
        );
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        expect(
          player.boostMessages.last.currentDb,
          closeTo(20 * log(2) / ln10 - 1, 0.001),
        );
      });

      test('skipping sends the next song\'s own boost', () async {
        final (handler, player) = await gained(
          [6, 3],
          peaks: [0.1, 0.1],
          caps: mpv,
          pipeline: false,
        );
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        expect(player.boostMessages.last.currentDb, 6);
        await handler.skipToNext();
        await settleQueue(handler);
        expect(player.boostMessages.last.currentDb, 3);
      });

      test('a settings change re-sends the boost', () async {
        var mode = 'track';
        final (handler, player) = await gained(
          [6],
          peaks: [0.1],
          caps: mpv,
          pipeline: false,
          readMode: () => mode,
        );
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        expect(player.boostMessages.last.currentDb, 6);
        mode = 'off';
        await handler.applyRuntimeSettings();
        await pumpEventQueue();
        expect(player.boostMessages.last.currentDb, 0);
        expect(handler.currentReplayGainDecision?.db, isNull);
      });

      test(
        'ExoPlayer has no boost stage: nothing is sent, boost is 0',
        () async {
          final (handler, player) = await gained([6], peaks: [0.1], caps: exo);
          await handler.replaceQueue(['song-0'], expandMatchFlows: false);
          expect(handler.replayGainBoostSupported, isFalse);
          expect(player.boostMessages, isEmpty);
          expect(handler.currentReplayGainDecision?.boostDb, 0);
          expect(handler.currentReplayGainDecision?.db, 0);
          expect(
            (handler.collectPlaybackDiagnostics()['replayGain']
                as Map<String, Object?>)['boostDb'],
            0,
          );
        },
      );

      test('diagnostics report the cut and the boost', () async {
        final (handler, _) = await gained(
          [6],
          peaks: [0.1],
          caps: mpv,
          pipeline: false,
        );
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        final json =
            handler.collectPlaybackDiagnostics()['replayGain']
                as Map<String, Object?>;
        expect(json['cutDb'], 0);
        expect(json['boostDb'], 6);
        expect(json['db'], 6);
      });

      group('on iOS (I24)', () {
        const ios = PlaybackAdjustmentCapabilities.ios;

        test(
          'the tap boosts and sends the per-file map, nothing else',
          () async {
            final (handler, player) = await gained(
              [6, -10.5],
              peaks: [0.1, 0.5],
              caps: ios,
              eq: EqCapabilities.available,
              durationSeconds: 200,
            );
            await handler.replaceQueue([
              'song-0',
              'song-1',
            ], expandMatchFlows: false);
            expect(handler.replayGainBoostSupported, isTrue);
            expect(handler.currentReplayGainDecision?.boostDb, 6);
            expect(
              player.volume,
              1,
              reason: 'the boost never touches the volume',
            );
            final sent = player.boostMessages.last;
            expect(sent.currentDb, 6);
            expect(sent.bySongId, {'song-0': 6.0, 'song-1': 0.0});
            expect(
              sent.durationMsBySongId,
              {'song-0': 200000, 'song-1': 200000},
              reason:
                  'the tag durations time the guard when the player is wrong',
            );
          },
        );

        test('a skip sends the next song\'s own boost, unguarded', () async {
          final (handler, player) = await gained(
            [6, 3],
            peaks: [0.1, 0.1],
            caps: ios,
            eq: EqCapabilities.available,
          );
          await handler.replaceQueue([
            'song-0',
            'song-1',
          ], expandMatchFlows: false);
          await handler.skipToNext();
          await settleQueue(handler);
          final sent = player.boostMessages.last;
          expect(sent.currentDb, 3);
          expect(
            player.boostMessages.where(
              (message) =>
                  message.bySongId.isNotEmpty && message.currentDb == 0,
            ),
            isEmpty,
            reason: 'no lower-to-0 before a command on iOS',
          );
        });

        test(
          'a cut song gets no boost and its cut rides the item mix',
          () async {
            final (handler, player) = await gained(
              [-3, 6],
              peaks: [0.98, 0.1],
              caps: ios,
              eq: EqCapabilities.available,
            );
            await handler.replaceQueue([
              'song-0',
              'song-1',
            ], expandMatchFlows: false);
            expect(
              player.volume,
              1,
              reason: 'the cut is in the item audio mix',
            );
            expect(player.sourceGains.first.db, -3);
            expect(player.boostMessages.last.currentDb, 0);
            expect(player.boostMessages.last.bySongId, {
              'song-0': 0.0,
              'song-1': 6.0,
            });
          },
        );

        test('radio gets no stamp and no level with the tap (I26)', () async {
          final (handler, player) = await gained(
            [-3],
            caps: ios,
            eq: EqCapabilities.available,
            radioAllowed: (_) => true,
          );
          await handler.setVolume(0.5);
          await handler.playRadioStream(
            stationId: 'fixture',
            stationName: 'Fixture',
            streamUrl: 'https://radio.example/live',
          );
          await handler.applyRuntimeSettings();
          await pumpEventQueue();
          expect(player.volume, 0.5);
          expect(
            player.levelMessages.expand((m) => m.entries).map((e) => e.songId),
            isNot(contains('fixture')),
          );
        });

        test(
          'an untagged song is stamped with the untagged level (I26)',
          () async {
            final (handler, player) = await gained(
              [null],
              caps: ios,
              eq: EqCapabilities.available,
              untagged: -12,
            );
            await handler.replaceQueue(['song-0'], expandMatchFlows: false);
            expect(player.sourceGains.first.db, -12);
            expect(player.levelMessages.last.bySongId, {'song-0': -12.0});
            expect(player.volume, 1);
          },
        );

        test('a settings change re-sends the map', () async {
          var mode = 'track';
          final (handler, player) = await gained(
            [6],
            peaks: [0.1],
            caps: ios,
            eq: EqCapabilities.available,
            readMode: () => mode,
          );
          await handler.replaceQueue(['song-0'], expandMatchFlows: false);
          expect(player.boostMessages.last.bySongId, {'song-0': 6.0});
          mode = 'off';
          await handler.applyRuntimeSettings();
          await pumpEventQueue();
          expect(player.boostMessages.last.currentDb, 0);
          expect(player.boostMessages.last.bySongId, {'song-0': 0.0});
        });

        test('status reports what the tap applied and its guard', () async {
          final (handler, player) = await gained(
            [6],
            peaks: [0.1],
            caps: ios,
            eq: EqCapabilities.available,
          );
          player.nativeEqualizerState = const EqualizerStateMessage(
            enabled: true,
            boostRequestedDb: 6,
            boostAppliedDb: 6,
            boostGuarded: true,
            boostClipSamples: 2,
          );
          await handler.replaceQueue(['song-0'], expandMatchFlows: false);
          await handler.refreshEqualizerState();
          final boost =
              handler.collectPlaybackDiagnostics()['replayGainBoost']
                  as Map<String, Object?>;
          expect(boost['requestedDb'], 6);
          expect(boost['appliedDb'], 6);
          expect(boost['guarded'], isTrue);
          expect(boost['clipSamples'], 2);
        });

        test('without the EQ pipeline (a rebuild) nothing is sent', () async {
          final (handler, player) = await gained(
            [6],
            peaks: [0.1],
            caps: ios,
            eq: EqCapabilities.unavailable,
          );
          await handler.replaceQueue(['song-0'], expandMatchFlows: false);
          expect(handler.replayGainBoostSupported, isFalse);
          expect(player.boostMessages, isEmpty);
          expect(handler.currentReplayGainDecision?.boostDb, 0);
          expect(
            handler.collectPlaybackDiagnostics()['replayGainBoost'],
            isNull,
          );
        });
      });
    });

    test('an untagged song takes the fallback level', () async {
      final (handler, player) = await gained([null, -10.5], caps: exo);
      await handler.setVolume(0.25);
      await handler.replaceQueue(['song-0'], expandMatchFlows: false);
      expect(player.volume, closeTo(0.25 * linearFactor(-8), 0.00001));
    });

    test('the untagged level comes from the runtime settings', () async {
      final (handler, player) = await gained([null], caps: exo, untagged: -12);
      await handler.replaceQueue(['song-0'], expandMatchFlows: false);
      expect(player.volume, closeTo(linearFactor(-12), 0.00001));
    });

    test('a garbage +918 dB tag is treated as untagged', () async {
      final (handler, player) = await gained([918], caps: exo);
      await handler.replaceQueue(['song-0'], expandMatchFlows: false);
      expect(player.volume, closeTo(linearFactor(-8), 0.00001));
    });

    test('off leaves the slider volume alone, tagged or not', () async {
      final (handler, player) = await gained([-10.5, null], mode: 'off');
      await handler.setVolume(0.25);
      await handler.replaceQueue(['song-0'], expandMatchFlows: false);
      expect(player.volume, 0.25);
    });

    test(
      'a mid-song mode change re-applies on the next settings pass',
      () async {
        var mode = 'track';
        final (handler, player) = await gained(
          [-10.5],
          caps: exo,
          readMode: () => mode,
        );
        await handler.setVolume(0.5);
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        expect(player.volume, closeTo(0.5 * linearFactor(-10.5), 0.00001));
        mode = 'off';
        await handler.applyRuntimeSettings();
        await pumpEventQueue();
        expect(player.volume, 0.5);
        mode = 'album';
        await handler.applyRuntimeSettings();
        await pumpEventQueue();
        // Album mode falls back to the track gain of a song without album gain.
        expect(player.volume, closeTo(0.5 * linearFactor(-10.5), 0.00001));
      },
    );

    test('moving the slider keeps the gain ratio', () async {
      final (handler, player) = await gained([-10.5], caps: exo);
      await handler.replaceQueue(['song-0'], expandMatchFlows: false);
      await handler.setVolume(0.5);
      final half = player.volume;
      await handler.setVolume(0.25);
      expect(player.volume / 0.25, closeTo(half / 0.5, 0.00001));
      expect(player.volume, closeTo(0.25 * linearFactor(-10.5), 0.00001));
    });

    test('radio stays at the slider volume', () async {
      final (handler, player) = await gained(
        [-10.5],
        caps: mpv,
        radioAllowed: (_) => true,
      );
      await handler.setVolume(0.5);
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: 'https://radio.example/live',
      );
      await handler.applyRuntimeSettings();
      await handler.setVolume(0.4);
      expect(player.volume, 0.4);
    });

    test('a rebuilt player keeps the song ReplayGain level', () async {
      final directory = await Directory.systemTemp.createTemp('navis-rgr-');
      final rebuilt = <ControllableAudioPlayer>[];
      final (handler, player, database) = await createHandler(
        directory,
        3,
        replayGainMode: 'track',
        rebuiltPlayers: rebuilt,
        timeouts: const NavisPlaybackTimeouts(
          load: Duration(milliseconds: 300),
          reset: Duration(milliseconds: 150),
          control: Duration(milliseconds: 300),
        ),
        seed: (database) async {
          await (database.update(
            database.songsTable,
          )..where((song) => song.id.equals('song-0'))).write(
            const SongsTableCompanion(replayGainTrackGain: Value(-10)),
          );
        },
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      await handler.setVolume(0.5);
      await handler.replaceQueue([
        'song-0',
        'song-1',
        'song-2',
      ], expandMatchFlows: false);
      await pumpEventQueue();
      player.hang.add('removeAudioSourceAt');
      await handler
          .removeAt(2)
          .timeout(const Duration(seconds: 6))
          .catchError((Object _) {});
      await pumpEventQueue();
      expect(rebuilt, isNotEmpty);
      // The first write to the replacement player already carries the gain.
      expect(
        rebuilt.first.appliedVolumes.first,
        closeTo(0.5 * linearFactor(-10), 0.00001),
      );
    });

    for (final (name, caps, factor) in [('ExoPlayer', exo, linearFactor)]) {
      test('both cross-fade decks use the $name curve', () async {
        final directory = await Directory.systemTemp.createTemp('navis-rgf-');
        final (handler, outgoing, database) = await createHandler(
          directory,
          3,
          crossfade: true,
          replayGainMode: 'track',
          adjustmentCapabilities: caps,

          seed: (database) async {
            await (database.update(
              database.songsTable,
            )..where((song) => song.id.equals('song-0'))).write(
              const SongsTableCompanion(replayGainTrackGain: Value(-10)),
            );
            await (database.update(
              database.songsTable,
            )..where((song) => song.id.equals('song-1'))).write(
              const SongsTableCompanion(replayGainTrackGain: Value(-20)),
            );
          },
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        await handler.setVolume(0.8);
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        expect(outgoing.volume, closeTo(0.8 * factor(-10), 0.00001));
        final incoming = handler.debugInactiveDeck! as ControllableAudioPlayer;
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        for (
          var i = 0;
          i < 800 && !(incoming.playing && incoming.volume > 0);
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(incoming.volume, lessThan(0.8 * factor(-20) + 0.00001));
        await handler.debugCompleteCrossfade();
        expect(incoming.volume, closeTo(0.8 * factor(-20), 0.00001));
        expect(outgoing.playing, isFalse);
      });
    }
  });

  group('ReplayGain refresh after a sync', () {
    const mpv = PlaybackAdjustmentCapabilities.mediaKit;
    const exo = PlaybackAdjustmentCapabilities.android;
    double linear(double db) => pow(10, db / 20).toDouble();

    Future<(NavisAudioHandler, ControllableAudioPlayer, NavisDatabase)> queued(
      List<double?> gains, {
      List<double?>? peaks,
      PlaybackAdjustmentCapabilities caps = exo,
      bool crossfade = false,
      bool? pipeline,
    }) async {
      final directory = await Directory.systemTemp.createTemp('navis-rgq-');
      final (handler, player, database) = await createHandler(
        directory,
        gains.length,
        replayGainInPipeline: pipeline,
        crossfade: crossfade,
        replayGainMode: 'track',
        adjustmentCapabilities: caps,
        seed: (database) async {
          for (var i = 0; i < gains.length; i++) {
            await (database.update(
              database.songsTable,
            )..where((song) => song.id.equals('song-$i'))).write(
              SongsTableCompanion(
                replayGainTrackGain: Value(gains[i]),
                replayGainTrackPeak: Value(peaks?.elementAtOrNull(i)),
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
      await handler.replaceQueue([
        for (var i = 0; i < gains.length; i++) 'song-$i',
      ], expandMatchFlows: false);
      return (handler, player, database);
    }

    Future<void> retag(NavisDatabase database, String id, double? gain) =>
        (database.update(database.songsTable)
              ..where((song) => song.id.equals(id)))
            .write(SongsTableCompanion(replayGainTrackGain: Value(gain)));

    double? gainOf(MediaItem? item) =>
        item?.extras?['replayGainTrackGain'] as double?;

    test('queued songs take the new gain from the next song, never '
        'mid-song', () async {
      final (handler, player, database) = await queued([-6, -6, null]);
      expect(player.appliedVolumes.last, closeTo(linear(-6), 0.00001));
      for (final id in ['song-0', 'song-1', 'song-2']) {
        await retag(database, id, -12);
      }
      final writes = player.appliedVolumes.length;

      await handler.refreshQueuedSongReplayGain();

      final items = handler.queue.value;
      expect(gainOf(items[0]), -6, reason: 'the playing song keeps its gain');
      expect(gainOf(handler.currentMediaItem), -6);
      expect(gainOf(items[1]), -12);
      expect(gainOf(items[2]), -12, reason: 'untagged became tagged');
      expect(player.appliedVolumes, hasLength(writes), reason: 'no apply');
      // A later volume write for the playing song still uses its old gain.
      await handler.setVolume(0.5);
      expect(player.appliedVolumes.last, closeTo(0.5 * linear(-6), 0.00001));
      expect(handler.currentReplayGainDecision?.db, -6);

      await handler.skipToNext();
      await settleQueue(handler);
      expect(player.appliedVolumes.last, closeTo(0.5 * linear(-12), 0.00001));
    });

    test('the next song is boosted with its new gain', () async {
      final (handler, player, database) = await queued(
        [6, 3],
        peaks: [0.1, 0.1],
        caps: mpv,
        pipeline: false,
      );
      await retag(database, 'song-1', 5);

      await handler.refreshQueuedSongReplayGain();
      await handler.skipToNext();
      await settleQueue(handler);

      expect(player.boostMessages.last.currentDb, 5);
    });

    test('the next song\'s mpv boost holds its new gain before any skip '
        '(a natural join reads it)', () async {
      final (handler, player, database) = await queued(
        [6, 3],
        peaks: [0.1, 0.1],
        caps: mpv,
        pipeline: false,
      );
      await retag(database, 'song-1', 5);

      await handler.refreshQueuedSongReplayGain();

      final sent = player.boostMessages.last;
      expect(sent.bySongId['song-1'], 5);
      expect(sent.currentDb, 6, reason: 'the playing song keeps its boost');
    });

    test('the cross-fade incoming song keeps its gain', () async {
      final (handler, player, database) = await queued([
        -6,
        -6,
        -6,
      ], crossfade: true);
      await handler.debugStartCrossfade();
      final incoming = handler.debugInactiveDeck! as ControllableAudioPlayer;
      for (var i = 0; i < 800 && !incoming.playing; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      for (final id in ['song-0', 'song-1', 'song-2']) {
        await retag(database, id, -12);
      }
      final writes = player.appliedVolumes.length;
      final incomingWrites = incoming.appliedVolumes.length;

      await handler.refreshQueuedSongReplayGain();

      final items = handler.queue.value;
      expect(gainOf(items[0]), -6);
      expect(gainOf(items[1]), -6, reason: 'it is audible while fading in');
      expect(gainOf(items[2]), -12);
      expect(player.appliedVolumes, hasLength(writes));
      expect(incoming.appliedVolumes, hasLength(incomingWrites));
    });

    test('rapid refreshes queue one job at a time', () async {
      final (handler, _, database) = await queued([-6, -6]);
      final edits = handler.debugQueueEditCount;

      final first = handler.refreshQueuedSongReplayGain();
      final second = handler.refreshQueuedSongReplayGain();
      final third = handler.refreshQueuedSongReplayGain();
      expect(handler.debugQueueEditCount, edits + 1);
      await Future.wait([first, second, third]);

      // Once it has run, the next call is a new job and sees newer rows.
      await retag(database, 'song-1', -12);
      await handler.refreshQueuedSongReplayGain();
      expect(handler.debugQueueEditCount, edits + 2);
      expect(gainOf(handler.queue.value[1]), -12);
    });

    test('a refresh cancelled by a queue clear is not reused', () async {
      final (handler, _, _) = await queued([-6, -6]);
      // Hold the lane so the refresh is still waiting when the queue clears.
      final blocker = handler
          .addToQueue(['song-0'], expandMatchFlows: false)
          .catchError((Object _) {});
      final waiting = handler.refreshQueuedSongReplayGain();
      final swallowed = waiting.then<void>((_) {}, onError: (Object _) {});
      final cleared = handler.clearQueue().catchError((Object _) {});
      await Future.wait(<Future<void>>[blocker, swallowed, cleared]);

      final before = handler.debugQueueEditCount;
      await handler.refreshQueuedSongReplayGain().catchError((Object _) {});
      expect(handler.debugQueueEditCount, before + 1);
    });

    test('unchanged rows publish nothing', () async {
      final (handler, _, database) = await queued([-6, -6]);
      var emissions = 0;
      final subscription = handler.queue.skip(1).listen((_) => emissions++);
      addTearDown(subscription.cancel);
      // A row that left the library is left alone as well.
      await (database.delete(
        database.songsTable,
      )..where((song) => song.id.equals('song-1'))).go();

      await handler.refreshQueuedSongReplayGain();
      await pumpEventQueue();

      expect(emissions, 0);
      expect(gainOf(handler.queue.value[1]), -6);
    });
  });

  group('ReplayGain Smart mode', () {
    const exo = PlaybackAdjustmentCapabilities.android;
    double linear(double db) => pow(10, db / 20).toDouble();
    // Every song has a -10 dB track gain and a -4 dB album gain, so the
    // volume says which one the handler chose.
    final trackVolume = linear(-10);
    final albumVolume = linear(-4);

    // song-N belongs to albums[N]; a null entry has no album id.
    Future<(NavisAudioHandler, ControllableAudioPlayer)> smart(
      List<String?> albums, {
      String mode = 'smart',
      String Function()? readMode,
      double Function()? readUntagged,
      bool crossfade = false,
      PlaybackAdjustmentCapabilities caps = exo,
      EqCapabilities? eq,
      bool positionStreams = false,
      double trackGain = -10,
      double albumGain = -4,
      double? peak,
      bool? pipeline,
      List<ControllableAudioPlayer>? decks,
      void Function(NavisDatabase database)? onDatabase,
    }) async {
      final directory = await Directory.systemTemp.createTemp('navis-rgs-');
      final (handler, player, database) = await createHandler(
        directory,
        albums.length,
        players: decks,
        replayGainInPipeline: pipeline,
        crossfade: crossfade,
        replayGainMode: mode,
        readReplayGainMode: readMode,
        readReplayGainUntaggedDb: readUntagged,
        adjustmentCapabilities: caps,
        equalizerCapabilities: eq,
        positionStreams: positionStreams,
        seed: (database) async {
          await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
            for (final id in albums.whereType<String>().toSet())
              AlbumsTableCompanion.insert(id: id, name: id),
          ]);
          for (var i = 0; i < albums.length; i++) {
            await (database.update(
              database.songsTable,
            )..where((song) => song.id.equals('song-$i'))).write(
              SongsTableCompanion(
                albumId: Value(albums[i]),
                replayGainTrackGain: Value(trackGain),
                replayGainAlbumGain: Value(albumGain),
                replayGainTrackPeak: Value(peak),
                replayGainAlbumPeak: Value(peak),
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
      onDatabase?.call(database);
      return (handler, player);
    }

    List<String> ids(int count) => [for (var i = 0; i < count; i++) 'song-$i'];

    for (final start in [0, 1, 2]) {
      test(
        'an album in order plays at album gain from track ${start + 1}',
        () async {
          final (handler, player) = await smart(['a', 'a', 'a']);
          await handler.replaceQueue(
            ids(3),
            startIndex: start,
            expandMatchFlows: false,
          );
          expect(player.volume, closeTo(albumVolume, 0.00001));
        },
      );
    }

    test('a lone song plays at track gain', () async {
      final (handler, player) = await smart(['a']);
      await handler.replaceQueue(ids(1), expandMatchFlows: false);
      expect(player.volume, closeTo(trackVolume, 0.00001));
    });

    test('songs from mixed albums play at track gain', () async {
      final (handler, player) = await smart(['a', 'b', 'c']);
      await handler.replaceQueue(
        ids(3),
        startIndex: 1,
        expandMatchFlows: false,
      );
      expect(player.volume, closeTo(trackVolume, 0.00001));
    });

    test('songs without an album id play at track gain', () async {
      final (handler, player) = await smart([null, null, null]);
      await handler.replaceQueue(
        ids(3),
        startIndex: 1,
        expandMatchFlows: false,
      );
      expect(player.volume, closeTo(trackVolume, 0.00001));
    });

    test(
      'a queue edit mid-song keeps the volume until the next song',
      () async {
        final (handler, player) = await smart(['a', 'b', 'a']);
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        expect(player.volume, closeTo(trackVolume, 0.00001));
        // song-2 shares song-0's album and is now next, which would flip the
        // decision if it were taken again mid-song.
        await handler.playNext(['song-2'], expandMatchFlows: false);
        await settleQueue(handler);
        await handler.setVolume(1);
        expect(player.volume, closeTo(trackVolume, 0.00001));
        await handler.skipToNext();
        await settleQueue(handler);
        expect(handler.snapshot.currentSongId, 'song-2');
        expect(player.volume, closeTo(albumVolume, 0.00001));
      },
    );

    test('a boost send leaves the next song\'s cut unchanged', () async {
      // mpv has the boost stage, so every song start sends a boost message.
      const mpv = PlaybackAdjustmentCapabilities.mediaKit;
      final track = pow(10, -10 / 20).toDouble();
      final album = pow(10, -4 / 20).toDouble();
      final (handler, player) = await smart(
        ['a', 'b', 'a'],
        caps: mpv,
        pipeline: false,
      );
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      expect(player.boostMessages, isNotEmpty);
      expect(player.volume, closeTo(track, 0.00001));
      // song-2 shares song-0's album and is now next. A boost send reads it
      // without freezing, so its cut still follows its neighbours at its start.
      await handler.playNext(['song-2'], expandMatchFlows: false);
      await settleQueue(handler);
      final sent = player.boostMessages.length;
      await handler.applyRuntimeSettings();
      await pumpEventQueue();
      expect(player.boostMessages.length, greaterThan(sent));
      expect(player.volume, closeTo(track, 0.00001));
      await handler.skipToNext();
      await settleQueue(handler);
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(player.volume, closeTo(album, 0.00001));
    });

    test('an unrelated settings pass keeps a frozen decision', () async {
      var untagged = -8.0;
      final (handler, player) = await smart([
        'a',
        'b',
        'a',
      ], readUntagged: () => untagged);
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      await handler.playNext(['song-2'], expandMatchFlows: false);
      await settleQueue(handler);
      expect(player.volume, closeTo(trackVolume, 0.00001));
      await handler.applyRuntimeSettings();
      await pumpEventQueue();
      expect(player.volume, closeTo(trackVolume, 0.00001));
      untagged = -12;
      await handler.applyRuntimeSettings();
      await pumpEventQueue();
      expect(player.volume, closeTo(trackVolume, 0.00001));
    });

    test('a mode change re-resolves a frozen decision', () async {
      var mode = 'smart';
      final (handler, player) = await smart([
        'a',
        'b',
        'a',
      ], readMode: () => mode);
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      await handler.playNext(['song-2'], expandMatchFlows: false);
      await settleQueue(handler);
      expect(player.volume, closeTo(trackVolume, 0.00001));
      mode = 'track';
      await handler.applyRuntimeSettings();
      await pumpEventQueue();
      mode = 'smart';
      await handler.applyRuntimeSettings();
      await pumpEventQueue();
      expect(player.volume, closeTo(albumVolume, 0.00001));
    });

    test('a jump to another copy of the playing song re-resolves', () async {
      final (handler, player) = await smart(['a', 'a', 'b']);
      await handler.replaceQueue([
        'song-0',
        'song-1',
        'song-2',
        'song-0',
      ], expandMatchFlows: false);
      // First copy: next is the same album.
      expect(player.volume, closeTo(albumVolume, 0.00001));
      await handler.skipToQueueItem(3);
      await settleQueue(handler);
      expect(handler.snapshot.currentIndex, 3);
      // Last copy: preceded by another album, nothing after it.
      expect(player.volume, closeTo(trackVolume, 0.00001));
    });

    test('repeat all wraps the neighbours', () async {
      final (handler, player) = await smart(['a', 'b', 'a']);
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      await handler.replaceQueue(
        ids(3),
        startIndex: 2,
        expandMatchFlows: false,
      );
      // The last song is followed by the first, which is its album.
      expect(player.volume, closeTo(albumVolume, 0.00001));
    });

    test('repeat all does not make a lone song its own neighbour', () async {
      final (handler, player) = await smart(['a']);
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      await handler.replaceQueue(ids(1), expandMatchFlows: false);
      expect(player.volume, closeTo(trackVolume, 0.00001));
    });

    test('reading the decision for diagnostics freezes nothing', () async {
      var mode = 'track';
      final (handler, player) = await smart([
        'a',
        'b',
        'a',
      ], readMode: () => mode);
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      await handler.playNext(['song-2'], expandMatchFlows: false);
      await settleQueue(handler);
      mode = 'smart';
      // Next is song-2, the same album: reported as album, not stored.
      expect(
        (handler.collectPlaybackDiagnostics()['replayGain']
            as Map<String, Object?>)['resolvedMode'],
        'album',
      );
      await handler.removeAt(1);
      await settleQueue(handler);
      expect(player.volume, closeTo(trackVolume, 0.00001));
    });

    test('the public decision shows album gain once the queue settles and '
        'reading it freezes nothing', () async {
      var mode = 'track';
      final (handler, player) = await smart([
        'a',
        'b',
        'a',
      ], readMode: () => mode);
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      await handler.playNext(['song-2'], expandMatchFlows: false);
      await settleQueue(handler);
      mode = 'smart';
      final decision = handler.currentReplayGainDecision;
      expect(decision?.mode, 'smart');
      expect(decision?.resolvedMode, 'album');
      expect(decision?.source, ReplayGainSource.album);
      expect(decision?.db, closeTo(-4, 0.00001));
      // Read twice, then change the neighbours: nothing was stored.
      expect(handler.currentReplayGainDecision?.resolvedMode, 'album');
      await handler.removeAt(1);
      await settleQueue(handler);
      expect(player.volume, closeTo(trackVolume, 0.00001));
    });

    test('a lone song reads as track gain in the public decision', () async {
      final (handler, _) = await smart(['a']);
      await handler.replaceQueue(ids(1), expandMatchFlows: false);
      final decision = handler.currentReplayGainDecision;
      expect(decision?.resolvedMode, 'track');
      expect(decision?.source, ReplayGainSource.track);
      expect(decision?.db, closeTo(-10, 0.00001));
    });

    test('a replaced queue resolves the same song again', () async {
      final (handler, player) = await smart(['a', 'b', 'a']);
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      expect(player.volume, closeTo(trackVolume, 0.00001));
      await handler.replaceQueue(['song-0', 'song-2'], expandMatchFlows: false);
      expect(player.volume, closeTo(albumVolume, 0.00001));
    });

    test(
      'turning shuffle on keeps this song and re-resolves the next',
      () async {
        final (handler, player) = await smart(['a', 'a', 'b', 'a', 'b', 'a']);
        await handler.replaceQueue(ids(6), expandMatchFlows: false);
        expect(player.volume, closeTo(albumVolume, 0.00001));
        await handler.setShuffleMode(AudioServiceShuffleMode.all);
        await settleQueue(handler);
        expect(player.volume, closeTo(albumVolume, 0.00001));
        await handler.skipToNext();
        await settleQueue(handler);
        // The expected level comes from the neighbours in the new play order.
        final queue = handler.queue.value;
        final index = handler.snapshot.currentIndex!;
        String? album(int i) => i < 0 || i >= queue.length
            ? null
            : queue[i].extras?['albumId'] as String?;
        final resolved = resolveReplayGainMode(
          'smart',
          albumId: album(index),
          prevAlbumId: album(index - 1),
          nextAlbumId: album(index + 1),
        );
        expect(
          player.volume,
          closeTo(resolved == 'album' ? albumVolume : trackVolume, 0.00001),
        );
      },
    );

    test('a mode change applies at once', () async {
      var mode = 'track';
      final (handler, player) = await smart(['a', 'a'], readMode: () => mode);
      await handler.replaceQueue(ids(2), expandMatchFlows: false);
      expect(player.volume, closeTo(trackVolume, 0.00001));
      mode = 'smart';
      await handler.applyRuntimeSettings();
      await pumpEventQueue();
      expect(player.volume, closeTo(albumVolume, 0.00001));
      mode = 'track';
      await handler.applyRuntimeSettings();
      await pumpEventQueue();
      expect(player.volume, closeTo(trackVolume, 0.00001));
    });

    test(
      'the cross-fade incoming song resolves with its own neighbours',
      () async {
        final (handler, outgoing) = await smart([
          'a',
          'b',
          'b',
        ], crossfade: true);
        await handler.setVolume(0.8);
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        // song-0 sits next to another album: track gain.
        expect(outgoing.volume, closeTo(0.8 * trackVolume, 0.00001));
        final incoming = handler.debugInactiveDeck! as ControllableAudioPlayer;
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        for (
          var i = 0;
          i < 800 && !(incoming.playing && incoming.volume > 0);
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        // Mid-fade the next song is removed, which would flip song-1 to
        // track gain if its decision were taken again.
        await handler.removeAt(2);
        await handler.debugCompleteCrossfade();
        // song-1 was followed by song-2 of its own album: album gain.
        expect(incoming.volume, closeTo(0.8 * albumVolume, 0.00001));
      },
    );

    test('diagnostics report the decision', () async {
      final (handler, _) = await smart(['a', 'a']);
      await handler.replaceQueue(ids(2), expandMatchFlows: false);
      expect(handler.collectPlaybackDiagnostics()['replayGain'], {
        'mode': 'smart',
        'resolvedMode': 'album',
        'source': 'album',
        'db': -4.0,
        'cutDb': -4.0,
        'boostDb': 0.0,
      });
    });

    group('in the pipeline (#392)', () {
      // Every smart() song has -10 dB track and -4 dB album gain.
      Map<String?, double?> carried(
        ControllableAudioPlayer player,
        String op,
      ) => {
        for (final g in player.sourceGains.where((g) => g.op == op))
          g.songId: g.db,
      };

      test('load, add and the deck load carry the level', () async {
        final decks = <ControllableAudioPlayer>[];
        final (handler, player) = await smart(
          ['a', 'b', 'c', 'd'],
          mode: 'track',
          pipeline: true,
          crossfade: true,
          decks: decks,
        );
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        // The first song's level is in the message that loads it.
        expect(player.sourceGains.first.op, 'load');
        expect(player.sourceGains.first.songId, 'song-0');
        expect(player.sourceGains.first.db, -10);
        expect(
          player.sourceGains.every((g) => g.db == -10),
          isTrue,
          reason: '${player.sourceGains}',
        );
        expect(player.sequence.map((s) => s.replayGainDb), everyElement(-10));
        await handler.addToQueue(['song-3'], expandMatchFlows: false);
        expect(
          carried(player, 'add')['song-3'] ??
              carried(player, 'insert')['song-3'],
          -10,
        );
        // A deck that never played gets its songs with the level too.
        await handler.debugStartCrossfade();
        await pumpEventQueue();
        final deck = handler.debugInactiveDeck as ControllableAudioPlayer;
        expect(deck.sourceGains, isNotEmpty);
        expect(deck.sourceGains.every((g) => g.db == -10), isTrue);
      });

      test('off carries 0 dB, not nothing', () async {
        final (handler, player) = await smart(
          ['a'],
          mode: 'off',
          pipeline: true,
        );
        await handler.replaceQueue(ids(1), expandMatchFlows: false);
        expect(player.sourceGains.single.db, 0);
      });

      test('the fallback carries nothing and keeps today\'s cut', () async {
        final (handler, player) = await smart(['a'], mode: 'track');
        await handler.setVolume(0.25);
        await handler.replaceQueue(ids(1), expandMatchFlows: false);
        expect(player.sourceGains.single.db, isNull);
        expect(player.levelMessages, isEmpty);
        expect(player.volume, closeTo(0.25 * linear(-10), 0.00001));
      });

      test('the player volume is independent of ReplayGain', () async {
        final (handler, player) = await smart(
          ['a'],
          mode: 'track',
          pipeline: true,
        );
        await handler.setVolume(0.25);
        await handler.replaceQueue(ids(1), expandMatchFlows: false);
        expect(player.volume, 0.25);
      });

      test('the cross-fade ramps exclude ReplayGain', () async {
        final (handler, player) = await smart(
          ['a', 'b'],
          mode: 'track',
          pipeline: true,
          crossfade: true,
        );
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        await handler.debugStartCrossfade();
        await pumpEventQueue();
        final deck = handler.debugInactiveDeck as ControllableAudioPlayer;
        await handler.setVolume(0.4);
        // The two decks share the user volume; a -10 dB cut would scale it.
        expect(player.volume + deck.volume, closeTo(0.4, 0.00001));
      });

      test('only a settings change pushes live', () async {
        var mode = 'track';
        late NavisDatabase database;
        final (handler, player) = await smart(
          ['a', 'b'],
          readMode: () => mode,
          pipeline: true,
          onDatabase: (db) => database = db,
        );
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        await pumpEventQueue();
        expect(player.levelMessages, isNotEmpty);
        expect(player.levelMessages.any((m) => m.live), isFalse);
        expect(player.levelMessages.last.bySongId, {
          'song-0': -10.0,
          'song-1': -10.0,
        });
        // A real tag correction of the queued song pushes, and not live.
        final pushes = player.levelMessages.length;
        await (database.update(database.songsTable)
              ..where((song) => song.id.equals('song-1')))
            .write(const SongsTableCompanion(replayGainTrackGain: Value(-7)));
        await handler.refreshQueuedSongReplayGain();
        await pumpEventQueue();
        expect(player.levelMessages.length, greaterThan(pushes));
        expect(player.levelMessages.last.bySongId['song-1'], -7);
        expect(player.levelMessages.last.live, isFalse);
        await handler.skipToNext();
        await pumpEventQueue();
        expect(player.levelMessages.any((m) => m.live), isFalse);
        mode = 'album';
        await handler.applyRuntimeSettings();
        await pumpEventQueue();
        expect(player.levelMessages.last.live, isTrue);
        expect(player.levelMessages.last.bySongId, {
          'song-0': -4.0,
          'song-1': -4.0,
        });
      });

      test('a reload after a settings change carries the new level', () async {
        var mode = 'off';
        final (handler, player) = await smart(
          ['a', 'b', 'c'],
          readMode: () => mode,
          pipeline: true,
        );
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        await pumpEventQueue();
        expect(player.sequence.map((s) => s.replayGainDb), everyElement(0));
        mode = 'track';
        await handler.applyRuntimeSettings();
        await pumpEventQueue();
        // The tap lands while the player is loading: the handler reloads the
        // same source objects, which must carry the pushed level, not the
        // one they were inserted with.
        final loads = player.sourceGains.where((g) => g.op == 'load').length;
        player.state = ProcessingState.loading;
        await handler.skipToNext();
        await pumpEventQueue();
        final reloaded = player.sourceGains
            .where((g) => g.op == 'load')
            .skip(loads);
        expect(reloaded, hasLength(3));
        expect(reloaded.map((g) => g.db), everyElement(-10));
      });

      test('duplicates of a song are two entries with the level', () async {
        final (handler, player) = await smart(
          ['a', 'b'],
          mode: 'track',
          pipeline: true,
        );
        await handler.replaceQueue([
          'song-0',
          'song-1',
          'song-0',
        ], expandMatchFlows: false);
        await pumpEventQueue();
        final sources = player.sequence;
        expect(sources.length, 3);
        expect(sources.map((s) => s.replayGainDb), everyElement(-10));
        expect(player.sourceGains.where((g) => g.songId == 'song-0').length, 2);
      });

      test('the Smart start equals the last pushed value', () async {
        final (handler, player) = await smart(['a', 'a', 'b'], pipeline: true);
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        await pumpEventQueue();
        // song-1 is queued between a (before) and b (after): album gain.
        final pushed = player.levelMessages.last.bySongId['song-1'];
        expect(pushed, -4);
        await handler.skipToNext();
        await pumpEventQueue();
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(handler.currentReplayGainDecision?.db, pushed);
        expect(handler.currentReplayGainDecision?.resolvedMode, 'album');
      });

      group('Smart neighbours come from the list that will play', () {
        test('the first song of a replace reads the incoming list', () async {
          final (handler, player) = await smart([
            'a',
            'a',
            'a',
          ], pipeline: true);
          await handler.replaceQueue(ids(3), expandMatchFlows: false);
          await pumpEventQueue();
          // Its next neighbour is the same album: album gain, not the -10 an
          // empty queue's neighbours would give.
          expect(player.sourceGains.first.db, -4);
        });

        test('a replace over another queue ignores the old one', () async {
          final (handler, player) = await smart([
            'a',
            'b',
            'b',
            'b',
          ], pipeline: true);
          await handler.replaceQueue([
            'song-0',
            'song-1',
          ], expandMatchFlows: false);
          await pumpEventQueue();
          player.sourceGains.clear();
          await handler.replaceQueue([
            'song-2',
            'song-3',
          ], expandMatchFlows: false);
          await pumpEventQueue();
          final load = player.sourceGains.firstWhere((g) => g.op == 'load');
          expect(load.songId, 'song-2');
          expect(load.db, -4);
          // What native holds is what the start freezes and shows.
          expect(handler.currentReplayGainDecision?.db, -4);
        });

        test(
          'an insert between same-album neighbours carries album gain',
          () async {
            final (handler, player) = await smart([
              'a',
              'b',
              'b',
            ], pipeline: true);
            await handler.replaceQueue([
              'song-0',
              'song-1',
            ], expandMatchFlows: false);
            await pumpEventQueue();
            player.sourceGains.clear();
            // song-2 (b) goes between song-0 (a) and song-1 (b).
            await handler.playNext(['song-2'], expandMatchFlows: false);
            await pumpEventQueue();
            final inserted = player.sourceGains.firstWhere(
              (g) => g.songId == 'song-2',
            );
            expect(inserted.db, -4);
          },
        );

        test('a Smart freeze equals the last pushed pair when an edit lands '
            'before the next push', () async {
          // song-1 sits between x and a, so it is pushed at album gain.
          final (handler, player) = await smart([
            'x',
            'a',
            'a',
          ], pipeline: true);
          await handler.replaceQueue(ids(3), expandMatchFlows: false);
          await pumpEventQueue();
          expect(player.levelMessages.last.bySongId['song-1'], -4);
          // The native step to song-1 arrives while song-2 is being removed:
          // the queue then no longer matches what was pushed to native.
          final gate = Completer<void>();
          player
            ..removeGate = gate
            ..removeEntered = Completer<void>();
          final removing = handler.removeQueueItemAt(2);
          await player.removeEntered!.future;
          player
            ..index = 1
            ..emitIndexAgain();
          await pumpEventQueue();
          gate.complete();
          await removing;
          await settleQueue(handler);
          expect(handler.snapshot.currentSongId, 'song-1');
          // Native applied album gain; read from the edited queue it would be
          // track gain (no neighbour of its album is left).
          expect(handler.currentReplayGainDecision?.db, -4);
        });
      });

      test('repeat-all wrap neighbours reach the update push', () async {
        final (handler, player) = await smart(['a', 'b', 'a'], pipeline: true);
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        expect(player.levelMessages.last.bySongId['song-2'], -10);
        await handler.setRepeatMode(AudioServiceRepeatMode.all);
        player.emitLoopMode(LoopMode.all);
        await pumpEventQueue();
        // song-2 wraps to song-0, the same album. The playing song-0 stays
        // frozen at the pair it started with.
        expect(player.levelMessages.last.bySongId['song-2'], -4);
        expect(player.levelMessages.last.bySongId['song-0'], -10);
        expect(player.levelMessages.last.bySongId['song-1'], -10);
      });

      test('a push gives each duplicate its own neighbours', () async {
        // Entry 0 and 3 are the same song; entry 3 sits after another album.
        final (handler, player) = await smart(['a', 'b', 'a'], pipeline: true);
        await handler.replaceQueue([
          'song-0',
          'song-2',
          'song-1',
          'song-0',
        ], expandMatchFlows: false);
        await pumpEventQueue();
        List<double> gains() => [
          for (final e in player.levelMessages.last.entries) e.db,
        ];
        expect(gains(), [-4, -4, -10, -10]);
        await handler.skipToNext();
        await pumpEventQueue();
        // The update push keeps the level each entry was loaded with.
        expect(gains(), [-4, -4, -10, -10]);
      });

      test(
        'a push skips entries the queue does not name the same way',
        () async {
          final (handler, player) = await smart(['a', 'b'], pipeline: true);
          await handler.replaceQueue(ids(2), expandMatchFlows: false);
          await pumpEventQueue();
          // The deck holds the two songs in the other order for a moment.
          await player.setAudioSources(<AudioSource>[
            RangeCacheSource('song-1', File('${Directory.systemTemp.path}/rg')),
            RangeCacheSource('song-0', File('${Directory.systemTemp.path}/rg')),
          ]);
          player.levelMessages.clear();
          await handler.setRepeatMode(AudioServiceRepeatMode.all);
          player.emitLoopMode(LoopMode.all);
          await pumpEventQueue();
          expect(player.levelMessages.last.bySongId, isEmpty);
        },
      );

      test('a tag-less rolling-cache source still gets its update push', () async {
        final (handler, player) = await smart(['a', 'b'], pipeline: true);
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        await pumpEventQueue();
        // Android's lock-cached stream has no tag: only its URL names the song.
        await player.setAudioSources(<AudioSource>[
          RangeCacheSource('song-1', File('${Directory.systemTemp.path}/rg')),
        ]);
        player.levelMessages.clear();
        await handler.setRepeatMode(AudioServiceRepeatMode.all);
        player.emitLoopMode(LoopMode.all);
        await pumpEventQueue();
        expect(player.levelMessages.last.bySongId, {'song-1': -10.0});
      });

      test(
        'a settings change during a cross-fade pushes live afterwards',
        () async {
          var mode = 'track';
          final decks = <ControllableAudioPlayer>[];
          final (handler, player) = await smart(
            ['a', 'a'],
            readMode: () => mode,
            pipeline: true,
            crossfade: true,
            decks: decks,
          );
          await handler.replaceQueue(ids(2), expandMatchFlows: false);
          await pumpEventQueue();
          await handler.debugStartCrossfade();
          await pumpEventQueue();
          mode = 'album';
          await handler.applyRuntimeSettings();
          await pumpEventQueue();
          List<Map<String?, double>> live() => [
            for (final p in {player, ...decks})
              for (final m in p.levelMessages)
                if (m.live) m.bySongId,
          ];
          expect(live(), isEmpty, reason: 'the fade holds volume writes');
          await handler.debugCompleteCrossfade();
          await pumpEventQueue();
          expect(live(), isNotEmpty, reason: 'the change is not lost');
          expect(live().last, {'song-0': -4.0, 'song-1': -4.0});
        },
      );

      test('a non-live push leaves the heard entry pair alone', () async {
        // song-0 starts between nothing and a (album gain). An edit then
        // makes its next neighbour another album; a restart of song-0 still
        // freezes the pair its level was built from, which native holds.
        final (handler, player) = await smart(['a', 'a', 'b'], pipeline: true);
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        await pumpEventQueue();
        expect(handler.currentReplayGainDecision?.db, -4);
        await handler.removeQueueItemAt(1);
        await handler.playNext(['song-2'], expandMatchFlows: false);
        await settleQueue(handler);
        expect(player.levelMessages.last.live, isFalse);
        await handler.skipToQueueItem(0);
        await pumpEventQueue();
        expect(handler.snapshot.currentSongId, 'song-0');
        expect(handler.currentReplayGainDecision?.db, -4);
      });
    });

    // Android's processor is the pipeline stage: no override, the capability
    // follows the EQ processor (#392 phase 3b).
    group('on Android (#392)', () {
      const processor = EqCapabilities.available;
      final cut = linear(-10);

      test('the processor makes ReplayGain a pipeline stage', () async {
        final (handler, player) = await smart(
          ['a', 'b'],
          mode: 'track',
          eq: processor,
        );
        await handler.setVolume(0.25);
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        await pumpEventQueue();
        expect(handler.replayGainInPipeline, isTrue);
        expect(handler.replayGainBoostSupported, isTrue);
        expect(player.volume, 0.25, reason: 'the volume carries no gain');
        expect(player.sourceGains.first.op, 'load');
        expect(player.sourceGains.map((g) => g.db), everyElement(-10));
        expect(player.boostMessages, isEmpty, reason: 'no Dart-timed boost');
        expect(player.levelMessages.last.bySongId, {
          'song-0': -10.0,
          'song-1': -10.0,
        });
      });

      test('an added song and the cross-fade deck carry the level', () async {
        final decks = <ControllableAudioPlayer>[];
        final (handler, player) = await smart(
          ['a', 'b', 'c'],
          mode: 'track',
          eq: processor,
          crossfade: true,
          decks: decks,
        );
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        await handler.addToQueue(['song-2'], expandMatchFlows: false);
        expect(
          player.sourceGains.where((g) => g.songId == 'song-2').single.db,
          -10,
        );
        await handler.debugStartCrossfade();
        await pumpEventQueue();
        final deck = handler.debugInactiveDeck as ControllableAudioPlayer;
        expect(deck.sourceGains, isNotEmpty);
        expect(deck.sourceGains.map((g) => g.db), everyElement(-10));
        await handler.setVolume(0.4);
        expect(player.volume + deck.volume, closeTo(0.4, 0.00001));
      });

      test('live comes only from a settings change', () async {
        var mode = 'track';
        final (handler, player) = await smart(
          ['a', 'b'],
          eq: processor,
          readMode: () => mode,
        );
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        await handler.skipToNext();
        await pumpEventQueue();
        expect(player.levelMessages.any((m) => m.live), isFalse);
        mode = 'album';
        await handler.applyRuntimeSettings();
        await pumpEventQueue();
        expect(player.levelMessages.last.live, isTrue);
      });

      test('without the processor the Dart cut applies and nothing '
          'is stamped', () async {
        final (handler, player) = await smart(['a'], mode: 'track');
        await handler.setVolume(0.25);
        await handler.replaceQueue(ids(1), expandMatchFlows: false);
        expect(handler.replayGainInPipeline, isFalse);
        expect(handler.replayGainBoostSupported, isFalse);
        expect(player.sourceGains.single.db, isNull);
        expect(player.levelMessages, isEmpty);
        expect(player.boostMessages, isEmpty);
        expect(player.volume, closeTo(0.25 * cut, 0.00001));
      });

      test('a rebuild without the processor falls back to the cut', () async {
        final decks = <ControllableAudioPlayer>[];
        final (handler, player) = await smart(
          ['a', 'b'],
          mode: 'track',
          eq: processor,
          decks: decks,
        );
        await handler.setVolume(0.25);
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        expect(player.volume, 0.25);
        await handler.debugRebuildPlayerWithoutEqualizer();
        expect(handler.equalizerCapabilities.supported, isFalse);
        expect(handler.replayGainInPipeline, isFalse);
        expect(handler.replayGainBoostSupported, isFalse);
        final rebuilt = handler.debugActivePlayer as ControllableAudioPlayer;
        expect(rebuilt, isNot(same(player)));
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        await handler.applyRuntimeSettings();
        await pumpEventQueue();
        expect(rebuilt.sourceGains.map((g) => g.db), everyElement(isNull));
        expect(rebuilt.levelMessages, isEmpty);
        expect(rebuilt.volume, closeTo(0.25 * cut, 0.00001));
      });

      test('the status reports the key and gain native applies', () async {
        final (handler, player) = await smart(
          ['a'],
          mode: 'track',
          eq: processor,
        );
        player.nativeEqualizerState = const EqualizerStateMessage(
          enabled: false,
          replayGainCurrentKey: 'source-7',
          replayGainAppliedDb: -10,
          boostClipSamples: 4,
        );
        await handler.replaceQueue(ids(1), expandMatchFlows: false);
        await handler.refreshEqualizerState();
        final status =
            handler.collectPlaybackDiagnostics()['replayGainBoost']
                as Map<String, Object?>;
        expect(status['currentKey'], 'source-7');
        expect(status['appliedDb'], -10);
        expect(status['clipSamples'], 4);
      });

      test('the status has no stage block without the processor', () async {
        final (handler, _) = await smart(['a'], mode: 'track');
        await handler.replaceQueue(ids(1), expandMatchFlows: false);
        expect(handler.collectPlaybackDiagnostics()['replayGainBoost'], isNull);
      });
    });

    // The iOS equalizer tap makes ReplayGain a pipeline stage too (I26): the
    // cut is each item's audio-mix volume, the tap keeps the boost.
    group('on iOS with the tap (I26)', () {
      const ios = PlaybackAdjustmentCapabilities.ios;
      const tap = EqCapabilities.available;
      final cut = linear(-10);

      test(
        'the tap makes ReplayGain a stage and the boost still goes out',
        () async {
          final (handler, player) = await smart(
            ['a', 'b'],
            mode: 'track',
            caps: ios,
            eq: tap,
          );
          await handler.setVolume(0.25);
          await handler.replaceQueue(ids(2), expandMatchFlows: false);
          await pumpEventQueue();
          expect(handler.replayGainInPipeline, isTrue);
          expect(handler.replayGainBoostSupported, isTrue);
          expect(player.volume, 0.25, reason: 'the volume carries no gain');
          expect(player.sourceGains.first.op, 'load');
          expect(player.sourceGains.map((g) => g.db), everyElement(-10));
          expect(player.levelMessages.last.bySongId, {
            'song-0': -10.0,
            'song-1': -10.0,
          });
          expect(
            player.boostMessages,
            isNotEmpty,
            reason: 'the boost map stays',
          );
          expect(player.boostMessages.last.bySongId, {
            'song-0': 0.0,
            'song-1': 0.0,
          });
        },
      );

      test('a mode change pushes live, off pushes 0', () async {
        var mode = 'track';
        final (handler, player) = await smart(
          ['a', 'b'],
          caps: ios,
          eq: tap,
          readMode: () => mode,
        );
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        await pumpEventQueue();
        expect(player.levelMessages.any((m) => m.live), isFalse);
        mode = 'album';
        await handler.applyRuntimeSettings();
        await pumpEventQueue();
        expect(player.levelMessages.last.live, isTrue);
        expect(player.levelMessages.last.bySongId, {
          'song-0': -4.0,
          'song-1': -4.0,
        });
        mode = 'off';
        await handler.applyRuntimeSettings();
        await pumpEventQueue();
        expect(player.levelMessages.last.live, isTrue);
        expect(player.levelMessages.last.bySongId, {
          'song-0': 0.0,
          'song-1': 0.0,
        });
        expect(player.volume, 1);
      });

      test(
        'a tag refresh pushes non-live and leaves the volume alone',
        () async {
          late NavisDatabase database;
          final (handler, player) = await smart(
            ['a', 'b'],
            mode: 'track',
            caps: ios,
            eq: tap,
            onDatabase: (db) => database = db,
          );
          await handler.replaceQueue(ids(2), expandMatchFlows: false);
          await pumpEventQueue();
          final pushes = player.levelMessages.length;
          final before = player.volume;
          await (database.update(database.songsTable)
                ..where((song) => song.id.equals('song-1')))
              .write(const SongsTableCompanion(replayGainTrackGain: Value(-7)));
          await handler.refreshQueuedSongReplayGain();
          await pumpEventQueue();
          expect(player.levelMessages.length, greaterThan(pushes));
          expect(player.levelMessages.last.bySongId['song-1'], -7);
          expect(player.levelMessages.last.live, isFalse);
          expect(player.volume, before);
        },
      );

      test('an added song and a played-next song are stamped', () async {
        final (handler, player) = await smart(
          ['a', 'b', 'c', 'd'],
          mode: 'track',
          caps: ios,
          eq: tap,
        );
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        await handler.addToQueue(['song-2'], expandMatchFlows: false);
        await handler.playNext(['song-3'], expandMatchFlows: false);
        await settleQueue(handler);
        for (final id in ['song-2', 'song-3']) {
          expect(
            player.sequence
                .firstWhere((s) => navisNativeSourceSongId(s) == id)
                .replayGainDb,
            -10,
            reason: id,
          );
        }
        expect(player.levelMessages.last.bySongId.keys, containsAll(ids(4)));
      });

      test('a removal repushes every remaining entry', () async {
        final (handler, player) = await smart(
          ['a', 'b', 'c'],
          mode: 'track',
          caps: ios,
          eq: tap,
        );
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        await pumpEventQueue();
        await handler.removeQueueItemAt(1);
        await settleQueue(handler);
        expect(player.levelMessages.last.bySongId, {
          'song-0': -10.0,
          'song-2': -10.0,
        });
        expect(player.levelMessages.last.live, isFalse);
      });

      test('toggling repeat repushes the levels and the boost', () async {
        final (handler, player) = await smart(
          ['a', 'b', 'a'],
          caps: ios,
          eq: tap,
        );
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        await pumpEventQueue();
        expect(player.levelMessages.last.bySongId['song-2'], -10);
        final boosts = player.boostMessages.length;
        await handler.setRepeatMode(AudioServiceRepeatMode.all);
        player.emitLoopMode(LoopMode.all);
        await pumpEventQueue();
        // song-2 wraps to song-0, the same album: album gain.
        expect(player.levelMessages.last.bySongId['song-2'], -4);
        expect(player.boostMessages.length, greaterThan(boosts));
      });

      test('the cut and the boost read the same Smart pair', () async {
        // song-1 sits between a and b: album gain for the cut, and the boost
        // (a peak leaves room) comes from the same pair.
        final (handler, player) = await smart(
          ['a', 'a', 'b'],
          trackGain: 2,
          albumGain: 6,
          peak: 0.1,
          caps: ios,
          eq: tap,
        );
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        await pumpEventQueue();
        await handler.skipToNext();
        await pumpEventQueue();
        expect(handler.snapshot.currentSongId, 'song-1');
        final decision = handler.currentReplayGainDecision;
        expect(decision?.resolvedMode, 'album');
        expect(player.boostMessages.last.currentDb, decision?.boostDb);
        expect(player.levelMessages.last.bySongId['song-1'], decision?.db);
      });

      test('the cross-fade ramps exclude ReplayGain', () async {
        final decks = <ControllableAudioPlayer>[];
        final (handler, player) = await smart(
          ['a', 'b'],
          mode: 'track',
          caps: ios,
          eq: tap,
          crossfade: true,
          decks: decks,
        );
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        await handler.debugStartCrossfade();
        await pumpEventQueue();
        final deck = handler.debugInactiveDeck as ControllableAudioPlayer;
        expect(deck.sourceGains, isNotEmpty);
        expect(deck.sourceGains.map((g) => g.db), everyElement(-10));
        expect(deck.levelMessages, isNotEmpty);
        expect(deck.boostMessages, isNotEmpty, reason: 'the deck gets the map');
        await handler.setVolume(0.4);
        // A second -10 dB cut on the volume would scale the sum.
        expect(player.volume + deck.volume, closeTo(0.4, 0.00001));
      });

      test('a rebuild without the tap goes back to the volume cut', () async {
        final decks = <ControllableAudioPlayer>[];
        final (handler, player) = await smart(
          ['a', 'b'],
          mode: 'track',
          caps: ios,
          eq: tap,
          decks: decks,
        );
        await handler.setVolume(0.25);
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        expect(player.volume, 0.25);
        await handler.debugRebuildPlayerWithoutEqualizer();
        expect(handler.replayGainInPipeline, isFalse);
        expect(handler.replayGainBoostSupported, isFalse);
        final rebuilt = handler.debugActivePlayer as ControllableAudioPlayer;
        expect(rebuilt, isNot(same(player)));
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        await handler.applyRuntimeSettings();
        await pumpEventQueue();
        expect(rebuilt.sourceGains.map((g) => g.db), everyElement(isNull));
        expect(rebuilt.levelMessages, isEmpty);
        expect(rebuilt.boostMessages, isEmpty);
        expect(rebuilt.volume, closeTo(0.25 * cut, 0.00001));
      });

      test(
        'without the tap the Dart cut applies and nothing is stamped',
        () async {
          final (handler, player) = await smart(
            ['a'],
            mode: 'track',
            caps: ios,
          );
          await handler.setVolume(0.25);
          await handler.replaceQueue(ids(1), expandMatchFlows: false);
          expect(handler.replayGainInPipeline, isFalse);
          expect(player.sourceGains.single.db, isNull);
          expect(player.levelMessages, isEmpty);
          expect(player.volume, closeTo(0.25 * cut, 0.00001));
        },
      );

      test(
        'the status adds the cut native assigned, under its own keys',
        () async {
          final (handler, player) = await smart(
            ['a'],
            mode: 'track',
            caps: ios,
            eq: tap,
          );
          player.nativeEqualizerState = const EqualizerStateMessage(
            enabled: true,
            boostRequestedDb: 3,
            replayGainCutDb: -10,
            replayGainNextCutDb: -4.5,
          );
          await handler.replaceQueue(ids(1), expandMatchFlows: false);
          await handler.refreshEqualizerState();
          final status =
              handler.collectPlaybackDiagnostics()['replayGainBoost']
                  as Map<String, Object?>;
          expect(status['cutDb'], -10);
          expect(status['nextCutDb'], -4.5);
          expect(status['requestedDb'], 3);
        },
      );
    });
  });

  group('cross-fade deck', () {
    List<String> ids(int count, [int from = 0]) =>
        List<String>.generate(count - from, (i) => 'song-${i + from}');

    Future<(NavisAudioHandler, ControllableAudioPlayer, NavisDatabase)>
    crossfading(
      int count, {
      bool sidecarStreams = false,
      bool positionStreams = false,
      String crossfadeType = 'normal',
      String Function()? readCrossfadeType,
      ScrobbleService? scrobbleService,
      String replayGainMode = 'off',
      double replayGainUntaggedDb = replayGainFallbackUntaggedDb,
      PlaybackAdjustmentCapabilities adjustmentCapabilities =
          PlaybackAdjustmentCapabilities.android,
      bool transcodeOffset = false,
      NavisPlaybackTimeouts timeouts = const NavisPlaybackTimeouts(),
      PlaybackSourceResolver Function(PlaybackSourceResolver)? wrapResolver,
      Future<void> Function(NavisDatabase database)? seed,
      bool? pipeline,
    }) async {
      final directory = await Directory.systemTemp.createTemp('navis-fade-');
      final created = await createHandler(
        directory,
        count,
        replayGainInPipeline: pipeline,
        crossfade: true,
        sidecarStreams: sidecarStreams || transcodeOffset,
        streamingQuality: transcodeOffset
            ? const StreamingQuality(
                label: 'opus',
                maxBitRate: 128,
                format: 'opus',
              )
            : const StreamingQuality(label: 'original'),
        supportsTranscodeOffset: transcodeOffset,
        timeouts: timeouts,
        wrapResolver: wrapResolver,
        positionStreams: positionStreams,
        crossfadeType: crossfadeType,
        readCrossfadeType: readCrossfadeType,
        scrobbleService: scrobbleService,
        replayGainMode: replayGainMode,
        replayGainUntaggedDb: replayGainUntaggedDb,
        adjustmentCapabilities: adjustmentCapabilities,
        seed: seed,
      );
      addTearDown(() async {
        await created.$1.disposeHandler();
        await created.$3.close();
        await directory.delete(recursive: true);
      });
      return created;
    }

    Future<void> waitForFade(bool Function() condition) async {
      for (var i = 0; i < 800 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(condition(), isTrue, reason: 'crossfade did not settle');
    }

    group('ReplayGain boost', () {
      const mpv = PlaybackAdjustmentCapabilities.mediaKit;

      // song-0 +6 dB (peak 0.1), song-1 +3 dB (peak 0.1), song-2 -4 dB.
      Future<void> seedGains(NavisDatabase database) async {
        for (final (i, gain, peak) in [
          (0, 6.0, 0.1),
          (1, 3.0, 0.1),
          (2, -4.0, 0.1),
        ]) {
          await (database.update(
            database.songsTable,
          )..where((song) => song.id.equals('song-$i'))).write(
            SongsTableCompanion(
              replayGainTrackGain: Value(gain),
              replayGainTrackPeak: Value(peak),
            ),
          );
        }
      }

      test('F3: the incoming deck has its own boost before it plays', () async {
        final (handler, _, _) = await crossfading(
          3,
          adjustmentCapabilities: mpv,
          pipeline: false,
          replayGainMode: 'track',
          seed: seedGains,
        );
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        await handler.debugStartCrossfade();
        final incoming = handler.debugInactiveDeck! as ControllableAudioPlayer;
        await waitForFade(() => incoming.playing);
        final beforePlay = incoming.boostMessages.where((m) => !m.playing);
        expect(beforePlay, isNotEmpty);
        expect(
          beforePlay.last.currentDb,
          3,
          reason: "song-1's own boost, sent before play",
        );
        expect(beforePlay.last.bySongId['song-1'], 3);
        await handler.debugCompleteCrossfade();
        // Nothing steps at the handover: the last message still says the same.
        expect(incoming.boostMessages.last.currentDb, 3);
      });

      test(
        'F6: a boost send never freezes Smart for the inactive deck',
        () async {
          final (handler, _, _) = await crossfading(
            3,
            adjustmentCapabilities: mpv,
            replayGainMode: 'smart',
            seed: seedGains,
          );
          await handler.replaceQueue(ids(3), expandMatchFlows: false);
          await handler.debugStartCrossfade();
          await handler.debugCompleteCrossfade();
          // The old deck is idle and still points at song-0.
          final idle = handler.debugInactiveDeck!;
          expect(idle.currentIndex, 0);
          await handler.debugSendReplayGainBoostTo(idle);
          expect(handler.debugSmartFrozenSongIds, isNot(contains('song-0')));
        },
      );
    });

    group('after a swap off an offset stream', () {
      // Song 0 plays as a transcode opened at 90 s, then crossfades into
      // song 1, which starts at its own beginning.
      Future<(NavisAudioHandler, ControllableAudioPlayer)> swapped() async {
        final (handler, outgoing, _) = await crossfading(
          3,
          transcodeOffset: true,
        );
        outgoing.simulateProgress = true;
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        await handler.seek(const Duration(seconds: 90));
        await waitForFade(() => !handler.snapshot.isLoading);
        expect(handler.collectPlaybackDiagnostics()['positionOffsetMs'], 90000);
        final incoming = handler.debugInactiveDeck! as ControllableAudioPlayer;
        incoming.simulateProgress = true;
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        await waitForFade(() => incoming.playing && incoming.volume > 0);
        await handler.debugCompleteCrossfade();
        expect(handler.debugActivePlayer, same(incoming));
        return (handler, incoming);
      }

      test('the current item and its offset belong to the new song', () async {
        final (handler, _) = await swapped();
        await waitForFade(() => handler.snapshot.currentSongId == 'song-1');
        expect(handler.mediaItem.valueOrNull?.id, 'song-1');
        expect(handler.collectPlaybackDiagnostics()['positionOffsetMs'], 0);
      });

      test('a seek on the new song is not an offset reopen', () async {
        final (handler, incoming) = await swapped();
        final loads = incoming.sourceLoads;
        // Under a second a fresh stream seeks natively; an offset one reopens.
        await handler.seek(const Duration(milliseconds: 500));
        await waitForFade(() => !handler.snapshot.isLoading);
        final events =
            handler.collectPlaybackDiagnostics()['seekEvents']! as List;
        expect((events.last as Map)['path'], isNot('transcodeOffset'));
        expect(incoming.sourceLoads, loads);
        expect(handler.collectPlaybackDiagnostics()['positionOffsetMs'], 0);
      });

      test('restart on the new song does not reopen an offset', () async {
        final (handler, incoming) = await swapped();
        incoming.simulatedPosition = const Duration(seconds: 10);
        final loads = incoming.sourceLoads;
        await handler.skipToPrevious();
        await waitForFade(() => !handler.snapshot.isLoading);
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(incoming.sourceLoads, loads);
        expect(handler.collectPlaybackDiagnostics()['positionOffsetMs'], 0);
      });

      test(
        'no crossfade into an unrepaired offset song: the wrap starts it at 0',
        () async {
          late GatedSourceResolver resolver;
          final (handler, outgoing, _) = await crossfading(
            2,
            transcodeOffset: true,
            wrapResolver: (base) => resolver = GatedSourceResolver(base),
          );
          outgoing.simulateProgress = true;
          await handler.replaceQueue(ids(2), expandMatchFlows: false);
          await handler.setRepeatMode(AudioServiceRepeatMode.all);
          await handler.seek(const Duration(seconds: 90));
          await waitForFade(() => !handler.snapshot.isLoading);
          final first = handler.debugInactiveDeck! as ControllableAudioPlayer;
          first.simulateProgress = true;
          handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
          await waitForFade(() => first.playing && first.volume > 0);
          // Hold the repair of song 0 once it is left.
          resolver
            ..blockedSongId = 'song-0'
            ..release = Completer<void>();
          addTearDown(() {
            if (!resolver.release!.isCompleted) resolver.release!.complete();
          });
          await handler.debugCompleteCrossfade();
          await waitForFade(() => handler.snapshot.currentSongId == 'song-1');

          // Song 0 still carries its offset: its end is a plain advance.
          final deck = handler.debugInactiveDeck as ControllableAudioPlayer?;
          handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
          await pumpEventQueue(times: 50);
          expect(fade(handler)['active'], isFalse);
          expect(deck?.playing ?? false, isFalse);
          final active = handler.debugActivePlayer as ControllableAudioPlayer;
          active.finishCurrentTrack();
          await pumpEventQueue(times: 20);
          resolver.release!.complete();
          await waitForFade(
            () =>
                handler.snapshot.currentSongId == 'song-0' &&
                !handler.snapshot.isLoading &&
                handler.collectPlaybackDiagnostics()['positionOffsetMs'] == 0,
          );
          final source = active.sequence[0] as UriAudioSource;
          expect(source.positionOffset, Duration.zero);
        },
      );

      test('a crossfade into the repaired entry needs no reopen', () async {
        final (handler, outgoing, _) = await crossfading(
          2,
          transcodeOffset: true,
        );
        outgoing.simulateProgress = true;
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        await handler.setRepeatMode(AudioServiceRepeatMode.all);
        await handler.seek(const Duration(seconds: 90));
        await waitForFade(() => !handler.snapshot.isLoading);
        final first = handler.debugInactiveDeck! as ControllableAudioPlayer;
        first.simulateProgress = true;
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        await waitForFade(() => first.playing && first.volume > 0);
        await handler.debugCompleteCrossfade();
        await waitForFade(
          () =>
              handler.snapshot.currentSongId == 'song-1' &&
              handler.queue.value[0].extras!['positionOffsetMs'] == 0 &&
              !handler.snapshot.isLoading,
        );
        await settleQueue(handler);
        final deck = handler.debugInactiveDeck! as ControllableAudioPlayer;
        final loads = deck.sourceLoads;
        deck.simulateProgress = true;
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        await waitForFade(() => deck.playing && deck.volume > 0);
        await handler.debugCompleteCrossfade();
        await waitForFade(() => handler.snapshot.currentSongId == 'song-0');
        await settleQueue(handler);

        expect(handler.collectPlaybackDiagnostics()['positionOffsetMs'], 0);
        expect(handler.debugActivePlayer, same(deck));
        expect(deck.sourceLoads, loads);
      });

      test(
        'a tap during the repair resolves against the shown queue',
        () async {
          final (handler, outgoing, _) = await crossfading(
            4,
            transcodeOffset: true,
            timeouts: const NavisPlaybackTimeouts(
              load: Duration(seconds: 2),
              reset: Duration(seconds: 2),
            ),
          );
          outgoing.simulateProgress = true;
          await handler.replaceQueue(ids(4), expandMatchFlows: false);
          await handler.seek(const Duration(seconds: 90));
          await waitForFade(() => !handler.snapshot.isLoading);
          final incoming =
              handler.debugInactiveDeck! as ControllableAudioPlayer;
          incoming.simulateProgress = true;
          handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
          await waitForFade(() => incoming.playing && incoming.volume > 0);
          // The old player becomes the deck: its mirror of the repair waits.
          final gate = Completer<void>();
          outgoing
            ..insertGate = gate
            ..insertEntered = Completer<void>();
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
          await handler.debugCompleteCrossfade();
          await waitForFade(() => handler.snapshot.currentSongId == 'song-1');
          // The repair is inserting its twin and waits on the deck mirror.
          await outgoing.insertEntered!.future;
          expect(handler.queue.value.map((item) => item.id), ids(4));

          final tap = handler.skipToQueueItem(2);
          await pumpEventQueue(times: 20);
          gate.complete();
          await tap;
          await waitForFade(
            () =>
                handler.snapshot.currentSongId == 'song-2' &&
                !handler.snapshot.isLoading,
          );

          expect(handler.snapshot.currentSongId, 'song-2');
        },
      );

      test('Previous loads the offset song from its start', () async {
        final (handler, incoming) = await swapped();
        incoming.simulatedPosition = const Duration(seconds: 1);
        await handler.skipToPrevious();
        await waitForFade(
          () =>
              !handler.snapshot.isLoading &&
              handler.snapshot.currentSongId == 'song-0' &&
              handler.collectPlaybackDiagnostics()['positionOffsetMs'] == 0,
        );
        expect(handler.queue.value[0].extras!['positionOffsetMs'], 0);
        final source = incoming.sequence[0] as UriAudioSource;
        expect(source.positionOffset, Duration.zero);
        expect(source.uri.queryParameters, isNot(contains('timeOffset')));
        expect(incoming.position, lessThan(const Duration(seconds: 5)));
      });
    });

    test(
      'incoming play preserves outgoing playback and reports both decks',
      () async {
        final (handler, outgoing, _) = await crossfading(2);
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        final incoming = handler.debugInactiveDeck! as ControllableAudioPlayer;
        incoming.simulateProgress = true;
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        await waitForFade(() => incoming.playing && incoming.volume > 0);
        expect(outgoing.playing, isTrue);
        final status = fade(handler);
        expect((status['outgoing']! as Map)['playing'], isTrue);
        expect((status['incoming']! as Map)['playing'], isTrue);
        expect((status['incoming']! as Map)['positionMs'], greaterThan(0));
        expect(outgoing.volume, greaterThan(0));
        await handler.setVolume(0);
        expect(outgoing.volume, 0);
        expect(incoming.volume, 0);
        await handler.setVolume(.5);
        expect(incoming.volume, lessThan(.5));
        await handler.debugCompleteCrossfade();
        expect(handler.debugActivePlayer, same(incoming));
        expect(incoming.volume, .5);
      },
    );

    for (final adjustment in ['mute', 'duck']) {
      test('awaited fade tick preserves a newer $adjustment', () async {
        final (handler, outgoing, _) = await crossfading(2);
        final session = TestAudioSession();
        handler.debugWireAudioSession(session);
        addTearDown(session.close);
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        final incoming = handler.debugInactiveDeck! as ControllableAudioPlayer;
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        await waitForFade(() => incoming.volume > 0);
        final gate = Completer<void>();
        incoming.volumeGate = gate;
        incoming.volumeEntered = Completer<void>();
        await incoming.volumeEntered!.future;
        if (adjustment == 'mute') {
          await handler.setVolume(0);
        } else {
          session.interruptions.add(
            AudioInterruptionEvent(true, AudioInterruptionType.duck),
          );
          await waitForFade(() => outgoing.volume <= .4);
        }
        final adjusted = outgoing.volume;
        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(outgoing.volume, lessThanOrEqualTo(adjusted + .001));
        expect(
          incoming.volume,
          lessThanOrEqualTo(adjustment == 'mute' ? 0 : .4),
        );
        await handler.stop();
      });
    }

    test(
      'supersession during listener cancellation rebinds the active deck',
      () async {
        final (handler, outgoing, _) = await crossfading(
          3,
          positionStreams: true,
        );
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        final incoming = handler.debugInactiveDeck! as ControllableAudioPlayer;
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        await waitForFade(() => incoming.playing);
        final gate = Completer<void>();
        outgoing.listenerCancelGate = gate;
        outgoing.listenerCancelEntered = Completer<void>();
        final handoff = handler.debugCompleteCrossfade();
        await outgoing.listenerCancelEntered!.future;
        await handler.playFromIndex(2);
        gate.complete();
        await handoff;
        expect(handler.debugActivePlayer, same(outgoing));
        outgoing.moveTo(1);
        await waitForFade(() => handler.snapshot.currentSongId == 'song-1');
        expect(handler.mediaItem.valueOrNull?.id, 'song-1');
        final positions = <Duration>[];
        final positionSubscription = handler.positionStream.listen(
          positions.add,
        );
        addTearDown(positionSubscription.cancel);
        outgoing.simulatedPosition = const Duration(seconds: 42);
        outgoing.emitPlayerEvent();
        await waitForFade(
          () => positions.contains(const Duration(seconds: 42)),
        );
        outgoing.isPlaying = false;
        outgoing.emitPlayerEvent();
        await waitForFade(() => !handler.snapshot.playing);
        expect(outgoing.volume, 1);
        outgoing.isPlaying = true;
        outgoing.simulatedPosition = const Duration(seconds: 175);
        outgoing.emitPlayerEvent();
        await waitForFade(() => fade(handler)['active'] == true);
        await handler.stop();
      },
    );

    test(
      'cellular handoff times out a resolver that never completes',
      () async {
        late GatedSourceResolver resolver;
        final directory = await Directory.systemTemp.createTemp(
          'navis-handoff-timeout-',
        );
        final (handler, outgoing, database) = await createHandler(
          directory,
          3,
          crossfade: true,
          crossfadeAllowStreaming: false,
          timeouts: const NavisPlaybackTimeouts(
            load: Duration(milliseconds: 100),
          ),
          wrapResolver: (base) => resolver = GatedSourceResolver(base),
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        final incoming = handler.debugInactiveDeck! as ControllableAudioPlayer;
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        await waitForFade(() => incoming.playing);
        await outgoing.setVolume(0); // The outgoing fade has finished.
        resolver.blockedSongId = 'song-2';
        resolver.entered = Completer<void>();
        resolver.release = Completer<void>(); // Deliberately never released.
        var completed = false;
        unawaited(
          handler.debugCompleteCrossfade().then((_) => completed = true),
        );
        await resolver.entered!.future;
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(completed, isTrue);
        expect(fade(handler)['active'], isFalse);
        expect(
          fade(handler)['lastFailure'],
          'handoff_queue_failed:TimeoutException',
        );
        expect(handler.debugActivePlayer, same(outgoing));
        expect(outgoing.volume, 1);
        expect(outgoing.playing, isTrue);
        expect(incoming.playing, isFalse);
        expect(incoming.volume, 0);
      },
    );

    for (final failure in ['play', 'volume']) {
      test(
        'incoming $failure failure reports and falls back gaplessly',
        () async {
          final (handler, outgoing, _) = await crossfading(2);
          await handler.replaceQueue(ids(2), expandMatchFlows: false);
          final incoming =
              handler.debugInactiveDeck! as ControllableAudioPlayer;
          incoming.failPlay = failure == 'play';
          handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
          if (failure == 'volume') {
            await waitForFade(() => incoming.playing);
            incoming.failVolume = true;
          }
          await waitForFade(() => fade(handler)['active'] == false);
          final phase = failure == 'play'
              ? 'incoming_play_failed'
              : 'fade_failed';
          expect(fade(handler)['lastFailure'], '$phase:StateError');
          expect(fade(handler)['phases'], containsPair(phase, 1));
          expect(handler.debugActivePlayer, same(outgoing));
          expect(outgoing.playing, isTrue);
          expect(outgoing.volume, 1);
          expect(incoming.playing, isFalse);
          expect(incoming.volume, 0);
        },
      );
    }

    for (final cacheType in [null, CacheType.permanent, CacheType.rolling]) {
      test(
        'cellular crossfade allows only local incoming ($cacheType)',
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'navis-cellular-fade-',
          );
          final (handler, outgoing, database) = await createHandler(
            directory,
            3,
            crossfade: true,
            crossfadeAllowStreaming: false,
            sidecarStreams: true,
            seed: (database) async {
              if (cacheType == null) return;
              final file = File(p.join(directory.path, 'incoming.mp3'));
              await file.writeAsBytes([1, 2, 3]);
              await database.cacheDao.upsertCachedTrack(
                CachedTracksTableCompanion.insert(
                  songId: 'song-1',
                  filePath: file.path,
                  fileSize: 3,
                  format: 'mp3',
                  cacheType: cacheType,
                  downloadStatus: DownloadStatus.complete,
                  lastAccessedAt: DateTime.now(),
                ),
              );
            },
          );
          addTearDown(() async {
            await handler.disposeHandler();
            await database.close();
            await directory.delete(recursive: true);
          });
          await handler.replaceQueue(ids(3), expandMatchFlows: false);
          final incoming =
              handler.debugInactiveDeck! as ControllableAudioPlayer;
          handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
          await waitForFade(
            () => incoming.playing || fade(handler)['active'] == false,
          );
          expect(outgoing.playing, isTrue);
          if (cacheType == null) {
            expect(fade(handler)['disabledReason'], 'cellular');
            expect(incoming.sourceIds, isEmpty);
            expect(fade(handler)['lastFailure'], isNull);
          } else {
            expect(fade(handler)['disabledReason'], isNull);
            expect(incoming.sourceIds, ['song-1']);
            await handler.debugCompleteCrossfade();
            expect(handler.debugActivePlayer, same(incoming));
            expect(incoming.sourceIds, ids(3));
            expect(incoming.currentIndex, 1);
            expect(incoming.playing, isTrue);
            expect(handler.snapshot.currentSongId, 'song-1');
            expectNativeMirrorsQueue(handler, incoming);
          }
        },
      );
    }

    test(
      'navigation supersedes a cellular handoff waiting to append',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-cellular-handoff-',
        );
        final (handler, outgoing, database) = await createHandler(
          directory,
          3,
          crossfade: true,
          crossfadeAllowStreaming: false,
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        final incoming = handler.debugInactiveDeck! as ControllableAudioPlayer;
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        await waitForFade(() => incoming.playing);
        incoming.appendGate = Completer<void>();
        incoming.appendEntered = Completer<void>();
        final gate = incoming.appendGate!;
        final handoff = handler.debugCompleteCrossfade();
        await incoming.appendEntered!.future;
        await handler.playFromIndex(2);
        expect(handler.snapshot.currentSongId, 'song-2');
        gate.complete();
        await handoff;
        expect(handler.debugActivePlayer, same(outgoing));
        expect(outgoing.audibleSongId, 'song-2');
        expect(incoming.playing, isFalse);
        expect(handler.mediaItem.valueOrNull?.id, 'song-2');
        expect(fade(handler)['active'], isFalse);
      },
    );

    test('an incoming deck that never starts cannot be handed over', () async {
      final (handler, outgoing, _) = await crossfading(2);
      await handler.replaceQueue(ids(2), expandMatchFlows: false);
      final incoming = handler.debugInactiveDeck! as ControllableAudioPlayer;
      incoming.ignorePlay = true;
      handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
      await waitForFade(() => incoming.playRequested);
      expect(outgoing.volume, 1);
      await handler.debugCompleteCrossfade();
      expect(handler.debugActivePlayer, same(outgoing));
      expect(outgoing.playing, isTrue);
      expect(fade(handler)['lastFailure'], 'incoming_not_ready:StateError');
      expect(fade(handler)['phases'], containsPair('incoming_not_ready', 1));
    });

    test(
      'fade and handoff preserve each song ReplayGain volume base',
      () async {
        final (handler, outgoing, database) = await crossfading(
          2,
          replayGainMode: 'track',
        );
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(
            id: 'song-0',
            title: 'Outgoing',
            replayGainTrackGain: const Value(0),
          ),
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Incoming',
            replayGainTrackGain: const Value(-20),
          ),
        ]);
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        await handler.setVolume(.8);
        final incoming = handler.debugInactiveDeck! as ControllableAudioPlayer;
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        await waitForFade(() => incoming.playing && incoming.volume > 0);
        expect(outgoing.volume, lessThan(.8));
        expect(outgoing.volume, greaterThan(.4));
        expect(incoming.volume, lessThan(.08));
        await handler.debugCompleteCrossfade();
        expect(incoming.volume, closeTo(.08, .000001));
        expect(outgoing.playing, isFalse);
      },
    );

    test(
      'normal repeat one self-crossfades through multiple handoffs',
      () async {
        final scrobbles = NoopScrobbleService();
        final (handler, player, database) = await crossfading(
          3,
          positionStreams: true,
          scrobbleService: scrobbles,
        );
        final positions = <Duration>[];
        final subscription = handler.positionStream.listen(positions.add);
        addTearDown(subscription.cancel);
        player.simulateProgress = true;
        await handler.replaceQueue(
          ids(3),
          startIndex: 1,
          expandMatchFlows: false,
        );
        await settleQueue(handler);
        await handler.setRepeatMode(AudioServiceRepeatMode.one);
        await Future<void>.delayed(Duration.zero);
        expect(scrobbles.nowPlaying, ['song-1']);
        for (var wrap = 0; wrap < 2; wrap++) {
          final outgoing = handler.debugActivePlayer as ControllableAudioPlayer;
          final incoming =
              handler.debugInactiveDeck! as ControllableAudioPlayer;
          incoming.simulateProgress = true;
          outgoing.simulatedPosition = const Duration(seconds: 175);
          outgoing.emitPlayerEvent();
          handler.debugCheckCrossfadeTrigger(outgoing.position);
          expect(fade(handler)['active'], isTrue);
          await waitForFade(() => incoming.playing);
          expect(incoming.currentIndex, 1);
          expect(incoming.playedFrom.last, Duration.zero);
          expect(incoming.sourceIds, ids(3));
          expect(incoming.loopMode, LoopMode.one);
          expect(scrobbles.nowPlaying, hasLength(wrap + 1));
          expect(scrobbles.submissions, hasLength(wrap + 1));
          // Use the existing fade timer, not the manual completion seam.
          await waitForFade(
            () =>
                identical(handler.debugActivePlayer, incoming) &&
                fade(handler)['active'] == false,
          );
          expect(outgoing.playing, isFalse);
          expect(incoming.playing, isTrue);
          expect(incoming.loopMode, LoopMode.one);
          expect(handler.snapshot.queueSongIds, ids(3));
          expect(handler.snapshot.currentIndex, 1);
          expect(handler.currentMediaItem?.id, 'song-1');
          expect(handler.snapshot.repeatMode, AudioServiceRepeatMode.one);
          expect(handler.playbackState.value.queueIndex, 1);
          expect(
            handler.playbackState.value.repeatMode,
            AudioServiceRepeatMode.one,
          );
          await Future<void>.delayed(const Duration(milliseconds: 250));
          final afterSwap = positions.last;
          expect(afterSwap, lessThan(const Duration(seconds: 8)));
          await Future<void>.delayed(const Duration(milliseconds: 350));
          expect(positions.last, greaterThan(afterSwap));
          expect(scrobbles.nowPlaying, hasLength(wrap + 2));
          await handler.debugFlushQueuePersistence();
          final saved = (await database.playQueueDao.getQueueState())!;
          expect(saved.currentIndex, 1);
          expect(saved.repeatMode, RepeatMode.one);
          expect(saved.positionMs, lessThan(8000));
          expect(
            (await database.playQueueDao.getQueueItems()).map((row) => row.id),
            ids(3),
          );
        }
        final active = handler.debugActivePlayer as ControllableAudioPlayer;
        active.simulatedPosition = const Duration(seconds: 91);
        for (var event = 0; event < 5; event++) {
          active.emitPlayerEvent();
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(scrobbles.nowPlaying, List.filled(3, 'song-1'));
        expect(scrobbles.submissions, List.filled(3, 'song-1'));
        expect(scrobbles.nowPlayingSessions.toSet(), hasLength(3));
        expect(scrobbles.submissionSessions, scrobbles.nowPlayingSessions);
        expect(
          await database.select(database.playHistoryTable).get(),
          hasLength(3),
        );
        expect(fade(handler)['phases'], containsPair('completed', 2));
      },
    );

    test('self-crossfade waits for a pending seek to settle', () async {
      final (handler, player, _) = await crossfading(2, positionStreams: true);
      player.simulateProgress = true;
      await handler.replaceQueue(ids(2), expandMatchFlows: false);
      await handler.setRepeatMode(AudioServiceRepeatMode.one);
      final entered = Completer<void>();
      final release = Completer<void>();
      player
        ..seekGate = release
        ..seekEntered = entered;
      final seeking = handler.seek(const Duration(seconds: 175));
      await entered.future;
      try {
        // just_audio can publish an optimistic position while native seek
        // confirmation is pending; that must not start a second deck.
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        expect(fade(handler)['active'], isFalse);
      } finally {
        release.complete();
        await seeking;
      }
      expect(handler.snapshot.pendingSeekPosition, isNull);
      handler.debugCheckCrossfadeTrigger(player.position);
      expect(fade(handler)['active'], isTrue);
      await waitForFade(() => handler.debugInactiveDeck!.playing);
      await handler.debugCompleteCrossfade();
      expect(handler.snapshot.pendingSeekPosition, isNull);
      expect(handler.debugActivePlayer.loopMode, LoopMode.one);
    });

    test('self-crossfade deducts preparation from its boundary wait', () async {
      final (handler, player, _) = await crossfading(2);
      await handler.replaceQueue(ids(2), expandMatchFlows: false);
      await handler.setRepeatMode(AudioServiceRepeatMode.one);
      final incoming = handler.debugInactiveDeck! as ControllableAudioPlayer;
      final entered = Completer<void>();
      final release = Completer<void>();
      incoming
        ..loadGate = release
        ..loadEntered = entered;
      player.simulatedPosition = const Duration(seconds: 174);
      handler.debugCheckCrossfadeTrigger(player.position);
      await entered.future.timeout(const Duration(seconds: 1));
      // Native playback progressed 900 ms while the deck prepared.
      player
        ..simulateProgress = true
        ..simulatedPosition = const Duration(seconds: 174, milliseconds: 900);
      final elapsed = Stopwatch()..start();
      release.complete();
      await waitForFade(() => incoming.playing);
      expect(elapsed.elapsed, lessThan(const Duration(milliseconds: 600)));
      expect(
        player.position,
        greaterThanOrEqualTo(const Duration(seconds: 175)),
      );
      await handler.debugCompleteCrossfade();
      expect(handler.debugActivePlayer, same(incoming));
    });

    test('a slow prewarm shortens the ramp to end by the song end', () async {
      final (handler, player, _) = await crossfading(2);
      await handler.replaceQueue(ids(2), expandMatchFlows: false);
      final incoming = handler.debugInactiveDeck! as ControllableAudioPlayer;
      final entered = Completer<void>();
      final release = Completer<void>();
      incoming
        ..loadGate = release
        ..loadEntered = entered;
      // 2 s before the end of a 3 min song: the 5 s fade cannot fit.
      player
        ..simulateProgress = true
        ..simulatedPosition =
            const Duration(minutes: 3) - const Duration(seconds: 2);
      handler.debugCheckCrossfadeTrigger(player.position);
      await entered.future.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      release.complete();
      await waitForFade(
        () =>
            identical(handler.debugActivePlayer, incoming) &&
            fade(handler)['active'] == false,
      );
      expect(
        player.position,
        lessThanOrEqualTo(const Duration(minutes: 3)),
        reason: 'the ramp must end before the outgoing song does',
      );
      expect(incoming.playing, isTrue);
    });

    test('with under half a second left the song advances gaplessly', () async {
      final (handler, player, _) = await crossfading(2);
      await handler.replaceQueue(ids(2), expandMatchFlows: false);
      final incoming = handler.debugInactiveDeck! as ControllableAudioPlayer;
      player.simulatedPosition =
          const Duration(minutes: 3) - const Duration(milliseconds: 300);
      handler.debugCheckCrossfadeTrigger(player.position);
      await waitForFade(() => fade(handler)['active'] == false);
      expect(handler.debugActivePlayer, same(player));
      expect(incoming.playing, isFalse);
      expect(fade(handler)['phases'], containsPair('too_late', 1));
      // No retry loop for this occurrence.
      handler.debugCheckCrossfadeTrigger(player.position);
      expect(fade(handler)['active'], isFalse);
    });

    test(
      'the outgoing deck advancing mid-fade does not drive the display',
      () async {
        final (handler, player, _) = await crossfading(3);
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        final incoming = handler.debugInactiveDeck! as ControllableAudioPlayer;
        final shown = <(String?, bool)>[];
        final sub = handler.snapshotStream.listen(
          (s) => shown.add((
            s.currentSongId,
            identical(handler.debugActivePlayer, player),
          )),
        );
        addTearDown(sub.cancel);
        player.simulatedPosition =
            const Duration(minutes: 3) - const Duration(seconds: 6);
        handler.debugCheckCrossfadeTrigger(player.position);
        await waitForFade(() => incoming.playing && incoming.volume > 0);
        expect(handler.currentMediaItem?.id, 'song-0');
        // The outgoing deck runs out and gapless-advances into song 1.
        player.finishCurrentTrack();
        await pumpEventQueue();
        expect(
          shown,
          isNot(contains(('song-1', true))),
          reason: 'the outgoing deck must not publish the next song',
        );
        await waitForFade(
          () =>
              identical(handler.debugActivePlayer, incoming) &&
              fade(handler)['active'] == false,
        );
        expect(handler.currentMediaItem?.id, 'song-1');
        expect(handler.snapshot.currentIndex, 1);
        expect(player.playing, isFalse, reason: 'no second copy of song 1');
        expect(incoming.playing, isTrue);
      },
    );

    group('an incoming song too short for the ramp', () {
      // The outgoing song has 6 s left, so the ramp is the full 5 s.
      Future<
        (NavisAudioHandler, ControllableAudioPlayer, ControllableAudioPlayer)
      >
      shortIncoming(Duration duration) async {
        final (handler, player, _) = await crossfading(3);
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        final incoming = handler.debugInactiveDeck! as ControllableAudioPlayer;
        incoming.simulatedDuration = duration;
        player.simulatedPosition =
            const Duration(minutes: 3) - const Duration(seconds: 6);
        handler.debugCheckCrossfadeTrigger(player.position);
        return (handler, player, incoming);
      }

      test('below ramp plus margin advances gaplessly', () async {
        final (handler, player, incoming) = await shortIncoming(
          const Duration(milliseconds: 5099),
        );
        await waitForFade(() => fade(handler)['active'] == false);
        expect(handler.debugActivePlayer, same(player));
        expect(incoming.playing, isFalse);
        expect(fade(handler)['phases'], containsPair('too_late', 1));
      });

      test('exactly ramp plus margin still crossfades', () async {
        final (handler, player, incoming) = await shortIncoming(
          const Duration(milliseconds: 5100),
        );
        await waitForFade(() => incoming.playing && incoming.volume > 0);
        expect(fade(handler)['active'], isTrue);
        expect(fade(handler)['phases'], isNot(contains('too_late')));
        await handler.debugCompleteCrossfade();
        expect(handler.debugActivePlayer, same(incoming));
        expect(player.playing, isFalse);
      });

      test('an unknown incoming duration keeps the full ramp', () async {
        final (handler, _, incoming) = await shortIncoming(Duration.zero);
        await waitForFade(() => incoming.playing && incoming.volume > 0);
        expect(fade(handler)['phases'], isNot(contains('too_late')));
        await handler.debugCompleteCrossfade();
        expect(handler.debugActivePlayer, same(incoming));
      });
    });

    group('the outgoing deck advancing mid-fade', () {
      final nearEnd = const Duration(minutes: 3) - const Duration(seconds: 6);

      Future<
        (
          NavisAudioHandler,
          ControllableAudioPlayer,
          ControllableAudioPlayer,
          NavisDatabase,
        )
      >
      midFade({bool positionStreams = false, int startIndex = 0}) async {
        final (handler, player, database) = await crossfading(
          3,
          positionStreams: positionStreams,
        );
        await handler.replaceQueue(
          ids(3),
          startIndex: startIndex,
          expandMatchFlows: false,
        );
        final incoming = handler.debugInactiveDeck! as ControllableAudioPlayer;
        player.simulatedPosition = nearEnd;
        handler.debugCheckCrossfadeTrigger(player.position);
        await waitForFade(() => incoming.playing && incoming.volume > 0.2);
        return (handler, player, incoming, database);
      }

      test('keeps the saved and shown position on the outgoing song', () async {
        final (handler, player, incoming, database) = await midFade();
        final hold = Completer<void>();
        // A slow native write keeps the hand-over open: the widest window.
        incoming.volumeHold = hold;
        player.finishCurrentTrack();
        await pumpEventQueue();
        expect(identical(handler.debugActivePlayer, player), isTrue);
        expect(handler.snapshot.currentSongId, 'song-0');
        expect(
          handler.snapshot.position,
          greaterThan(const Duration(minutes: 2)),
          reason: 'song-0 must not be shown at the next song\'s ~0',
        );
        await handler.debugFlushQueuePersistence();
        final saved = (await database.playQueueDao.getQueueState())!;
        expect(saved.currentIndex, 0);
        expect(saved.positionMs, greaterThan(120000));
        hold.complete();
        await waitForFade(
          () =>
              identical(handler.debugActivePlayer, incoming) &&
              fade(handler)['active'] == false,
        );
      });

      test('mutes the outgoing deck before any hand-over await', () async {
        final (handler, player, incoming, _) = await midFade();
        final hold = Completer<void>();
        incoming.volumeHold = hold;
        player.finishCurrentTrack();
        await pumpEventQueue();
        expect(player.volume, 0, reason: 'no second copy of song-1');
        hold.complete();
        await waitForFade(
          () =>
              identical(handler.debugActivePlayer, incoming) &&
              fade(handler)['active'] == false,
        );
      });

      test('the position stream never shows the next song at 0', () async {
        final (handler, player, incoming, _) = await midFade(
          positionStreams: true,
        );
        final seen = <Duration>[];
        final sub = handler.positionStream.listen(seen.add);
        addTearDown(sub.cancel);
        final hold = Completer<void>();
        incoming.volumeHold = hold;
        player.finishCurrentTrack();
        await pumpEventQueue();
        seen.clear();
        for (var i = 0; i < 3; i++) {
          player.emitPlayerEvent();
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        expect(identical(handler.debugActivePlayer, player), isTrue);
        expect(seen, isNotEmpty);
        expect(
          seen.every((p) => p > const Duration(minutes: 2)),
          isTrue,
          reason: 'saw $seen',
        );
        hold.complete();
        await waitForFade(
          () =>
              identical(handler.debugActivePlayer, incoming) &&
              fade(handler)['active'] == false,
        );
      });

      test(
        'a volume change inside the hand-over keeps the outgoing mute',
        () async {
          final (handler, player, incoming, _) = await midFade();
          final hold = Completer<void>();
          incoming.volumeHold = hold;
          player.finishCurrentTrack();
          await pumpEventQueue();
          unawaited(handler.setVolume(0.8));
          await pumpEventQueue();
          expect(player.volume, 0, reason: 'song-1 must not come back');
          hold.complete();
          await waitForFade(
            () =>
                identical(handler.debugActivePlayer, incoming) &&
                fade(handler)['active'] == false,
          );
          expect(incoming.volume, closeTo(0.8, 0.001));
        },
      );

      test(
        'previous inside the hand-over restarts the outgoing song',
        () async {
          final (handler, player, incoming, _) = await midFade(startIndex: 1);
          final hold = Completer<void>();
          incoming.volumeHold = hold;
          player.finishCurrentTrack();
          await pumpEventQueue();
          await handler.skipToPrevious();
          await pumpEventQueue();
          expect(handler.snapshot.currentSongId, 'song-1');
          expect(player.index, 1, reason: 'a restart, not the previous song');
          hold.complete();
          await pumpEventQueue();
        },
      );

      test('a volume change follows the shortened ramp', () async {
        final (handler, player, _) = await crossfading(2);
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        final incoming = handler.debugInactiveDeck! as ControllableAudioPlayer;
        // 2 s left: the 5 s fade shortens to about 1.9 s.
        player
          ..simulateProgress = true
          ..simulatedPosition =
              const Duration(minutes: 3) - const Duration(seconds: 2);
        handler.debugCheckCrossfadeTrigger(player.position);
        await waitForFade(() => incoming.playing && incoming.volume > 0.5);
        await handler.setVolume(1);
        expect(player.volume, lessThan(0.55));
        expect(incoming.volume, greaterThan(0.45));
      });
    });

    test(
      'an outgoing advance with the incoming deck unready falls back',
      () async {
        final (handler, player, _) = await crossfading(3);
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        final incoming = handler.debugInactiveDeck! as ControllableAudioPlayer;
        incoming.ignorePlay = true;
        player.simulatedPosition =
            const Duration(minutes: 3) - const Duration(seconds: 6);
        handler.debugCheckCrossfadeTrigger(player.position);
        await waitForFade(() => incoming.playRequested);
        player.finishCurrentTrack();
        await waitForFade(() => fade(handler)['active'] == false);
        await pumpEventQueue();
        // The suppressed index event is replayed when the fade is abandoned.
        expect(handler.debugActivePlayer, same(player));
        expect(handler.currentMediaItem?.id, 'song-1');
        expect(handler.snapshot.currentIndex, 1);
        expect(player.playing, isTrue);
      },
    );

    test('self-crossfade retries after a native wrap during prewarm', () async {
      final (handler, player, _) = await crossfading(2);
      await handler.replaceQueue(ids(2), expandMatchFlows: false);
      await handler.setRepeatMode(AudioServiceRepeatMode.one);
      final incoming = handler.debugInactiveDeck! as ControllableAudioPlayer;
      final entered = Completer<void>();
      final release = Completer<void>();
      incoming
        ..loadGate = release
        ..loadEntered = entered;
      player.simulatedPosition = const Duration(seconds: 175);
      handler.debugCheckCrossfadeTrigger(player.position);
      await entered.future;
      player.simulatedPosition = const Duration(seconds: 1);
      release.complete();
      await waitForFade(() => fade(handler)['active'] == false);
      expect(handler.debugActivePlayer, same(player));
      expect(incoming.playing, isFalse);
      expect(fade(handler)['phases'], isNot(contains('prewarm_failed')));
      player.simulatedPosition = const Duration(seconds: 175);
      handler.debugCheckCrossfadeTrigger(player.position);
      expect(fade(handler)['active'], isTrue);
      await waitForFade(() => incoming.playing);
      await handler.debugCompleteCrossfade();
      expect(handler.debugActivePlayer, same(incoming));
      expect(handler.snapshot.queueSongIds, ids(2));
    });

    test(
      'smart repeat one never crossfades even without album metadata',
      () async {
        final (handler, player, _) = await crossfading(
          3,
          positionStreams: true,
          crossfadeType: 'smart',
        );
        player.simulateProgress = true;
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        await handler.setRepeatMode(AudioServiceRepeatMode.one);
        final positions = <Duration>[];
        final subscription = handler.positionStream.listen(positions.add);
        addTearDown(subscription.cancel);
        for (var wrap = 0; wrap < 2; wrap++) {
          player.simulatedPosition = const Duration(seconds: 175);
          player.emitPlayerEvent();
          handler.debugCheckCrossfadeTrigger(player.position);
          await Future<void>.delayed(const Duration(milliseconds: 350));
          expect(fade(handler)['active'], isFalse);
          expect(handler.debugInactiveDeck!.playing, isFalse);
          player.simulatedPosition = Duration.zero;
          player.emitPlayerEvent();
          await Future<void>.delayed(const Duration(milliseconds: 350));
          expect(positions.last, lessThan(const Duration(seconds: 1)));
          final before = positions.last;
          await Future<void>.delayed(const Duration(milliseconds: 350));
          expect(positions.last, greaterThan(before));
        }
        expect(handler.debugActivePlayer, same(player));
        expect(handler.snapshot.queueSongIds, ids(3));
        expect(fade(handler)['phases'], isNot(contains('completed')));
      },
    );

    for (final seconds in [9, 10]) {
      test(
        'normal repeat one minimum length is twice the fade ($seconds s)',
        () async {
          final (handler, player, _) = await crossfading(1);
          player.simulatedDuration = Duration(seconds: seconds);
          await handler.replaceQueue(ids(1), expandMatchFlows: false);
          await handler.setRepeatMode(AudioServiceRepeatMode.one);
          player.simulatedPosition = Duration(seconds: seconds - 5);
          handler.debugCheckCrossfadeTrigger(player.position);
          expect(fade(handler)['active'], seconds >= 10);
          if (seconds >= 10) {
            await waitForFade(() => handler.debugInactiveDeck!.playing);
            await handler.debugCompleteCrossfade();
            expect(handler.snapshot.queueSongIds, ids(1));
            expect(handler.debugActivePlayer.loopMode, LoopMode.one);
          }
        },
      );
    }

    for (final type in ['normal', 'smart']) {
      for (final repeat in [
        AudioServiceRepeatMode.none,
        AudioServiceRepeatMode.all,
      ]) {
        for (final index in [0, 1]) {
          test(
            'crossfade keeps $type $repeat next index from $index',
            () async {
              final (handler, player, _) = await crossfading(
                2,
                crossfadeType: type,
              );
              await handler.replaceQueue(
                ids(2),
                startIndex: index,
                expandMatchFlows: false,
              );
              await handler.setRepeatMode(repeat);
              handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
              final target = index == 0
                  ? 1
                  : repeat == AudioServiceRepeatMode.all
                  ? 0
                  : null;
              expect(fade(handler)['active'], target != null);
              if (target != null) {
                final incoming = handler.debugInactiveDeck!;
                await waitForFade(() => incoming.playing);
                expect(incoming.currentIndex, target);
                await handler.debugCompleteCrossfade();
                expect(handler.debugActivePlayer, same(incoming));
                expect(handler.snapshot.currentIndex, target);
                expect(handler.snapshot.repeatMode, repeat);
              } else {
                expect(handler.debugActivePlayer, same(player));
              }
              expect(handler.snapshot.queueSongIds, ids(2));
            },
          );
        }
      }
    }

    for (final change in ['repeat', 'smart']) {
      test('self-crossfade cancels when policy changes to $change', () async {
        var type = 'normal';
        final (handler, player, _) = await crossfading(
          2,
          readCrossfadeType: () => type,
        );
        await handler.replaceQueue(ids(2), expandMatchFlows: false);
        await handler.setRepeatMode(AudioServiceRepeatMode.one);
        handler.debugCheckCrossfadeTrigger(const Duration(seconds: 175));
        expect(fade(handler)['active'], isTrue);
        final incoming = handler.debugInactiveDeck!;
        await waitForFade(() => incoming.playing);
        if (change == 'repeat') {
          await handler.setRepeatMode(AudioServiceRepeatMode.none);
        } else {
          type = 'smart';
          await handler.applyRuntimeSettings();
        }
        expect(fade(handler)['active'], isFalse);
        expect(handler.debugActivePlayer, same(player));
        expect(player.playing, isTrue);
        expect(incoming.playing, isFalse);
      });
    }

    test(
      'hung inactive deck prewarm expires without stopping active playback',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-fade-hang-',
        );
        final (handler, player, database) = await createHandler(
          directory,
          3,
          crossfade: true,
          timeouts: const NavisPlaybackTimeouts(
            load: Duration(milliseconds: 80),
          ),
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        await handler.replaceQueue(ids(3), expandMatchFlows: false);
        final deck = handler.debugInactiveDeck! as ControllableAudioPlayer;
        deck.hang.add('setAudioSources');
        final started = handler.debugStartCrossfade();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(fade(handler)['active'], isFalse);
        expect(player.playing, isTrue);
        expect(handler.debugActivePlayer, same(player));
        expect(handler.snapshot.queueSongIds, ids(3));
        expect(fade(handler)['phases'], containsPair('prewarm_failed', 1));
        expect(handler.debugInactiveDeck, isNot(same(deck)));
        await started;
        player.moveTo(1);
        await Future<void>.delayed(Duration.zero);
        await handler.debugStartCrossfade();
        expect(fade(handler)['active'], isTrue);
      },
    );

    test(
      'a deck load that races a queue edit loads again before it plays',
      () async {
        final (handler, player, _) = await crossfading(8);
        await handler.replaceQueue(ids(6), expandMatchFlows: false);
        final deck = handler.debugInactiveDeck! as ControllableAudioPlayer;
        final gate = Completer<void>();
        final entered = Completer<void>();
        deck
          ..loadGate = gate
          ..loadEntered = entered;

        final started = handler.debugStartCrossfade();
        await entered.future;
        // Queue edits do not wait for a fade.
        await handler.addToQueue(<String>[
          'song-6',
          'song-7',
        ], expandMatchFlows: false);
        gate.complete();
        await started;

        expect(player.sourceIds, ids(8));
        expect(deck.sourceIds, ids(8));
        expect(deck.isPlaying, isTrue);
        expect(fade(handler)['phases'], containsPair('deck_resynced', 1));

        await handler.debugCompleteCrossfade();
        expect(identical(handler.debugActivePlayer, deck), isTrue);
        expect(
          handler.collectPlaybackDiagnostics()['playerMatchesQueue'],
          true,
        );
        expect(handler.snapshot.queueSongIds, ids(8));
      },
    );

    test('a deck that missed an edit is never handed over', () async {
      final (handler, player, _) = await crossfading(6);
      await handler.replaceQueue(ids(6), expandMatchFlows: false);
      final deck = handler.debugInactiveDeck! as ControllableAudioPlayer;
      await handler.debugStartCrossfade();
      expect(deck.isPlaying, isTrue);
      // A mirror the deck did not get.
      await deck.removeAudioSourceAt(5);

      await handler.debugCompleteCrossfade();

      expect(identical(handler.debugActivePlayer, player), isTrue);
      expect(deck.isPlaying, isFalse);
      expect(fade(handler)['active'], isFalse);
      expect(fade(handler)['phases'], containsPair('deck_mismatch', 1));
      expect(handler.collectPlaybackDiagnostics()['playerMatchesQueue'], true);
    });

    test(
      'a transition that cannot be prepared is not retried every tick',
      () async {
        final (handler, player, _) = await crossfading(6);
        await handler.replaceQueue(ids(6), expandMatchFlows: false);
        player.isPlaying = true;
        final deck = handler.debugInactiveDeck! as ControllableAudioPlayer;
        // The deck cannot load the queue.
        deck.failLoadSongId = 'song-0';
        int failures() =>
            (fade(handler)['phases']! as Map<String, int>)['prewarm_failed'] ??
            0;
        const nearEnd = Duration(minutes: 2, seconds: 56);

        handler.debugCheckCrossfadeTrigger(nearEnd);
        for (var i = 0; i < 100 && failures() == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(failures(), 1);
        for (var tick = 0; tick < 5; tick++) {
          handler.debugCheckCrossfadeTrigger(nearEnd);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        expect(failures(), 1);
        expect(fade(handler)['active'], isFalse);
      },
    );

    test(
      'a transition that could not be prepared is tried again on a later play',
      () async {
        final (handler, player, _) = await crossfading(6);
        await handler.replaceQueue(ids(6), expandMatchFlows: false);
        player.isPlaying = true;
        final deck = handler.debugInactiveDeck! as ControllableAudioPlayer;
        deck.failLoadSongId = 'song-0';
        int failures() =>
            (fade(handler)['phases']! as Map<String, int>)['prewarm_failed'] ??
            0;
        const nearEnd = Duration(minutes: 2, seconds: 56);
        Future<void> trigger(int expected) async {
          handler.debugCheckCrossfadeTrigger(nearEnd);
          for (var i = 0; i < 100 && failures() < expected; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        }

        await trigger(1);
        expect(failures(), 1);

        // Another song plays, then the first one again (as on repeat).
        await handler.playFromIndex(1);
        await handler.playFromIndex(0);
        for (var i = 0; i < 100 && handler.snapshot.isLoading; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        player.isPlaying = true;
        await trigger(2);

        expect(failures(), 2);
      },
    );

    test('a deck with the same length but other songs is reloaded', () async {
      final (handler, _, _) = await crossfading(7);
      await handler.replaceQueue(ids(6), expandMatchFlows: false);
      final deck = handler.debugInactiveDeck! as ControllableAudioPlayer;
      // Same length as the queue, different last song.
      await deck.setAudioSources(<AudioSource>[
        for (final id in <String>[...ids(5), 'song-6'])
          AudioSource.uri(
            Uri.parse('file:///$id.mp3'),
            tag: MediaItem(id: id, title: id),
          ),
      ]);

      await handler.debugStartCrossfade();

      expect(deck.sourceIds, ids(6));
    });
  });

  group('remote first load', () {
    // A server that fetches a remote song before answering needs longer than
    // the ordinary load deadline on its first play.
    for (final external in [true, false]) {
      test('a slow first load of a ${external ? 'remote' : 'library'} '
          'stream ${external ? 'waits' : 'times out'}', () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-remote-',
        );
        final (handler, player, database) = await createHandler(
          directory,
          2,
          sidecarStreams: true,
          rebuiltPlayers: <ControllableAudioPlayer>[],
          timeouts: const NavisPlaybackTimeouts(
            load: Duration(milliseconds: 300),
            remoteLoad: Duration(seconds: 5),
            control: Duration(milliseconds: 100),
            reset: Duration(milliseconds: 150),
          ),
          seed: (database) async {
            if (external) {
              await database.customStatement(
                "UPDATE songs SET is_external = 1 WHERE id = 'song-0'",
              );
            }
          },
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        final gate = Completer<void>();
        player.loadGate = gate;
        final release = Timer(const Duration(milliseconds: 900), gate.complete);
        addTearDown(release.cancel);

        await handler
            .replaceQueue(['song-0', 'song-1'], expandMatchFlows: false)
            .catchError((Object _) {});

        final attempts =
            handler.collectPlaybackDiagnostics()['startupAttempts']! as List;
        final stages = [
          for (final attempt in attempts)
            for (final event in (attempt as Map)['events'] as List)
              (event as Map)['stage'],
        ];
        expect(stages.contains('player:active queue apply:timeout'), !external);
        if (external) {
          expect(player.sourceIds.first, 'song-0');
          expect(player.processingState, ProcessingState.ready);
        }
      });
    }
  });

  group('progress-aware playback deadlines', () {
    // Scaled load, fixed desktop settlement and mobile/load progress budgets.
    const deadlines = NavisPlaybackTimeouts(
      load: Duration(milliseconds: 300),
      seekBufferingRecovery: Duration(milliseconds: 150),
      seekProgress: Duration(milliseconds: 1200),
      desktopSeekSettle: Duration(milliseconds: 600),
      // Keep the scaled idle window above the 250 ms load-check cadence.
      progressIdle: Duration(milliseconds: 300),
    );

    Future<
      (
        NavisAudioHandler,
        ControllableAudioPlayer,
        void Function({required bool growing, bool bufferProgress}),
      )
    >
    fixture({
      NavisPlaybackTimeouts timeouts = deadlines,
      List<ControllableAudioPlayer>? rebuiltPlayers,
      Set<String>? hungLoadSongs,
      bool transcode = false,
      bool positionStreams = false,
      int count = 2,
      NavisQueueWindow queueWindow = const NavisQueueWindow(),
      bool? desktopRuntimeOverride,
    }) async {
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final release = Completer<void>();
      var receiving = false;
      final transfers = <Future<void>>[];
      server.listen((request) {
        transfers.add(() async {
          Timer? fill;
          try {
            request.response
              ..bufferOutput = false
              ..headers.contentType = ContentType('audio', 'flac')
              ..contentLength = 1000000;
            fill = Timer.periodic(const Duration(milliseconds: 40), (_) {
              if (receiving) request.response.add(List<int>.filled(100, 1));
            });
            await release.future;
          } on HttpException {
            // Teardown cancels the incomplete sidecar.
          } finally {
            fill?.cancel();
          }
        }());
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
        'navis-progress-',
      );
      final (handler, player, database) = await createHandler(
        directory,
        count,
        positionStreams: positionStreams,
        queueWindow: queueWindow,
        desktopRuntimeOverride: desktopRuntimeOverride,
        sidecarStreams: true,
        streamingQuality: transcode
            ? const StreamingQuality(
                label: 'opus',
                format: 'opus',
                maxBitRate: 128,
              )
            : const StreamingQuality(label: 'original'),
        supportsTranscodeOffset: transcode,
        readApiClient: () => api,
        rebuiltPlayers: rebuiltPlayers ?? <ControllableAudioPlayer>[],
        hungLoadSongs: hungLoadSongs,
        timeouts: timeouts,
      );
      addTearDown(() async {
        release.complete();
        await handler.disposeHandler();
        await server.close(force: true);
        await Future.wait(transfers);
        await database.close();
        await directory.delete(recursive: true);
        HttpOverrides.global = previousHttp;
      });
      player.simulateProgress = true;
      var bufferGrowing = false;
      final buffer = Timer.periodic(const Duration(milliseconds: 40), (_) {
        if (bufferGrowing) {
          player.simulatedBuffered += const Duration(milliseconds: 100);
        }
      });
      addTearDown(buffer.cancel);
      return (
        handler,
        player,
        ({required bool growing, bool bufferProgress = false}) {
          receiving = growing;
          bufferGrowing = growing && bufferProgress;
        },
      );
    }

    test(
      'desktop buffering probes both obey the fixed settlement deadline',
      () async {
        final (handler, player, grow) = await fixture();
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        grow(growing: true);
        player
          ..state = ProcessingState.buffering
          ..ignoreSeeks = true
          ..ignoreInitialPosition = true
          ..bufferAfterLoad = true
          ..nativePositionFrozen = true;
        final seeking = handler.seek(const Duration(seconds: 90));
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(
          (handler.collectPlaybackDiagnostics()['seek']!
              as Map)['recoveryAttempts'],
          0,
        );
        await seeking;
        await settleQueue(handler);
        await pumpEventQueue();
        final seek = handler.collectPlaybackDiagnostics()['seek']! as Map;
        expect(seek['recoveryAttempts'], 1);
        expect(seek['outcome'], 'failed');
        final event =
            (handler.collectPlaybackDiagnostics()['seekEvents']! as List).last
                as Map;
        final probes = event['unsettled']! as List;
        expect(probes, hasLength(2));
        for (final entry in probes) {
          final probe = entry as Map;
          expect(probe['reason'], 'deadline');
          expect(probe['elapsedMs'], inInclusiveRange(600, 1000));
          expect(probe['processingState'], 'buffering');
          expect(probe['positionMs'], isA<int>());
          expect(probe['bufferedMs'], isA<int>());
          expect(probe['playing'], isTrue);
          expect(probe.containsKey('inputBytesPerSecond'), isFalse);
          expect(probe.containsKey('inputExtensionActive'), isFalse);
        }
      },
    );

    for (final flapping in [false, true]) {
      test('buffering seek with frozen decoded buffer '
          'can settle after the load deadline (flapping $flapping)', () async {
        final (handler, player, grow) = await fixture();
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        grow(growing: true);
        player
          ..state = ProcessingState.buffering
          ..ignoreSeeks = true
          ..nativePositionFrozen = true;
        final elapsed = Stopwatch()..start();
        final flap = Timer.periodic(const Duration(milliseconds: 40), (_) {
          if (flapping && elapsed.elapsedMilliseconds >= 200) {
            player.state = player.state == ProcessingState.ready
                ? ProcessingState.buffering
                : ProcessingState.ready;
          }
        });
        addTearDown(flap.cancel);
        final landed = Timer(const Duration(milliseconds: 325), () {
          flap.cancel();
          player
            ..simulatedPosition = const Duration(seconds: 90)
            ..nativePositionFrozen = false
            ..state = ProcessingState.ready;
        });
        addTearDown(landed.cancel);
        final loads = player.sourceLoads;
        final seeking = handler.seek(const Duration(seconds: 90));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(player.sourceLoads, loads);
        expect(player.bufferedPosition, Duration.zero);
        expect(player.playbackEvent.updatePosition, Duration.zero);
        await seeking;
        final seek = handler.collectPlaybackDiagnostics()['seek']! as Map;
        expect(seek['recoveryAttempts'], 0);
        expect(seek['outcome'], 'completed');
        expect(player.sourceLoads, loads);
        expect(
          handler.collectPlaybackDiagnostics()['partialCacheBytes'],
          greaterThan(0),
        );
      });
    }

    for (final near in [true, false]) {
      test('ready frozen seek retains short stall checks after buffering '
          '(near target $near)', () async {
        final (handler, player, grow) = await fixture();
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        grow(growing: true);
        player
          ..state = ProcessingState.buffering
          ..ignoreSeeks = true
          ..nativePositionFrozen = true;
        final ready = Timer(Duration(milliseconds: near ? 350 : 100), () {
          player
            ..state = ProcessingState.ready
            ..simulatedPosition = near
                ? const Duration(seconds: 90)
                : Duration.zero;
        });
        addTearDown(ready.cancel);
        await handler.seek(const Duration(seconds: 90));
        await settleQueue(handler);
        await pumpEventQueue();
        final events =
            handler.collectPlaybackDiagnostics()['seekEvents']! as List;
        final probe = ((events.last as Map)['unsettled']! as List).first as Map;
        expect(
          probe['reason'],
          near ? equals('no progress') : anyOf('no progress', 'missed target'),
        );
        expect(probe['elapsedMs'], lessThan(near ? 1100 : 600));
        expect(probe['processingState'], 'ready');
        expect(probe['playing'], isTrue);
      });
    }

    test(
      'a frozen landed seek finishes recovery before a later seek',
      () async {
        final (handler, player, grow) = await fixture();
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        grow(growing: true);
        player.nativePositionFrozen = true;
        final first = handler.seek(const Duration(seconds: 90));
        // Landing alone is not settlement; frozen ready must recover promptly.
        await Future<void>.delayed(const Duration(milliseconds: 600));
        player.nativePositionFrozen = false;
        final second = handler.seek(const Duration(seconds: 30));
        await Future.wait([first, second]);
        final events =
            handler.collectPlaybackDiagnostics()['seekEvents']! as List;
        expect((events[events.length - 2] as Map)['outcome'], 'failed');
        expect((events.last as Map)['outcome'], 'completed');
      },
    );

    test('desktop sidecar growth does not hide a ready frozen seek', () async {
      final (handler, player, grow) = await fixture();
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      grow(growing: true);
      player
        ..state = ProcessingState.ready
        ..ignoreSeeks = true
        ..nativePositionFrozen = true;
      final seeking = handler.seek(const Duration(seconds: 90));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final bytes = handler.collectPlaybackDiagnostics()['partialCacheBytes'];
      await seeking;
      await settleQueue(handler);
      await pumpEventQueue();
      final event =
          (handler.collectPlaybackDiagnostics()['seekEvents']! as List).last
              as Map;
      final probe = (event['unsettled']! as List).first as Map;
      expect(probe['reason'], 'missed target');
      expect(probe['elapsedMs'], lessThan(600));
      expect(bytes, greaterThan(0));
    });

    for (final rapid in [false, true]) {
      test(
        '${rapid ? 'rapid' : 'single'} same-song seek preserves a progressing cold start',
        () async {
          final (handler, player, grow) = await fixture();
          final gate = Completer<void>();
          final entered = Completer<void>();
          player
            ..loadGate = gate
            ..loadEntered = entered
            ..gateNonEmptyLoadsOnly = true;
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
          final failures = <PlaybackLoadFailure>[];
          final subscription = handler.loadFailureStream.listen(failures.add);
          addTearDown(subscription.cancel);
          grow(growing: true);
          final loading = handler.replaceQueue([
            'song-0',
            'song-1',
          ], expandMatchFlows: false);
          await entered.future;
          await Future<void>.delayed(const Duration(milliseconds: 400));
          final olderSeek = rapid
              ? handler.seek(const Duration(seconds: 30))
              : Future<void>.value();
          await Future<void>.delayed(const Duration(milliseconds: 30));
          final seeking = handler.seek(const Duration(seconds: 90));
          await Future<void>.delayed(const Duration(milliseconds: 350));
          final wasDisposed = player.disposed;
          gate.complete();
          await Future.wait([loading, olderSeek, seeking]);
          expect(wasDisposed, isFalse);
          expect(failures, isEmpty);
          final seek = handler.collectPlaybackDiagnostics()['seek']! as Map;
          expect(seek['outcome'], 'completed');
          expect(seek['recoveryAttempts'], 0);
          expect(handler.snapshot.currentSongId, 'song-0');
          expect(
            (player.position - const Duration(seconds: 90)).abs(),
            lessThan(const Duration(seconds: 1)),
          );
        },
      );
    }

    for (final holdMs in [1000, 2000]) {
      for (final transcode in [false, true]) {
        test(
          'cold seek hold $holdMs transcode $transcode retires sources and keeps the target alive',
          () async {
            final rebuilt = <ControllableAudioPlayer>[];
            final (handler, player, _) = await fixture(
              rebuiltPlayers: rebuilt,
              transcode: transcode,
              timeouts: const NavisPlaybackTimeouts(
                load: Duration(milliseconds: 600),
                seekProgress: Duration(milliseconds: 2400),
              ),
            );
            final gate = Completer<void>();
            final entered = Completer<void>();
            player
              ..claimedSources = <AudioSource>{}
              ..replacementLoadGate = gate
              ..loadGate = gate
              ..loadEntered = entered
              ..gateNonEmptyLoadsOnly = true;
            addTearDown(() {
              if (!gate.isCompleted) gate.complete();
            });
            final failures = <PlaybackLoadFailure>[];
            final notices = handler.loadFailureStream.listen(failures.add);
            addTearDown(notices.cancel);
            final loading = handler.replaceQueue([
              'song-0',
            ], expandMatchFlows: false);
            await entered.future;
            await Future<void>.delayed(const Duration(milliseconds: 250));
            final seeking = handler.seek(const Duration(seconds: 60));
            // The new player must keep waiting for this same body hold too.
            for (var i = 0; i < 200 && rebuilt.isEmpty; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
            expect(rebuilt, isNotEmpty);
            await Future<void>.delayed(Duration(milliseconds: holdMs - 750));
            final before = handler.collectPlaybackDiagnostics()['seek']! as Map;
            expect(before['outcome'], isNull);
            gate.complete();
            await Future.wait([loading, seeking]);
            final seek = handler.collectPlaybackDiagnostics()['seek']! as Map;
            expect(seek['outcome'], 'completed');
            expect(handler.snapshot.queueSongIds, ['song-0']);
            expect(handler.snapshot.currentSongId, 'song-0');
            expect(handler.snapshot.playing, isTrue);
            expect(
              handler.snapshot.processingState,
              AudioProcessingState.ready,
            );
            expect(rebuilt.last.playedFrom.first.inSeconds, 60);
            expect(failures, isEmpty);
            expect(rebuilt.single.sourceLoads, 1);
            if (transcode) {
              final event =
                  (handler.collectPlaybackDiagnostics()['seekEvents']! as List)
                          .last
                      as Map;
              expect(event['path'], 'transcodeOffset');
              expect(
                (rebuilt.single.sequence.single as UriAudioSource)
                    .positionOffset,
                const Duration(seconds: 60),
              );
            }
          },
        );
      }
    }

    for (final retryFails in [false, true]) {
      for (final onlySong in [false, true]) {
        test(
          'failed cold load onlySong $onlySong ${retryFails ? 'exhausts retry' : 'retries at the target'}',
          () async {
            final rebuilt = <ControllableAudioPlayer>[];
            final hungSongs = <String>{};
            final (handler, player, _) = await fixture(
              rebuiltPlayers: rebuilt,
              hungLoadSongs: hungSongs,
            );
            final gate = Completer<void>();
            final entered = Completer<void>();
            player
              ..loadGate = gate
              ..loadEntered = entered
              ..gateNonEmptyLoadsOnly = true;
            addTearDown(() {
              if (!gate.isCompleted) gate.complete();
            });
            final loading = handler.replaceQueue([
              'song-0',
              if (!onlySong) 'song-1',
            ], expandMatchFlows: false);
            await entered.future;
            if (retryFails) hungSongs.add('song-0');
            final seeking = handler.seek(const Duration(seconds: 90));
            await Future.wait([loading, seeking]);
            if (retryFails && onlySong) {
              await pumpEventQueue();
              expect(handler.debugQueueLaneIdle, isTrue);
              expect(handler.snapshot.isLoading, isFalse);
            } else {
              await settleQueue(handler);
            }
            expect(player.disposed, isTrue);
            expect(rebuilt, hasLength(retryFails ? 2 : 1));
            expect(
              handler.snapshot.currentSongId,
              retryFails && !onlySong ? 'song-1' : 'song-0',
            );
            expect(handler.snapshot.queueSongIds, [
              'song-0',
              if (!onlySong) 'song-1',
            ]);
            expect(rebuilt.last.playing, !(retryFails && onlySong));
            expect(
              rebuilt.last.processingState,
              retryFails && onlySong
                  ? ProcessingState.idle
                  : ProcessingState.ready,
            );
            if (retryFails && onlySong) {
              hungSongs.clear();
              await handler.play();
              await settleQueue(handler);
              expect(handler.snapshot.currentSongId, 'song-0');
              expect(rebuilt.last.playing, isTrue);
              expect(rebuilt.last.processingState, ProcessingState.ready);
            }
            if (!retryFails) {
              expect(rebuilt.last.playedFrom, isNotEmpty);
              expect(
                (rebuilt.last.playedFrom.first - const Duration(seconds: 90))
                    .abs(),
                lessThan(const Duration(seconds: 1)),
              );
              final seek = handler.collectPlaybackDiagnostics()['seek']! as Map;
              expect(seek['outcome'], 'completed');
              expect(seek['recoveryAttempts'], 1);
            }
          },
        );
      }
    }

    for (final processing in [
      ProcessingState.ready,
      ProcessingState.buffering,
    ]) {
      test(
        'exhausted ${processing.name} seek stops quietly and Play reloads the only song',
        () async {
          final (handler, player, _) = await fixture();
          await handler.replaceQueue(['song-0'], expandMatchFlows: false);
          final failures = <PlaybackLoadFailure>[];
          final notices = handler.loadFailureStream.listen(failures.add);
          addTearDown(notices.cancel);
          player
            ..state = processing
            ..bufferAfterLoad = processing == ProcessingState.buffering
            ..nativePositionFrozen = true;
          await handler.seek(const Duration(seconds: 60));
          expect(
            (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
            'failed',
          );
          expect(handler.snapshot.queueSongIds, ['song-0']);
          expect(handler.snapshot.playing, isFalse);
          expect(player.processingState, ProcessingState.idle);
          expect(failures, isEmpty);
          player
            ..bufferAfterLoad = false
            ..nativePositionFrozen = false;
          final loads = player.sourceLoads;
          await handler.play();
          await settleQueue(handler);
          expect(player.sourceLoads, greaterThan(loads));
          expect(handler.snapshot.currentSongId, 'song-0');
          expect(handler.snapshot.playing, isTrue);
          expect(player.processingState, ProcessingState.ready);
        },
      );
    }

    // Round 10: bounded failover. Scaled deadlines; a short reset window and
    // healthy-play window keep the cascades quick.
    const quick = NavisPlaybackTimeouts(
      load: Duration(milliseconds: 300),
      seekBufferingRecovery: Duration(milliseconds: 400),
      seekProgress: Duration(milliseconds: 1200),
      desktopSeekSettle: Duration(milliseconds: 600),
      progressIdle: Duration(milliseconds: 300),
      reset: Duration(milliseconds: 300),
      healthyPlayback: Duration(milliseconds: 400),
    );

    Future<void> idle(NavisAudioHandler handler) async {
      var quiet = 0;
      for (var i = 0; i < 600 && quiet < 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        quiet = !handler.snapshot.isLoading && handler.debugQueueLaneIdle
            ? quiet + 1
            : 0;
      }
      expect(quiet, 4, reason: 'handler did not go idle');
    }

    List<String> songIds(int count) =>
        List<String>.generate(count, (i) => 'song-$i');

    for (final halt in ['pause', 'stop', 'timed-out stop']) {
      for (final pauseAgain in [false, true]) {
        test(
          'row 01 Play during final $halt honors latest intent (later Pause: $pauseAgain)',
          () async {
            final rebuilt = <ControllableAudioPlayer>[];
            final (handler, player, _) = await fixture(
              timeouts: quick,
              rebuiltPlayers: rebuilt,
            );
            await handler.replaceQueue(['song-0'], expandMatchFlows: false);
            final release = Completer<void>();
            final entered = Completer<void>();
            addTearDown(() {
              if (!release.isCompleted) release.complete();
            });
            player.nativePositionFrozen = true;
            if (halt == 'pause') {
              player
                ..pauseGate = release
                ..pauseEntered = entered
                ..pauseGateWhen = () =>
                    (handler.collectPlaybackDiagnostics()['seek']!
                        as Map)['outcome'] ==
                    'failed';
            } else {
              player
                ..stopGate = release
                ..stopEntered = entered
                ..stopGateFrom = player.stopCalls + 2;
            }
            final seeking = handler.seek(const Duration(seconds: 60));
            await entered.future.timeout(const Duration(seconds: 6));
            player
              ..nativePositionFrozen = false
              ..ignoreSeeks = false;
            await handler.play();
            if (pauseAgain) await handler.pause();
            if (halt != 'timed-out stop') release.complete();
            await seeking.timeout(const Duration(seconds: 8));
            await idle(handler);
            if (!release.isCompleted) release.complete();
            await pumpEventQueue(times: 30);
            await idle(handler);
            final active = handler.debugActivePlayer as ControllableAudioPlayer;
            expect(handler.snapshot.currentSongId, 'song-0');
            expect(
              handler.snapshot.playing,
              !pauseAgain,
              reason: 'row 01: final halt must honor the latest intent',
            );
            if (!pauseAgain) {
              expect(active.processingState, ProcessingState.ready);
              final position = active.position;
              await Future<void>.delayed(const Duration(milliseconds: 80));
              expect(active.position, greaterThan(position));
            }
            if (halt == 'timed-out stop') {
              expect(active, isNot(same(player)));
            }
          },
        );
      }
    }

    test(
      'row 01 a newer queue plays while an older final Pause settles',
      () async {
        final (handler, player, _) = await fixture(timeouts: quick);
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        final release = Completer<void>();
        final entered = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        player
          ..nativePositionFrozen = true
          ..pauseGate = release
          ..pauseEntered = entered
          ..pauseGateWhen = () =>
              (handler.collectPlaybackDiagnostics()['seek']!
                  as Map)['outcome'] ==
              'failed';
        final seeking = handler.seek(const Duration(seconds: 60));
        await entered.future.timeout(const Duration(seconds: 6));
        player.nativePositionFrozen = false;
        await handler.replaceQueue(['song-1'], expandMatchFlows: false);
        release.complete();
        await seeking;
        await idle(handler);
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(
          player.playing,
          isTrue,
          reason: 'an older halt must not hold a newer source paused',
        );
        expect(player.processingState, ProcessingState.ready);
      },
    );

    for (final intent in ['seek', 'Play', 'Pause']) {
      test('row 01 newer seek during final Stop honors $intent', () async {
        final (handler, player, _) = await fixture(timeouts: quick);
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        final release = Completer<void>();
        final entered = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        player
          ..nativePositionFrozen = true
          ..stopGate = release
          ..stopEntered = entered
          ..stopGateFrom = player.stopCalls + 2;
        final older = handler.seek(const Duration(seconds: 60));
        await entered.future.timeout(const Duration(seconds: 6));
        player
          ..nativePositionFrozen = false
          ..ignoreSeeks = false;
        final newer = handler.seek(const Duration(seconds: 130));
        if (intent == 'Play') await handler.play();
        if (intent == 'Pause') await handler.pause();
        release.complete();
        await Future.wait([older, newer]).timeout(const Duration(seconds: 8));
        await idle(handler);
        final active = handler.debugActivePlayer as ControllableAudioPlayer;
        expect(
          (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
          'completed',
        );
        expect(active.position.inSeconds, greaterThanOrEqualTo(130));
        expect(active.playing, intent != 'Pause');
        expectNativeMirrorsQueue(handler, active);
      });
    }

    test('a hung final stop never parks the seek lane', () async {
      final (handler, player, _) = await fixture(timeouts: quick);
      await handler.replaceQueue(['song-0'], expandMatchFlows: false);
      player
        ..state = ProcessingState.ready
        ..nativePositionFrozen = true
        // Seek recovery stops twice; the third stop is the final quiet one.
        ..hangStopsFrom = 3;
      await handler
          .seek(const Duration(seconds: 60))
          .timeout(const Duration(seconds: 8));
      expect(
        (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
        'failed',
      );
      await handler
          .seek(const Duration(seconds: 30))
          .timeout(const Duration(seconds: 8));
      expect(handler.snapshot.currentSongId, 'song-0');
    });

    test(
      'a failed seek on a song that keeps playing does not skip it',
      () async {
        final (handler, player, _) = await fixture(
          timeouts: quick,
          positionStreams: true,
        );
        await handler.replaceQueue(songIds(2), expandMatchFlows: false);
        final failures = <PlaybackLoadFailure>[];
        final notices = handler.loadFailureStream.listen(failures.add);
        addTearDown(notices.cancel);
        // Seeks never land and reloads restart the song, which plays on.
        player
          ..ignoreSeeks = true
          ..ignoreInitialPosition = true;
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await handler.seek(const Duration(seconds: 90));
        await idle(handler);
        expect(
          (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
          'failed',
        );
        expect(handler.snapshot.currentSongId, 'song-0');
        expect(handler.snapshot.playing, isTrue);
        expect(failures, isEmpty);
      },
    );

    test('a dead source still fails over after a failed seek', () async {
      final (handler, player, _) = await fixture(
        timeouts: quick,
        positionStreams: true,
      );
      await handler.replaceQueue(songIds(2), expandMatchFlows: false);
      player
        ..ignoreSeeks = true
        ..simulateProgress = false
        ..nativePositionFrozen = true;
      // Long enough for the last advance to age out.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await handler.seek(const Duration(seconds: 90));
      await idle(handler);
      expect(handler.snapshot.currentSongId, 'song-1');
    });

    test('automatic failover stops quietly after two skipped songs', () async {
      final rebuilt = <ControllableAudioPlayer>[];
      final hung = <String>{for (var i = 0; i < 5; i++) 'song-$i'};
      final (handler, _, _) = await fixture(
        timeouts: quick,
        count: 6,
        rebuiltPlayers: rebuilt,
        hungLoadSongs: hung,
      );
      final failures = <PlaybackLoadFailure>[];
      final notices = handler.loadFailureStream.listen(failures.add);
      addTearDown(notices.cancel);
      await handler.replaceQueue(songIds(6), expandMatchFlows: false);
      await idle(handler);
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(handler.snapshot.queueSongIds, songIds(6));
      expect(handler.snapshot.playing, isFalse);
      expect(failures, isEmpty);
      hung.clear();
      await handler.play();
      await idle(handler);
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(handler.snapshot.playing, isTrue);
      expect(rebuilt.last.processingState, ProcessingState.ready);
    });

    for (final command in ['playFromIndex', 'skipToNext', 'replaceQueue']) {
      test('$command after a cap stop gets automatic failover again', () async {
        final rebuilt = <ControllableAudioPlayer>[];
        // Songs 0-2 hit the cap; the user's pick then fails and is skipped.
        final hung = <String>{
          for (final i in [0, 1, 2, if (command == 'skipToNext') 3 else 4])
            'song-$i',
        };
        final (handler, _, _) = await fixture(
          timeouts: quick,
          count: 8,
          rebuiltPlayers: rebuilt,
          hungLoadSongs: hung,
        );
        await handler.replaceQueue(songIds(8), expandMatchFlows: false);
        await idle(handler);
        expect(handler.snapshot.currentSongId, 'song-2');
        switch (command) {
          case 'playFromIndex':
            await handler.playFromIndex(4);
          case 'skipToNext':
            await handler.skipToNext();
          default:
            await handler.replaceQueue(
              songIds(8),
              startIndex: 4,
              expandMatchFlows: false,
            );
        }
        await idle(handler);
        expect(
          handler.snapshot.currentSongId,
          command == 'skipToNext' ? 'song-4' : 'song-5',
        );
        expect(handler.snapshot.playing, isTrue);
      });
    }

    test('a cap stop in a windowed queue releases no tail into it', () async {
      final rebuilt = <ControllableAudioPlayer>[];
      final hung = <String>{'song-0', 'song-1', 'song-2'};
      final (handler, _, _) = await fixture(
        timeouts: quick,
        count: 14,
        rebuiltPlayers: rebuilt,
        hungLoadSongs: hung,
        queueWindow: const NavisQueueWindow(
          deferThreshold: 12,
          ahead: 3,
          lowWater: 2,
          page: 3,
          nearJump: 5,
          behind: 3,
          trimSlack: 1,
        ),
      );
      await handler.replaceQueue(songIds(14), expandMatchFlows: false);
      await idle(handler);
      // Let a background tail release run if one is going to.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await idle(handler);
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(handler.snapshot.currentIndex, 2);
      expect(handler.snapshot.queueSongIds, songIds(14));
      expect(rebuilt.last.sourceIds, isEmpty);
      hung.clear();
      await handler.play();
      await idle(handler);
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(handler.snapshot.currentIndex, 2);
      expect(handler.snapshot.playing, isTrue);
    });

    test(
      'a song that played healthily and ends early is not a failure',
      () async {
        final (handler, _, _) = await fixture(
          timeouts: quick,
          count: 8,
          positionStreams: true,
        );
        await handler.replaceQueue(songIds(8), expandMatchFlows: false);
        Future<void> complete(Duration at) async {
          final active = handler.debugActivePlayer as ControllableAudioPlayer;
          active
            ..state = ProcessingState.completed
            ..simulatedPosition = at
            ..playbackEvents.add(active.playbackEvent);
          await idle(handler);
        }

        // Song 0 plays past healthyPlayback, then ends 30 s short of its
        // (overstated) duration: a normal completion, not counted.
        await Future<void>.delayed(const Duration(milliseconds: 900));
        await complete(const Duration(minutes: 2, seconds: 30));
        expect(handler.snapshot.currentSongId, 'song-1');
        // Songs 1 and 2 never play: two counted failures, then the cap on 3.
        await complete(Duration.zero);
        expect(handler.snapshot.currentSongId, 'song-2');
        await complete(Duration.zero);
        expect(handler.snapshot.currentSongId, 'song-3');
        expect(handler.snapshot.playing, isTrue);
        await complete(Duration.zero);
        expect(handler.snapshot.currentSongId, 'song-3');
        expect(handler.snapshot.playing, isFalse);
      },
    );

    for (final command in ['skipToNext', 'playFromIndex', 'replaceQueue']) {
      test(
        '$command from a healthy song starts the next one unplayed',
        () async {
          final (handler, _, _) = await fixture(
            timeouts: quick,
            count: 8,
            positionStreams: true,
          );
          await handler.replaceQueue(songIds(8), expandMatchFlows: false);
          await Future<void>.delayed(const Duration(milliseconds: 900));
          expect(
            handler.debugPlayedSinceFailover,
            greaterThan(quick.healthyPlayback),
          );
          // At once, before any position tick of the new song can reset it.
          final selecting = switch (command) {
            'skipToNext' => handler.skipToNext(),
            'playFromIndex' => handler.playFromIndex(3),
            _ => handler.replaceQueue(songIds(8), expandMatchFlows: false),
          };
          expect(handler.debugPlayedSinceFailover, Duration.zero);
          await selecting;
        },
      );
    }

    test('the same song twice in a row is a new occurrence', () async {
      final (handler, player, _) = await fixture(
        timeouts: quick,
        count: 8,
        positionStreams: true,
      );
      await handler.replaceQueue([
        'song-0',
        'song-0',
        'song-1',
      ], expandMatchFlows: false);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(
        handler.debugPlayedSinceFailover,
        greaterThan(quick.healthyPlayback),
      );
      player.finishCurrentTrack();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(handler.snapshot.currentIndex, 1);
      expect(handler.debugPlayedSinceFailover, lessThan(quick.healthyPlayback));
    });

    test('a ready backend with a frozen native position stays dead', () async {
      final (handler, player, _) = await fixture(
        timeouts: quick,
        positionStreams: true,
      );
      await handler.replaceQueue(songIds(2), expandMatchFlows: false);
      // The interpolated clock moves; the backend reports no position.
      player
        ..ignoreSeeks = true
        ..nativePositionFrozen = true;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await handler.seek(const Duration(seconds: 90));
      await idle(handler);
      expect(handler.snapshot.currentSongId, 'song-1');
    });

    test('a frozen native position never clears the failover count', () async {
      final (handler, player, _) = await fixture(
        timeouts: const NavisPlaybackTimeouts(
          load: Duration(milliseconds: 300),
          seekBufferingRecovery: Duration(milliseconds: 400),
          seekProgress: Duration(milliseconds: 1200),
          desktopSeekSettle: Duration(milliseconds: 600),
          progressIdle: Duration(milliseconds: 300),
          reset: Duration(milliseconds: 300),
          healthyPlayback: Duration(milliseconds: 800),
        ),
        count: 6,
        positionStreams: true,
      );
      await handler.replaceQueue(songIds(6), expandMatchFlows: false);
      Future<void> fail(String id) async {
        player
          ..failLoadSongId = id
          ..state = ProcessingState.buffering;
        await handler.debugRecoverCurrentSong();
        await idle(handler);
      }

      player.nativePositionFrozen = true;
      await fail('song-0');
      player
        ..failLoadSongId = null
        ..state = ProcessingState.ready;
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await fail('song-1');
      await fail('song-2');
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(handler.snapshot.playing, isFalse);
    });

    test('a hung final stop retires the player so Play reloads', () async {
      final rebuilt = <ControllableAudioPlayer>[];
      final (handler, player, _) = await fixture(
        timeouts: quick,
        rebuiltPlayers: rebuilt,
      );
      await handler.replaceQueue(['song-0'], expandMatchFlows: false);
      player
        ..state = ProcessingState.ready
        ..nativePositionFrozen = true
        ..hangStopsFrom = 3;
      await handler
          .seek(const Duration(seconds: 60))
          .timeout(const Duration(seconds: 8));
      await idle(handler);
      expect(rebuilt, hasLength(1));
      await handler.play();
      await idle(handler);
      expect(handler.debugActivePlayer, same(rebuilt.last));
      expect(handler.snapshot.currentSongId, 'song-0');
      expect(handler.snapshot.playing, isTrue);
      expect(rebuilt.last.sourceIds, contains('song-0'));
      expect(rebuilt.last.processingState, ProcessingState.ready);
    });

    test('sources that complete at once advance at most twice', () async {
      final (handler, _, _) = await fixture(timeouts: quick, count: 8);
      await handler.replaceQueue(songIds(8), expandMatchFlows: false);
      final visited = <String?>[handler.snapshot.currentSongId];
      for (var i = 0; i < 6; i++) {
        // A server that sends headers and closes: the song ends at position 0.
        final active = handler.debugActivePlayer as ControllableAudioPlayer;
        active
          ..state = ProcessingState.completed
          ..simulatedPosition = Duration.zero
          ..playbackEvents.add(active.playbackEvent);
        await idle(handler);
        visited.add(handler.snapshot.currentSongId);
      }
      expect(visited.toSet(), {'song-0', 'song-1', 'song-2'});
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(handler.snapshot.playing, isFalse);
      expect(handler.snapshot.queueSongIds, songIds(8));
    });

    test('seek and stall failovers share one cap', () async {
      final (handler, player, _) = await fixture(timeouts: quick, count: 6);
      await handler.replaceQueue(songIds(6), expandMatchFlows: false);
      player
        ..ignoreSeeks = true
        ..simulateProgress = false
        ..nativePositionFrozen = true;
      await handler.seek(const Duration(seconds: 90));
      await idle(handler);
      expect(handler.snapshot.currentSongId, 'song-1');
      for (final id in ['song-1', 'song-2']) {
        // Each song fails again when reloaded, as a dead stream would.
        player
          ..failLoadSongId = id
          ..state = ProcessingState.buffering;
        await handler.debugRecoverCurrentSong();
        await idle(handler);
      }
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(handler.snapshot.queueSongIds, songIds(6));
      expect(handler.snapshot.playing, isFalse);
      player.failLoadSongId = null;
      await handler.play();
      await idle(handler);
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(handler.snapshot.playing, isTrue);
    });

    test('healthy playback restarts the failover count', () async {
      final rebuilt = <ControllableAudioPlayer>[];
      final (handler, player, _) = await fixture(
        timeouts: const NavisPlaybackTimeouts(
          load: Duration(milliseconds: 300),
          seekBufferingRecovery: Duration(milliseconds: 400),
          seekProgress: Duration(milliseconds: 1200),
          desktopSeekSettle: Duration(milliseconds: 600),
          progressIdle: Duration(milliseconds: 300),
          reset: Duration(milliseconds: 300),
          healthyPlayback: Duration(milliseconds: 800),
        ),
        count: 6,
        rebuiltPlayers: rebuilt,
        positionStreams: true,
      );
      await handler.replaceQueue(songIds(6), expandMatchFlows: false);
      var current = player;
      Future<void> fail(String id) async {
        current
          ..failLoadSongId = id
          ..state = ProcessingState.buffering;
        await handler.debugRecoverCurrentSong();
        await idle(handler);
      }

      await fail('song-0');
      expect(handler.snapshot.currentSongId, 'song-1');
      // Song 1 plays long enough to count as healthy, which clears the count.
      current
        ..failLoadSongId = null
        ..state = ProcessingState.ready;
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await fail('song-1');
      expect(handler.snapshot.currentSongId, 'song-2');
      await fail('song-2');
      expect(handler.snapshot.currentSongId, 'song-3');
    });

    test(
      'a seek waiting on a load that ends in a quiet stop fails at once',
      () async {
        final hung = <String>{};
        final (handler, player, _) = await fixture(
          hungLoadSongs: hung,
          timeouts: const NavisPlaybackTimeouts(
            load: Duration(seconds: 2),
            seekBufferingRecovery: Duration(milliseconds: 150),
            seekProgress: Duration(seconds: 10),
            desktopSeekSettle: Duration(milliseconds: 600),
            progressIdle: Duration(milliseconds: 300),
            reset: Duration(milliseconds: 300),
          ),
        );
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..loadGate = gate
          ..loadEntered = entered
          ..gateNonEmptyLoadsOnly = true;
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final loading = handler.replaceQueue([
          'song-0',
        ], expandMatchFlows: false);
        await entered.future;
        hung.add('song-0');
        final seeking = handler.seek(const Duration(seconds: 90));
        await loading;
        final stopped = Stopwatch()..start();
        await seeking;
        expect(stopped.elapsedMilliseconds, lessThan(1000));
        expect(
          (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
          'failed',
        );
      },
    );

    test('a cold load cannot hold a seek past the seek progress cap', () async {
      final rebuilt = <ControllableAudioPlayer>[];
      final (handler, player, _) = await fixture(
        rebuiltPlayers: rebuilt,
        timeouts: const NavisPlaybackTimeouts(
          load: Duration(milliseconds: 600),
          seekProgress: Duration(milliseconds: 1000),
          reset: Duration(milliseconds: 300),
        ),
      );
      final gate = Completer<void>();
      final entered = Completer<void>();
      player
        ..claimedSources = <AudioSource>{}
        ..replacementLoadGate = gate
        ..loadGate = gate
        ..loadEntered = entered
        ..gateNonEmptyLoadsOnly = true;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final loading = handler.replaceQueue(['song-0'], expandMatchFlows: false);
      await entered.future;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final seeking = handler.seek(const Duration(seconds: 60));
      await Future<void>.delayed(const Duration(milliseconds: 1800));
      expect(
        (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
        'failed',
      );
      gate.complete();
      await Future.wait([loading, seeking]);
    });

    // Issue #203 (1): a seek whose recovery reload times out leaves the player
    // empty. Android keeps the song and fails over to the next one, like desktop.
    for (final android in [true, false]) {
      test(
        'a seek reload that times out keeps the song and fails over (${android ? 'Android' : 'desktop'})',
        () async {
          if (android) {
            debugDefaultTargetPlatformOverride = TargetPlatform.android;
            addTearDown(() => debugDefaultTargetPlatformOverride = null);
          }
          final hung = <String>{};
          final (handler, player, _) = await fixture(
            timeouts: quick,
            count: 3,
            hungLoadSongs: hung,
            desktopRuntimeOverride: !android,
          );
          await handler.replaceQueue(songIds(3), expandMatchFlows: false);
          player
            ..ignoreSeeks = true
            ..simulateProgress = false
            ..nativePositionFrozen = true;
          hung.add('song-0');
          await handler.seek(const Duration(seconds: 90));
          await idle(handler);
          expect(handler.snapshot.currentSongId, 'song-1');
          expect(handler.snapshot.queueSongIds, songIds(3));
        },
      );
    }

    test(
      'a stalled seek on the last song stops quietly and keeps it (Android)',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final hung = <String>{};
        final (handler, player, _) = await fixture(
          timeouts: quick,
          count: 2,
          hungLoadSongs: hung,
          desktopRuntimeOverride: false,
        );
        await handler.replaceQueue(
          songIds(2),
          startIndex: 1,
          expandMatchFlows: false,
        );
        player
          ..ignoreSeeks = true
          ..simulateProgress = false
          ..nativePositionFrozen = true;
        hung.add('song-1');
        await handler.seek(const Duration(seconds: 90));
        await idle(handler);
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(handler.snapshot.playing, isFalse);
      },
    );

    test('a failover that already moved the queue is not repeated', () async {
      final rebuilt = <ControllableAudioPlayer>[];
      final hungSongs = <String>{};
      final (handler, player, _) = await fixture(
        timeouts: quick,
        count: 3,
        rebuiltPlayers: rebuilt,
        hungLoadSongs: hungSongs,
      );
      final gate = Completer<void>();
      final entered = Completer<void>();
      player
        ..loadGate = gate
        ..loadEntered = entered
        ..gateNonEmptyLoadsOnly = true;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final loading = handler.replaceQueue(songIds(3), expandMatchFlows: false);
      await entered.future;
      hungSongs.add('song-0');
      final seeking = handler.seek(const Duration(seconds: 90));
      await Future.wait([loading, seeking]);
      await idle(handler);
      expect(handler.snapshot.currentSongId, 'song-1');
      expect(handler.snapshot.playing, isTrue);
    });

    test('sidecar bytes cannot extend a seek recovery load deadline', () async {
      final (handler, player, grow) = await fixture(
        timeouts: const NavisPlaybackTimeouts(
          load: Duration(milliseconds: 600),
          seekBufferingRecovery: Duration(milliseconds: 150),
          seekProgress: Duration(seconds: 3),
        ),
      );
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      final gate = Completer<void>();
      final entered = Completer<void>();
      player
        ..ignoreSeeks = true
        ..loadGate = gate
        ..loadEntered = entered
        ..gateNonEmptyLoadsOnly = true;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      grow(growing: true);
      final seeking = handler.seek(const Duration(seconds: 90));
      await entered.future;
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      final retiredAtDeadline = player.disposed;
      gate.complete();
      await seeking;
      await settleQueue(handler);
      expect(retiredAtDeadline, isTrue);
      expect(handler.snapshot.currentSongId, 'song-1');
      expect(handler.snapshot.queueSongIds, ['song-0', 'song-1']);
      expect(handler.snapshot.playing, isTrue);
      expect(handler.snapshot.processingState, AudioProcessingState.ready);
      expect(
        (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
        'failed',
      );
    });

    for (final command in ['next', 'stop']) {
      test(
        '$command aborts a seek recovery load within one check interval',
        () async {
          final (handler, player, grow) = await fixture(
            timeouts: const NavisPlaybackTimeouts(
              load: Duration(seconds: 2),
              seekBufferingRecovery: Duration(milliseconds: 150),
              desktopSeekSettle: Duration(milliseconds: 600),
            ),
          );
          await handler.replaceQueue([
            'song-0',
            'song-1',
          ], expandMatchFlows: false);
          final gate = Completer<void>();
          final entered = Completer<void>();
          player
            ..ignoreSeeks = true
            ..loadGate = gate
            ..loadEntered = entered
            ..gateNonEmptyLoadsOnly = true;
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
          grow(growing: true);
          final seeking = handler.seek(const Duration(seconds: 90));
          await entered.future;
          final control = command == 'next'
              ? handler.skipToNext()
              : handler.stop();
          await Future<void>.delayed(const Duration(milliseconds: 350));
          final retiredAtCheck = player.disposed;
          gate.complete();
          await Future.wait([seeking, control]);
          expect(retiredAtCheck, isTrue);
          expect(
            (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
            'superseded',
          );
          if (command == 'next') {
            expect(handler.snapshot.currentSongId, 'song-1');
          }
          if (command == 'stop') {
            expect(handler.snapshot.playing, isFalse);
          }
        },
      );
    }

    for (final command in ['next', 'stop']) {
      for (final extended in [false, true]) {
        test('$command aborts a ${extended ? 'extended' : 'new'} load '
            'within one check interval', () async {
          final (handler, player, grow) = await fixture();
          final gate = Completer<void>();
          final entered = Completer<void>();
          player
            ..loadGate = gate
            ..loadEntered = entered
            ..gateNonEmptyLoadsOnly = true;
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
          grow(growing: true, bufferProgress: true);
          final loading = handler.replaceQueue([
            'song-0',
            'song-1',
          ], expandMatchFlows: false);
          await entered.future;
          await Future<void>.delayed(
            Duration(milliseconds: extended ? 600 : 100),
          );
          expect(player.disposed, isFalse);
          final control = command == 'next'
              ? handler.skipToNext()
              : handler.stop();
          // One 250 ms check plus scheduling/rebuild slack; below the old
          // 500 ms check that first notices the scaled 300 ms deadline.
          await Future<void>.delayed(const Duration(milliseconds: 300));
          expect(player.disposed, isTrue);
          await Future.wait([loading, control]);
          if (command == 'stop') expect(handler.snapshot.playing, isFalse);
        });
      }
    }

    for (final growing in [true, false]) {
      test('start ${growing ? 'keeps downloading past' : 'still fails at'} '
          'the old load deadline', () async {
        final (handler, player, grow) = await fixture();
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..loadGate = gate
          ..loadEntered = entered
          ..gateNonEmptyLoadsOnly = true;
        grow(growing: growing);
        final failures = <Object>[];
        final loading = handler
            .replaceQueue(['song-0', 'song-1'], expandMatchFlows: false)
            .catchError(failures.add);
        await entered.future;
        final finish = Timer(const Duration(milliseconds: 700), gate.complete);
        addTearDown(() {
          finish.cancel();
          if (!gate.isCompleted) gate.complete();
        });
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(player.disposed, !growing);
        if (growing) expect(handler.snapshot.loadingSongId, 'song-0');
        await loading;
        if (growing) {
          expect(failures, isEmpty);
          expect(handler.snapshot.currentSongId, 'song-0');
          expect(handler.snapshot.playing, isTrue);
        } else {
          expect(handler.snapshot.currentSongId, 'song-1');
        }
      });
    }
    for (final idle in [true, false]) {
      test(
        'start remains bounded by ${idle ? 'download idle' : 'hard cap'}',
        () async {
          final (handler, player, grow) = await fixture(
            timeouts: idle
                ? const NavisPlaybackTimeouts(
                    load: Duration(milliseconds: 300),
                    seekProgress: Duration(milliseconds: 2400),
                    progressIdle: Duration(milliseconds: 300),
                  )
                : deadlines,
          );
          final gate = Completer<void>();
          final entered = Completer<void>();
          player
            ..loadGate = gate
            ..loadEntered = entered
            ..gateNonEmptyLoadsOnly = true;
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
          final failures = <PlaybackLoadFailure>[];
          final subscription = handler.loadFailureStream.listen(failures.add);
          addTearDown(subscription.cancel);
          grow(growing: true);
          final elapsed = Stopwatch()..start();
          final loading = handler.replaceQueue([
            'song-0',
            'song-1',
          ], expandMatchFlows: false);
          await entered.future;
          await Future<void>.delayed(const Duration(milliseconds: 400));
          expect(player.disposed, isFalse);
          if (idle) grow(growing: false);
          await loading;
          expect(player.disposed, isTrue);
          if (handler.snapshot.currentSongId != 'song-1' ||
              handler.snapshot.isLoading) {
            await handler.snapshotStream
                .firstWhere(
                  (snapshot) =>
                      snapshot.currentSongId == 'song-1' && !snapshot.isLoading,
                )
                .timeout(const Duration(seconds: 2));
          }
          expect(handler.snapshot.currentSongId, 'song-1');
          expect(failures, isEmpty);
          expect(elapsed.elapsedMilliseconds, greaterThan(idle ? 500 : 1100));
          if (idle) expect(elapsed.elapsedMilliseconds, lessThan(2000));
        },
      );
    }
  });

  group('Android range bandwidth', () {
    Future<
      (
        NavisAudioHandler,
        ControllableAudioPlayer,
        Map<String, RangeCacheSource>,
      )
    >
    rangeHandler({
      List<ControllableAudioPlayer>? rebuilt,
      TargetPlatform platform = TargetPlatform.android,
    }) async {
      debugDefaultTargetPlatformOverride = platform;
      final directory = await Directory.systemTemp.createTemp(
        'navis-range-priority-',
      );
      final sources = {
        for (var i = 0; i < 3; i++)
          'song-$i': RangeCacheSource(
            'song-$i',
            File(p.join(directory.path, '$i.mp3')),
          ),
      };
      final (handler, player, database) = await createHandler(
        directory,
        3,
        cacheSongs: false,
        positionStreams: true,
        rebuiltPlayers: rebuilt,
        desktopRuntimeOverride: platform == TargetPlatform.linux,
        timeouts: const NavisPlaybackTimeouts(
          control: Duration(milliseconds: 300),
          progressIdle: Duration(milliseconds: 400),
          seekProgress: Duration(seconds: 3),
        ),
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
      return (handler, player, sources);
    }

    for (final exit in [
      'Pause',
      'seek back',
      'skip',
      'Stop',
      'replace',
      'dispose',
      'buffer full',
      'range failed',
    ]) {
      test(
        'range priority pauses current and next and resumes on $exit',
        () async {
          final (handler, player, sources) = await rangeHandler();
          sources['song-0']!.activeRange = true;
          player.emitBuffered(const Duration(seconds: 2));
          await pumpEventQueue();
          expect(sources['song-0']!.paused, isTrue);
          expect(sources['song-1']!.paused, isTrue);
          expect(sources['song-2']!.paused, isFalse);
          switch (exit) {
            case 'Pause':
              await handler.pause();
            case 'seek back':
              sources['song-0']!.activeRange = false;
              await handler.seek(Duration.zero);
            case 'skip':
              await handler.skipToNext();
            case 'Stop':
              await handler.stop();
            case 'replace':
              await handler.replaceQueue(['song-2'], expandMatchFlows: false);
            case 'dispose':
              await handler.disposeHandler();
            case 'buffer full':
              player.emitBuffered(const Duration(seconds: 60));
            case 'range failed':
              sources['song-0']!.activeRange = false;
              sources['song-0']!.progress.add(0);
          }
          await pumpEventQueue();
          expect(sources['song-0']!.paused, isFalse);
          expect(sources['song-1']!.paused, isFalse);
        },
      );
    }

    for (final progress in ['range', 'buffer', 'none']) {
      test(
        'mobile native seek ${progress == 'none' ? 'retires' : 'keeps'} its engine with $progress progress',
        () async {
          final rebuilt = <ControllableAudioPlayer>[];
          final (handler, player, sources) = await rangeHandler(
            rebuilt: rebuilt,
          );
          final gate = Completer<void>();
          final entered = Completer<void>();
          player
            ..seekGate = gate
            ..seekEntered = entered;
          final seek = handler.seek(const Duration(seconds: 30));
          await entered.future.timeout(const Duration(seconds: 2));
          player.state = ProcessingState.buffering;
          sources['song-0']!.activeRange = true;
          player.emitBuffered(const Duration(seconds: 2));
          final ticker = Timer.periodic(const Duration(milliseconds: 50), (_) {
            if (progress == 'range') {
              sources['song-0']!.receivedRangeBytes += 1024;
            }
            if (progress == 'buffer') {
              player.emitBuffered(
                player.bufferedPosition + const Duration(seconds: 1),
              );
            }
          });
          try {
            await Future<void>.delayed(const Duration(milliseconds: 900));
            expect(rebuilt, progress == 'none' ? hasLength(1) : isEmpty);
            gate.complete();
            if (progress != 'none') player.state = ProcessingState.ready;
            await seek;
            expect(rebuilt, progress == 'none' ? hasLength(1) : isEmpty);
            if (progress == 'none') {
              expect(sources['song-0']!.paused, isFalse);
              expect(sources['song-1']!.paused, isFalse);
            }
          } finally {
            ticker.cancel();
            if (!gate.isCompleted) gate.complete();
            await seek;
          }
        },
      );
    }

    test('Pause during progressing native seek releases downloads and stays paused', () async {
      final rebuilt = <ControllableAudioPlayer>[];
      final (handler, player, sources) = await rangeHandler(rebuilt: rebuilt);
      sources['song-0']!.activeRange = true;
      final gate = Completer<void>();
      final entered = Completer<void>();
      player
        ..seekGate = gate
        ..seekEntered = entered;
      final seek = handler.seek(const Duration(seconds: 30));
      await entered.future;
      player.state = ProcessingState.buffering;
      await handler.pause();
      expect(sources['song-0']!.paused, isFalse);
      gate.complete();
      await seek;
      expect(player.playing, isFalse);
      expect(rebuilt, isEmpty);
    });

    test('desktop native seek retains its fixed control deadline', () async {
      final rebuilt = <ControllableAudioPlayer>[];
      final (handler, player, sources) = await rangeHandler(
        rebuilt: rebuilt,
        platform: TargetPlatform.linux,
      );
      player.hang.add('seek');
      final ticker = Timer.periodic(
        const Duration(milliseconds: 50),
        (_) => sources['song-0']!.receivedRangeBytes += 1024,
      );
      try {
        await handler.seek(const Duration(seconds: 30));
        expect(rebuilt, hasLength(1));
      } finally {
        ticker.cancel();
      }
    });

    test(
      'new seek cancels a progressing native wait and keeps lock caching',
      () async {
        final rebuilt = <ControllableAudioPlayer>[];
        final (handler, player, sources) = await rangeHandler(rebuilt: rebuilt);
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..seekGate = gate
          ..seekEntered = entered;
        final old = handler.seek(const Duration(seconds: 30));
        await entered.future.timeout(const Duration(seconds: 2));
        sources['song-0']!.activeRange = true;
        player.state = ProcessingState.buffering;
        final ticker = Timer.periodic(
          const Duration(milliseconds: 50),
          (_) => sources['song-0']!.receivedRangeBytes += 1024,
        );
        final latest = handler.seek(const Duration(seconds: 60));
        try {
          await Future<void>.delayed(const Duration(milliseconds: 900));
          expect(rebuilt, isEmpty);
          expect(player.seekCalls, 2);
          expect(player.sourceLoads, 1);
          expect(
            handler.queue.value.first.extras!['sourceKind'],
            PlaybackSourceKind.lockCachedStream.name,
          );
          expect(sources['song-0']!.activeRange, isTrue);
          expect(handler.debugQueueLaneIdle, isTrue);
          expect(
            handler.collectPlaybackDiagnostics()['lockCachingBypassed'],
            isFalse,
          );
          expect(handler.collectPlaybackDiagnostics()['anomalies'], isEmpty);
        } finally {
          ticker.cancel();
          gate.complete();
          await Future.wait([old, latest]);
          await pumpEventQueue();
        }
        expect(handler.snapshot.currentSongId, 'song-0');
        expect(handler.snapshot.pendingSeekPosition, isNull);
      },
    );

    test(
      'dead native seek cancels retired ranges before stop returns',
      () async {
        final rebuilt = <ControllableAudioPlayer>[];
        final (handler, player, sources) = await rangeHandler(rebuilt: rebuilt);
        final seekGate = Completer<void>();
        final stopGate = Completer<void>();
        final entered = Completer<void>();
        player
          ..seekGate = seekGate
          ..seekEntered = entered
          ..stopGate = stopGate;
        final seek = handler.seek(const Duration(seconds: 30));
        await entered.future.timeout(const Duration(seconds: 2));
        sources['song-0']!.activeRange = true;
        player.state = ProcessingState.buffering;
        player.emitBuffered(const Duration(seconds: 2));
        try {
          await Future<void>.delayed(const Duration(milliseconds: 900));
          expect(rebuilt, hasLength(1));
          expect(stopGate.isCompleted, isFalse);
          expect(sources['song-0']!.activeRange, isFalse);
          expect(sources['song-0']!.paused, isFalse);
          expect(sources['song-1']!.paused, isFalse);
        } finally {
          stopGate.complete();
          seekGate.complete();
          await seek;
        }
      },
    );

    test(
      'dead native seek clears retired cache activity and tracking',
      () async {
        final rebuilt = <ControllableAudioPlayer>[];
        final (handler, player, sources) = await rangeHandler(rebuilt: rebuilt);
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        await pumpEventQueue();
        final source = sources['song-0']!;
        source.progress.add(0.4);
        await pumpEventQueue();
        expect(
          handler.collectPlaybackDiagnostics()['cacheActivity'],
          containsPair('songId', 'song-0'),
        );
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..seekGate = gate
          ..seekEntered = entered;
        final seek = handler.seek(const Duration(seconds: 30));
        try {
          await entered.future.timeout(const Duration(seconds: 2));
          player.state = ProcessingState.buffering;
          await Future<void>.delayed(const Duration(milliseconds: 900));
          expect(rebuilt, hasLength(1));
          expect(handler.snapshot.currentSongId, 'song-0');
          expect(handler.collectPlaybackDiagnostics()['cacheActivity'], isNull);
          expect(source.progress.hasListener, isFalse);
        } finally {
          gate.complete();
          await seek;
        }
      },
    );

    test(
      'range priority ignores a next song from a mismatched queue index',
      () async {
        final (handler, player, sources) = await rangeHandler();
        sources['song-0']!.activeRange = true;
        player.emitBuffered(const Duration(seconds: 2));
        await pumpEventQueue();
        expect(sources['song-1']!.paused, isTrue);
        // Native index can move before the current media item is published.
        player.index = 1;
        sources['song-0']!.progress.add(0);
        await pumpEventQueue();
        expect(handler.mediaItem.value!.id, 'song-0');
        expect(sources['song-0']!.paused, isTrue);
        expect(sources['song-1']!.paused, isFalse);
        expect(sources['song-2']!.paused, isFalse);
      },
    );

    test(
      'desktop lock-cache probes do not pause whole-file downloads',
      () async {
        final (_, player, sources) = await rangeHandler(
          platform: TargetPlatform.linux,
        );
        sources['song-0']!.activeRange = true;
        player.emitBuffered(const Duration(seconds: 2));
        await pumpEventQueue();
        expect(sources.values.every((source) => !source.paused), isTrue);
      },
    );

    test('Android load reserve keeps native playback thresholds', () {
      final control =
          NavisAudioHandler.androidLoadConfiguration.androidLoadControl!;
      expect(control.minBufferDuration, const Duration(seconds: 180));
      expect(control.maxBufferDuration, const Duration(seconds: 180));
      expect(control.targetBufferBytes, 32 * 1024 * 1024);
      expect(control.prioritizeTimeOverSizeThresholds, isFalse);
      expect(
        control.bufferForPlaybackDuration,
        const Duration(milliseconds: 2500),
      );
      expect(
        control.bufferForPlaybackAfterRebufferDuration,
        const Duration(seconds: 5),
      );
    });
  });
}
