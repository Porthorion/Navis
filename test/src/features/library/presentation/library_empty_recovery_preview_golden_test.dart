import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool hasRecoveryAction}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(Colors.deepPurple),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: EmptyState(
            icon: Icons.visibility_off_outlined,
            title: 'No library pages enabled',
            subtitle:
                'Enable a page in Appearance settings to browse your library.',
            action: hasRecoveryAction
                ? FilledButton.tonalIcon(
                    onPressed: () {},
                    icon: const Icon(Icons.tune_outlined),
                    label: const Text('Open Appearance settings'),
                  )
                : null,
          ),
        ),
      ),
    );
  }

  testWidgets('library-disabled before explains the fix without a path to it', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, hasRecoveryAction: false);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/library_empty_recovery_before.png'),
    );
  });

  testWidgets('library-disabled after offers Appearance settings directly', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, hasRecoveryAction: true);
    expect(
      find.widgetWithText(FilledButton, 'Open Appearance settings'),
      findsOneWidget,
    );
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/library_empty_recovery_after.png'),
    );
  });
}
