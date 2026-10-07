import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navis/l10n/navis_localizations.dart';
import 'package:navis/src/routing/shell_offline_banner.dart';
import 'package:navis/src/theme/navis_theme.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required String message}) {
    return tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildDarkTheme(Colors.deepPurple),
          localizationsDelegates: navisLocalizationsDelegates,
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(400, 160),
              padding: EdgeInsets.only(top: 24),
              viewPadding: EdgeInsets.only(top: 24),
            ),
            child: Scaffold(
              body: ShellOfflineBannerScope(
                visible: true,
                message: message,
                child: const ShellOfflineBannerFrame(child: SizedBox.expand()),
              ),
            ),
          ),
        ),
      ),
    );
  }

  for (final (name, message) in <(String, String)>[
    ('retrying', 'Server unreachable. Retrying every 30s.'),
    ('quiet', 'Offline mode'),
  ]) {
    testWidgets('offline banner below a status bar while $name', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(400, 160));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pump(tester, message: message);
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/offline_status_$name.png'),
      );
    });
  }
}
