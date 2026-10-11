import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/queue_screen.dart';
import 'package:navis/src/features/player/presentation/queue_sheet.dart';
import 'package:navis/src/features/player/presentation/queue_track_row.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

class _Queue extends QueueController {
  new(this.ids);

  final List<String> ids;
  final removed = <int>[];
  final reordered = <(int, int)>[];

  @override
  List<String> build() => ids;

  @override
  Future<void> removeAt(int index) async => removed.add(index);

  @override
  Future<void> reorder(int oldIndex, int newIndex) async =>
      reordered.add((oldIndex, newIndex));
}

List<String> _ids(int count) => [for (var i = 0; i < count; i++) 'song-$i'];

PlaybackSnapshot _snapshot(List<String> ids, int? current) => PlaybackSnapshot(
  queueSongIds: ids,
  currentSongId: current == null ? null : ids[current],
  currentIndex: current,
  playing: true,
  processingState: AudioProcessingState.ready,
  position: Duration.zero,
  duration: const Duration(minutes: 3),
  bufferedPosition: Duration.zero,
  shuffleMode: AudioServiceShuffleMode.none,
  repeatMode: AudioServiceRepeatMode.none,
);

Widget _app(_Queue queue, PlaybackSnapshot snapshot, {required bool sheet}) {
  return ProviderScope(
    overrides: [
      playerStateProvider.overrideWithValue(snapshot),
      appSettingsProvider.overrideWithValue(
        const AsyncData(AppSettingsModel.defaults()),
      ),
      queueProvider.overrideWith(() => queue),
      songByIdProvider.overrideWith(
        (ref, songId) => Stream.value(
          SongsTableData(
            isProvisional: false,
            isExternal: false,
            id: songId,
            title: 'Track $songId',
            albumId: 'album',
            artistName: 'Artist',
            albumName: 'Album',
            duration: 180,
          ),
        ),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: navisLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: sheet
          ? Scaffold(body: QueueSheet(scrollController: ScrollController()))
          : const QueueScreen(),
    ),
  );
}

Future<_Queue> _pump(
  WidgetTester tester,
  int count,
  int? current, {
  required bool sheet,
}) async {
  final ids = _ids(count);
  final queue = _Queue(ids);
  await tester.pumpWidget(_app(queue, _snapshot(ids, current), sheet: sheet));
  // Settle the post-frame estimate and refinement frames.
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return queue;
}

Finder _row(int index) => find.byWidgetPredicate(
  (w) => w is QueueTrackRow && w.index == index,
  description: 'queue row $index',
);

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position;

void main() {
  for (final sheet in [true, false]) {
    final host = sheet ? 'QueueSheet' : 'QueueScreen';

    group(host, () {
      testWidgets('centres a deep current row in a 200-song queue', (
        tester,
      ) async {
        await _pump(tester, 200, 120, sheet: sheet);

        expect(_row(120), findsOneWidget);
        final list = tester.getRect(find.byType(ReorderableListView));
        final row = tester.getRect(_row(120));
        expect(
          (row.center.dy - list.center.dy).abs(),
          lessThanOrEqualTo(row.height),
        );
        expect(_position(tester).pixels, greaterThan(0));
      });

      testWidgets('first song stays at the top', (tester) async {
        await _pump(tester, 200, 0, sheet: sheet);

        expect(_position(tester).pixels, 0);
        expect(_row(0), findsOneWidget);
      });

      testWidgets('last song clamps at the max extent', (tester) async {
        await _pump(tester, 200, 199, sheet: sheet);

        final position = _position(tester);
        expect(position.pixels, position.maxScrollExtent);
        expect(_row(199), findsOneWidget);
      });

      testWidgets('short queue does not scroll', (tester) async {
        await _pump(tester, 4, 3, sheet: sheet);

        expect(_position(tester).pixels, 0);
      });

      testWidgets('unknown current index does not scroll', (tester) async {
        await _pump(tester, 200, null, sheet: sheet);

        expect(_position(tester).pixels, 0);
      });

      testWidgets('remove and reorder still work after centring', (
        tester,
      ) async {
        final queue = await _pump(tester, 200, 120, sheet: sheet);

        await tester.drag(find.text('Track song-120'), const Offset(-400, 0));
        await tester.pumpAndSettle();
        expect(queue.removed, [120]);

        final list = tester.widget<ReorderableListView>(
          find.byType(ReorderableListView),
        );
        list.onReorderItem!(120, 121);
        await tester.pump();
        expect(queue.reordered, isNotEmpty);
      });

      testWidgets('does not re-centre after the user scrolls and a rebuild', (
        tester,
      ) async {
        final ids = _ids(200);
        final queue = _Queue(ids);
        await tester.pumpWidget(_app(queue, _snapshot(ids, 120), sheet: sheet));
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.drag(
          find.byType(ReorderableListView),
          const Offset(0, -300),
        );
        await tester.pumpAndSettle();
        final scrolled = _position(tester).pixels;

        // Track change: the current index moves, the list rebuilds.
        await tester.pumpWidget(_app(queue, _snapshot(ids, 10), sheet: sheet));
        await tester.pumpAndSettle();

        expect(_position(tester).pixels, scrolled);
      });
    });
  }
}
