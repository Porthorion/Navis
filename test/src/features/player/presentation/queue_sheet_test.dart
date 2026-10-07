import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/queue_sheet.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';

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
  Future<void> removeAt(int index) async {
    removeCalls++;
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
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pump();

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
    expect(find.byIcon(Icons.delete_outline), findsAtLeastNWidgets(1));
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(QueueSheet),
      matchesGoldenFile('goldens/queue_sheet_text_scale_200.png'),
    );
  });
}
