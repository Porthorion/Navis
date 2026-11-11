import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/semantics.dart'
    show CustomSemanticsAction, SemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/marquee_text.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/queue_screen.dart';
import 'package:navis/src/features/player/presentation/queue_sheet.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/routing/desktop_layout.dart';

import '../../../../helpers/test_database.dart';

class _QueueSpyController extends QueueController {
  new(this.ids);

  final List<String> ids;
  int removeCalls = 0;
  int playCalls = 0;
  final reorderCalls = <(int, int)>[];

  @override
  List<String> build() => ids;

  @override
  Future<void> reorder(int oldIndex, int newIndex) async {
    reorderCalls.add((oldIndex, newIndex));
  }

  @override
  Future<QueueRemoval?> removeForUndo(int index, String songId) async {
    removeCalls++;
    return null;
  }

  @override
  Future<void> playFromIndex(int index) async {
    playCalls++;
  }
}

const _pendingSnapshot = PlaybackSnapshot(
  queueSongIds: <String>['song-1', 'song-2', 'song-3'],
  currentSongId: 'song-2',
  currentIndex: 1,
  playing: true,
  processingState: AudioProcessingState.loading,
  position: Duration.zero,
  duration: Duration(minutes: 3),
  bufferedPosition: Duration.zero,
  shuffleMode: AudioServiceShuffleMode.none,
  repeatMode: AudioServiceRepeatMode.none,
  isLoading: true,
  hasPendingLogicalQueue: true,
  loadingSongId: 'song-2',
);

SongsTableData _song(String id, String title, {bool isExternal = false}) {
  return SongsTableData(
    isProvisional: false,
    isExternal: isExternal,
    id: id,
    title: title,
    albumId: 'album',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 180,
  );
}

