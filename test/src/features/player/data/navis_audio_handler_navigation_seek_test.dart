import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride, debugPrint;

import 'package:navis/src/features/player/domain/playback_adjustments.dart';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:navis/src/features/player/data/playback_art_cache.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/constants.dart';
import 'package:drift/drift.dart' show Value;
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/recommendation_service.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/data/scrobble_service.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/domain/streaming_quality.dart';

import '../../../../helpers/cached_audio_builders.dart';
import '../../../../helpers/test_database.dart';
import 'navis_audio_handler_navigation_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(const RadioFilters()));

  group('playback anomaly recorder', () {
    Future<(NavisAudioHandler, ControllableAudioPlayer, List<String>)>
    anomalyHandler({int duration = 180}) async {
      final directory = await Directory.systemTemp.createTemp('navis-anomaly-');
      final (handler, player, database) = await createHandler(
        directory,
        3,
        positionStreams: true,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final warnings = <String>[];
      final printer = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null && message.contains('[PLAYBACK_ANOMALY]')) {
          warnings.add(message);
        }
      };
      addTearDown(() => debugPrint = printer);
      await database.libraryDao.upsertSongs([
        SongsTableCompanion.insert(
          id: 'song-1',
          title: 'Song 1',
          duration: Value(duration),
        ),
      ]);
      // The position stream only reports a moving position.
      player.simulateProgress = true;
      await handler.replaceQueue(
        ['song-0', 'song-1', 'song-2'],
        startIndex: 1,
        expandMatchFlows: false,
      );
      await settleQueue(handler);
      await handler.play();
      // Let the load's own position moves leave the recorder's grace window.
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      return (handler, player, warnings);
    }

    Future<void> pause(int ms) =>
        Future<void>.delayed(Duration(milliseconds: ms));

    // One printed line per record header; the rest are its events.
    List<String> headers(List<String> lines) =>
        lines.where((line) => line.contains('"kind":')).toList();

    List<Object?> anomalies(NavisAudioHandler handler) =>
        handler.collectPlaybackDiagnostics()['anomalies']! as List<Object?>;

    test(
      'a four-second natural advance survives the desktop index yield',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final (handler, player, warnings) = await anomalyHandler(duration: 4);
        player.simulatedPosition = const Duration(milliseconds: 3368);
        await pause(200);
        final loads = player.sourceLoads;

        player.finishCurrentTrack(endPosition: const Duration(seconds: 4));
        player.emitPlayerEvent();
        await pause(600);

        expect(handler.snapshot.currentSongId, 'song-2');
        expect(player.sourceLoads, loads);
        expect(anomalies(handler), isEmpty);
        expect(warnings, isEmpty);
      },
    );

    test(
      'a raw player step back is recorded once, with the log line',
      () async {
        final (handler, player, warnings) = await anomalyHandler();
        player.simulatedPosition = const Duration(seconds: 90);
        await pause(500);
        player.simulatedPosition = const Duration(seconds: 80);
        await pause(1200);

        expect(anomalies(handler), hasLength(1));
        expect(headers(warnings), hasLength(1));
        expect(warnings.join('\n'), contains('"kind":"backwardJump"'));
        expect(warnings.join('\n'), isNot(contains('song-1')));
      },
    );

    test('a swapped queue entry mid-song does not hide a rewind', () async {
      final (handler, player, warnings) = await anomalyHandler();
      player.simulatedPosition = const Duration(seconds: 90);
      await pause(500);
      // Likes, art caching and recovery rebuilds replace the entry object.
      await handler.syncSongLikedState('song-1', liked: true);
      await pause(500);
      player.simulatedPosition = const Duration(seconds: 85);
      await pause(1200);

      expect(anomalies(handler), hasLength(1));
      expect(headers(warnings), hasLength(1));
    });

    test('a recovery rebuild landing behind its target is recorded', () async {
      final directory = await Directory.systemTemp.createTemp('navis-anomaly-');
      final (handler, player, database) = await createHandler(
        directory,
        3,
        sidecarStreams: true,
        positionStreams: true,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final warnings = <String>[];
      final printer = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null && message.contains('[PLAYBACK_ANOMALY]')) {
          warnings.add(message);
        }
      };
      addTearDown(() => debugPrint = printer);
      player.simulateProgress = true;
      await handler.replaceQueue(
        ['song-0', 'song-1', 'song-2'],
        startIndex: 1,
        expandMatchFlows: false,
      );
      await settleQueue(handler);
      await handler.play();
      await pause(1700);
      player.simulatedPosition = const Duration(seconds: 70);
      await pause(500);

      // The reload ignores its start position and every correction seek.
      player
        ..ignoreInitialPosition = true
        ..ignoreSeeks = true
        ..simulatedPosition = const Duration(seconds: 70)
        ..state = ProcessingState.idle;
      player.playbackEvents.addError(
        PlayerException(2002, 'Read timed out', 1),
      );
      for (var i = 0; i < 300 && anomalies(handler).isEmpty; i++) {
        await pause(50);
      }

      expect(anomalies(handler), hasLength(1));
      expect(warnings.join('\n'), contains('"e":"recovery"'));
      // The automatic recovery ends with a seekDone row, like a user seek.
      expect(warnings.join('\n'), contains('"outcome":"recovery"'));
    });

    test('a skip whose song is published early is not a rewind', () async {
      final (handler, player, warnings) = await anomalyHandler();
      player.simulatedPosition = const Duration(seconds: 90);
      await pause(500);
      // The native seek to the next song hangs, as a slow load does: the
      // handler publishes song-2 while the player still plays song-1.
      final gate = Completer<void>();
      player.seekGate = gate;
      final skip = handler.skipToNext();
      await pause(300);
      expect(handler.currentMediaItem?.id, 'song-2');
      expect(player.index, 1);
      await pause(1900);
      gate.complete();
      await skip;
      await pause(1500);
      expect(anomalies(handler), isEmpty);
      expect(warnings, isEmpty);

      // A real rewind on the new song is still caught.
      player.simulatedPosition = const Duration(seconds: 40);
      await pause(500);
      player.simulatedPosition = const Duration(seconds: 30);
      await pause(1200);
      expect(anomalies(handler), hasLength(1));
    });

    test('a seek during an outage is explained', () async {
      final directory = await Directory.systemTemp.createTemp('navis-anomaly-');
      final (handler, player, database) = await createHandler(
        directory,
        3,
        sidecarStreams: true,
        positionStreams: true,
        reconcileNetwork: () async =>
            (connected: false, serverReachable: false),
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      player.simulateProgress = true;
      await handler.replaceQueue(
        ['song-0', 'song-1', 'song-2'],
        startIndex: 1,
        expandMatchFlows: false,
      );
      await settleQueue(handler);
      await handler.play();
      await pause(1700);
      player.simulatedPosition = const Duration(seconds: 60);
      await pause(500);

      // The stream drops; offline, the recovery is held, not run.
      player
        ..simulatedPosition = const Duration(seconds: 60)
        ..state = ProcessingState.idle;
      player.playbackEvents.addError(
        PlayerException(2002, 'Read timed out', 1),
      );
      await pause(500);
      await handler.seek(const Duration(seconds: 30));
      player
        ..simulatedPosition = const Duration(seconds: 30)
        ..state = ProcessingState.ready;
      await pause(1500);

      expect(anomalies(handler), isEmpty);
    });

    test('a handler seek back is not an anomaly', () async {
      final (handler, player, warnings) = await anomalyHandler();
      player.simulatedPosition = const Duration(seconds: 90);
      await pause(500);
      await handler.seek(const Duration(seconds: 30));
      await pause(1500);

      expect(player.position, lessThan(const Duration(seconds: 40)));
      expect(anomalies(handler), isEmpty);
      expect(warnings, isEmpty);
    });

    test('a skipToPrevious restart is not an anomaly', () async {
      final (handler, player, warnings) = await anomalyHandler();
      player.simulatedPosition = const Duration(seconds: 90);
      await pause(500);
      await handler.skipToPrevious();
      await settleQueue(handler);
      await pause(1500);

      expect(anomalies(handler), isEmpty);
      expect(warnings, isEmpty);
    });

    test('a Repeat One loop is not an anomaly', () async {
      final (handler, player, warnings) = await anomalyHandler();
      await handler.setRepeatMode(AudioServiceRepeatMode.one);
      player.simulatedPosition = const Duration(seconds: 170);
      await pause(500);
      player.finishCurrentTrack();
      await pause(1500);

      expect(anomalies(handler), isEmpty);
      expect(warnings, isEmpty);
    });
  });

  group('fast seeking bridge', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.linux);
    tearDown(() => debugDefaultTargetPlatformOverride = null);
    const target = Duration(seconds: 90);
    Future<
      (NavisAudioHandler, ControllableAudioPlayer, NavisDatabase, BridgeSidecar)
    >
    bridgeHandler({
      bool enabled = true,
      bool capable = true,
      bool slow = true,
      bool lossy = false,
      bool transcode = false,
      bool external = false,
      bool crossfade = false,
      PlaybackSourceResolver Function(PlaybackSourceResolver)? wrap,
    }) async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-fast-seek-',
      );
      final downloader = BridgeSidecar()..rate = slow ? 10000 : null;
      final (handler, player, db) = await createHandler(
        directory,
        3,
        sidecarStreams: true,
        cacheSongs: false,
        sidecarDownloader: downloader,
        // These cases watch the current song's single download.
        nextSongPrefetchAllowed: false,
        supportsTranscodeOffset: capable,
        fastSeeking: enabled,
        wrapResolver: wrap,
        crossfade: crossfade,
        streamingQuality: transcode
            ? const StreamingQuality(
                label: 'opus',
                format: 'opus',
                maxBitRate: 128,
              )
            : const StreamingQuality(label: 'original'),
        timeouts: const NavisPlaybackTimeouts(
          fastSeekGuard: Duration(milliseconds: 500),
          desktopSeekSettle: Duration(seconds: 1),
        ),
        seed: (db) => db.libraryDao.upsertSongs([
          for (var i = 0; i < 3; i++)
            SongsTableCompanion.insert(
              id: 'song-$i',
              title: 'Song $i',
              duration: const Value(180),
              suffix: Value(lossy ? 'mp3' : 'flac'),
              bitRate: const Value(1000),
              isExternal: Value(external),
            ),
        ]),
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await db.close();
        await directory.delete(recursive: true);
      });
      player.simulateProgress = true;
      await handler.replaceQueue(
        ['song-0', 'song-1', 'song-2'],
        startIndex: 1,
        expandMatchFlows: false,
      );
      await settleQueue(handler);
      await handler.play();
      return (handler, player, db, downloader);
    }

    UriAudioSource current(ControllableAudioPlayer player) =>
        player.sequence[player.index!] as UriAudioSource;
    Future<void> seekTo(NavisAudioHandler handler, Duration position) async {
      await handler.seek(position);
      await settleQueue(handler);
    }

    Map<String, Object?> event(NavisAudioHandler handler) =>
        (handler.collectPlaybackDiagnostics()['seekEvents']! as List).last
            as Map<String, Object?>;
    bool bridging(NavisAudioHandler handler) =>
        handler.mediaItem.value?.extras?['bridgeFormat'] == 'opus';

    for (final slow in [false, true]) {
      test(
        'seek preview opens only the immediate bridge plan (slow=$slow)',
        () async {
          final (handler, player, _, _) = await bridgeHandler(slow: slow);
          final client = SeekPreviewHttpClient()..respond();
          await HttpOverrides.runZoned(
            () => handler.previewSeek(target),
            createHttpClient: (_) => client,
          );
          await pumpEventQueue();
          expect(client.gets, slow ? 1 : 0);
          if (slow) {
            await handler.seek(target);
            // ignore: experimental_member_use, reason: Verify bridge preview adoption through the proxy.
            final source = player.sequence[player.index!] as StreamAudioSource;
            final response = await source.request();
            final sub = response.stream.listen((_) {});
            await sub.cancel();
            expect(client.gets, 1);
          }
          handler.cancelSeekPreview();
          unawaited(client.body.close());
        },
      );
    }

    test('slow link bridges immediately without restarting or caching the transcode', () async {
      final (handler, player, db, downloader) = await bridgeHandler();
      final starts = downloader.starts;
      await seekTo(handler, target);
      expect(bridging(handler), isTrue);
      expect(current(player).uri.queryParameters['format'], 'opus');
      expect(current(player).uri.queryParameters['maxBitRate'], '256');
      expect(current(player).positionOffset, target);
      expect(downloader.starts, starts);
      expect(event(handler)['path'], 'fastSeekBridge');
      expect(handler.collectPlaybackDiagnostics()['anomalies'], isEmpty);
      expect(downloader.downloadUri!.queryParameters['timeOffset'], isNull);
      downloader.bytes += 65536;
      downloader.progress!(.2);
      expect(handler.collectPlaybackDiagnostics()['partialCacheBytes'], 131072);
      await downloader.finish();
      final cached = (await db.cacheDao.getCachedTrack('song-1'))!;
      expect(cached.filePath, downloader.path);
      expect(cached.format, 'flac');
      expect(cached.bitRate, 1000);
      expect(cached.fileSize, 131072);
      expect(bridging(handler), isTrue);
      await seekTo(handler, const Duration(seconds: 110));
      expect(current(player).uri.scheme, 'file');
      expect(bridging(handler), isFalse);
      expect(handler.mediaItem.value!.extras, isNot(contains('bridgeBitRate')));
    });

    test(
      'bridge keeps playing when the original sidecar ends without a file',
      () async {
        final (handler, player, db, downloader) = await bridgeHandler();
        await seekTo(handler, target);
        final source = current(player);
        await downloader.cancel();
        expect(bridging(handler), isTrue);
        expect(player.playing, isTrue);
        expect(current(player), same(source));
        expect(handler.collectPlaybackDiagnostics()['cacheActivity'], isNull);
        expect(await db.cacheDao.getCachedTrack('song-1'), isNull);
        expect(File(downloader.path!).existsSync(), isFalse);
      },
    );

    test(
      'bridge started without an active sidecar downloads the original',
      () async {
        final (handler, player, db, downloader) = await bridgeHandler();
        await downloader.cancel();
        player.ignoredSeeks = 1;
        await seekTo(handler, target);
        expect(bridging(handler), isTrue);
        expect(
          downloader.downloadUri!.queryParameters['format'],
          isNot('opus'),
        );
        await downloader.finish();
        final cached = (await db.cacheDao.getCachedTrack('song-1'))!;
        expect(cached.format, 'flac');
        expect(cached.bitRate, 1000);
      },
    );

    test(
      'installed bridge load failure restores the native queue before fallback',
      () async {
        final (handler, player, _, downloader) = await bridgeHandler();
        final starts = downloader.starts;
        final notices = <PlaybackLoadFailure>[];
        final subscription = handler.loadFailureStream.listen(notices.add);
        addTearDown(subscription.cancel);
        player.rejectBridgeLoad = true;
        await seekTo(handler, target);
        expectNativeMirrorsQueue(handler, player);
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(current(player).positionOffset, Duration.zero);
        expect(current(player).uri.queryParameters['format'], isNot('opus'));
        expect(bridging(handler), isFalse);
        expect(event(handler)['outcome'], 'completed');
        expect(notices, isEmpty);
        expect(downloader.starts, starts);
      },
    );

    test('native guard exception still attempts the bridge', () async {
      final (handler, player, _, _) = await bridgeHandler(slow: false);
      player.rejectNextSeek = true;
      await seekTo(handler, target);
      expect(bridging(handler), isTrue);
      expect(event(handler)['path'], 'fastSeekBridge');
      expect(player.seekCalls, 1);
    });

    test(
      'paused buffering bridge resumes the original after seek settlement',
      () async {
        final (handler, player, _, downloader) = await bridgeHandler();
        await handler.pause();
        player.bufferAfterLoad = true;
        await seekTo(handler, target);
        expect(bridging(handler), isTrue);
        expect(event(handler)['outcome'], 'completed');
        expect(player.processingState, ProcessingState.buffering);
        expect(player.playing, isFalse);
        expect(downloader.isPaused, isFalse);
        player.playbackEvents.add(player.playbackEvent);
        await pumpEventQueue(times: 20);
        expect(downloader.isPaused, isFalse);
      },
    );

    for (final milliseconds in [90750, 179750]) {
      test(
        'bridge reload starts at whole-second offset for $milliseconds ms',
        () async {
          final (handler, player, _, _) = await bridgeHandler();
          await seekTo(handler, Duration(milliseconds: milliseconds));
          expect(bridging(handler), isTrue);
          expect(
            player.bridgeInitialPositions.single,
            current(player).positionOffset,
          );
        },
      );
    }

    test('fast or unknown link settles natively without a bridge', () async {
      final (handler, player, _, _) = await bridgeHandler(slow: false);
      final loads = player.sourceLoads;
      await seekTo(handler, target);
      expect(bridging(handler), isFalse);
      expect(player.sourceLoads, loads);
    });

    test('measured fast link keeps a settled native seek', () async {
      final (handler, player, _, downloader) = await bridgeHandler();
      downloader.rate = 10000000;
      final loads = player.sourceLoads;
      await seekTo(handler, target);
      expect(player.sourceLoads, loads);
      expect(bridging(handler), isFalse);
    });

    test('failed bridge falls back silently to the native path', () async {
      late GatedSourceResolver resolver;
      final (handler, _, _, _) = await bridgeHandler(
        wrap: (base) => resolver = GatedSourceResolver(base),
      );
      final notices = <PlaybackLoadFailure>[];
      final subscription = handler.loadFailureStream.listen(notices.add);
      addTearDown(subscription.cancel);
      resolver.rejectBridge = true;
      await seekTo(handler, target);
      expect(bridging(handler), isFalse);
      expect(notices, isEmpty);
      expect(event(handler)['outcome'], 'completed');
    });

    test(
      'crossfade hands over from a bridge to a plain lossless song',
      () async {
        final (handler, player, _, downloader) = await bridgeHandler(
          crossfade: true,
        );
        await seekTo(handler, target);
        final incoming = handler.debugInactiveDeck! as ControllableAudioPlayer;
        incoming.simulateProgress = true;
        player.simulatedPosition = const Duration(seconds: 175);
        await handler.debugStartCrossfade();
        await handler.debugCompleteCrossfade();
        await settleQueue(handler);
        expect(handler.snapshot.currentSongId, 'song-2');
        expect(bridging(handler), isFalse);
        expect(downloader.isPaused, isFalse);
        expect(current(incoming).positionOffset, Duration.zero);
      },
    );

    test('Android runtime keeps the original native seek', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final (handler, player, _, _) = await bridgeHandler();
      final loads = player.sourceLoads;
      await seekTo(handler, target);
      expect(bridging(handler), isFalse);
      expect(player.sourceLoads, loads);
    });

    test('radio keeps its existing non-seekable behavior', () async {
      final (handler, _, _, _) = await bridgeHandler();
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: 'https://radio.example.invalid/live',
      );
      await handler.seek(target);
      expect(bridging(handler), isFalse);
      expect(handler.snapshot.radioStation?.stationId, 'fixture');
    });

    test('fast link guard expires and opens a bridge', () async {
      final (handler, player, _, _) = await bridgeHandler(slow: false);
      player.ignoredSeeks = 1;
      await seekTo(handler, target);
      expect(bridging(handler), isTrue);
      final probe = (event(handler)['unsettled']! as List).first as Map;
      expect(probe['elapsedMs'], inInclusiveRange(500, 1000));
    });

    test('cache completion during guard uses the local original', () async {
      final (handler, player, _, downloader) = await bridgeHandler(slow: false);
      player.ignoredSeeks = 1;
      final seeking = handler.seek(target);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await downloader.finish();
      await seeking;
      await settleQueue(handler);
      expect(current(player).uri.scheme, 'file');
      expect(bridging(handler), isFalse);
    });

    test('bridge yields while loading and buffering and resumes on ready, upgrade, change and stop', () async {
      final (handler, player, _, downloader) = await bridgeHandler();
      await seekTo(handler, target);
      for (final state in [
        ProcessingState.loading,
        ProcessingState.buffering,
        ProcessingState.ready,
      ]) {
        player.state = state;
        player.playbackEvents.add(player.playbackEvent);
        await pumpEventQueue(times: 20);
        expect(downloader.isPaused, state != ProcessingState.ready);
      }
      player.state = ProcessingState.buffering;
      player.playbackEvents.add(player.playbackEvent);
      await pumpEventQueue(times: 20);
      await seekTo(handler, const Duration(seconds: 5));
      expect(bridging(handler), isFalse);
      expect(downloader.isPaused, isFalse);
      await seekTo(handler, target);
      player.state = ProcessingState.buffering;
      player.playbackEvents.add(player.playbackEvent);
      await pumpEventQueue(times: 20);
      await handler.skipToNext();
      await settleQueue(handler);
      expect(downloader.isPaused, isFalse);
      await seekTo(handler, target);
      player.state = ProcessingState.buffering;
      player.playbackEvents.add(player.playbackEvent);
      await pumpEventQueue(times: 20);
      await handler.stop();
      player.playbackEvents.add(player.playbackEvent);
      await pumpEventQueue(times: 20);
      expect(downloader.isPaused, isFalse);
    });

    test(
      'pause resumes the original while a queue edit hides player events',
      () async {
        final (handler, player, _, downloader) = await bridgeHandler();
        await seekTo(handler, target);
        player.state = ProcessingState.buffering;
        player.playbackEvents.add(player.playbackEvent);
        await pumpEventQueue(times: 20);
        expect(downloader.isPaused, isTrue);
        final gate = Completer<void>();
        player
          ..removeGate = gate
          ..removeEntered = Completer<void>();
        final removing = handler.removeQueueItemAt(2);
        try {
          await player.removeEntered!.future;
          expect(handler.debugQueueLaneIdle, isFalse);
          expect(
            handler.collectPlaybackDiagnostics()['playerMatchesQueue'],
            isFalse,
          );
          await handler.pause();
          player.playbackEvents.add(player.playbackEvent);
          await pumpEventQueue(times: 20);
          expect(player.playing, isFalse);
          expect(downloader.isPaused, isFalse);
        } finally {
          gate.complete();
          await removing;
        }
        await settleQueue(handler);
      },
    );

    test(
      'seek into downloaded extent upgrades lossless and stays paused',
      () async {
        final (handler, player, _, _) = await bridgeHandler();
        await handler.pause();
        await seekTo(handler, target);
        expect(bridging(handler), isTrue);
        expect(player.playing, isFalse);
        await seekTo(handler, const Duration(seconds: 5));
        expect(bridging(handler), isFalse);
        expect(current(player).positionOffset, Duration.zero);
        expect(current(player).uri.queryParameters['format'], isNot('opus'));
        expect(player.playing, isFalse);
      },
    );

    for (final reject in [false, true]) {
      test(
        'premature transcode EOF recovers a bridge (rejected: $reject)',
        () async {
          late GatedSourceResolver resolver;
          final (handler, player, _, _) = await bridgeHandler(
            wrap: (base) => resolver = GatedSourceResolver(base),
          );
          if (reject) {
            await handler.replaceQueue(
              ['song-1', 'song-1', 'song-1'],
              startIndex: 1,
              expandMatchFlows: false,
            );
            await settleQueue(handler);
          }
          await seekTo(handler, target);
          resolver.rejectBridge = reject;
          final events =
              (handler.collectPlaybackDiagnostics()['seekEvents']! as List)
                  .length;
          player.simulatedDuration = const Duration(seconds: 110);

          player.finishCurrentTrack(endPosition: const Duration(seconds: 110));
          for (
            var i = 0;
            i < 300 &&
                (handler.collectPlaybackDiagnostics()['seekEvents']! as List)
                        .length ==
                    events;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await settleQueue(handler);

          expect(
            (handler.collectPlaybackDiagnostics()['seekEvents']! as List)
                .length,
            events + 1,
          );
          expect(handler.snapshot.currentSongId, 'song-1');
          expect(player.index, 1);
          expect(player.position.inSeconds, 110);
          expect(bridging(handler), !reject);
          expect(
            current(player).positionOffset,
            reject ? Duration.zero : const Duration(seconds: 110),
          );
          expect(player.playing, isTrue);
        },
      );
    }

    test('Repeat One returns to lossless', () async {
      final (handler, player, _, _) = await bridgeHandler();
      await seekTo(handler, target);
      await handler.setRepeatMode(AudioServiceRepeatMode.one);
      player.finishCurrentTrack(endPosition: const Duration(seconds: 180));
      for (var i = 0; i < 300 && bridging(handler); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await settleQueue(handler);
      expect(bridging(handler), isFalse);
      expect(current(player).positionOffset, Duration.zero);
    });

    test('advancing away and back clears bridge extras', () async {
      final (handler, player, _, _) = await bridgeHandler();
      await seekTo(handler, target);
      await handler.skipToNext();
      await settleQueue(handler);
      player.simulatedPosition = Duration.zero;
      await handler.skipToPrevious();
      await settleQueue(handler);
      expect(handler.snapshot.currentSongId, 'song-1');
      expect(bridging(handler), isFalse);
      expect(current(player).positionOffset, Duration.zero);
    });

    test('recovery preserves a bridge at the exact song position', () async {
      final (handler, player, _, _) = await bridgeHandler();
      await seekTo(handler, target);
      player.simulatedPosition = const Duration(milliseconds: 110750);
      player.state = ProcessingState.idle;
      player.playbackEvents.addError(
        PlayerException(2002, 'Read timed out', 1),
      );
      for (
        var i = 0;
        i < 300 && current(player).positionOffset.inSeconds != 110;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await settleQueue(handler);
      expect(bridging(handler), isTrue);
      expect(current(player).uri.queryParameters['timeOffset'], '110');
      expect(
        player.position,
        greaterThanOrEqualTo(const Duration(seconds: 110)),
      );
      expect(player.position, lessThan(const Duration(seconds: 112)));
    });

    for (final rejectBridge in [false, true]) {
      test(
        'completed original replaces the bridge during remote recovery, bridge fails=$rejectBridge',
        () async {
          late GatedSourceResolver resolver;
          final (handler, player, _, downloader) = await bridgeHandler(
            wrap: (base) => resolver = GatedSourceResolver(base),
          );
          await seekTo(handler, target);
          await downloader.finish();
          resolver.rejectBridge = rejectBridge;
          player.simulatedPosition = const Duration(milliseconds: 110750);
          player.state = ProcessingState.idle;
          final before =
              (handler.collectPlaybackDiagnostics()['seekEvents']! as List)
                  .length;
          player.playbackEvents.addError(
            PlayerException(2002, 'Read timed out', 1),
          );
          for (
            var i = 0;
            i < 300 &&
                (handler.collectPlaybackDiagnostics()['seekEvents']! as List)
                        .length ==
                    before;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await settleQueue(handler);
          expect(handler.snapshot.currentSongId, 'song-1');
          expect(bridging(handler), isFalse);
          expect(current(player).uri.scheme, 'file');
          expect(current(player).positionOffset, Duration.zero);
          expectNativeMirrorsQueue(handler, player);
          expect(
            player.position,
            greaterThanOrEqualTo(const Duration(milliseconds: 110750)),
          );
        },
      );
    }

    for (final completesDuringReopen in [true, false]) {
      test(
        'failed bridge recovery falls back without skipping, cache completes during reopen=$completesDuringReopen',
        () async {
          final (handler, player, _, downloader) = await bridgeHandler();
          await seekTo(handler, target);
          final starts = downloader.starts;
          final loads = player.sourceLoads;
          final notices = <PlaybackLoadFailure>[];
          final subscription = handler.loadFailureStream.listen(notices.add);
          addTearDown(subscription.cancel);
          final gate = Completer<void>();
          player
            ..rejectBridgeLoad = true
            ..loadGate = gate
            ..loadEntered = Completer<void>()
            ..simulatedPosition = const Duration(milliseconds: 110750)
            ..state = ProcessingState.idle;
          final before =
              (handler.collectPlaybackDiagnostics()['seekEvents']! as List)
                  .length;
          player.playbackEvents.addError(
            PlayerException(2002, 'Read timed out', 1),
          );
          try {
            await player.loadEntered!.future;
            if (completesDuringReopen) await downloader.finish();
          } finally {
            gate.complete();
          }
          for (
            var i = 0;
            i < 300 &&
                (handler.collectPlaybackDiagnostics()['seekEvents']! as List)
                        .length ==
                    before;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await settleQueue(handler);
          expect(handler.snapshot.currentSongId, 'song-1');
          expect(event(handler)['outcome'], 'reloaded');
          expect(
            player.sourceLoads,
            loads + 2,
            reason: 'row 03: one bridge and one original open',
          );
          expect(
            event(handler)['recoveryPath'],
            completesDuringReopen ? 'completedFile' : 'original',
            reason: 'row 04: attribute the selected fallback',
          );
          expect(bridging(handler), isFalse);
          expect(
            handler.mediaItem.value!.extras,
            isNot(contains('bridgeBitRate')),
          );
          expect(
            current(player).uri.scheme,
            completesDuringReopen ? 'file' : 'https',
          );
          expect(current(player).uri.queryParameters['format'], isNot('opus'));
          expect(current(player).uri.queryParameters['timeOffset'], isNull);
          expect(handler.mediaItem.value!.extras!['resolvedFormat'], 'flac');
          expect(current(player).positionOffset, Duration.zero);
          expectNativeMirrorsQueue(handler, player);
          expect(
            player.position,
            greaterThanOrEqualTo(const Duration(milliseconds: 110750)),
          );
          expect(player.position, lessThan(const Duration(seconds: 112)));
          expect(player.playing, isTrue);
          expect(notices, isEmpty);
          expect(downloader.starts, starts);
        },
      );
    }

    test(
      'row 04 rejected bridge resolver reports the original recovery path',
      () async {
        late GatedSourceResolver resolver;
        final (handler, player, _, _) = await bridgeHandler(
          wrap: (base) => resolver = GatedSourceResolver(base),
        );
        await seekTo(handler, target);
        resolver.rejectBridge = true;
        final before =
            (handler.collectPlaybackDiagnostics()['seekEvents']! as List)
                .length;
        player
          ..simulatedPosition = const Duration(seconds: 110)
          ..state = ProcessingState.idle;
        player.playbackEvents.addError(
          PlayerException(2002, 'Read timed out', 1),
        );
        for (
          var i = 0;
          i < 300 &&
              (handler.collectPlaybackDiagnostics()['seekEvents']! as List)
                      .length ==
                  before;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await settleQueue(handler);
        expect(event(handler)['recoveryPath'], 'original');
        expect(bridging(handler), isFalse);
      },
    );

    test(
      'row 17 newer Fast Seeking target wins while cut reopen resolves',
      () async {
        late GatedSourceResolver resolver;
        final (handler, player, _, _) = await bridgeHandler(
          wrap: (base) => resolver = GatedSourceResolver(base),
        );
        await seekTo(handler, target);
        resolver
          ..blockedSongId = 'song-1'
          ..entered = Completer<void>()
          ..release = Completer<void>();
        addTearDown(() {
          if (!resolver.release!.isCompleted) resolver.release!.complete();
        });
        player.finishCurrentTrack(endPosition: const Duration(seconds: 110));
        await resolver.entered!.future.timeout(const Duration(seconds: 3));
        final newer = handler.seek(const Duration(seconds: 140));
        resolver
          ..blockedSongId = null
          ..release!.complete();
        await newer;
        await settleQueue(handler);
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(player.index, 1);
        expect(bridging(handler), isTrue);
        expect(current(player).positionOffset, const Duration(seconds: 140));
        expect(player.playing, isTrue);
        expectNativeMirrorsQueue(handler, player);
      },
    );

    test('superseded bridge seek reloads only the newest target and clamps the tail', () async {
      late GatedSourceResolver resolver;
      final (handler, player, _, _) = await bridgeHandler(
        wrap: (base) => resolver = GatedSourceResolver(base),
      );
      resolver
        ..blockedSongId = 'song-1'
        ..entered = Completer<void>()
        ..release = Completer<void>();
      final loads = player.sourceLoads;
      final first = handler.seek(target);
      await resolver.entered!.future;
      final latest = handler.seek(const Duration(seconds: 180));
      resolver
        ..blockedSongId = null
        ..release!.complete();
      await Future.wait([first, latest]);
      await settleQueue(handler);
      expect(current(player).positionOffset, const Duration(seconds: 179));
      expect(player.sourceLoads, loads + 1);
    });

    for (final gate in [
      'off',
      'unsupported',
      'lossy',
      'transcode',
      'external',
    ]) {
      test('gate $gate keeps existing behavior', () async {
        final (handler, _, _, _) = await bridgeHandler(
          enabled: gate != 'off',
          capable: gate != 'unsupported',
          lossy: gate == 'lossy',
          transcode: gate == 'transcode',
          external: gate == 'external',
        );
        await seekTo(handler, target);
        expect(bridging(handler), isFalse);
      });
    }
  }, skip: !sqliteAvailable);

  group('transcode offset seek', () {
    const opus128 = StreamingQuality(
      label: 'opus',
      maxBitRate: 128,
      format: 'opus',
    );

    Future<(NavisAudioHandler, ControllableAudioPlayer, NavisDatabase)>
    offsetHandler({
      bool capable = true,
      bool? desktopRuntimeOverride,
      StreamingQuality quality = opus128,
      int count = 3,
      NavisQueueWindow queueWindow = const NavisQueueWindow(),
      SubsonicApiClient? Function()? readApiClient,
      ScrobbleService? scrobbleService,
      bool positionStreams = false,
      NavisPlaybackTimeouts timeouts = const NavisPlaybackTimeouts(),
      List<ControllableAudioPlayer>? rebuiltPlayers,
      PlaybackSourceResolver Function(PlaybackSourceResolver)? wrapResolver,
    }) async {
      final directory = await Directory.systemTemp.createTemp('navis-offset-');
      final created = await createHandler(
        directory,
        count,
        sidecarStreams: true,
        streamingQuality: quality,
        supportsTranscodeOffset: capable,
        desktopRuntimeOverride: desktopRuntimeOverride,
        readApiClient: readApiClient,
        scrobbleService: scrobbleService,
        positionStreams: positionStreams,
        timeouts: timeouts,
        rebuiltPlayers: rebuiltPlayers,
        wrapResolver: wrapResolver,
        queueWindow: queueWindow,
      );
      addTearDown(() async {
        await created.$1.disposeHandler();
        await created.$3.close();
        await directory.delete(recursive: true);
      });
      created.$2.simulateProgress = true;
      return created;
    }

    UriAudioSource current(ControllableAudioPlayer player) =>
        player.sequence[player.index!] as UriAudioSource;

    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 300 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(condition(), isTrue);
    }

    Future<void> start(NavisAudioHandler handler) async {
      await handler.replaceQueue(
        ['song-0', 'song-1', 'song-2'],
        startIndex: 1,
        expandMatchFlows: false,
      );
      await settleQueue(handler);
      await handler.play();
    }

    Future<void> seekAndSettle(NavisAudioHandler handler, Duration to) async {
      await handler.seek(to);
      await until(() => !handler.snapshot.isLoading);
    }

    Map<String, Object?> lastSeekEvent(NavisAudioHandler handler) =>
        (handler.collectPlaybackDiagnostics()['seekEvents']! as List).last
            as Map<String, Object?>;

    Future<void> failAt(
      NavisAudioHandler handler,
      ControllableAudioPlayer player,
      Duration position,
    ) async {
      final events =
          (handler.collectPlaybackDiagnostics()['seekEvents']! as List).length;
      player
        ..simulatedPosition = position
        ..state = ProcessingState.idle;
      // Duplicate native failures must not start two reloads.
      player.playbackEvents.addError(
        PlayerException(2002, 'Read timed out', 1),
      );
      player.playbackEvents.addError(
        PlayerException(2002, 'Read timed out', 1),
      );
      await until(
        () =>
            (handler.collectPlaybackDiagnostics()['seekEvents']! as List)
                .length >
            events,
      );
      await until(() => !handler.snapshot.isLoading);
    }

    group('seek preview', () {
      for (final platform in [TargetPlatform.linux, TargetPlatform.android]) {
        test('seek preview sends the native User-Agent ($platform)', () async {
          debugDefaultTargetPlatformOverride = platform;
          final (handler, _, _) = await offsetHandler(
            desktopRuntimeOverride: platform == TargetPlatform.linux,
          );
          await start(handler);
          if (platform == TargetPlatform.android) {
            handler.queue.value[1].extras!['positionOffsetMs'] = 40000;
          }
          final client = SeekPreviewHttpClient()..respond();
          addTearDown(() {
            unawaited(client.body.close());
          });
          await HttpOverrides.runZoned(
            () => handler.previewSeek(const Duration(seconds: 90)),
            createHttpClient: (_) => client,
          );
          expect(
            client.userAgent,
            platform == TargetPlatform.linux
                ? 'Navis Desktop'
                : AppConstants.userAgent,
          );
          handler.cancelSeekPreview();
          debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        });
      }

      test(
        'seek preview adopts the desired occurrence while native index lags',
        () async {
          late GatedSourceResolver resolver;
          final (handler, player, _) = await offsetHandler(
            wrapResolver: (delegate) =>
                resolver = GatedSourceResolver(delegate),
          );
          await start(handler);
          final client = SeekPreviewHttpClient()..respond();
          addTearDown(() {
            unawaited(client.body.close());
          });
          await HttpOverrides.runZoned(
            () => handler.previewSeek(const Duration(seconds: 90)),
            createHttpClient: (_) => client,
          );
          resolver
            ..blockedSongId = 'song-1'
            ..entered = Completer<void>()
            ..release = Completer<void>();
          final seek = handler.seek(const Duration(seconds: 90));
          await resolver.entered!.future;
          player.index = 0;
          resolver.release!.complete();
          await seek;
          expect(lastSeekEvent(handler)['previewAdopted'], isTrue);
        },
      );

      for (final action in ['loop', 'depart']) {
        test(
          'seek preview stream offset survives cleared entry metadata ($action)',
          () async {
            final (handler, player, _) = await offsetHandler();
            await start(handler);
            final client = SeekPreviewHttpClient()..respond();
            addTearDown(() {
              unawaited(client.body.close());
            });
            await HttpOverrides.runZoned(
              () => handler.previewSeek(const Duration(seconds: 90)),
              createHttpClient: (_) => client,
            );
            await handler.seek(const Duration(seconds: 90));
            expect(
              player.sequence[1].positionOffset,
              const Duration(seconds: 90),
            );
            handler.queue.value[1].extras!['positionOffsetMs'] = 0;
            final seekCalls = player.seekCalls;
            if (action == 'loop') {
              await handler.setRepeatMode(AudioServiceRepeatMode.one);
              player.finishCurrentTrack(
                endPosition: const Duration(seconds: 180),
              );
            } else {
              await handler.skipToNext();
            }
            if (action == 'loop') {
              await until(
                () => lastSeekEvent(handler)['requestedPositionMs'] == 0,
              );
              expect(player.seekCalls, greaterThan(seekCalls));
            } else {
              await until(
                () => player.sequence[1].positionOffset == Duration.zero,
              );
            }
          },
        );
      }

      for (final delta in [0, 2, 3, -1]) {
        test(
          'adopts only release 0..2 seconds after preview (delta=$delta)',
          () async {
            final client = SeekPreviewHttpClient()..respond();
            addTearDown(() {
              client.close(force: true);
              unawaited(client.body.close());
            });
            final (handler, player, _) = await offsetHandler();
            await start(handler);
            final before = handler.snapshot;
            await HttpOverrides.runZoned(
              () => handler.previewSeek(const Duration(seconds: 90)),
              createHttpClient: (_) => client,
            );
            await until(() => client.gets == 1);
            expect(handler.snapshot, before);
            expect(handler.snapshot.pendingSeekPosition, isNull);
            await handler.previewSeek(const Duration(seconds: 90));
            expect(client.gets, 1);
            await handler.seek(Duration(seconds: 90 + delta));
            final source = player.sequence[player.index!];
            if (delta >= 0 && delta <= 2) {
              // ignore: experimental_member_use, reason: Verify the adopted proxy source.
              expect(source, isA<StreamAudioSource>());
              // ignore: experimental_member_use, reason: Consume the adopted proxy response.
              final response = await (source as StreamAudioSource).request();
              final sub = response.stream.listen((_) {});
              await pumpEventQueue();
              expect(client.gets, 1);
              await sub.cancel();
            } else {
              expect(source, isA<UriAudioSource>());
            }
          },
        );
      }

      test('50 alternating handler previews cancel before opening, final release adopts', () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        final clients = <SeekPreviewHttpClient>[];
        for (var i = 0; i < 50; i++) {
          final client = SeekPreviewHttpClient();
          clients.add(client);
          await HttpOverrides.runZoned(
            () => handler.previewSeek(Duration(seconds: i.isEven ? 40 : 140)),
            createHttpClient: (_) {
              expect(
                clients.take(clients.length - 1).every((c) => c.closed),
                isTrue,
              );
              return client;
            },
          );
          if (i != 0) clients[i - 1].respond();
          await pumpEventQueue();
          expect(clients.where((c) => !c.closed).length, 1);
          expect(
            clients.where((c) => c.body.hasListener).length,
            lessThanOrEqualTo(1),
          );
        }
        clients.last.respond();
        clients.last.body.add([1, 2, 3]);
        await pumpEventQueue();
        await handler.seek(const Duration(seconds: 140));
        // ignore: experimental_member_use, reason: Verify final release consumes the last request.
        final source = player.sequence[player.index!] as StreamAudioSource;
        final response = await source.request();
        final result = response.stream.expand((b) => b).toList();
        await clients.last.body.close();
        expect(await result, [1, 2, 3]);
        for (final client in clients) {
          expect(client.closed, isTrue);
          expect(client.gets, 1);
          expect(client.body.hasListener, isFalse);
          if (!client.body.isClosed) unawaited(client.body.close());
        }
      });

      for (final intent in [
        'cancel',
        'pause',
        'play',
        'next',
        'stop',
        'repeat',
      ]) {
        test('$intent closes a pending preview socket', () async {
          final (handler, _, _) = await offsetHandler();
          await start(handler);
          final client = SeekPreviewHttpClient();
          await HttpOverrides.runZoned(
            () => handler.previewSeek(const Duration(seconds: 90)),
            createHttpClient: (_) => client,
          );
          switch (intent) {
            case 'cancel':
              handler.cancelSeekPreview();
            case 'pause':
              await handler.pause();
            case 'play':
              await handler.play();
            case 'next':
              await handler.skipToNext();
            case 'stop':
              await handler.stop();
            case 'repeat':
              await handler.setRepeatMode(AudioServiceRepeatMode.one);
          }
          expect(client.closed, isTrue);
          client.respond();
          await pumpEventQueue();
          expect(client.body.hasListener, isFalse);
          unawaited(client.body.close());
        });
      }

      test(
        'superseding an adopted preview closes it while native load waits',
        () async {
          final (handler, player, _) = await offsetHandler();
          await start(handler);
          final client = SeekPreviewHttpClient();
          await HttpOverrides.runZoned(
            () => handler.previewSeek(const Duration(seconds: 90)),
            createHttpClient: (_) => client,
          );
          player.loadEntered = Completer<void>();
          final loadGate = Completer<void>();
          player.loadGate = loadGate;
          final seek = handler.seek(const Duration(seconds: 90));
          await player.loadEntered!.future;
          final next = handler.skipToNext();
          expect(client.closed, isTrue);
          loadGate.complete();
          await seek;
          await next;
          client.respond();
          await pumpEventQueue();
          expect(client.body.hasListener, isFalse);
          unawaited(client.body.close());
        },
      );

      test('unused preview expires after ten seconds', () async {
        final (handler, _, _) = await offsetHandler();
        await start(handler);
        final client = SeekPreviewHttpClient();
        fakeAsync((clock) {
          HttpOverrides.runZoned(() {
            unawaited(handler.previewSeek(const Duration(seconds: 90)));
          }, createHttpClient: (_) => client);
          clock.flushMicrotasks();
          expect(client.closed, isFalse);
          clock.elapse(const Duration(seconds: 10));
          expect(client.closed, isTrue);
          client.respond();
          clock.flushMicrotasks();
        });
        unawaited(client.body.close());
      });

      test('representation mismatch discards and keeps the ordinary release offset', () async {
        late GatedSourceResolver resolver;
        final (handler, player, _) = await offsetHandler(
          wrapResolver: (delegate) => resolver = GatedSourceResolver(delegate),
        );
        await start(handler);
        final client = SeekPreviewHttpClient()..respond();
        await HttpOverrides.runZoned(
          () => handler.previewSeek(const Duration(seconds: 90)),
          createHttpClient: (_) => client,
        );
        resolver.previewRepresentation = Object();
        await handler.seek(const Duration(seconds: 92));
        expect(client.closed, isTrue);
        expect(current(player).positionOffset, const Duration(seconds: 92));
        expect(current(player).uri.queryParameters['timeOffset'], '92');
        expect(client.gets, 1);
        unawaited(client.body.close());
      });

      test(
        'discarding a preview after cache completion keeps the release target',
        () async {
          late GatedSourceResolver resolver;
          final (handler, player, database) = await offsetHandler(
            wrapResolver: (delegate) =>
                resolver = GatedSourceResolver(delegate),
          );
          await start(handler);
          final client = SeekPreviewHttpClient()..respond();
          await HttpOverrides.runZoned(
            () => handler.previewSeek(const Duration(seconds: 90)),
            createHttpClient: (_) => client,
          );
          resolver.blockedSongId = 'song-1';
          resolver.entered = Completer<void>();
          resolver.release = Completer<void>();
          addTearDown(() {
            if (!resolver.release!.isCompleted) resolver.release!.complete();
          });
          final seek = handler.seek(const Duration(seconds: 92));
          await resolver.entered!.future;
          final directory = await Directory.systemTemp.createTemp(
            'navis-preview-completed-',
          );
          addTearDown(() => directory.delete(recursive: true));
          final file = File(p.join(directory.path, 'completed.opus'));
          await file.writeAsBytes([1, 2, 3]);
          await database.cacheDao.upsertCachedTrack(
            CachedTracksTableCompanion.insert(
              songId: 'song-1',
              filePath: file.path,
              fileSize: 3,
              cacheType: CacheType.rolling,
              downloadStatus: DownloadStatus.complete,
              format: 'opus',
              lastAccessedAt: DateTime(2026),
              bitRate: const Value(128),
            ),
          );
          resolver.release!.complete();
          await seek;
          expect(client.closed, isTrue);
          expect(current(player).uri.scheme, 'file');
          expect(player.playedFrom.last, const Duration(seconds: 92));
          expect(client.gets, 1);
          unawaited(client.body.close());
        },
      );

      test('adoption retains metadata updated during the drag', () async {
        final (handler, _, database) = await offsetHandler();
        await start(handler);
        final client = SeekPreviewHttpClient()..respond();
        await HttpOverrides.runZoned(
          () => handler.previewSeek(const Duration(seconds: 90)),
          createHttpClient: (_) => client,
        );
        await database.libraryDao.upsertSongs([
          const SongsTableCompanion(
            id: Value('song-1'),
            title: Value('Updated title'),
          ),
        ]);
        await handler.seek(const Duration(seconds: 90));
        expect(handler.currentMediaItem!.title, 'Updated title');
        expect(client.gets, 1);
        client.close(force: true);
        unawaited(client.body.close());
      });

      test('completed local source opens no preview request', () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-preview-local-',
        );
        final (handler, _, database) = await createHandler(
          directory,
          1,
          supportsTranscodeOffset: true,
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        await handler.replaceQueue(
          ['song-0'],
          autoPlay: false,
          expandMatchFlows: false,
        );
        await settleQueue(handler);
        final client = SeekPreviewHttpClient();
        await HttpOverrides.runZoned(
          () => handler.previewSeek(const Duration(seconds: 90)),
          createHttpClient: (_) => client,
        );
        expect(client.gets, 0);
        expect(handler.collectPlaybackDiagnostics()['seekPreview'], isNull);
        unawaited(client.body.close());
      });

      test('native and local plans do not open preview requests', () async {
        final (handler, _, _) = await offsetHandler(capable: false);
        await start(handler);
        await handler.previewSeek(const Duration(seconds: 90));
        expect(handler.collectPlaybackDiagnostics()['seekPreview'], isNull);
      });
    });

    group('premature transcode EOF', () {
      Future<(NavisAudioHandler, ControllableAudioPlayer)> setup({
        bool last = false,
        bool capable = true,
        bool original = false,
        int? duration = 300,
        ScrobbleService? scrobbleService,
        bool positionStreams = false,
        void Function(NavisDatabase)? onDatabase,
        PlaybackSourceResolver Function(PlaybackSourceResolver)? wrap,
      }) async {
        final (handler, player, database) = await offsetHandler(
          capable: capable,
          quality: original
              ? const StreamingQuality(label: 'original')
              : opus128,
          wrapResolver: wrap,
          scrobbleService: scrobbleService,
          positionStreams: scrobbleService != null || positionStreams,
        );
        onDatabase?.call(database);
        await database.libraryDao.upsertSongs([
          for (final id in ['song-0', 'song-1', 'song-2'])
            SongsTableCompanion.insert(
              id: id,
              title: id,
              duration: Value(duration),
            ),
        ]);
        await handler.replaceQueue(
          ['song-0', 'song-1', if (!last) 'song-2'],
          startIndex: 1,
          expandMatchFlows: false,
        );
        await settleQueue(handler);
        await handler.play();
        // Native duration can shrink to the truncated stream's length.
        player.simulatedDuration = const Duration(seconds: 47);
        return (handler, player);
      }

      Future<void> drain(NavisAudioHandler handler) async {
        await pumpEventQueue(times: 100);
        await settleQueue(handler);
      }

      group('position stream across a cut reload (#210)', () {
        Future<
          (
            NavisAudioHandler,
            ControllableAudioPlayer,
            GatedSourceResolver,
            List<Duration>,
          )
        >
        gatedCut() async {
          late GatedSourceResolver resolver;
          final (handler, player) = await setup(
            positionStreams: true,
            wrap: (base) => resolver = GatedSourceResolver(base),
          );
          final seen = <Duration>[];
          final sub = handler.positionStream.listen(seen.add);
          addTearDown(sub.cancel);
          addTearDown(() {
            if (resolver.release?.isCompleted == false) {
              resolver.release!.complete();
            }
          });
          // The sampler runs on real timers; let it publish the pre-cut value.
          player.simulatedPosition = const Duration(seconds: 47);
          await Future<void>.delayed(const Duration(milliseconds: 350));
          resolver
            ..blockedSongId = 'song-1'
            ..entered = Completer<void>()
            ..release = Completer<void>();
          seen.clear();
          // just_audio auto-advances: the player now reads the next item at 0.
          player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
          await until(() => resolver.entered!.isCompleted);
          await Future<void>.delayed(const Duration(milliseconds: 450));
          return (handler, player, resolver, seen);
        }

        test('holds the cut position instead of the next item 0', () async {
          final (handler, player, resolver, seen) = await gatedCut();
          expect(seen.where((p) => p < const Duration(seconds: 47)), isEmpty);
          expect(seen, isNotEmpty);
          expect(seen.last, greaterThanOrEqualTo(const Duration(seconds: 47)));
          resolver.release!.complete();
          await drain(handler);
          expect(current(player).positionOffset, const Duration(seconds: 47));
        });

        test('a skip during the cut releases the hold', () async {
          final (handler, player, resolver, seen) = await gatedCut();
          unawaited(handler.skipToNext());
          resolver.release!.complete();
          await drain(handler);
          seen.clear();
          player.simulatedPosition = const Duration(seconds: 3);
          await Future<void>.delayed(const Duration(milliseconds: 450));
          expect(seen, isNotEmpty);
          expect(seen.last, lessThan(const Duration(seconds: 47)));
        });

        test('raw positions resume once the departure clears', () async {
          final (handler, player, resolver, seen) = await gatedCut();
          resolver.release!.complete();
          await drain(handler);
          await until(
            () =>
                (handler.collectPlaybackDiagnostics()['seek']!
                    as Map)['pending'] !=
                true,
          );
          seen.clear();
          player.simulatedPosition = const Duration(seconds: 50);
          await Future<void>.delayed(const Duration(milliseconds: 450));
          expect(seen, isNotEmpty);
          expect(seen.last, greaterThanOrEqualTo(const Duration(seconds: 50)));
        });
        test('the stream follows the player once the reload is ready, '
            'while the seek is still pending', () async {
          final (handler, player, resolver, seen) = await gatedCut();
          resolver.release!.complete();
          await drain(handler);
          expect(
            (handler.collectPlaybackDiagnostics()['seek']! as Map)['pending'],
            isTrue,
          );
          seen.clear();
          player.simulatedPosition = const Duration(seconds: 50);
          await Future<void>.delayed(const Duration(milliseconds: 450));
          expect(seen, isNotEmpty);
          expect(seen.last, greaterThanOrEqualTo(const Duration(seconds: 50)));
        });
      });

      test('row 15 queued append preserves the classified cut', () async {
        final (handler, player, database) = await offsetHandler();
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Song 1',
            duration: const Value(300),
          ),
        ]);
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..afterAppendGate = gate
          ..afterAppendEntered = entered;
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final loading = handler.replaceQueue(
          ['song-0', 'song-1', 'song-2'],
          startIndex: 1,
          expandMatchFlows: false,
        );
        await entered.future.timeout(const Duration(seconds: 3));
        final editing = handler.addToQueue(['song-0'], expandMatchFlows: false);
        await pumpEventQueue(times: 20);
        player.finishCurrentTrack(
          endPosition: const Duration(milliseconds: 47750),
        );
        await pumpEventQueue(times: 20);
        gate.complete();
        await Future.wait([loading, editing]);
        await drain(handler);
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(handler.snapshot.currentIndex, 1);
        expect(current(player).positionOffset, const Duration(seconds: 47));
        expect(player.playing, isTrue);
        expect(handler.snapshot.queueSongIds, [
          'song-0',
          'song-1',
          'song-2',
          'song-0',
        ]);
        expectNativeMirrorsQueue(handler, player);
      });

      for (final delayedPause in [false, true]) {
        for (final intent in ['none', 'Play', 'Pause']) {
          test('row 15 removed cut releases its pause with $intent '
              '(delayed acknowledgement: $delayedPause)', () async {
            final (handler, player, database) = await offsetHandler();
            await database.libraryDao.upsertSongs([
              SongsTableCompanion.insert(
                id: 'song-1',
                title: 'Song 1',
                duration: const Value(300),
              ),
            ]);
            final fill = Completer<void>();
            final entered = Completer<void>();
            final pause = Completer<void>();
            final paused = Completer<void>();
            addTearDown(() {
              if (!fill.isCompleted) fill.complete();
              if (!pause.isCompleted) pause.complete();
            });
            player
              ..afterAppendGate = fill
              ..afterAppendEntered = entered;
            final loading = handler.replaceQueue(
              ['song-0', 'song-1', 'song-2'],
              startIndex: 1,
              expandMatchFlows: false,
            );
            await entered.future.timeout(const Duration(seconds: 3));
            final editing = handler.removeAt(1);
            await pumpEventQueue(times: 20);
            final loads = player.sourceLoads;
            if (delayedPause) {
              player
                ..pauseGate = pause
                ..pauseEntered = paused;
            }
            player.finishCurrentTrack(
              endPosition: const Duration(milliseconds: 47750),
            );
            await pumpEventQueue(times: 20);
            if (delayedPause) await paused.future;
            if (intent == 'Play') await handler.play();
            if (intent == 'Pause') await handler.pause();
            fill.complete();
            await Future.wait([loading, editing]);
            await drain(handler);
            if (delayedPause) {
              expect(
                player.playing,
                isFalse,
                reason: 'wait for the owned pause acknowledgement',
              );
              pause.complete();
              await drain(handler);
            }
            expect(handler.snapshot.queueSongIds, ['song-0', 'song-2']);
            expect(handler.snapshot.currentSongId, 'song-2');
            expect(handler.snapshot.currentIndex, 1);
            expect(
              player.playing,
              intent != 'Pause',
              reason: 'release recovery pause with the latest intent',
            );
            expect(
              player.sourceLoads,
              loads,
              reason: 'never reopen the removed occurrence',
            );
            expectNativeMirrorsQueue(handler, player);
          });
        }
      }

      for (final late in ['Pause', 'Play']) {
        test('row 15 removed cut honours a late $late during the pause '
            'acknowledgement', () async {
          final (handler, player, database) = await offsetHandler();
          await database.libraryDao.upsertSongs([
            SongsTableCompanion.insert(
              id: 'song-1',
              title: 'Song 1',
              duration: const Value(300),
            ),
          ]);
          final fill = Completer<void>();
          final entered = Completer<void>();
          final pause = Completer<void>();
          final paused = Completer<void>();
          addTearDown(() {
            if (!fill.isCompleted) fill.complete();
            if (!pause.isCompleted) pause.complete();
          });
          player
            ..afterAppendGate = fill
            ..afterAppendEntered = entered;
          final loading = handler.replaceQueue(
            ['song-0', 'song-1', 'song-2'],
            startIndex: 1,
            expandMatchFlows: false,
          );
          await entered.future.timeout(const Duration(seconds: 3));
          final editing = handler.removeAt(1);
          await pumpEventQueue(times: 20);
          player
            ..pauseGate = pause
            ..pauseEntered = paused;
          player.finishCurrentTrack(
            endPosition: const Duration(milliseconds: 47750),
          );
          await pumpEventQueue(times: 20);
          await paused.future;
          if (late == 'Play') await handler.pause();
          fill.complete();
          await Future.wait([loading, editing]);
          await pumpEventQueue(times: 50);
          // The intent arrives while cleanup still awaits the pause ack.
          if (late == 'Pause') {
            await handler.pause();
          } else {
            await handler.play();
          }
          pause.complete();
          await drain(handler);

          expect(player.playing, late == 'Play');
        });
      }

      for (final intent in ['none', 'Play', 'Pause', 'skip']) {
        test('row 15 cut during native tail fill honors $intent', () async {
          final (handler, player, database) = await offsetHandler();
          await database.libraryDao.upsertSongs([
            SongsTableCompanion.insert(
              id: 'song-1',
              title: 'Song 1',
              duration: const Value(300),
            ),
          ]);
          final gate = Completer<void>();
          final entered = Completer<void>();
          player
            ..afterAppendGate = gate
            ..afterAppendEntered = entered;
          addTearDown(() {
            if (!gate.isCompleted) gate.complete();
          });
          final loading = handler.replaceQueue(
            ['song-0', 'song-1', 'song-2'],
            startIndex: 1,
            expandMatchFlows: false,
          );
          await entered.future.timeout(const Duration(seconds: 3));
          expect(handler.debugQueueLaneIdle, isFalse);
          final published = <String?>[];
          final subscription = handler.mediaItem.listen(
            (item) => published.add(item?.id),
          );
          addTearDown(subscription.cancel);
          final loads = player.sourceLoads;
          player.finishCurrentTrack(
            endPosition: const Duration(milliseconds: 47750),
          );
          await pumpEventQueue(times: 20);
          expect(
            player.audibleSongId,
            isNull,
            reason: 'the successor must stay silent while the lane finishes',
          );
          if (intent == 'Play') await handler.play();
          if (intent == 'Pause') await handler.pause();
          final newer = intent == 'skip'
              ? handler.skipToNext()
              : Future<void>.value();
          gate.complete();
          await loading;
          await newer;
          await drain(handler);
          expect(
            handler.snapshot.currentSongId,
            intent == 'skip' ? 'song-2' : 'song-1',
            reason: 'row 15: retain the departed occurrence through fill',
          );
          if (intent == 'skip') {
            expect(player.sourceLoads, lessThanOrEqualTo(loads + 1));
          } else {
            expect(player.sourceLoads, loads + 1);
          }
          expect(
            current(player).positionOffset,
            intent == 'skip' ? Duration.zero : const Duration(seconds: 47),
          );
          expect(player.playing, intent != 'Pause');
          if (intent != 'skip') {
            expect(
              published,
              isNot(contains('song-2')),
              reason: 'the successor must never own metadata',
            );
          }
          if (intent != 'skip') {
            expect(
              (player.position - const Duration(milliseconds: 47750)).abs(),
              lessThan(const Duration(seconds: 1)),
            );
          }
          expect(handler.snapshot.queueSongIds, ['song-0', 'song-1', 'song-2']);
          expectNativeMirrorsQueue(handler, player);
        });
      }

      for (final work in ['release', 'trim', 'advance during release']) {
        test(
          'row 15 cut during deferred tail $work retains the source occurrence',
          () async {
            final (handler, player, database) = await offsetHandler(
              count: 12,
              queueWindow: const NavisQueueWindow(
                deferThreshold: 4,
                ahead: 1,
                lowWater: 1,
                page: 2,
                nearJump: 3,
                behind: 1,
                trimSlack: 0,
              ),
            );
            final ids = List.generate(12, (i) => 'song-$i');
            await database.libraryDao.upsertSongs([
              for (final id in ids)
                SongsTableCompanion.insert(
                  id: id,
                  title: id,
                  duration: const Value(300),
                ),
            ]);
            await handler.replaceQueue(
              ids,
              startIndex: work == 'trim' ? 10 : 0,
              expandMatchFlows: false,
            );
            await drain(handler);
            final release = Completer<void>();
            final entered = Completer<void>();
            addTearDown(() {
              if (!release.isCompleted) release.complete();
            });
            if (work == 'trim') {
              player
                ..removeGate = release
                ..removeEntered = entered;
            } else {
              player
                ..afterAppendGate = release
                ..afterAppendEntered = entered;
            }
            player.moveTo(work == 'trim' ? 2 : 1);
            await entered.future.timeout(const Duration(seconds: 3));
            expect(handler.debugQueueLaneIdle, isFalse);
            final loads = player.sourceLoads;
            if (work == 'advance during release') {
              player.finishCurrentTrack(
                endPosition: const Duration(seconds: 300),
              );
              await pumpEventQueue(times: 20);
            }
            player.finishCurrentTrack(
              endPosition: const Duration(milliseconds: 47750),
            );
            await pumpEventQueue(times: 20);
            release.complete();
            await drain(handler);
            expect(
              player.sourceLoads,
              loads + 1,
              reason: 'row 15: cut while $work owns the lane must reopen once',
            );
            expect(
              handler.snapshot.currentSongId,
              work == 'trim'
                  ? 'song-11'
                  : work == 'advance during release'
                  ? 'song-2'
                  : 'song-1',
            );
            expect(current(player).positionOffset, const Duration(seconds: 47));
            expect(
              (player.position - const Duration(milliseconds: 47750)).abs(),
              lessThan(const Duration(seconds: 1)),
            );
            expect(handler.snapshot.queueSongIds, ids);
            expect(player.playing, isTrue);
            expectNativeMirrorsQueue(handler, player);
          },
        );
      }

      for (final duplicate in [false, true]) {
        test(
          'cut after artwork refresh recovers the occurrence (duplicate: $duplicate)',
          () async {
            final directory = await Directory.systemTemp.createTemp(
              'navis-cut-art-',
            );
            const channel = MethodChannel('plugins.flutter.io/path_provider');
            final messenger = TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger;
            messenger.setMockMethodCallHandler(
              channel,
              (_) async => directory.path,
            );
            PlaybackArtCache.resetKeyForTesting();
            addTearDown(() async {
              messenger.setMockMethodCallHandler(channel, null);
              PlaybackArtCache.resetKeyForTesting();
              await directory.delete(recursive: true);
            });
            await PlaybackArtCache.initializeKey(supportDirectory: directory);
            await File(
              p.join(
                directory.path,
                'navis_art_v2_${PlaybackArtCache.fileKey('cut-cover')}.jpg',
              ),
            ).writeAsBytes([0xFF, 0xD8, 0xFF, 1]);
            late NavisDatabase database;
            final (handler, player) = await setup(
              onDatabase: (value) => database = value,
            );
            await database.libraryDao.upsertSongs([
              SongsTableCompanion.insert(
                id: 'song-1',
                title: 'Song 1',
                duration: const Value(300),
                coverArt: const Value('cut-cover'),
              ),
            ]);
            await handler.replaceQueue(
              [if (duplicate) 'song-1' else 'song-0', 'song-1', 'song-2'],
              startIndex: 1,
              expandMatchFlows: false,
            );
            await drain(handler);
            await handler.play();
            await until(
              () => handler.currentMediaItem?.extras?['artCacheFile'] != null,
            );
            expect(
              identical(handler.currentMediaItem, handler.queue.value[1]),
              isFalse,
            );
            final loads = player.sourceLoads;

            player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
            await until(() => player.sourceLoads > loads);
            await drain(handler);

            expect(player.index, 1);
            expect(handler.snapshot.currentSongId, 'song-1');
            expect(current(player).positionOffset, const Duration(seconds: 47));
          },
        );
      }

      test(
        'remove current with a discontinuity after lane release is not a cut',
        () async {
          final (handler, player) = await setup();
          player.simulatedPosition = const Duration(seconds: 47);
          final before = player.playbackEvent;
          final loads = player.sourceLoads;
          await handler.removeAt(1);
          await drain(handler);
          expect(handler.debugQueueLaneIdle, isTrue);

          player.discontinuityEvents.add(
            PositionDiscontinuity(
              PositionDiscontinuityReason.autoAdvance,
              before,
              player.playbackEvent,
            ),
          );
          await drain(handler);

          expect(player.sourceLoads, loads);
          expect(handler.snapshot.currentSongId, 'song-2');
          expect(current(player).positionOffset, Duration.zero);
        },
      );

      for (final last in [false, true]) {
        for (final intent in ['none', 'Play', 'Pause']) {
          test(
            'native cut reopen failure preserves the queue after $intent (last: $last)',
            () async {
              late GatedSourceResolver resolver;
              final (handler, player) = await setup(
                wrap: (base) => resolver = GatedSourceResolver(base),
              );
              final failedIndex = last ? 2 : 1;
              final failedSong = 'song-$failedIndex';
              if (last) {
                await handler.playFromIndex(2);
                await drain(handler);
              }
              resolver
                ..blockedSongId = failedSong
                ..entered = Completer<void>()
                ..release = Completer<void>();
              addTearDown(() {
                if (!resolver.release!.isCompleted) {
                  resolver.release!.complete();
                }
              });
              player.loadErrorAfterApply = StateError('HTTP 500 after apply');
              player.finishCurrentTrack(
                endPosition: const Duration(seconds: 47),
              );
              await until(() => resolver.entered!.isCompleted);
              if (intent == 'Play') await handler.play();
              if (intent == 'Pause') await handler.pause();
              // Reject only the reopen; the next song remains available.
              resolver.blockedSongId = null;
              resolver.release!.complete();
              await drain(handler);

              expect(lastSeekEvent(handler)['outcome'], 'skipped');
              expect(handler.snapshot.queueSongIds, [
                'song-0',
                'song-1',
                'song-2',
              ]);
              expect(handler.snapshot.currentIndex, 2);
              expect(handler.snapshot.currentSongId, 'song-2');
              expect(player.playing, !last && intent != 'Pause');
              expectNativeMirrorsQueue(handler, player);
              if (last) {
                expect(player.position, const Duration(seconds: 47));
                final loads = player.sourceLoads;
                await handler.play();
                await until(() => player.sourceLoads > loads);
                await drain(handler);
                expect(handler.snapshot.currentSongId, failedSong);
                expect(player.audibleSongId, failedSong);
                expect(current(player).uri.queryParameters['id'], failedSong);
                expect(
                  current(player).positionOffset,
                  const Duration(seconds: 47),
                );
                expect(handler.snapshot.currentIndex, failedIndex);
                expectNativeMirrorsQueue(handler, player);
              }
            },
          );
        }
      }

      for (final last in [false, true]) {
        for (final pauseFirst in [false, true]) {
          test(
            'Play during cut resolution only records intent (last: $last, pause first: $pauseFirst)',
            () async {
              late GatedSourceResolver resolver;
              final (handler, player) = await setup(
                last: last,
                wrap: (base) => resolver = GatedSourceResolver(base),
              );
              resolver
                ..blockedSongId = 'song-1'
                ..entered = Completer<void>()
                ..release = Completer<void>();
              addTearDown(() {
                if (!resolver.release!.isCompleted) {
                  resolver.release!.complete();
                }
              });
              final loads = player.sourceLoads;
              player.finishCurrentTrack(
                endPosition: const Duration(seconds: 47),
              );
              await until(() => resolver.entered!.isCompleted);
              if (pauseFirst) {
                await handler.pause();
              }
              final plays = player.playedFrom.length;

              await handler.play();
              expect(player.playedFrom.length, plays);
              expect(player.audibleSongId, isNull);
              expect(player.index, last ? 1 : 2);
              expect(handler.snapshot.currentSongId, 'song-1');
              resolver
                ..blockedSongId = null
                ..release!.complete();
              await until(() => player.sourceLoads > loads);
              await drain(handler);
              await until(() => handler.snapshot.pendingSeekPosition == null);

              expect(player.index, 1);
              expect(handler.snapshot.currentSongId, 'song-1');
              expect(
                current(player).positionOffset,
                const Duration(seconds: 47),
              );
              expect(player.playing, isTrue);
            },
          );
        }
      }

      for (final last in [false, true]) {
        for (final play in [true, false]) {
          test(
            'failed cut resolution keeps failover after ${play ? 'Play' : 'Pause'} (last: $last)',
            () async {
              late GatedSourceResolver resolver;
              final (handler, player) = await setup(
                last: last,
                wrap: (base) => resolver = GatedSourceResolver(base),
              );
              resolver
                ..blockedSongId = 'song-1'
                ..entered = Completer<void>()
                ..release = Completer<void>()
                ..failure = StateError('source unavailable');
              addTearDown(() {
                if (!resolver.release!.isCompleted) {
                  resolver.release!.complete();
                }
              });
              player.finishCurrentTrack(
                endPosition: const Duration(seconds: 47),
              );
              await until(() => resolver.entered!.isCompleted);

              if (play) {
                await handler.play();
              } else {
                await handler.pause();
              }
              resolver.release!.complete();
              await drain(handler);

              expect(lastSeekEvent(handler)['outcome'], 'skipped');
              expect(
                handler.snapshot.currentSongId,
                last ? 'song-1' : 'song-2',
              );
              expect(player.playing, play && !last);
              if (last && play) {
                resolver.blockedSongId = null;
                await handler.play();
                await drain(handler);
                expect(player.playing, isTrue);
                expect(handler.snapshot.currentSongId, 'song-1');
              }
            },
          );

          test(
            'unbuilt cut recovery keeps failover after ${play ? 'Play' : 'Pause'} (last: $last)',
            () async {
              final (handler, player) = await setup(last: last);
              final entered = Completer<void>();
              final release = Completer<void>();
              player
                ..pauseGate = release
                ..pauseEntered = entered;
              addTearDown(() {
                if (!release.isCompleted) release.complete();
              });
              player.finishCurrentTrack(
                endPosition: const Duration(seconds: 47),
              );
              await until(() => entered.isCompleted);
              if (play) {
                await handler.play();
              } else {
                await handler.pause();
              }
              // Native lost the departed source before the rebuild could find it.
              player.queuedSources.clear();
              release.complete();
              // Final-song failover stops quietly; only Play rebuilds lost sources.
              await pumpEventQueue(times: 100);
              if (!last) await settleQueue(handler);

              expect(lastSeekEvent(handler)['outcome'], 'skipped');
              expect(
                handler.snapshot.currentSongId,
                last ? 'song-1' : 'song-2',
              );
              expect(player.playing, play && !last);
              if (last && play) {
                await handler.play();
                await drain(handler);
                expect(player.playing, isTrue);
                expect(handler.snapshot.currentSongId, 'song-1');
              }
            },
          );
        }
      }

      test('audio-focus regain defers Play during cut resolution', () async {
        late GatedSourceResolver resolver;
        final (handler, player) = await setup(
          wrap: (base) => resolver = GatedSourceResolver(base),
        );
        final session = TestAudioSession();
        handler.debugWireAudioSession(session);
        addTearDown(session.close);
        session.interruptions.add(
          AudioInterruptionEvent(true, AudioInterruptionType.pause),
        );
        await pumpEventQueue();
        resolver
          ..blockedSongId = 'song-1'
          ..entered = Completer<void>()
          ..release = Completer<void>();
        addTearDown(() {
          if (!resolver.release!.isCompleted) resolver.release!.complete();
        });
        final loads = player.sourceLoads;
        player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
        await until(() => resolver.entered!.isCompleted);
        final plays = player.playedFrom.length;

        session.interruptions.add(
          AudioInterruptionEvent(false, AudioInterruptionType.pause),
        );
        await pumpEventQueue();
        expect(player.playedFrom.length, plays);
        expect(player.audibleSongId, isNull);
        resolver
          ..blockedSongId = null
          ..release!.complete();
        await until(() => player.sourceLoads > loads);
        await drain(handler);
        await until(() => handler.snapshot.pendingSeekPosition == null);
        expect(player.audibleSongId, 'song-1');
      });

      test(
        'Play resumes a reopened source while settlement is pending',
        () async {
          final (handler, player) = await setup();
          final loads = player.sourceLoads;
          player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
          await until(() => player.sourceLoads > loads && player.playing);
          expect(handler.snapshot.pendingSeekPosition, isNotNull);
          await handler.pause();
          final plays = player.playedFrom.length;

          await handler.play();
          expect(player.playedFrom.length, plays + 1);
          expect(player.audibleSongId, 'song-1');
          await drain(handler);
          await until(() => handler.snapshot.pendingSeekPosition == null);
          expect(current(player).positionOffset, const Duration(seconds: 47));
        },
      );

      for (final edit in [
        'remove current',
        'remove earlier',
        'insert',
        'move',
      ]) {
        test('queue edit $edit is not a transcode cut', () async {
          final (handler, player) = await setup();
          final loads = player.sourceLoads;
          player
            ..simulatedPosition = const Duration(seconds: 47)
            ..emitQueueEditDiscontinuity = true;

          switch (edit) {
            case 'remove current':
              await handler.removeAt(1);
            case 'remove earlier':
              await handler.removeAt(0);
            case 'insert':
              await handler.insertQueueItem(
                0,
                const MediaItem(id: 'song-0', title: 'Song 0'),
              );
            case 'move':
              await handler.reorderQueue(0, 3);
          }
          await drain(handler);

          expect(player.sourceLoads, loads);
          expect(
            handler.snapshot.currentSongId,
            edit == 'remove current' ? 'song-2' : 'song-1',
          );
          expect(current(player).positionOffset, Duration.zero);
          expect(player.position.inSeconds, edit == 'remove current' ? 0 : 47);
        });
      }

      for (final discontinuityFirst in [false, true]) {
        for (final last in [false, true]) {
          test(
            'cut preserves scrobbles and history (last: $last, discontinuity first: $discontinuityFirst)',
            () async {
              final scrobbles = NoopScrobbleService();
              late NavisDatabase database;
              final (handler, player) = await setup(
                last: last,
                scrobbleService: scrobbles,
                onDatabase: (value) => database = value,
              );
              await drain(handler);
              expect(scrobbles.nowPlaying, ['song-1']);
              final session = scrobbles.nowPlayingSessions.single;
              final completed = <PlaybackSnapshot>[];
              final subscription = handler.snapshotStream.listen((snapshot) {
                if (snapshot.processingState ==
                    AudioProcessingState.completed) {
                  completed.add(snapshot);
                }
              });
              addTearDown(subscription.cancel);
              final loads = player.sourceLoads;

              player.finishCurrentTrack(
                endPosition: const Duration(seconds: 47),
                discontinuityFirst: discontinuityFirst,
              );
              await until(() => player.sourceLoads > loads);
              await drain(handler);
              await until(() => handler.snapshot.pendingSeekPosition == null);

              expect(handler.snapshot.currentSongId, 'song-1');
              expect(
                current(player).positionOffset,
                const Duration(seconds: 47),
              );
              expect(scrobbles.nowPlaying, ['song-1']);
              expect(scrobbles.nowPlayingSessions, [session]);
              expect(scrobbles.submissions, isEmpty);
              expect(completed, isEmpty);
              final history = await database.historyDao
                  .watchPlayHistory()
                  .first;
              expect(history.map((entry) => entry.songId), ['song-1']);

              player.simulatedPosition = const Duration(seconds: 180);
              player.emitPlayerEvent();
              await drain(handler);
              expect(scrobbles.submissions, ['song-1']);
              expect(scrobbles.submissionSessions, [session]);
            },
          );
        }
      }

      test('cut pauses the successor before source resolution', () async {
        late GatedSourceResolver resolver;
        final (handler, player) = await setup(
          wrap: (base) => resolver = GatedSourceResolver(base),
        );
        resolver
          ..blockedSongId = 'song-1'
          ..entered = Completer<void>()
          ..release = Completer<void>();
        addTearDown(() {
          if (!resolver.release!.isCompleted) resolver.release!.complete();
        });
        final loads = player.sourceLoads;
        player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
        await until(() => resolver.entered!.isCompleted);
        expect(player.audibleSongId, isNull);
        expect(handler.snapshot.currentSongId, 'song-1');
        resolver
          ..blockedSongId = null
          ..release!.complete();
        await until(() => player.sourceLoads > loads);
        await drain(handler);
        expect(player.playing, isTrue);
      });

      test(
        'a newer Pause preserves recovery during native acknowledgement',
        () async {
          final (handler, player) = await setup();
          final release = Completer<void>();
          final entered = Completer<void>();
          player
            ..pauseGate = release
            ..pauseEntered = entered;
          addTearDown(() {
            if (!release.isCompleted) release.complete();
          });
          final loads = player.sourceLoads;

          player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
          await until(() => entered.isCompleted);
          await handler.pause();
          release.complete();
          await until(() => player.sourceLoads > loads);
          await drain(handler);
          await until(() => handler.snapshot.pendingSeekPosition == null);

          expect(handler.snapshot.currentSongId, 'song-1');
          expect(current(player).positionOffset, const Duration(seconds: 47));
          expect(player.playing, isFalse);
        },
      );

      for (final last in [false, true]) {
        test('reopens at 47 of 300 seconds (last: $last)', () async {
          final (handler, player) = await setup(last: last);
          final loads = player.sourceLoads;
          final failures = <PlaybackLoadFailure>[];
          final notices = handler.loadFailureStream.listen(failures.add);
          addTearDown(notices.cancel);

          player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
          await until(() => player.sourceLoads > loads);
          await drain(handler);

          expect(handler.snapshot.currentSongId, 'song-1');
          expect(player.index, 1);
          expect(current(player).uri.queryParameters['timeOffset'], '47');
          expect(current(player).positionOffset, const Duration(seconds: 47));
          expect(player.sourceLoads, loads + 1);
          expect(player.playing, isTrue);
          expect(handler.playbackState.value.playing, isTrue);
          expect(failures, isEmpty);
        });

        test('a second early end does not loop (last: $last)', () async {
          final (handler, player) = await setup(last: last);
          final loads = player.sourceLoads;
          player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
          await until(() => player.sourceLoads > loads);
          await drain(handler);
          final retriedLoads = player.sourceLoads;

          player.finishCurrentTrack(endPosition: const Duration(seconds: 50));
          await drain(handler);

          expect(player.sourceLoads, retriedLoads);
          expect(handler.snapshot.currentSongId, last ? 'song-1' : 'song-2');
          expect(
            player.processingState,
            last ? ProcessingState.completed : ProcessingState.ready,
          );
        });
      }

      for (final gate in [
        'near end',
        'unknown duration',
        'unsupported',
        'original',
      ]) {
        test('$gate keeps normal advance', () async {
          final (handler, player) = await setup(
            capable: gate != 'unsupported',
            original: gate == 'original',
            duration: gate == 'unknown duration' ? null : 300,
          );
          final loads = player.sourceLoads;
          player.finishCurrentTrack(
            endPosition: Duration(seconds: gate == 'near end' ? 290 : 47),
          );
          await drain(handler);

          expect(player.sourceLoads, loads);
          expect(handler.snapshot.currentSongId, 'song-2');
        });
      }

      // A cut stream drains in mpv after the sidecar's full re-download has
      // already finished, so a completed file must not block the recovery.
      test('a completed cache file still recovers the cut', () async {
        late NavisDatabase database;
        final (handler, player) = await setup(
          onDatabase: (db) => database = db,
        );
        final path =
            handler.currentMediaItem!.extras!['sidecarCacheFilePath']!
                as String;
        await File(path).writeAsBytes(List<int>.filled(64, 1));
        // The sidecar registers the finished download as a rolling entry.
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: 'song-1',
            filePath: path,
            fileSize: 64,
            format: 'opus',
            cacheType: CacheType.rolling,
            downloadStatus: DownloadStatus.complete,
            lastAccessedAt: DateTime.now(),
          ),
        );
        final loads = player.sourceLoads;

        player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
        await until(() => player.sourceLoads > loads);
        await drain(handler);

        expect(handler.snapshot.currentSongId, 'song-1');
        expect(player.sourceLoads, loads + 1);
        expect(current(player).uri, Uri.file(path));
        expect(player.position.inSeconds, 47);
        expect(player.playing, isTrue);
      });

      test(
        'completion uses the backend position instead of its clock',
        () async {
          final (handler, player) = await setup(last: true);
          final loads = player.sourceLoads;
          player
            ..nativePositionFrozen = true
            ..simulatedPosition = const Duration(seconds: 47)
            ..positionUpdatedAt = DateTime.now().subtract(
              const Duration(seconds: 240),
            )
            ..state = ProcessingState.completed;
          expect(player.position, greaterThan(const Duration(seconds: 280)));
          player.playbackEvents.add(player.playbackEvent);
          await until(() => player.sourceLoads > loads);
          await drain(handler);

          expect(current(player).positionOffset, const Duration(seconds: 47));
        },
      );

      test(
        'an offset continuation also recovers at its last song position',
        () async {
          final (handler, player) = await setup();
          await seekAndSettle(handler, const Duration(seconds: 30));
          final loads = player.sourceLoads;

          player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
          await until(() => player.sourceLoads > loads);
          await drain(handler);

          expect(current(player).positionOffset, const Duration(seconds: 47));
          expect(handler.snapshot.currentSongId, 'song-1');
        },
      );

      test('healthy play does not excuse a truncated transcode', () async {
        final (handler, player, database) = await offsetHandler(
          positionStreams: true,
          timeouts: const NavisPlaybackTimeouts(
            healthyPlayback: Duration(milliseconds: 600),
          ),
        );
        await database.libraryDao.upsertSongs([
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Song 1',
            duration: const Value(300),
          ),
        ]);
        await start(handler);
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        final loads = player.sourceLoads;
        player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
        await until(() => player.sourceLoads > loads);
        await drain(handler);

        expect(current(player).positionOffset, const Duration(seconds: 47));
      });

      test('a user skip does not reopen the departed song', () async {
        final (handler, player) = await setup();
        player.simulatedPosition = const Duration(seconds: 47);
        final loads = player.sourceLoads;

        await handler.skipToNext();
        await drain(handler);

        expect(handler.snapshot.currentSongId, 'song-2');
        expect(player.sourceLoads, loads);
      });

      // P7: the departed song's end during a user navigation is superseded by
      // it, even though the navigate lane is busy and the load flag is set.
      for (final command in ['next', 'previous', 'select']) {
        {
          test('a $command skip held in the lane ignores the departed '
              "song's end", () async {
            final (handler, player) = await setup();
            player.simulatedPosition = const Duration(seconds: 2);
            final loads = player.sourceLoads;
            final target = command == 'next' ? 'song-2' : 'song-0';
            player
              ..seekGate = Completer<void>()
              ..seekEntered = Completer<void>();
            final gate = player.seekGate!;
            addTearDown(() {
              if (!gate.isCompleted) gate.complete();
            });
            final navigation = switch (command) {
              'next' => handler.skipToNext(),
              'previous' => handler.skipToPrevious(),
              _ => handler.playFromIndex(0),
            };
            await player.seekEntered!.future.timeout(
              const Duration(seconds: 3),
            );

            // Any event the departed player emits after the skip began
            // re-captures its occurrence; its end then looks like a cut.
            player.playbackEvents.add(player.playbackEvent);
            await pumpEventQueue(times: 20);
            player.finishCurrentTrack(endPosition: const Duration(seconds: 2));
            await pumpEventQueue(times: 50);
            gate.complete();
            await navigation;
            await drain(handler);

            expect(
              player.sourceLoads,
              loads,
              reason: 'the departed song must not be reloaded',
            );
            expect(handler.snapshot.currentSongId, target);
            expect(current(player).positionOffset, Duration.zero);
          });
        }
      }

      test('a real cut on the skip target right after the skip still '
          'retries', () async {
        final (handler, player) = await setup();
        await handler.skipToNext();
        await drain(handler);
        expect(handler.snapshot.currentSongId, 'song-2');
        final loads = player.sourceLoads;

        player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
        await until(() => player.sourceLoads > loads);
        await drain(handler);

        expect(handler.snapshot.currentSongId, 'song-2');
        expect(current(player).positionOffset, const Duration(seconds: 47));
      });

      test('a skip cancelled before it ran does not disable cut recovery '
          'during later queue work', () async {
        final (handler, player) = await setup();
        final append = Completer<void>();
        final appendEntered = Completer<void>();
        player
          ..appendGate = append
          ..appendEntered = appendEntered;
        addTearDown(() {
          if (!append.isCompleted) append.complete();
        });
        // The replacement below retires this edit.
        final editing = handler
            .addToQueue(['song-0'], expandMatchFlows: false)
            .then<void>((_) {}, onError: (Object _) {});
        await appendEntered.future.timeout(const Duration(seconds: 3));
        // Queued behind the held edit, then cancelled before its callback ran.
        await handler.skipToNext();
        final replacing = handler.replaceQueue(
          ['song-0', 'song-1', 'song-2'],
          startIndex: 1,
          expandMatchFlows: false,
        );
        append.complete();
        await Future.wait([editing, replacing]);
        await drain(handler);
        await handler.play();
        player.simulatedDuration = const Duration(seconds: 47);

        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..afterAppendGate = gate
          ..afterAppendEntered = entered;
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final loading = handler.replaceQueue(
          ['song-0', 'song-1', 'song-2'],
          startIndex: 1,
          expandMatchFlows: false,
        );
        await entered.future.timeout(const Duration(seconds: 3));
        final more = handler.addToQueue(['song-0'], expandMatchFlows: false);
        await pumpEventQueue(times: 20);
        player.finishCurrentTrack(
          endPosition: const Duration(milliseconds: 47750),
        );
        await pumpEventQueue(times: 20);
        gate.complete();
        await Future.wait([loading, more]);
        await drain(handler);

        expect(handler.snapshot.currentSongId, 'song-1');
        expect(current(player).positionOffset, const Duration(seconds: 47));
      });

      test(
        'a lagging departed end during later queue work is ignored',
        () async {
          final (handler, player) = await setup();
          player.simulatedPosition = const Duration(seconds: 2);
          player
            ..seekGate = Completer<void>()
            ..seekEntered = Completer<void>();
          final seek = player.seekGate!;
          addTearDown(() {
            if (!seek.isCompleted) seek.complete();
          });
          final navigation = handler.skipToNext();
          await player.seekEntered!.future.timeout(const Duration(seconds: 3));
          player.playbackEvents.add(player.playbackEvent);
          await pumpEventQueue(times: 20);
          final stale = player.playbackEvent;
          seek.complete();
          await navigation;
          await drain(handler);
          final loads = player.sourceLoads;

          final append = Completer<void>();
          final appendEntered = Completer<void>();
          player
            ..appendGate = append
            ..appendEntered = appendEntered;
          addTearDown(() {
            if (!append.isCompleted) append.complete();
          });
          final editing = handler.addToQueue([
            'song-0',
          ], expandMatchFlows: false);
          await appendEntered.future.timeout(const Duration(seconds: 3));
          player.discontinuityEvents.add(
            PositionDiscontinuity(
              PositionDiscontinuityReason.autoAdvance,
              stale,
              player.playbackEvent,
            ),
          );
          await pumpEventQueue(times: 50);
          append.complete();
          await editing;
          await drain(handler);

          expect(player.sourceLoads, loads);
          expect(handler.snapshot.currentSongId, 'song-2');
        },
      );

      test('a stale departed end after the skip finished is ignored', () async {
        final (handler, player) = await setup();
        player.simulatedPosition = const Duration(seconds: 2);
        final stale = player.playbackEvent;
        await handler.skipToNext();
        await drain(handler);
        final loads = player.sourceLoads;

        player.discontinuityEvents.add(
          PositionDiscontinuity(
            PositionDiscontinuityReason.autoAdvance,
            stale,
            player.playbackEvent,
          ),
        );
        await drain(handler);

        expect(player.sourceLoads, loads);
        expect(handler.snapshot.currentSongId, 'song-2');
      });

      test(
        'Repeat One resumes the cut rather than restarting at zero',
        () async {
          final (handler, player) = await setup();
          await handler.setRepeatMode(AudioServiceRepeatMode.one);
          final loads = player.sourceLoads;

          player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
          await until(() => player.sourceLoads > loads);
          await drain(handler);

          expect(handler.snapshot.currentSongId, 'song-1');
          expect(current(player).positionOffset, const Duration(seconds: 47));
          expect(player.loopMode, LoopMode.one);
          expect(player.playing, isTrue);
        },
      );

      test('recovers the departed duplicate occurrence', () async {
        final (handler, player) = await setup();
        await handler.replaceQueue(
          ['song-1', 'song-1', 'song-2'],
          startIndex: 1,
          expandMatchFlows: false,
        );
        await settleQueue(handler);
        await handler.play();
        final loads = player.sourceLoads;

        player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
        await until(() => player.sourceLoads > loads);
        await drain(handler);

        expect(player.index, 1);
        expect(handler.snapshot.queueSongIds, ['song-1', 'song-1', 'song-2']);
        expect(current(player).positionOffset, const Duration(seconds: 47));
      });

      for (final command in ['pause', 'seek', 'skip']) {
        test('a newer $command wins during reopen resolution', () async {
          late GatedSourceResolver resolver;
          final (handler, player) = await setup(
            wrap: (base) => resolver = GatedSourceResolver(base),
          );
          resolver
            ..blockedSongId = 'song-1'
            ..entered = Completer<void>()
            ..release = Completer<void>();
          addTearDown(() {
            if (!resolver.release!.isCompleted) resolver.release!.complete();
          });
          player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
          await until(() => resolver.entered!.isCompleted);
          final newer = switch (command) {
            'pause' => handler.pause(),
            'seek' => handler.seek(const Duration(seconds: 130)),
            _ => handler.skipToNext(),
          };
          if (command == 'pause') await newer;
          resolver
            ..blockedSongId = null
            ..release!.complete();
          await newer;
          await drain(handler);

          expect(
            handler.snapshot.currentSongId,
            command == 'skip' ? 'song-2' : 'song-1',
          );
          if (command != 'skip') {
            expect(
              current(player).positionOffset,
              Duration(seconds: command == 'seek' ? 130 : 47),
            );
          }
          expect(player.playing, command != 'pause');
        });
      }

      test('row 16 newer seek owns a failed cut reopen', () async {
        late GatedSourceResolver resolver;
        final (handler, player) = await setup(
          wrap: (base) => resolver = GatedSourceResolver(base),
        );
        resolver
          ..blockedSongId = 'song-1'
          ..entered = Completer<void>()
          ..release = Completer<void>()
          ..failure = StateError('reopen unavailable');
        addTearDown(() {
          if (!resolver.release!.isCompleted) resolver.release!.complete();
        });
        player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
        await resolver.entered!.future.timeout(const Duration(seconds: 3));
        final newer = handler.seek(const Duration(seconds: 130));
        resolver
          ..blockedSongId = null
          ..release!.complete();
        await newer;
        await drain(handler);
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(current(player).positionOffset, const Duration(seconds: 130));
        expect(player.playing, isTrue);
        expectNativeMirrorsQueue(handler, player);
      });

      for (final edit in ['append', 'insert']) {
        test(
          'row 18 $edit during completed cut resolution keeps the queue and Play intent',
          () async {
            late GatedSourceResolver resolver;
            final (handler, player) = await setup(
              last: true,
              wrap: (base) => resolver = GatedSourceResolver(base),
            );
            resolver
              ..blockedSongId = 'song-1'
              ..entered = Completer<void>()
              ..release = Completer<void>();
            addTearDown(() {
              if (!resolver.release!.isCompleted) resolver.release!.complete();
            });
            player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
            await resolver.entered!.future.timeout(const Duration(seconds: 3));
            final editing = edit == 'append'
                ? handler.addToQueue(['song-2'], expandMatchFlows: false)
                : handler.playNext(['song-2'], expandMatchFlows: false);
            await handler.pause();
            final plays = player.playedFrom.length;
            await handler.play();
            expect(
              player.playedFrom.length,
              plays,
              reason: 'source is not ready',
            );
            expect(player.audibleSongId, isNull);
            resolver
              ..blockedSongId = null
              ..release!.complete();
            await editing;
            await drain(handler);
            expect(handler.snapshot.currentSongId, 'song-1');
            expect(handler.snapshot.currentIndex, 1);
            expect(handler.snapshot.queueSongIds, [
              'song-0',
              'song-1',
              'song-2',
            ]);
            expect(current(player).positionOffset, const Duration(seconds: 47));
            expect(player.playing, isTrue);
            expectNativeMirrorsQueue(handler, player);
          },
        );
      }

      test('a failed reopen uses bounded silent failover', () async {
        late GatedSourceResolver resolver;
        final (handler, player) = await setup(
          wrap: (base) => resolver = GatedSourceResolver(base),
        );
        resolver
          ..blockedSongId = 'song-1'
          ..entered = Completer<void>()
          ..failure = StateError('source unavailable');
        final loads = player.sourceLoads;

        player.finishCurrentTrack(endPosition: const Duration(seconds: 47));
        await until(() => resolver.entered!.isCompleted);
        await drain(handler);

        expect(handler.snapshot.currentSongId, 'song-2');
        expect(player.playing, isTrue);
        expect(player.sourceLoads, lessThanOrEqualTo(loads + 1));
      });
    });

    for (final playing in [true, false]) {
      test('stall recovery resumes a transcode at song time 70 (playing: '
          '$playing)', () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        if (!playing) await handler.pause();
        final loads = player.sourceLoads;
        final failures = <PlaybackLoadFailure>[];
        final notices = handler.loadFailureStream.listen(failures.add);
        addTearDown(notices.cancel);

        await failAt(handler, player, const Duration(seconds: 70));

        expect(current(player).uri.queryParameters['timeOffset'], '70');
        expect(current(player).positionOffset, const Duration(seconds: 70));
        expect(player.position.inSeconds, 70);
        expect(player.sourceLoads, loads + 1);
        expect(player.sourceIds, ['song-0', 'song-1', 'song-2']);
        expect(player.playing, playing);
        expect(lastSeekEvent(handler)['path'], 'remote_retry');
        expect(failures, isEmpty);
      });
    }

    test('stall recovery on an offset stream uses song time 130', () async {
      final (handler, player, _) = await offsetHandler();
      await start(handler);
      await seekAndSettle(handler, const Duration(seconds: 110));
      final loads = player.sourceLoads;

      await failAt(handler, player, const Duration(seconds: 130));

      expect(current(player).uri.queryParameters['timeOffset'], '130');
      expect(player.position.inSeconds, 130);
      expect(player.sourceLoads, loads + 1);
      expect(player.playing, isTrue);
    });

    test('stall recovery prefers a completed file at song time 70', () async {
      final (handler, player, _) = await offsetHandler();
      await start(handler);
      final sidecar =
          handler.queue.value[1].extras!['sidecarCacheFilePath'] as String;
      await File(sidecar).writeAsBytes(List<int>.filled(64, 1));
      final loads = player.sourceLoads;

      await failAt(handler, player, const Duration(seconds: 70));

      expect(current(player).uri, Uri.file(sidecar));
      expect(current(player).positionOffset, Duration.zero);
      expect(player.position.inSeconds, 70);
      expect(player.sourceLoads, loads + 1);
      expect(player.playing, isTrue);
    });

    test('row 01 newer seek waits for ordinary recovery final Stop', () async {
      final (handler, player, database) = await offsetHandler(
        capable: false,
        timeouts: const NavisPlaybackTimeouts(
          load: Duration(milliseconds: 300),
          reset: Duration(milliseconds: 300),
          seekProgress: Duration(milliseconds: 1200),
          desktopSeekSettle: Duration(milliseconds: 600),
        ),
      );
      await handler.replaceQueue(
        ['song-0', 'song-1'],
        startIndex: 1,
        expandMatchFlows: false,
      );
      await settleQueue(handler);
      await (database.delete(
        database.songsTable,
      )..where((row) => row.id.equals('song-0'))).go();
      final release = Completer<void>();
      final entered = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      player
        ..stopGate = release
        ..stopEntered = entered
        ..stopGateFrom = player.stopCalls + 1
        ..simulatedPosition = const Duration(seconds: 70)
        ..state = ProcessingState.idle;
      final recovery = handler.debugRecoverCurrentSong();
      await entered.future.timeout(const Duration(seconds: 3));
      await database.libraryDao.upsertSongs([
        SongsTableCompanion.insert(id: 'song-0', title: 'Song 0'),
      ]);
      final seeking = handler.seek(const Duration(seconds: 130));
      await pumpEventQueue(times: 30);
      release.complete();
      await Future.wait([recovery, seeking]);
      await settleQueue(handler);
      expect(
        (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
        'completed',
      );
      expect(handler.snapshot.currentSongId, 'song-1');
      expect(player.position.inSeconds, greaterThanOrEqualTo(130));
      expect(player.playing, isTrue);
      expectNativeMirrorsQueue(handler, player);
    });

    test(
      'row 05 unbuilt original recovery honors Pause during failover',
      () async {
        final (handler, player, database) = await offsetHandler(
          capable: false,
          count: 4,
        );
        await start(handler);
        final release = Completer<void>();
        final entered = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        player
          ..appendGate = release
          ..appendEntered = entered;
        final editing = handler.addToQueue(['song-3'], expandMatchFlows: false);
        await entered.future;
        player
          ..simulatedPosition = const Duration(seconds: 70)
          ..state = ProcessingState.idle;
        final recovery = handler.debugRecoverCurrentSong();
        await pumpEventQueue(times: 30);
        await (database.delete(
          database.songsTable,
        )..where((row) => row.id.equals('song-0'))).go();
        await handler.pause();
        release.complete();
        await Future.wait([editing, recovery]);
        await settleQueue(handler);
        expect(handler.snapshot.currentSongId, 'song-2');
        expect(player.playing, isFalse);
        expectNativeMirrorsQueue(handler, player);
      },
    );

    for (final superseded in [false, true]) {
      test(
        'row 05 unbuilt original recovery ${superseded ? 'yields to selection' : 'fails over once'}',
        () async {
          final (handler, player, database) = await offsetHandler(
            capable: false,
            count: 4,
          );
          await start(handler);
          final release = Completer<void>();
          final entered = Completer<void>();
          player
            ..appendGate = release
            ..appendEntered = entered;
          final editing = handler.addToQueue([
            'song-3',
          ], expandMatchFlows: false);
          await entered.future;
          player
            ..simulatedPosition = const Duration(seconds: 70)
            ..state = ProcessingState.idle;
          final recovery = handler.debugRecoverCurrentSong();
          await pumpEventQueue(times: 30);
          if (!superseded) {
            await (database.delete(
              database.songsTable,
            )..where((row) => row.id.equals('song-0'))).go();
          }
          final selection = superseded
              ? handler.playFromIndex(2)
              : Future<void>.value();
          release.complete();
          await Future.wait([editing, recovery, selection]);
          await settleQueue(handler);
          expect(
            handler.snapshot.currentSongId,
            'song-2',
            reason: 'row 05: only the owned failure may fail over',
          );
          expect(player.playing, isTrue);
          expectNativeMirrorsQueue(handler, player);
        },
      );
    }

    test(
      'row 05 removal before an original rebuild does not fail over again',
      () async {
        final (handler, player, _) = await offsetHandler(
          capable: false,
          count: 4,
        );
        await start(handler);
        final release = Completer<void>();
        final entered = Completer<void>();
        player
          ..appendGate = release
          ..appendEntered = entered;
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        final editing = handler.addToQueue(['song-3'], expandMatchFlows: false);
        await entered.future;
        final removing = handler.removeAt(1);
        player.state = ProcessingState.idle;
        final recovery = handler.debugRecoverCurrentSong();
        await pumpEventQueue(times: 30);
        release.complete();
        await Future.wait([editing, removing, recovery]);
        await settleQueue(handler);
        expect(handler.snapshot.queueSongIds, ['song-0', 'song-2', 'song-3']);
        expect(handler.snapshot.currentSongId, 'song-2');
        expect(player.playing, isTrue);
        expectNativeMirrorsQueue(handler, player);
      },
    );

    test(
      'row 02 failed seek suppression uses the configured healthy interval',
      () async {
        final (handler, player, _) = await offsetHandler(
          capable: false,
          desktopRuntimeOverride: false,
          timeouts: const NavisPlaybackTimeouts(
            seekProgress: Duration(milliseconds: 400),
            seekBufferingRecovery: Duration(milliseconds: 150),
            healthyPlayback: Duration(milliseconds: 600),
          ),
        );
        await start(handler);
        player
          ..ignoreSeeks = true
          ..nativePositionFrozen = true
          ..simulateProgress = false;
        await handler.seek(const Duration(seconds: 90));
        expect(
          (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
          'failed',
        );
        final failedAt = player.position;
        final loads = player.sourceLoads;
        player
          ..state = ProcessingState.ready
          ..simulatedPosition = failedAt + const Duration(milliseconds: 500);
        player.playbackEvents.add(player.playbackEvent);
        await pumpEventQueue(times: 20);
        player.state = ProcessingState.idle;
        await handler.debugRecoverCurrentSong();
        expect(
          player.sourceLoads,
          loads,
          reason: 'no renewal below healthyPlayback',
        );
        player
          ..state = ProcessingState.ready
          ..simulatedPosition = failedAt + const Duration(milliseconds: 700);
        player.playbackEvents.add(player.playbackEvent);
        await pumpEventQueue(times: 20);
        player
          ..state = ProcessingState.idle
          ..ignoreSeeks = false
          ..nativePositionFrozen = false
          ..simulateProgress = true;
        await handler.debugRecoverCurrentSong();
        await settleQueue(handler);
        expect(
          player.sourceLoads,
          loads + 1,
          reason: 'row 02: renew at healthyPlayback, before five seconds',
        );
      },
    );

    test(
      'stall recovery without the capability keeps the original path',
      () async {
        final (handler, player, _) = await offsetHandler(capable: false);
        await start(handler);
        final loads = player.sourceLoads;

        await failAt(handler, player, const Duration(seconds: 70));

        expect(
          current(player).uri.queryParameters,
          isNot(contains('timeOffset')),
        );
        expect(current(player).positionOffset, Duration.zero);
        expect(player.position.inSeconds, 70);
        expect(player.sourceLoads, loads + 1);
        expect(player.playing, isTrue);
      },
    );

    test(
      'stall recovery in the first second keeps the original path',
      () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        final loads = player.sourceLoads;

        await failAt(handler, player, const Duration(milliseconds: 400));

        expect(
          current(player).uri.queryParameters,
          isNot(contains('timeOffset')),
        );
        expect(current(player).positionOffset, Duration.zero);
        expect(player.position.inMilliseconds, greaterThanOrEqualTo(400));
        expect(player.sourceLoads, loads + 1);
        expect(player.playing, isTrue);
      },
    );

    test(
      'stall recovery keeps Play while a queue edit holds the reload',
      () async {
        final (handler, player, _) = await offsetHandler(count: 4);
        await start(handler);
        await handler.pause();
        final loads = player.sourceLoads;
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..appendGate = gate
          ..appendEntered = entered;
        final adding = handler.addToQueue(['song-3'], expandMatchFlows: false);
        await entered.future;
        player
          ..simulatedPosition = const Duration(seconds: 70)
          ..state = ProcessingState.idle;
        player.playbackEvents.addError(
          PlayerException(2002, 'Read timed out', 1),
        );
        await pumpEventQueue(times: 20);

        await handler.play();
        gate.complete();
        await adding;
        await until(
          () => !handler.snapshot.isLoading && player.sourceIds.length == 4,
        );
        await until(() => player.playing);

        expect(current(player).positionOffset, const Duration(seconds: 70));
        expect(player.position.inSeconds, 70);
        expect(player.sourceLoads, loads + 1);
        expect(player.sourceIds, ['song-0', 'song-1', 'song-2', 'song-3']);
      },
    );

    test('stall recovery at the song end advances without replaying', () async {
      final (handler, player, _) = await offsetHandler();
      await start(handler);

      await failAt(handler, player, const Duration(minutes: 3));

      expect(handler.snapshot.currentSongId, 'song-2');
      expect(player.playing, isTrue);
      expect(lastSeekEvent(handler)['outcome'], 'skipped');
    });

    for (final command in ['pause', 'seek']) {
      test(
        'stall recovery yields to a newer $command during resolution',
        () async {
          late GatedSourceResolver resolver;
          final (handler, player, _) = await offsetHandler(
            wrapResolver: (base) => resolver = GatedSourceResolver(base),
          );
          await start(handler);
          final loads = player.sourceLoads;
          resolver
            ..blockedSongId = 'song-1'
            ..entered = Completer<void>()
            ..release = Completer<void>();
          player
            ..simulatedPosition = const Duration(seconds: 70)
            ..state = ProcessingState.buffering;
          final recovery = handler.debugRecoverCurrentSong();
          await resolver.entered!.future;
          final newer = command == 'pause'
              ? handler.pause()
              : handler.seek(const Duration(seconds: 130));
          if (command == 'pause') await newer;
          resolver
            ..blockedSongId = null
            ..release!.complete();
          await Future.wait([recovery, newer]);
          await until(() => !handler.snapshot.isLoading);

          final expected = command == 'pause' ? 70 : 130;
          expect(current(player).positionOffset, Duration(seconds: expected));
          expect(player.position.inSeconds, expected);
          expect(player.sourceLoads, loads + 1);
          expect(player.sourceIds, ['song-0', 'song-1', 'song-2']);
          expect(player.playing, command != 'pause');
        },
      );
    }

    test(
      'stall recovery retries once then advances after another failure',
      () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        await failAt(handler, player, const Duration(seconds: 70));

        await failAt(handler, player, const Duration(seconds: 80));

        expect(handler.snapshot.currentSongId, 'song-2');
        expect(player.playing, isTrue);
        expect(lastSeekEvent(handler)['outcome'], 'skipped');
      },
    );

    group('the retry bound renews with sustained play', () {
      const quick = NavisPlaybackTimeouts(
        healthyPlayback: Duration(milliseconds: 600),
      );

      Future<(NavisAudioHandler, ControllableAudioPlayer)> retried({
        bool frozen = false,
      }) async {
        final (handler, player, _) = await offsetHandler(
          positionStreams: true,
          timeouts: quick,
        );
        await start(handler);
        await failAt(handler, player, const Duration(seconds: 70));
        expect(lastSeekEvent(handler)['outcome'], 'reloaded');
        player.nativePositionFrozen = frozen;
        return (handler, player);
      }

      test('a cut after healthy play is retried again', () async {
        final (handler, player) = await retried();
        await Future<void>.delayed(const Duration(milliseconds: 1200));

        await failAt(handler, player, const Duration(seconds: 80));

        expect(handler.snapshot.currentSongId, 'song-1');
        expect(lastSeekEvent(handler)['outcome'], 'reloaded');
      });

      test('a second cut before healthy play skips the song', () async {
        final (handler, player) = await retried();

        await failAt(handler, player, const Duration(seconds: 80));

        expect(handler.snapshot.currentSongId, 'song-2');
        expect(lastSeekEvent(handler)['outcome'], 'skipped');
      });

      test('renewal is per song: the next song keeps its own bound', () async {
        final (handler, player) = await retried();
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        // A natural advance keeps the transport generation and its bounds.
        player.finishCurrentTrack();
        await until(() => handler.snapshot.currentSongId == 'song-2');

        await failAt(handler, player, const Duration(seconds: 30));
        expect(lastSeekEvent(handler)['outcome'], 'reloaded');
        await failAt(handler, player, const Duration(seconds: 40));

        expect(lastSeekEvent(handler)['outcome'], 'skipped');
      });

      Future<(NavisAudioHandler, ControllableAudioPlayer)>
      repeatingOne() async {
        final (handler, player, _) = await offsetHandler(
          positionStreams: true,
          timeouts: quick,
        );
        await start(handler);
        await handler.setRepeatMode(AudioServiceRepeatMode.one);
        return (handler, player);
      }

      test('a Repeat One loop starts a new play-time occurrence', () async {
        final (handler, player) = await repeatingOne();
        await Future<void>.delayed(const Duration(milliseconds: 900));
        expect(
          handler.debugPlayedSinceFailover,
          greaterThan(quick.healthyPlayback),
        );

        player.finishCurrentTrack();
        await pumpEventQueue();

        expect(
          handler.debugPlayedSinceFailover,
          lessThan(quick.healthyPlayback),
        );
      });

      test(
        'play time before a Repeat One loop does not renew the retry',
        () async {
          final (handler, player) = await repeatingOne();
          await failAt(handler, player, const Duration(milliseconds: 500));
          expect(lastSeekEvent(handler)['outcome'], 'reloaded');
          // Neither half of the play reaches healthyPlayback on its own.
          await Future<void>.delayed(const Duration(milliseconds: 400));
          player.finishCurrentTrack();
          await Future<void>.delayed(const Duration(milliseconds: 400));

          await failAt(handler, player, const Duration(milliseconds: 900));

          expect(lastSeekEvent(handler)['outcome'], 'skipped');
        },
      );

      test('Repeat One retries again after healthy play', () async {
        final (handler, player, _) = await offsetHandler(
          positionStreams: true,
          timeouts: quick,
        );
        await start(handler);
        await handler.setRepeatMode(AudioServiceRepeatMode.one);
        await failAt(handler, player, const Duration(seconds: 70));
        expect(lastSeekEvent(handler)['outcome'], 'reloaded');
        await Future<void>.delayed(const Duration(milliseconds: 1200));

        await failAt(handler, player, const Duration(seconds: 80));

        expect(handler.snapshot.currentSongId, 'song-1');
        expect(lastSeekEvent(handler)['outcome'], 'reloaded');
      });

      test('a frozen native position never renews the bound', () async {
        final (handler, player) = await retried(frozen: true);
        await Future<void>.delayed(const Duration(milliseconds: 1200));

        await failAt(handler, player, const Duration(seconds: 80));

        expect(handler.snapshot.currentSongId, 'song-2');
        expect(lastSeekEvent(handler)['outcome'], 'skipped');
      });
    });

    test(
      'a far seek reopens the transcode at the whole-second offset',
      () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        final loadsBefore = player.sourceLoads;

        await seekAndSettle(
          handler,
          const Duration(seconds: 95, milliseconds: 700),
        );

        final source = current(player);
        expect(source.uri.queryParameters['timeOffset'], '95');
        expect(
          source.uri.queryParameters,
          isNot(contains('estimateContentLength')),
        );
        expect(source.positionOffset, const Duration(seconds: 95));
        expect(player.sourceLoads, loadsBefore + 1);
        expect(
          (player.position - const Duration(seconds: 95)).abs(),
          lessThan(const Duration(seconds: 1)),
        );
        expect(player.sourceIds, ['song-0', 'song-1', 'song-2']);
        expect(player.index, 1);
        final seek = lastSeekEvent(handler);
        expect(seek['path'], 'transcodeOffset');
        expect(seek['outcome'], 'completed');
        final diagnostics = handler.collectPlaybackDiagnostics();
        expect(diagnostics['positionOffsetMs'], 95000);
        expect(handler.queue.value[1].extras!['positionOffsetMs'], 95000);
      },
    );

    test(
      'going back to a song that played as an offset starts it at 0',
      () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        await seekAndSettle(handler, const Duration(seconds: 90));
        await handler.skipToNext();
        await until(() => handler.snapshot.currentSongId == 'song-2');
        player.simulatedPosition = const Duration(seconds: 1);
        await handler.skipToPrevious();
        await until(
          () =>
              handler.snapshot.currentSongId == 'song-1' &&
              !handler.snapshot.isLoading &&
              current(player).positionOffset == Duration.zero,
        );
        expect(handler.collectPlaybackDiagnostics()['positionOffsetMs'], 0);
        expect(handler.queue.value[1].extras!['positionOffsetMs'], 0);
        expect(
          current(player).uri.queryParameters,
          isNot(contains('timeOffset')),
        );
      },
    );

    group('departed offset entry repair', () {
      bool clean(NavisAudioHandler handler, ControllableAudioPlayer player) =>
          handler.queue.value[1].extras!['positionOffsetMs'] == 0 &&
          (player.sequence[1] as UriAudioSource).positionOffset ==
              Duration.zero &&
          !handler.snapshot.isLoading;

      Future<(NavisAudioHandler, ControllableAudioPlayer)> leftOffset({
        PlaybackSourceResolver Function(PlaybackSourceResolver)? wrap,
      }) async {
        final (handler, player, _) = await offsetHandler(wrapResolver: wrap);
        await start(handler);
        await seekAndSettle(handler, const Duration(seconds: 90));
        await handler.skipToNext();
        await until(() => handler.snapshot.currentSongId == 'song-2');
        return (handler, player);
      }

      test('leaving an offset song repairs its entry in place', () async {
        final (handler, player) = await leftOffset();
        final loads = player.sourceLoads;
        final seeks = player.seekCalls;

        await until(() => clean(handler, player));
        await settleQueue(handler);

        expect(player.sourceLoads, loads);
        expect(player.seekCalls, seeks);
        expect(player.index, 2);
        expect(player.sourceIds, ['song-0', 'song-1', 'song-2']);
        expect(handler.snapshot.queueSongIds, ['song-0', 'song-1', 'song-2']);
        expect(handler.snapshot.currentSongId, 'song-2');
      });

      test('Previous right after leaving never starts the offset', () async {
        final (handler, player) = await leftOffset();
        final loads = player.sourceLoads;
        player.simulatedPosition = const Duration(seconds: 1);

        await handler.skipToPrevious();
        await until(
          () =>
              handler.snapshot.currentSongId == 'song-1' &&
              !handler.snapshot.isLoading,
        );
        await settleQueue(handler);

        expect(current(player).positionOffset, Duration.zero);
        expect(player.sourceLoads, loads, reason: 'no reopen safety net');
        expect(handler.collectPlaybackDiagnostics()['positionOffsetMs'], 0);
      });

      test(
        'the repeat-all wrap lands on a repaired entry without a reopen',
        () async {
          final (handler, player, _) = await offsetHandler(count: 2);
          await handler.replaceQueue([
            'song-0',
            'song-1',
          ], expandMatchFlows: false);
          await settleQueue(handler);
          await handler.play();
          await handler.setRepeatMode(AudioServiceRepeatMode.all);
          await seekAndSettle(handler, const Duration(seconds: 90));
          player.finishCurrentTrack();
          await until(
            () =>
                handler.snapshot.currentSongId == 'song-1' &&
                handler.queue.value[0].extras!['positionOffsetMs'] == 0 &&
                (player.sequence[0] as UriAudioSource).positionOffset ==
                    Duration.zero,
          );
          await settleQueue(handler);
          final loads = player.sourceLoads;

          player.finishCurrentTrack();
          await until(() => handler.snapshot.currentSongId == 'song-0');
          await settleQueue(handler);

          expect(player.sourceLoads, loads);
          expect(handler.collectPlaybackDiagnostics()['positionOffsetMs'], 0);
        },
      );

      test('a repair never removes the song that became current', () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        await seekAndSettle(handler, const Duration(seconds: 90));
        final stale = player.sequence[1];
        // The player advances onto the stale entry while its twin is being
        // inserted, before the old source would be removed.
        player.afterInsertSources = () {
          player.afterInsertSources = null;
          player
            ..index = 1
            ..simulatedPosition = Duration.zero
            ..indexEvents.add(1);
        };
        await handler.skipToNext();
        await until(() => player.index == 1);
        await settleQueue(handler);
        await pumpEventQueue(times: 50);

        expect(player.sequence[1], same(stale), reason: 'current kept');
        expect(player.sourceIds, ['song-0', 'song-1', 'song-2']);
        expect(handler.snapshot.queueSongIds, ['song-0', 'song-1', 'song-2']);
      });

      test('a skip chain enqueues one repair', () async {
        late GatedSourceResolver resolver;
        final (handler, player, _) = await offsetHandler(
          count: 4,
          wrapResolver: (base) => resolver = GatedSourceResolver(base),
        );
        await handler.replaceQueue([
          'song-0',
          'song-1',
          'song-2',
          'song-3',
        ], expandMatchFlows: false);
        await settleQueue(handler);
        await handler.play();
        await seekAndSettle(handler, const Duration(seconds: 90));
        resolver
          ..blockedSongId = 'song-0'
          ..entered = Completer<void>()
          ..release = Completer<void>();
        addTearDown(() {
          if (!resolver.release!.isCompleted) resolver.release!.complete();
        });
        final edits = handler.debugQueueEditCount;

        player.finishCurrentTrack();
        await resolver.entered!.future;
        player.finishCurrentTrack();
        await pumpEventQueue(times: 50);

        expect(handler.debugQueueEditCount, edits + 1);
        resolver.release!.complete();
        await until(
          () =>
              handler.queue.value[0].extras!['positionOffsetMs'] == 0 &&
              !handler.snapshot.isLoading,
        );
      });

      test('a repair removal that times out keeps the playing song', () async {
        final rebuilt = <ControllableAudioPlayer>[];
        final (handler, player, _) = await offsetHandler(
          count: 4,
          rebuiltPlayers: rebuilt,
          timeouts: const NavisPlaybackTimeouts(
            load: Duration(milliseconds: 300),
            reset: Duration(milliseconds: 300),
          ),
        );
        await handler.replaceQueue(
          ['song-0', 'song-1', 'song-2', 'song-3'],
          startIndex: 1,
          expandMatchFlows: false,
        );
        await settleQueue(handler);
        await handler.play();
        await seekAndSettle(handler, const Duration(seconds: 90));
        player.hang.add('removeAudioSourceAt');

        await handler.skipToNext();
        await until(() => rebuilt.isNotEmpty);
        await settleQueue(handler);

        expect(rebuilt.first.sourceIds, [
          'song-0',
          'song-1',
          'song-2',
          'song-3',
        ]);
        expect(rebuilt.first.index, 2);
        expect(handler.snapshot.currentSongId, 'song-2');
      });

      for (final edit in ['remove', 'move']) {
        test(
          'a repair racing a queue $edit leaves the queue consistent',
          () async {
            late GatedSourceResolver resolver;
            final (handler, player) = await leftOffset(
              wrap: (base) => resolver = GatedSourceResolver(base),
            );
            // The next song is repaired only after its entry was already
            // left: hold that repair, then edit the queue under it.
            await until(() => clean(handler, player));
            await seekAndSettle(handler, const Duration(seconds: 100));
            resolver
              ..blockedSongId = 'song-2'
              ..entered = Completer<void>()
              ..release = Completer<void>();
            player.simulatedPosition = const Duration(seconds: 1);
            await handler.skipToPrevious();
            await until(() => handler.snapshot.currentSongId == 'song-1');
            await resolver.entered!.future;
            final editing = edit == 'remove'
                ? handler.removeAt(2)
                : handler.reorderQueue(2, 0);
            resolver
              ..blockedSongId = null
              ..release!.complete();
            await editing;
            await settleQueue(handler);

            final ids = handler.snapshot.queueSongIds;
            expect(
              ids.toSet(),
              edit == 'remove'
                  ? {'song-0', 'song-1'}
                  : {'song-0', 'song-1', 'song-2'},
            );
            expect(player.sourceIds, ids);
            expect(handler.snapshot.currentSongId, 'song-1');
            for (var i = 0; i < player.sequence.length; i++) {
              expect(
                (player.sequence[i] as UriAudioSource).positionOffset,
                player.index == i
                    ? greaterThanOrEqualTo(Duration.zero)
                    : Duration.zero,
              );
            }
          },
        );
      }
    });

    test('a seek on an offset source reopens it at the new offset', () async {
      final (handler, player, _) = await offsetHandler();
      await start(handler);
      await seekAndSettle(handler, const Duration(seconds: 90));
      await seekAndSettle(handler, const Duration(seconds: 40));
      expect(current(player).positionOffset, const Duration(seconds: 40));
      await seekAndSettle(handler, const Duration(seconds: 150));
      expect(current(player).positionOffset, const Duration(seconds: 150));
      expect(lastSeekEvent(handler)['path'], 'transcodeOffset');
    });

    test('the offset never passes the last second of the song', () async {
      final (handler, player, database) = await offsetHandler();
      await database.libraryDao.upsertSongs([
        SongsTableCompanion.insert(
          id: 'song-1',
          title: 'Song 1',
          duration: const Value(180),
        ),
      ]);
      await start(handler);
      await seekAndSettle(handler, const Duration(seconds: 180));
      expect(current(player).positionOffset, const Duration(seconds: 179));
    });

    test(
      'edge 1: a seek during an in-flight offset reload wins with one reload',
      () async {
        late GatedSourceResolver resolver;
        final (handler, player, _) = await offsetHandler(
          wrapResolver: (base) => resolver = GatedSourceResolver(base),
        );
        await start(handler);
        final loadsBefore = player.sourceLoads;
        resolver
          ..blockedSongId = 'song-1'
          ..entered = Completer<void>()
          ..release = Completer<void>();

        final first = handler.seek(const Duration(seconds: 60));
        await resolver.entered!.future;
        final latest = handler.seek(const Duration(seconds: 120));
        resolver
          ..blockedSongId = null
          ..release!.complete();
        await Future.wait([first, latest]);
        await until(() => !handler.snapshot.isLoading);

        expect(current(player).positionOffset, const Duration(seconds: 120));
        expect(player.sourceLoads, loadsBefore + 1);
        expect(player.sourceIds, ['song-0', 'song-1', 'song-2']);
      },
    );

    test(
      'edge 2: the natural end of an offset stream advances without a replay',
      () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        await seekAndSettle(handler, const Duration(seconds: 170));
        final loadsBefore = player.sourceLoads;

        player.finishCurrentTrack();
        await until(() => handler.snapshot.currentSongId == 'song-2');
        await settleQueue(handler);

        expect(player.index, 2);
        expect(player.sourceLoads, loadsBefore);
        expect(current(player).positionOffset, Duration.zero);
        expect(player.position, lessThan(const Duration(seconds: 2)));
      },
    );

    test('repeat all wrapping onto a song that played as an offset starts it '
        'at 0', () async {
      final (handler, player, _) = await offsetHandler(count: 2);
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      await settleQueue(handler);
      await handler.play();
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      await seekAndSettle(handler, const Duration(seconds: 90));
      expect(current(player).positionOffset, const Duration(seconds: 90));

      player.finishCurrentTrack();
      await until(() => handler.snapshot.currentSongId == 'song-1');
      player.finishCurrentTrack();
      await until(
        () =>
            handler.snapshot.currentSongId == 'song-0' &&
            !handler.snapshot.isLoading &&
            current(player).positionOffset == Duration.zero,
      );

      expect(handler.collectPlaybackDiagnostics()['positionOffsetMs'], 0);
      expect(handler.queue.value[0].extras!['positionOffsetMs'], 0);
      expect(
        current(player).uri.queryParameters,
        isNot(contains('timeOffset')),
      );
      expect(player.position, lessThan(const Duration(seconds: 2)));
    });

    test('an offset reload of the current song starts no extra seek', () async {
      final (handler, player, _) = await offsetHandler();
      await start(handler);
      final loads = player.sourceLoads;
      final events =
          (handler.collectPlaybackDiagnostics()['seekEvents']! as List).length;

      await seekAndSettle(handler, const Duration(seconds: 90));
      // The reload's own index change and playback events are not loops.
      player.playbackEvents.add(player.playbackEvent);
      await pumpEventQueue(times: 50);
      await settleQueue(handler);

      expect(player.sourceLoads, loads + 1);
      expect(
        (handler.collectPlaybackDiagnostics()['seekEvents']! as List).length,
        events + 1,
      );
      expect(current(player).positionOffset, const Duration(seconds: 90));
    });

    test('an index change during an offset reload is not a wrap', () async {
      final (handler, player, _) = await offsetHandler();
      await start(handler);
      await seekAndSettle(handler, const Duration(seconds: 90));
      final loads = player.sourceLoads;
      final gate = Completer<void>();
      final entered = Completer<void>();
      player
        ..loadGate = gate
        ..loadEntered = entered;

      final seeking = handler.seek(const Duration(seconds: 120));
      await entered.future;
      // The reload reports an index change while the old offset source is
      // still in the sequence.
      player.discontinuityEvents.add(
        PositionDiscontinuity(
          PositionDiscontinuityReason.autoAdvance,
          PlaybackEvent(
            processingState: ProcessingState.ready,
            updatePosition: const Duration(seconds: 3),
            currentIndex: 0,
          ),
          player.playbackEvent,
        ),
      );
      await pumpEventQueue(times: 50);
      gate.complete();
      await seeking;
      await until(() => !handler.snapshot.isLoading);
      await settleQueue(handler);

      expect(player.sourceLoads, loads + 1);
      expect(current(player).positionOffset, const Duration(seconds: 120));
    });

    for (final index in [1, 2]) {
      test('edge 3: repeat one reloads offset item $index exactly once', () async {
        final (handler, player, _) = await offsetHandler();
        await handler.replaceQueue(
          ['song-0', 'song-1', 'song-2'],
          startIndex: index,
          expandMatchFlows: false,
        );
        await settleQueue(handler);
        await handler.play();
        await handler.setRepeatMode(AudioServiceRepeatMode.one);
        await seekAndSettle(handler, const Duration(seconds: 170));
        expect(player.loopMode, LoopMode.one);
        final loadsBefore = player.sourceLoads;

        // The owned native seek reports the same tail-to-start event as a loop.
        player.finishCurrentTrack();
        // Further playback events following that seek are not more loops.
        player.playbackEvents.add(player.playbackEvent);
        player.playbackEvents.add(player.playbackEvent);
        await until(
          () =>
              player.sourceLoads == loadsBefore + 1 &&
              !handler.snapshot.isLoading,
        );
        await settleQueue(handler);

        expect(player.sourceLoads, loadsBefore + 1);
        expect(current(player).positionOffset, Duration.zero);
        expect(
          current(player).uri.queryParameters,
          isNot(contains('timeOffset')),
        );
        expect(player.position, lessThan(const Duration(seconds: 2)));
        expect(player.sourceIds, ['song-0', 'song-1', 'song-2']);
        expect(player.index, index);
        expect(player.playing, isTrue);
        expect(player.loopMode, LoopMode.one);
      });
    }

    test(
      'edge 3: repeat all auto-advance never restarts the next song while the '
      'current item lags',
      () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        await handler.setRepeatMode(AudioServiceRepeatMode.all);
        await seekAndSettle(handler, const Duration(seconds: 100));
        expect(player.loopMode, LoopMode.all);
        await settleQueue(handler);
        final loadsBefore = player.sourceLoads;
        final seeksBefore = player.seekCalls;
        player.simulatedPosition = const Duration(seconds: 179);
        player.playbackEvents.add(player.playbackEvent);
        await pumpEventQueue();

        // The native advance event reaches the handler before the index
        // chain moves its current item off the offset song.
        player
          ..index = 2
          ..simulatedPosition = Duration.zero;
        player.playbackEvents.add(player.playbackEvent);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        player.indexEvents.add(2);
        player.discontinuityEvents.add(
          PositionDiscontinuity(
            PositionDiscontinuityReason.autoAdvance,
            PlaybackEvent(
              processingState: ProcessingState.ready,
              updatePosition: const Duration(seconds: 179),
              currentIndex: 1,
            ),
            player.playbackEvent,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(player.sourceLoads, loadsBefore);
        expect(player.seekCalls, seeksBefore);
        expect(handler.snapshot.currentSongId, 'song-2');
        expect(lastSeekEvent(handler)['requestedPositionMs'], 100000);
      },
    );

    test(
      'edge 3: repeat all over a single offset song reloads it from zero',
      () async {
        final directory = await Directory.systemTemp.createTemp('navis-loop1-');
        final (handler, player, database) = await createHandler(
          directory,
          1,
          sidecarStreams: true,
          streamingQuality: opus128,
          supportsTranscodeOffset: true,
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        player.simulateProgress = true;
        await handler.replaceQueue(['song-0'], expandMatchFlows: false);
        await settleQueue(handler);
        await handler.play();
        await handler.setRepeatMode(AudioServiceRepeatMode.all);
        await seekAndSettle(handler, const Duration(seconds: 170));
        final loadsBefore = player.sourceLoads;

        player.finishCurrentTrack();
        await until(
          () =>
              player.sourceLoads == loadsBefore + 1 &&
              !handler.snapshot.isLoading,
        );

        expect(current(player).positionOffset, Duration.zero);
        expect(player.position, lessThan(const Duration(seconds: 2)));
      },
    );

    test(
      'edge 3: a loop during the background queue fill still reloads from zero',
      () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        await handler.setRepeatMode(AudioServiceRepeatMode.one);
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..appendGate = gate
          ..appendEntered = entered;
        await handler.seek(const Duration(seconds: 100));
        await entered.future;
        // The fill that restores the rest of the queue is still running.
        expect(handler.snapshot.isLoading, isTrue);
        expect(current(player).positionOffset, const Duration(seconds: 100));
        final loadsBefore = player.sourceLoads;

        player.finishCurrentTrack();
        await pumpEventQueue();
        gate.complete();
        await until(
          () =>
              player.sourceLoads == loadsBefore + 1 &&
              !handler.snapshot.isLoading,
        );

        expect(current(player).positionOffset, Duration.zero);
        expect(player.position, lessThan(const Duration(seconds: 2)));
        expect(player.sourceIds, ['song-0', 'song-1', 'song-2']);
      },
    );

    test('edge 3: a loop during teardown starts no seek', () async {
      final (handler, player, _) = await offsetHandler();
      await start(handler);
      await handler.setRepeatMode(AudioServiceRepeatMode.one);
      await seekAndSettle(handler, const Duration(seconds: 100));
      await settleQueue(handler);
      final gate = Completer<void>();
      final entered = Completer<void>();
      player
        ..listenerCancelGate = gate
        ..listenerCancelEntered = entered;

      final disposal = handler.disposeHandler();
      await entered.future;
      // Disposal has started but the discontinuity listener is still wired.
      player.finishCurrentTrack();
      await pumpEventQueue();
      gate.complete();
      await disposal;

      expect(
        handler.collectPlaybackDiagnostics()['seek'],
        containsPair('requestedPositionMs', 100000),
      );
    });

    test('edge 4: Previous reloads an offset song from zero', () async {
      final (handler, player, _) = await offsetHandler();
      await start(handler);
      await seekAndSettle(handler, const Duration(seconds: 100));

      await handler.skipToPrevious();
      await until(
        () =>
            !handler.snapshot.isLoading &&
            player.position < const Duration(seconds: 2),
      );

      expect(handler.snapshot.currentSongId, 'song-1');
      expect(current(player).positionOffset, Duration.zero);
      expect(
        current(player).uri.queryParameters,
        isNot(contains('timeOffset')),
      );
    });

    test('edge 5: an offset reload keeps the scrobble session', () async {
      final scrobbles = NoopScrobbleService();
      final (handler, player, _) = await offsetHandler(
        scrobbleService: scrobbles,
        positionStreams: true,
      );
      await start(handler);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final sessions = scrobbles.nowPlayingSessions.length;
      expect(sessions, 1);

      await seekAndSettle(handler, const Duration(seconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(current(player).positionOffset, const Duration(seconds: 100));
      expect(scrobbles.nowPlaying, ['song-1']);
      expect(scrobbles.nowPlayingSessions, hasLength(1));
    });

    test(
      'edge 6: the sidecar keeps downloading the full non-offset stream',
      () async {
        final previousHttp = HttpOverrides.current;
        HttpOverrides.global = null;
        final requests = <Map<String, String>>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final release = Completer<void>();
        server.listen((request) async {
          requests.add(request.uri.queryParameters);
          try {
            request.response
              ..bufferOutput = false
              ..contentLength = 100 * 1024
              ..add(List<int>.filled(10 * 1024, 1));
            await request.response.flush();
            await release.future;
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
        final (handler, player, _) = await offsetHandler(
          readApiClient: () => api,
        );
        addTearDown(() async {
          release.complete();
          await server.close(force: true);
          HttpOverrides.global = previousHttp;
        });
        await start(handler);
        await until(() => requests.isNotEmpty);
        expect(
          handler.collectPlaybackDiagnostics()['sidecarCacheActiveSongId'],
          'song-1',
        );

        await seekAndSettle(handler, const Duration(seconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(current(player).uri.queryParameters['timeOffset'], '100');
        expect(
          handler.collectPlaybackDiagnostics()['sidecarCacheActiveSongId'],
          'song-1',
        );
        expect(
          [for (final q in requests) '${q['id']}:${q['timeOffset']}'],
          ['song-1:null'],
        );
        expect(requests.single['id'], 'song-1');
        expect(requests.single, isNot(contains('timeOffset')));
      },
    );

    test(
      'edge 7: once the full download completes a seek uses the file',
      () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        final sidecar =
            handler.queue.value[1].extras!['sidecarCacheFilePath'] as String;
        await seekAndSettle(handler, const Duration(seconds: 60));
        expect(current(player).positionOffset, const Duration(seconds: 60));
        expect(handler.queue.value[1].extras!['sidecarCacheFilePath'], sidecar);
        await File(sidecar).writeAsBytes(List<int>.filled(64, 1));

        await seekAndSettle(handler, const Duration(seconds: 120));

        expect(handler.queue.value[1].extras!['sourceKind'], 'file');
        expect(handler.queue.value[1].extras!['positionOffsetMs'], 0);
        expect(current(player).positionOffset, Duration.zero);
        expect(current(player).uri.scheme, 'file');
        expect(lastSeekEvent(handler)['path'], isNot('transcodeOffset'));
      },
    );

    test('edge 7 (lock cache): the original download fills the file an offset '
        'stream leaves; a later seek reloads from it', () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-offset-lock-',
      );
      final api = SubsonicApiClient(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
        ),
        enableLogging: false,
      );
      final (handler, player, database) = await createHandler(
        directory,
        3,
        cacheSongs: false,
        readApiClient: () => api,
        streamingQuality: opus128,
        supportsTranscodeOffset: true,
        // The origin never answers, so the range probe gives up quickly.
        timeouts: const NavisPlaybackTimeouts(
          load: Duration(milliseconds: 300),
        ),
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      player.simulateProgress = true;
      await start(handler);
      final lockCached = handler.queue.value[1].extras!;
      expect(lockCached['sourceKind'], 'lockCachedStream');
      final cachePath = lockCached['cachedFilePath']! as String;

      await failAt(handler, player, const Duration(seconds: 70));
      expect(current(player).positionOffset, const Duration(seconds: 70));
      expect(current(player).uri.queryParameters['timeOffset'], '70');
      expect(player.position.inSeconds, 70);

      await seekAndSettle(handler, const Duration(seconds: 100));

      final offsetItem = handler.queue.value[1].extras!;
      expect(offsetItem['sourceKind'], 'directStream');
      expect(offsetItem['positionOffsetMs'], 100000);
      expect(offsetItem['cachedFilePath'], cachePath);
      expect(current(player).positionOffset, const Duration(seconds: 100));
      expect(lastSeekEvent(handler)['path'], 'transcodeOffset');

      // The lock-cache download finishes beside the offset stream.
      await File(cachePath).writeAsBytes(List<int>.filled(64, 1));
      await seekAndSettle(handler, const Duration(seconds: 150));

      expect(handler.queue.value[1].extras!['sourceKind'], 'file');
      expect(current(player).positionOffset, Duration.zero);
      expect(lastSeekEvent(handler)['path'], isNot('transcodeOffset'));
    });

    test('edge 8: no timeOffset without the capability', () async {
      final (handler, player, _) = await offsetHandler(capable: false);
      player.ignoreSeeks = true;
      await start(handler);

      await handler.seek(const Duration(seconds: 90));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      for (final source in player.sequence.whereType<UriAudioSource>()) {
        expect(source.uri.queryParameters, isNot(contains('timeOffset')));
        expect(source.positionOffset, Duration.zero);
      }
    });

    test('edge 8: no timeOffset for original quality', () async {
      final (handler, player, _) = await offsetHandler(
        quality: const StreamingQuality(label: 'original'),
      );
      player.ignoreSeeks = true;
      await start(handler);

      await handler.seek(const Duration(seconds: 90));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      for (final source in player.sequence.whereType<UriAudioSource>()) {
        expect(source.uri.queryParameters, isNot(contains('timeOffset')));
        expect(source.positionOffset, Duration.zero);
      }
    });

    test('a seek under a second stays a native seek', () async {
      final (handler, player, _) = await offsetHandler();
      await start(handler);
      final loadsBefore = player.sourceLoads;

      await handler.seek(const Duration(milliseconds: 400));

      expect(player.sourceLoads, loadsBefore);
      expect(player.seekCalls, greaterThan(0));
    });

    test(
      'a failed offset reload falls back to the existing seek path',
      () async {
        final (handler, player, _) = await offsetHandler();
        await start(handler);
        player.ignoreSeeks = true;
        // The offset load fails; the fallback may only reload without one.
        player.failLoadSongId = 'song-1';

        await handler.seek(const Duration(seconds: 90));
        await Future<void>.delayed(const Duration(milliseconds: 100));

        for (final source in player.sequence.whereType<UriAudioSource>()) {
          expect(source.positionOffset, Duration.zero);
        }
        expect(lastSeekEvent(handler)['path'], isNot('transcodeOffset'));
      },
    );
  });

  group('repeat one timeline', () {
    for (final crossfade in [false, true]) {
      test('paused initial snapshot cannot retain a settled seek target, '
          'fade=$crossfade', () async {
        final directory = await Directory.systemTemp.createTemp(
          'navis-timeline-',
        );
        final (handler, player, database) = await createHandler(
          directory,
          3,
          crossfade: crossfade,
          positionStreams: true,
        );
        final container = ProviderContainer(
          overrides: [audioHandlerProvider.overrideWithValue(handler)],
        );
        addTearDown(() async {
          container.dispose();
          await handler.disposeHandler();
          await database.close();
          await directory.delete(recursive: true);
        });
        player.simulateProgress = true;
        await handler.replaceQueue([
          'song-0',
          'song-1',
          'song-2',
        ], expandMatchFlows: false);
        await handler.setRepeatMode(AudioServiceRepeatMode.one);
        await settleQueue(handler);
        container.listen(playbackPositionProvider, (_, _) {});
        final seeking = handler.seek(const Duration(seconds: 166));
        final initial = Completer<void>();
        late ProviderSubscription<AsyncValue<PlaybackSnapshot>> subscription;
        subscription = container.listen(playbackSnapshotProvider, (_, next) {
          if (!initial.isCompleted &&
              next.asData?.value.pendingSeekPosition != null) {
            // Riverpod pauses the source when its last visible listener pauses.
            // Pause at the initial yield, before the live broadcast is attached.
            subscription.pause();
            initial.complete();
          }
        });
        await initial.future;
        await seeking;
        expect(handler.snapshot.pendingSeekPosition, isNull);
        expect(
          (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
          'completed',
        );
        subscription.resume();
        await Future<void>.delayed(const Duration(milliseconds: 350));

        final before = container.read(playbackPositionProvider).requireValue;
        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect(
          container.read(playbackPositionProvider).requireValue,
          greaterThan(before),
        );
        player.simulatedPosition = const Duration(seconds: 1);
        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect(
          container.read(playbackPositionProvider).requireValue,
          lessThan(const Duration(seconds: 2)),
        );
        expect(container.read(playerStateProvider).pendingSeekPosition, isNull);
      });
    }

    for (final crossfade in [false, true]) {
      for (final recovery in [false, true]) {
        test('seek, skip and native wrap keep provider position moving, '
            'fade=$crossfade recovery=$recovery', () async {
          final directory = await Directory.systemTemp.createTemp(
            'navis-timeline-',
          );
          final (handler, player, database) = await createHandler(
            directory,
            3,
            crossfade: crossfade,
            positionStreams: true,
            rebuiltPlayers: <ControllableAudioPlayer>[],
            timeouts: const NavisPlaybackTimeouts(
              control: Duration(milliseconds: 100),
              reset: Duration(milliseconds: 150),
              load: Duration(seconds: 2),
            ),
          );
          final container = ProviderContainer(
            overrides: [audioHandlerProvider.overrideWithValue(handler)],
          );
          addTearDown(() async {
            container.dispose();
            await handler.disposeHandler();
            await database.close();
            await directory.delete(recursive: true);
          });
          final displayedPosition = Provider<Duration>((ref) {
            final snapshot = ref.watch(playerStateProvider);
            return snapshot.pendingSeekPosition ??
                ref.watch(playbackPositionProvider).asData?.value ??
                snapshot.position;
          });
          container.listen(displayedPosition, (_, _) {});
          final snapshots = <PlaybackSnapshot>[];
          container.listen(playbackSnapshotProvider, (_, next) {
            if (next.asData case final data?) snapshots.add(data.value);
          });

          player.simulateProgress = true;
          await handler.replaceQueue([
            'song-0',
            'song-1',
            'song-2',
          ], expandMatchFlows: false);
          await handler.setRepeatMode(AudioServiceRepeatMode.one);
          await handler.skipToNext();
          await settleQueue(handler);
          expect(player.index, 1);
          await Future<void>.delayed(const Duration(milliseconds: 250));
          final afterNext = container
              .read(playbackPositionProvider)
              .requireValue;
          await Future<void>.delayed(const Duration(milliseconds: 350));
          expect(container.read(displayedPosition), greaterThan(afterNext));
          if (recovery) player.hang.add('seek');
          final seeking = handler.seek(const Duration(minutes: 2, seconds: 46));
          expect(
            handler.snapshot.pendingSeekPosition,
            const Duration(minutes: 2, seconds: 46),
          );
          await seeking;
          await Future<void>.delayed(const Duration(milliseconds: 350));
          expect(snapshots.last.pendingSeekPosition, isNull);
          final active = handler.debugActivePlayer as ControllableAudioPlayer;
          expect(identical(active, player), !recovery);
          expect(active.loopMode, LoopMode.one);
          expect(
            (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
            'completed',
          );
          expect(active.position, greaterThan(const Duration(seconds: 166)));
          expect(active.position, lessThan(const Duration(seconds: 170)));
          final first = container.read(playbackPositionProvider).requireValue;
          await Future<void>.delayed(const Duration(milliseconds: 350));
          final second = container.read(playbackPositionProvider).requireValue;
          expect(second, greaterThan(first));
          expect(container.read(displayedPosition), second);
          expect(fade(handler)['active'], isFalse);
          // Native loop-one changes position without changing queue occurrence.
          active.simulatedPosition = const Duration(seconds: 1);
          // Keep the same PlayerEvent: progress must not need another event
          // to rearm its timer after seek settlement or a loop wrap.
          await Future<void>.delayed(const Duration(milliseconds: 350));
          final wrapped = container.read(playbackPositionProvider).requireValue;
          expect(wrapped, lessThan(const Duration(seconds: 2)));
          expect(handler.snapshot.currentSongId, 'song-1');
          expect(handler.snapshot.currentIndex, 1);
          expect(handler.snapshot.queueSongIds, ['song-0', 'song-1', 'song-2']);
          await Future<void>.delayed(const Duration(milliseconds: 350));
          expect(
            container.read(playbackPositionProvider).requireValue,
            greaterThan(wrapped),
          );
          await handler.skipToPrevious();
          await settleQueue(handler);
          expect(active.index, 0);
          await Future<void>.delayed(const Duration(milliseconds: 250));
          final afterSkip = container
              .read(playbackPositionProvider)
              .requireValue;
          await Future<void>.delayed(const Duration(milliseconds: 350));
          expect(
            container.read(playbackPositionProvider).requireValue,
            greaterThan(afterSkip),
          );
          expect(handler.snapshot.pendingSeekPosition, isNull);
          expect(handler.snapshot.repeatMode, AudioServiceRepeatMode.one);
        });
      }
    }
  });

  group('seek requests', () {
    const fastTimeouts = NavisPlaybackTimeouts(
      load: Duration(seconds: 2),
      control: Duration(milliseconds: 100),
      reset: Duration(milliseconds: 150),
      seekBufferingRecovery: Duration(milliseconds: 150),
    );
    Future<(NavisAudioHandler, ControllableAudioPlayer, NavisDatabase)> setup({
      List<ControllableAudioPlayer>? rebuilt,
    }) async {
      final directory = await Directory.systemTemp.createTemp('navis-seek-');
      final created = await createHandler(
        directory,
        4,
        timeouts: fastTimeouts,
        rebuiltPlayers: rebuilt,
      );
      addTearDown(() async {
        await created.$1.disposeHandler();
        await created.$3.close();
        await directory.delete(recursive: true);
      });
      created.$2.simulateProgress = true;
      return created;
    }

    for (final play in [true, false]) {
      test('latest seek survives loading with playing=$play', () async {
        final (handler, player, _) = await setup();
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..loadGate = gate
          ..loadEntered = entered;
        final load = handler.replaceQueue(
          ['song-0', 'song-1'],
          expandMatchFlows: false,
          autoPlay: play,
        );
        await entered.future;
        final old = handler.seek(const Duration(seconds: 30));
        final latest = handler.seek(const Duration(seconds: 90));
        expect(
          handler.snapshot.pendingSeekPosition,
          const Duration(seconds: 90),
        );
        expect(player.seekCalls, 0);
        expect(handler.snapshot.playing, play);
        gate.complete();
        await Future.wait([load, old, latest]);
        expect(
          (player.position - const Duration(seconds: 90)).abs().inMilliseconds,
          lessThan(1000),
        );
        expect(player.playing, play);
        expect(handler.snapshot.pendingSeekPosition, isNull);
        expect(
          (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
          'completed',
        );
      });
    }

    test('hung seek retires the engine before a newer seek uses it', () async {
      final rebuilt = <ControllableAudioPlayer>[];
      final (handler, player, _) = await setup(rebuilt: rebuilt);
      await handler.replaceQueue(
        ['song-0', 'song-1', 'song-0'],
        startIndex: 2,
        expandMatchFlows: false,
      );
      const adjustments = PlaybackAdjustments(speed: 1.25, pitchSemitones: -2);
      await handler.setPlaybackAdjustments(adjustments);
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      player.hang.add('seek');
      final old = handler.seek(const Duration(seconds: 90));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final latest = handler.seek(const Duration(seconds: 40));
      await Future.wait([old, latest]);
      expect(rebuilt, hasLength(1));
      expect(
        (rebuilt.single.position - const Duration(seconds: 40))
            .abs()
            .inMilliseconds,
        lessThan(1000),
      );
      expect(rebuilt.single.index, 2);
      expect(rebuilt.single.sourceIds, ['song-0', 'song-1', 'song-0']);
      expect(rebuilt.single.playing, isTrue);
      expect(rebuilt.single.appliedSpeed, adjustments.speed);
      expect(
        rebuilt.single.appliedPitch,
        closeTo(adjustments.pitchFactor, 0.000001),
      );
      expect(rebuilt.single.appliedLoopMode, LoopMode.all);
      expect(player.seekCalls, 1);
    });

    test(
      'late callbacks from a timed-out engine cannot change the new selection',
      () async {
        final rebuilt = <ControllableAudioPlayer>[];
        final (handler, player, _) = await setup(rebuilt: rebuilt);
        player.keepStreamsAfterDispose = true;
        addTearDown(player.indexEvents.close);
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..seekGate = gate
          ..seekEntered = entered;
        final seek = handler.seek(const Duration(seconds: 90));
        await entered.future;
        final selection = handler.playFromIndex(1);
        await Future.wait([seek, selection]);
        // Navigation acknowledges admission before its serialized load settles.
        for (var attempt = 0; attempt < 100; attempt++) {
          if (rebuilt.length == 1 &&
              !handler.snapshot.isLoading &&
              handler.snapshot.currentIndex == 1) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(rebuilt, hasLength(1));
        expect(handler.snapshot.isLoading, isFalse);
        gate.complete();
        player.indexEvents.add(0);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(handler.snapshot.currentIndex, 1);
        expect(handler.snapshot.pendingSeekPosition, isNull);
        expect(rebuilt.single.position.inMilliseconds, lessThan(1000));
      },
    );

    test(
      'removing the selected duplicate cancels its pending target',
      () async {
        final (handler, player, _) = await setup();
        await handler.replaceQueue([
          'song-0',
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        player.ignoreSeeks = true;
        final seek = handler.seek(const Duration(seconds: 90));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await handler.removeAt(0);
        await seek;
        expect(handler.snapshot.pendingSeekPosition, isNull);
        expect(handler.snapshot.queueSongIds, ['song-0', 'song-1']);
        expect(
          (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
          'superseded',
        );
      },
    );

    test(
      'an interpolated clock cannot confirm a stalled native seek',
      () async {
        final (handler, player, _) = await setup();
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        player.nativePositionFrozen = true;
        await handler.seek(const Duration(seconds: 90));
        final outcome = handler.collectPlaybackDiagnostics()['seek']! as Map;
        expect(outcome['outcome'], 'failed');
        expect(outcome['recoveryAttempts'], 1);
        player.state = ProcessingState.buffering; // A stall.
        await handler.debugRecoverCurrentSong();
        expect(
          (handler.collectPlaybackDiagnostics()['seek']!
              as Map)['recoveryAttempts'],
          1,
        );
        expect(handler.snapshot.queueSongIds, ['song-0', 'song-1']);
        expect(player.playing, isTrue);
        expect(handler.snapshot.pendingSeekPosition, isNull);
      },
    );

    test('a backend flapping between ready and buffering while it fetches '
        'still lands without recovery', () async {
      final (handler, player, _) = await setup();
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      // mpv reports the target at once but produces no packets yet, while
      // its buffering flag toggles many times a second.
      player.nativePositionFrozen = true;
      final flap = Timer.periodic(const Duration(milliseconds: 40), (_) {
        player.state = player.state == ProcessingState.ready
            ? ProcessingState.buffering
            : ProcessingState.ready;
      });
      final landed = Timer(const Duration(milliseconds: 700), () {
        flap.cancel();
        player
          ..state = ProcessingState.ready
          ..simulatedPosition = player.simulatedPosition
          ..nativePositionFrozen = false;
      });
      addTearDown(() {
        flap.cancel();
        landed.cancel();
      });
      await handler.seek(const Duration(seconds: 90));
      final outcome = handler.collectPlaybackDiagnostics()['seek']! as Map;
      expect(outcome['outcome'], 'completed');
      expect(outcome['recoveryAttempts'], 0);
      expect(
        (player.position - const Duration(seconds: 90)).abs(),
        lessThan(const Duration(seconds: 2)),
      );
    });

    test('desktop buffering seek outlasts the load deadline without a download signal', () async {
      final directory = await Directory.systemTemp.createTemp('navis-seek-');
      final (handler, player, database) = await createHandler(
        directory,
        2,
        rebuiltPlayers: <ControllableAudioPlayer>[],
        timeouts: const NavisPlaybackTimeouts(
          load: Duration(milliseconds: 300),
          control: Duration(milliseconds: 100),
          reset: Duration(milliseconds: 150),
          seekBufferingRecovery: Duration(milliseconds: 150),
          seekProgress: Duration(seconds: 5),
        ),
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      player.simulateProgress = true;
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      player
        ..state = ProcessingState.buffering
        ..nativePositionFrozen = true;
      final landed = Timer(const Duration(milliseconds: 900), () {
        player
          ..state = ProcessingState.ready
          ..simulatedPosition = player.simulatedPosition
          ..nativePositionFrozen = false;
      });
      addTearDown(landed.cancel);
      await handler.seek(const Duration(seconds: 90));
      final outcome = handler.collectPlaybackDiagnostics()['seek']! as Map;
      expect(outcome['recoveryAttempts'], 0);
      expect(outcome['outcome'], 'completed');
    });

    test(
      'buffering range probes can outlast the short stall interval',
      () async {
        final (handler, player, _) = await setup();
        await handler.replaceQueue([
          'song-0',
          'song-1',
        ], expandMatchFlows: false);
        player
          ..state = ProcessingState.buffering
          ..nativePositionFrozen = true;
        final ready = Timer(const Duration(milliseconds: 350), () {
          player
            ..state = ProcessingState.ready
            ..nativePositionFrozen = false;
        });
        addTearDown(ready.cancel);
        await handler.seek(const Duration(seconds: 90));
        final outcome = handler.collectPlaybackDiagnostics()['seek']! as Map;
        expect(outcome['outcome'], 'completed');
        expect(outcome['recoveryAttempts'], 0);
        expect(handler.snapshot.queueSongIds, ['song-0', 'song-1']);
      },
    );

    test(
      'recovery waits for a progressing sidecar to become a complete file',
      () async {
        final previousHttp = HttpOverrides.current;
        HttpOverrides.global = null;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        unawaited(() async {
          await for (final request in server) {
            request.response
              ..headers.contentType = ContentType('audio', 'mpeg')
              ..contentLength = 100
              ..add(List<int>.filled(80, 1));
            await request.response.flush();
            for (var chunk = 0; chunk < 4; chunk++) {
              await Future<void>.delayed(const Duration(milliseconds: 100));
              request.response.add(List<int>.filled(5, 1));
              await request.response.flush();
            }
            await request.response.close();
          }
        }());
        final api = SubsonicApiClient(
          baseUrl: 'http://127.0.0.1:${server.port}',
          authConfig: const SubsonicAuthConfig(
            username: 'fixture',
            password: 'synthetic',
            apiVersion: '1.16.1',
          ),
          enableLogging: false,
        );
        final directory = await Directory.systemTemp.createTemp('navis-seek-');
        final (handler, player, database) = await createHandler(
          directory,
          2,
          sidecarStreams: true,
          readApiClient: () => api,
          timeouts: fastTimeouts,
        );
        addTearDown(() async {
          await handler.disposeHandler();
          await database.close();
          await server.close(force: true);
          await directory.delete(recursive: true);
          HttpOverrides.global = previousHttp;
        });
        await handler.replaceQueue(
          ['song-0', 'song-1', 'song-0'],
          startIndex: 2,
          expandMatchFlows: false,
        );
        player
          ..ignoreSeeks = true
          ..simulateProgress = true;
        for (var attempt = 0; attempt < 100; attempt++) {
          final activity = handler
              .collectPlaybackDiagnostics()['cacheActivity'];
          if (activity is Map && (activity['progress'] as num) >= 0.8) break;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await handler.seek(const Duration(seconds: 90));
        final outcome = handler.collectPlaybackDiagnostics()['seek']! as Map;
        expect(outcome['outcome'], 'completed');
        expect(outcome['recoveryAttempts'], 1);
        expect(handler.snapshot.queueSongIds, ['song-0', 'song-1', 'song-0']);
        expect(handler.snapshot.currentIndex, 2);
        expect(handler.queue.value[2].extras!['sourceKind'], 'file');
        expect(player.playing, isTrue);
      },
    );

    test('backward native no-op recovers to the requested position', () async {
      final (handler, player, _) = await setup();
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      player
        ..simulatedPosition = const Duration(seconds: 90)
        ..ignoreSeeks = true;
      await handler.seek(const Duration(seconds: 20));
      expect(
        (player.position - const Duration(seconds: 20)).abs().inMilliseconds,
        lessThan(1000),
      );
      expect(player.playing, isTrue);
      expect(
        (handler.collectPlaybackDiagnostics()['seek']!
            as Map)['recoveryAttempts'],
        1,
      );
    });

    for (final resetAccount in [true, false]) {
      test(
        'pending seek is cancelled by ${resetAccount ? 'account reset' : 'track selection'}',
        () async {
          final (handler, player, _) = await setup();
          final gate = Completer<void>();
          final entered = Completer<void>();
          player
            ..loadGate = gate
            ..loadEntered = entered;
          final load = handler.replaceQueue([
            'song-0',
            'song-1',
          ], expandMatchFlows: false);
          await entered.future;
          final seek = handler.seek(const Duration(seconds: 90));
          final selection = resetAccount
              ? handler.resetSession()
              : handler.replaceQueue(['song-1'], expandMatchFlows: false);
          gate.complete();
          await Future.wait([load, seek, selection]);
          expect(handler.snapshot.pendingSeekPosition, isNull);
          expect(player.position.inMilliseconds, lessThan(1000));
          expect(
            handler.snapshot.currentSongId,
            resetAccount ? isNull : 'song-1',
          );
        },
      );
    }
  });

  group('seek recovery', () {
    List<String> ids(int count, [int from = 0]) =>
        List<String>.generate(count - from, (i) => 'song-${i + from}');

    Future<(NavisAudioHandler, ControllableAudioPlayer, NavisDatabase)>
    recovering(int count, {bool crossfade = false}) async {
      final directory = await Directory.systemTemp.createTemp('navis-recover-');
      final created = await createHandler(
        directory,
        count,
        crossfade: crossfade,
        sidecarStreams: true,
      );
      addTearDown(() async {
        await created.$1.disposeHandler();
        await created.$3.close();
        await directory.delete(recursive: true);
      });
      created.$2
        ..ignoreSeeks = true
        ..simulateProgress = true;
      return created;
    }

    /// Plays [count] songs from the second one, with its stream already cached
    /// in a completed sidecar file so a seek that does not land reloads the
    /// queue (the fake player never lands a seek).
    Future<void> start(NavisAudioHandler handler, int count) async {
      await handler.replaceQueue(
        ids(count),
        startIndex: 1,
        expandMatchFlows: false,
      );
      final sidecar =
          handler.queue.value[1].extras!['sidecarCacheFilePath'] as String;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await File(sidecar).writeAsBytes(List<int>.filled(64, 1));
    }

    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 300 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(condition(), isTrue);
    }

    test('reloads paused and resumes only once landed on the target', () async {
      final (handler, player, _) = await recovering(5);
      await start(handler, 5);
      // The native seek is a no-op and the reload ignores its initial
      // position: only the correction seek lands.
      player
        ..ignoreSeeks = false
        ..ignoredSeeks = 1
        ..ignoreInitialPosition = true;
      final playsBefore = player.playedFrom.length;

      await handler.seek(const Duration(seconds: 30));

      final outcome = handler.collectPlaybackDiagnostics()['seek']! as Map;
      expect(outcome['outcome'], 'completed');
      expect(outcome['recoveryAttempts'], 1);
      final resumed = player.playedFrom.skip(playsBefore).toList();
      expect(resumed, isNotEmpty);
      // Never heard from the start of the song.
      for (final position in resumed) {
        expect(
          (position - const Duration(seconds: 30)).abs(),
          lessThan(const Duration(seconds: 2)),
        );
      }
      expect(player.playing, isTrue);
    });

    test(
      'restores the whole queue even when playback is paused meanwhile',
      () async {
        final (handler, player, _) = await recovering(5);
        await start(handler, 5);
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..loadGate = gate
          ..loadEntered = entered;

        final seek = handler.seek(const Duration(seconds: 30));
        await entered.future;
        // A newer transport command while the current song reloads.
        await handler.pause();
        gate.complete();

        await until(
          () => player.sourceIds.length == 5 && !handler.snapshot.isLoading,
        );
        await seek;
        expect(player.position, const Duration(seconds: 30));
        expect(player.playing, isFalse);
        expect(player.sourceIds, ids(5));
        expect(handler.snapshot.queueSongIds, ids(5));
        expect(
          handler.collectPlaybackDiagnostics()['playerMatchesQueue'],
          true,
        );
      },
    );

    test(
      'Play during recovery of a paused song resumes at the target',
      () async {
        final (handler, player, _) = await recovering(5);
        await start(handler, 5);
        await handler.pause();
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..loadGate = gate
          ..loadEntered = entered;
        final seek = handler.seek(const Duration(seconds: 30));
        await entered.future;
        await handler.play();
        gate.complete();
        await seek;
        await until(
          () => player.sourceIds.length == 5 && !handler.snapshot.isLoading,
        );
        expect(player.playing, isTrue);
        expect(
          (player.position - const Duration(seconds: 30)).abs().inMilliseconds,
          lessThan(1000),
        );
        expect(handler.snapshot.queueSongIds, ids(5));
      },
    );

    test(
      'overlapping seeks during recovery restore the full duplicate queue',
      () async {
        final (handler, player, _) = await recovering(5);
        await handler.replaceQueue(
          ['song-0', 'song-1', 'song-1', 'song-2'],
          startIndex: 2,
          expandMatchFlows: false,
        );
        final sidecar =
            handler.queue.value[2].extras!['sidecarCacheFilePath']! as String;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await File(sidecar).writeAsBytes(List<int>.filled(64, 1));
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..loadGate = gate
          ..loadEntered = entered;
        final first = handler.seek(const Duration(seconds: 30));
        await entered.future;
        final latest = handler.seek(const Duration(seconds: 60));
        expect(
          handler.snapshot.pendingSeekPosition,
          const Duration(seconds: 60),
        );
        gate.complete();
        await Future.wait([first, latest]);
        await until(() => !handler.snapshot.isLoading);
        expect(player.index, 2);
        expect(player.sourceIds, ['song-0', 'song-1', 'song-1', 'song-2']);
        expect(
          (player.position - const Duration(seconds: 60)).abs().inMilliseconds,
          lessThan(1000),
        );
        expect(player.playing, isTrue);
        expect(
          (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'],
          'completed',
        );
      },
    );

    test('keeps an edit made while the current song reloads', () async {
      final (handler, player, _) = await recovering(7);
      await start(handler, 5);
      final gate = Completer<void>();
      final entered = Completer<void>();
      player
        ..loadGate = gate
        ..loadEntered = entered;

      unawaited(handler.seek(const Duration(seconds: 30)));
      await entered.future;
      final edit = handler.addToQueue(<String>[
        'song-5',
        'song-6',
      ], expandMatchFlows: false);
      gate.complete();
      await edit;

      await until(
        () => player.sourceIds.length == 7 && !handler.snapshot.isLoading,
      );
      expect(handler.snapshot.queueSongIds, ids(7));
      expect(player.sourceIds, ids(7));
    });

    for (final command in ['pause', 'selection']) {
      test('failed remote recovery honors a newer $command', () async {
        final (handler, player, _) = await recovering(5);
        await start(handler, 5);
        final gate = Completer<void>();
        final entered = Completer<void>();
        player
          ..loadGate = gate
          ..loadEntered = entered
          ..blockedLoadError = StateError('retry failed');
        player.state = ProcessingState.buffering; // A stall.
        final recovery = handler.debugRecoverCurrentSong();
        await entered.future;
        final newerCommand = command == 'pause'
            ? handler.pause()
            : handler.playFromIndex(4);
        if (command == 'pause') await newerCommand;
        gate.complete();
        await Future.wait([recovery, newerCommand]);
        await until(() => !handler.snapshot.isLoading);
        expect(
          handler.snapshot.currentSongId,
          command == 'pause' ? 'song-2' : 'song-4',
        );
        expect(player.playing, command != 'pause');
        expectNativeMirrorsQueue(handler, player);
      });
    }

    test('failed recovery of a paused song advances without playing', () async {
      final (handler, player, _) = await recovering(5);
      await start(handler, 5);
      await handler.pause();
      player.failLoadSongId = 'song-1';
      player.state = ProcessingState.buffering; // A stall.
      await handler.debugRecoverCurrentSong();
      await until(() => !handler.snapshot.isLoading);
      expect(handler.snapshot.currentSongId, 'song-2');
      expect(player.playing, isFalse);
    });

    test(
      'a song that cannot be reloaded keeps the queue and moves on',
      () async {
        final (handler, player, _) = await recovering(5);
        await start(handler, 5);
        // The stream that stalled fails again when reloaded.
        player.failLoadSongId = 'song-1';

        player.state = ProcessingState.buffering; // A stall.
        await handler.debugRecoverCurrentSong();

        await until(
          () =>
              handler.snapshot.currentSongId == 'song-2' &&
              !handler.snapshot.isLoading,
        );
        expect(handler.snapshot.queueSongIds, ids(5));
        expect(player.sourceIds, ids(5));
      },
    );

    /// Starts replacing the queue with [count] songs at [startIndex] and
    /// returns once the fill (phase 2) is held open, with the player
    /// holding only the start song.
    Future<Completer<void>> fillHeldOpen(
      NavisAudioHandler handler,
      ControllableAudioPlayer player,
      int count, {
      required int startIndex,
    }) async {
      final gate = Completer<void>();
      final entered = Completer<void>();
      player
        ..appendGate = gate
        ..appendEntered = entered;
      unawaited(
        handler.replaceQueue(
          ids(count),
          startIndex: startIndex,
          expandMatchFlows: false,
        ),
      );
      await entered.future.timeout(const Duration(seconds: 5));
      return gate;
    }

    for (final startIndex in <int>[0, 2]) {
      test('keeps the whole queue when the stream stalls while the queue fills '
          '(start $startIndex)', () async {
        final (handler, player, _) = await recovering(6);
        final gate = await fillHeldOpen(
          handler,
          player,
          6,
          startIndex: startIndex,
        );

        player.state = ProcessingState.buffering; // A stall.
        final recovery = handler.debugRecoverCurrentSong();
        gate.complete();
        await recovery;

        await until(
          () => !handler.snapshot.isLoading && player.sourceIds.length == 6,
        );
        expect(handler.snapshot.queueSongIds, ids(6));
        expect(player.sourceIds, ids(6));
        expect(handler.snapshot.currentSongId, 'song-$startIndex');
        final events =
            handler.collectPlaybackDiagnostics()['seekEvents']!
                as List<Map<String, Object?>>;
        // Queue fill owns the selected source; recovery must wait for it.
        expect(events, isEmpty);
      });
    }

    test(
      'a stalled song waits for queue fill before retrying and moving on',
      () async {
        final (handler, player, _) = await recovering(6);
        final gate = await fillHeldOpen(handler, player, 6, startIndex: 0);
        player.failLoadSongId = 'song-0';

        player.state = ProcessingState.buffering; // A stall.
        final recovery = handler.debugRecoverCurrentSong();
        gate.complete();
        await recovery;
        await settleQueue(handler);
        expect(handler.snapshot.currentSongId, 'song-0');
        expect(handler.collectPlaybackDiagnostics()['seekEvents'], isEmpty);
        player.state = ProcessingState.buffering; // A stall.
        await handler.debugRecoverCurrentSong();

        await until(
          () =>
              handler.snapshot.currentSongId == 'song-1' &&
              !handler.snapshot.isLoading,
        );
        expect(handler.snapshot.queueSongIds, ids(6));
      },
    );

    test('a skip rebuilds a player that lost its songs', () async {
      final (handler, player, _) = await recovering(5);
      await start(handler, 5);
      // As after a timed-out reload: the rebuilt player holds nothing.
      await player.setAudioSources(const <AudioSource>[]);

      await handler.playFromIndex(3);

      await until(
        () =>
            handler.snapshot.currentSongId == 'song-3' &&
            !handler.snapshot.isLoading,
      );
      expect(handler.snapshot.queueSongIds, ids(5));
      expect(player.sourceIds, ids(5));
      expect(player.index, 3);
    });

    test('cancels a cross-fade in progress', () async {
      final (handler, player, _) = await recovering(5, crossfade: true);
      await start(handler, 5);
      await handler.debugStartCrossfade();
      expect(fade(handler)['active'], isTrue);

      player.state = ProcessingState.buffering; // A stall.
      await handler.debugRecoverCurrentSong();

      await until(
        () => player.sourceIds.length == 5 && !handler.snapshot.isLoading,
      );
      expect(fade(handler)['active'], isFalse);
      expect(identical(handler.debugActivePlayer, player), isTrue);
      expect(handler.debugInactiveDeck!.playing, isFalse);
    });
  });

  group('seek bar buffered line', () {
    late HttpServer server;
    late Completer<void> release;
    late Completer<void> more;
    late Directory directory;
    var requests = 0;

    // The server sends [first] bytes, waits for [release], then ends or, for
    // an unknown length, waits for [more] and sends [second] further bytes.
    Future<(NavisAudioHandler, ControllableAudioPlayer)> serve({
      int? length = 100 * 1024,
      int first = 40 * 1024,
      int second = 0,
      bool fail = false,
      bool sidecar = true,
      bool cacheSongs = false,
      int count = 2,
      StreamingQuality quality = const StreamingQuality(label: 'original'),
      Uint8List? payload,
      bool supportsTranscodeOffset = false,
      NavisPlaybackTimeouts timeouts = const NavisPlaybackTimeouts(),
    }) async {
      List<int> chunk(int from, int to) => payload == null
          ? List<int>.filled(to - from, 1)
          : payload.sublist(from, to);
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      requests = 0;
      release = Completer<void>();
      more = Completer<void>();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final nth = requests++;
        try {
          final response = request.response..bufferOutput = false;
          if (length != null) response.contentLength = length;
          if (nth == 0) response.add(chunk(0, first));
          await response.flush();
          if (nth != 0) return;
          if (length != null || fail) await release.future;
          if (fail) {
            await server.close(force: true);
            return;
          }
          if (length != null) {
            response.add(chunk(first, length));
          } else if (second > 0) {
            await more.future;
            response.add(chunk(first, first + second));
          }
          if (length != null) await response.close();
        } on HttpException {
          // The handler cancels the unfinished transfer.
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
      directory = await Directory.systemTemp.createTemp('navis-buffered-');
      final (handler, player, database) = await createHandler(
        directory,
        count,
        sidecarStreams: sidecar,
        cacheSongs: cacheSongs,
        readApiClient: () => api,
        streamingQuality: quality,
        supportsTranscodeOffset: supportsTranscodeOffset,
        timeouts: timeouts,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        if (!release.isCompleted) release.complete();
        if (!more.isCompleted) more.complete();
        await database.close();
        await server.close(force: true);
        await directory.delete(recursive: true);
        HttpOverrides.global = previousHttp;
      });
      return (handler, player);
    }

    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 400 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    Duration line(NavisAudioHandler handler) =>
        handler.bufferState.bufferedPosition;

    Duration fraction(NavisAudioHandler handler, double value) => Duration(
      seconds: (handler.snapshot.duration.inSeconds * value).floor(),
    );

    Future<void> startSong(NavisAudioHandler handler) async {
      await handler.replaceQueue(['song-0', 'song-1'], expandMatchFlows: false);
      await settleQueue(handler);
    }

    test('after a seek the line follows the known-length download', () async {
      final (handler, player) = await serve();
      await startSong(handler);
      player.emitBuffered(const Duration(seconds: 5));
      await until(() => line(handler) >= fraction(handler, 0.4));
      expect(handler.snapshot.duration, greaterThan(Duration.zero));
      expect(line(handler), fraction(handler, 0.4));
      expect(handler.bufferState.songId, 'song-0');
      final diagnostics = handler.collectPlaybackDiagnostics();
      expect(
        diagnostics['cachedPlayablePositionMs'],
        line(handler).inMilliseconds,
      );
      expect(diagnostics['playerBufferedPositionMs'], 5000);
    });

    test('a player buffered ahead of the download sets the line', () async {
      final (handler, player) = await serve();
      await startSong(handler);
      await until(
        () => handler.collectPlaybackDiagnostics()['cacheActivity'] != null,
      );
      player.emitBuffered(fraction(handler, 0.9));
      await pumpEventQueue();
      expect(line(handler), fraction(handler, 0.9));
    });

    test('an unknown-length transcode counts bytes at the bitrate', () async {
      final (handler, player) = await serve(
        length: null,
        first: 160000,
        second: 3000000,
        quality: const StreamingQuality(
          label: 'opus',
          maxBitRate: 128,
          format: 'opus',
        ),
      );
      await startSong(handler);
      player.emitBuffered(const Duration(seconds: 2));
      await until(() => line(handler) >= const Duration(seconds: 10));
      expect(line(handler), const Duration(seconds: 10));
      more.complete();
      await until(() => line(handler) >= handler.snapshot.duration);
      // 3 MB at 128 kbit/s is longer than the song: clamped to its duration.
      expect(line(handler), handler.snapshot.duration);
    });

    test('a file source draws the full duration', () async {
      final (handler, player) = await serve(sidecar: false, cacheSongs: true);
      await startSong(handler);
      expect(handler.queue.value[0].extras!['sourceKind'], 'file');
      player.emitBuffered(const Duration(seconds: 3));
      await pumpEventQueue();
      expect(line(handler), handler.snapshot.duration);
    });

    test('a completed sidecar download draws the full duration', () async {
      final (handler, player) = await serve();
      await startSong(handler);
      player.emitBuffered(const Duration(seconds: 3));
      release.complete();
      await until(() => line(handler) >= handler.snapshot.duration);
      expect(line(handler), handler.snapshot.duration);
    });

    test('a sidecar completed before the song became current draws the full '
        'duration', () async {
      final (handler, player) = await serve();
      await startSong(handler);
      player.emitBuffered(const Duration(seconds: 3));
      release.complete();
      await until(() => line(handler) >= handler.snapshot.duration);
      // The finished download must unregister its activity first.
      await until(
        () => handler.collectPlaybackDiagnostics()['cacheActivity'] == null,
      );
      await handler.skipToNext();
      await settleQueue(handler);
      expect(handler.bufferState.songId, 'song-1');
      await handler.skipToPrevious();
      await settleQueue(handler);
      player.emitBuffered(const Duration(seconds: 1));
      await until(() => line(handler) >= handler.snapshot.duration);
      expect(line(handler), handler.snapshot.duration);
    });

    test('a completed lock-cache download draws the full duration', () async {
      final (handler, player) = await serve(sidecar: false);
      await startSong(handler);
      final extras = handler.queue.value[0].extras!;
      expect(extras['sourceKind'], 'lockCachedStream');
      // ignore: experimental_member_use, reason: drives the lock-cache download the player would.
      final source = player.audioSources[0] as LockCachingAudioSource;
      final drained = (await source.request()).stream.drain<void>();
      await until(() => line(handler) >= fraction(handler, 0.4));
      expect(line(handler), fraction(handler, 0.4));
      release.complete();
      await drained;
      await until(() => line(handler) >= handler.snapshot.duration);
      expect(line(handler), handler.snapshot.duration);
      // The finished song's activity is gone; the line stays full.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      player.emitBuffered(const Duration(seconds: 3));
      await pumpEventQueue();
      expect(line(handler), handler.snapshot.duration);
    });

    test(
      'an exhausted sidecar download does not draw the full duration',
      () async {
        final (handler, player) = await serve(fail: true);
        await startSong(handler);
        player.emitBuffered(const Duration(seconds: 5));
        await until(() => line(handler) >= fraction(handler, 0.4));
        release.complete();
        await Future.doWhile(() async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return handler.collectPlaybackDiagnostics()['cacheActivity'] != null;
        }).timeout(const Duration(seconds: 10));
        player.emitBuffered(const Duration(seconds: 6));
        await pumpEventQueue();
        expect(line(handler), const Duration(seconds: 6));
      },
    );

    test('the previous song cache does not reach the next song', () async {
      final (handler, player) = await serve();
      await startSong(handler);
      await until(() => line(handler) >= fraction(handler, 0.4));
      await handler.skipToNext();
      await pumpEventQueue();
      expect(handler.bufferState.songId, 'song-1');
      expect(line(handler), Duration.zero);
      player.emitBuffered(const Duration(seconds: 4));
      await pumpEventQueue();
      expect(line(handler), const Duration(seconds: 4));
    });

    const opus = StreamingQuality(
      label: 'opus',
      maxBitRate: 128,
      format: 'opus',
    );

    // 20 Opus pages of about 8 kB (161 kB: 10 s at 128 kbit/s) whose last
    // granule says 90 s.
    Uint8List opusBytes() => concat([
      opusHeadPage(),
      for (var i = 0; i < 20; i++)
        oggAudioPage(48000 * 90 * (i + 1) ~/ 20 + 312, size: 8000),
    ]);

    bool partHolds(int bytes) => directory
        .listSync(recursive: true)
        .whereType<File>()
        .any((f) => f.path.contains('.part') && f.lengthSync() >= bytes);

    // The cache refreshes per chunk and per player event; keep emitting the
    // player's own value until the line shows [done].
    Future<void> drawUntil(
      ControllableAudioPlayer player,
      bool Function() done,
    ) async {
      for (var i = 0; i < 80 && !done(); i++) {
        player.emitBuffered(player.simulatedBuffered);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    int probes(NavisAudioHandler handler) =>
        handler.collectPlaybackDiagnostics()['cachedExtentProbes']! as int;

    test('an Ogg part file draws its exact time, not the estimate', () async {
      final bytes = opusBytes();
      final (handler, player) = await serve(
        length: null,
        first: bytes.length,
        payload: bytes,
        quality: opus,
      );
      await startSong(handler);
      await until(() => partHolds(bytes.length));
      await drawUntil(
        player,
        () => line(handler) >= const Duration(seconds: 90),
      );
      expect(line(handler), const Duration(seconds: 90));
      final diagnostics = handler.collectPlaybackDiagnostics();
      expect(diagnostics['cachedPlayableSource'], 'exact');
      expect(diagnostics['cachedPlayablePositionMs'], 90000);
    });

    test('a FLAC part file draws the last verified frame time', () async {
      final bytes = concat([
        flacHead(),
        for (var n = 1000; n < 1250; n++) flacFrame(n),
      ]);
      final (handler, player) = await serve(
        length: bytes.length,
        first: 40 * 1024,
        payload: bytes,
      );
      await startSong(handler);
      await until(() => partHolds(40 * 1024));
      // 1100 frames of 4096 samples at 44.1 kHz; the progress fraction
      // (40%) would say 72 s.
      await drawUntil(
        player,
        () => line(handler) >= const Duration(seconds: 100),
      );
      expect(line(handler), const Duration(seconds: 102));
      expect(
        handler.collectPlaybackDiagnostics()['cachedPlayableSource'],
        'exact',
      );
    });

    test('an unparseable part file falls back to the estimate', () async {
      final (handler, player) = await serve(
        length: null,
        first: 160000,
        quality: opus,
      );
      await startSong(handler);
      await until(() => probes(handler) >= 1);
      await drawUntil(
        player,
        () => line(handler) >= const Duration(seconds: 10),
      );
      expect(line(handler), const Duration(seconds: 10));
      expect(
        handler.collectPlaybackDiagnostics()['cachedPlayableSource'],
        'bitrate',
      );
    });

    test('chunk updates within a second start one probe', () async {
      final bytes = opusBytes();
      final (handler, player) = await serve(
        length: null,
        first: bytes.length,
        second: 1000,
        payload: concat([bytes, Uint8List(1000)]),
        quality: opus,
      );
      await startSong(handler);
      await until(() => probes(handler) >= 1);
      more.complete();
      for (var i = 0; i < 20; i++) {
        player.emitBuffered(Duration(seconds: i));
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(probes(handler), 1);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      player.emitBuffered(const Duration(seconds: 30));
      await until(() => probes(handler) >= 2);
      expect(probes(handler), 2);
    });

    test('a late probe for the previous song is ignored', () async {
      final (handler, player) = await serve(length: null, first: 160000);
      final gate = Completer<Duration?>();
      var reads = 0;
      handler.cachedExtentReader = (_) async =>
          reads++ == 0 ? gate.future : null;
      await startSong(handler);
      await until(() => probes(handler) >= 1);
      await handler.skipToNext();
      await settleQueue(handler);
      expect(handler.bufferState.songId, 'song-1');
      gate.complete(const Duration(seconds: 90));
      await pumpEventQueue();
      player.emitBuffered(const Duration(seconds: 4));
      await pumpEventQueue();
      expect(line(handler), const Duration(seconds: 4));
    });

    Future<void> seekPast(NavisAudioHandler handler, Duration to) async {
      await handler.seek(to);
      await until(() => !handler.snapshot.isLoading);
    }

    test('an offset stream draws the cached range and its own ahead', () async {
      final bytes = opusBytes();
      final (handler, player) = await serve(
        length: null,
        first: bytes.length,
        payload: bytes,
        quality: opus,
        supportsTranscodeOffset: true,
      );
      player.simulateProgress = true;
      await startSong(handler);
      await handler.play();
      await until(() => partHolds(bytes.length));
      await drawUntil(
        player,
        () => line(handler) >= const Duration(seconds: 90),
      );
      await seekPast(handler, const Duration(seconds: 120));
      expect(handler.collectPlaybackDiagnostics()['positionOffsetMs'], 120000);
      player.emitBuffered(const Duration(seconds: 150));
      await drawUntil(player, () => handler.bufferState.aheadStart != null);
      expect(line(handler), const Duration(seconds: 90));
      expect(handler.bufferState.aheadStart, const Duration(seconds: 120));
      expect(handler.bufferState.aheadEnd, const Duration(seconds: 150));
      final diagnostics = handler.collectPlaybackDiagnostics();
      expect(diagnostics['drawnAheadStartMs'], 120000);
      expect(diagnostics['drawnAheadEndMs'], 150000);
      expect(diagnostics['playerBufferedPositionMs'], 150000);
    });

    test(
      'a seek past the download starts the ahead range at its target',
      () async {
        final (handler, player) = await serve();
        player.simulateProgress = true;
        await startSong(handler);
        await handler.play();
        await until(() => line(handler) >= fraction(handler, 0.4));
        await seekPast(handler, const Duration(seconds: 150));
        player.emitBuffered(const Duration(seconds: 170));
        await pumpEventQueue();
        expect(line(handler), fraction(handler, 0.4));
        expect(handler.bufferState.aheadStart, const Duration(seconds: 150));
        expect(handler.bufferState.aheadEnd, const Duration(seconds: 170));
      },
    );

    test('a seek inside the download or no seek draws one range', () async {
      final (handler, player) = await serve();
      player.simulateProgress = true;
      await startSong(handler);
      await handler.play();
      await until(() => line(handler) >= fraction(handler, 0.4));
      player.emitBuffered(const Duration(seconds: 100));
      await pumpEventQueue();
      expect(line(handler), const Duration(seconds: 100));
      expect(handler.bufferState.aheadStart, isNull);
      await seekPast(handler, const Duration(seconds: 30));
      player.emitBuffered(const Duration(seconds: 120));
      await pumpEventQueue();
      expect(line(handler), const Duration(seconds: 120));
      expect(handler.bufferState.aheadStart, isNull);
      expect(handler.bufferState.aheadEnd, isNull);
    });

    test('a page-less Opus start still shows the estimate', () async {
      // Early in a download the last complete page is OpusTags (granule 0):
      // that is not an exact time, so the bitrate estimate stays.
      final bytes = concat([
        opusHeadPage(),
        oggPage('OpusTags'.codeUnits, granule: 0),
        oggAudioPage(-1, size: 3000),
      ]);
      final (handler, player) = await serve(
        length: null,
        first: bytes.length,
        payload: bytes,
        quality: const StreamingQuality(
          label: 'opus',
          maxBitRate: 8,
          format: 'opus',
        ),
      );
      await startSong(handler);
      await until(() => partHolds(bytes.length));
      // A probe after the whole file is on disk has run.
      await drawUntil(player, () => probes(handler) >= 2);
      await pumpEventQueue();
      expect(line(handler), const Duration(seconds: 3));
      expect(
        handler.collectPlaybackDiagnostics()['cachedPlayableSource'],
        'bitrate',
      );
    });

    test('a failed seek past the download draws no ahead range', () async {
      final (handler, player) = await serve(
        timeouts: const NavisPlaybackTimeouts(
          seekProgress: Duration(seconds: 1),
          progressIdle: Duration(milliseconds: 300),
          desktopSeekSettle: Duration(seconds: 1),
        ),
      );
      final states = <PlaybackBufferState>[];
      final subscription = handler.bufferStateStream.listen(states.add);
      addTearDown(subscription.cancel);
      await startSong(handler);
      // The seek never settles and recovery cannot reload the stream.
      player
        ..ignoreSeeks = true
        ..failLoadSongId = 'song-0';
      final seeking = handler.seek(const Duration(seconds: 150));
      player.emitBuffered(const Duration(seconds: 170));
      await pumpEventQueue();
      expect(handler.bufferState.aheadStart, const Duration(seconds: 150));
      await seeking;
      await until(
        () =>
            (handler.collectPlaybackDiagnostics()['seek']! as Map)['outcome'] ==
            'failed',
      );
      // Failover may then move to the next song; before it, the failed
      // seek's target is forgotten and the line is the player's range.
      final ahead = states.indexWhere((state) => state.aheadStart != null);
      expect(ahead, isNonNegative);
      expect(
        states
            .skip(ahead + 1)
            .any(
              (state) =>
                  state.songId == 'song-0' &&
                  state.aheadStart == null &&
                  state.bufferedPosition == const Duration(seconds: 170),
            ),
        isTrue,
      );
    });

    test(
      'a late probe for a restarted download of the same song is ignored',
      () async {
        final (handler, player) = await serve(length: null, first: 160000);
        final gate = Completer<Duration?>();
        final paths = <String>[];
        handler.cachedExtentReader = (path) async {
          paths.add(path);
          return paths.length == 1 ? gate.future : null;
        };
        await startSong(handler);
        await until(() => paths.isNotEmpty);
        // Away and back: the song's download restarts into a new part file.
        await handler.skipToNext();
        await settleQueue(handler);
        await handler.skipToPrevious();
        await settleQueue(handler);
        expect(handler.bufferState.songId, 'song-0');
        await drawUntil(player, () => paths.length >= 2);
        expect(paths.first, isNot(paths.last), reason: 'a new part file');
        gate.complete(const Duration(seconds: 90));
        await pumpEventQueue();
        player.emitBuffered(const Duration(seconds: 4));
        await pumpEventQueue();
        expect(line(handler), const Duration(seconds: 4));
        expect(
          handler.collectPlaybackDiagnostics()['cachedPlayableSource'],
          isNot('exact'),
        );
      },
    );

    // A held or slow download sends no buffer events, so the probe re-arms
    // itself while the part file grows (a shortened interval keeps these fast).
    group('trailing probe', () {
      const interval = Duration(milliseconds: 100);

      test('re-probes a growing part file without buffer events', () async {
        final (handler, _) = await serve(length: null, first: 160000);
        var reads = 0;
        handler
          ..cachedExtentInterval = interval
          ..cachedExtentReader = (_) async => Duration(seconds: 30 + reads++);
        await startSong(handler);
        await until(() => line(handler) >= const Duration(seconds: 34));
        expect(
          line(handler),
          greaterThanOrEqualTo(const Duration(seconds: 34)),
        );
        expect(probes(handler), greaterThanOrEqualTo(5));
        expect(
          handler.collectPlaybackDiagnostics()['cachedPlayableSource'],
          'exact',
        );
      });

      test(
        'stops after an unchanged streak and restarts on an event',
        () async {
          final (handler, player) = await serve(length: null, first: 160000);
          handler
            ..cachedExtentInterval = interval
            ..cachedExtentReader = (_) async => const Duration(seconds: 30);
          await startSong(handler);
          await Future<void>.delayed(const Duration(milliseconds: 900));
          final settled = probes(handler);
          expect(settled, inInclusiveRange(6, 8));
          await Future<void>.delayed(const Duration(milliseconds: 400));
          expect(probes(handler), settled);
          expect(handler.cachedExtentTimerActive, isFalse);
          player.emitBuffered(const Duration(seconds: 3));
          await until(() => probes(handler) > settled);
          expect(probes(handler), settled + 1);
        },
      );

      // A long interval keeps an armed timer visibly pending.
      Future<NavisAudioHandler> armed({
        int? length,
        int first = 160000,
        FutureOr<Duration?> Function(String path)? after,
      }) async {
        final (handler, _) = await serve(length: length, first: first);
        var reads = 0;
        handler
          ..cachedExtentInterval = const Duration(seconds: 5)
          ..cachedExtentReader = (path) => reads++ == 0
              ? Future.value(const Duration(seconds: 10))
              : Future.value(after?.call(path));
        await startSong(handler);
        await until(() => handler.cachedExtentTimerActive);
        expect(handler.cachedExtentTimerActive, isTrue);
        return handler;
      }

      test('a song change cancels the timer', () async {
        final handler = await armed(
          after: (_) => Completer<Duration?>().future,
        );
        await handler.skipToNext();
        await settleQueue(handler);
        expect(handler.bufferState.songId, 'song-1');
        // The next song's probe never returns, so only a leftover timer of
        // the previous song could still be pending.
        await until(() => probes(handler) >= 2);
        expect(handler.cachedExtentTimerActive, isFalse);
      });

      test('cache completion cancels the timer', () async {
        final handler = await armed(length: 100 * 1024, first: 40 * 1024);
        release.complete();
        await until(() => !handler.cachedExtentTimerActive);
        expect(handler.cachedExtentTimerActive, isFalse);
        expect(line(handler), handler.snapshot.duration);
      });

      test('dispose cancels the timer', () async {
        final handler = await armed();
        await handler.disposeHandler();
        expect(handler.cachedExtentTimerActive, isFalse);
      });
    });

    test('a Repeat One loop clears the ahead range start', () async {
      final (handler, player) = await serve();
      player.simulateProgress = true;
      await startSong(handler);
      await handler.play();
      await until(() => line(handler) >= fraction(handler, 0.4));
      await seekPast(handler, const Duration(seconds: 150));
      player.emitBuffered(const Duration(seconds: 170));
      await pumpEventQueue();
      expect(handler.bufferState.aheadStart, const Duration(seconds: 150));
      player.discontinuityEvents.add(
        PositionDiscontinuity(
          PositionDiscontinuityReason.autoAdvance,
          PlaybackEvent(
            processingState: ProcessingState.ready,
            updatePosition: const Duration(seconds: 175),
            currentIndex: 0,
          ),
          player.playbackEvent,
        ),
      );
      await pumpEventQueue();
      expect(handler.bufferState.aheadStart, isNull);
      expect(line(handler), const Duration(seconds: 170));
    });

    test('the download catching up to the ahead range merges them', () async {
      final (handler, player) = await serve();
      player.simulateProgress = true;
      await startSong(handler);
      await handler.play();
      await until(() => line(handler) >= fraction(handler, 0.4));
      await seekPast(handler, const Duration(seconds: 150));
      player.emitBuffered(const Duration(seconds: 170));
      await pumpEventQueue();
      expect(handler.bufferState.aheadStart, const Duration(seconds: 150));
      release.complete();
      await until(() => line(handler) >= handler.snapshot.duration);
      expect(line(handler), handler.snapshot.duration);
      expect(handler.bufferState.aheadStart, isNull);
    });

    test('radio draws no line', () async {
      final (handler, player) = await serve(cacheSongs: true, sidecar: false);
      await handler.playRadioStream(
        stationId: 'fixture',
        stationName: 'Fixture',
        streamUrl: 'https://radio.example.invalid/live',
      );
      player.emitBuffered(const Duration(seconds: 10));
      await pumpEventQueue();
      expect(handler.bufferState.songId, isNull);
      expect(line(handler), Duration.zero);
    });
  });

  // #374: Play on a finished queue must restart it at song 0. The fake's
  // seek flips `completed` to `ready` before it emits, which hides the bug.
  // On Android (ExoPlayer; a2-r4b transport trace seq 523-532) the seek to
  // index 0 is first reported as `completed` at index 0, position 0, and only
  // then as `buffering`.
  group('Play on a completed queue (#374)', () {
    Future<(NavisAudioHandler, ControllableAudioPlayer)> finished({
      int count = 2,
      bool desktop = false,
      NavisQueueWindow queueWindow = const NavisQueueWindow(),
      bool shuffle = false,
      // Songs queued out of the [count] in the library.
      int? queued,
    }) async {
      final directory = await Directory.systemTemp.createTemp('navis-i374-');
      final (handler, player, database) = await createHandler(
        directory,
        count,
        desktopRuntimeOverride: desktop,
        queueWindow: queueWindow,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      final length = queued ?? count;
      final ids = [for (var i = 0; i < length; i++) 'song-$i'];
      await handler.replaceQueue(
        ids,
        startIndex: shuffle ? 0 : length - 1,
        expandMatchFlows: false,
      );
      await settleQueue(handler);
      if (shuffle) {
        await handler.setShuffleMode(AudioServiceShuffleMode.all);
        await settleQueue(handler);
      }
      await handler.play();
      await pumpEventQueue();
      player
        ..isPlaying = true
        ..state = ProcessingState.ready;
      if (queueWindow.deferThreshold ==
          const NavisQueueWindow().deferThreshold) {
        for (
          var i = 0;
          i < length && player.state != ProcessingState.completed;
          i++
        ) {
          player.finishCurrentTrack();
          await pumpEventQueue();
        }
      } else {
        // The player holds only the window around the last song.
        player
          ..index = player.sourceIds.length - 1
          ..state = ProcessingState.completed;
        player.playbackEvents.add(player.playbackEvent);
      }
      await pumpEventQueue();
      expect(player.state, ProcessingState.completed);
      return (handler, player);
    }

    Future<void> settle() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await pumpEventQueue();
    }

    // Control: the ready order never showed the bug; it pins the behaviour.
    test(
      'restarts at song 0 when the seek is reported as ready (control)',
      () async {
        final (handler, player) = await finished();
        final seeksBefore = player.seekCalls;
        await handler.play();
        await settle();

        expect(handler.snapshot.currentSongId, 'song-0');
        expect(player.index, 0);
        expect(player.seekCalls - seeksBefore, 1);
      },
    );

    // a: the stale `completed` arrives while the seek is in flight; b: after
    // the seek future has resolved.
    for (final late in [false, true]) {
      test('restarts at song 0 when the seek is first reported as completed '
          '${late ? 'after seek returned' : 'during the seek'}', () async {
        final (handler, player) = await finished();
        player
          ..exoEndedSeek = !late
          ..exoEndedSeekLate = late;
        final seeksBefore = player.seekCalls;
        await handler.play();
        await settle();

        expect(handler.snapshot.currentSongId, 'song-0');
        expect(player.index, 0);
        expect(
          player.seekCalls - seeksBefore,
          1,
          reason: 'only the restart seek; a second one is the failover',
        );
      });
    }

    // c: song 0 then plays to its end and the queue moves on.
    for (final desktop in [false, true]) {
      test('song 0 plays on to song 1 after the restart '
          '(${desktop ? 'media_kit order' : 'Android order'})', () async {
        final (handler, player) = await finished(count: 3, desktop: desktop);
        player
          ..exoEndedSeekLate = !desktop
          // Conservative model: real media_kit goes buffering -> ready on a
          // different-index restart (Linux runtime check, #374), so it never
          // stays `completed` there.
          ..completedStaysOnSeek = desktop;
        await handler.play();
        await settle();
        expect(handler.snapshot.currentSongId, 'song-0');
        if (desktop) {
          // Still `completed` at index 0, now at the song's end: the stale
          // note must not hide this real end.
          player.simulatedPosition = player.simulatedDuration;
          player.playbackEvents.add(player.playbackEvent);
        } else {
          player.simulatedPosition = const Duration(seconds: 5);
          player.playbackEvents.add(player.playbackEvent);
          await settle();
          expect(handler.snapshot.currentSongId, 'song-0');
          player.finishCurrentTrack();
        }
        await settle();

        expect(handler.snapshot.currentSongId, 'song-1');
        expect(player.index, 1);
      });
    }

    // d: a genuine premature end of song 0 right after the restart still
    // runs the skip-past-failed-song recovery.
    test('song 0 ending early after the restart is still skipped', () async {
      final (handler, player) = await finished(count: 3);
      player.exoEndedSeekLate = true;
      await handler.play();
      await settle();
      expect(handler.snapshot.currentSongId, 'song-0');
      player
        ..exoEndedSeekLate = false
        ..simulatedPosition = const Duration(seconds: 2)
        ..state = ProcessingState.completed;
      player.playbackEvents.add(player.playbackEvent);
      await settle();

      expect(handler.snapshot.currentSongId, 'song-1');
    });

    // e: the shuffle and deferred-head restarts land on their own target.
    test('a shuffled queue restarts at the new pass start', () async {
      final (handler, player) = await finished(count: 4, shuffle: true);
      player.exoEndedSeekLate = true;
      final finishedSong = handler.snapshot.currentSongId;
      await handler.play();
      await settle();

      expect(handler.snapshot.currentIndex, 0);
      expect(handler.snapshot.currentSongId, isNot(finishedSong));
      expect(player.index, 0);
    });

    // Control: the deferred-head restart reloads the window through
    // playFromIndex(0), not `_seekPlayerToIndex`, so no echo reaches it.
    test('a queue with a deferred head restarts at song 0 (control)', () async {
      const window = NavisQueueWindow(
        deferThreshold: 16,
        ahead: 8,
        lowWater: 3,
        page: 8,
        nearJump: 16,
      );
      final (handler, player) = await finished(count: 60, queueWindow: window);
      expect(
        handler.collectPlaybackDiagnostics()['deferredHeadLength'],
        greaterThan(0),
      );
      player
        ..exoEndedSeek = true
        ..exoEndedSeekLate = true;
      await handler.play();
      await settle();

      expect(handler.snapshot.currentSongId, 'song-0');
      expect(handler.snapshot.currentIndex, 0);
    });

    // f: the other seeks out of a finished queue.
    for (final late in [false, true]) {
      test('Play from index 0 on a finished queue stays on song 0 '
          '(${late ? 'late echo' : 'in-seek echo, behaviour pin'})', () async {
        final (handler, player) = await finished(count: 3);
        player
          ..exoEndedSeek = !late
          ..exoEndedSeekLate = late;
        await handler.playFromIndex(0);
        await settle();

        expect(handler.snapshot.currentSongId, 'song-0');
        expect(player.index, 0);
      });

      test('Previous on a finished queue lands on the previous song '
          '(${late ? 'late echo' : 'in-seek echo, behaviour pin'})', () async {
        final (handler, player) = await finished(count: 3);
        // Within the first seconds Previous goes to the earlier song.
        player
          ..simulatedPosition = const Duration(seconds: 1)
          ..exoEndedSeek = !late
          ..exoEndedSeekLate = late;
        await handler.skipToPrevious();
        await settle();

        expect(handler.snapshot.currentSongId, 'song-1');
        expect(player.index, 1);
      });
    }

    // A song added to a finished queue resumes at the new song
    // (_resumeInsertedItemIfCompleted); more songs follow it, so a stale
    // `completed` there reads as that song ending early.
    for (final late in [false, true]) {
      test('Play Next on a finished queue resumes at the inserted song '
          '(${late ? 'late' : 'in-seek'} echo)', () async {
        final (handler, player) = await finished(count: 4, queued: 2);
        player
          ..exoEndedSeek = !late
          ..exoEndedSeekLate = late;
        await handler.playNext(['song-2', 'song-3'], expandMatchFlows: false);
        await settle();

        expect(handler.snapshot.currentSongId, 'song-2');
        expect(player.index, 2);
      });
    }

    test('Play on a finished one-song queue restarts it (late echo, behaviour pin)', () async {
      final (handler, player) = await finished(count: 1);
      player.exoEndedSeekLate = true;
      final seeksBefore = player.seekCalls;
      await handler.play();
      await settle();

      expect(handler.snapshot.currentSongId, 'song-0');
      expect(player.index, 0);
      expect(player.seekCalls - seeksBefore, 1);
      expect(player.state, ProcessingState.ready);
      expect(handler.snapshot.playing, isTrue);
    });
  });
  // #509: media_kit reports a seek's new index a moment after `seek` returned,
  // so a skip read the old index, called that a failed seek and rebuilt the
  // whole queue in a new player. Native shuffle stays off in Navis (the queue
  // is shuffled in Dart), so no native shuffle order is involved here.
  group('a skip whose index lands after the seek returned (#509)', () {
    const lag = Duration(milliseconds: 60);

    Future<(NavisAudioHandler, ControllableAudioPlayer)> laggedQueue({
      int count = 4,
      int startIndex = 0,
      bool crossfade = false,
      bool desktop = true,
    }) async {
      final directory = await Directory.systemTemp.createTemp('navis-i509-');
      final (handler, player, database) = await createHandler(
        directory,
        count,
        crossfade: crossfade,
        desktopRuntimeOverride: desktop,
      );
      addTearDown(() async {
        await handler.disposeHandler();
        await database.close();
        await directory.delete(recursive: true);
      });
      await handler.replaceQueueWithData(
        await database.libraryDao.getSongsByIds([
          for (var i = 0; i < count; i++) 'song-$i',
        ]),
        startIndex: startIndex,
      );
      await settleQueue(handler);
      await handler.play();
      await settleQueue(handler);
      player.seekIndexLag = lag;
      return (handler, player);
    }

    void expectPlainJump(
      NavisAudioHandler handler,
      ControllableAudioPlayer player, {
      required int stops,
      required int loads,
      required int target,
    }) {
      expect(player.stopCalls, stops, reason: 'no stop');
      expect(player.setAudioSourcesCounts, hasLength(loads), reason: 'reload');
      expect(player.index, target);
      expect(handler.snapshot.currentIndex, target);
      expect(handler.snapshot.currentSongId, 'song-$target');
      expect(handler.snapshot.isLoading, isFalse);
    }

    for (final (name, startIndex, target, action)
        in <(String, int, int, Future<void> Function(NavisAudioHandler))>[
          ('skipToNext', 0, 1, (h) => h.skipToNext()),
          ('skipToPrevious', 2, 1, (h) => h.skipToPrevious()),
          ('skipToQueueItem', 0, 3, (h) => h.skipToQueueItem(3)),
        ]) {
      for (final crossfade in [false, true]) {
        test(
          '$name is a plain jump${crossfade ? ' with crossfade on' : ''}',
          () async {
            final (handler, player) = await laggedQueue(
              startIndex: startIndex,
              crossfade: crossfade,
            );
            final stops = player.stopCalls;
            final loads = player.setAudioSourcesCounts.length;
            await action(handler);
            await settleQueue(handler);

            expectPlainJump(
              handler,
              player,
              stops: stops,
              loads: loads,
              target: target,
            );
            expect(handler.snapshot.playing, isTrue);
          },
        );
      }
    }

    test('repeat-all wraps from the last song with a plain jump', () async {
      final (handler, player) = await laggedQueue(startIndex: 3);
      await handler.setRepeatMode(AudioServiceRepeatMode.all);
      await settleQueue(handler);
      final stops = player.stopCalls;
      final loads = player.setAudioSourcesCounts.length;
      await handler.skipToNext();
      await settleQueue(handler);

      expectPlainJump(handler, player, stops: stops, loads: loads, target: 0);
    });

    test('a rapid double skip ends on the second target', () async {
      final (handler, player) = await laggedQueue();
      final stops = player.stopCalls;
      final loads = player.setAudioSourcesCounts.length;
      final started = DateTime.now();
      await Future.wait([handler.skipToNext(), handler.skipToNext()]);
      await settleQueue(handler);
      expect(player.stopCalls, stops);
      expect(player.setAudioSourcesCounts, hasLength(loads));

      expect(handler.snapshot.currentSongId, 'song-2');
      expect(player.index, 2);
      expect(handler.snapshot.isLoading, isFalse);
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 3)),
        reason: 'the wait must not hold the queue lane for its full bound',
      );
    });

    test(
      'an index that never lands still reloads after a bounded wait',
      () async {
        final (handler, player) = await laggedQueue();
        player.seekIndexNeverLands = true;
        final loads = player.setAudioSourcesCounts.length;
        final started = DateTime.now();
        await handler.skipToNext();
        await settleQueue(handler);

        expect(player.setAudioSourcesCounts, hasLength(loads + 1));
        expect(player.stopCalls, greaterThan(0));
        expect(player.index, 1);
        expect(handler.snapshot.currentSongId, 'song-1');
        expect(
          DateTime.now().difference(started),
          lessThan(const Duration(seconds: 3)),
          reason: 'bounded well under the 4 s control timeout',
        );
      },
    );

    for (final late in [false, true]) {
      test('Play on a finished queue restarts at song 0 with a lagging index '
          '${late ? '(late echo)' : '(control)'}', () async {
        final (handler, player) = await laggedQueue(count: 2, startIndex: 1);
        player.finishCurrentTrack();
        await pumpEventQueue();
        expect(player.state, ProcessingState.completed);
        player.exoEndedSeekLate = late;
        final seeks = player.seekCalls;
        final loads = player.setAudioSourcesCounts.length;
        await handler.play();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await settleQueue(handler);

        expect(handler.snapshot.currentSongId, 'song-0');
        expect(player.index, 0);
        expect(player.seekCalls - seeks, 1);
        expect(player.setAudioSourcesCounts, hasLength(loads));
      });
    }

    test('Previous on a finished queue lands on the previous song with a '
        'lagging index', () async {
      final (handler, player) = await laggedQueue(count: 3, startIndex: 2);
      player.finishCurrentTrack();
      await pumpEventQueue();
      player.simulatedPosition = const Duration(seconds: 1);
      await handler.skipToPrevious();
      await settleQueue(handler);

      expect(handler.snapshot.currentSongId, 'song-1');
      expect(player.index, 1);
    });
  });
}
