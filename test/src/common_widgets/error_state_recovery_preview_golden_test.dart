import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool recovered}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(Colors.deepPurple),
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: recovered
              ? ErrorState(
                  title: 'Could not load playback settings',
                  onRetry: () {},
                )
              : const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'StateError: Settings repository unavailable (503)',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  testWidgets('settings error before exposes a raw backend failure', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, recovered: false);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/error_state_recovery_before.png'),
    );
  });

  testWidgets('settings error after provides recovery and retry', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, recovered: true);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/error_state_recovery_after.png'),
    );
  });
}
