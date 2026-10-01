import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool loadingSkeleton}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(Colors.deepPurple),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          appBar: AppBar(title: const Text('Weekly Jams')),
          body: loadingSkeleton
              ? const ShimmerListPage(count: 8, leadingSize: 56)
              : const Center(child: CircularProgressIndicator()),
        ),
      ),
    );
  }

  testWidgets('weekly detail loading before is an isolated spinner', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, loadingSkeleton: false);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/weekly_detail_loading_before.png'),
    );
  });

  testWidgets('weekly detail loading after preserves the track rhythm', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pump(tester, loadingSkeleton: true);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/weekly_detail_loading_after.png'),
    );
  });
}
