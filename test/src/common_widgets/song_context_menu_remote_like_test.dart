import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/song_context_menu.dart';
import 'package:navis/src/database/navis_database.dart';

import '../../helpers/adaptive_test_harness.dart';
import '../../helpers/test_database.dart';
import '../../helpers/test_theme.dart';

void main() {
  late NavisDatabase db;

  setUp(() {
    db = createTestDatabase();
    addTearDown(db.close);
  });

  for (final anchored in <bool>[false, true]) {
    final where = anchored ? 'desktop popup menu' : 'bottom sheet';
    testWidgets('the $where explains why a remote song cannot be liked', (
      tester,
    ) async {
      setAdaptiveTestViewport(tester, const Size(900, 900));
      final notices = AppNoticeController();
      addTearDown(notices.dispose);
      const song = SongsTableData(
        id: 'ext-deezer-song-1',
        title: 'Song',
        isProvisional: true,
        isExternal: true,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: withTestDatabase(db),
          child: MaterialApp(
            theme: testTheme(),
            localizationsDelegates: navisLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (_, child) =>
                AppNoticeScope(notifier: notices, child: child!),
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => showSongContextMenu(
                      context,
                      ref,
                      song,
                      anchor: anchored ? const Offset(300, 300) : null,
                    ),
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

      await tester.tap(find.text('Like'));
      await tester.pumpAndSettle();

      expect(notices.notice?.message, 'Not available for remote tracks.');
      await tester.pump(const Duration(seconds: 3));
    });
  }
}
