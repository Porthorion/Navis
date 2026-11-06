import 'package:audio_service/audio_service.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/rating_widget.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/media_info.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/adaptive_test_harness.dart';
import '../../../../helpers/now_playing_harness.dart';
import '../../../../helpers/test_database.dart';

const _playback = PlaybackSnapshot(
  queueSongIds: <String>['s1'],
  currentSongId: 's1',
  currentIndex: 0,
  playing: true,
  processingState: AudioProcessingState.ready,
  position: Duration(seconds: 42),
  duration: Duration(minutes: 3),
  bufferedPosition: Duration(minutes: 1),
  shuffleMode: AudioServiceShuffleMode.none,
  repeatMode: AudioServiceRepeatMode.none,
);

const _song = SongsTableData(
  id: 's1',
  title: 'Aurora',
  artistName: 'Some Artist',
  albumName: 'Some Album',
  suffix: 'flac',
  bitRate: 900,
  size: 30 * 1024 * 1024,
  duration: 180,
  isProvisional: false,
  isExternal: false,
);

const _chip = 'FLAC • 900 Kb/s';

void main() {
  Future<void> pumpPhone(WidgetTester tester) async {
    setAdaptiveTestViewport(tester, const Size(390, 844));
    final container = createNowPlayingContainer(
      overrides: <Override>[
        songByIdProvider.overrideWith((ref, id) => Stream.value(_song)),
        songServerDetailsProvider.overrideWith((ref, id) async => null),
        songDownloadStateProvider.overrideWith(
          (ref, id) => SongDownloadState.none,
        ),
        serverUserIsAdminProvider.overrideWith((ref) async => false),
      ],
    );
    container.read(nowPlayingTestPlaybackProvider.notifier).state = _playback;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: NowPlayingScreen(onCollapse: () {})),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // The visible line of the cycling info panel.
  final infoText = find
      .descendant(
        of: find.byKey(const ValueKey('nowPlayingInfoSwitcher')),
        matching: find.byType(Text),
      )
      .first;
  final sheet = find.byKey(const ValueKey('mediaInfoSheet'));

  testWidgets('long press on the quality chip opens the track info sheet', (
    tester,
  ) async {
    await pumpPhone(tester);
    expect(find.text(_chip), findsOneWidget);
    expect(sheet, findsNothing);

    await tester.longPress(find.text(_chip));
    await tester.pumpAndSettle();
    expect(sheet, findsOneWidget);
    expect(find.text('Server file'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, skip: !sqliteAvailable);

  testWidgets('tap still cycles the chip and opens nothing', (tester) async {
    await pumpPhone(tester);
    await tester.tap(find.text(_chip));
    await tester.pumpAndSettle();
    expect(find.text(_chip), findsNothing);
    expect(find.text('Playing 1 of 1'), findsOneWidget);
    expect(sheet, findsNothing);
  }, skip: !sqliteAvailable);

  testWidgets('long press on the star rating still edits the rating', (
    tester,
  ) async {
    await pumpPhone(tester);
    // Quality, queue, release date and speed come before the rating.
    for (var i = 0; i < 4; i++) {
      await tester.tap(infoText);
      await tester.pumpAndSettle();
    }
    expect(find.byType(RatingWidget), findsNothing);
    await tester.longPress(infoText);
    await tester.pumpAndSettle();
    expect(find.byType(RatingWidget), findsOneWidget);
    expect(sheet, findsNothing);
  }, skip: !sqliteAvailable);

  testWidgets('the chip has the long-press hint and a screen-reader action', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpPhone(tester);
    final data = tester.getSemantics(find.text(_chip)).getSemanticsData();
    final labels = data.customSemanticsActionIds
        ?.map((id) => CustomSemanticsAction.getAction(id)?.label)
        .toList();
    expect(labels, contains('Track info'));
    // A tooltip never shows on touch here (the long press opens the sheet),
    // so the hint is for screen readers.
    expect(data.hint, 'Hold for track info');
    handle.dispose();
  }, skip: !sqliteAvailable);

  testWidgets('the Track Info row in the settings panel opens the sheet', (
    tester,
  ) async {
    await pumpPhone(tester);
    await tester.tap(find.byKey(const ValueKey('nowPlayingSettingsAction')));
    await tester.pumpAndSettle();
    final row = find.widgetWithText(ListTile, 'Track Info');
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.info_outline)),
      findsOneWidget,
    );
    expect(find.text('Source, quality and file details'), findsOneWidget);

    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(sheet, findsOneWidget);
    expect(find.byKey(const ValueKey('nowPlayingSettingsSheet')), findsNothing);
  }, skip: !sqliteAvailable);
}
