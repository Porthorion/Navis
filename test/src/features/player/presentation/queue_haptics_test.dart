import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/queue_sheet.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/haptics_spy.dart';

import 'package:navis/src/common_widgets/navis_haptics.dart';
import 'package:navis/src/features/settings/domain/haptics_prefs.dart';

class _Queue extends QueueController {
  new(this.ids);

  final List<String> ids;
  int removed = 0;

  @override
  List<String> build() => ids;

  @override
  Future<void> reorder(int oldIndex, int newIndex) async {}

  @override
  Future<QueueRemoval?> removeForUndo(int index, String songId) async {
    removed++;
    return null;
  }
}

const _ids = <String>['song-1', 'song-2', 'song-3'];

Future<_Queue> _pump(WidgetTester tester) async {
  // The commit point is 45 percent of the row, so the drags below need a phone
  // width: 380 dp is past it at 390 dp.
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final queue = _Queue(_ids);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playerStateProvider.overrideWithValue(
          const PlaybackSnapshot(
            queueSongIds: _ids,
            currentSongId: 'song-2',
            currentIndex: 1,
            playing: false,
            processingState: AudioProcessingState.ready,
            position: Duration.zero,
            duration: Duration(minutes: 3),
            bufferedPosition: Duration.zero,
            shuffleMode: AudioServiceShuffleMode.none,
            repeatMode: AudioServiceRepeatMode.none,
          ),
        ),
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
        queueProvider.overrideWith(() => queue),
        songByIdProvider.overrideWith(
          (ref, id) => Stream.value(
            SongsTableData(
              isProvisional: false,
              isExternal: false,
              id: id,
              title: 'Track $id',
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
        home: Scaffold(body: QueueSheet(scrollController: ScrollController())),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return queue;
}

void main() {
  testWidgets('picking a row up and dropping it feels like a drag', (
    tester,
  ) async {
    final spy = HapticsSpy.install(tester);
    await _pump(tester);
    final handle = find.byIcon(Icons.drag_indicator_rounded).first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(await spy.take(tester), ['dragStart']);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(await spy.take(tester), ['dragEnd']);
  });

  testWidgets('swiping a row to remove it clicks at the dismiss point, '
      'releases when pulled back and is firm on commit', (tester) async {
    final spy = HapticsSpy.install(tester);
    final queue = await _pump(tester);
    final row = find.byType(Dismissible).first;
    final start = tester.getCenter(row);

    var gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(-20, 0));
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(await spy.take(tester), ['thresholdOn']);
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(await spy.take(tester), ['thresholdOff']);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(queue.removed, 0);

    gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(-20, 0));
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    spy.kinds.clear();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(queue.removed, 1);
    expect(await spy.take(tester), ['reject']);
  });

  testWidgets('Lists & Menus off silences reordering and swiping a row away', (
    tester,
  ) async {
    final spy = HapticsSpy.install(tester);
    final queue = await _pump(tester);
    NavisHaptics.prefs = HapticsPrefs.fromColumns(
      true,
      HapticCategory.listsAndMenus.bit,
    );
    final handle = find.byIcon(Icons.drag_indicator_rounded).first;
    final drag = await tester.startGesture(tester.getCenter(handle));
    await drag.moveBy(const Offset(0, 30));
    await tester.pump();
    await drag.moveBy(const Offset(0, 40));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();

    final swipe = await tester.startGesture(
      tester.getCenter(find.byType(Dismissible).first),
    );
    await swipe.moveBy(const Offset(-20, 0));
    for (var i = 0; i < 12; i++) {
      await swipe.moveBy(const Offset(-30, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await swipe.up();
    await tester.pumpAndSettle();
    expect(queue.removed, 1);
    expect(await spy.take(tester), isEmpty);
  });
}
