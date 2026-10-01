import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool requestFailed}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(Colors.deepPurple),
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ErrorState(
            title: requestFailed
                ? 'Could not load search results'
                : 'No results found',
            message: 'Check your connection and try again.',
            onRetry: () {},
          ),
        ),
      ),
    );
  }

  testWidgets('search failure before is mistaken for an empty query', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, requestFailed: false);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/search_error_state_before.png'),
    );
  });

  testWidgets('search failure after makes recovery explicit', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, requestFailed: true);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/search_error_state_after.png'),
    );
  });
}
