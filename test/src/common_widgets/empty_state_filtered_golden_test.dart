import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/common_widgets/empty_state.dart';

import '../../helpers/test_theme.dart';

void main() {
  Future<void> pumpState(WidgetTester tester, {required bool canClear}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: testTheme(),
        localizationsDelegates: navisLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: EmptyState(
            title: 'No downloaded content',
            subtitle: 'Download albums or tracks to see them here.',
            icon: Icons.download_done_outlined,
            action: canClear
                ? FilledButton.tonalIcon(
                    onPressed: () {},
                    icon: const Icon(Icons.filter_alt_off_outlined),
                    label: const Text('Show all'),
                  )
                : null,
          ),
        ),
      ),
    );
  }

  testWidgets('filtered empty state before has no path back to content', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpState(tester, canClear: false);

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/filtered_empty_state_before.png'),
    );
  });

  testWidgets('filtered empty state offers one clear recovery action', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpState(tester, canClear: true);

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/filtered_empty_state_after.png'),
    );
  });
}