Future<_QueueSpyController> _pumpQueueSheet(
  WidgetTester tester, {
  required PlaybackSnapshot snapshot,
  Set<String> externalSongIds = const <String>{},
  Set<String> missingSongIds = const <String>{},
  Set<String> failedSongIds = const <String>{},
  TextScaler? textScaler,
}) async {
  final queueSpy = _QueueSpyController(snapshot.queueSongIds);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playerStateProvider.overrideWithValue(snapshot),
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
        queueProvider.overrideWith(() => queueSpy),
        songByIdProvider.overrideWith(
          (ref, songId) => failedSongIds.contains(songId)
              ? Stream<SongsTableData?>.error(
                  StateError('Local metadata lookup failed.'),
                )
              : Stream.value(
                  missingSongIds.contains(songId)
                      ? null
                      : _song(
                          songId,
                          'Track $songId',
                          isExternal: externalSongIds.contains(songId),
                        ),
                ),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: textScaler == null
            ? null
            : (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                child: child!,
              ),
        home: Scaffold(body: QueueSheet(scrollController: ScrollController())),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return queueSpy;
}

void main() {
  for (final (oldIndex, itemIndex, insertionIndex) in [
    (0, 2, 3),
    (2, 0, 0),
    (1, 1, 1),
  ]) {
    testWidgets(
      'queue item move $oldIndex to $itemIndex preserves handler indices',
      (tester) async {
        final queue = await _pumpQueueSheet(
          tester,
          snapshot: _pendingSnapshot.copyWith(
            isLoading: false,
            hasPendingLogicalQueue: false,
            processingState: AudioProcessingState.ready,
          ),
        );
        final list = tester.widget<ReorderableListView>(
          find.byType(ReorderableListView),
        );
        list.onReorderItem!(oldIndex, itemIndex);
        await tester.pump();
        expect(queue.reorderCalls, [(oldIndex, insertionIndex)]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Queue close action has an explicit platform label', (
    tester,
  ) async {
    await _pumpQueueSheet(
      tester,
      snapshot: const PlaybackSnapshot(
        queueSongIds: <String>[],
        currentSongId: null,
        currentIndex: null,
        playing: false,
        processingState: AudioProcessingState.ready,
        position: Duration.zero,
        duration: Duration.zero,
        bufferedPosition: Duration.zero,
        shuffleMode: AudioServiceShuffleMode.none,
        repeatMode: AudioServiceRepeatMode.none,
      ),
    );

    expect(find.byTooltip('Close'), findsOneWidget);
  });

  testWidgets('duplicate song IDs mark only the current queue occurrence', (
    tester,
  ) async {
    await _pumpQueueSheet(
      tester,
      snapshot: const PlaybackSnapshot(
        queueSongIds: <String>['song-1', 'song-1', 'song-2'],
        currentSongId: 'song-1',
        currentIndex: 1,
        playing: false,
        processingState: AudioProcessingState.ready,
        position: Duration.zero,
        duration: Duration(minutes: 3),
        bufferedPosition: Duration.zero,
        shuffleMode: AudioServiceShuffleMode.none,
        repeatMode: AudioServiceRepeatMode.none,
      ),
    );

    final selectedTiles = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .where((tile) => tile.selected);
    expect(selectedTiles, hasLength(1));
    expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
  });

  testWidgets('pending logical queue disables item actions while visible', (
    tester,
  ) async {
    final queueSpy = await _pumpQueueSheet(tester, snapshot: _pendingSnapshot);

    expect(find.text('Track song-1'), findsOneWidget);
    expect(find.text('Track song-2'), findsOneWidget);
    expect(find.text('Track song-3'), findsOneWidget);
    expect(find.byType(ReorderableDragStartListener), findsNothing);

    await tester.tap(find.text('Track song-2'));
    await tester.drag(find.text('Track song-3'), const Offset(-300, 0));
    await tester.pump(const Duration(seconds: 1));

    expect(queueSpy.playCalls, 0);
    expect(queueSpy.removeCalls, 0);
  });

  testWidgets('queue chrome badges only external songs', (tester) async {
    await _pumpQueueSheet(
      tester,
      snapshot: _pendingSnapshot,
      externalSongIds: const <String>{'song-2'},
    );

    expect(find.byKey(RemoteSourceIndicator.semanticsKey), findsOneWidget);
  });

  testWidgets('missing queued tracks explain availability without raw IDs', (
    tester,
  ) async {
    await _pumpQueueSheet(
      tester,
      snapshot: const PlaybackSnapshot(
        queueSongIds: <String>['missing-song'],
        currentSongId: 'missing-song',
        currentIndex: 0,
        playing: false,
        processingState: AudioProcessingState.ready,
        position: Duration.zero,
        duration: Duration.zero,
        bufferedPosition: Duration.zero,
        shuffleMode: AudioServiceShuffleMode.none,
        repeatMode: AudioServiceRepeatMode.none,
      ),
      missingSongIds: const <String>{'missing-song'},
    );

    expect(find.text('Unknown track'), findsOneWidget);
    expect(
      find.text('This track is no longer available in your library.'),
      findsOneWidget,
    );
    expect(find.textContaining('ID:'), findsNothing);
  });

  testWidgets('queue load errors use safe recovery copy and allow removal', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final queueSpy = await _pumpQueueSheet(
      tester,
      snapshot: const PlaybackSnapshot(
        queueSongIds: <String>['failed-song'],
        currentSongId: 'failed-song',
        currentIndex: 0,
        playing: false,
        processingState: AudioProcessingState.ready,
        position: Duration.zero,
        duration: Duration.zero,
        bufferedPosition: Duration.zero,
        shuffleMode: AudioServiceShuffleMode.none,
        repeatMode: AudioServiceRepeatMode.none,
      ),
      failedSongIds: const <String>{'failed-song'},
    );

    expect(find.text('Error loading track'), findsOneWidget);
    expect(
      find.text(
        "This track couldn't be loaded. You can remove it from the queue or try again later.",
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Local metadata lookup failed'), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump(const Duration(milliseconds: 100));

    expect(queueSpy.removeCalls, 1);
    await expectLater(
      find.byType(QueueSheet),
      matchesGoldenFile('goldens/queue_sheet_load_error_after.png'),
    );
  });

  testWidgets('phone Queue remains usable at 200 percent text scale', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await _pumpQueueSheet(
      tester,
      snapshot: _pendingSnapshot,
      textScaler: const TextScaler.linear(2),
    );

    expect(find.text('Track song-1'), findsOneWidget);
    expect(find.text('Track song-2'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(QueueSheet),
      matchesGoldenFile('goldens/queue_sheet_text_scale_200.png'),
    );
  });

  group('row layout', () {
    final longId = 'a-long-title-${'word ' * 40}';

    List<double> heights(WidgetTester tester) => [
      for (final tile in find.byType(ListTile).evaluate())
        tester.getSize(find.byWidget(tile.widget)).height,
    ];

    testWidgets('phone rows have uniform height and a two-line w600 title', (
      tester,
    ) async {
      await _pumpRemovable(tester, ids: ['a', longId, 'c']);

      final rows = heights(tester);
      expect(rows, [72.0, 72.0, 72.0]);
      final title = tester.widget<MarqueeText>(find.byType(MarqueeText).at(1));
      expect(title.maxLines, 2);
      expect(title.active, isFalse);
      expect(title.style.fontWeight, FontWeight.w600);
      expect(tester.takeException(), isNull);
    });

    for (final scale in [1.3, 2.0]) {
      testWidgets('phone rows stay uniform at text scale $scale', (
        tester,
      ) async {
        await _pumpRemovable(tester, ids: ['a', longId, 'c'], textScale: scale);
        final rows = heights(tester);
        expect(rows.toSet(), hasLength(1), reason: '$rows');
        expect(rows.first, greaterThan(72));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('phone rows fit 360 dp wide', (tester) async {
      await _pumpRemovable(tester, ids: ['a', longId], width: 360);
      expect(heights(tester).toSet(), hasLength(1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('disabled phone rows dim the title like the artist line', (
      tester,
    ) async {
      await _pumpRemovable(tester, pendingLogicalQueue: true);
      final title = tester.widget<MarqueeText>(find.byType(MarqueeText).at(1));
      expect(title.style.color?.a, closeTo(0.38, 0.01));
    });

    testWidgets('desktop queue rows are unchanged', (tester) async {
      await _pumpRemovable(tester, ids: ['a', longId, 'c'], desktop: true);

      expect(find.byType(MarqueeText), findsNothing);
      final title = tester.widget<Text>(find.text('Track a'));
      expect(title.maxLines, isNull);
      expect(title.style?.fontWeight, FontWeight.bold);
    });
  });

  group('swipe to remove', () {
    testWidgets('a release below 45 percent without a fling keeps the row', (
      tester,
    ) async {
      final h = await _pumpRemovable(tester);
      final g = await tester.startGesture(
        tester.getCenter(find.text('Track a')),
      );
      await g.moveBy(const Offset(-20, 0));
      await g.moveBy(const Offset(-136, 0));
      // Wait so the release carries no fling velocity.
      await tester.pump(const Duration(milliseconds: 500));
      await g.up();
      await tester.pumpAndSettle();

      expect(h.removed, isEmpty);
      expect(find.text('Track a'), findsOneWidget);
      await h.end(tester);
    });

    testWidgets('a fast fling below 45 percent removes the row', (
      tester,
    ) async {
      final h = await _pumpRemovable(tester);
      await tester.fling(find.text('Track a'), const Offset(-150, 0), 2000);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(h.removed, [0]);
      expect(find.text('Track a'), findsNothing);
      await h.end(tester);
    });

    testWidgets('past 45 percent removes once and shows Undo for 5 s', (
      tester,
    ) async {
      final h = await _pumpRemovable(tester);
      await tester.drag(find.text('Track b'), const Offset(-300, 0));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(h.removed, [1]);
      expect(find.text('Track b'), findsNothing);
      expect(find.text('Removed “Track b”'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('Undo'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Undo'), findsNothing);
      await h.end(tester);
    });

    testWidgets('Undo re-inserts at the original index', (tester) async {
      final h = await _pumpRemovable(tester, database: true);
      await tester.drag(find.text('Track b'), const Offset(-300, 0));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(h.inserted.single.index, 1);
      expect(h.inserted.single.songs.single.id, 'b');
      expect(find.text('Track b'), findsOneWidget);
      expect(h.queue, ['a', 'b', 'c']);
      await h.end(tester);
    }, skip: !sqliteAvailable);

    testWidgets('Undo still works after the sheet closed', (tester) async {
      final h = await _pumpRemovable(tester, database: true);
      await tester.drag(find.text('Track b'), const Offset(-300, 0));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      h.hideSheet.value = true;
      await tester.pump();
      expect(find.byType(QueueSheet), findsNothing);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(h.inserted.single.index, 1);
      await h.end(tester);
    }, skip: !sqliteAvailable);

    testWidgets('removing the only row offers no Undo', (tester) async {
      final h = await _pumpRemovable(tester, ids: const ['a']);
      await tester.drag(find.text('Track a'), const Offset(-300, 0));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(h.removed, [0]);
      expect(find.text('Removed “Track a”'), findsOneWidget);
      expect(find.text('Undo'), findsNothing);
      await h.end(tester);
    });

    testWidgets('a handler that cannot insert at an index offers no Undo', (
      tester,
    ) async {
      final h = await _pumpRemovable(tester, batch: false);
      await tester.drag(find.text('Track b'), const Offset(-300, 0));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(find.text('Removed “Track b”'), findsOneWidget);
      expect(find.text('Undo'), findsNothing);
      await h.end(tester);
    });

    testWidgets('a failed removal brings the row back and reports', (
      tester,
    ) async {
      final locks = <bool>[];
      final h = await _pumpRemovable(
        tester,
        failRemove: true,
        onLock: locks.add,
      );
      await tester.drag(find.text('Track b'), const Offset(-300, 0));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(find.text('Track b'), findsOneWidget);
      expect(find.textContaining('Removed'), findsNothing);
      expect(h.errors.single.error, isA<StateError>());
      // The row survives, so only _commitRemoval can have released the lock.
      expect(locks, isNotEmpty);
      expect(locks.last, isFalse);
      await h.end(tester);
    });

    testWidgets('duplicate song: removing occurrence 0 keeps occurrence 1', (
      tester,
    ) async {
      final h = await _pumpRemovable(tester, ids: const ['a', 'b', 'a']);
      await tester.drag(find.text('Track a').first, const Offset(-300, 0));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(h.removed, [0]);
      expect(h.queue, ['b', 'a']);
      expect(find.text('Track a'), findsOneWidget);
      expect(find.text('Track b'), findsOneWidget);
      await h.end(tester);
    });

    testWidgets('a second swipe during a slow removal still removes its row', (
      tester,
    ) async {
      final h = await _pumpRemovable(
        tester,
        ids: const ['a', 'b', 'c', 'd'],
        removeDelay: const Duration(milliseconds: 300),
      );
      await tester.drag(find.text('Track b'), const Offset(-300, 0));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.drag(find.text('Track d'), const Offset(-300, 0));
      // The handler's delayed removals are timers, not frames.
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(h.queue, ['a', 'c']);
      expect(h.removed, [1, 2]);
      expect(find.text('Track a'), findsOneWidget);
      expect(find.text('Track c'), findsOneWidget);
      expect(find.text('Track b'), findsNothing);
      expect(find.text('Track d'), findsNothing);
      await h.end(tester);
    });

    testWidgets('the full Queue screen removes without a notice scope', (
      tester,
    ) async {
      final h = await _pumpRemovable(tester, screen: true, noticeScope: false);
      await tester.drag(find.text('Track b'), const Offset(-300, 0));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(h.removed, [1]);
      expect(h.queue, ['a', 'c']);
      expect(find.text('Track b'), findsNothing);
      expect(find.textContaining('Removed'), findsNothing);
      expect(tester.takeException(), isNull);
      await h.end(tester);
    });

    testWidgets('the swipe lock is released after a committed swipe', (
      tester,
    ) async {
      final locks = <bool>[];
      final h = await _pumpRemovable(tester, onLock: locks.add);
      await tester.drag(find.text('Track b'), const Offset(-300, 0));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(locks, isNotEmpty);
      expect(locks.last, isFalse);
      await h.end(tester);
    });

    testWidgets('the semantics action removes and shows Undo', (tester) async {
      final handle = tester.ensureSemantics();
      final h = await _pumpRemovable(tester);
      final node = tester.getSemantics(find.text('Track b'));
      final actions = {
        for (final id
            in node.getSemanticsData().customSemanticsActionIds ?? <int>[])
          CustomSemanticsAction.getAction(id)!.label: id,
      };
      expect(actions.keys, contains('Remove from Queue'));
      tester.semantics.performAction(
        find.semantics.byPredicate((n) => n.id == node.id),
        SemanticsAction.customAction,
        args: actions['Remove from Queue'],
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(h.removed, [1]);
      expect(find.text('Undo'), findsOneWidget);
      handle.dispose();
      await h.end(tester);
    });

    testWidgets('no semantics action while the queue is loading', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pumpRemovable(tester, pendingLogicalQueue: true);
      final node = tester.getSemantics(find.text('Track b'));
      final ids = node.getSemanticsData().customSemanticsActionIds ?? <int>[];
      expect(
        ids.map((id) => CustomSemanticsAction.getAction(id)!.label),
        isNot(contains('Remove from Queue')),
      );
      handle.dispose();
    });

    testWidgets('Reduce Motion removes without sliding or collapsing', (
      tester,
    ) async {
      final h = await _pumpRemovable(tester, reduceMotion: true);
      final g = await tester.startGesture(
        tester.getCenter(find.text('Track b')),
      );
      await g.moveBy(const Offset(-20, 0));
      await g.moveBy(const Offset(-200, 0));
      await tester.pump();
      await g.up();
      await tester.pump();
      await tester.pump();

      expect(find.text('Track b'), findsNothing);
      expect(h.removed, [1]);
      await h.end(tester);
    });

    testWidgets('the reveal turns red with a filled icon at the threshold', (
      tester,
    ) async {
      final h = await _pumpRemovable(tester, textScale: 1.3, width: 360);
      final g = await tester.startGesture(
        tester.getCenter(find.text('Track b')),
      );
      await g.moveBy(const Offset(-20, 0));
      await g.moveBy(const Offset(-60, 0));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
      expect(find.byIcon(Icons.delete), findsNothing);
      await g.moveBy(const Offset(-120, 0));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byIcon(Icons.delete), findsOneWidget);
      final label = find.text('Remove from Queue');
      expect(label, findsOneWidget);
      expect(tester.takeException(), isNull);
      final scheme = Theme.of(tester.element(label)).colorScheme;
      final bg = tester.widget<AnimatedContainer>(
        find
            .ancestor(of: label, matching: find.byType(AnimatedContainer))
            .first,
      );
      expect((bg.decoration! as BoxDecoration).color, scheme.errorContainer);
      await g.up();
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      await h.end(tester);
    });

    testWidgets('phone rows have no trash button', (tester) async {
      await _pumpRemovable(tester);
      expect(find.byTooltip('Remove'), findsNothing);
      expect(find.byIcon(Icons.delete_outline), findsNothing);
    });

    testWidgets('desktop rows keep the trash button', (tester) async {
      await _pumpRemovable(tester, desktop: true);
      expect(find.byTooltip('Remove'), findsNWidgets(3));
    });

    testWidgets('the desktop trash button removes with Undo', (tester) async {
      final h = await _pumpRemovable(tester, desktop: true);
      await tester.tap(find.byTooltip('Remove').at(1));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(h.removed, [1]);
      expect(find.text('Undo'), findsOneWidget);
      await h.end(tester);
    });
  });
}

class _MockHandler extends Mock implements NavisPlaybackHandler {}

class _BatchHandler extends _MockHandler implements QueueBatchEditor {}

class _Removable {
  _Removable(this.queue);

  List<String> queue;
  final removed = <int>[];
  final inserted = <QueueInsertRun>[];
  final errors = <PlaybackActionError>[];
  final hideSheet = ValueNotifier<bool>(false);
  final notices = AppNoticeController();

  /// Ends the notice timer, which would outlive the test otherwise.
  Future<void> end(WidgetTester tester) async {
    notices.dismiss();
    await tester.pump();
  }
}

/// A real [QueueController] over a handler that really drops the id from the
/// published queue, so the rows behave as in the app.
Future<_Removable> _pumpRemovable(
  WidgetTester tester, {
  List<String> ids = const ['a', 'b', 'c'],
  bool batch = true,
  bool database = false,
  bool failRemove = false,
  Duration removeDelay = Duration.zero,
  bool noticeScope = true,
  bool screen = false,
  bool desktop = false,
  bool reduceMotion = false,
  bool pendingLogicalQueue = false,
  double textScale = 1,
  double width = 390,
  ValueChanged<bool>? onLock,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 844);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final h = _Removable(List.unmodifiable(ids));
  final snapshots = StreamController<PlaybackSnapshot>.broadcast();
  addTearDown(snapshots.close);
  PlaybackSnapshot snap() => const PlaybackSnapshot.idle().copyWith(
    queueSongIds: h.queue,
    currentSongId: h.queue.isEmpty ? null : h.queue.first,
    currentIndex: h.queue.isEmpty ? null : 0,
    isLoading: pendingLogicalQueue,
    hasPendingLogicalQueue: pendingLogicalQueue,
  );
  void publish(List<String> next) {
    h.queue = List.unmodifiable(next);
    snapshots.add(snap());
  }

  final handler = batch ? _BatchHandler() : _MockHandler();
  when(() => handler.snapshotStream).thenAnswer((_) => snapshots.stream);
  when(() => handler.snapshot).thenAnswer((_) => snap());
  when(() => handler.removeAt(any())).thenAnswer((invocation) async {
    if (removeDelay > Duration.zero) await Future<void>.delayed(removeDelay);
    if (failRemove) throw StateError('remove failed');
    final index = invocation.positionalArguments.first as int;
    h.removed.add(index);
    publish([...h.queue]..removeAt(index));
  });
  if (handler is QueueBatchEditor) {
    when(
      () => (handler as QueueBatchEditor).insertQueueRuns(any()),
    ).thenAnswer((invocation) async {
      final runs = invocation.positionalArguments.first as List<QueueInsertRun>;
      h.inserted.addAll(runs);
      final next = [...h.queue];
      for (final run in runs) {
        next.insertAll(
          run.index.clamp(0, next.length),
          run.songs.map((song) => song.id),
        );
      }
      publish(next);
      return const QueueBatchEditResult(skippedSongIds: <String>[]);
    });
  }
  NavisDatabase? db;
  if (database) {
    db = createTestDatabase();
    addTearDown(db.close);
    await db.libraryDao.upsertSongs([
      for (final id in ids.toSet())
        SongsTableCompanion.insert(id: id, title: 'Track $id'),
    ]);
  }
  final notices = h.notices;
  addTearDown(notices.dispose);
  final container = ProviderContainer(
    overrides: [
      if (db != null) ...withTestDatabase(db),
      audioHandlerProvider.overrideWithValue(handler),
      appSettingsProvider.overrideWithValue(
        const AsyncData(AppSettingsModel.defaults()),
      ),
      songByIdProvider.overrideWith(
        (ref, id) => Stream.value(_song(id, 'Track $id')),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.listen(
    playbackActionErrorProvider,
    (_, next) => next.whenData(h.errors.add),
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: reduceMotion,
          ),
          child: noticeScope
              ? AppNoticeScope(
                  notifier: notices,
                  child: Stack(
                    children: [
                      child!,
                      AppNoticeHost(controller: notices),
                    ],
                  ),
                )
              : child!,
        ),
        home: AdaptiveContextScope(
          adaptiveContext: resolveAdaptiveContext(
            desktopRuntime: desktop,
            viewportSize: Size(width, 844),
            safePadding: EdgeInsets.zero,
          ),
          child: screen
              ? const QueueScreen()
              : Scaffold(
                  body: ValueListenableBuilder<bool>(
                    valueListenable: h.hideSheet,
                    builder: (context, hidden, _) => hidden
                        ? const SizedBox()
                        : QueueSheet(
                            scrollController: ScrollController(),
                            onItemSwipeActiveChanged: onLock,
                          ),
                  ),
                ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return h;
}
