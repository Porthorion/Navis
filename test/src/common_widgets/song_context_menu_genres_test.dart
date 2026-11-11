import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/genre_chips.dart';
import 'package:navis/src/common_widgets/song_context_menu.dart';
import 'package:navis/src/common_widgets/song_sheet_header.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../helpers/adaptive_test_harness.dart';
import '../../helpers/test_database.dart';
import '../../helpers/test_theme.dart';

SongsTableData _song({bool external = false}) => SongsTableData(
  id: external ? 'ext-1' : 's1',
  title: 'Song',
  genres: const <String>['Hip Hop', 'Rock'],
  isProvisional: false,
  isExternal: external,
);

void main() {
  late NavisDatabase db;

  setUp(() {
    db = createTestDatabase();
    addTearDown(db.close);
  });

  Future<void> openMenu(
    WidgetTester tester,
    SongsTableData song, {
    Offset? anchor,
  }) async {
    setAdaptiveTestViewport(tester, const Size(900, 900));
    await tester.pumpWidget(
      ProviderScope(
        overrides: withTestDatabase(
          db,
          overrides: [showGenresPageProvider.overrideWithValue(true)],
        ),
        child: MaterialApp(
          theme: testTheme(),
          localizationsDelegates: navisLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () =>
                      showSongContextMenu(context, ref, song, anchor: anchor),
                  child: const Text('Open menu'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open menu'));
    await tester.pumpAndSettle();
  }

  for (final anchored in <bool>[false, true]) {
    final where = anchored ? 'desktop popup menu' : 'bottom sheet';
    testWidgets('the $where leads with the song\'s genre chips', (
      tester,
    ) async {
      await openMenu(
        tester,
        _song(),
        anchor: anchored ? const Offset(300, 300) : null,
      );
      expect(
        find.byType(SongSheetHeader),
        anchored ? findsNothing : findsOneWidget,
      );
      expect(find.byType(GenreChips), findsOneWidget);
      expect(find.text('Hip Hop'), findsOneWidget);
      expect(find.text('Rock'), findsOneWidget);
    });

    testWidgets('the $where has no chips for a remote song', (tester) async {
      await openMenu(
        tester,
        _song(external: true),
        anchor: anchored ? const Offset(300, 300) : null,
      );
      expect(find.byType(GenreChips), findsNothing);
    });
  }
}
