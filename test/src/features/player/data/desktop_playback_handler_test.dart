import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/player/data/linux_mpris_bridge.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/windows_smtc_bridge.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';

class _Delegate extends Mock implements NavisAudioHandler;

class _WindowsBridge extends Mock implements WindowsSmtcBridge;

class _LinuxBridge extends Mock implements LinuxMprisBridge;

void main() {
  for (final windows in [false, true]) {
    group(windows ? 'Windows wrapper' : 'Linux wrapper', () {
      late _Delegate delegate;
      late NavisPlaybackHandler wrapper;
      late Future<void> Function() disposeBridge;

      setUp(() {
        delegate = _Delegate();
        if (windows) {
          final bridge = _WindowsBridge();
          disposeBridge = bridge.dispose;
          wrapper = WindowsNavisPlaybackHandler.forTesting(
            delegate,
            bridge: bridge,
          );
        } else {
          final bridge = _LinuxBridge();
          disposeBridge = bridge.dispose;
          wrapper = LinuxNavisPlaybackHandler.forTesting(
            delegate,
            bridge: bridge,
          );
        }
      });

      test('preserves value and stream identity', () {
        const snapshot = PlaybackSnapshot.idle();
        final item = MediaItem(id: 'song', title: 'Song');
        const snapshots = Stream<PlaybackSnapshot>.empty();
        const positions = Stream<Duration>.empty();
        const cues = Stream<TransportVisualCue>.empty();
        const buffers = Stream<PlaybackBufferState>.empty();
        const items = Stream<MediaItem?>.empty();
        const failures = Stream<PlaybackLoadFailure>.empty();
        const dropped = Stream<QueueSongsDropped>.empty();
        const radioErrors = Stream<void>.empty();
        const adjustments = Stream<PlaybackAdjustments>.empty();
        const equalizer = Stream<EqApplicationState>.empty();
        when(() => delegate.snapshot).thenReturn(snapshot);
        when(() => delegate.currentMediaItem).thenReturn(item);
        when(() => delegate.snapshotStream).thenAnswer((_) => snapshots);
        when(() => delegate.positionStream).thenAnswer((_) => positions);
        when(() => delegate.transportVisualCueStream).thenAnswer((_) => cues);
        when(() => delegate.bufferStateStream).thenAnswer((_) => buffers);
        when(() => delegate.mediaItemStream).thenAnswer((_) => items);
        when(() => delegate.loadFailureStream).thenAnswer((_) => failures);
        when(() => delegate.droppedSongsStream).thenAnswer((_) => dropped);
        when(() => delegate.radioStreamErrorStream)
            .thenAnswer((_) => radioErrors);
        when(() => delegate.playbackAdjustmentsStream)
            .thenAnswer((_) => adjustments);
        when(() => delegate.equalizerStateStream).thenAnswer((_) => equalizer);

        expect(wrapper.snapshot, same(snapshot));
        expect(wrapper.currentMediaItem, same(item));
        expect(wrapper.snapshotStream, same(snapshots));
        expect(wrapper.positionStream, same(positions));
        expect(wrapper.transportVisualCueStream, same(cues));
        expect(wrapper.bufferStateStream, same(buffers));
        expect(wrapper.mediaItemStream, same(items));
        expect(wrapper.loadFailureStream, same(failures));
        expect(wrapper.droppedSongsStream, same(dropped));
        expect(wrapper.radioStreamErrorStream, same(radioErrors));
        expect(wrapper.playbackAdjustmentsStream, same(adjustments));
        expect(wrapper.equalizerStateStream, same(equalizer));
      });

      test(
        'forwards defaults, arguments, telemetry and batch results',
        () async {
          final ids = ['song'];
          final rows = <SongsTableData>[];
          final runs = <QueueInsertRun>[];
          final random = Random(3);
          const result = QueueBatchEditResult(skippedSongIds: ['unavailable']);
          when(() => delegate.replaceQueue(ids)).thenAnswer((_) async {});
          when(
            () => delegate.replaceQueueWithData(
              rows,
              startIndex: 2,
              autoPlay: false,
              expandMatchFlows: false,
            ),
          ).thenAnswer((_) async {});
          when(() => delegate.addToQueue(ids)).thenAnswer((_) async {});
          when(() => delegate.seek(const Duration(seconds: 12)))
              .thenAnswer((_) async {});
          when(() => delegate.beginPlaybackSelection('song', isExternal: true))
              .thenReturn(9);
          when(() => delegate.isPlaybackSelectionCurrent(9)).thenReturn(true);
          when(
            () =>
                delegate.mergeIntoUpcoming(rows, notBefore: 4, random: random),
          ).thenAnswer((_) async => result);
          when(() => delegate.insertQueueRuns(runs))
              .thenAnswer((_) async => result);

          await wrapper.replaceQueue(ids);
          await wrapper.replaceQueueWithData(
            rows,
            startIndex: 2,
            autoPlay: false,
            expandMatchFlows: false,
          );
          await wrapper.addToQueue(ids);
          await wrapper.seek(const Duration(seconds: 12));
          final observer = wrapper as PlaybackStartupObserver;
          expect(observer.beginPlaybackSelection('song', isExternal: true), 9);
          observer.notePlaybackSelectionStage(9, 'selected');
          expect(observer.isPlaybackSelectionCurrent(9), isTrue);
          final editor = wrapper as QueueBatchEditor;
          expect(
            await editor.mergeIntoUpcoming(rows, notBefore: 4, random: random),
            same(result),
          );
          expect(await editor.insertQueueRuns(runs), same(result));
          wrapper.updateRadioMetadata(title: 'Title', replaceMetadata: true);
          Future<void> callback(String _) async {}
          wrapper.registerPreferredMixCallback(callback);
          wrapper.registerPreferredMixToggleCallback(callback);

          verify(() => delegate.replaceQueue(ids)).called(1);
          verify(
            () => delegate.replaceQueueWithData(
              rows,
              startIndex: 2,
              autoPlay: false,
              expandMatchFlows: false,
            ),
          ).called(1);
          verify(() => delegate.addToQueue(ids)).called(1);
          verify(() => delegate.seek(const Duration(seconds: 12))).called(1);
          verify(() => delegate.notePlaybackSelectionStage(9, 'selected'))
              .called(1);
          verify(
            () =>
                delegate.mergeIntoUpcoming(rows, notBefore: 4, random: random),
          ).called(1);
          verify(() => delegate.insertQueueRuns(runs)).called(1);
          verify(
            () => delegate.updateRadioMetadata(
              title: 'Title',
              replaceMetadata: true,
            ),
          ).called(1);
          verify(() => delegate.registerPreferredMixCallback(callback))
              .called(1);
          verify(() => delegate.registerPreferredMixToggleCallback(callback))
              .called(1);
        },
      );

      test(
        'begins delegate teardown immediately and awaits bridge before handler',
        () async {
          final events = <String>[];
          final bridgeDone = Completer<void>();
          when(delegate.beginTeardown).thenAnswer((_) => events.add('begin'));
          when(disposeBridge).thenAnswer((_) {
            events.add('bridge');
            return bridgeDone.future;
          });
          when(delegate.disposeHandler).thenAnswer((_) async {
            events.add('handler');
          });

          beginNavisPlaybackHandlerTeardown(wrapper);
          expect(events, ['begin', 'bridge']);
          final disposed = disposeNavisPlaybackHandler(wrapper);
          expect(events, ['begin', 'bridge', 'bridge']);
          await pumpEventQueue();
          expect(events, isNot(contains('handler')));
          bridgeDone.complete();
          await disposed;
          expect(events.last, 'handler');
          verify(delegate.beginTeardown).called(1);
          verify(delegate.disposeHandler).called(1);
        },
      );
    });
  }
}
